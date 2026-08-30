import Foundation

enum EquipmentWarrantyClaimStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case requested
    case submitted
    case approved
    case denied
    case closed
    case cancelled

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .requested: "Requested"
        case .submitted: "Submitted"
        case .approved: "Approved"
        case .denied: "Denied"
        case .closed: "Closed"
        case .cancelled: "Cancelled"
        }
    }

    var isOpen: Bool {
        switch self {
        case .requested, .submitted, .approved: true
        case .denied, .closed, .cancelled: false
        }
    }
}

enum EquipmentWarrantyResolution: String, Codable, CaseIterable, Identifiable, Sendable {
    case replacement
    case vendorCredit
    case laborCredit
    case replacementAndCredit

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .replacement: "Replacement part"
        case .vendorCredit: "Part/vendor credit"
        case .laborCredit: "Labor credit"
        case .replacementAndCredit: "Replacement and credit"
        }
    }

    var requiresReplacement: Bool {
        self == .replacement || self == .replacementAndCredit
    }

    var requiresCredit: Bool {
        self == .vendorCredit || self == .laborCredit || self == .replacementAndCredit
    }
}

enum EquipmentWarrantyClaimEventKind: String, Codable, Sendable {
    case requested
    case submitted
    case approved
    case denied
    case replacementReceived
    case creditReceived
    case closed
    case cancelled
}

struct EquipmentWarrantyClaimEvent: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let kind: EquipmentWarrantyClaimEventKind
    let occurredAt: Date
    let actorEmail: String
    let detail: String

    init(
        id: UUID = UUID(),
        kind: EquipmentWarrantyClaimEventKind,
        occurredAt: Date = Date(),
        actorEmail: String,
        detail: String
    ) {
        self.id = id
        self.kind = kind
        self.occurredAt = occurredAt
        self.actorEmail = actorEmail
        self.detail = detail
    }
}

struct EquipmentWarrantyClaim: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var status: EquipmentWarrantyClaimStatus
    var manufacturer: String
    var distributorName: String?
    var equipmentSerialNumberSnapshot: String
    var issueDescription: String
    var failedPartName: String
    var failedPartNumber: String?
    var failedPartSerialNumber: String?
    var quantity: Double
    var originatingServiceCallID: UUID?
    var originalPurchaseOrderID: UUID?
    var originalPurchaseOrderLineID: UUID?
    var evidenceAttachmentIDs: [UUID]
    var claimNumber: String?
    var resolution: EquipmentWarrantyResolution?
    var denialReason: String?
    var expectedPartCreditCents: Int?
    var expectedLaborCreditCents: Int?
    var replacementCatalogItemID: UUID?
    var replacementPartName: String?
    var replacementPartNumber: String?
    var replacementSerialNumber: String?
    var replacementInventoryMovementID: UUID?
    var replacementReceivedAt: Date?
    var actualPartCreditCents: Int?
    var actualLaborCreditCents: Int?
    var vendorCreditReference: String?
    var quickBooksVendorCreditID: String?
    var creditReceivedAt: Date?
    let requestedAt: Date
    let requestedByEmail: String
    var submittedAt: Date?
    var submittedByEmail: String?
    var decidedAt: Date?
    var decidedByEmail: String?
    var closedAt: Date?
    var closedByEmail: String?
    var updatedAt: Date
    var events: [EquipmentWarrantyClaimEvent]

    var shortReference: String {
        claimNumber ?? "Request \(String(id.uuidString.prefix(8)).uppercased())"
    }

    var isRecoveryComplete: Bool {
        guard status == .approved, let resolution else { return false }
        let replacementComplete = replacementReceivedAt != nil && replacementInventoryMovementID != nil
        let totalCreditCents = max(actualPartCreditCents ?? 0, 0) + max(actualLaborCreditCents ?? 0, 0)
        let creditComplete = creditReceivedAt != nil && totalCreditCents > 0 && normalized(vendorCreditReference) != nil
        switch resolution {
        case .replacement:
            return replacementComplete
        case .vendorCredit:
            return creditComplete && (actualPartCreditCents ?? 0) > 0
        case .laborCredit:
            return creditComplete && (actualLaborCreditCents ?? 0) > 0
        case .replacementAndCredit:
            return replacementComplete && creditComplete
        }
    }

    var openAttentionSummary: String? {
        switch status {
        case .requested:
            return "Office submission needed"
        case .submitted:
            return "Manufacturer decision pending"
        case .approved:
            guard let resolution else { return "Approved resolution needs review" }
            if isRecoveryComplete { return "Recovery ready to close" }
            switch resolution {
            case .replacement: return "Replacement part pending"
            case .vendorCredit: return "Vendor credit pending"
            case .laborCredit: return "Labor credit pending"
            case .replacementAndCredit: return "Replacement and credit pending"
            }
        case .denied, .closed, .cancelled:
            return nil
        }
    }

    var totalExpectedCreditCents: Int {
        max(expectedPartCreditCents ?? 0, 0) + max(expectedLaborCreditCents ?? 0, 0)
    }

    var totalActualCreditCents: Int {
        max(actualPartCreditCents ?? 0, 0) + max(actualLaborCreditCents ?? 0, 0)
    }

    mutating func submit(
        claimNumber: String,
        evidenceAttachmentIDs: [UUID],
        actorEmail: String?,
        at date: Date = Date()
    ) throws {
        guard status == .requested else { throw EquipmentWarrantyClaimError.invalidTransition }
        let actor = try Self.requiredActor(actorEmail)
        guard let reference = Self.normalized(claimNumber) else {
            throw EquipmentWarrantyClaimError.claimNumberRequired
        }
        let evidence = Array(Set(evidenceAttachmentIDs)).sorted { $0.uuidString < $1.uuidString }
        guard !evidence.isEmpty else { throw EquipmentWarrantyClaimError.evidenceRequired }
        self.claimNumber = reference
        self.evidenceAttachmentIDs = evidence
        status = .submitted
        submittedAt = date
        submittedByEmail = actor
        updatedAt = date
        events.append(.init(
            kind: .submitted,
            occurredAt: date,
            actorEmail: actor,
            detail: "Submitted to the manufacturer or distributor as \(reference) with \(evidence.count) evidence file\(evidence.count == 1 ? "" : "s")."
        ))
    }

    mutating func recordDecision(
        approved: Bool,
        resolution: EquipmentWarrantyResolution?,
        denialReason: String?,
        expectedPartCreditCents: Int?,
        expectedLaborCreditCents: Int?,
        actorEmail: String?,
        at date: Date = Date()
    ) throws {
        guard status == .submitted else { throw EquipmentWarrantyClaimError.invalidTransition }
        let actor = try Self.requiredActor(actorEmail)
        try Self.validateCreditCents(expectedPartCreditCents)
        try Self.validateCreditCents(expectedLaborCreditCents)
        if approved {
            guard let resolution else { throw EquipmentWarrantyClaimError.resolutionRequired }
            self.resolution = resolution
            self.denialReason = nil
            self.expectedPartCreditCents = expectedPartCreditCents
            self.expectedLaborCreditCents = expectedLaborCreditCents
            status = .approved
            events.append(.init(
                kind: .approved,
                occurredAt: date,
                actorEmail: actor,
                detail: "Claim approved for \(resolution.displayName.lowercased())."
            ))
        } else {
            guard let denialReason = Self.normalized(denialReason) else {
                throw EquipmentWarrantyClaimError.denialReasonRequired
            }
            self.resolution = nil
            self.denialReason = denialReason
            self.expectedPartCreditCents = nil
            self.expectedLaborCreditCents = nil
            status = .denied
            events.append(.init(
                kind: .denied,
                occurredAt: date,
                actorEmail: actor,
                detail: "Claim denied: \(denialReason)"
            ))
        }
        decidedAt = date
        decidedByEmail = actor
        updatedAt = date
    }

    mutating func recordReplacementReceipt(
        catalogItemID: UUID?,
        partName: String,
        partNumber: String?,
        serialNumber: String?,
        inventoryMovementID: UUID,
        actorEmail: String?,
        at date: Date = Date()
    ) throws {
        guard status == .approved, resolution?.requiresReplacement == true else {
            throw EquipmentWarrantyClaimError.invalidTransition
        }
        let actor = try Self.requiredActor(actorEmail)
        guard let partName = Self.normalized(partName) else {
            throw EquipmentWarrantyClaimError.replacementPartRequired
        }
        replacementCatalogItemID = catalogItemID
        replacementPartName = partName
        replacementPartNumber = Self.normalized(partNumber)
        replacementSerialNumber = Self.normalized(serialNumber)
        replacementInventoryMovementID = inventoryMovementID
        replacementReceivedAt = date
        updatedAt = date
        events.append(.init(
            kind: .replacementReceived,
            occurredAt: date,
            actorEmail: actor,
            detail: "Received replacement \(partName) into the inventory ledger."
        ))
    }

    mutating func recordCredit(
        partCreditCents: Int,
        laborCreditCents: Int,
        reference: String,
        quickBooksVendorCreditID: String?,
        actorEmail: String?,
        at date: Date = Date()
    ) throws {
        guard status == .approved, resolution?.requiresCredit == true else {
            throw EquipmentWarrantyClaimError.invalidTransition
        }
        let actor = try Self.requiredActor(actorEmail)
        try Self.validateCreditCents(partCreditCents)
        try Self.validateCreditCents(laborCreditCents)
        guard partCreditCents + laborCreditCents > 0 else {
            throw EquipmentWarrantyClaimError.creditAmountRequired
        }
        if resolution == .vendorCredit, partCreditCents == 0 {
            throw EquipmentWarrantyClaimError.partCreditRequired
        }
        if resolution == .laborCredit, laborCreditCents == 0 {
            throw EquipmentWarrantyClaimError.laborCreditRequired
        }
        guard let reference = Self.normalized(reference) else {
            throw EquipmentWarrantyClaimError.creditReferenceRequired
        }
        actualPartCreditCents = partCreditCents
        actualLaborCreditCents = laborCreditCents
        vendorCreditReference = reference
        self.quickBooksVendorCreditID = Self.normalized(quickBooksVendorCreditID)
        creditReceivedAt = date
        updatedAt = date
        events.append(.init(
            kind: .creditReceived,
            occurredAt: date,
            actorEmail: actor,
            detail: "Recorded \(Self.currency(cents: partCreditCents + laborCreditCents)) of warranty credit under \(reference)."
        ))
    }

    mutating func close(actorEmail: String?, at date: Date = Date()) throws {
        guard status == .approved else { throw EquipmentWarrantyClaimError.invalidTransition }
        guard isRecoveryComplete else { throw EquipmentWarrantyClaimError.recoveryIncomplete }
        let actor = try Self.requiredActor(actorEmail)
        status = .closed
        closedAt = date
        closedByEmail = actor
        updatedAt = date
        events.append(.init(
            kind: .closed,
            occurredAt: date,
            actorEmail: actor,
            detail: "Closed after the approved replacement and/or credit recovery was recorded."
        ))
    }

    mutating func cancel(reason: String, actorEmail: String?, at date: Date = Date()) throws {
        guard status.isOpen else { throw EquipmentWarrantyClaimError.invalidTransition }
        let actor = try Self.requiredActor(actorEmail)
        guard let reason = Self.normalized(reason) else { throw EquipmentWarrantyClaimError.cancellationReasonRequired }
        status = .cancelled
        closedAt = date
        closedByEmail = actor
        updatedAt = date
        events.append(.init(
            kind: .cancelled,
            occurredAt: date,
            actorEmail: actor,
            detail: "Cancelled: \(reason)"
        ))
    }

    private static func validateCreditCents(_ value: Int?) throws {
        guard let value else { return }
        guard value >= 0, value <= 1_000_000_000 else {
            throw EquipmentWarrantyClaimError.invalidCreditAmount
        }
    }

    private static func requiredActor(_ actorEmail: String?) throws -> String {
        guard let actor = normalized(actorEmail), actor.contains("@") else {
            throw EquipmentWarrantyClaimError.actorRequired
        }
        return actor.lowercased()
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }

    private static func currency(cents: Int) -> String {
        (Double(cents) / 100).formatted(.currency(code: "USD"))
    }

    private func normalized(_ value: String?) -> String? {
        Self.normalized(value)
    }
}

struct EquipmentWarrantyClaimRequest: Equatable, Sendable {
    let manufacturer: String
    let distributorName: String?
    let equipmentSerialNumber: String
    let issueDescription: String
    let failedPartName: String
    let failedPartNumber: String?
    let failedPartSerialNumber: String?
    let quantity: Double
    let originatingServiceCallID: UUID?
    let originalPurchaseOrderID: UUID?
    let originalPurchaseOrderLineID: UUID?
    let evidenceAttachmentIDs: [UUID]
}

enum EquipmentWarrantyClaimError: Error, Equatable, LocalizedError {
    case actorRequired
    case inactiveEquipment
    case manufacturerRequired
    case equipmentSerialRequired
    case issueRequired
    case issueTooLong
    case failedPartRequired
    case invalidQuantity
    case claimNumberRequired
    case evidenceRequired
    case invalidEvidence
    case resolutionRequired
    case denialReasonRequired
    case replacementPartRequired
    case invalidCreditAmount
    case creditAmountRequired
    case partCreditRequired
    case laborCreditRequired
    case creditReferenceRequired
    case recoveryIncomplete
    case cancellationReasonRequired
    case invalidTransition

    var errorDescription: String? {
        switch self {
        case .actorRequired: "Sign in with an approved business account before changing a warranty claim."
        case .inactiveEquipment: "Reactivate this equipment profile before starting a warranty claim."
        case .manufacturerRequired: "Enter the equipment or failed-part manufacturer."
        case .equipmentSerialRequired: "Record the installed equipment serial number before requesting warranty support."
        case .issueRequired: "Describe the failure and diagnostic finding."
        case .issueTooLong: "Keep the warranty issue description to 2,000 characters or fewer."
        case .failedPartRequired: "Enter the failed part or component."
        case .invalidQuantity: "Enter a failed-part quantity from 1 through 1,000."
        case .claimNumberRequired: "Enter the manufacturer claim number or submission confirmation."
        case .evidenceRequired: "Link at least one equipment, diagnostic, or warranty evidence file before submission."
        case .invalidEvidence: "Every selected warranty file must belong to this customer and installed system."
        case .resolutionRequired: "Choose the approved replacement or credit resolution."
        case .denialReasonRequired: "Record the manufacturer or distributor denial reason."
        case .replacementPartRequired: "Enter the replacement part received."
        case .invalidCreditAmount: "Enter a valid warranty credit amount no greater than $10,000,000."
        case .creditAmountRequired: "Record a part or labor credit greater than zero."
        case .partCreditRequired: "This resolution requires a part/vendor credit amount."
        case .laborCreditRequired: "This resolution requires a labor credit amount."
        case .creditReferenceRequired: "Enter the vendor credit memo or reimbursement reference."
        case .recoveryIncomplete: "Record every approved replacement and credit before closing the claim."
        case .cancellationReasonRequired: "Explain why the open warranty claim is being cancelled."
        case .invalidTransition: "That warranty action is not valid for the claim’s current status."
        }
    }
}

enum EquipmentWarrantyClaimPolicy {
    static func request(
        id: UUID = UUID(),
        for equipment: CustomerEquipment,
        submission: EquipmentWarrantyClaimRequest,
        actorEmail: String?,
        at date: Date = Date()
    ) throws -> EquipmentWarrantyClaim {
        guard equipment.isActive else { throw EquipmentWarrantyClaimError.inactiveEquipment }
        guard let actor = normalized(actorEmail), actor.contains("@") else {
            throw EquipmentWarrantyClaimError.actorRequired
        }
        guard let manufacturer = normalized(submission.manufacturer) else {
            throw EquipmentWarrantyClaimError.manufacturerRequired
        }
        guard let serial = normalized(submission.equipmentSerialNumber) else {
            throw EquipmentWarrantyClaimError.equipmentSerialRequired
        }
        guard let issue = normalizedMultiline(submission.issueDescription) else {
            throw EquipmentWarrantyClaimError.issueRequired
        }
        guard issue.count <= 2_000 else { throw EquipmentWarrantyClaimError.issueTooLong }
        guard let failedPartName = normalized(submission.failedPartName) else {
            throw EquipmentWarrantyClaimError.failedPartRequired
        }
        guard submission.quantity.isFinite,
              submission.quantity >= 1,
              submission.quantity <= 1_000 else {
            throw EquipmentWarrantyClaimError.invalidQuantity
        }
        let evidence = Array(Set(submission.evidenceAttachmentIDs)).sorted { $0.uuidString < $1.uuidString }
        let detail = "Requested warranty review for \(submission.quantity.formatted(.number.precision(.fractionLength(0...3)))) × \(failedPartName)."
        return EquipmentWarrantyClaim(
            id: id,
            status: .requested,
            manufacturer: manufacturer,
            distributorName: normalized(submission.distributorName),
            equipmentSerialNumberSnapshot: serial,
            issueDescription: issue,
            failedPartName: failedPartName,
            failedPartNumber: normalized(submission.failedPartNumber),
            failedPartSerialNumber: normalized(submission.failedPartSerialNumber),
            quantity: submission.quantity,
            originatingServiceCallID: submission.originatingServiceCallID,
            originalPurchaseOrderID: submission.originalPurchaseOrderID,
            originalPurchaseOrderLineID: submission.originalPurchaseOrderLineID,
            evidenceAttachmentIDs: evidence,
            claimNumber: nil,
            resolution: nil,
            denialReason: nil,
            expectedPartCreditCents: nil,
            expectedLaborCreditCents: nil,
            replacementCatalogItemID: nil,
            replacementPartName: nil,
            replacementPartNumber: nil,
            replacementSerialNumber: nil,
            replacementInventoryMovementID: nil,
            replacementReceivedAt: nil,
            actualPartCreditCents: nil,
            actualLaborCreditCents: nil,
            vendorCreditReference: nil,
            quickBooksVendorCreditID: nil,
            creditReceivedAt: nil,
            requestedAt: date,
            requestedByEmail: actor.lowercased(),
            submittedAt: nil,
            submittedByEmail: nil,
            decidedAt: nil,
            decidedByEmail: nil,
            closedAt: nil,
            closedByEmail: nil,
            updatedAt: date,
            events: [.init(kind: .requested, occurredAt: date, actorEmail: actor.lowercased(), detail: detail)]
        )
    }

    static func eligibleEvidenceAttachments(
        for equipment: CustomerEquipment,
        originatingServiceCallID: UUID?,
        attachments: [ServiceDocumentAttachment]
    ) -> [ServiceDocumentAttachment] {
        attachments.filter { attachment in
            guard attachment.customer?.id == equipment.customer?.id else { return false }
            return attachment.customerEquipmentID == equipment.id ||
                (originatingServiceCallID != nil && attachment.serviceCallID == originatingServiceCallID)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    static func validatedEvidenceIDs(
        _ requestedIDs: [UUID],
        for equipment: CustomerEquipment,
        originatingServiceCallID: UUID?,
        attachments: [ServiceDocumentAttachment]
    ) throws -> [UUID] {
        let eligible = Set(eligibleEvidenceAttachments(
            for: equipment,
            originatingServiceCallID: originatingServiceCallID,
            attachments: attachments
        ).map(\.id))
        let requested = Set(requestedIDs)
        guard !requested.isEmpty else { throw EquipmentWarrantyClaimError.evidenceRequired }
        guard requested.isSubset(of: eligible) else { throw EquipmentWarrantyClaimError.invalidEvidence }
        return requested.sorted { $0.uuidString < $1.uuidString }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizedMultiline(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.split(whereSeparator: \Character.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return normalized.isEmpty ? nil : normalized
    }
}

struct EquipmentOperationalEvidenceEnvelope: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var technicalBaselines: [String: String]
    var warrantyClaims: [EquipmentWarrantyClaim]

    init(
        version: Int = currentVersion,
        technicalBaselines: [String: String] = [:],
        warrantyClaims: [EquipmentWarrantyClaim] = []
    ) {
        self.version = version
        self.technicalBaselines = technicalBaselines
        self.warrantyClaims = warrantyClaims
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case technicalBaselines
        case warrantyClaims
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        technicalBaselines = try container.decodeIfPresent([String: String].self, forKey: .technicalBaselines) ?? [:]
        warrantyClaims = try container.decodeIfPresent([EquipmentWarrantyClaim].self, forKey: .warrantyClaims) ?? []
    }

    static func decode(from rawValue: String?) -> EquipmentOperationalEvidenceEnvelope {
        guard let rawValue,
              let data = rawValue.data(using: .utf8) else {
            return .init()
        }
        // Decode the legacy flat dictionary first. `decodeIfPresent` makes the
        // versioned envelope tolerant of missing keys, so a legacy object such
        // as {"refrigerant_type":"R-410A"} would otherwise decode as an empty
        // envelope and silently discard every baseline on read.
        if let legacyBaselines = try? JSONDecoder().decode([String: String].self, from: data) {
            return .init(technicalBaselines: legacyBaselines)
        }
        if let envelope = try? JSONDecoder().decode(Self.self, from: data) {
            return envelope
        }
        return .init()
    }

    var encodedValue: String? {
        guard !technicalBaselines.isEmpty || !warrantyClaims.isEmpty else { return nil }
        var current = self
        current.version = Self.currentVersion
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(current) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

extension CustomerEquipment {
    var warrantyClaims: [EquipmentWarrantyClaim] {
        EquipmentOperationalEvidenceEnvelope.decode(from: technicalBaselineReadingsJSON)
            .warrantyClaims
            .sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    var openWarrantyClaims: [EquipmentWarrantyClaim] {
        warrantyClaims.filter { $0.status.isOpen }
    }

    var warrantyClaimAttentionSummary: String? {
        let claims = openWarrantyClaims
        guard !claims.isEmpty else { return nil }
        let requested = claims.filter { $0.status == .requested }.count
        let submitted = claims.filter { $0.status == .submitted }.count
        let approved = claims.filter { $0.status == .approved }.count
        let parts = [
            requested > 0 ? "\(requested) to submit" : nil,
            submitted > 0 ? "\(submitted) awaiting decision" : nil,
            approved > 0 ? "\(approved) recovery pending" : nil
        ].compactMap { $0 }
        return "\(claims.count) open warranty claim\(claims.count == 1 ? "" : "s") • \(parts.joined(separator: " • "))"
    }

    func upsertWarrantyClaim(_ claim: EquipmentWarrantyClaim) {
        var envelope = EquipmentOperationalEvidenceEnvelope.decode(from: technicalBaselineReadingsJSON)
        if let index = envelope.warrantyClaims.firstIndex(where: { $0.id == claim.id }) {
            envelope.warrantyClaims[index] = claim
        } else {
            envelope.warrantyClaims.append(claim)
        }
        technicalBaselineReadingsJSON = envelope.encodedValue
    }

    func replaceTechnicalBaselines(_ baselines: [String: String]) {
        var envelope = EquipmentOperationalEvidenceEnvelope.decode(from: technicalBaselineReadingsJSON)
        envelope.technicalBaselines = baselines
        technicalBaselineReadingsJSON = envelope.encodedValue
    }
}
