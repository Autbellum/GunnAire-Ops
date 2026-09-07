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
    private(set) var mayHaveReachedProvider = false

    init(isCurrent: @escaping () -> Bool) {
        self.isCurrent = isCurrent
        parent = nil
    }

    /// Add a run/role lifetime without losing the initiating provider identity
    /// or the uncertain-write evidence of an enclosing operation.
    init(parent: WorkspaceProviderOperation, isCurrent: @escaping () -> Bool) {
        self.parent = parent
        self.isCurrent = isCurrent
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
        mayHaveReachedProvider = true
        do {
            let result = try await body()
            try check()
            return result
        } catch {
            if let failure { throw failure }
            throw error
        }
    }

    func data(
        for request: URLRequest,
        transport: Transport = { try await URLSession.shared.data(for: $0) }
    ) async throws -> (Data, URLResponse) {
        try check()
        if !["GET", "HEAD", "OPTIONS"].contains((request.httpMethod ?? "GET").uppercased()) {
            mayHaveReachedProvider = true
        }
        do {
            let result = try await transport(request)
            try check()
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
