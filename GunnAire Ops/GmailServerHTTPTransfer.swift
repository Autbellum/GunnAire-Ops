import Foundation

nonisolated enum GmailServerHTTPError: Error { case response, limit, status(Int) }

/// Delegate state is protected by one lock, including cancellation before start.
/// Stop at the byte boundary while receiving, not after allocating an unbounded
/// provider reply. Never follow redirects or retain a private response in a cache.
nonisolated final class GmailServerHTTPTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maximum: Int
    private let lock = NSLock()
    private var bytes = Data()
    private var response: HTTPURLResponse?
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var session: URLSession?
    private var finished = false

    init(maximum: Int) { self.maximum = maximum }

    static func data(for request: URLRequest, maximum: Int, configuration: URLSessionConfiguration = .ephemeral) async throws -> (Data, HTTPURLResponse) {
        let receiver = GmailServerHTTPTransfer(maximum: maximum)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { receiver.start(request, configuration: configuration, continuation: $0) }
        } onCancel: { receiver.finish(.failure(CancellationError())) }
    }
    private func start(_ request: URLRequest, configuration: URLSessionConfiguration,
                       continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) {
        lock.lock()
        if finished { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        guard maximum > 0 else { lock.unlock(); continuation.resume(throwing: GmailServerHTTPError.limit); return }
        self.continuation = continuation
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 100; configuration.timeoutIntervalForResource = 110
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: request)
        lock.unlock(); task.resume()
    }
    private func finish(_ result: Result<(Data, HTTPURLResponse), Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation, session = self.session
        self.continuation = nil; self.session = nil; bytes = Data(); response = nil
        lock.unlock()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            finish(.failure(GmailServerHTTPError.response)); completionHandler(.cancel); return
        }
        guard http.statusCode == 200 else {
            finish(.failure(GmailServerHTTPError.status(http.statusCode))); completionHandler(.cancel); return
        }
        guard http.expectedContentLength <= maximum else {
            finish(.failure(GmailServerHTTPError.limit)); completionHandler(.cancel); return
        }
        lock.lock(); let stopped = finished
        if !stopped { self.response = http }
        lock.unlock(); completionHandler(stopped ? .cancel : .allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard data.count <= maximum - bytes.count else { lock.unlock(); finish(.failure(GmailServerHTTPError.limit)); return }
        bytes.append(data); lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        lock.lock()
        let result: Result<(Data, HTTPURLResponse), Error> = response.map { .success((bytes, $0)) } ?? .failure(GmailServerHTTPError.response)
        lock.unlock(); finish(result)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        finish(.failure(GmailServerHTTPError.status(response.statusCode))); completionHandler(nil)
    }
}
