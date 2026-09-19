import Foundation

/// A non-2xx reply from /api/qbo/change-capture, keeping the HTTP status and
/// the server's staff-facing `error` and `code` strings. Only a bounded body
/// is parsed and both strings are sanitized before they can reach a screen.
/// The Authorization header, tokens and request bodies are never captured.
nonisolated struct QuickBooksChangeHistoryServerFailure: Error, Equatable, Sendable {
    /// 200 plus every client/server error status. 1xx, other 2xx and 3xx stay
    /// rejected by the transfer exactly as before, so a redirect is never content.
    static let observedStatusCodes: Set<Int> = Set([200] + Array(400..<600))
    static let maximumParsedBodyBytes = 16 * 1024
    static let maximumMessageLength = 300
    static let maximumCodeLength = 64

    let status: Int
    let code: String?
    let message: String?

    init(status: Int, code: String?, message: String?) {
        self.status = status
        self.code = Self.sanitizedCode(code)
        self.message = Self.sanitizedMessage(message)
    }

    init(status: Int, body: Data) {
        var decoded: [String: Any] = [:]
        if !body.isEmpty, body.count <= Self.maximumParsedBodyBytes,
           let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            decoded = object
        }
        self.init(status: status, code: decoded["code"] as? String, message: decoded["error"] as? String)
    }

    /// The same status mapping the client already applies to a backend error.
    var backendError: GunnAireBackendError {
        .server(statusCode: status, message: "Accounting history was not confirmed.")
    }

    static func sanitizedCode(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              value.count <= maximumCodeLength,
              value.range(of: #"\A[A-Za-z0-9_.\-]+\z"#, options: .regularExpression) != nil else { return nil }
        return value
    }

    static func sanitizedMessage(_ value: String?) -> String? {
        guard let value else { return nil }
        let collapsed = value.unicodeScalars.map { scalar -> String in
            CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) ? " " : String(scalar)
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > maximumMessageLength else { return collapsed }
        return String(collapsed.prefix(maximumMessageLength)) + "…"
    }
}

/// One transport-level explanation for a shared accounting history failure.
/// `QuickBooksChangeHistoryError` stays the only error the UI branches on;
/// this is display-only detail so staff can tell a throttled provider, an
/// unavailable store, a gateway failure and a device timeout apart.
nonisolated struct QuickBooksChangeHistoryFailure: Equatable, Sendable {
    enum Kind: String, Sendable { case server = "Server", transport = "Transport", response = "Response" }

    let kind: Kind
    let status: Int?
    let code: String?
    let message: String
    let entity: String?
    let at: Date

    /// "Server: HTTP 503 provider_throttled - QuickBooks is busy. …",
    /// "Transport: URLError -1001 timed out." or
    /// "Response: DecodingError keyNotFound at versions[0].payloadSHA256."
    var summary: String {
        switch kind {
        case .server:
            let status = status.map { "HTTP \($0)" } ?? "HTTP"
            return "Server: \(status)\(code.map { " \($0)" } ?? "") - \(message)"
        case .transport, .response:
            return "\(kind.rawValue): \(code.map { "\($0) " } ?? "")\(message)"
        }
    }

    /// Appended to a resource's sync detail: " Server: HTTP 503 …".
    var detailSuffix: String { " " + summary }
}

/// The most recent shared-history failure per device session. Recorded by the
/// change-history client at the point an error is reduced to a safe
/// `QuickBooksChangeHistoryError`, so the UI can show why without changing
/// which error the sync logic branches on. Holds no amounts, customer data,
/// tokens, headers or request bodies.
@MainActor enum QuickBooksChangeHistoryDiagnostics {
    static private(set) var lastFailure: QuickBooksChangeHistoryFailure?
    static private(set) var failuresByEntity: [String: QuickBooksChangeHistoryFailure] = [:]

    static func record(_ error: Error, entity: QuickBooksChangeEntity?, at: Date = Date()) {
        guard let failure = describe(error, entity: entity, at: at) else { return }
        lastFailure = failure
        if let entity { failuresByEntity[entity.rawValue] = failure }
    }

    static func reset() {
        lastFailure = nil
        failuresByEntity = [:]
    }

    /// Pure mapping from a transport error to a display-safe failure. Returns
    /// nil for the client's own outcome errors and for access/cancellation,
    /// which already carry a specific user message.
    static func describe(_ error: Error, entity: QuickBooksChangeEntity?,
                         at: Date = Date()) -> QuickBooksChangeHistoryFailure? {
        let entity = entity?.rawValue
        if let own = error as? QuickBooksChangeHistoryError {
            // The client's own outcome errors used to be silent here, which
            // left every row with the generic sentence and no cause. Record
            // which check failed for which entity; no record content is kept.
            guard let cause = own.diagnosticCause else { return nil }
            return .init(kind: .response, status: nil, code: cause.code, message: cause.message, entity: entity, at: at)
        }
        if error is CancellationError
            || error is WorkspaceProviderAccessError || error is CompanyWorkspaceFailure { return nil }
        if let failure = error as? QuickBooksChangeHistoryServerFailure {
            return .init(kind: .server, status: failure.status, code: failure.code,
                         message: failure.message ?? "No error details were returned.", entity: entity, at: at)
        }
        if let backend = error as? GunnAireBackendError {
            if case .server(let status, let message) = backend {
                let text = QuickBooksChangeHistoryServerFailure.sanitizedMessage(message) ?? "No error details were returned."
                return .init(kind: .server, status: status, code: nil, message: text, entity: entity, at: at)
            }
            // A fixed label: the other cases' descriptions can embed the
            // request path, and a change-capture page path carries identifiers.
            return .init(kind: .transport, status: nil, code: nil,
                         message: "Backend request could not be sent.", entity: entity, at: at)
        }
        if let urlError = error as? URLError {
            return .init(kind: .transport, status: nil, code: "URLError \(urlError.code.rawValue)",
                         message: Self.name(for: urlError.code) + ".", entity: entity, at: at)
        }
        if let decoding = error as? DecodingError {
            let (kind, path) = Self.describe(decoding)
            let location = path.isEmpty ? "with no coding path" : "at " + path
            return .init(kind: .response, status: nil, code: "DecodingError \(kind)",
                         message: location + ".", entity: entity, at: at)
        }
        let nsError = error as NSError
        return .init(kind: .transport, status: nil, code: "\(nsError.domain) \(nsError.code)",
                     message: String(describing: type(of: error)) + ".", entity: entity, at: at)
    }

    private static func name(for code: URLError.Code) -> String {
        switch code {
        case .timedOut: "timed out"
        case .notConnectedToInternet: "not connected to the internet"
        case .networkConnectionLost: "network connection lost"
        case .cannotFindHost: "cannot find host"
        case .cannotConnectToHost: "cannot connect to host"
        case .dnsLookupFailed: "DNS lookup failed"
        case .secureConnectionFailed: "secure connection failed"
        case .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid: "server certificate rejected"
        case .appTransportSecurityRequiresSecureConnection: "insecure connection blocked"
        case .badServerResponse: "bad server response"
        case .dataNotAllowed: "cellular data not allowed"
        case .cancelled: "cancelled"
        default: "request failed"
        }
    }

    /// Only the error kind and coding keys (schema names), never decoded values
    /// or the decoder's free-text description.
    private static func describe(_ error: DecodingError) -> (kind: String, path: String) {
        func render(_ path: [CodingKey]) -> String {
            path.reduce(into: "") { rendered, key in
                if let index = key.intValue { rendered += "[\(index)]" }
                else { rendered += rendered.isEmpty ? key.stringValue : ".\(key.stringValue)" }
            }
        }
        switch error {
        case .keyNotFound(let key, let context): return ("keyNotFound", render(context.codingPath + [key]))
        case .typeMismatch(_, let context): return ("typeMismatch", render(context.codingPath))
        case .valueNotFound(_, let context): return ("valueNotFound", render(context.codingPath))
        case .dataCorrupted(let context): return ("dataCorrupted", render(context.codingPath))
        @unknown default: return ("unknown", "")
        }
    }
}
