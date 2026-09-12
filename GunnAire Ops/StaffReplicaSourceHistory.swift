import Foundation
import SwiftData

/// A token is meaningful only in the explicitly registered SQLite store. The
/// journal commits this token together with the captured facts and deletions.
struct StaffReplicaSourceCapture: Codable, Equatable {
    let source: StaffReplicaCoreSource
    let token: Data?
    let deletions: Set<String>
}

enum StaffReplicaSourceHistory {
    static func capture(container: ModelContainer, after tokenData: Data?, storeUUID: String) throws -> StaffReplicaSourceCapture {
        do { return try captureVerified(container: container, after: tokenData, storeUUID: storeUUID) }
        catch let error as StaffReplicaSourceError { throw error }
        catch { throw StaffReplicaSourceSyncError.history }
    }
    private static func captureVerified(container: ModelContainer, after tokenData: Data?, storeUUID: String) throws -> StaffReplicaSourceCapture {
        guard !container.mainContext.hasChanges else { throw StaffReplicaSourceError.unsaved }
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
        guard try context.fetchHistory(newer).isEmpty, !container.mainContext.hasChanges else {
            throw StaffReplicaSourceError.unsaved
        }
        // A subsequently re-created model is a live fact, not an instruction to
        // delete it. A server tombstone still requires explicit restore review.
        deletions.subtract(source.records.map(\.key))
        return .init(source: source, token: try boundary.map { try JSONEncoder().encode($0) } ?? tokenData, deletions: deletions)
    }
}
