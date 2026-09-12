import Foundation
import SwiftData
import Combine
import AuthenticationServices

enum GoogleServerFeature: String, Codable, CaseIterable, Identifiable {
    case mail, calendar, drive
    var id: String { rawValue }
    var title: String { switch self { case .mail: "Mail"; case .calendar: "Calendar"; case .drive: "Drive files" } }
    var scopes: Set<String> {
        let prefix = "https://www.googleapis.com/auth/"
        switch self {
        case .mail: return [prefix + "gmail.modify"]
        case .calendar: return [prefix + "calendar.events", prefix + "calendar.calendarlist.readonly"]
        case .drive: return [prefix + "drive.file"]
        }
    }
}

enum GoogleServerConnectionError: Error, LocalizedError, Equatable {
    case access, storage, changed, invalid, unavailable, notFound, cancelled, presentation, network
    var errorDescription: String? {
        switch self {
        case .access: "Sign in again with your approved business account, then reopen Google Access."
        case .storage: "The saved approval could not be secured. Nothing was discarded. Reopen Google Access to try again."
        case .changed: "This request or account changed. Check its status before continuing."
        case .invalid: "The server reply could not be verified. Check the original request before trying again."
        case .unavailable: "Shared Google access is not available on the business server yet. Your device connection is unchanged."
        case .notFound: "The server has not confirmed this request. Continue the original approval or cancel it."
        case .cancelled: "Google approval was cancelled."
        case .presentation: "Open this app in the foreground to continue with Google."
        case .network: "Could not confirm the result. Check the connection, then check this request's status."
        }
    }
    static func safe(_ error: Error) -> Self {
        if let own = error as? Self { return own }
        if case GunnAireBackendError.server(let status, _) = error {
            switch status {
            case 401, 403: return .access
            case 404: return .notFound
            case 409, 429: return .changed
            case 503: return .unavailable
            default: return .network
            }
        }
        if error is DecodingError { return .invalid }
        if error is KeychainStore.KeychainError { return .storage }
        if error is CompanyWorkspaceFailure { return .access }
        return .network
    }
}

struct GoogleServerScope: Codable, Equatable {
    let companyID: UUID
    let backendOrigin: String
    let actorEmail: String
    var storageKey: String {
        "GunnAireGoogleConnection-" + CompanyWorkspaceSession.digest(
            companyID.uuidString.lowercased() + "\n" + backendOrigin + "\n" + actorEmail)
    }
    func validate() throws {
        guard let url = URLComponents(string: backendOrigin), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.port == nil || url.port == 443,
              actorEmail == AppAccess.normalizedEmail(actorEmail), actorEmail.contains("@"),
              !actorEmail.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw GoogleServerConnectionError.access }
    }
}

struct GoogleServerAttempt: Codable, Equatable {
    enum State: String, Codable { case pending, exchanging, connected, denied, review, cancelled, expired }
    let id: UUID
    let companyID: UUID
    let actorEmail: String
    let features: [GoogleServerFeature]
    let state: State
    let grantID: UUID?
    var finished: Bool { state != .pending && state != .exchanging }
    func validate(scope: GoogleServerScope, record: GoogleServerPending? = nil) throws {
        guard companyID == scope.companyID, actorEmail == scope.actorEmail,
              !features.isEmpty, Set(features).count == features.count,
              (state == .connected) == (grantID != nil),
              record == nil || (record?.id == id && record?.action == .authorize && Set(record?.features ?? []) == Set(features))
        else { throw GoogleServerConnectionError.invalid }
    }
}

struct GoogleServerSnapshot: Codable, Equatable {
    enum State: String, Codable { case active, refreshing, review, disconnected }
    let id: UUID?
    let companyID: UUID
    let actorEmail: String
    let state: State
    let features: [GoogleServerFeature]
    let pendingAttempt: GoogleServerAttempt?
    func validate(scope: GoogleServerScope) throws {
        guard companyID == scope.companyID, actorEmail == scope.actorEmail,
              state == .disconnected || id != nil, Set(features).count == features.count,
              state == .active || features.isEmpty else { throw GoogleServerConnectionError.invalid }
        try pendingAttempt?.validate(scope: scope)
        if let pendingAttempt, ![.pending, .exchanging, .expired].contains(pendingAttempt.state) {
            throw GoogleServerConnectionError.invalid
        }
    }
}

/// No authorization URL, OAuth state, code, nonce or provider credential is saved
/// on the device. A disconnect also retains the exact original grant until read back.
struct GoogleServerPending: Codable, Equatable {
    enum Action: String, Codable { case authorize, disconnect }
    var version = 1
    let id: UUID
    let scope: GoogleServerScope
    let action: Action
    let features: [GoogleServerFeature]
    let sessionFingerprint: String?
    func validate(scope: GoogleServerScope) throws {
        try scope.validate()
        guard version == 1, self.scope == scope, Set(features).count == features.count,
              action == .authorize ? !features.isEmpty : features.isEmpty else { throw GoogleServerConnectionError.storage }
    }
}

struct GoogleServerPrepared: Decodable {
    let id: UUID
    let companyID: UUID
    let actorEmail: String
    let state: String
    let authorizationURL: String
    func validatedURL(record: GoogleServerPending) throws -> URL {
        guard id == record.id, companyID == record.scope.companyID, actorEmail == record.scope.actorEmail, state == "pending",
              authorizationURL.utf8.count <= 16384,
              let url = URLComponents(string: authorizationURL), url.scheme == "https", url.host == "accounts.google.com",
              url.port == nil, url.user == nil, url.password == nil, url.fragment == nil,
              url.percentEncodedPath == "/o/oauth2/v2/auth", let items = url.queryItems,
              Set(items.map(\.name)).count == items.count, items.allSatisfy({ $0.value != nil }) else { throw GoogleServerConnectionError.invalid }
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        let keys: Set<String> = ["client_id", "redirect_uri", "response_type", "scope", "access_type", "prompt", "include_granted_scopes", "state", "nonce", "login_hint", "hd", "code_challenge_method", "code_challenge"]
        let required = record.features.reduce(into: Set(["openid", "https://www.googleapis.com/auth/userinfo.email"])) { $0.formUnion($1.scopes) }
        guard Set(query.keys) == keys, query["response_type"] == "code", query["access_type"] == "offline",
              query["prompt"] == "consent", query["include_granted_scopes"] == "true", query["login_hint"] == actorEmail,
              query["hd"] == actorEmail.components(separatedBy: "@").last,
              query["client_id"]?.hasSuffix(".apps.googleusercontent.com") == true,
              query["redirect_uri"] == record.scope.backendOrigin + "/api/google/oauth/callback",
              Set((query["scope"] ?? "").split(separator: " ").map(String.init)) == required,
              query["code_challenge_method"] == "S256", Self.urlSafe(query["state"], length: 64),
              Self.urlSafe(query["nonce"], length: 43), Self.urlSafe(query["code_challenge"], length: 43),
              let result = url.url else { throw GoogleServerConnectionError.invalid }
        return result
    }
    private static func urlSafe(_ value: String?, length: Int) -> Bool {
        guard let value, value.utf8.count == length else { return false }
        return value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
    }
    static func validateCallback(_ url: URL, attemptID: UUID) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "gunnaireops", parts.host == "oauth", parts.port == nil,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.percentEncodedPath == "/google/connection", let items = parts.queryItems,
              items.count == 1, items[0].name == "attemptID", UUID(uuidString: items[0].value ?? "") == attemptID
        else { throw GoogleServerConnectionError.invalid }
    }
}

struct GoogleServerConnectionDependencies {
    let scope: GoogleServerScope
    let sessionFingerprint: String
    var check: () throws -> Void
    var read: () throws -> GoogleServerPending?
    var replace: (GoogleServerPending?, GoogleServerPending?) throws -> Void
    var request: (String, String, Data?) async throws -> Data
    var browse: (URL) async throws -> URL
    var stopBrowser: () -> Void

    static func live(context: ModelContext) throws -> Self {
        let workspace = CompanyWorkspaceAccessController.shared
        guard let session = CompanyWorkspaceSession.current, let company = workspace.verifiedCompanyID,
              let role = workspace.verifiedRole, role != .standard, workspace.authorizedContainer === context.container
        else { throw GoogleServerConnectionError.access }
        let scope = GoogleServerScope(companyID: company, backendOrigin: session.backendOrigin, actorEmail: session.email)
        try scope.validate()
        let generation = workspace.generation
        let browser = GoogleServerBrowser()
        return Self(scope: scope, sessionFingerprint: session.tokenFingerprint, check: {
            guard CompanyWorkspaceSession.current == session, workspace.generation == generation,
                  workspace.verifiedCompanyID == company, workspace.verifiedRole == role,
                  workspace.authorizedContainer === context.container else { throw GoogleServerConnectionError.access }
        }, read: { try KeychainStore.loadCodable(GoogleServerPending.self, account: scope.storageKey) }, replace: { expected, next in
            // All app windows serialize this read/compare/write on the main actor.
            guard try KeychainStore.loadCodable(GoogleServerPending.self, account: scope.storageKey) == expected else { throw GoogleServerConnectionError.changed }
            if let next { try next.validate(scope: scope); try KeychainStore.saveCodable(next, account: scope.storageKey) }
            else { try KeychainStore.remove(account: scope.storageKey) }
        }, request: { try await GunnAireBackendService.googleConnectionRequest(path: $0, method: $1, body: $2) },
            browse: { try await browser.open($0) }, stopBrowser: { browser.cancel() })
    }
}

@MainActor
final class GoogleServerConnectionController: ObservableObject {
    @Published private(set) var snapshot: GoogleServerSnapshot?
    @Published private(set) var pending: GoogleServerPending?
    @Published private(set) var attempt: GoogleServerAttempt?
    @Published private(set) var message: String?
    @Published private(set) var busy = false
    private let dependencies: GoogleServerConnectionDependencies?
    private var isOpen = true
    init(dependencies: GoogleServerConnectionDependencies) { self.dependencies = dependencies }
    init(context: ModelContext) {
        do { dependencies = try .live(context: context) }
        catch { dependencies = nil; message = GoogleServerConnectionError.safe(error).localizedDescription }
    }
    var available: Bool { dependencies != nil && isOpen }
    var canContinue: Bool {
        pending?.action == .authorize && pending?.sessionFingerprint == dependencies?.sessionFingerprint &&
        (attempt == nil || attempt?.state == .pending)
    }
    func leave() { isOpen = false; dependencies?.stopBrowser(); snapshot = nil; attempt = nil }
    private func checked() throws -> GoogleServerConnectionDependencies {
        guard isOpen, let dependencies else { throw GoogleServerConnectionError.access }
        try Task.checkCancellation(); try dependencies.check(); return dependencies
    }
    private func read() throws -> GoogleServerPending? {
        let deps = try checked(); let record = try deps.read(); try record?.validate(scope: deps.scope); return record
    }
    private func replace(_ old: GoogleServerPending?, with new: GoogleServerPending?) throws {
        let deps = try checked(); try deps.replace(old, new); pending = new
    }
    private func request<T: Decodable>(_ type: T.Type, path: String, method: String = "GET", body: Data? = nil) async throws -> T {
        let deps = try checked()
        do {
            let data = try await deps.request(path, method, body)
            _ = try checked()
            guard data.count <= 32768 else { throw GoogleServerConnectionError.invalid }
            return try JSONDecoder().decode(type, from: data)
        } catch { _ = try checked(); throw error }
    }
    private func loadSnapshot() async throws -> GoogleServerSnapshot {
        let deps = try checked()
        let response = try await request(GoogleServerSnapshot.self, path: "/api/google/connection?companyID=" + deps.scope.companyID.uuidString.lowercased())
        try response.validate(scope: deps.scope)
        return response
    }
    private func recover() async throws {
        let deps = try checked(); let original = try read()
        let current = try await loadSnapshot()
        guard try read() == original else { throw GoogleServerConnectionError.changed }
        snapshot = current; pending = original; attempt = nil
        if let original {
            if original.action == .disconnect {
                if current.id != original.id || current.state == .disconnected {
                    try replace(original, with: nil)
                    message = current.id == original.id ? "Shared access disconnected. Your device connection is unchanged." : "Google access changed elsewhere. The newer connection was not disconnected."
                } else { message = "Disconnection is not confirmed. Check again or retry the original disconnection." }
                return
            }
            let result = try await request(GoogleServerAttempt.self, path: "/api/google/authorizations/" + original.id.uuidString.lowercased())
            try result.validate(scope: deps.scope, record: original)
            guard try read() == original else { throw GoogleServerConnectionError.changed }
            attempt = result
            if result.finished {
                // A browser callback is never evidence of approval. The durable
                // attempt and its current grant must agree before showing success.
                let latest = try await loadSnapshot()
                guard try read() == original else { throw GoogleServerConnectionError.changed }
                snapshot = latest
                if result.state == .connected && (latest.id != result.grantID || latest.state != .active) {
                    message = "This approval finished, but Google access changed. Review the current access before reconnecting."
                } else {
                    switch result.state {
                    case .connected: message = nil // The status and per-feature rows already confirm approval.
                    case .cancelled, .denied: message = "Google approval was not completed. Your existing connection is unchanged."
                    case .expired: message = "The original approval expired. You can start a new request."
                    default: message = "Google could not confirm this approval. You can reconnect when ready."
                    }
                }
                try replace(original, with: nil)
            } else { message = result.state == .exchanging ? "Google is still confirming the original request. Check its status before continuing." : "An approval is unfinished. Continue it or cancel the original request." }
        } else if let remote = current.pendingAttempt, !remote.finished {
            let adopted = GoogleServerPending(id: remote.id, scope: deps.scope, action: .authorize, features: remote.features, sessionFingerprint: nil)
            try replace(nil, with: adopted); attempt = remote
            message = "An approval was started in another session. Finish it there, check its status, or cancel it here."
        }
    }
    private func perform(_ operation: () async throws -> Void) async {
        guard !busy else { return }; busy = true; message = nil
        defer { busy = false }
        do { try await operation() }
        catch {
            if isOpen { message = GoogleServerConnectionError.safe(error).localizedDescription }
            if (try? checked()) == nil { snapshot = nil; attempt = nil }
        }
    }
    func refresh() async { await perform { try await recover() } }
    func authorize(features: Set<GoogleServerFeature>) async {
        await perform {
            let deps = try checked()
            guard snapshot != nil, try read() == nil, !features.isEmpty else { throw GoogleServerConnectionError.changed }
            let record = GoogleServerPending(id: UUID(), scope: deps.scope, action: .authorize,
                features: features.sorted { $0.rawValue < $1.rawValue }, sessionFingerprint: deps.sessionFingerprint)
            try replace(nil, with: record) // Durable before the first HTTP request.
            try await open(record)
        }
    }
    func continueApproval() async {
        await perform {
            let original = try read()
            do { try await recover() } catch GoogleServerConnectionError.notFound { /* original prepare reply was lost */ }
            catch GunnAireBackendError.server(let status, _) where status == 404 { /* same original ID only */ }
            guard let original, try read() == original, canContinue else { throw GoogleServerConnectionError.changed }
            try await open(original)
        }
    }
    private func open(_ record: GoogleServerPending) async throws {
        let deps = try checked()
        guard record.sessionFingerprint == deps.sessionFingerprint, try read() == record else { throw GoogleServerConnectionError.changed }
        let body = try JSONEncoder().encode(PrepareBody(id: record.id, companyID: record.scope.companyID, features: record.features))
        let response = try await request(GoogleServerPrepared.self, path: "/api/google/authorizations", method: "POST", body: body)
        let url = try response.validatedURL(record: record)
        guard try read() == record else { throw GoogleServerConnectionError.changed }
        do {
            let callback = try await deps.browse(url)
            _ = try checked()
            guard try read() == record else { throw GoogleServerConnectionError.changed }
            try GoogleServerPrepared.validateCallback(callback, attemptID: record.id)
            try await recover()
        } catch GoogleServerConnectionError.cancelled {
            _ = try checked(); try await cancelOriginal(record)
        }
    }
    func cancelApproval() async {
        await perform {
            guard let original = try read(), original.action == .authorize else { throw GoogleServerConnectionError.changed }
            try await cancelOriginal(original)
        }
    }
    private func cancelOriginal(_ record: GoogleServerPending) async throws {
        let deps = try checked()
        guard try read() == record else { throw GoogleServerConnectionError.changed }
        let body = try JSONEncoder().encode(CancelBody(companyID: record.scope.companyID, features: record.features))
        let result = try await request(GoogleServerAttempt.self, path: "/api/google/authorizations/" + record.id.uuidString.lowercased() + "/cancel", method: "POST", body: body)
        try result.validate(scope: deps.scope, record: record)
        try await recover() // Cancellation racing a completed approval must read its grant.
    }
    func disconnect() async {
        await perform {
            let deps = try checked()
            var original = try read()
            if original == nil {
                guard let id = snapshot?.id, snapshot?.state != .disconnected else { throw GoogleServerConnectionError.changed }
                original = GoogleServerPending(id: id, scope: deps.scope, action: .disconnect, features: [], sessionFingerprint: deps.sessionFingerprint)
                try replace(nil, with: original)
            }
            guard let original, original.action == .disconnect else { throw GoogleServerConnectionError.changed }
            let body = try JSONEncoder().encode(DisconnectBody(companyID: deps.scope.companyID, grantID: original.id))
            let result = try await request(GoogleServerSnapshot.self, path: "/api/google/connection/disconnect", method: "POST", body: body)
            try result.validate(scope: deps.scope)
            guard result.id == original.id, result.state == .disconnected else { throw GoogleServerConnectionError.invalid }
            try await recover()
        }
    }
    private struct PrepareBody: Encodable { let id: UUID; let companyID: UUID; let features: [GoogleServerFeature] }
    private struct CancelBody: Encodable { let companyID: UUID; let features: [GoogleServerFeature] }
    private struct DisconnectBody: Encodable { let companyID: UUID; let grantID: UUID }
}

@MainActor
private final class GoogleServerBrowser {
    private var session: ASWebAuthenticationSession?
    private var anchor: ContentViewPresentationContextProvider?
    private var continuation: CheckedContinuation<URL, Error>?
    func open(_ url: URL) async throws -> URL {
        guard session == nil, let context = ContentViewPresentationContextProvider.makeIfAvailable() else { throw GoogleServerConnectionError.presentation }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation; anchor = context
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme("gunnaireops")) { [weak self] url, error in
                Task { @MainActor in
                    if let url { self?.finish(.success(url)) }
                    else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin { self?.finish(.failure(GoogleServerConnectionError.cancelled)) }
                    else { self?.finish(.failure(GoogleServerConnectionError.presentation)) }
                }
            }
            self.session = session; session.presentationContextProvider = context
            if !session.start() { finish(.failure(GoogleServerConnectionError.presentation)) }
        }
    }
    func cancel() {
        let previous = session
        finish(.failure(GoogleServerConnectionError.cancelled)); previous?.cancel()
    }
    private func finish(_ result: Result<URL, Error>) {
        let previous = continuation; continuation = nil; session = nil; anchor = nil
        previous?.resume(with: result)
    }
}

/// Connection management never follows a redirect carrying a business bearer.
final class GoogleConnectionNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                               newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
