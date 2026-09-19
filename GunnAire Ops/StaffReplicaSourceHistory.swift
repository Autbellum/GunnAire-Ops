import Foundation
import SwiftData

/// A token is meaningful only in the explicitly registered SQLite store. The
/// journal commits this token together with the captured facts and deletions.
nonisolated struct StaffReplicaSourceCapture: Codable, Equatable {
    let source: StaffReplicaCoreSource
    let token: Data?
    let deletions: Set<String>
}

enum StaffReplicaSourceHistory {
    /// Synchronous capture on the main actor. The unsaved-changes fence is
    /// checked before and after, so a capture never describes a store that
    /// the main context is still editing.
    static func capture(container: ModelContainer, after tokenData: Data?, storeUUID: String) throws -> StaffReplicaSourceCapture {
        do {
            try requireSaved(container)
            let capture = try captureVerified(container: container, after: tokenData, storeUUID: storeUUID)
            try requireSaved(container)
            return capture
        }
        catch let error as StaffReplicaSourceError { throw error }
        catch { throw StaffReplicaSourceSyncError.history }
    }

    /// The same capture with the history and record fetches on a background
    /// task. The source pass runs this every minute; on the owner's iPad the
    /// synchronous form held the main thread for about a second each time,
    /// on whichever screen was open. Both fences stay on the main actor, and
    /// the history boundary check inside `captureVerified` still catches a
    /// save that lands while the fetches run.
    static func captureOffMain(container: ModelContainer, after tokenData: Data?, storeUUID: String) async throws -> StaffReplicaSourceCapture {
        try requireSaved(container)
        let capture: StaffReplicaSourceCapture
        do {
            capture = try await Task.detached(priority: .utility) {
                try captureVerified(container: container, after: tokenData, storeUUID: storeUUID)
            }.value
        }
        catch let error as StaffReplicaSourceError { throw error }
        catch { throw StaffReplicaSourceSyncError.history }
        try requireSaved(container)
        return capture
    }

    private static func requireSaved(_ container: ModelContainer) throws {
        guard !container.mainContext.hasChanges else { throw StaffReplicaSourceError.unsaved }
    }

    /// Reads history and the six core tables on its own context. Safe on any
    /// thread; never touches the main context.
    nonisolated private static func captureVerified(container: ModelContainer, after tokenData: Data?, storeUUID: String) throws -> StaffReplicaSourceCapture {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var descriptor = HistoryDescriptor<DefaultHistoryTransaction>()
        if let tokenData {
            let token = try JSONDecoder().decode(DefaultHistoryToken.self, from: tokenData)
            descriptor.predicate = #Predicate { $0.token > token }
        }
        // Do not silently truncate a large history or advance past unprocessed
        // transactions. Expired history remains an explicit recovery failure.
        descriptor.fetchLimit = 100_001
        let history = try context.fetchHistory(descriptor)
        guard history.count <= 100_000,
              history.allSatisfy({ $0.storeIdentifier.caseInsensitiveCompare(storeUUID) == .orderedSame }) else {
            throw StaffReplicaSourceSyncError.history
        }
        var deletions = Set<String>()
        for transaction in history {
            for change in transaction.changes {
                guard case .delete(let deletion) = change else { continue }
                let value: (String, UUID?)?
                switch deletion {
                case let deleted as DefaultHistoryDelete<Customer>: value = ("customer", deleted.tombstone[\Customer.id] as? UUID)
                case let deleted as DefaultHistoryDelete<CustomerServiceLocation>: value = ("location", deleted.tombstone[\CustomerServiceLocation.id] as? UUID)
                case let deleted as DefaultHistoryDelete<CustomerEquipment>: value = ("equipment", deleted.tombstone[\CustomerEquipment.id] as? UUID)
                case let deleted as DefaultHistoryDelete<Technician>: value = ("technician", deleted.tombstone[\Technician.id] as? UUID)
                case let deleted as DefaultHistoryDelete<ServiceCall>: value = ("job", deleted.tombstone[\ServiceCall.id] as? UUID)
                case let deleted as DefaultHistoryDelete<Item>: value = ("item", deleted.tombstone[\Item.id] as? UUID)
                default: value = nil
                }
                if let (kind, id) = value {
                    guard let id else { throw StaffReplicaSourceSyncError.history }
                    deletions.insert(kind + ":" + id.uuidString.lowercased())
                }
            }
        }
        let source = try StaffReplicaCoreSource.capture(customers: context.fetch(FetchDescriptor<Customer>()),
            locations: context.fetch(FetchDescriptor<CustomerServiceLocation>()), equipment: context.fetch(FetchDescriptor<CustomerEquipment>()),
            technicians: context.fetch(FetchDescriptor<Technician>()), jobs: context.fetch(FetchDescriptor<ServiceCall>()), items: context.fetch(FetchDescriptor<Item>()))
        let boundary = history.last?.token
        var newer = HistoryDescriptor<DefaultHistoryTransaction>()
        if let boundary { newer.predicate = #Predicate { $0.token > boundary } }
        else if let tokenData {
            let token = try JSONDecoder().decode(DefaultHistoryToken.self, from: tokenData)
            newer.predicate = #Predicate { $0.token > token }
        }
        newer.fetchLimit = 1
        guard try context.fetchHistory(newer).isEmpty else {
            throw StaffReplicaSourceError.unsaved
        }
        // A subsequently re-created model is a live fact, not an instruction to
        // delete it. A server tombstone still requires explicit restore review.
        deletions.subtract(source.records.map(\.key))
        return .init(source: source, token: try boundary.map { try JSONEncoder().encode($0) } ?? tokenData, deletions: deletions)
    }
}
