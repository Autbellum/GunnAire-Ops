import Foundation

/// Raw, unfinished input is durable but is never a valid submission by itself.
struct StaffInvoiceDraft: Codable, Equatable {
    var origin: StaffInvoiceOrigin
    let commandID: String
    let newItemID: String
    var mode = "new"
    var catalog: StaffInvoiceLine?
    var name = ""
    var detail = ""
    var sku = ""
    var price = ""
    var quantity = "1"
    var reason = ""
    var itemType = "Service"
    var isTaxable = false
    var equipmentID: String?

    func validate() throws {
        try origin.validate()
        guard CloudKitStaffSetupPolicy.canonicalID(commandID), CloudKitStaffSetupPolicy.canonicalID(newItemID),
              ["new", "catalog"].contains(mode), ["Service", "NonInventory"].contains(itemType),
              equipmentID == nil || CloudKitStaffSetupPolicy.canonicalID(equipmentID!),
              [name, detail, sku, price, quantity, reason].allSatisfy({ StaffInvoiceLine.text($0, maximum: 8192, normalized: false) }) else {
            throw StaffReplicaDeliveryError.storage
        }
        if let catalog { try catalog.validate(); guard catalog.kind == "catalog" else { throw StaffReplicaDeliveryError.storage } }
    }
    func request() throws -> StaffInvoiceRequest {
        try validate()
        func clean(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        func optional(_ text: String) -> String? { let value = clean(text); return value.isEmpty ? nil : value }
        guard let quantity = Double(clean(quantity)) else { throw StaffReplicaDeliveryError.invalid }
        var line: StaffInvoiceLine
        if mode == "catalog" {
            guard let catalog else { throw StaffReplicaDeliveryError.invalid }
            line = catalog; line.quantity = quantity; line.equipmentID = equipmentID
        } else {
            guard let price = Double(clean(price)) else { throw StaffReplicaDeliveryError.invalid }
            line = .init(kind: "new", itemID: newItemID, itemRevision: 0, itemType: itemType, name: clean(name),
                         description: optional(detail), sku: optional(sku), unitPrice: price, quantity: quantity,
                         isTaxable: isTaxable, equipmentID: equipmentID)
        }
        let result = StaffInvoiceRequest(origin: origin, commandID: commandID, line: line, reason: clean(reason))
        try result.validate(); return result
    }
}

struct StaffInvoiceJournal: Codable, Equatable {
    struct Entry: Codable, Equatable, Identifiable {
        var id: String { request.commandID }
        let request: StaffInvoiceRequest
        var receipt: StaffInvoiceReceipt?
    }
    var version = 1
    let scope: CloudKitStaffSetupScope
    let planID: UUID
    let replicaID: String
    let invoiceID: String
    var revision = 0
    var draft: StaffInvoiceDraft?
    var entries: [Entry] = []
    var pending: [Entry] { entries.filter { $0.receipt == nil } }
    func validate(scope: CloudKitStaffSetupScope, plan: UUID, replica: String, invoice: String) throws {
        guard version == 1, self.scope == scope, planID == plan, replicaID == replica, invoiceID == invoice,
              (0..<Int.max - 1).contains(revision), entries.count <= 128,
              Set(entries.map(\.id)).count == entries.count, CloudKitStaffSetupPolicy.canonicalID(replica),
              CloudKitStaffSetupPolicy.canonicalID(invoice) else { throw StaffReplicaDeliveryError.storage }
        func bound(_ origin: StaffInvoiceOrigin) throws {
            try origin.validate()
            guard origin.companyID == scope.company.uuidString.lowercased(), origin.environment == scope.environment,
                  origin.replicaID == replica, origin.invoiceID == invoice else { throw StaffReplicaDeliveryError.storage }
        }
        if let draft {
            try draft.validate(); try bound(draft.origin)
            guard !entries.contains(where: { $0.id == draft.commandID }) else { throw StaffReplicaDeliveryError.storage }
        }
        for entry in entries {
            try entry.request.validate(); try bound(entry.request.origin)
            try entry.receipt?.validate(request: entry.request, email: scope.email, plan: plan)
        }
    }
}

/// Primary per-invoice journal: draft, queue and complete receipts share one atomic write.
/// No secondary discovery index, mutable projection, automatic rebase or silent eviction.
enum StaffInvoiceJournalStore {
    static let maximum = 8 * 1024 * 1024
    static func key(scope: CloudKitStaffSetupScope, plan: UUID, invoice: String) -> String {
        "staff-invoice-journal-v1\n" + scope.key + "\n" + plan.uuidString.lowercased() + "\n" + invoice
    }
    static func load(store: SharedTimeLocalStore, scope: CloudKitStaffSetupScope, plan: UUID, replica: String, invoice: String) throws -> StaffInvoiceJournal? {
        guard let bytes = try store.read(key(scope: scope, plan: plan, invoice: invoice)) else { return nil }
        let result = try StaffWorkspacePublicationContract.decode(StaffInvoiceJournal.self, from: bytes, maximum: maximum)
        try result.validate(scope: scope, plan: plan, replica: replica, invoice: invoice)
        return result
    }
    static func write(store: SharedTimeLocalStore, next: StaffInvoiceJournal, expected: StaffInvoiceJournal?, check: () throws -> Void) throws {
        let key = key(scope: next.scope, plan: next.planID, invoice: next.invoiceID)
        let lock = try SharedTimeMutationGate.begin(key)
        defer { SharedTimeMutationGate.finish(key, id: lock) }
        try check(); try next.validate(scope: next.scope, plan: next.planID, replica: next.replicaID, invoice: next.invoiceID)
        let previous = try load(store: store, scope: next.scope, plan: next.planID, replica: next.replicaID, invoice: next.invoiceID)
        if previous == next { try check(); return } // The write succeeded but its acknowledgment was lost.
        guard previous == expected, next.revision == (previous.map { $0.revision + 1 } ?? 0) else { throw StaffReplicaDeliveryError.changed }
        if let previous {
            guard next.entries.count >= previous.entries.count else { throw StaffReplicaDeliveryError.changed }
            for (old, new) in zip(previous.entries, next.entries) {
                guard old.request == new.request, old.receipt == nil || old.receipt == new.receipt else { throw StaffReplicaDeliveryError.changed }
            }
        }
        let bytes = try StaffWorkspacePublicationContract.encode(next)
        guard bytes.count <= maximum else { throw StaffReplicaDeliveryError.storage }
        try check(); try store.write(key, bytes); try check()
        guard try load(store: store, scope: next.scope, plan: next.planID, replica: next.replicaID, invoice: next.invoiceID) == next else {
            throw StaffReplicaDeliveryError.storage
        }
    }
}
