import Foundation

/// Owner-side integrity and original-field verification. Structured projections
/// remain server-authoritative views, never owner SwiftData models or commands.
/// This does not grant staff access or replace full-model receiver acceptance.
enum StaffWorkspaceContentVerification {
    private static let structured: [String: Set<String>] = [
        "technician": ["serviceAreasJSON", "supportedEquipmentTypesJSON"],
        "equipment": ["technicalBaselineReadingsJSON"], "item": ["flatRateAssemblyJSON"],
        "job": ["additionalTechnicianIDsJSON", "serviceActionChecklistJSON", "serviceReportReadingsJSON"],
        "timeEntry": ["reviewAuditJSON"], "agreement": ["coveredEquipmentIDsJSON", "lifecycleJSON"],
        "communication": ["attachmentFileNamesJSON", "consentSnapshotJSON"],
        "formTemplate": ["questionsJSON", "applicableServiceTypesJSON"], "formResponse": ["answersJSON"],
        "vehicleEvent": ["inspectionResultsJSON"], "expense": ["auditJSON"]
    ]
    private static func object(_ value: Any, keys: Set<String>? = nil) throws -> [String: Any] {
        guard let result = value as? [String: Any], keys == nil || Set(result.keys) == keys else { throw StaffReplicaDeliveryError.invalid }
        return result
    }
    private static func decode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
    }
    private static func equal(_ lhs: Any, _ rhs: Any) throws -> Bool {
        try JSONSerialization.data(withJSONObject: lhs, options: [.sortedKeys]) == JSONSerialization.data(withJSONObject: rhs, options: [.sortedKeys])
    }
    static func validate(_ bytes: Data, receipt: StaffWorkspaceContentReceipt, index: [StaffWorkspaceSelectionIndex],
                         originals: [StaffWorkspacePublishedRecord], stage: StaffWorkspaceSourceJournal,
                         source: StaffReplicaSourceContext, plan: CloudKitStaffSharePlan,
                         workspace: CompanyWorkspaceIdentity, now: Date) throws {
        guard bytes.count == receipt.payloadBytes, StaffReplicaManifest.hash(bytes) == receipt.contentSHA256 else { throw StaffReplicaDeliveryError.invalid }
        try StaffWorkspacePublicationContract.validateJSON(bytes, maximum: StaffWorkspaceContentReceipt.maximumBytes)
        var expected = try object(JSONSerialization.jsonObject(with: StaffWorkspacePublicationContract.encode(receipt)))
        for name in ["schema", "contentSchema", "selectionID", "selectionSHA256", "contentSHA256", "recordCount", "payloadBytes", "chunkBytes",
                     "currentSourceSequence", "sourceCurrent", "operationalWorkspaceReady", "fieldProjectionRequired", "localCloudKitProofRequired"] {
            expected.removeValue(forKey: name)
        }
        expected["schema"] = receipt.contentSchema
        var root = try object(JSONSerialization.jsonObject(with: bytes), keys: Set(expected.keys).union(["records"]))
        guard let records = root.removeValue(forKey: "records") as? [[String: Any]], records.count == index.count,
              try equal(root, expected), originals.count <= StaffWorkspacePublicationContract.maximumRecords,
              Set(originals.map(\.key)).count == originals.count else { throw StaffReplicaDeliveryError.invalid }
        let rows = Dictionary(uniqueKeysWithValues: originals.map { ($0.key, $0) })
        var billing: [StaffWorkspaceBillingProjection.Document] = []
        for (wire, entry) in zip(records, index) {
            var value = try object(wire, keys: ["kind", "id", "revision", "unavailableLinks", "body"])
            let body = try object(value.removeValue(forKey: "body")!)
            let identity = try decode(StaffWorkspaceSelectionIndex.self, value)
            guard identity == entry, let original = rows[entry.key] else { throw StaffReplicaDeliveryError.invalid }
            try entry.validate(original: original)
            if ["invoice", "estimate"].contains(entry.kind) {
                let branch = try object(body, keys: ["billing"])
                let box = try object(branch["billing"]!, keys: ["_0"])
                let document = try decode(StaffWorkspaceBillingProjection.Document.self, box["_0"]!)
                guard document.kind == entry.kind, document.id.uuidString.lowercased() == entry.id else { throw StaffReplicaDeliveryError.invalid }
                billing.append(document)
            } else {
                let branch = try object(body, keys: ["operational"])
                let box = try object(branch["operational"]!, keys: ["_0"])
                let fields = try object(box["_0"]!, keys: ["fields", "unavailableFields", "structuredFields"])
                let scalars = try decode([String: StaffWorkspaceValue].self, fields["fields"]!)
                let unavailable = try decode([String: StaffWorkspaceBillingProjection.Unavailable].self, fields["unavailableFields"]!)
                let evidence = try object(fields["structuredFields"]!)
                let a = Set(scalars.keys), b = Set(unavailable.keys), c = Set(evidence.keys)
                guard a.isDisjoint(with: b), a.isDisjoint(with: c), b.isDisjoint(with: c),
                      a.union(b).union(c) == Set(original.fields.keys), c.isSubset(of: structured[entry.kind, default: []]),
                      scalars.allSatisfy({ !$0.key.hasSuffix("JSON") && original.fields[$0.key] == $0.value }) else {
                    throw StaffReplicaDeliveryError.invalid
                }
                for (name, value) in evidence {
                    let disclosure = try object(value)
                    if Set(disclosure.keys) == ["notRecorded"] {
                        _ = try object(disclosure["notRecorded"]!, keys: [])
                        guard original.fields[name] == .null else { throw StaffReplicaDeliveryError.invalid }
                    } else {
                        let saved = try object(disclosure, keys: ["recorded"])
                        _ = try object(saved["recorded"]!, keys: ["_0"])
                    }
                }
            }
        }
        // This already-qualified native adapter independently checks complete
        // original sold-line, tax, discount, bundle and private-cost history.
        let expectedBilling = try StaffWorkspaceBillingProjection.prepare(source: stage, expectedScope: source.scope,
            plan: plan, workspace: workspace, sourceSequence: receipt.sourceSequence, now: now)
        guard billing == expectedBilling.documents else { throw StaffReplicaDeliveryError.invalid }
    }
}
