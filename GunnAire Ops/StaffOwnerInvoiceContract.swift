import Foundation

enum StaffOwnerInvoiceError: Error, LocalizedError {
    case changed, manual, incompatible, otherDevice, missing, storage
    var errorDescription: String? {
        switch self {
        case .changed: "Invoice or catalog details changed. Check the request again before approving."
        case .manual: "Itemize the existing manual invoice amount before adding this work. The original balance was kept."
        case .incompatible: "This item already has different sold prices, package details or system assignments. Review the original invoice; its existing lines were kept."
        case .otherDevice: "Recover this approved request on its original office device and account. No second invoice or item was created."
        case .missing: "The original invoice, customer, system or catalog record is not available on this device yet. Sync and try again."
        case .storage: "The original approval could not be saved or verified. Keep this app installed and retry."
        }
    }
}

struct StaffOwnerInvoicePage: Codable {
    let schema, companyID, environment, replicaID: String
    let commandIDs: [String]
    let nextCursor: String?
    enum CodingKeys: String, CodingKey { case schema, companyID, environment, replicaID, commandIDs, nextCursor }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema); try c.encode(companyID, forKey: .companyID)
        try c.encode(environment, forKey: .environment); try c.encode(replicaID, forKey: .replicaID)
        try c.encode(commandIDs, forKey: .commandIDs); try c.encode(nextCursor, forKey: .nextCursor)
    }
    func validate(_ scope: StaffReplicaSourceScope, after: String?) throws {
        guard schema == StaffInvoiceRequest.schema, companyID == scope.binding.companyID.uuidString.lowercased(),
              environment == scope.binding.environment, replicaID == scope.binding.replicaID.uuidString.lowercased(),
              commandIDs.count <= 50, commandIDs == Set(commandIDs).sorted(),
              commandIDs.allSatisfy({ CloudKitStaffSetupPolicy.canonicalID($0) && $0 > (after ?? "") }),
              nextCursor == nil || (commandIDs.count == 50 && nextCursor == commandIDs.last)
        else { throw StaffReplicaSourceSyncError.invalid }
    }
}

struct StaffOwnerInvoiceReview: Codable, Equatable, Identifiable {
    let schema: String
    let request: StaffInvoiceRequest
    let receipt: StaffInvoiceReceipt
    let baseInvoice: StaffWorkspacePublishedRecord
    let baseInvoiceSHA256: String
    let baseItem: StaffWorkspacePublishedRecord?
    let baseItemSHA256: String?
    let currentInvoice: StaffWorkspacePublishedRecord?
    let currentItem: StaffWorkspacePublishedRecord?
    let invoiceUnchanged, itemUnchanged: Bool
    let currentSourceSequence: Int
    let sourceUnchanged: Bool
    var id: String { request.commandID }
    enum CodingKeys: String, CodingKey {
        case schema, request, receipt, baseInvoice, baseInvoiceSHA256, baseItem, baseItemSHA256
        case currentInvoice, currentItem, invoiceUnchanged, itemUnchanged, currentSourceSequence, sourceUnchanged
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema); try c.encode(request, forKey: .request); try c.encode(receipt, forKey: .receipt)
        try c.encode(baseInvoice, forKey: .baseInvoice); try c.encode(baseInvoiceSHA256, forKey: .baseInvoiceSHA256)
        try c.encode(baseItem, forKey: .baseItem); try c.encode(baseItemSHA256, forKey: .baseItemSHA256)
        try c.encode(currentInvoice, forKey: .currentInvoice); try c.encode(currentItem, forKey: .currentItem)
        try c.encode(invoiceUnchanged, forKey: .invoiceUnchanged); try c.encode(itemUnchanged, forKey: .itemUnchanged)
        try c.encode(currentSourceSequence, forKey: .currentSourceSequence); try c.encode(sourceUnchanged, forKey: .sourceUnchanged)
    }
    func validate(_ scope: StaffReplicaSourceScope) throws {
        try request.validate(); try baseInvoice.validate(scope)
        guard let share = UUID(uuidString: receipt.shareID), SharedTimeError.validEmail(receipt.actorEmail) else { throw StaffReplicaSourceSyncError.invalid }
        try receipt.validate(request: request, email: receipt.actorEmail, plan: share)
        guard schema == StaffInvoiceRequest.schema, baseInvoice.kind == "invoice", !baseInvoice.deleted,
              baseInvoice.id == request.origin.invoiceID, baseInvoice.revision == request.origin.invoiceRevision,
              baseInvoice.companyID == request.origin.companyID, baseInvoice.environment == request.origin.environment,
              baseInvoice.replicaID == request.origin.replicaID,
              baseInvoice.fields["customer"] == .identifier(UUID(uuidString: request.origin.customerID)!),
              baseInvoice.fields["serviceCallID"] == (request.origin.jobID.flatMap(UUID.init(uuidString:)).map(StaffWorkspaceValue.identifier) ?? .null),
              JobBillingAssignmentSnapshot.validConnectionRevision(baseInvoiceSHA256),
              (request.origin.sourceSequence..<2_147_483_647).contains(currentSourceSequence),
              invoiceUnchanged == (currentInvoice == baseInvoice), itemUnchanged == (currentItem == baseItem),
              sourceUnchanged == (currentSourceSequence == request.origin.sourceSequence && invoiceUnchanged && itemUnchanged)
        else { throw StaffReplicaSourceSyncError.invalid }
        for record in [currentInvoice, baseItem, currentItem].compactMap({ $0 }) { try record.validate(scope) }
        if let currentInvoice {
            guard currentInvoice.kind == "invoice", currentInvoice.id == baseInvoice.id, currentInvoice.revision >= baseInvoice.revision else { throw StaffReplicaSourceSyncError.invalid }
        }
        if request.line.kind == "new" {
            guard baseItem == nil, baseItemSHA256 == nil, currentItem == nil else { throw StaffReplicaSourceSyncError.invalid }
        } else {
            guard let baseItem, !baseItem.deleted, baseItem.kind == "item", baseItem.id == request.line.itemID,
                  baseItem.revision == request.line.itemRevision,
                  baseItemSHA256.map(JobBillingAssignmentSnapshot.validConnectionRevision) == true else { throw StaffReplicaSourceSyncError.invalid }
            try StaffOwnerInvoiceEvidence.match(request.line, fields: baseItem.fields)
            if let currentItem {
                guard currentItem.kind == "item", currentItem.id == baseItem.id, currentItem.revision >= baseItem.revision else { throw StaffReplicaSourceSyncError.invalid }
            }
        }
    }
}

struct StaffOwnerInvoiceProposal: Codable, Equatable {
    static let schema = "staff-owner-invoice-application-v1"
    static let changedFields = Set("catalogSnapshotJSON lineItemSummary amount salesTaxAmount taxCalculationStatusRawValue taxCalculatedAt quickBooksSyncStatus quickBooksSyncDetail customerSignatureName customerSignatureImageBase64 customerSignedAt".split(separator: " ").map(String.init))
    let schema, companyID, environment, replicaID, commandID, operationID, ownerStoreID: String
    let request: StaffInvoiceRequest
    let expectedInvoice: StaffWorkspacePublishedRecord
    let invoiceFields: [String: StaffWorkspaceValue]
    let newItemFields: [String: StaffWorkspaceValue]?
    let dependencies: [StaffWorkspacePublishedRecord]
    let reviewed: Bool
    let reason: String
    enum CodingKeys: String, CodingKey {
        case schema, companyID, environment, replicaID, commandID, operationID, ownerStoreID
        case request, expectedInvoice, invoiceFields, newItemFields, dependencies, reviewed, reason
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema); try c.encode(companyID, forKey: .companyID)
        try c.encode(environment, forKey: .environment); try c.encode(replicaID, forKey: .replicaID)
        try c.encode(commandID, forKey: .commandID); try c.encode(operationID, forKey: .operationID); try c.encode(ownerStoreID, forKey: .ownerStoreID)
        try c.encode(request, forKey: .request); try c.encode(expectedInvoice, forKey: .expectedInvoice)
        try c.encode(invoiceFields, forKey: .invoiceFields); try c.encode(newItemFields, forKey: .newItemFields)
        try c.encode(dependencies, forKey: .dependencies); try c.encode(reviewed, forKey: .reviewed); try c.encode(reason, forKey: .reason)
    }
    var confirmation: StaffOwnerInvoiceConfirmation {
        .init(schema: schema, companyID: companyID, environment: environment, replicaID: replicaID,
              commandID: commandID, operationID: operationID, ownerStoreID: ownerStoreID)
    }
    func validate(_ scope: StaffReplicaSourceScope, original: StaffOwnerInvoiceReview? = nil) throws {
        try request.validate(); try expectedInvoice.validate(scope); try confirmation.validate()
        guard reviewed, ownerStoreID == scope.storeUUID.lowercased(), expectedInvoice.kind == "invoice", !expectedInvoice.deleted,
              expectedInvoice.id == request.origin.invoiceID, expectedInvoice.revision < 2_147_483_646,
              companyID == request.origin.companyID, companyID == expectedInvoice.companyID,
              environment == request.origin.environment, environment == expectedInvoice.environment,
              replicaID == request.origin.replicaID, replicaID == expectedInvoice.replicaID, commandID == request.commandID,
              StaffInvoiceLine.text(reason, maximum: 2000), dependencies.count <= 1000,
              Set(dependencies.map(\.key)).count == dependencies.count,
              expectedInvoice.fields.allSatisfy({ Self.changedFields.contains($0.key) || invoiceFields[$0.key] == $0.value }),
              expectedInvoice.fields["customer"] == .identifier(UUID(uuidString: request.origin.customerID)!),
              expectedInvoice.fields["serviceCallID"] == (request.origin.jobID.flatMap(UUID.init(uuidString:)).map(StaffWorkspaceValue.identifier) ?? .null),
              [.text("unpaid"), .text("overdue")].contains(expectedInvoice.fields["status"]),
              ["finalizedAt", "projectMilestoneID", "milestoneDraftReceiptJSON"].allSatisfy({ expectedInvoice.fields[$0] == .null }),
              invoiceFields["salesTaxAmount"] == .number(0), invoiceFields["taxCalculatedAt"] == .null,
              ["customerSignatureName", "customerSignatureImageBase64", "customerSignedAt"].allSatisfy({ invoiceFields[$0] == .null }),
              invoiceFields["quickBooksSyncStatus"] == .text(expectedInvoice.fields["quickBooksID"] == .null ? "pending" : "balance_needs_refresh"),
              (request.line.kind == "new") == (newItemFields != nil)
        else { throw StaffReplicaSourceSyncError.invalid }
        if let original {
            try original.validate(scope)
            guard original.request == request, original.currentInvoice == expectedInvoice else { throw StaffReplicaSourceSyncError.invalid }
        }
        try StaffWorkspacePublicationContract.validate(.init(version: 1, kind: "invoice", id: UUID(uuidString: expectedInvoice.id)!, fields: invoiceFields))
        for record in dependencies {
            try record.validate(scope)
            guard !record.deleted, ["customer", "job", "location", "equipment", "item"].contains(record.kind) else { throw StaffReplicaSourceSyncError.invalid }
        }
        if let fields = newItemFields {
            try StaffWorkspacePublicationContract.validate(.init(version: 1, kind: "item", id: UUID(uuidString: request.line.itemID)!, fields: fields))
            try StaffOwnerInvoiceEvidence.match(request.line, fields: fields)
            guard fields["name"] == .text(request.line.name), fields["unitPrice"] == .number(request.line.unitPrice),
                  fields["isTaxable"] == .flag(request.line.isTaxable), fields["itemTypeRawValue"] == .text(request.line.itemType),
                  fields["quickBooksID"] == .null, fields["quickBooksSyncStatus"] == .text("pending"),
                  fields["pricebookReviewStatusRawValue"] == .text("approved"), fields["pricebookReviewedByEmail"] == .text(scope.actorEmail),
                  fields["tracksInventory"] == .flag(false) else { throw StaffReplicaSourceSyncError.invalid }
            for (key, value) in fields where key.hasPrefix("quickBooks") && !["quickBooksSyncStatus", "quickBooksSyncDetail"].contains(key) {
                guard value == .null else { throw StaffReplicaSourceSyncError.invalid }
            }
            guard case .text(let author) = fields["pricebookCreatedByEmail"], SharedTimeError.validEmail(author),
                  case .date(let reviewedAt) = fields["pricebookReviewedAt"] else { throw StaffReplicaSourceSyncError.invalid }
            if let original {
                guard author == original.receipt.actorEmail,
                      let recorded = StaffOwnerFieldEditApplication.instant(original.receipt.createdAt),
                      reviewedAt >= recorded.addingTimeInterval(-300) else { throw StaffReplicaSourceSyncError.invalid }
            }
        }
        guard case .text(let raw) = invoiceFields["catalogSnapshotJSON"], let snapshot = try CatalogSnapshotPayload.read(raw) else { throw StaffReplicaSourceSyncError.invalid }
        try CatalogSnapshotPayload.validateBusinessEvidence(snapshot)
        try StaffOwnerInvoiceEvidence.validate(self, snapshot: snapshot, scope: scope)
        guard try StaffInvoiceHTTPPolicy.asciiWireBytes(self) <= StaffOwnerInvoiceTransport.maximumRequestBytes else { throw StaffReplicaSourceSyncError.invalid }
    }
}

struct StaffOwnerInvoiceConfirmation: Codable, Equatable {
    let schema, companyID, environment, replicaID, commandID, operationID, ownerStoreID: String
    func validate() throws {
        guard schema == StaffOwnerInvoiceProposal.schema, [companyID, replicaID, commandID, operationID, ownerStoreID].allSatisfy(CloudKitStaffSetupPolicy.canonicalID),
              ["development", "production"].contains(environment) else { throw StaffReplicaSourceSyncError.invalid }
    }
}
struct StaffOwnerInvoiceApplication: Codable, Equatable {
    let schema, companyID, environment, replicaID, commandID, operationID, ownerStoreID, ownerEmail, invoiceID, preparedAt, state: String
    let publishedAt: String?
    let qboPublished: Bool
    let proposalSHA256: String
    enum CodingKeys: String, CodingKey { case schema, companyID, environment, replicaID, commandID, operationID, ownerStoreID, ownerEmail, invoiceID, preparedAt, state, publishedAt, qboPublished, proposalSHA256 }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema); try c.encode(companyID, forKey: .companyID); try c.encode(environment, forKey: .environment)
        try c.encode(replicaID, forKey: .replicaID); try c.encode(commandID, forKey: .commandID); try c.encode(operationID, forKey: .operationID)
        try c.encode(ownerStoreID, forKey: .ownerStoreID); try c.encode(ownerEmail, forKey: .ownerEmail); try c.encode(invoiceID, forKey: .invoiceID)
        try c.encode(preparedAt, forKey: .preparedAt); try c.encode(state, forKey: .state); try c.encode(publishedAt, forKey: .publishedAt)
        try c.encode(qboPublished, forKey: .qboPublished); try c.encode(proposalSHA256, forKey: .proposalSHA256)
    }
    func validate(_ proposal: StaffOwnerInvoiceProposal, scope: StaffReplicaSourceScope) throws {
        try proposal.validate(scope)
        guard schema == proposal.schema, companyID == proposal.companyID, environment == proposal.environment, replicaID == proposal.replicaID,
              commandID == proposal.commandID, operationID == proposal.operationID, ownerStoreID == proposal.ownerStoreID,
              ownerEmail == scope.actorEmail, invoiceID == proposal.request.origin.invoiceID, !qboPublished,
              JobBillingAssignmentSnapshot.validConnectionRevision(proposalSHA256), let prepared = StaffOwnerFieldEditApplication.instant(preparedAt),
              (state == "prepared" && publishedAt == nil) || (state == "published" && publishedAt.flatMap(StaffOwnerFieldEditApplication.instant).map({ $0 >= prepared }) == true)
        else { throw StaffReplicaSourceSyncError.invalid }
        if let fields = proposal.newItemFields {
            guard case .date(let reviewedAt) = fields["pricebookReviewedAt"],
                  reviewedAt <= prepared.addingTimeInterval(300) else { throw StaffReplicaSourceSyncError.invalid }
        }
    }
}
struct StaffOwnerInvoiceSavedApplication: Codable, Equatable {
    let proposal: StaffOwnerInvoiceProposal
    let receipt: StaffOwnerInvoiceApplication
}
struct StaffOwnerInvoiceApplicationEnvelope: Codable {
    let schema: String
    let application: StaffOwnerInvoiceSavedApplication?
    enum CodingKeys: String, CodingKey { case schema, application }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema); try c.encode(application, forKey: .application)
    }
}

enum StaffOwnerInvoiceTransport {
    static let root = "/api/workspace/invoice-applications"
    static let reviewRoot = "/api/workspace/invoice-line-requests"
    static let maximumRequestBytes = 7 * 1024 * 1024
    static let maximumResponseBytes = 32 * 1024 * 1024 // Review contains original and current full records.
    static func path(_ scope: StaffReplicaSourceScope, id: String? = nil, application: Bool = false, after: String? = nil) -> String {
        var url = URLComponents(); url.path = (application ? root : reviewRoot) + (id.map { "/" + $0 } ?? "")
        url.queryItems = [.init(name: "companyID", value: scope.binding.companyID.uuidString.lowercased()),
                          .init(name: "environment", value: scope.binding.environment), .init(name: "replicaID", value: scope.binding.replicaID.uuidString.lowercased())]
        if let after { url.queryItems?.append(.init(name: "after", value: after)) }; return url.string!
    }
    static func allows(path: String, method: String, body: Data?) -> Bool {
        guard let url = URLComponents(string: path), url.scheme == nil, url.host == nil, url.fragment == nil,
              url.path == url.percentEncodedPath else { return false }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4, Array(parts.prefix(3)) == ["", "api", "workspace"],
              ["invoice-line-requests", "invoice-applications"].contains(parts[3]) else { return false }
        if method == "GET" {
            guard body == nil, parts.count == 4 || parts.count == 5,
                  parts[3] != "invoice-applications" || parts.count == 5,
                  parts.count != 5 || CloudKitStaffSetupPolicy.canonicalID(parts[4]), let items = url.queryItems,
                  Set(items.map(\.name)).count == items.count else { return false }
            let keys = Set(items.map(\.name)), required = Set(["companyID", "environment", "replicaID"])
            guard keys == required || (parts.count == 4 && parts[3] == "invoice-line-requests" && keys == required.union(["after"])) else { return false }
            return items.allSatisfy { item in
                guard let value = item.value else { return false }
                return item.name == "environment" ? ["development", "production"].contains(value) : CloudKitStaffSetupPolicy.canonicalID(value)
            }
        }
        guard method == "POST", url.query == nil, parts.count == 6, parts[3] == "invoice-applications",
              CloudKitStaffSetupPolicy.canonicalID(parts[4]), let body, body.count <= maximumRequestBytes else { return false }
        if parts[5] == "confirm" {
            guard let value = try? StaffWorkspacePublicationContract.decode(StaffOwnerInvoiceConfirmation.self, from: body, maximum: maximumRequestBytes),
                  value.commandID == parts[4], (try? value.validate()) != nil else { return false }
            return true
        }
        guard parts[5] == "prepare", let value = try? StaffWorkspacePublicationContract.decode(StaffOwnerInvoiceProposal.self, from: body, maximum: maximumRequestBytes),
              value.commandID == parts[4], value.reviewed, (try? value.confirmation.validate()) != nil,
              (try? value.request.validate()) != nil, (try? StaffInvoiceHTTPPolicy.asciiWireBytes(value)).map({ $0 <= maximumRequestBytes }) == true else { return false }
        return true
    }
}
