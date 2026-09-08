import Foundation
import Testing
@testable import GunnAire_Ops

nonisolated private final class MailTransferProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let route = request.url!.lastPathComponent
        if route == "wait" { return }
        if route == "redirect" {
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil,
                headerFields: ["Location": "https://elsewhere.example.invalid/"])!
            // URLProtocol's redirect callback is unsupported on some test
            // runtimes. Deliver the 302 itself; it must not become success.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self); return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: route == "denied" ? 403 : 200,
            httpVersion: nil, headerFields: route == "advertised" ? ["Content-Length": "999999"] : [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 4))
        client?.urlProtocol(self, didLoad: Data(repeating: 66, count: route == "oversize" ? 6 : 4))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Bounded Mail HTTP transfer") struct GmailServerHTTPTransferTests {
    private func transfer(_ path: String) async throws -> (Data, HTTPURLResponse) {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MailTransferProtocol.self]
        let request = URLRequest(url: URL(string: "https://mail.example.invalid/" + path)!)
        return try await GmailServerHTTPTransfer.data(for: request, maximum: 8, configuration: config)
    }
    @Test func responseAtExactLimitIsDeliveredOnce() async throws {
        let (data, response) = try await transfer("exact")
        #expect(data == Data("AAAABBBB".utf8) && response.statusCode == 200)
    }
    @Test(arguments: ["oversize", "advertised"])
    func boundsApplyToChunksAndAdvertisedLength(_ path: String) async {
        await #expect(throws: GmailServerHTTPError.self) { try await transfer(path) }
    }
    @Test(arguments: ["denied", "redirect"])
    func rejectedAndRedirectedResponsesAreNeverContent(_ path: String) async {
        await #expect(throws: GmailServerHTTPError.self) { try await transfer(path) }
    }
    @Test func cancellationBeforeOrDuringStartCompletesWithoutAResponse() async {
        for _ in 0..<10 {
            let task = Task { try await transfer("wait") }
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
        }
    }
}
