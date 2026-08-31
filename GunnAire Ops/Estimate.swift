// Estimate.swift
// Model for service estimates
import Foundation
import SwiftData

enum EstimateProposalOption: String, CaseIterable, Identifiable, Codable {
    case standalone
    case good
    case better
    case best

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standalone: "Single Estimate"
        case .good: "Good"
        case .better: "Better"
        case .best: "Best"
        }
    }

    var comparisonRank: Int {
        switch self {
        case .good: 0
        case .better: 1
        case .best: 2
        case .standalone: 3
        }
    }
}

enum EstimateApprovalMethod: String, CaseIterable, Identifiable, Codable {
    case inPersonSignature
    case email
    case textMessage
    case phoneVerbal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .inPersonSignature: "In-person signature"
        case .email: "Email approval"
        case .textMessage: "Text-message approval"
        case .phoneVerbal: "Phone / verbal approval"
        }
    }

    var requiresSignature: Bool { self == .inPersonSignature }

    var referencePrompt: String {
        switch self {
        case .inPersonSignature: ""
        case .email: "Email subject, message ID, or brief note"
        case .textMessage: "Phone number, message time, or brief note"
        case .phoneVerbal: "Call time and brief authorization note"
        }
    }
}

@Model
final class Estimate {
    var id: UUID = UUID()
    var serviceCallID: UUID?
    /// Stable property identity plus the address snapshot shown to the customer.
    /// Standalone estimates need this before any work order exists.
    var serviceLocationID: UUID?
    var siteAddress: String?
    /// The approved proposal's operational work order. This is separate from
    /// `serviceCallID`, which may point to the diagnostic/estimate visit that
    /// produced the proposal.
    var scheduledServiceCallID: UUID?
    /// The accepted or pending proposal this revision amends. The original remains immutable evidence.
    var parentEstimateID: UUID?
    var changeOrderReason: String?
    var proposalGroupID: UUID?
    var proposalOption: String?
    var proposalIsRecommended: Bool = false
    /// CloudKit relationships must be optional because records can arrive out
    /// of order. Initializers still require a customer for local creation.
    var customer: Customer!
    var quickBooksID: String?
    var lineItemSummary: String = ""
    var catalogSnapshotJSON: String?
    var amount: Double = 0
    var salesTaxAmount: Double = 0
    var taxCalculationStatusRawValue: String?
    var taxCalculatedAt: Date?
    var status: String = "pending" // pending, accepted, rejected, invoiced, etc.
    var customerApprovedByName: String?
    var customerApprovedAt: Date?
    /// Evidence is stored on the exact estimate revision that the customer approved.
    var customerApprovalMethodRaw: String?
    var customerApprovalReference: String?
    var customerApprovalRecordedByEmail: String?
    var customerApprovalSignatureImageBase64: String?
    var notes: String?
    var createdAt: Date = Date()
    
    init(
        id: UUID = UUID(),
        serviceCallID: UUID? = nil,
        serviceLocationID: UUID? = nil,
        siteAddress: String? = nil,
        scheduledServiceCallID: UUID? = nil,
        parentEstimateID: UUID? = nil,
        changeOrderReason: String? = nil,
        proposalGroupID: UUID? = nil,
        proposalOption: String? = nil,
        proposalIsRecommended: Bool = false,
        customer: Customer,
        quickBooksID: String? = nil,
        lineItemSummary: String = "",
        catalogSnapshotJSON: String? = nil,
        amount: Double = 0,
        salesTaxAmount: Double = 0,
        taxCalculationStatus: BillingTaxCalculationStatus? = nil,
        taxCalculatedAt: Date? = nil,
        status: String = "pending",
        customerApprovedByName: String? = nil,
        customerApprovedAt: Date? = nil,
        customerApprovalMethodRaw: String? = nil,
        customerApprovalReference: String? = nil,
        customerApprovalRecordedByEmail: String? = nil,
        customerApprovalSignatureImageBase64: String? = nil,
        notes: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.serviceCallID = serviceCallID
        self.serviceLocationID = serviceLocationID
        self.siteAddress = siteAddress
        self.scheduledServiceCallID = scheduledServiceCallID
        self.parentEstimateID = parentEstimateID
        self.changeOrderReason = changeOrderReason
        self.proposalGroupID = proposalGroupID
        self.proposalOption = proposalOption
        self.proposalIsRecommended = proposalIsRecommended
        self.customer = customer
        self.quickBooksID = quickBooksID
        self.lineItemSummary = lineItemSummary
        self.catalogSnapshotJSON = catalogSnapshotJSON
        self.amount = amount
        self.salesTaxAmount = max(salesTaxAmount, 0)
        self.taxCalculationStatusRawValue = taxCalculationStatus?.rawValue
        self.taxCalculatedAt = taxCalculatedAt
        self.status = status
        self.customerApprovedByName = customerApprovedByName
        self.customerApprovedAt = customerApprovedAt
        self.customerApprovalMethodRaw = customerApprovalMethodRaw
        self.customerApprovalReference = customerApprovalReference
        self.customerApprovalRecordedByEmail = customerApprovalRecordedByEmail
        self.customerApprovalSignatureImageBase64 = customerApprovalSignatureImageBase64
        self.notes = notes
        self.createdAt = createdAt
    }

    var catalogLineSnapshots: [CatalogLineItemSnapshot] {
        CatalogLineItemSnapshot.decoded(from: catalogSnapshotJSON)
    }

    var subtotalAmount: Double {
        return max(amount - salesTaxAmount, 0)
    }

    var grossSubtotalAmount: Double {
        BillingTaxPolicy.snapshotGrossSubtotal(catalogSnapshotJSON) ?? subtotalAmount
    }

    var documentDiscount: AuthorizedDocumentDiscount? {
        CatalogLineItemSnapshot.documentDiscount(from: catalogSnapshotJSON)
    }

    var documentDiscountAmount: Double {
        documentDiscount?.amount(for: grossSubtotalAmount) ?? 0
    }

    var hasTaxableLines: Bool {
        BillingTaxPolicy.hasTaxableLines(catalogSnapshotJSON)
    }

    var taxCalculationStatus: BillingTaxCalculationStatus {
        BillingTaxPolicy.resolvedStatus(
            storedRawValue: taxCalculationStatusRawValue,
            snapshotJSON: catalogSnapshotJSON,
            quickBooksID: quickBooksID
        )
    }

    var customerApprovalBlockedMessage: String? {
        BillingTaxPolicy.customerCommitmentBlockedMessage(
            status: taxCalculationStatus,
            documentName: "estimate"
        )
    }

    @discardableResult
    func applyQuickBooksTaxResult(
        total: Double,
        reportedTax: Double?,
        at date: Date = Date()
    ) -> String? {
        let reconciliation = BillingTaxPolicy.reconcile(
            snapshotJSON: catalogSnapshotJSON,
            quickBooksTotal: total,
            reportedTax: reportedTax
        )
        taxCalculationStatusRawValue = reconciliation.status.rawValue
        taxCalculatedAt = date
        guard reconciliation.attentionDetail == nil else {
            return reconciliation.attentionDetail
        }
        amount = reconciliation.total
        salesTaxAmount = reconciliation.salesTax
        return reconciliation.attentionDetail
    }

    var hasRecordedCustomerApproval: Bool {
        guard status.caseInsensitiveCompare("accepted") == .orderedSame,
              customerApprovedAt != nil,
              customerApprovedByName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              let customerApprovalMethod else {
            return false
        }
        if customerApprovalMethod.requiresSignature {
            guard let signature = customerApprovalSignatureImageBase64,
                  Data(base64Encoded: signature)?.isEmpty == false else {
                return false
            }
            return true
        }
        return customerApprovalReference?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var customerApprovalMethod: EstimateApprovalMethod? {
        guard let customerApprovalMethodRaw else { return nil }
        return EstimateApprovalMethod(rawValue: customerApprovalMethodRaw)
    }

    var isChangeOrder: Bool {
        parentEstimateID != nil
    }

    var proposalOptionKind: EstimateProposalOption? {
        guard let proposalOption else { return nil }
        return EstimateProposalOption(rawValue: proposalOption)
    }

    var isProposalOption: Bool {
        proposalGroupID != nil && proposalOptionKind != nil && proposalOptionKind != .standalone
    }

    var proposalOptionDisplayName: String {
        proposalOptionKind?.displayName ?? "Option"
    }

    var proposalOptionDisplayDetail: String {
        proposalIsRecommended ? "\(proposalOptionDisplayName) • Recommended" : proposalOptionDisplayName
    }

    var proposalLabel: String {
        if isChangeOrder { return "Change Order" }
        return proposalOptionKind?.displayName ?? "Estimate"
    }

    var proposalIsFinalized: Bool {
        hasRecordedCustomerApproval || ["accepted", "invoiced"].contains(status.lowercased())
    }

    @discardableResult
    func recordCustomerApproval(
        by name: String,
        method: EstimateApprovalMethod,
        reference: String? = nil,
        signatureImageBase64: String? = nil,
        recordedByEmail: String? = nil,
        at date: Date = Date()
    ) -> Bool {
        if hasRecordedCustomerApproval { return true }
        guard customerApprovalBlockedMessage == nil else { return false }

        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return false }

        let normalizedReference = reference?.trimmingCharacters(in: .whitespacesAndNewlines)
        if method.requiresSignature {
            guard let signatureImageBase64,
                  Data(base64Encoded: signatureImageBase64)?.isEmpty == false else {
                return false
            }
        } else if normalizedReference?.isEmpty != false {
            return false
        }

        status = "accepted"
        customerApprovedByName = normalizedName
        customerApprovedAt = date
        customerApprovalMethodRaw = method.rawValue
        customerApprovalReference = normalizedReference?.isEmpty == false ? normalizedReference : nil
        customerApprovalSignatureImageBase64 = method.requiresSignature ? signatureImageBase64 : nil
        let normalizedRecorder = recordedByEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        customerApprovalRecordedByEmail = normalizedRecorder?.isEmpty == false ? normalizedRecorder : nil
        return true
    }

    static func displayDeduplicated(_ estimates: [Estimate]) -> [Estimate] {
        var selectedByKey: [String: Estimate] = [:]
        for estimate in estimates {
            let key = displayDedupeKey(for: estimate)
            if let existing = selectedByKey[key] {
                selectedByKey[key] = preferredDisplayEstimate(existing, estimate)
            } else {
                selectedByKey[key] = estimate
            }
        }
        return selectedByKey.values.sorted { lhs, rhs in
            lhs.createdAt > rhs.createdAt
        }
    }

    private static func displayDedupeKey(for estimate: Estimate) -> String {
        if let proposalGroupID = estimate.proposalGroupID,
           let proposalOption = estimate.proposalOptionKind,
           proposalOption != .standalone {
            return "proposal:\(proposalGroupID.uuidString.lowercased()):\(proposalOption.rawValue)"
        }
        if estimate.parentEstimateID != nil {
            // Change orders are immutable revisions. Equal totals on the same
            // job are not evidence that two revisions are duplicates.
            return "change-order:\(estimate.id.uuidString.lowercased())"
        }
        if let serviceCallID = estimate.serviceCallID {
            return "call:\(serviceCallID.uuidString.lowercased()):\(String(format: "%.2f", estimate.amount))"
        }
        if let quickBooksID = estimate.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !quickBooksID.isEmpty {
            return "qb:\(quickBooksID.lowercased())"
        }
        guard let customer = estimate.customer else {
            return "unresolved-customer:\(estimate.id.uuidString.lowercased())"
        }
        let customerKey = customer.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let day = Calendar.current.startOfDay(for: estimate.createdAt).timeIntervalSince1970
        return "local:\(customerKey):\(String(format: "%.2f", estimate.amount)):\(Int(day))"
    }

    private static func preferredDisplayEstimate(_ lhs: Estimate, _ rhs: Estimate) -> Estimate {
        let lhsHasQuickBooks = lhs.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let rhsHasQuickBooks = rhs.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if lhsHasQuickBooks != rhsHasQuickBooks {
            return rhsHasQuickBooks ? rhs : lhs
        }
        return rhs.createdAt > lhs.createdAt ? rhs : lhs
    }
}

enum EstimateProposalPolicy {
    static func options(for estimate: Estimate, in estimates: [Estimate]) -> [Estimate] {
        guard let groupID = estimate.proposalGroupID else { return [estimate] }
        return estimates
            .filter { $0.proposalGroupID == groupID }
            .sorted {
                let lhsRank = $0.proposalOptionKind?.comparisonRank ?? .max
                let rhsRank = $1.proposalOptionKind?.comparisonRank ?? .max
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return $0.createdAt < $1.createdAt
            }
    }

    static func creationIssue(
        groupID: UUID,
        option: EstimateProposalOption,
        customerID: UUID,
        serviceCallID: UUID?,
        serviceLocationID: UUID?,
        in estimates: [Estimate]
    ) -> String? {
        guard option != .standalone else { return nil }
        let group = estimates.filter { $0.proposalGroupID == groupID }
        guard !group.isEmpty else { return nil }

        if group.contains(where: { $0.proposalOptionKind == option }) {
            return "This proposal set already contains a \(option.displayName) option. Resume that option or end the set before starting another."
        }
        if group.contains(where: { $0.customer?.id != customerID }) {
            return "A proposal set cannot mix customers. End the current set before creating this estimate."
        }
        if group.contains(where: { $0.serviceCallID != serviceCallID }) {
            return "A proposal set cannot span different jobs. End the current set before creating this estimate."
        }
        if group.contains(where: { $0.serviceLocationID != serviceLocationID }) {
            return "All proposal options must use the same service property. End the current set before changing the property."
        }
        if group.contains(where: \.proposalIsFinalized) {
            return "This proposal set is already approved or invoiced. Create a change order instead of adding another option."
        }
        if group.count >= 3 {
            return "Good, Better, and Best are already present. End this proposal set before creating another estimate."
        }
        return nil
    }

    static func selectionIssue(for estimate: Estimate, in estimates: [Estimate]) -> String? {
        guard estimate.isProposalOption else { return nil }
        let finalized = options(for: estimate, in: estimates).filter(\.proposalIsFinalized)
        if finalized.count > 1 {
            return "Proposal conflict: more than one option is finalized. An administrator must reconcile the approval evidence before billing or scheduling."
        }
        if let finalizedOption = finalized.first, finalizedOption.id != estimate.id {
            return "\(finalizedOption.proposalOptionDisplayName) is already approved. Create a change order to revise the selected scope."
        }
        return nil
    }

    @discardableResult
    static func select(_ estimate: Estimate, in estimates: [Estimate]) -> Bool {
        guard selectionIssue(for: estimate, in: estimates) == nil else { return false }
        guard estimate.isProposalOption else { return true }

        for option in options(for: estimate, in: estimates) {
            if option.id == estimate.id {
                if ["not-selected", "rejected"].contains(option.status.lowercased()) {
                    option.status = "pending"
                }
            } else if !option.proposalIsFinalized {
                option.status = "not-selected"
            }
        }
        return true
    }

    @discardableResult
    static func recordApproval(
        for estimate: Estimate,
        in estimates: [Estimate],
        customerName: String,
        method: EstimateApprovalMethod,
        reference: String?,
        signatureImageBase64: String?,
        recordedByEmail: String?
    ) -> Bool {
        guard select(estimate, in: estimates) else { return false }
        guard estimate.recordCustomerApproval(
            by: customerName,
            method: method,
            reference: reference,
            signatureImageBase64: signatureImageBase64,
            recordedByEmail: recordedByEmail
        ) else {
            return false
        }

        if estimate.isProposalOption {
            for option in options(for: estimate, in: estimates)
                where option.id != estimate.id && !option.proposalIsFinalized {
                option.status = "not-selected"
            }
        }
        return true
    }

    static func enforceSingleRecommendation(for estimate: Estimate, in estimates: [Estimate]) {
        guard estimate.isProposalOption, estimate.proposalIsRecommended else { return }
        for option in options(for: estimate, in: estimates) where option.id != estimate.id {
            option.proposalIsRecommended = false
        }
    }
}
