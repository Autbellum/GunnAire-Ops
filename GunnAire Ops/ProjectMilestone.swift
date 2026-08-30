import Foundation
import SwiftData

enum ProjectBillingTrigger: String, Codable, CaseIterable, Identifiable {
    case customerApproval
    case milestoneCompletion

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .customerApproval: "Customer Approval"
        case .milestoneCompletion: "Milestone Completion"
        }
    }
}

enum ProjectMilestoneStatus: String, Codable, CaseIterable {
    case planned
    case scheduled
    case readyForBilling
    case invoiced
}

enum ProjectMilestoneDisplayState: Equatable {
    case planned
    case scheduled
    case readyForBilling
    case invoiced
    case paid

    var label: String {
        switch self {
        case .planned: "Planned"
        case .scheduled: "Visit Scheduled"
        case .readyForBilling: "Ready to Bill"
        case .invoiced: "Invoiced"
        case .paid: "Paid"
        }
    }

    var systemImage: String {
        switch self {
        case .planned: "circle.dashed"
        case .scheduled: "calendar.badge.clock"
        case .readyForBilling: "checkmark.circle"
        case .invoiced: "doc.text"
        case .paid: "checkmark.seal.fill"
        }
    }
}

/// A project milestone stays operationally separate from its invoice. Stable
/// UUID links tolerate CloudKit records arriving out of order and prevent an
/// accounting document from becoming the only record of field progress.
@Model
final class ProjectMilestone {
    var id: UUID = UUID()
    var projectServiceCallID: UUID = UUID()
    var estimateID: UUID = UUID()
    var sequence: Int = 0
    var title: String = ""
    var milestoneDescription: String?
    var plannedDate: Date = Date()
    var billingPercent: Double = 0
    var plannedAmount: Double = 0
    var billingTriggerRaw: String = ProjectBillingTrigger.milestoneCompletion.rawValue
    var statusRaw: String = ProjectMilestoneStatus.planned.rawValue
    var scheduledVisitID: UUID?
    var invoiceID: UUID?
    var completedAt: Date?
    var completedByEmail: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var createdByEmail: String?

    init(
        id: UUID = UUID(),
        projectServiceCallID: UUID,
        estimateID: UUID,
        sequence: Int,
        title: String,
        milestoneDescription: String? = nil,
        plannedDate: Date,
        billingPercent: Double,
        plannedAmount: Double,
        billingTrigger: ProjectBillingTrigger,
        status: ProjectMilestoneStatus = .planned,
        scheduledVisitID: UUID? = nil,
        invoiceID: UUID? = nil,
        completedAt: Date? = nil,
        completedByEmail: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        createdByEmail: String? = nil
    ) {
        self.id = id
        self.projectServiceCallID = projectServiceCallID
        self.estimateID = estimateID
        self.sequence = sequence
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.milestoneDescription = Self.normalized(milestoneDescription)
        self.plannedDate = plannedDate
        self.billingPercent = billingPercent
        self.plannedAmount = plannedAmount
        self.billingTriggerRaw = billingTrigger.rawValue
        self.statusRaw = status.rawValue
        self.scheduledVisitID = scheduledVisitID
        self.invoiceID = invoiceID
        self.completedAt = completedAt
        self.completedByEmail = Self.normalizedEmail(completedByEmail)
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.createdByEmail = Self.normalizedEmail(createdByEmail)
    }

    var billingTrigger: ProjectBillingTrigger {
        get { ProjectBillingTrigger(rawValue: billingTriggerRaw) ?? .milestoneCompletion }
        set { billingTriggerRaw = newValue.rawValue }
    }

    var status: ProjectMilestoneStatus {
        get { ProjectMilestoneStatus(rawValue: statusRaw) ?? .planned }
        set { statusRaw = newValue.rawValue }
    }

    func displayState(invoices: [Invoice], payments: [Payment]) -> ProjectMilestoneDisplayState {
        if let invoice = linkedInvoice(in: invoices) {
            return Invoice.isPaid(invoice, payments: payments) ? .paid : .invoiced
        }
        if invoiceID != nil || status == .invoiced { return .invoiced }
        if completedAt != nil || status == .readyForBilling { return .readyForBilling }
        if scheduledVisitID != nil || status == .scheduled { return .scheduled }
        return .planned
    }

    func linkedInvoice(in invoices: [Invoice]) -> Invoice? {
        guard let invoiceID else { return nil }
        return invoices.first { $0.id == invoiceID }
    }

    func markScheduled(visitID: UUID, at date: Date = Date()) {
        guard invoiceID == nil else { return }
        scheduledVisitID = visitID
        status = .scheduled
        updatedAt = date
    }

    @discardableResult
    func markCompleted(by email: String?, at date: Date = Date()) -> Bool {
        guard invoiceID == nil else { return false }
        completedAt = date
        completedByEmail = Self.normalizedEmail(email)
        status = .readyForBilling
        updatedAt = date
        return true
    }

    @discardableResult
    func markInvoiced(invoiceID: UUID, at date: Date = Date()) -> Bool {
        guard self.invoiceID == nil else { return false }
        self.invoiceID = invoiceID
        status = .invoiced
        updatedAt = date
        return true
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func normalizedEmail(_ value: String?) -> String? {
        normalized(value)?.lowercased()
    }
}

struct ProjectMilestonePlanDraft: Identifiable, Equatable {
    let id: UUID
    var title: String
    var milestoneDescription: String
    var billingPercent: Double
    var plannedDate: Date
    var billingTrigger: ProjectBillingTrigger

    init(
        id: UUID = UUID(),
        title: String,
        milestoneDescription: String = "",
        billingPercent: Double,
        plannedDate: Date,
        billingTrigger: ProjectBillingTrigger
    ) {
        self.id = id
        self.title = title
        self.milestoneDescription = milestoneDescription
        self.billingPercent = billingPercent
        self.plannedDate = plannedDate
        self.billingTrigger = billingTrigger
    }
}

enum ProjectBillingValidationError: LocalizedError, Equatable {
    case approvalRequired
    case invalidContractAmount
    case milestoneCount
    case missingTitle
    case duplicateTitle
    case invalidPercent
    case percentTotal(Double)
    case datesOutOfOrder
    case approvalTriggerMustComeFirst
    case invalidPersistedPlan
    case missingCatalogSnapshot

    var errorDescription: String? {
        switch self {
        case .approvalRequired: "Record traceable customer approval before creating a project billing plan."
        case .invalidContractAmount: "The approved contract must have an amount greater than zero."
        case .milestoneCount: "Create between 2 and 8 milestones."
        case .missingTitle: "Every milestone needs a title."
        case .duplicateTitle: "Milestone titles must be unique."
        case .invalidPercent: "Every milestone needs a billing percentage greater than zero."
        case .percentTotal(let total): "Milestone percentages must total 100%. Current total: \(total.formatted(.number.precision(.fractionLength(0...2))))%."
        case .datesOutOfOrder: "Milestone dates must follow the displayed project order."
        case .approvalTriggerMustComeFirst: "Approval-triggered billing can only be used for the first milestone."
        case .invalidPersistedPlan: "The saved milestone plan no longer reconciles to the approved contract. Review it before invoicing."
        case .missingCatalogSnapshot: "The approved estimate does not contain the durable line-item snapshot required for progress billing."
        }
    }
}

struct ProjectBillingSummary: Equatable {
    let contractAmount: Double
    let invoicedAmount: Double
    let paidAmount: Double
    let remainingToInvoice: Double
    let readyToBillCount: Int
    let milestoneCount: Int

    var billedFraction: Double {
        guard contractAmount > 0 else { return 0 }
        return min(max(invoicedAmount / contractAmount, 0), 1)
    }
}

enum ProjectBillingPolicy {
    static func defaultDrafts(startingAt startDate: Date, calendar: Calendar = .current) -> [ProjectMilestonePlanDraft] {
        let installationDate = startDate
        let completionDate = calendar.date(byAdding: .day, value: 1, to: startDate) ?? startDate.addingTimeInterval(86_400)
        return [
            ProjectMilestonePlanDraft(
                title: "Deposit & Equipment Reservation",
                milestoneDescription: "Customer-approved deposit and equipment commitment.",
                billingPercent: 30,
                plannedDate: startDate,
                billingTrigger: .customerApproval
            ),
            ProjectMilestonePlanDraft(
                title: "Installation & Startup",
                milestoneDescription: "Equipment installation, startup, and operating checks.",
                billingPercent: 50,
                plannedDate: installationDate,
                billingTrigger: .milestoneCompletion
            ),
            ProjectMilestonePlanDraft(
                title: "Commissioning & Customer Handoff",
                milestoneDescription: "Final commissioning, documentation, and customer handoff.",
                billingPercent: 20,
                plannedDate: completionDate,
                billingTrigger: .milestoneCompletion
            )
        ]
    }

    static func validate(drafts: [ProjectMilestonePlanDraft], contractAmount: Double) throws {
        guard contractAmount.isFinite, contractAmount > 0 else {
            throw ProjectBillingValidationError.invalidContractAmount
        }
        guard (2...8).contains(drafts.count) else {
            throw ProjectBillingValidationError.milestoneCount
        }
        let normalizedTitles = drafts.map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard normalizedTitles.allSatisfy({ !$0.isEmpty }) else {
            throw ProjectBillingValidationError.missingTitle
        }
        guard Set(normalizedTitles).count == normalizedTitles.count else {
            throw ProjectBillingValidationError.duplicateTitle
        }
        guard drafts.allSatisfy({ $0.billingPercent.isFinite && $0.billingPercent > 0 }) else {
            throw ProjectBillingValidationError.invalidPercent
        }
        let total = drafts.reduce(0) { $0 + $1.billingPercent }
        guard abs(total - 100) < 0.005 else {
            throw ProjectBillingValidationError.percentTotal(total)
        }
        for index in drafts.indices.dropFirst() where drafts[index].plannedDate < drafts[index - 1].plannedDate {
            throw ProjectBillingValidationError.datesOutOfOrder
        }
        for index in drafts.indices where drafts[index].billingTrigger == .customerApproval && index != drafts.startIndex {
            throw ProjectBillingValidationError.approvalTriggerMustComeFirst
        }
    }

    static func makeMilestones(
        drafts: [ProjectMilestonePlanDraft],
        projectServiceCallID: UUID,
        estimate: Estimate,
        createdByEmail: String?,
        now: Date = Date()
    ) throws -> [ProjectMilestone] {
        guard estimate.hasRecordedCustomerApproval else {
            throw ProjectBillingValidationError.approvalRequired
        }
        try validate(drafts: drafts, contractAmount: estimate.amount)
        let amounts = allocatedAmounts(total: estimate.amount, percentages: drafts.map(\.billingPercent))
        return zip(drafts.indices, zip(drafts, amounts)).map { index, pair in
            let draft = pair.0
            return ProjectMilestone(
                id: draft.id,
                projectServiceCallID: projectServiceCallID,
                estimateID: estimate.id,
                sequence: index,
                title: draft.title,
                milestoneDescription: draft.milestoneDescription,
                plannedDate: draft.plannedDate,
                billingPercent: draft.billingPercent,
                plannedAmount: pair.1,
                billingTrigger: draft.billingTrigger,
                status: draft.billingTrigger == .customerApproval ? .readyForBilling : .planned,
                createdAt: now,
                createdByEmail: createdByEmail
            )
        }
    }

    static func validatePersistedPlan(_ milestones: [ProjectMilestone], contractAmount: Double) throws {
        let sorted = milestones.sorted { $0.sequence < $1.sequence }
        let drafts = sorted.map {
            ProjectMilestonePlanDraft(
                id: $0.id,
                title: $0.title,
                milestoneDescription: $0.milestoneDescription ?? "",
                billingPercent: $0.billingPercent,
                plannedDate: $0.plannedDate,
                billingTrigger: $0.billingTrigger
            )
        }
        do {
            try validate(drafts: drafts, contractAmount: contractAmount)
        } catch {
            throw ProjectBillingValidationError.invalidPersistedPlan
        }
        let amountTotal = milestones.reduce(0) { $0 + $1.plannedAmount }
        guard abs(amountTotal - contractAmount) < 0.01 else {
            throw ProjectBillingValidationError.invalidPersistedPlan
        }
    }

    static func canInvoice(
        _ milestone: ProjectMilestone,
        estimate: Estimate,
        scheduledVisit: ServiceCall?
    ) -> Bool {
        guard milestone.invoiceID == nil, estimate.hasRecordedCustomerApproval else { return false }
        switch milestone.billingTrigger {
        case .customerApproval:
            return milestone.sequence == 0
        case .milestoneCompletion:
            if milestone.completedAt != nil { return true }
            return scheduledVisit?.status == .completed || scheduledVisit?.status == .invoiced
        }
    }

    static func allocatedAmounts(total: Double, percentages: [Double]) -> [Double] {
        guard !percentages.isEmpty else { return [] }
        guard total.isFinite, total > 0, total * 100 <= Double(Int.max) else {
            return Array(repeating: 0, count: percentages.count)
        }
        let weights = percentages.map { value in
            value.isFinite ? max(value, 0) : 0
        }
        let weightTotal = weights.reduce(0, +)
        guard weightTotal > 0 else {
            return Array(repeating: 0, count: percentages.count)
        }

        let totalCents = Int((total * 100).rounded())
        let exactCents = weights.map { Double(totalCents) * $0 / weightTotal }
        var allocatedCents = exactCents.map { Int($0.rounded(.down)) }
        var remainingCents = totalCents - allocatedCents.reduce(0, +)
        let remainderPriority = exactCents.indices.sorted { lhs, rhs in
            let lhsRemainder = exactCents[lhs] - Double(allocatedCents[lhs])
            let rhsRemainder = exactCents[rhs] - Double(allocatedCents[rhs])
            if abs(lhsRemainder - rhsRemainder) >= 0.000_000_1 {
                return lhsRemainder > rhsRemainder
            }
            return lhs < rhs
        }
        var priorityIndex = 0
        while remainingCents > 0, !remainderPriority.isEmpty {
            allocatedCents[remainderPriority[priorityIndex % remainderPriority.count]] += 1
            remainingCents -= 1
            priorityIndex += 1
        }
        return allocatedCents.map { Double($0) / 100 }
    }

    /// Allocates the exact milestone cents across the approved estimate lines
    /// while retaining the approved unit prices and their authorization audit.
    /// Fractional QBO quantities represent the billed share of each contract line.
    static func progressSnapshots(
        from source: [CatalogLineItemSnapshot],
        targetAmount: Double
    ) throws -> [CatalogLineItemSnapshot] {
        guard !source.isEmpty else { throw ProjectBillingValidationError.missingCatalogSnapshot }
        let extendedAmounts = source.map { max($0.unitPrice * $0.quantity, 0) }
        let sourceTotal = extendedAmounts.reduce(0, +)
        guard sourceTotal > 0, targetAmount > 0 else {
            throw ProjectBillingValidationError.missingCatalogSnapshot
        }
        let percentages = extendedAmounts.map { $0 / sourceTotal * 100 }
        let lineAmounts = allocatedAmounts(total: targetAmount, percentages: percentages)
        return zip(source, lineAmounts).map { snapshot, lineAmount in
            guard snapshot.unitPrice > 0 else {
                return snapshot.replacingQuantity(with: snapshot.quantity * targetAmount / sourceTotal)
            }
            return snapshot.replacingQuantity(with: lineAmount / snapshot.unitPrice)
        }
    }

    static func summary(
        milestones: [ProjectMilestone],
        invoices: [Invoice],
        payments: [Payment]
    ) -> ProjectBillingSummary {
        let invoiceByID = Dictionary(invoices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let linkedInvoices = milestones.compactMap { milestone in
            milestone.invoiceID.flatMap { invoiceByID[$0] }
        }
        let contractAmount = milestones.reduce(0) { $0 + $1.plannedAmount }
        let invoicedAmount = linkedInvoices.reduce(0) { $0 + $1.amount }
        let paidAmount = linkedInvoices.reduce(0) { partial, invoice in
            partial + max(invoice.amount - Invoice.outstandingBalance(for: invoice, payments: payments), 0)
        }
        let readyToBillCount = milestones.filter { milestone in
            milestone.invoiceID == nil && (milestone.completedAt != nil || milestone.billingTrigger == .customerApproval)
        }.count
        return ProjectBillingSummary(
            contractAmount: contractAmount,
            invoicedAmount: invoicedAmount,
            paidAmount: paidAmount,
            remainingToInvoice: max(contractAmount - invoicedAmount, 0),
            readyToBillCount: readyToBillCount,
            milestoneCount: milestones.count
        )
    }
}
