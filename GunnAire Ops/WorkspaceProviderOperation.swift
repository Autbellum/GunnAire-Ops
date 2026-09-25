import Foundation

/// A provider write may already have committed even when its result can no
/// longer be delivered to the initiating workspace. Never silently retry it
/// under a new session or label it as a confirmed failure.
enum WorkspaceProviderAccessError: Error, LocalizedError, Equatable {
    case unavailable
    case changed(mayHaveReachedProvider: Bool)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Verify your company workspace before using this connection."
        case .changed(false):
            "Your business or provider connection changed. Reopen the workspace before trying again."
        case .changed(true):
            "Your connection changed after a request was sent. Its result is not confirmed here. Review the original provider transaction before retrying; saved work has been retained."
        }
    }
}

struct CompanyWorkspaceOperationStamp: Equatable {
    let generation: UUID
    let session: CompanyWorkspaceSession
}

/// Ephemeral, main-actor operation identity shared by all attempts, pages and
/// upload chunks. It contains no bearer token and is never persisted.
@MainActor
final class WorkspaceProviderOperation {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)
    private let isCurrent: () -> Bool
    private let parent: WorkspaceProviderOperation?
    private let retainedServerMail: GmailServerMail?
    private let asyncPreflight: (() async throws -> Void)?
    private let transportFence: (() throws -> Void)?
    var serverMail: GmailServerMail? { retainedServerMail ?? parent?.serverMail }
    private(set) var mayHaveReachedProvider = false

    init(serverMail: GmailServerMail? = nil, isCurrent: @escaping () -> Bool) {
        self.isCurrent = isCurrent
        parent = nil
        retainedServerMail = serverMail
        asyncPreflight = nil; transportFence = nil
    }

    /// Add a run/role lifetime without losing the initiating provider identity
    /// or the uncertain-write evidence of an enclosing operation.
    init(parent: WorkspaceProviderOperation, isCurrent: @escaping () -> Bool) {
        self.parent = parent
        self.isCurrent = isCurrent
        retainedServerMail = nil
        asyncPreflight = nil; transportFence = nil
    }

    init(parent: WorkspaceProviderOperation, beforeTransport: @escaping () async throws -> Void,
         transportFence: @escaping () throws -> Void, isCurrent: @escaping () -> Bool) {
        self.parent = parent; self.isCurrent = isCurrent; retainedServerMail = nil
        asyncPreflight = beforeTransport; self.transportFence = transportFence
    }

    private func prepareTransport() async throws {
        try await parent?.prepareTransport()
        try await asyncPreflight?()
    }

    private func checkTransportFences() throws {
        try parent?.checkTransportFences()
        try transportFence?()
    }

    /// A delayed store notification may invalidate a read permit after an
    /// awaited classifier. Retry only those read-only preflights, never a write.
    private func validateTransport() async throws {
        for attempt in 0..<2 {
            try await prepareTransport()
            try check()
            do { try checkTransportFences(); return }
            catch { if attempt == 1 { throw error } }
        }
    }

    static func capture(
        requiresWorkspace: Bool = true,
        providerIsCurrent: @escaping () -> Bool
    ) throws -> WorkspaceProviderOperation {
        let workspace: () -> Bool
        if requiresWorkspace && !GunnAireCloudKit.usesTestDatabase {
            guard let stamp = CompanyWorkspaceAccessController.shared.operationStamp else {
                throw WorkspaceProviderAccessError.unavailable
            }
            workspace = { CompanyWorkspaceAccessController.shared.operationStamp == stamp }
        } else {
            // Identity bootstrap is explicitly limited to OAuth/userinfo by
            // callers. Operational fixture bypass is compiled out of Release.
            workspace = { true }
        }
        let operation = WorkspaceProviderOperation { workspace() && providerIsCurrent() }
        try operation.check()
        return operation
    }

    var failure: WorkspaceProviderAccessError? {
        guard parent?.failure != nil || !isCurrent() else { return nil }
        return .changed(mayHaveReachedProvider: combinedSentRisk)
    }

    private var combinedSentRisk: Bool {
        mayHaveReachedProvider || parent?.combinedSentRisk == true
    }

    func check() throws {
        if let failure { throw failure }
        try Task.checkCancellation()
    }

    /// A backend may send to the provider on our behalf. Preserve the same
    /// uncertain-write risk even though its transport owns a separate request.
    func performExternalMutation<T>(_ body: () async throws -> T) async throws -> T {
        try check()
        try await validateTransport()
        try check()
        try checkTransportFences()
        mayHaveReachedProvider = true
        do {
            let result = try await body()
            try await validateTransport()
            try check()
            try checkTransportFences()
            return result
        } catch {
            if let failure { throw failure }
            throw error
        }
    }

    /// Payload encoding may suspend. Keep the initiating identity across that
    /// work so a replacement login cannot send the previous user's records.
    func prepareAndPerformExternalMutation<Prepared, T>(
        prepare: () async throws -> Prepared,
        perform: (Prepared) async throws -> T
    ) async throws -> T {
        try check()
        let prepared = try await prepare()
        try check()
        return try await performExternalMutation { try await perform(prepared) }
    }

    func data(
        for request: URLRequest,
        transport: Transport = { try await URLSession.shared.data(for: $0) }
    ) async throws -> (Data, URLResponse) {
        try check()
        try await validateTransport()
        try check()
        try checkTransportFences()
        if !["GET", "HEAD", "OPTIONS"].contains((request.httpMethod ?? "GET").uppercased()) {
            mayHaveReachedProvider = true
        }
        do {
            let result = try await transport(request)
            try await validateTransport()
            try check()
            try checkTransportFences()
            return result
        } catch {
            // An old authorization failure must not clear a new connection's
            // credentials. Prefer the changed-context outcome to provider data.
            if let failure { throw failure }
            throw error
        }
    }

    func send(
        _ request: URLRequest,
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) },
        completion: @escaping (Data?, URLResponse?, Error?) -> Void
    ) {
        Task { @MainActor in
            do {
                let (data, response) = try await self.data(for: request, transport: transport)
                completion(data, response, nil)
            } catch {
                completion(nil, nil, error)
            }
        }
    }
}
