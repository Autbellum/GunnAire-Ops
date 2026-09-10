import Foundation

struct StaffWorkspaceSelectionRequest: Codable, Equatable {
    let companyID: String
    let environment: String
    let replicaID: String
    let operationID: String
    let expectedSourceSequence: Int
    let expectedShareRevision: Int
    let sourceSchemaDigest: String
    init(plan: CloudKitStaffSharePlan, sequence: Int, operation: UUID = UUID()) {
        companyID = plan.companyID.uuidString.lowercased(); environment = plan.environment
        replicaID = plan.replicaID.uuidString.lowercased(); operationID = operation.uuidString.lowercased()
        expectedSourceSequence = sequence; expectedShareRevision = plan.revision
        sourceSchemaDigest = StaffWorkspacePublicationContract.schemaDigest
    }
    func validate(_ plan: CloudKitStaffSharePlan) throws {
        guard companyID == plan.companyID.uuidString.lowercased(), environment == plan.environment,
              replicaID == plan.replicaID.uuidString.lowercased(), CloudKitStaffSetupPolicy.canonicalID(operationID),
              (1...2_147_483_647).contains(expectedSourceSequence), expectedShareRevision == plan.revision,
              sourceSchemaDigest == StaffWorkspacePublicationContract.schemaDigest else { throw StaffReplicaDeliveryError.invalid }
    }
}

struct StaffWorkspaceContentRequest: Codable, Equatable {
    let companyID: String
    let environment: String
    let replicaID: String
    let contentSchema: String
    init(_ selection: StaffWorkspaceSelectionRequest) {
        companyID = selection.companyID; environment = selection.environment; replicaID = selection.replicaID
        contentSchema = "staff-workspace-content-v1"
    }
}

struct StaffWorkspaceSelectionIndex: Codable, Equatable {
    let kind: String
    let id: String
    let revision: Int
    let unavailableLinks: [String]
    var key: String { kind + ":" + id }
    func validate(original: StaffWorkspacePublishedRecord) throws {
        let names = Set(StaffWorkspaceRecordLinks.scalar[kind, default: [:]].keys)
            .union(StaffWorkspaceRecordLinks.owning[kind, default: [:]].keys)
            .union(StaffWorkspaceRecordLinks.lists.filter { $0.kind == kind }.map(\.field))
        guard StaffWorkspacePublicationContract.validKey(key), !original.deleted, key == original.key,
              revision == original.revision, unavailableLinks == Array(Set(unavailableLinks)).sorted(),
              Set(unavailableLinks).isSubset(of: names) else { throw StaffReplicaDeliveryError.invalid }
    }
}

struct StaffWorkspaceSelectionReceipt: Codable, Equatable {
    let schema: String
    let sourceSchema: String
    let sourceSchemaDigest: String
    let companyID: String
    let environment: String
    let replicaID: String
    let membershipID: String
    let memberRevision: String
    let memberRole: String
    let projectionPolicy: String
    let shareRevision: Int
    let coverage: [String]
    let fieldProjectionRequired: Bool
    let operationalWorkspaceReady: Bool
    let localCloudKitProofRequired: Bool
    let operationID: String
    let sourceSequence: Int
    let recordCount: Int
    let snapshotSHA256: String
    let currentSourceSequence: Int
    let sourceCurrent: Bool

    func validate(_ request: StaffWorkspaceSelectionRequest, plan: CloudKitStaffSharePlan,
                  workspace: CompanyWorkspaceIdentity, now: Date) throws {
        try request.validate(plan); try plan.validate(workspace: workspace, now: now)
        guard plan.state == "accepted", plan.businessAccessEligible, !plan.reviewRequired, !plan.cloudKitRevocationRequired,
              schema == "staff-workspace-selection-v1", sourceSchema == StaffWorkspacePublicationContract.schema,
              sourceSchemaDigest == StaffWorkspacePublicationContract.schemaDigest,
              companyID == request.companyID, environment == request.environment, replicaID == request.replicaID,
              membershipID == plan.id.uuidString.lowercased(), memberRevision == plan.memberRevision,
              memberRole == plan.memberRole, projectionPolicy == plan.projectionPolicy, shareRevision == plan.revision,
              operationID == request.operationID, sourceSequence == request.expectedSourceSequence,
              (sourceSequence...2_147_483_647).contains(currentSourceSequence), sourceCurrent == (currentSourceSequence == sourceSequence),
              coverage == StaffWorkspacePublicationContract.kinds.sorted(), (0...20_000).contains(recordCount),
              fieldProjectionRequired, !operationalWorkspaceReady, localCloudKitProofRequired,
              JobBillingAssignmentSnapshot.validConnectionRevision(snapshotSHA256) else { throw StaffReplicaDeliveryError.invalid }
    }
    /// Unlike content, this index has no floating point, dates, provider text or
    /// arbitrary numeric spelling: only validated ASCII identifiers, enum strings,
    /// booleans and bounded integers. Cross-language vectors pin this digest.
    func verifyIndex(_ records: [StaffWorkspaceSelectionIndex]) throws {
        guard records.count == recordCount, records.map(\.key) == Array(Set(records.map(\.key))).sorted() else {
            throw StaffReplicaDeliveryError.invalid
        }
        let encoded = try StaffWorkspacePublicationContract.encode(self)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { throw StaffReplicaDeliveryError.invalid }
        for name in ["recordCount", "snapshotSHA256", "currentSourceSequence", "sourceCurrent"] { object.removeValue(forKey: name) }
        object["records"] = try JSONSerialization.jsonObject(with: StaffWorkspacePublicationContract.encode(records))
        // JSONSerialization.sortedKeys uses different case ordering for keys
        // such as operationID/operationalWorkspaceReady. Sort literal UTF-8
        // explicitly; do not treat a platform's presentation sort as a wire hash.
        let bytes = try Self.canonicalIndex(object)
        guard StaffReplicaManifest.hash(bytes) == snapshotSHA256 else { throw StaffReplicaDeliveryError.invalid }
    }
    private static func canonicalIndex(_ value: Any, depth: Int = 0) throws -> Data {
        guard depth <= 8 else { throw StaffReplicaDeliveryError.invalid }
        if let object = value as? [String: Any] {
            var bytes = Data("{".utf8)
            for (offset, key) in object.keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }).enumerated() {
                if offset > 0 { bytes.append(contentsOf: ",".utf8) }
                bytes.append(try canonicalIndex(key, depth: depth + 1)); bytes.append(contentsOf: ":".utf8)
                bytes.append(try canonicalIndex(object[key]!, depth: depth + 1))
            }
            bytes.append(contentsOf: "}".utf8); return bytes
        }
        if let array = value as? [Any] {
            var bytes = Data("[".utf8)
            for (offset, item) in array.enumerated() {
                if offset > 0 { bytes.append(contentsOf: ",".utf8) }
                bytes.append(try canonicalIndex(item, depth: depth + 1))
            }
            bytes.append(contentsOf: "]".utf8); return bytes
        }
        guard value is String || value is NSNumber else { throw StaffReplicaDeliveryError.invalid }
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        if !(value is String) {
            let raw = String(decoding: bytes, as: UTF8.self)
            guard raw == "true" || raw == "false" || raw.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw StaffReplicaDeliveryError.invalid }
        }
        return bytes
    }
    func sameOriginal(as other: Self) -> Bool {
        // Dynamic head freshness may advance while the immutable original does not.
        // Compare encoded identity after removing only the two freshness fields.
        func identity(_ value: Self) -> Data? {
            guard let data = try? StaffWorkspacePublicationContract.encode(value),
                  var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            object.removeValue(forKey: "currentSourceSequence"); object.removeValue(forKey: "sourceCurrent")
            return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        return identity(self) != nil && identity(self) == identity(other)
    }
}

struct StaffWorkspaceSelectionPage: Codable {
    let receipt: StaffWorkspaceSelectionReceipt
    let records: [StaffWorkspaceSelectionIndex]
    let nextCursor: String?
    enum CodingKeys: String, CodingKey { case records, nextCursor }
    init(receipt: StaffWorkspaceSelectionReceipt, records: [StaffWorkspaceSelectionIndex], nextCursor: String?) {
        self.receipt = receipt; self.records = records; self.nextCursor = nextCursor
    }
    init(from decoder: Decoder) throws {
        receipt = try StaffWorkspaceSelectionReceipt(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        records = try c.decode([StaffWorkspaceSelectionIndex].self, forKey: .records)
        guard c.contains(.nextCursor) else { throw StaffReplicaDeliveryError.invalid }
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
    }
    func encode(to encoder: Encoder) throws {
        try receipt.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(records, forKey: .records); try c.encode(nextCursor, forKey: .nextCursor)
    }
}

enum StaffWorkspaceContentHTTPPolicy {
    static func root(_ plan: CloudKitStaffSharePlan) -> String {
        CloudKitStaffSetupPolicy.base + "/" + plan.id.uuidString.lowercased() + "/full-selections"
    }
    static func path(_ plan: CloudKitStaffSharePlan, request: StaffWorkspaceSelectionRequest,
                     suffix: String = "", after: String? = nil, offset: Int? = nil) -> String {
        var url = URLComponents()
        url.path = root(plan) + "/" + request.operationID + suffix
        url.queryItems = [URLQueryItem(name: "companyID", value: request.companyID),
            .init(name: "environment", value: request.environment), .init(name: "replicaID", value: request.replicaID)]
        if let after { url.queryItems?.append(.init(name: "after", value: after)) }
        if let offset { url.queryItems?.append(.init(name: "offset", value: String(offset))) }
        return url.string ?? ""
    }
    static func allows(path: String, method: String, body: Data?) -> Bool {
        guard let url = URLComponents(string: path), url.scheme == nil, url.host == nil, url.fragment == nil,
              url.path == url.percentEncodedPath else { return false }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (6...9).contains(parts.count), Array(parts.prefix(4)) == ["", "api", "workspace", "staff-shares"],
              CloudKitStaffSetupPolicy.canonicalID(parts[4]), parts[5] == "full-selections",
              parts.count == 6 || CloudKitStaffSetupPolicy.canonicalID(parts[6]) else { return false }
        if method == "POST" {
            guard url.query == nil, let body, body.count <= 8192 else { return false }
            if parts.count == 6, let value = try? StaffWorkspacePublicationContract.decode(StaffWorkspaceSelectionRequest.self, from: body) {
                return scope(value.companyID, value.environment, value.replicaID) && CloudKitStaffSetupPolicy.canonicalID(value.operationID) &&
                    (1...2_147_483_647).contains(value.expectedSourceSequence) && (1...2_147_483_647).contains(value.expectedShareRevision) &&
                    value.sourceSchemaDigest == StaffWorkspacePublicationContract.schemaDigest
            }
            if parts.count == 8, parts[7] == "content", let value = try? StaffWorkspacePublicationContract.decode(StaffWorkspaceContentRequest.self, from: body) {
                return scope(value.companyID, value.environment, value.replicaID) && value.contentSchema == "staff-workspace-content-v1"
            }
            return false
        }
        guard method == "GET", body == nil, let items = url.queryItems,
              items.allSatisfy({ $0.value != nil }), Set(items.map(\.name)).count == items.count else { return false }
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
        guard scope(query["companyID"], query["environment"], query["replicaID"]) else { return false }
        let names: Set<String> = ["companyID", "environment", "replicaID"]
        if parts.count == 7 || parts.count == 8 && parts[7] == "content" { return Set(query.keys) == names }
        if parts.count == 8, parts[7] == "records" {
            return Set(query.keys) == names || Set(query.keys) == names.union(["after"]) && StaffWorkspacePublicationContract.validKey(query["after"]!)
        }
        if parts.count == 9, parts[7] == "content", parts[8] == "chunks", Set(query.keys) == names.union(["offset"]),
           let raw = query["offset"], let offset = Int(raw), String(offset) == raw {
            return (0..<StaffWorkspaceContentReceipt.maximumBytes).contains(offset) && offset % StaffWorkspaceContentReceipt.chunkSize == 0
        }
        return false
    }
    private static func scope(_ company: String?, _ environment: String?, _ replica: String?) -> Bool {
        guard let company, let environment, let replica else { return false }
        return CloudKitStaffSetupPolicy.canonicalID(company) && CloudKitStaffSetupPolicy.canonicalID(replica) && ["development", "production"].contains(environment)
    }
}
