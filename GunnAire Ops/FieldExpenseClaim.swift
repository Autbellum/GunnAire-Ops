import Foundation
import SwiftData

enum FieldExpenseClaimType: String, Codable, CaseIterable, Identifiable {
    case expense
    case mileage

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .expense: "Expense"
        case .mileage: "Mileage"
        }
    }

    var systemImage: String {
        switch self {
        case .expense: "receipt"
        case .mileage: "car"
        }
    }
}

enum FieldExpenseCategory: String, Codable, CaseIterable, Identifiable {
    case mileage
    case parkingToll
    case permitFee
    case fuel
    case lodging
    case meal
    case smallTool
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mileage: "Mileage"
        case .parkingToll: "Parking or Toll"
        case .permitFee: "Permit or Inspection Fee"
        case .fuel: "Fuel"
        case .lodging: "Lodging"
        case .meal: "Meal"
        case .smallTool: "Small Tool or Supply"
        case .other: "Other"
        }
    }
}

enum FieldExpenseClaimStatus: String, Codable, CaseIterable, Identifiable {
    case submitted
    case correctionRequested
    case approved
    case rejected
    case reimbursed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .submitted: "Submitted"
        case .correctionRequested: "Correction Needed"
        case .approved: "Approved"
        case .rejected: "Rejected"
        case .reimbursed: "Reimbursed"
        }
    }

    var systemImage: String {
        switch self {
        case .submitted: "clock.badge.checkmark"
        case .correctionRequested: "exclamationmark.bubble"
        case .approved: "checkmark.seal"
        case .rejected: "xmark.seal"
        case .reimbursed: "banknote"
        }
    }
}

enum FieldExpenseAuditAction: String, Codable {
    case submitted
    case correctionRequested
    case resubmitted
    case approved
    case rejected
    case reimbursed
}

struct FieldExpenseAuditEvent: Codable, Equatable, Identifiable {
    let id: UUID
    let action: FieldExpenseAuditAction
    let actorEmail: String
    let occurredAt: Date
    let detail: String

    init(
        id: UUID = UUID(),
        action: FieldExpenseAuditAction,
        actorEmail: String,
        occurredAt: Date = Date(),
        detail: String
    ) {
        self.id = id
        self.action = action
        self.actorEmail = AppAccess.normalizedEmail(actorEmail)
        self.occurredAt = occurredAt
        self.detail = FieldExpenseClaimPolicy.boundedText(detail, limit: 500)
    }
}

enum FieldExpenseClaimError: LocalizedError, Equatable {
    case unauthorized
    case jobAccessChanged
    case claimantRequired
    case merchantRequired
    case detailRequired
    case invalidAmount
    case invalidMileage
    case invalidMileageRate
    case invalidRoute
    case invalidStatus
    case reviewNoteRequired
    case receiptRequired
    case selfReviewRequiresAdmin
    case notReimbursable
    case reimbursementReferenceRequired

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            "This account is not allowed to change field expense claims."
        case .jobAccessChanged:
            "The selected job is no longer available to this account. Reopen an assigned job and try again."
        case .claimantRequired:
            "A signed-in business account is required."
        case .merchantRequired:
            "Enter the merchant or payee for this expense."
        case .detailRequired:
            "Describe the business purpose of this claim."
        case .invalidAmount:
            "Enter an expense amount from $0.01 through $25,000."
        case .invalidMileage:
            "Enter mileage from 0.1 through 1,000 miles."
        case .invalidMileageRate:
            "Enter a mileage rate from $0.01 through $10 per mile."
        case .invalidRoute:
            "Enter both the starting point and destination for mileage. Do not include unnecessary customer details."
        case .invalidStatus:
            "This claim can no longer make that transition."
        case .reviewNoteRequired:
            "Enter a reason so the claimant can understand the review decision."
        case .receiptRequired:
            "Attach a receipt before approving an expense of $25 or more. Mileage claims do not require a receipt."
        case .selfReviewRequiresAdmin:
            "Only an administrator can review their own claim."
        case .notReimbursable:
            "This company-paid expense does not require employee reimbursement."
        case .reimbursementReferenceRequired:
            "Enter the payroll, check, or accounting reference used to reimburse this claim."
        }
    }
}

@Model
final class FieldExpenseClaim {
    var id: UUID = UUID()
    var serviceCallID: UUID?
    var customerID: UUID?
    var customerName: String?
    var jobSummary: String?
    var claimantEmail: String = ""
    var claimantName: String = ""
    var claimTypeRaw: String = FieldExpenseClaimType.expense.rawValue
    var categoryRaw: String = FieldExpenseCategory.other.rawValue
    var expenseDate: Date = Date()
    var merchant: String = ""
    var businessPurpose: String = ""
    var amount: Double = 0
    var mileageMiles: Double?
    var mileageRatePerMile: Double?
    var mileageOrigin: String?
    var mileageDestination: String?
    var reimbursable: Bool = true
    var statusRaw: String = FieldExpenseClaimStatus.submitted.rawValue
    var receiptAttachmentID: UUID?
    var submittedAt: Date = Date()
    var reviewedByEmail: String?
    var reviewedAt: Date?
    var reviewNote: String?
    var reimbursedByEmail: String?
    var reimbursedAt: Date?
    var reimbursementReference: String?
    var auditJSON: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        serviceCallID: UUID? = nil,
        customerID: UUID? = nil,
        customerName: String? = nil,
        jobSummary: String? = nil,
        claimantEmail: String,
        claimantName: String,
        claimType: FieldExpenseClaimType,
        category: FieldExpenseCategory,
        expenseDate: Date,
        merchant: String,
        businessPurpose: String,
        amount: Double,
        mileageMiles: Double? = nil,
        mileageRatePerMile: Double? = nil,
        mileageOrigin: String? = nil,
        mileageDestination: String? = nil,
        reimbursable: Bool,
        receiptAttachmentID: UUID? = nil,
        submittedAt: Date = Date(),
        createdAt: Date = Date()
    ) {
        self.id = id
        self.serviceCallID = serviceCallID
        self.customerID = customerID
        self.customerName = FieldExpenseClaimPolicy.optionalText(customerName, limit: 160)
        self.jobSummary = FieldExpenseClaimPolicy.optionalText(jobSummary, limit: 240)
        self.claimantEmail = AppAccess.normalizedEmail(claimantEmail)
        self.claimantName = FieldExpenseClaimPolicy.boundedText(claimantName, limit: 160)
        self.claimTypeRaw = claimType.rawValue
        self.categoryRaw = category.rawValue
        self.expenseDate = expenseDate
        self.merchant = FieldExpenseClaimPolicy.boundedText(merchant, limit: 160)
        self.businessPurpose = FieldExpenseClaimPolicy.boundedText(businessPurpose, limit: 600)
        self.amount = FieldExpenseClaimPolicy.roundCurrency(amount)
        self.mileageMiles = mileageMiles
        self.mileageRatePerMile = mileageRatePerMile
        self.mileageOrigin = FieldExpenseClaimPolicy.optionalText(mileageOrigin, limit: 160)
        self.mileageDestination = FieldExpenseClaimPolicy.optionalText(mileageDestination, limit: 160)
        self.reimbursable = reimbursable
        self.statusRaw = FieldExpenseClaimStatus.submitted.rawValue
        self.receiptAttachmentID = receiptAttachmentID
        self.submittedAt = submittedAt
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.auditJSON = FieldExpenseClaimPolicy.appending(
            FieldExpenseAuditEvent(
                action: .submitted,
                actorEmail: claimantEmail,
                occurredAt: submittedAt,
                detail: serviceCallID == nil ? "Submitted a general business claim." : "Submitted a job-linked claim."
            ),
            to: nil
        )
    }

    var claimType: FieldExpenseClaimType {
        get { FieldExpenseClaimType(rawValue: claimTypeRaw) ?? .expense }
        set { claimTypeRaw = newValue.rawValue }
    }

    var category: FieldExpenseCategory {
        get { FieldExpenseCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }

    var status: FieldExpenseClaimStatus {
        get { FieldExpenseClaimStatus(rawValue: statusRaw) ?? .submitted }
        set { statusRaw = newValue.rawValue }
    }

    var auditEvents: [FieldExpenseAuditEvent] {
        FieldExpenseClaimPolicy.auditEvents(from: auditJSON)
    }

    var requiresReceiptForApproval: Bool {
        claimType == .expense && amount >= 25
    }

    var isApprovedJobCost: Bool {
        status == .approved || status == .reimbursed
    }

    var needsOfficeReview: Bool { status == .submitted }

    var needsReimbursement: Bool { status == .approved && reimbursable }

    var claimReference: String {
        String(id.uuidString.prefix(8)).uppercased()
    }

    func approvalIssue(hasReceipt: Bool) -> FieldExpenseClaimError? {
        requiresReceiptForApproval && !hasReceipt ? .receiptRequired : nil
    }

    func requestCorrection(
        note: String,
        reviewerEmail: String,
        reviewerRole: AppUserRole,
        now: Date = Date()
    ) throws {
        try validateReviewer(reviewerEmail: reviewerEmail, reviewerRole: reviewerRole)
        guard status == .submitted else { throw FieldExpenseClaimError.invalidStatus }
        let note = FieldExpenseClaimPolicy.boundedText(note, limit: 600)
        guard !note.isEmpty else { throw FieldExpenseClaimError.reviewNoteRequired }
        status = .correctionRequested
        reviewedByEmail = AppAccess.normalizedEmail(reviewerEmail)
        reviewedAt = now
        reviewNote = note
        updatedAt = now
        appendAudit(.correctionRequested, actorEmail: reviewerEmail, at: now, detail: note)
    }

    func resubmit(
        claimType: FieldExpenseClaimType,
        category: FieldExpenseCategory,
        expenseDate: Date,
        merchant: String,
        businessPurpose: String,
        amount: Double?,
        mileageMiles: Double?,
        mileageRatePerMile: Double?,
        mileageOrigin: String?,
        mileageDestination: String?,
        reimbursable: Bool,
        receiptAttachmentID: UUID?,
        actorEmail: String,
        now: Date = Date()
    ) throws {
        guard status == .correctionRequested,
              AppAccess.normalizedEmail(actorEmail) == claimantEmail else {
            throw FieldExpenseClaimError.unauthorized
        }
        let facts = try FieldExpenseClaimPolicy.validatedFacts(
            claimType: claimType,
            category: category,
            merchant: merchant,
            businessPurpose: businessPurpose,
            amount: amount,
            mileageMiles: mileageMiles,
            mileageRatePerMile: mileageRatePerMile,
            mileageOrigin: mileageOrigin,
            mileageDestination: mileageDestination
        )
        apply(facts: facts)
        self.expenseDate = expenseDate
        self.reimbursable = reimbursable
        self.receiptAttachmentID = receiptAttachmentID
        status = .submitted
        submittedAt = now
        reviewedByEmail = nil
        reviewedAt = nil
        reviewNote = nil
        updatedAt = now
        appendAudit(.resubmitted, actorEmail: actorEmail, at: now, detail: "Corrected and resubmitted for office review.")
    }

    func approve(
        reviewerEmail: String,
        reviewerRole: AppUserRole,
        note: String? = nil,
        hasReceipt: Bool,
        now: Date = Date()
    ) throws {
        try validateReviewer(reviewerEmail: reviewerEmail, reviewerRole: reviewerRole)
        guard status == .submitted else { throw FieldExpenseClaimError.invalidStatus }
        if let issue = approvalIssue(hasReceipt: hasReceipt) { throw issue }
        let note = FieldExpenseClaimPolicy.optionalText(note, limit: 600)
        status = .approved
        reviewedByEmail = AppAccess.normalizedEmail(reviewerEmail)
        reviewedAt = now
        reviewNote = note
        updatedAt = now
        appendAudit(
            .approved,
            actorEmail: reviewerEmail,
            at: now,
            detail: note ?? (reimbursable ? "Approved for reimbursement." : "Approved as company paid.")
        )
    }

    func reject(
        note: String,
        reviewerEmail: String,
        reviewerRole: AppUserRole,
        now: Date = Date()
    ) throws {
        try validateReviewer(reviewerEmail: reviewerEmail, reviewerRole: reviewerRole)
        guard status == .submitted else { throw FieldExpenseClaimError.invalidStatus }
        let note = FieldExpenseClaimPolicy.boundedText(note, limit: 600)
        guard !note.isEmpty else { throw FieldExpenseClaimError.reviewNoteRequired }
        status = .rejected
        reviewedByEmail = AppAccess.normalizedEmail(reviewerEmail)
        reviewedAt = now
        reviewNote = note
        updatedAt = now
        appendAudit(.rejected, actorEmail: reviewerEmail, at: now, detail: note)
    }

    func markReimbursed(
        reference: String,
        actorEmail: String,
        actorRole: AppUserRole,
        now: Date = Date()
    ) throws {
        guard actorRole == .accounting || actorRole == .admin else {
            throw FieldExpenseClaimError.unauthorized
        }
        guard status == .approved else { throw FieldExpenseClaimError.invalidStatus }
        guard reimbursable else { throw FieldExpenseClaimError.notReimbursable }
        let reference = FieldExpenseClaimPolicy.boundedText(reference, limit: 160)
        guard !reference.isEmpty else { throw FieldExpenseClaimError.reimbursementReferenceRequired }
        status = .reimbursed
        reimbursedByEmail = AppAccess.normalizedEmail(actorEmail)
        reimbursedAt = now
        reimbursementReference = reference
        updatedAt = now
        appendAudit(.reimbursed, actorEmail: actorEmail, at: now, detail: "Reimbursement reference: \(reference)")
    }

    private func validateReviewer(
        reviewerEmail: String,
        reviewerRole: AppUserRole
    ) throws {
        guard reviewerRole == .accounting || reviewerRole == .admin else {
            throw FieldExpenseClaimError.unauthorized
        }
        if AppAccess.normalizedEmail(reviewerEmail) == claimantEmail,
           reviewerRole != .admin {
            throw FieldExpenseClaimError.selfReviewRequiresAdmin
        }
    }

    private func apply(facts: FieldExpenseClaimPolicy.ValidatedFacts) {
        claimType = facts.claimType
        category = facts.category
        merchant = facts.merchant
        businessPurpose = facts.businessPurpose
        amount = facts.amount
        mileageMiles = facts.mileageMiles
        mileageRatePerMile = facts.mileageRatePerMile
        mileageOrigin = facts.mileageOrigin
        mileageDestination = facts.mileageDestination
    }

    private func appendAudit(
        _ action: FieldExpenseAuditAction,
        actorEmail: String,
        at: Date,
        detail: String
    ) {
        auditJSON = FieldExpenseClaimPolicy.appending(
            FieldExpenseAuditEvent(
                action: action,
                actorEmail: actorEmail,
                occurredAt: at,
                detail: detail
            ),
            to: auditJSON
        )
    }
}

enum FieldExpenseClaimPolicy {
    struct ValidatedFacts: Equatable {
        let claimType: FieldExpenseClaimType
        let category: FieldExpenseCategory
        let merchant: String
        let businessPurpose: String
        let amount: Double
        let mileageMiles: Double?
        let mileageRatePerMile: Double?
        let mileageOrigin: String?
        let mileageDestination: String?
    }

    static func makeClaim(
        id: UUID = UUID(),
        serviceCall: ServiceCall?,
        claimantEmail: String,
        claimantName: String,
        claimType: FieldExpenseClaimType,
        category: FieldExpenseCategory,
        expenseDate: Date,
        merchant: String,
        businessPurpose: String,
        amount: Double?,
        mileageMiles: Double?,
        mileageRatePerMile: Double?,
        mileageOrigin: String?,
        mileageDestination: String?,
        reimbursable: Bool,
        receiptAttachmentID: UUID? = nil,
        now: Date = Date()
    ) throws -> FieldExpenseClaim {
        let email = AppAccess.normalizedEmail(claimantEmail)
        guard !email.isEmpty else { throw FieldExpenseClaimError.claimantRequired }
        let facts = try validatedFacts(
            claimType: claimType,
            category: category,
            merchant: merchant,
            businessPurpose: businessPurpose,
            amount: amount,
            mileageMiles: mileageMiles,
            mileageRatePerMile: mileageRatePerMile,
            mileageOrigin: mileageOrigin,
            mileageDestination: mileageDestination
        )
        return FieldExpenseClaim(
            id: id,
            serviceCallID: serviceCall?.id,
            customerID: serviceCall?.customer.id,
            customerName: serviceCall?.customer.name,
            jobSummary: serviceCall.map {
                "\($0.type.displayName) • \($0.scheduledDate.formatted(date: .abbreviated, time: .omitted))"
            },
            claimantEmail: email,
            claimantName: claimantName,
            claimType: facts.claimType,
            category: facts.category,
            expenseDate: expenseDate,
            merchant: facts.merchant,
            businessPurpose: facts.businessPurpose,
            amount: facts.amount,
            mileageMiles: facts.mileageMiles,
            mileageRatePerMile: facts.mileageRatePerMile,
            mileageOrigin: facts.mileageOrigin,
            mileageDestination: facts.mileageDestination,
            reimbursable: reimbursable,
            receiptAttachmentID: receiptAttachmentID,
            submittedAt: now,
            createdAt: now
        )
    }

    static func validatedFacts(
        claimType: FieldExpenseClaimType,
        category: FieldExpenseCategory,
        merchant: String,
        businessPurpose: String,
        amount: Double?,
        mileageMiles: Double?,
        mileageRatePerMile: Double?,
        mileageOrigin: String?,
        mileageDestination: String?
    ) throws -> ValidatedFacts {
        let purpose = boundedText(businessPurpose, limit: 600)
        guard !purpose.isEmpty else { throw FieldExpenseClaimError.detailRequired }
        switch claimType {
        case .expense:
            let merchant = boundedText(merchant, limit: 160)
            guard !merchant.isEmpty else { throw FieldExpenseClaimError.merchantRequired }
            guard let amount, amount.isFinite, (0.01...25_000).contains(amount) else {
                throw FieldExpenseClaimError.invalidAmount
            }
            return ValidatedFacts(
                claimType: .expense,
                category: category == .mileage ? .other : category,
                merchant: merchant,
                businessPurpose: purpose,
                amount: roundCurrency(amount),
                mileageMiles: nil,
                mileageRatePerMile: nil,
                mileageOrigin: nil,
                mileageDestination: nil
            )
        case .mileage:
            guard let mileageMiles, mileageMiles.isFinite, (0.1...1_000).contains(mileageMiles) else {
                throw FieldExpenseClaimError.invalidMileage
            }
            guard let mileageRatePerMile,
                  mileageRatePerMile.isFinite,
                  (0.01...10).contains(mileageRatePerMile) else {
                throw FieldExpenseClaimError.invalidMileageRate
            }
            guard let origin = optionalText(mileageOrigin, limit: 160),
                  let destination = optionalText(mileageDestination, limit: 160) else {
                throw FieldExpenseClaimError.invalidRoute
            }
            let total = roundCurrency(mileageMiles * mileageRatePerMile)
            guard total >= 0.01, total <= 25_000 else { throw FieldExpenseClaimError.invalidAmount }
            return ValidatedFacts(
                claimType: .mileage,
                category: .mileage,
                merchant: "Mileage",
                businessPurpose: purpose,
                amount: total,
                mileageMiles: mileageMiles,
                mileageRatePerMile: mileageRatePerMile,
                mileageOrigin: origin,
                mileageDestination: destination
            )
        }
    }

    static func auditEvents(from json: String?) -> [FieldExpenseAuditEvent] {
        guard let json,
              let data = json.data(using: .utf8),
              let events = try? JSONDecoder().decode([FieldExpenseAuditEvent].self, from: data) else {
            return []
        }
        return events.sorted { $0.occurredAt < $1.occurredAt }
    }

    static func appending(_ event: FieldExpenseAuditEvent, to json: String?) -> String? {
        var events = auditEvents(from: json)
        events.append(event)
        guard let data = try? JSONEncoder().encode(events) else { return json }
        return String(data: data, encoding: .utf8)
    }

    static func roundCurrency(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    static func boundedText(_ value: String, limit: Int) -> String {
        String(value
            .unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(limit))
    }

    static func optionalText(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let normalized = boundedText(value, limit: limit)
        return normalized.isEmpty ? nil : normalized
    }
}
