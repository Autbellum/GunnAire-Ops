import Foundation
import SwiftData

/// Owner-local full-model history, deliberately separate from core-field-v1.
/// A cursor cannot migrate to another store or silently gain model coverage.
nonisolated struct StaffWorkspaceHistoryCursor: Codable, Equatable {
    let version: Int
    let storeUUID: String
    let coverage: [String]
    let transactionID: Int64
    let token: Data

    func validate(storeUUID expected: String) throws -> DefaultHistoryToken {
        guard version == 1, storeUUID == expected.lowercased(),
              coverage == StaffWorkspaceModelCatalog.all.map(\.kind).sorted(),
              transactionID > 0, !token.isEmpty, token.count <= 64 * 1024 else {
            throw StaffReplicaSourceSyncError.history
        }
        return try JSONDecoder().decode(DefaultHistoryToken.self, from: token)
    }
}

nonisolated struct StaffWorkspaceHistoryCapture: Codable, Equatable {
    let records: [StaffWorkspaceModelRecord]
    let cursor: StaffWorkspaceHistoryCursor?
    let deletions: Set<String>
}

@MainActor enum StaffWorkspaceHistory {
    nonisolated static func key(_ record: StaffWorkspaceModelRecord) -> String { record.kind + ":" + record.id.uuidString.lowercased() }

    nonisolated static func verifyStore(_ container: ModelContainer, storeUUID: String) throws {
        // Checking transaction store IDs alone is vacuously true for an empty
        // history. Verify the actual single on-disk store on both sides too.
        guard container.configurations.count == 1, let configuration = container.configurations.first,
              !configuration.isStoredInMemoryOnly, UUID(uuidString: storeUUID) != nil,
              try CompanyWorkspaceStore.identity(at: configuration.url)?.lowercased() == storeUUID.lowercased() else {
            throw StaffReplicaSourceSyncError.history
        }
        try StaffWorkspaceModelCatalog.validateSchema(container.schema)
        guard container.schema.entities.allSatisfy({ $0.attributesByName["id"]?.options.contains(.preserveValueOnDeletion) == true }) else {
            throw StaffReplicaSourceSyncError.history
        }
    }

    nonisolated static func readSavedRecords(_ context: ModelContext) throws -> [StaffWorkspaceModelRecord] {
        var records: [StaffWorkspaceModelRecord] = [], bytes = 2
        for codec in StaffWorkspaceModelCatalog.all {
            let next = try codec.readSavedRecords(context)
            bytes += try JSONEncoder().encode(next).count
            guard records.count + next.count <= 20_000, bytes <= 32 * 1024 * 1024 else {
                throw StaffReplicaSourceSyncError.history
            }
            records += next
        }
        return records.sorted { key($0) < key($1) }
    }

    nonisolated private static func verifyAnchor(_ cursor: StaffWorkspaceHistoryCursor, in context: ModelContext, storeUUID: String) throws -> DefaultHistoryToken {
        let token = try cursor.validate(storeUUID: storeUUID), identifier = cursor.transactionID
        var descriptor = HistoryDescriptor<DefaultHistoryTransaction>()
        descriptor.predicate = #Predicate { $0.transactionIdentifier == identifier }
        descriptor.fetchLimit = 2
        let anchors = try context.fetchHistory(descriptor)
        guard anchors.count == 1, let anchor = anchors.first, anchor.token == token,
              anchor.storeIdentifier.lowercased() == storeUUID.lowercased() else {
            throw StaffReplicaSourceSyncError.history
        }
        return token
    }

    /// Synchronous capture on the main actor: the unsaved-changes fence is
    /// checked before and after the body.
    static func capture(container: ModelContainer, after cursor: StaffWorkspaceHistoryCursor?, storeUUID: String,
                        read: (ModelContext) throws -> [StaffWorkspaceModelRecord] = readSavedRecords) throws -> StaffWorkspaceHistoryCapture {
        try requireSaved(container)
        let capture = try captureBody(container: container, after: cursor, storeUUID: storeUUID, read: read)
        try requireSaved(container)
        return capture
    }

    /// The same capture with the history and the 32 model reads on a
    /// background task. The owner-workspace staging runs this every minute
    /// (twice: once to prepare, once as the fence); the synchronous form held
    /// the main thread for about a second each pass on the owner's iPad.
    static func captureOffMain(container: ModelContainer, after cursor: StaffWorkspaceHistoryCursor?, storeUUID: String) async throws -> StaffWorkspaceHistoryCapture {
        try requireSaved(container)
        let capture = try await Task.detached(priority: .utility) {
            try captureBody(container: container, after: cursor, storeUUID: storeUUID, read: readSavedRecords)
        }.value
        try requireSaved(container)
        return capture
    }

    private static func requireSaved(_ container: ModelContainer) throws {
        guard !container.mainContext.hasChanges else { throw StaffReplicaSourceError.unsaved }
    }

    /// Reads on its own context; never touches the main context. The history
    /// boundary check at the end still catches a save that lands mid-read.
    /// The body without the main-context fences, for callers that hold those
    /// fences themselves on the main actor around a background read.
    nonisolated static func captureBodyForStaging(container: ModelContainer, after cursor: StaffWorkspaceHistoryCursor?, storeUUID: String) throws -> StaffWorkspaceHistoryCapture {
        try captureBody(container: container, after: cursor, storeUUID: storeUUID, read: readSavedRecords)
    }

    nonisolated private static func captureBody(container: ModelContainer, after cursor: StaffWorkspaceHistoryCursor?, storeUUID: String,
                                                read: (ModelContext) throws -> [StaffWorkspaceModelRecord]) throws -> StaffWorkspaceHistoryCapture {
        do {
            try verifyStore(container, storeUUID: storeUUID)
            let context = ModelContext(container); context.autosaveEnabled = false
            let previous = try cursor.map { try verifyAnchor($0, in: context, storeUUID: storeUUID) }
            var descriptor = HistoryDescriptor<DefaultHistoryTransaction>()
            if let previous { descriptor.predicate = #Predicate { $0.token > previous } }
            descriptor.fetchLimit = 100_001
            let history = try context.fetchHistory(descriptor)
            guard history.count <= 100_000 else { throw StaffReplicaSourceSyncError.history }
            var lastID = cursor?.transactionID ?? 0, lastToken = previous, deletions = Set<String>()
            let codecs = StaffWorkspaceModelCatalog.all
            for transaction in history {
                guard transaction.storeIdentifier.lowercased() == storeUUID.lowercased(),
                      transaction.transactionIdentifier > lastID,
                      lastToken.map({ transaction.token > $0 }) ?? true else { throw StaffReplicaSourceSyncError.history }
                lastID = transaction.transactionIdentifier; lastToken = transaction.token
                for change in transaction.changes {
                    guard case .delete(let deletion) = change else { continue }
                    var matched = false
                    for codec in codecs {
                        if let id = try codec.deletedID(deletion) {
                            guard !matched else { throw StaffReplicaSourceSyncError.history }
                            matched = true; deletions.insert(codec.kind + ":" + id.uuidString.lowercased())
                        }
                    }
                    guard matched, deletions.count <= 100_000 else { throw StaffReplicaSourceSyncError.history }
                }
            }
            let records = try read(context)
            _ = try StaffWorkspaceRelationshipGraph.validate(records)
            // A writer in another context/process may save during these 32
            // fetches. Never stamp a mixed snapshot with a newer history token.
            var newer = HistoryDescriptor<DefaultHistoryTransaction>()
            if let lastToken { newer.predicate = #Predicate { $0.token > lastToken } }
            newer.fetchLimit = 1
            guard try context.fetchHistory(newer).isEmpty, !context.hasChanges else {
                throw StaffReplicaSourceError.unsaved
            }
            let next = try history.last.map {
                StaffWorkspaceHistoryCursor(version: 1, storeUUID: storeUUID.lowercased(), coverage: codecs.map(\.kind).sorted(),
                                            transactionID: $0.transactionIdentifier, token: try JSONEncoder().encode($0.token))
            } ?? cursor
            if let next { _ = try verifyAnchor(next, in: context, storeUUID: storeUUID) }
            try verifyStore(container, storeUUID: storeUUID)
            deletions.subtract(records.map(key))
            return .init(records: records.sorted { key($0) < key($1) }, cursor: next, deletions: deletions)
        } catch let error as StaffReplicaSourceError { throw error }
        catch { throw StaffReplicaSourceSyncError.history }
    }
}
