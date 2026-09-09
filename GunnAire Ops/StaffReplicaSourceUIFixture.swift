import Foundation

/// Synthetic UI-only transport. No real account, CloudKit, HTTP or model writes.
@MainActor enum StaffReplicaSourceUIFixture {
    static var isEnabled: Bool {
        #if DEBUG
        GunnAireCloudKit.usesTestDatabase && ProcessInfo.processInfo.arguments.contains("-uiTestStaffSourceSync") &&
        UUID(uuidString: ProcessInfo.processInfo.environment["GUNNAIRE_STAFF_SETUP_FIXTURE"] ?? "") != nil
        #else
        false
        #endif
    }
    static var dependencies: StaffReplicaSourceDependencies? {
        #if DEBUG
        guard isEnabled, let company = UUID(uuidString: ProcessInfo.processInfo.environment["GUNNAIRE_STAFF_SETUP_FIXTURE"] ?? "") else { return nil }
        let server = Server(company: company)
        return .init(context: { server.context }, check: { context in
            guard context.scope == server.context.scope, context.stamp == server.context.stamp else { throw StaffReplicaSourceSyncError.access }
        }, capture: { _, _ in .init(source: .init(schema: StaffReplicaCoreSource.schemaVersion, coverage: StaffReplicaCoreSource.recordKinds,
                                                  records: [server.local]), token: nil, deletions: []) },
            request: { try server.request($0, $1, $2) }, store: .init(read: { server.saved[$0] }, write: { server.saved[$0] = $1 }))
        #else
        return nil
        #endif
    }
    #if DEBUG
    private final class Server {
        let context: StaffReplicaSourceContext
        let local: StaffReplicaCoreRecord
        var remote: StaffReplicaSourceRemoteRecord
        var sequence = 1
        var saved: [String: Data] = [:]
        var receipts: [String: Data] = [:]
        init(company: UUID) {
            let binding = CompanyCloudKitBinding(companyID: company, containerID: GunnAireCloudKit.containerIdentifier,
                environment: "development", replicaID: company, cloudAccountHash: String(repeating: "a", count: 64), approvedAt: "2026-09-09T00:00:00Z")
            let session = CompanyWorkspaceSession(backendOrigin: "https://source-fixture.invalid", email: "owner@example.invalid",
                tokenFingerprint: String(repeating: "b", count: 64), expiresAt: Date().addingTimeInterval(3600))
            context = .init(scope: .init(backendOrigin: session.backendOrigin, actorEmail: session.email, binding: binding, storeUUID: company.uuidString),
                            stamp: .init(generation: UUID(), session: session))
            local = .init(kind: "customer", id: company.uuidString.lowercased(), fields: ["name": .text("Morgan residence"), "address": .text("10 Main — service entrance")])
            remote = .init(companyID: company, environment: "development", replicaID: company, kind: "customer", id: company.uuidString.lowercased(),
                           revision: 1, deleted: false, fields: ["name": .text("Morgan residence"), "address": .text("10 Main — front entrance")])
        }
        func request(_ path: String, _ method: String, _ body: Data?) throws -> Data {
            if method == "GET" {
                return try JSONEncoder().encode(StaffReplicaSourcePage(schema: StaffReplicaCoreSource.schemaVersion, companyID: context.scope.binding.companyID,
                    environment: "development", replicaID: context.scope.binding.replicaID, sequence: sequence, authorizationSequence: 1, records: [remote], nextCursor: nil))
            }
            guard let body else { throw StaffReplicaSourceSyncError.invalid }
            let batch = try JSONDecoder().decode(StaffReplicaSourceBatch.self, from: body); try batch.validate(context.scope)
            if let prior = receipts[batch.operationID] { return prior }
            guard batch.expectedSequence == sequence, batch.changes.count == 1,
                  batch.changes[0].expectedRevision == remote.revision, batch.changes[0].fields == local.fields else { throw StaffReplicaSourceSyncError.invalid }
            sequence += 1
            remote = .init(companyID: remote.companyID, environment: remote.environment, replicaID: remote.replicaID, kind: remote.kind,
                           id: remote.id, revision: remote.revision + 1, deleted: false, fields: local.fields)
            let receipt = StaffReplicaSourceReceipt(operationID: batch.operationID, companyID: remote.companyID, environment: remote.environment,
                replicaID: remote.replicaID, schema: batch.schema, sequence: sequence, currentSequence: sequence,
                changes: [.init(kind: remote.kind, id: remote.id, revision: remote.revision, deleted: false)])
            let result = try JSONEncoder().encode(receipt); receipts[batch.operationID] = result; return result
        }
    }
    #endif
}
