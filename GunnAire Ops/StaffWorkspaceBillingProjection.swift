import Foundation

/// Read-only disclosure values are deliberately not optional owner values.
/// A restricted cost is neither zero nor an unrecorded cost, even when the
/// original owner record happens not to contain one.
enum StaffBillingDisclosure<Value: Codable & Equatable>: Codable, Equatable {
    case recorded(Value)
    case notRecorded
    case restricted
}

/// A separate presentation/transport model. Never decode it as Invoice,
/// Estimate or CatalogLineItemSnapshot and never use it to publish or charge.
struct StaffWorkspaceBillingProjection: Codable, Equatable {
    enum Failure: Error, Equatable { case access, identity, scope, coverage, invalid }
    enum Unavailable: String, Codable { case roleRestricted, serviceOnly }
    enum Catalog: Codable, Equatable {
        case notRecorded
        case saved(SavedCatalog)
    }
    struct SavedCatalog: Codable, Equatable {
        let lines: [Line]
        let discount: AuthorizedDocumentDiscount?
        let taxAddresses: BillingTaxAddressContext?
    }
    struct Line: Codable, Equatable {
        let catalogItemID: UUID
        let itemTypeRawValue: String?
        let quickBooksItemID: StaffBillingDisclosure<String>
        let name: String
        let description: String?
        let sku: String?
        let pricebookUnitPrice: Double
        let unitPrice: Double
        let purchaseCost: StaffBillingDisclosure<Double>
        let isTaxable: Bool
        let quantity: Double
        let extendedAmount: Double
        let catalogUpdatedAt: Date
        let priceAdjustmentReason: String?
        let priceAdjustmentAuthorizedByEmail: String?
        let priceAdjustmentAuthorizedAt: Date?
        let servicedEquipment: CatalogLineEquipmentSnapshot?
        let assembly: Assembly?
        let bundle: SoldBundle?
    }
    struct Assembly: Codable, Equatable {
        struct Component: Codable, Equatable {
            let itemID: UUID
            let name: String
            let sku: String?
            let quantity: Double
            let purchaseCost: StaffBillingDisclosure<Double>
            let tracksInventory: Bool
        }
        let assemblyItemID: UUID
        let name: String
        let revision: Int
        let presentation: CatalogAssemblyPresentation
        let components: [Component]
    }
    struct SoldBundle: Codable, Equatable {
        struct Member: Codable, Equatable {
            let id: UUID
            let line: Line
            let tracksInventory: Bool
        }
        let scope: StaffBillingDisclosure<QuickBooksChangeHistoryScope>
        let printGroupedItems: Bool
        let members: [Member]
    }
    struct Document: Codable, Equatable {
        let kind: String
        let id: UUID
        /// Exact original scalar values; no rewritten totals, status, approvals,
        /// signatures or fabricated default values.
        let fields: [String: StaffWorkspaceValue]
        let unavailableFields: [String: Unavailable]
        /// Replaces catalogSnapshotJSON, never carries its raw owner text.
        let catalog: Catalog
    }

    let schema: String
    let companyID: UUID
    let environment: String
    let replicaID: UUID
    let membershipID: UUID
    let memberRevision: String
    let shareRevision: Int
    let projectionPolicy: String
    let sourceSequence: Int
    let documents: [Document]

    /// These field lists must match the complete, pinned native schema. A new
    /// field cannot inherit a disclosure grant merely by being Codable.
    private static let invoiceFields: Set<String> = [
        "quickBooksSyncStatus", "workTypeRaw", "lineItemSummary", "amount", "salesTaxAmount", "status", "createdAt",
        "serviceCallID", "serviceLocationID", "siteAddress", "quickBooksID", "quickBooksBalanceDue", "quickBooksLastSyncedAt",
        "taxCalculationStatusRawValue", "taxCalculatedAt", "projectMilestoneID", "projectMilestoneSequence", "projectMilestoneTitle",
        "projectContractAmount", "projectBillingPercent", "dueDate", "notes", "customerSignatureName", "customerSignatureImageBase64",
        "customerSignedAt", "completionNotes", "finalizedAt", "customer",
    ]
    private static let estimateFields: Set<String> = [
        "proposalIsRecommended", "lineItemSummary", "amount", "salesTaxAmount", "status", "createdAt", "serviceCallID",
        "serviceLocationID", "siteAddress", "scheduledServiceCallID", "parentEstimateID", "changeOrderReason", "proposalGroupID",
        "proposalOption", "quickBooksID", "taxCalculationStatusRawValue", "taxCalculatedAt", "customerApprovedByName",
        "customerApprovedAt", "customerApprovalMethodRaw", "customerApprovalReference", "customerApprovalRecordedByEmail",
        "customerApprovalSignatureImageBase64", "notes", "customer",
    ]
    private static let serviceFields: Set<String> = ["quickBooksSyncDetail", "quickBooksPaymentReviewJSON", "milestoneDraftReceiptJSON"]

    static func validateCoverage() throws {
        try StaffWorkspacePublicationContract.validateCatalog()
        guard invoiceFields.union(serviceFields).union(["catalogSnapshotJSON"]) == StaffWorkspaceModelCodecs.invoice.fieldNames,
              invoiceFields.isDisjoint(with: serviceFields),
              estimateFields.union(["catalogSnapshotJSON"]) == StaffWorkspaceModelCodecs.estimate.fieldNames else {
            throw Failure.coverage
        }
    }

    /// Owner-side preparation from the complete original graph and a current
    /// server plan. The caller must still fence its session/source sequence and
    /// obtain independent CloudKit proof. This creates no staff lease, sends no
    /// data, and does not make this billing slice a complete staff workspace.
    static func prepare(source: StaffWorkspaceSourceJournal, expectedScope: StaffReplicaSourceScope, plan: CloudKitStaffSharePlan,
                        workspace: CompanyWorkspaceIdentity, sourceSequence: Int, now: Date = Date()) throws -> Self {
        try plan.validate(workspace: workspace, now: now)
        guard expectedScope.binding == workspace.binding(for: plan.environment) else { throw Failure.scope }
        guard plan.state == "accepted", plan.businessAccessEligible, !plan.reviewRequired, !plan.cloudKitRevocationRequired,
              let role = AppUserRole(rawValue: plan.memberRole),
              (1..<2_147_483_647).contains(sourceSequence) else { throw Failure.access }
        try validateCoverage()
        // Validates all original scalar, list and nested billing/customer links
        // before filtering. A bad private row cannot become a partial success.
        try source.validate(expectedScope)
        let records = source.records
        // Company lineage is a source invariant, not conditional on which
        // role happens to see a document. Inspect hidden documents too.
        var snapshots: [StaffWorkspaceRecordKey: CatalogSnapshotPayload.Snapshot] = [:]
        for record in records where record.kind == "invoice" || record.kind == "estimate" {
            if record.fields["catalogSnapshotJSON"] == .null { continue }
            let text = try String.fromStaffValue(record.fields["catalogSnapshotJSON"]!)
            guard let snapshot = try CatalogSnapshotPayload.read(text) else { throw Failure.invalid }
            guard snapshot.lines.allSatisfy({ $0.bundle.map { $0.scope.companyID == plan.companyID } ?? true }) else {
                throw Failure.scope
            }
            snapshots[.init(kind: record.kind, id: record.id)] = snapshot
        }
        let financial = role == .admin || role == .accounting
        let assigned = try assignedJobs(records, role: role, email: plan.memberEmail)
        let documents = try records.filter { record in
            switch (role, record.kind) {
            case (.admin, "invoice"), (.admin, "estimate"), (.accounting, "invoice"), (.dispatcher, "estimate"): return true
            case (.fieldTechnician, "invoice"):
                return try identifier(record, "serviceCallID").map { assigned.contains($0) } ?? false
            default: return false
            }
        }.sorted { ($0.kind, $0.id.uuidString) < ($1.kind, $1.id.uuidString) }.map { record in
            let allowed = record.kind == "invoice" ? invoiceFields : estimateFields
            var fields: [String: StaffWorkspaceValue] = [:]
            var unavailable: [String: Unavailable] = [:]
            for name in allowed {
                if name == "quickBooksID" && !financial { unavailable[name] = .roleRestricted }
                else { fields[name] = record.fields[name]! }
            }
            if record.kind == "invoice" { for name in serviceFields { unavailable[name] = .serviceOnly } }
            let catalog: Catalog
            if record.fields["catalogSnapshotJSON"] == .null { catalog = .notRecorded }
            else {
                guard let snapshot = snapshots[.init(kind: record.kind, id: record.id)] else { throw Failure.invalid }
                // The graph already validated its original totals, approvals,
                // equipment lineage, catalog IDs and nested business evidence.
                let lines = try snapshot.lines.map { try project($0, financial: financial, companyID: plan.companyID) }
                catalog = .saved(.init(lines: lines, discount: snapshot.discount, taxAddresses: snapshot.taxAddresses))
            }
            return Document(kind: record.kind, id: record.id, fields: fields, unavailableFields: unavailable, catalog: catalog)
        }
        let result = Self(schema: "staff-billing-view-v1", companyID: plan.companyID, environment: plan.environment,
            replicaID: plan.replicaID, membershipID: plan.id, memberRevision: plan.memberRevision, shareRevision: plan.revision,
            projectionPolicy: plan.projectionPolicy, sourceSequence: sourceSequence, documents: documents)
        guard try StaffWorkspacePublicationContract.encode(result).count <= 32 * 1024 * 1024 else { throw Failure.invalid }
        return result
    }

    /// Verify an encoded preparation against the original source and exact
    /// plan, rather than trusting sender-declared role or unavailable markers.
    /// Not a network receiver: a staff receiver cannot possess the owner graph.
    static func verify(_ bytes: Data, source: StaffWorkspaceSourceJournal, expectedScope: StaffReplicaSourceScope, plan: CloudKitStaffSharePlan,
                       workspace: CompanyWorkspaceIdentity, sourceSequence: Int, now: Date = Date()) throws -> Self {
        let decoded = try StaffWorkspacePublicationContract.decode(Self.self, from: bytes, maximum: 32 * 1024 * 1024)
        let expected = try prepare(source: source, expectedScope: expectedScope, plan: plan, workspace: workspace, sourceSequence: sourceSequence, now: now)
        guard decoded == expected else { throw Failure.invalid }
        return decoded
    }

    private static func disclose<T: Codable & Equatable>(_ value: T?, financial: Bool) -> StaffBillingDisclosure<T> {
        guard financial else { return .restricted }
        return value.map(StaffBillingDisclosure.recorded) ?? .notRecorded
    }

    private static func project(_ line: CatalogLineItemSnapshot, financial: Bool, companyID: UUID) throws -> Line {
        let assembly = line.assembly.map { original in
            Assembly(assemblyItemID: original.assemblyItemID, name: original.name, revision: original.revision,
                presentation: original.presentation, components: original.components.map {
                    .init(itemID: $0.itemID, name: $0.name, sku: $0.sku, quantity: $0.quantity,
                          purchaseCost: disclose($0.purchaseCost, financial: financial), tracksInventory: $0.tracksInventory)
                })
        }
        let bundle = try line.bundle.map { original in
            guard original.scope.companyID == companyID else { throw Failure.scope }
            return SoldBundle(scope: disclose(original.scope, financial: financial), printGroupedItems: original.printGroupedItems,
                members: try original.members.map {
                    .init(id: $0.id, line: try project($0.line, financial: financial, companyID: companyID), tracksInventory: $0.tracksInventory)
                })
        }
        return Line(catalogItemID: line.catalogItemID, itemTypeRawValue: line.itemTypeRawValue,
            quickBooksItemID: disclose(line.quickBooksItemID, financial: financial), name: line.name,
            description: line.description, sku: line.sku, pricebookUnitPrice: line.pricebookUnitPrice, unitPrice: line.unitPrice,
            purchaseCost: disclose(line.purchaseCost, financial: financial), isTaxable: line.isTaxable, quantity: line.quantity,
            extendedAmount: line.extendedAmount, catalogUpdatedAt: line.catalogUpdatedAt,
            priceAdjustmentReason: line.priceAdjustmentReason, priceAdjustmentAuthorizedByEmail: line.priceAdjustmentAuthorizedByEmail,
            priceAdjustmentAuthorizedAt: line.priceAdjustmentAuthorizedAt, servicedEquipment: line.servicedEquipment, assembly: assembly, bundle: bundle)
    }

    private static func identifier(_ record: StaffWorkspaceModelRecord, _ field: String) throws -> UUID? {
        guard let value = record.fields[field] else { throw Failure.invalid }
        return value == .null ? nil : try UUID.fromStaffValue(value)
    }

    private static func assignedJobs(_ records: [StaffWorkspaceModelRecord], role: AppUserRole, email: String) throws -> Set<UUID> {
        guard role == .fieldTechnician else { return [] }
        let actor = AppAccess.normalizedEmail(email)
        let matches = try records.filter { record in
            guard record.kind == "technician", record.fields["contactInfo"] != .null else { return false }
            return try AppAccess.normalizedEmail(String.fromStaffValue(record.fields["contactInfo"]!)) == actor
        }
        // Missing/ambiguous mapping is pending identity, not an empty invoice
        // list or a grant to every technician with a matching display name.
        guard matches.count == 1, let technicianID = matches.first?.id else { throw Failure.identity }
        var result = Set<UUID>()
        for record in records where record.kind == "job" {
            let lead = try identifier(record, "assignedTechnician")
            let crew: [UUID]
            if record.fields["additionalTechnicianIDsJSON"] == .null { crew = [] }
            else {
                let text = try String.fromStaffValue(record.fields["additionalTechnicianIDsJSON"]!)
                crew = try JSONDecoder().decode([UUID].self, from: Data(text.utf8))
            }
            if lead == technicianID || crew.contains(technicianID) { result.insert(record.id) }
        }
        return result
    }
}
