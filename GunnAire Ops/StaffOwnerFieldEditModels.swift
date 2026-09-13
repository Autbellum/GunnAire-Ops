import Foundation
import SwiftData

@MainActor struct StaffOwnerFieldEditTarget {
    let title: String
    let value: () -> StaffWorkspaceValue
    let write: (StaffWorkspaceValue) throws -> Void
    let ownsPendingWrite: (StaffWorkspaceValue) -> Bool
}

@MainActor enum StaffOwnerFieldEditModels {
    static func title(_ model: any PersistentModel, record: StaffWorkspaceModelRecord) -> String {
        if let job = model as? ServiceCall {
            return [job.customer?.name, job.type.displayName, job.scheduledDate.formatted(date: .abbreviated, time: .omitted)]
                .compactMap { $0 }.joined(separator: " · ")
        }
        for name in ["name", "number", "title", "displayName"] {
            if case .text(let text) = record.fields[name], !text.isEmpty { return String(text.prefix(200)) }
        }
        return StaffWorkspacePublicationReview.label(record.kind) + " · " + record.id.uuidString.suffix(6)
    }
    static func target(_ edit: StaffOwnerFieldEdit, context: ModelContext) throws -> StaffOwnerFieldEditTarget {
        guard let id = UUID(uuidString: edit.request.recordID),
              StaffWorkspaceOperationalCommandPolicy.isOperationsField(kind: edit.request.recordKind, field: edit.request.fieldName),
              !edit.request.fieldName.hasSuffix("JSON"),
              let codec = StaffWorkspaceModelCatalog.all.first(where: { $0.kind == edit.request.recordKind })
        else { throw StaffReplicaSourceSyncError.invalid }
        return try codec.scalarTarget(context, id, edit.request.fieldName)
    }
    static func read(_ edit: StaffOwnerFieldEdit, container: ModelContainer) throws -> StaffWorkspaceValue {
        guard !container.mainContext.hasChanges else { throw StaffOwnerFieldEditError.unsaved }
        let context = ModelContext(container); context.autosaveEnabled = false
        return try target(edit, context: context).value()
    }
    static func apply(_ edit: StaffOwnerFieldEdit, expected: StaffWorkspaceValue, container: ModelContainer,
                      check: () throws -> Void, save: ((ModelContext) throws -> Void)? = nil) throws {
        try check()
        guard !container.mainContext.hasChanges else { throw StaffOwnerFieldEditError.unsaved }
        // Read the persisted value through a fresh context; a registered office
        // object can be older than the store. Write via the clean UI context so
        // existing @Model references observe the edit without a duplicate save.
        let current = try read(edit, container: container)
        guard current == expected || current == edit.request.value else { throw StaffOwnerFieldEditError.conflict }
        let context = container.mainContext
        let field = try target(edit, context: context)
        if current == edit.request.value && field.value() == current { return }
        try check()
        guard !context.hasChanges else { throw StaffOwnerFieldEditError.unsaved }
        let oldAuthor = context.author, oldValue = field.value()
        context.author = "staff-field-edit-v1:" + edit.id
        defer { context.author = oldAuthor }
        // No suspension occurs while this otherwise-clean context is reserved.
        do {
            try field.write(edit.request.value)
            if let save { try save(context) } else { try context.save() }
        } catch {
            if context.hasChanges {
                // Roll back only when the complete pending change set is this
                // exact scalar. A save observer's unrelated draft is preserved.
                if field.ownsPendingWrite(edit.request.value) {
                    // Restore the registered accessor as well as the stored
                    // value; rollback alone can leave a stale @Model value.
                    try? field.write(oldValue)
                    context.rollback()
                }
                else if field.value() == edit.request.value { try? field.write(oldValue) }
            }
            throw error
        }
        try check()
        let verified = ModelContext(container); verified.autosaveEnabled = false
        guard try target(edit, context: verified).value() == edit.request.value else { throw StaffOwnerFieldEditError.conflict }
    }
}
