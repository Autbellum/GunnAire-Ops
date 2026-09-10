import Foundation

/// Durable staff-side semantic acceptance of a mounted role projection.
///
/// Small journal only (selection/content digest/sequence) — never stores opened
/// bytes, keys, or a ModelContext import. Acceptance does not flip
/// `operationalWorkspaceReady` and is not media, command, or full staff-store
/// activation. Restricted/unavailable fields stay explicit; never invent
/// SwiftData defaults (nil/0/""/empty collections) for them.
struct StaffWorkspaceOperationalAcceptance: Codable, Equatable {
    static let schema = "staff-workspace-operational-acceptance-v1"
    let schema: String
    let scope: CloudKitStaffSetupScope
    let planID: UUID
    let selectionID: String
    let sourceSequence: Int
    let contentSHA256: String
    let recordCount: Int
    let state: String

    init(scope: CloudKitStaffSetupScope, planID: UUID, selectionID: String,
         sourceSequence: Int, contentSHA256: String, recordCount: Int) throws {
        guard CloudKitStaffSetupPolicy.canonicalID(selectionID),
              (1...2_147_483_647).contains(sourceSequence),
              JobBillingAssignmentSnapshot.validConnectionRevision(contentSHA256),
              (0...20_000).contains(recordCount) else {
            throw StaffReplicaDeliveryError.invalid
        }
        schema = Self.schema
        self.scope = scope
        self.planID = planID
        self.selectionID = selectionID
        self.sourceSequence = sourceSequence
        self.contentSHA256 = contentSHA256
        self.recordCount = recordCount
        state = "accepted"
    }

    func validate(scope: CloudKitStaffSetupScope, plan: UUID, mount: StaffWorkspaceOperationalMount) throws {
        guard schema == Self.schema, state == "accepted", self.scope == scope, planID == plan,
              selectionID == mount.selectionID, sourceSequence == mount.sourceSequence,
              contentSHA256 == mount.contentSHA256 else {
            throw StaffReplicaDeliveryError.storage
        }
    }
}

/// Read-only operational view derived from mounted `staff-workspace-content-v1` bytes.
/// Billing bodies reuse the typed billing Document; operational bodies keep the
/// explicit fields / unavailableFields / structuredFields partition.
struct StaffWorkspaceOperationalView: Equatable {
    struct Record: Equatable {
        let kind: String
        let id: String
        let revision: Int
        let unavailableLinks: [String]
        let body: Body
    }
    enum Body: Equatable {
        case billing(StaffWorkspaceBillingProjection.Document)
        case operational(OperationalPartition)
    }
    struct OperationalPartition: Equatable {
        let fields: [String: StaffWorkspaceValue]
        let unavailableFields: [String: StaffWorkspaceBillingProjection.Unavailable]
        /// Canonical JSON of each structured disclosure object (`notRecorded` / `recorded`).
        let structuredFields: [String: Data]
    }

    let schema: String
    let selectionID: String
    let contentSHA256: String
    let sourceSequence: Int
    let companyID: String
    let environment: String
    let replicaID: String
    let membershipID: String
    let memberRevision: String
    let memberRole: String
    let shareRevision: Int
    let projectionPolicy: String
    let coverage: [String]
    let records: [Record]
}

/// Parse + journal helpers for staff semantic acceptance after durable mount.
enum StaffWorkspaceOperationalAcceptanceStore {
    private static let invoiceServiceOnly: Set<String> = [
        "quickBooksSyncDetail", "quickBooksPaymentReviewJSON", "milestoneDraftReceiptJSON",
    ]
    private static let structuredByKind: [String: Set<String>] = [
        "technician": ["serviceAreasJSON", "supportedEquipmentTypesJSON"],
        "equipment": ["technicalBaselineReadingsJSON"], "item": ["flatRateAssemblyJSON"],
        "job": ["additionalTechnicianIDsJSON", "serviceActionChecklistJSON", "serviceReportReadingsJSON"],
        "timeEntry": ["reviewAuditJSON"], "agreement": ["coveredEquipmentIDsJSON", "lifecycleJSON"],
        "communication": ["attachmentFileNamesJSON", "consentSnapshotJSON"],
        "formTemplate": ["questionsJSON", "applicableServiceTypesJSON"], "formResponse": ["answersJSON"],
        "vehicleEvent": ["inspectionResultsJSON"], "expense": ["auditJSON"],
    ]

    static func key(_ scope: CloudKitStaffSetupScope, _ plan: UUID) -> String {
        "full-staff-content-acceptance-v1\n" + scope.key + "\n" + plan.uuidString.lowercased()
    }

    static func load(store: SharedTimeLocalStore, scope: CloudKitStaffSetupScope, plan: UUID) throws -> StaffWorkspaceOperationalAcceptance? {
        do {
            guard let bytes = try store.read(key(scope, plan)) else { return nil }
            guard bytes.count <= 8192 else { throw StaffReplicaDeliveryError.storage }
            let journal = try StaffWorkspacePublicationContract.decode(StaffWorkspaceOperationalAcceptance.self,
                                                                       from: bytes, maximum: 8192)
            guard journal.schema == StaffWorkspaceOperationalAcceptance.schema, journal.state == "accepted",
                  journal.scope == scope, journal.planID == plan,
                  CloudKitStaffSetupPolicy.canonicalID(journal.selectionID),
                  (1...2_147_483_647).contains(journal.sourceSequence),
                  JobBillingAssignmentSnapshot.validConnectionRevision(journal.contentSHA256),
                  (0...20_000).contains(journal.recordCount) else {
                throw StaffReplicaDeliveryError.storage
            }
            return journal
        } catch let error as StaffReplicaDeliveryError {
            throw error
        } catch {
            throw StaffReplicaDeliveryError.storage
        }
    }

    /// Mount must already exist. Failed acceptance never deletes or rewrites mount/lease.
    @discardableResult
    static func accept(store: SharedTimeLocalStore, scope: CloudKitStaffSetupScope, plan: UUID,
                       selectionID: String? = nil, check: () throws -> Void = {}) throws -> StaffWorkspaceOperationalView {
        try check()
        guard let (mount, payload) = try StaffWorkspaceOperationalMountStore.load(store: store, scope: scope, plan: plan) else {
            throw StaffReplicaDeliveryError.pending
        }
        if let selectionID {
            guard mount.selectionID == selectionID else { throw StaffReplicaDeliveryError.changed }
        }
        guard payload.count == mount.contentBytes,
              StaffReplicaManifest.hash(payload) == mount.contentSHA256 else {
            throw StaffReplicaDeliveryError.changed
        }
        let view = try parse(opened: payload, mount: mount)
        try check()
        let next = try StaffWorkspaceOperationalAcceptance(
            scope: scope, planID: plan, selectionID: mount.selectionID,
            sourceSequence: mount.sourceSequence, contentSHA256: mount.contentSHA256,
            recordCount: view.records.count)
        if let existing = try load(store: store, scope: scope, plan: plan) {
            if existing.selectionID == next.selectionID,
               existing.contentSHA256 == next.contentSHA256,
               existing.sourceSequence == next.sourceSequence,
               existing.recordCount == next.recordCount {
                try existing.validate(scope: scope, plan: plan, mount: mount)
                return view // Idempotent re-accept of the same mounted head.
            }
            // Different head — replace journal only after successful parse of new mount.
        }
        try check()
        let encoded = try StaffWorkspacePublicationContract.encode(next)
        guard encoded.count <= 8192 else { throw StaffReplicaDeliveryError.storage }
        try store.write(key(scope, plan), encoded)
        try check()
        guard let confirmed = try load(store: store, scope: scope, plan: plan), confirmed == next else {
            throw StaffReplicaDeliveryError.storage
        }
        try confirmed.validate(scope: scope, plan: plan, mount: mount)
        return view
    }

    /// Fail-closed parse of mounted `staff-workspace-content-v1` bytes into a read-only view.
    /// Does not call owner ModelCodec.make (those invent SwiftData defaults).
    static func parse(opened: Data, mount: StaffWorkspaceOperationalMount) throws -> StaffWorkspaceOperationalView {
        guard opened.count == mount.contentBytes,
              StaffReplicaManifest.hash(opened) == mount.contentSHA256,
              opened.count <= StaffWorkspaceContentReceipt.maximumBytes else {
            throw StaffReplicaDeliveryError.changed
        }
        try StaffWorkspacePublicationContract.validateJSON(opened, maximum: StaffWorkspaceContentReceipt.maximumBytes)
        guard let root = try JSONSerialization.jsonObject(with: opened) as? [String: Any] else {
            throw StaffReplicaDeliveryError.invalid
        }
        let required: Set<String> = [
            "schema", "companyID", "environment", "replicaID", "membershipID", "memberRevision",
            "memberRole", "shareRevision", "projectionPolicy", "sourceSequence", "sourceSchema",
            "sourceSchemaDigest", "fieldPolicy", "discriminatorSchema", "structuredSchema",
            "billingSchema", "coverage", "records",
        ]
        guard Set(root.keys) == required else { throw StaffReplicaDeliveryError.invalid }
        guard root["schema"] as? String == "staff-workspace-content-v1",
              root["sourceSchema"] as? String == StaffWorkspacePublicationContract.schema,
              root["sourceSchemaDigest"] as? String == StaffWorkspacePublicationContract.schemaDigest,
              root["fieldPolicy"] as? String == "staff-operational-fields-v1",
              root["discriminatorSchema"] as? String == "staff-workspace-discriminators-v1",
              root["structuredSchema"] as? String == "staff-operational-evidence-v1",
              root["billingSchema"] as? String == "staff-billing-view-v1",
              root["sourceSequence"] as? Int == mount.sourceSequence,
              let companyID = root["companyID"] as? String, CloudKitStaffSetupPolicy.canonicalID(companyID),
              let environment = root["environment"] as? String, ["development", "production"].contains(environment),
              let replicaID = root["replicaID"] as? String, CloudKitStaffSetupPolicy.canonicalID(replicaID),
              let membershipID = root["membershipID"] as? String, CloudKitStaffSetupPolicy.canonicalID(membershipID),
              let memberRevision = root["memberRevision"] as? String,
              JobBillingAssignmentSnapshot.validConnectionRevision(memberRevision),
              let memberRole = root["memberRole"] as? String, !memberRole.isEmpty, memberRole.utf8.count <= 128,
              let shareRevision = root["shareRevision"] as? Int, (1...2_147_483_647).contains(shareRevision),
              let projectionPolicy = root["projectionPolicy"] as? String, !projectionPolicy.isEmpty,
              let coverage = root["coverage"] as? [String], coverage == StaffWorkspacePublicationContract.kinds.sorted(),
              let wires = root["records"] as? [[String: Any]], wires.count <= 20_000 else {
            throw StaffReplicaDeliveryError.invalid
        }
        var records: [StaffWorkspaceOperationalView.Record] = []
        var seen = Set<String>()
        for wire in wires {
            guard Set(wire.keys) == ["kind", "id", "revision", "unavailableLinks", "body"],
                  let kind = wire["kind"] as? String, StaffWorkspacePublicationContract.kinds.contains(kind),
                  let id = wire["id"] as? String, CloudKitStaffSetupPolicy.canonicalID(id),
                  let revision = wire["revision"] as? Int, (1..<2_147_483_647).contains(revision),
                  let links = wire["unavailableLinks"] as? [String], links.count <= 64,
                  links.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }),
                  let bodyObject = wire["body"] as? [String: Any], bodyObject.count == 1,
                  seen.insert(kind + ":" + id).inserted else {
                throw StaffReplicaDeliveryError.invalid
            }
            let body: StaffWorkspaceOperationalView.Body
            if kind == "invoice" || kind == "estimate" {
                guard let branch = bodyObject["billing"] as? [String: Any], Set(branch.keys) == ["_0"],
                      let documentObject = branch["_0"] else { throw StaffReplicaDeliveryError.invalid }
                let document = try decode(StaffWorkspaceBillingProjection.Document.self, documentObject)
                guard document.kind == kind, document.id.uuidString.lowercased() == id else {
                    throw StaffReplicaDeliveryError.invalid
                }
                try validateBilling(document)
                body = .billing(document)
            } else {
                guard let branch = bodyObject["operational"] as? [String: Any], Set(branch.keys) == ["_0"],
                      let partitionObject = branch["_0"] as? [String: Any],
                      Set(partitionObject.keys) == ["fields", "unavailableFields", "structuredFields"] else {
                    throw StaffReplicaDeliveryError.invalid
                }
                body = .operational(try validateOperational(kind: kind, partitionObject))
            }
            records.append(.init(kind: kind, id: id, revision: revision, unavailableLinks: links, body: body))
        }
        return StaffWorkspaceOperationalView(
            schema: "staff-workspace-content-v1", selectionID: mount.selectionID,
            contentSHA256: mount.contentSHA256, sourceSequence: mount.sourceSequence,
            companyID: companyID, environment: environment, replicaID: replicaID,
            membershipID: membershipID, memberRevision: memberRevision, memberRole: memberRole,
            shareRevision: shareRevision, projectionPolicy: projectionPolicy, coverage: coverage,
            records: records)
    }

    /// Reject forged billing bodies that strip unavailable markers and invent empty scalars.
    private static func validateBilling(_ document: StaffWorkspaceBillingProjection.Document) throws {
        let fieldKeys = Set(document.fields.keys)
        let unavailableKeys = Set(document.unavailableFields.keys)
        guard fieldKeys.isDisjoint(with: unavailableKeys) else { throw StaffReplicaDeliveryError.invalid }
        guard document.unavailableFields.values.allSatisfy({
            $0 == .roleRestricted || $0 == .serviceOnly
        }) else { throw StaffReplicaDeliveryError.invalid }
        if document.kind == "invoice" {
            guard invoiceServiceOnly.isDisjoint(with: fieldKeys),
                  invoiceServiceOnly.isSubset(of: unavailableKeys),
                  invoiceServiceOnly.allSatisfy({ document.unavailableFields[$0] == .serviceOnly }) else {
                throw StaffReplicaDeliveryError.invalid
            }
        }
        for name in unavailableKeys {
            guard document.fields[name] == nil else { throw StaffReplicaDeliveryError.invalid }
        }
    }

    private static func validateOperational(kind: String, _ object: [String: Any]) throws -> StaffWorkspaceOperationalView.OperationalPartition {
        let fields = try decode([String: StaffWorkspaceValue].self, object["fields"]!)
        let unavailable = try decode([String: StaffWorkspaceBillingProjection.Unavailable].self, object["unavailableFields"]!)
        guard let evidenceObject = object["structuredFields"] as? [String: Any] else { throw StaffReplicaDeliveryError.invalid }
        let fieldKeys = Set(fields.keys)
        let unavailableKeys = Set(unavailable.keys)
        let structuredKeys = Set(evidenceObject.keys)
        let allowedStructured = structuredByKind[kind, default: []]
        guard fieldKeys.isDisjoint(with: unavailableKeys),
              fieldKeys.isDisjoint(with: structuredKeys),
              unavailableKeys.isDisjoint(with: structuredKeys),
              fieldKeys.allSatisfy({ !$0.hasSuffix("JSON") }),
              structuredKeys.isSubset(of: allowedStructured),
              unavailable.values.allSatisfy({ $0 == .roleRestricted || $0 == .serviceOnly }) else {
            throw StaffReplicaDeliveryError.invalid
        }
        var structured: [String: Data] = [:]
        for (name, value) in evidenceObject {
            guard let disclosure = value as? [String: Any] else { throw StaffReplicaDeliveryError.invalid }
            if Set(disclosure.keys) == ["notRecorded"] {
                guard let empty = disclosure["notRecorded"] as? [String: Any], empty.isEmpty else {
                    throw StaffReplicaDeliveryError.invalid
                }
            } else if Set(disclosure.keys) == ["recorded"] {
                guard let box = disclosure["recorded"] as? [String: Any], Set(box.keys) == ["_0"],
                      box["_0"] != nil else { throw StaffReplicaDeliveryError.invalid }
            } else {
                throw StaffReplicaDeliveryError.invalid
            }
            structured[name] = try JSONSerialization.data(withJSONObject: disclosure, options: [.sortedKeys])
        }
        for name in unavailableKeys {
            guard fields[name] == nil, evidenceObject[name] == nil else { throw StaffReplicaDeliveryError.invalid }
        }
        return .init(fields: fields, unavailableFields: unavailable, structuredFields: structured)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
        } catch {
            throw StaffReplicaDeliveryError.invalid
        }
    }
}
