import Foundation
import CryptoKit

/// Full owner records are never a staff projection, permission grant, or a
/// financial command. Keep this protocol separate from core-field-v1.
enum StaffWorkspacePublicationContract {
    static let schema = "owner-workspace-v1"
    static let schemaDigest = "d713a48445601f87bff3a47f101bd2173793fdc0d405f3a547851df5a9e4c6d3"
    static let maximumResponseBytes = 8 * 1024 * 1024
    static let maximumScanBytes = 64 * 1024 * 1024
    static let maximumRecords = 100_000
    // Leave room for the server's canonical numeric/envelope representation.
    static let maximumRequestBytes = 7 * 1024 * 1024
    // Immutable validation metadata only: no models, company records, session
    // state, context or journal is cached here. Rebuilding 32 typed codecs for
    // every record key made bounded large-company publication needlessly slow.
    private static let codecs = Dictionary(uniqueKeysWithValues: StaffWorkspaceModelCatalog.all.map { ($0.kind, $0) })
    static let kinds = Set(codecs.keys)

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    static func validateJSON(_ bytes: Data, maximum: Int) throws {
        guard !bytes.isEmpty, bytes.count <= maximum else { throw StaffReplicaSourceSyncError.invalid }
        try StaffWorkspacePublicationJSON.validate(bytes)
    }
    static func decode<T: Codable>(_ type: T.Type, from bytes: Data, maximum: Int = maximumResponseBytes) throws -> T {
        guard !bytes.isEmpty, bytes.count <= maximum else { throw StaffReplicaSourceSyncError.invalid }
        let comparison = try StaffWorkspacePublicationJSON.normalizingSignedZeros(bytes)
        let value = try JSONDecoder().decode(type, from: bytes)
        let original = try JSONSerialization.jsonObject(with: comparison)
        let encoded = try JSONSerialization.jsonObject(with: encode(value))
        guard try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys]) ==
                JSONSerialization.data(withJSONObject: encoded, options: [.sortedKeys]) else {
            throw StaffReplicaSourceSyncError.invalid
        }
        return value
    }
    static func digest<T: Encodable>(_ value: T) throws -> String {
        SHA256.hash(data: try encode(value)).map { String(format: "%02x", $0) }.joined()
    }
    static func validateCatalog() throws {
        let fields = codecs.mapValues(\.fieldSchema)
        guard try digest(fields) == schemaDigest else { throw StaffReplicaSourceSyncError.invalid }
    }
    static func validKey(_ key: String) -> Bool {
        let parts = key.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 2 && kinds.contains(String(parts[0])) && CloudKitStaffSetupPolicy.canonicalID(String(parts[1]))
    }
    static func validate(_ record: StaffWorkspaceModelRecord) throws {
        guard let codec = codecs[record.kind] else {
            throw StaffReplicaSourceSyncError.invalid
        }
        try codec.validate(record)
    }
}

/// Scan object keys without materializing another full workspace tree. The
/// Codable/JSONSerialization decoders below still validate the JSON grammar.
/// Duplicate keys (including Unicode-escaped aliases) must not be discarded.
private struct StaffWorkspacePublicationJSON {
    let bytes: [UInt8]
    var collectSignedZeros = false
    var signedZeros: [Range<Int>] = []
    var index = 0
    var nodes = 0
    var current: UInt8? { index < bytes.count ? bytes[index] : nil }
    static func validate(_ data: Data) throws {
        var reader = Self(bytes: Array(data))
        try reader.value(depth: 0); reader.whitespace()
        guard reader.index == reader.bytes.count else { throw StaffReplicaSourceSyncError.invalid }
    }
    /// Python emits -0.0; Swift may emit -0, which Foundation parses as integer 0.
    /// Normalize only literal zero number tokens for structural comparison, never
    /// strings, booleans, nonzero/underflowing numbers, stored bytes or digests.
    static func normalizingSignedZeros(_ data: Data) throws -> Data {
        var reader = Self(bytes: Array(data), collectSignedZeros: true)
        try reader.value(depth: 0); reader.whitespace()
        guard reader.index == reader.bytes.count else { throw StaffReplicaSourceSyncError.invalid }
        guard !reader.signedZeros.isEmpty else { return data }
        var result = Data(), start = 0
        for range in reader.signedZeros {
            result.append(contentsOf: reader.bytes[start..<range.lowerBound]); result.append(48)
            start = range.upperBound
        }
        result.append(contentsOf: reader.bytes[start...]); return result
    }
    mutating func whitespace() { while let byte = current, [9, 10, 13, 32].contains(byte) { index += 1 } }
    mutating func take(_ byte: UInt8) throws {
        guard current == byte else { throw StaffReplicaSourceSyncError.invalid }; index += 1
    }
    mutating func string() throws -> Range<Int> {
        let start = index; try take(34)
        while let byte = current {
            index += 1
            if byte == 34 { return start..<index }
            if byte == 92 {
                guard current != nil else { throw StaffReplicaSourceSyncError.invalid }; index += 1
            }
        }
        throw StaffReplicaSourceSyncError.invalid
    }
    mutating func value(depth: Int) throws {
        nodes += 1
        guard depth <= 24, nodes <= 2_000_000 else { throw StaffReplicaSourceSyncError.invalid }
        whitespace()
        switch current {
        case 123:
            index += 1; whitespace(); var keys = Set<String>()
            if current == 125 { index += 1; return }
            while true {
                whitespace()
                let range = try string()
                let key = try JSONDecoder().decode(String.self, from: Data(bytes[range]))
                guard keys.insert(key).inserted else { throw StaffReplicaSourceSyncError.invalid }
                whitespace(); try take(58); try value(depth: depth + 1); whitespace()
                if current == 125 { index += 1; return }; try take(44)
            }
        case 91:
            index += 1; whitespace()
            if current == 93 { index += 1; return }
            while true {
                try value(depth: depth + 1); whitespace()
                if current == 93 { index += 1; return }; try take(44)
            }
        case 34: _ = try string()
        default:
            let start = index
            while let byte = current, ![9, 10, 13, 32, 44, 93, 125].contains(byte) { index += 1 }
            guard index > start else { throw StaffReplicaSourceSyncError.invalid }
            if collectSignedZeros, bytes[start] == 45, index > start + 1, bytes[start + 1] == 48 {
                let token = String(decoding: bytes[start..<index], as: UTF8.self)
                if token.range(of: #"^-0(?:\.0+)?(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil {
                    signedZeros.append(start..<index)
                }
            }
        }
    }
}

struct StaffWorkspacePublishedRecord: Codable, Equatable {
    let companyID: String
    let environment: String
    let replicaID: String
    let schema: String
    let schemaDigest: String
    let kind: String
    let id: String
    let revision: Int
    let deleted: Bool
    let fields: [String: StaffWorkspaceValue]
    var key: String { kind + ":" + id }
    var model: StaffWorkspaceModelRecord? {
        UUID(uuidString: id).map { .init(version: 1, kind: kind, id: $0, fields: fields) }
    }
    var live: StaffWorkspaceModelRecord? { deleted ? nil : model }
    func validate(_ scope: StaffReplicaSourceScope) throws {
        guard companyID == scope.binding.companyID.uuidString.lowercased(), environment == scope.binding.environment,
              replicaID == scope.binding.replicaID.uuidString.lowercased(), schema == StaffWorkspacePublicationContract.schema,
              schemaDigest == StaffWorkspacePublicationContract.schemaDigest, StaffWorkspacePublicationContract.validKey(key),
              (1..<2_147_483_647).contains(revision), let model else { throw StaffReplicaSourceSyncError.invalid }
        try StaffWorkspacePublicationContract.validate(model)
    }
}

struct StaffWorkspacePublicationPage: Codable {
    let companyID: String
    let environment: String
    let replicaID: String
    let schema: String
    let schemaDigest: String
    let sequence: Int
    let records: [StaffWorkspacePublishedRecord]
    let nextCursor: String?
    enum CodingKeys: String, CodingKey { case companyID, environment, replicaID, schema, schemaDigest, sequence, records, nextCursor }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(companyID, forKey: .companyID); try c.encode(environment, forKey: .environment)
        try c.encode(replicaID, forKey: .replicaID); try c.encode(schema, forKey: .schema)
        try c.encode(schemaDigest, forKey: .schemaDigest); try c.encode(sequence, forKey: .sequence)
        try c.encode(records, forKey: .records); try c.encode(nextCursor, forKey: .nextCursor)
    }
    func validate(_ scope: StaffReplicaSourceScope, sequence expected: Int?, after: String?) throws {
        guard companyID == scope.binding.companyID.uuidString.lowercased(), environment == scope.binding.environment,
              replicaID == scope.binding.replicaID.uuidString.lowercased(), schema == StaffWorkspacePublicationContract.schema,
              schemaDigest == StaffWorkspacePublicationContract.schemaDigest, (0..<2_147_483_647).contains(sequence),
              expected == nil || sequence == expected, records.count <= 100,
              sequence > 0 || records.isEmpty,
              records.map(\.key) == records.map(\.key).sorted(), Set(records.map(\.key)).count == records.count,
              records.allSatisfy({ $0.key > (after ?? "") }),
              nextCursor == nil || (!records.isEmpty && nextCursor == records.last?.key) else {
            throw StaffReplicaSourceSyncError.invalid
        }
        // Pages can be short because of their actual escaped HTTP byte size.
        try records.forEach { try $0.validate(scope) }
    }
}

struct StaffWorkspacePublicationChange: Codable, Equatable {
    let kind: String
    let id: String
    let expectedRevision: Int
    let action: String
    let fields: [String: StaffWorkspaceValue]
    var key: String { kind + ":" + id }
    func validate() throws {
        guard StaffWorkspacePublicationContract.validKey(key), (0..<2_147_483_646).contains(expectedRevision),
              ["upsert", "delete", "restore"].contains(action), action == "upsert" || expectedRevision > 0,
              try StaffWorkspacePublicationContract.encode(self).count <= 2 * 1024 * 1024 else {
            throw StaffReplicaSourceSyncError.invalid
        }
        if action == "delete" { guard fields.isEmpty else { throw StaffReplicaSourceSyncError.invalid } }
        else {
            guard let uuid = UUID(uuidString: id) else { throw StaffReplicaSourceSyncError.invalid }
            try StaffWorkspacePublicationContract.validate(.init(version: 1, kind: kind, id: uuid, fields: fields))
        }
    }
}

struct StaffWorkspacePublicationBatch: Codable, Equatable {
    let companyID: String
    let environment: String
    let replicaID: String
    let schema: String
    let schemaDigest: String
    let operationID: String
    let expectedSequence: Int
    let changes: [StaffWorkspacePublicationChange]
    init(scope: StaffReplicaSourceScope, sequence: Int, changes: [StaffWorkspacePublicationChange], operation: UUID = UUID()) {
        companyID = scope.binding.companyID.uuidString.lowercased(); environment = scope.binding.environment
        replicaID = scope.binding.replicaID.uuidString.lowercased(); schema = StaffWorkspacePublicationContract.schema
        schemaDigest = StaffWorkspacePublicationContract.schemaDigest; operationID = operation.uuidString.lowercased()
        expectedSequence = sequence; self.changes = changes
    }
    func validate(_ scope: StaffReplicaSourceScope) throws {
        guard companyID == scope.binding.companyID.uuidString.lowercased(), environment == scope.binding.environment,
              replicaID == scope.binding.replicaID.uuidString.lowercased(), schema == StaffWorkspacePublicationContract.schema,
              schemaDigest == StaffWorkspacePublicationContract.schemaDigest, CloudKitStaffSetupPolicy.canonicalID(operationID),
              (0..<2_147_483_646).contains(expectedSequence), (1...100).contains(changes.count),
              Set(changes.map(\.key)).count == changes.count else { throw StaffReplicaSourceSyncError.invalid }
        try changes.forEach { try $0.validate() }
    }
}

/// Keep the original wire bytes, not just a value that could be re-encoded
/// differently after a relaunch or SDK update.
struct StaffWorkspacePublicationPending: Codable, Equatable {
    let body: Data
    let previous: [String: StaffWorkspacePublicationFingerprint]
    func batch(_ scope: StaffReplicaSourceScope) throws -> StaffWorkspacePublicationBatch {
        let batch = try StaffWorkspacePublicationContract.decode(StaffWorkspacePublicationBatch.self, from: body,
            maximum: StaffWorkspacePublicationContract.maximumRequestBytes)
        try batch.validate(scope)
        guard Set(previous.keys) == Set(batch.changes.filter { $0.expectedRevision > 0 }.map(\.key)) else {
            throw StaffReplicaSourceSyncError.storage
        }
        for change in batch.changes where change.expectedRevision > 0 {
            guard let prior = previous[change.key], prior.key == change.key, prior.revision == change.expectedRevision,
                  prior.deleted == (change.action == "restore") else { throw StaffReplicaSourceSyncError.storage }
            try prior.validate()
        }
        return batch
    }
}

struct StaffWorkspacePublicationReceipt: Codable {
    struct Change: Codable, Equatable { let kind: String; let id: String; let revision: Int; let deleted: Bool }
    let companyID: String
    let environment: String
    let replicaID: String
    let schema: String
    let schemaDigest: String
    let operationID: String
    let sequence: Int
    let currentSequence: Int
    let changes: [Change]
    func validate(_ batch: StaffWorkspacePublicationBatch) throws {
        guard companyID == batch.companyID, environment == batch.environment, replicaID == batch.replicaID,
              schema == batch.schema, schemaDigest == batch.schemaDigest, operationID == batch.operationID,
              sequence == batch.expectedSequence + 1, currentSequence >= sequence, currentSequence < 2_147_483_647,
              changes == batch.changes.map({ .init(kind: $0.kind, id: $0.id, revision: $0.expectedRevision + 1, deleted: $0.action == "delete") }) else {
            throw StaffReplicaSourceSyncError.invalid
        }
    }
}

enum StaffWorkspacePublicationTransportPolicy {
    static let root = "/api/workspace/full-records"
    static func path(scope: StaffReplicaSourceScope, sequence: Int? = nil, after: String? = nil) -> String {
        var result = root + "?companyID=" + scope.binding.companyID.uuidString.lowercased()
            + "&environment=" + scope.binding.environment + "&replicaID=" + scope.binding.replicaID.uuidString.lowercased()
        if let sequence { result += "&sequence=\(sequence)" }
        if let after { result += "&after=" + after }
        return result
    }
    static func allows(path: String, method: String, body: Data?) -> Bool {
        if method == "POST" {
            return path == root && body.map { !$0.isEmpty && $0.count <= StaffWorkspacePublicationContract.maximumRequestBytes } == true
        }
        guard method == "GET", body == nil, let url = URLComponents(string: path), url.scheme == nil, url.host == nil,
              url.fragment == nil, url.percentEncodedPath == root, !path.contains("%"),
              let query = url.queryItems, Set(query.map(\.name)).count == query.count else { return false }
        let values = Dictionary(uniqueKeysWithValues: query.compactMap { item in item.value.map { (item.name, $0) } })
        guard values.count == query.count, let company = values["companyID"], let replica = values["replicaID"],
              CloudKitStaffSetupPolicy.canonicalID(company), CloudKitStaffSetupPolicy.canonicalID(replica),
              ["development", "production"].contains(values["environment"] ?? ""),
              Set(values.keys).isSubset(of: ["companyID", "environment", "replicaID", "sequence", "after"]) else { return false }
        if let sequence = values["sequence"] {
            guard let number = Int(sequence), (0..<2_147_483_647).contains(number), String(number) == sequence else { return false }
        }
        if let after = values["after"] {
            guard values["sequence"] != nil, StaffWorkspacePublicationContract.validKey(after) else { return false }
        }
        return true
    }
}
