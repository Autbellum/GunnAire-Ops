import Foundation
import SwiftData

/// Lossless model-transfer primitives, not a server grant or a workspace lease.
/// These records must pass the full domain/role projection before distribution.
/// No generic model dump, KVC, reflection or unknown-field fallback is permitted.
enum StaffWorkspaceValue: Codable, Equatable {
    case text(String), number(Double), integer(Int), flag(Bool), date(Date), identifier(UUID), null
}

enum StaffWorkspaceModelError: Error, Equatable {
    case invalid, incomplete, relationships, unsupported
}

enum StaffWorkspaceWireType: String, Codable {
    case text, number, integer, flag, date, identifier
}

struct StaffWorkspaceFieldSchema: Codable, Equatable {
    let type: StaffWorkspaceWireType
    let nullable: Bool
    let reference: String?
    let enumeration: [String]?

    func validateScalar(_ value: StaffWorkspaceValue) throws {
        guard reference == nil else { throw StaffWorkspaceModelError.relationships }
        if value == .null {
            guard nullable else { throw StaffWorkspaceModelError.invalid }
            return
        }
        switch type {
        case .text:
            let text = try String.fromStaffValue(value)
            guard enumeration?.contains(text) ?? true else { throw StaffWorkspaceModelError.invalid }
        case .number: _ = try Double.fromStaffValue(value)
        case .integer: _ = try Int.fromStaffValue(value)
        case .flag: _ = try Bool.fromStaffValue(value)
        case .date: _ = try Date.fromStaffValue(value)
        case .identifier: _ = try UUID.fromStaffValue(value)
        }
    }
}

struct StaffWorkspaceModelRecord: Codable, Equatable {
    let version: Int
    let kind: String
    let id: UUID
    let fields: [String: StaffWorkspaceValue]

    static func decode(_ bytes: Data) throws -> [Self] {
        guard bytes.count <= 32 * 1024 * 1024 else { throw StaffWorkspaceModelError.invalid }
        let values = try JSONDecoder().decode([Self].self, from: bytes)
        guard values.count <= 20_000 else { throw StaffWorkspaceModelError.invalid }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // Codable alone ignores unknown keys. Compare JSON structures so no
        // unknown envelope or tagged-value member can disappear on decoding.
        let original = try JSONSerialization.jsonObject(with: bytes)
        let encoded = try JSONSerialization.jsonObject(with: encoder.encode(values))
        guard try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys]) ==
                JSONSerialization.data(withJSONObject: encoded, options: [.sortedKeys]) else { throw StaffWorkspaceModelError.invalid }
        let keys = values.map { $0.kind + ":" + $0.id.uuidString }
        guard Set(keys).count == keys.count else { throw StaffWorkspaceModelError.invalid }
        return values
    }
}

@MainActor protocol StaffWorkspaceAtom {
    static var wireType: StaffWorkspaceWireType { get }
    var staffValue: StaffWorkspaceValue { get }
    static func fromStaffValue(_ value: StaffWorkspaceValue) throws -> Self
}
extension String: StaffWorkspaceAtom {
    static var wireType: StaffWorkspaceWireType { .text }
    var staffValue: StaffWorkspaceValue { .text(self) }
    static func fromStaffValue(_ value: StaffWorkspaceValue) throws -> Self {
        guard case .text(let result) = value, result.utf8.count <= 1_048_576,
              !result.unicodeScalars.contains(where: { $0.value == 0 }) else { throw StaffWorkspaceModelError.invalid }
        return result
    }
}
extension Double: StaffWorkspaceAtom {
    static var wireType: StaffWorkspaceWireType { .number }
    var staffValue: StaffWorkspaceValue { .number(self) }
    static func fromStaffValue(_ value: StaffWorkspaceValue) throws -> Self {
        guard case .number(let result) = value, result.isFinite, abs(result) <= 1_000_000_000_000 else { throw StaffWorkspaceModelError.invalid }
        return result
    }
}
extension Int: StaffWorkspaceAtom {
    static var wireType: StaffWorkspaceWireType { .integer }
    var staffValue: StaffWorkspaceValue { .integer(self) }
    static func fromStaffValue(_ value: StaffWorkspaceValue) throws -> Self {
        guard case .integer(let result) = value, (-2_147_483_647...2_147_483_647).contains(result) else { throw StaffWorkspaceModelError.invalid }
        return result
    }
}
extension Bool: StaffWorkspaceAtom {
    static var wireType: StaffWorkspaceWireType { .flag }
    var staffValue: StaffWorkspaceValue { .flag(self) }
    static func fromStaffValue(_ value: StaffWorkspaceValue) throws -> Self {
        guard case .flag(let result) = value else { throw StaffWorkspaceModelError.invalid }; return result
    }
}
extension Date: StaffWorkspaceAtom {
    static var wireType: StaffWorkspaceWireType { .date }
    var staffValue: StaffWorkspaceValue { .date(self) }
    static func fromStaffValue(_ value: StaffWorkspaceValue) throws -> Self {
        guard case .date(let result) = value, result.timeIntervalSinceReferenceDate.isFinite,
              abs(result.timeIntervalSinceReferenceDate) <= 100_000_000_000 else { throw StaffWorkspaceModelError.invalid }; return result
    }
}
extension UUID: StaffWorkspaceAtom {
    static var wireType: StaffWorkspaceWireType { .identifier }
    var staffValue: StaffWorkspaceValue { .identifier(self) }
    static func fromStaffValue(_ value: StaffWorkspaceValue) throws -> Self {
        guard case .identifier(let result) = value else { throw StaffWorkspaceModelError.invalid }; return result
    }
}

/// Resolver contains only the new detached graph, never objects fetched from
/// an existing owner or staff store. Duplicate identity is an error, not a merge.
@MainActor struct StaffWorkspaceModelResolver {
    private var models: [String: any PersistentModel] = [:]
    mutating func add<M: PersistentModel>(_ model: M, kind: String, id: UUID) throws {
        let key = kind + ":" + id.uuidString
        guard model.modelContext == nil, models[key] == nil else { throw StaffWorkspaceModelError.invalid }; models[key] = model
    }
    func require<M: PersistentModel>(_ type: M.Type, kind: String, id: UUID) throws -> M {
        guard let value = models[kind + ":" + id.uuidString] as? M, value.modelContext == nil else { throw StaffWorkspaceModelError.relationships }
        return value
    }
    func contains(kind: String, id: UUID) -> Bool { models[kind + ":" + id.uuidString] != nil }
    func parent<M: PersistentModel>(_ type: M.Type, kind: String, field: String, record: StaffWorkspaceModelRecord) throws -> M {
        guard let value = record.fields[field] else { throw StaffWorkspaceModelError.incomplete }
        return try require(type, kind: kind, id: UUID.fromStaffValue(value))
    }
}

@MainActor struct StaffWorkspaceModelField<M: PersistentModel> {
    let name: String
    let referenceKind: String?
    let schema: StaffWorkspaceFieldSchema
    let read: (M) -> StaffWorkspaceValue
    let validate: (StaffWorkspaceValue) throws -> Void
    let write: (M, StaffWorkspaceValue, StaffWorkspaceModelResolver) throws -> Void
    var validateReference: (StaffWorkspaceValue, StaffWorkspaceModelResolver) throws -> Void = { _, _ in }

    static func value<T: StaffWorkspaceAtom>(_ name: String, _ key: ReferenceWritableKeyPath<M, T>) -> Self {
        .init(name: name, referenceKind: nil, schema: .init(type: T.wireType, nullable: false, reference: nil, enumeration: nil),
            read: { $0[keyPath: key].staffValue },
            validate: { _ = try T.fromStaffValue($0) }, write: { object, value, _ in object[keyPath: key] = try T.fromStaffValue(value) })
    }
    static func optional<T: StaffWorkspaceAtom>(_ name: String, _ key: ReferenceWritableKeyPath<M, T?>) -> Self {
        .init(name: name, referenceKind: nil, schema: .init(type: T.wireType, nullable: true, reference: nil, enumeration: nil),
            read: { $0[keyPath: key]?.staffValue ?? .null },
            validate: { if $0 != .null { _ = try T.fromStaffValue($0) } },
            write: { object, value, _ in object[keyPath: key] = value == .null ? nil : try T.fromStaffValue(value) })
    }
    static func enumeration<T: RawRepresentable & CaseIterable>(_ name: String, _ key: ReferenceWritableKeyPath<M, T>) -> Self where T.RawValue == String {
        func decode(_ value: StaffWorkspaceValue) throws -> T {
            guard let result = T(rawValue: try String.fromStaffValue(value)) else { throw StaffWorkspaceModelError.invalid }; return result
        }
        return .init(name: name, referenceKind: nil,
            schema: .init(type: .text, nullable: false, reference: nil, enumeration: T.allCases.map(\.rawValue).sorted()),
            read: { .text($0[keyPath: key].rawValue) },
            validate: { _ = try decode($0) }, write: { object, value, _ in object[keyPath: key] = try decode(value) })
    }
    static func reference<P: PersistentModel>(_ name: String, _ key: ReferenceWritableKeyPath<M, P?>,
                                               id: KeyPath<P, UUID>, kind: String, required: Bool) -> Self {
        .init(name: name, referenceKind: kind, schema: .init(type: .identifier, nullable: !required, reference: kind, enumeration: nil),
            read: { $0[keyPath: key].map { .identifier($0[keyPath: id]) } ?? .null },
            validate: { if $0 == .null && !required { return }; _ = try UUID.fromStaffValue($0) },
            write: { object, value, resolver in
                object[keyPath: key] = value == .null && !required ? nil : try resolver.require(P.self, kind: kind, id: UUID.fromStaffValue(value))
            }, validateReference: { value, resolver in
                if value == .null && !required { return }
                _ = try resolver.require(P.self, kind: kind, id: UUID.fromStaffValue(value))
            })
    }
}

@MainActor struct StaffWorkspaceModelCodec<M: PersistentModel> {
    let kind: String
    let id: KeyPath<M, UUID>
    let fields: [StaffWorkspaceModelField<M>]
    /// Every excluded persisted attribute needs a reason. Inverse relationships
    /// are separately reconstructed from their owning records, never defaulted.
    let excludedAttributes: [String: String]
    let inverseRelationships: Set<String>
    let make: (StaffWorkspaceModelRecord, StaffWorkspaceModelResolver) throws -> M

    var fieldNames: Set<String> { Set(fields.map(\.name)) }
    func encode(_ object: M) throws -> StaffWorkspaceModelRecord {
        guard fieldNames.count == fields.count else { throw StaffWorkspaceModelError.invalid }
        let result = StaffWorkspaceModelRecord(version: 1, kind: kind, id: object[keyPath: id],
            fields: Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.read(object)) }))
        try validate(result); return result
    }
    func validate(_ record: StaffWorkspaceModelRecord) throws {
        guard record.version == 1, record.kind == kind, Set(record.fields.keys) == fieldNames,
              fieldNames.isDisjoint(with: Set(excludedAttributes.keys)),
              try JSONEncoder().encode(record).count <= 2 * 1024 * 1024 else { throw StaffWorkspaceModelError.incomplete }
        for field in fields { try field.validate(record.fields[field.name]!) }
    }
    func decodeDetached(_ record: StaffWorkspaceModelRecord, resolver: inout StaffWorkspaceModelResolver) throws -> M {
        try validate(record)
        guard !resolver.contains(kind: kind, id: record.id) else { throw StaffWorkspaceModelError.invalid }
        for field in fields { try field.validateReference(record.fields[field.name]!, resolver) }
        let model = try make(record, resolver)
        guard model.modelContext == nil, model[keyPath: id] == record.id else { throw StaffWorkspaceModelError.invalid }
        for field in fields { try field.write(model, record.fields[field.name]!, resolver) }
        try resolver.add(model, kind: kind, id: record.id)
        return model
    }
}
