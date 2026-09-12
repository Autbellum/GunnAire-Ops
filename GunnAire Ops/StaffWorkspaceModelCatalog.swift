import Foundation
import SwiftData

/// A closed, versioned owner-domain catalog, not a network payload or staff
/// membership grant. All 32 models must be represented before a full snapshot
/// can be considered. Role projection and scalar-link lineage are separate gates.
@MainActor struct StaffWorkspaceAnyModelCodec {
    let kind: String
    let modelName: String
    let modelType: any PersistentModel.Type
    let attributes: Set<String>
    let relationships: Set<String>
    let excludedAttributes: [String: String]
    let fields: Set<String>
    let fieldSchema: [String: StaffWorkspaceFieldSchema]
    let references: [String: String]
    let validate: (StaffWorkspaceModelRecord) throws -> Void
    let encode: (any PersistentModel) throws -> StaffWorkspaceModelRecord
    let readSavedRecords: (ModelContext) throws -> [StaffWorkspaceModelRecord]
    let deletedID: (any HistoryDelete) throws -> UUID?
    let decode: (StaffWorkspaceModelRecord, inout StaffWorkspaceModelResolver) throws -> any PersistentModel
    let scalarTarget: (ModelContext, UUID, String) throws -> StaffOwnerFieldEditTarget

    init<M>(_ codec: StaffWorkspaceModelCodec<M>) {
        kind = codec.kind
        modelName = String(describing: M.self)
        modelType = M.self
        let owning = codec.fields.filter { $0.referenceKind != nil }
        references = Dictionary(uniqueKeysWithValues: owning.map { ($0.name, $0.referenceKind!) })
        fields = codec.fieldNames
        fieldSchema = Dictionary(uniqueKeysWithValues: codec.fields.map { ($0.name, $0.schema) })
        attributes = codec.fieldNames.subtracting(references.keys).union(["id"]).union(codec.excludedAttributes.keys)
        relationships = Set(references.keys).union(codec.inverseRelationships)
        excludedAttributes = codec.excludedAttributes
        validate = codec.validate
        encode = { model in
            guard let typed = model as? M else { throw StaffWorkspaceModelError.invalid }
            return try codec.encode(typed)
        }
        readSavedRecords = { context in
            guard !context.hasChanges else { throw StaffWorkspaceModelError.invalid }
            var descriptor = FetchDescriptor<M>()
            descriptor.fetchLimit = 20_001
            let models = try context.fetch(descriptor)
            guard models.count <= 20_000 else { throw StaffWorkspaceModelError.invalid }
            return try models.map(codec.encode)
        }
        deletedID = { deletion in
            guard let typed = deletion as? DefaultHistoryDelete<M> else { return nil }
            // A recognized model with no retained original ID is not an empty
            // change. It needs recovery; never advance past that deletion.
            guard let id = typed.tombstone[codec.id] as? UUID else { throw StaffReplicaSourceSyncError.history }
            return id
        }
        decode = { try codec.decodeDetached($0, resolver: &$1) }
        scalarTarget = { context, id, name in
            guard let field = codec.fields.first(where: { $0.name == name }), field.referenceKind == nil else {
                throw StaffWorkspaceModelError.unsupported
            }
            var descriptor = FetchDescriptor<M>(); descriptor.fetchLimit = 20_001
            let models = try context.fetch(descriptor)
            guard models.count <= 20_000 else { throw StaffWorkspaceModelError.invalid }
            let matches = models.filter { $0[keyPath: codec.id] == id }
            guard matches.count == 1, let model = matches.first else { throw StaffOwnerFieldEditError.missing }
            let original = try codec.encode(model)
            return .init(title: StaffOwnerFieldEditModels.title(model, record: original), value: { field.read(model) }, write: { value in
                try field.validate(value)
                try field.write(model, value, StaffWorkspaceModelResolver())
            }, ownsPendingWrite: { value in
                guard codec.excludedAttributes.isEmpty,
                      context.insertedModelsArray.isEmpty, context.deletedModelsArray.isEmpty,
                      context.changedModelsArray.allSatisfy({ $0.persistentModelID == model.persistentModelID }),
                      let changed = try? codec.encode(model) else { return false }
                var expected = original.fields; expected[name] = value
                return changed.fields == expected
            })
        }
    }
}

@MainActor enum StaffWorkspaceModelCatalog {
    static var all: [StaffWorkspaceAnyModelCodec] {
        typealias C = StaffWorkspaceModelCodecs
        return [
            .init(C.customer), .init(C.location), .init(C.equipment), .init(C.technician),
            .init(C.item), .init(C.job), .init(C.invoice), .init(C.estimate), .init(C.payment),
            .init(C.user), .init(C.availability), .init(C.shift), .init(C.timeOff),
            .init(C.availabilityEvent), .init(C.timeEntry), .init(C.agreement), .init(C.request),
            .init(C.activity), .init(C.milestone), .init(C.alert), .init(C.task), .init(C.taskEvent),
            .init(C.attachment), .init(C.communication), .init(C.formTemplate), .init(C.formResponse),
            .init(C.vendor), .init(C.purchaseOrder), .init(C.movement), .init(C.vehicle),
            .init(C.vehicleEvent), .init(C.expense),
        ]
    }

    static func validateSchema(_ schema: Schema) throws {
        let codecs = all
        guard Set(codecs.map(\.kind)).count == codecs.count,
              Set(codecs.map(\.modelName)).count == codecs.count,
              Set(codecs.map(\.modelName)) == Set(schema.entities.map(\.name)) else {
            throw StaffWorkspaceModelError.unsupported
        }
        for entity in schema.entities {
            guard let codec = codecs.first(where: { $0.modelName == entity.name }),
                  codec.attributes == Set(entity.attributes.map(\.name)),
                  codec.relationships == Set(entity.relationships.map(\.name)),
                  codec.excludedAttributes.values.allSatisfy({ !$0.isEmpty }) else {
                throw StaffWorkspaceModelError.incomplete
            }
        }
    }

    /// Reconstructs an entirely new in-memory graph. Every record, kind and
    /// owning SwiftData relationship is validated before any reconstruction.
    /// Input order is irrelevant. The caller receives no active ModelContext,
    /// and this method never inserts, saves, updates or deletes existing data.
    /// Historical scalar UUID links are preserved, not assumed to grant access.
    static func decodeDetached(_ records: [StaffWorkspaceModelRecord]) throws -> [any PersistentModel] {
        guard records.count <= 20_000,
              try JSONEncoder().encode(records).count <= 32 * 1024 * 1024 else {
            throw StaffWorkspaceModelError.invalid
        }
        try validateSchema(GunnAireModelSchema.schema)
        let codecs = Dictionary(uniqueKeysWithValues: all.map { ($0.kind, $0) })
        func key(_ kind: String, _ id: UUID) -> String { kind + ":" + id.uuidString }
        let keys = Set(records.map { key($0.kind, $0.id) })
        guard keys.count == records.count else { throw StaffWorkspaceModelError.invalid }
        for record in records {
            guard let codec = codecs[record.kind] else { throw StaffWorkspaceModelError.unsupported }
            try codec.validate(record)
            for (field, kind) in codec.references {
                let value = record.fields[field]!
                if value == .null { continue } // Required-null was rejected by the codec.
                guard keys.contains(key(kind, try UUID.fromStaffValue(value))) else {
                    throw StaffWorkspaceModelError.relationships
                }
            }
        }
        var resolver = StaffWorkspaceModelResolver()
        var remaining = records.sorted { key($0.kind, $0.id) < key($1.kind, $1.id) }
        var models: [any PersistentModel] = []
        while !remaining.isEmpty {
            var deferred: [StaffWorkspaceModelRecord] = []
            let before = models.count
            for record in remaining {
                let codec = codecs[record.kind]!
                let ready = try codec.references.allSatisfy { field, kind in
                    let value = record.fields[field]!
                    if value == .null { return true }
                    return resolver.contains(kind: kind, id: try UUID.fromStaffValue(value))
                }
                if ready { models.append(try codec.decode(record, &resolver)) }
                else { deferred.append(record) }
            }
            guard models.count > before else { throw StaffWorkspaceModelError.relationships }
            remaining = deferred
        }
        return models
    }
}
