import Foundation
import SwiftData

/// Typed, synchronous application boundary. A caller must retain the complete
/// proposal and confirmed exclusive claim before invoking this method. It is
/// intentionally not exposed by a live button until provider/collection fencing
/// and the durable native coordinator are connected.
@MainActor enum StaffOwnerInvoiceModels {
    private static func originals(_ proposal: StaffOwnerInvoiceProposal, context: ModelContext) throws -> [String: StaffWorkspaceModelRecord] {
        let requested = Set(proposal.dependencies.map(\.key) + [proposal.expectedInvoice.key, "item:" + proposal.request.line.itemID])
        let kinds = Set(proposal.dependencies.map(\.kind) + ["invoice", "item"])
        var result: [String: StaffWorkspaceModelRecord] = [:]
        for codec in StaffWorkspaceModelCatalog.all where kinds.contains(codec.kind) {
            for record in try codec.readSavedRecords(context) {
                let key = record.kind + ":" + record.id.uuidString.lowercased()
                if requested.contains(key) {
                    guard result[key] == nil else { throw StaffOwnerInvoiceError.changed }
                    result[key] = record
                }
            }
        }
        return result
    }
    static func verify(_ proposal: StaffOwnerInvoiceProposal, scope: StaffReplicaSourceScope, container: ModelContainer,
                       allowApplied: Bool) throws -> Bool {
        try proposal.validate(scope)
        guard !container.mainContext.hasChanges else { throw StaffOwnerFieldEditError.unsaved }
        let context = ModelContext(container); context.autosaveEnabled = false
        let records = try originals(proposal, context: context)
        for dependency in proposal.dependencies {
            guard records[dependency.key]?.fields == dependency.fields else { throw StaffOwnerInvoiceError.changed }
        }
        guard let invoice = records[proposal.expectedInvoice.key] else { throw StaffOwnerInvoiceError.missing }
        let saved = invoice.fields == proposal.invoiceFields
        guard invoice.fields == proposal.expectedInvoice.fields || (allowApplied && saved) else { throw StaffOwnerInvoiceError.changed }
        var itemSaved = true
        if let fields = proposal.newItemFields {
            let item = records["item:" + proposal.request.line.itemID]
            itemSaved = item?.fields == fields
            guard item == nil || (allowApplied && itemSaved) else { throw StaffOwnerInvoiceError.changed }
        }
        return saved && itemSaved
    }
    static func apply(_ proposal: StaffOwnerInvoiceProposal, application: StaffOwnerInvoiceApplication,
                      scope: StaffReplicaSourceScope, container: ModelContainer, check: () throws -> Void,
                      save: ((ModelContext) throws -> Void)? = nil) throws {
        try check(); try application.validate(proposal, scope: scope)
        guard application.state == "prepared" else { throw StaffOwnerInvoiceError.changed }
        if try verify(proposal, scope: scope, container: container, allowApplied: true) { return }
        let context = container.mainContext
        let id = UUID(uuidString: proposal.expectedInvoice.id)!
        var descriptor = FetchDescriptor<Invoice>(predicate: #Predicate { $0.id == id }); descriptor.fetchLimit = 2
        let invoices = try context.fetch(descriptor)
        guard invoices.count == 1, let invoice = invoices.first else { throw StaffOwnerInvoiceError.missing }
        let codec = StaffWorkspaceModelCodecs.invoice
        let original = try codec.encode(invoice)
        guard original.fields == proposal.expectedInvoice.fields || original.fields == proposal.invoiceFields else { throw StaffOwnerInvoiceError.changed }
        let fields = codec.fields.filter { StaffOwnerInvoiceProposal.changedFields.contains($0.name) }
        guard Set(fields.map(\.name)) == StaffOwnerInvoiceProposal.changedFields, fields.allSatisfy({ $0.referenceKind == nil }) else { throw StaffReplicaSourceSyncError.invalid }
        var inserted: Item?
        if let proposed = proposal.newItemFields {
            let itemID = UUID(uuidString: proposal.request.line.itemID)!
            var query = FetchDescriptor<Item>(predicate: #Predicate { $0.id == itemID }); query.fetchLimit = 2
            let found = try context.fetch(query)
            guard found.count <= 1 else { throw StaffOwnerInvoiceError.changed }
            if let existing = found.first {
                guard try StaffWorkspaceModelCodecs.item.encode(existing).fields == proposed else { throw StaffOwnerInvoiceError.changed }
            } else {
                var resolver = StaffWorkspaceModelResolver()
                inserted = try StaffWorkspaceModelCodecs.item.decodeDetached(.init(version: 1, kind: "item", id: itemID, fields: proposed), resolver: &resolver)
            }
        }
        try check()
        guard !context.hasChanges else { throw StaffOwnerFieldEditError.unsaved }
        // The authority callback must not make an intervening committed edit
        // invisible to this transaction. Check the persisted and registered
        // preimages again immediately before changing any scalar.
        if try verify(proposal, scope: scope, container: container, allowApplied: true) { return }
        guard try codec.encode(invoice).fields == original.fields else { throw StaffOwnerInvoiceError.changed }
        let oldAuthor = context.author
        context.author = "staff-invoice-application-v1:" + proposal.commandID
        defer { context.author = oldAuthor }
        do {
            if let inserted { context.insert(inserted) }
            for field in fields { try field.write(invoice, proposal.invoiceFields[field.name]!, StaffWorkspaceModelResolver()) }
            if let save { try save(context) } else { try context.save() }
        } catch {
            if context.hasChanges {
                let allowed = Set([invoice.persistentModelID] + (inserted.map { [$0.persistentModelID] } ?? []))
                let onlyThisWrite = context.deletedModelsArray.isEmpty
                    && context.changedModelsArray.allSatisfy { allowed.contains($0.persistentModelID) }
                    && context.insertedModelsArray.allSatisfy { $0.persistentModelID == inserted?.persistentModelID }
                    && (try? codec.encode(invoice).fields) == proposal.invoiceFields
                    && (inserted == nil || (try? inserted.map { try StaffWorkspaceModelCodecs.item.encode($0).fields }) == proposal.newItemFields)
                if onlyThisWrite {
                    // SwiftData can retain a changed @Model accessor after
                    // rollback. Restore registered values before discarding
                    // this transaction, so the UI and store both retain the
                    // original invoice without a second save.
                    for field in fields { try? field.write(invoice, original.fields[field.name]!, StaffWorkspaceModelResolver()) }
                    context.rollback()
                }
                else {
                    // Preserve any save observer's unrelated edits. Restore only
                    // our exact scalar values, never roll back the user's draft.
                    for field in fields where field.read(invoice) == proposal.invoiceFields[field.name] {
                        try? field.write(invoice, original.fields[field.name]!, StaffWorkspaceModelResolver())
                    }
                }
            }
            throw error
        }
        try check()
        guard try verify(proposal, scope: scope, container: container, allowApplied: true) else { throw StaffOwnerInvoiceError.changed }
    }
}
