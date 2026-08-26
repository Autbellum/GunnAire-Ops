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

@Model
final class Estimate {
    var id: UUID = UUID()
    var serviceCallID: UUID?
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
    var status: String = "pending" // pending, accepted, rejected, invoiced, etc.
    var customerApprovedByName: String?
    var customerApprovedAt: Date?
    var notes: String?
    var createdAt: Date = Date()
    
    init(
        id: UUID = UUID(),
        serviceCallID: UUID? = nil,
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
        status: String = "pending",
        customerApprovedByName: String? = nil,
        customerApprovedAt: Date? = nil,
        notes: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.serviceCallID = serviceCallID
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
        self.status = status
        self.customerApprovedByName = customerApprovedByName
        self.customerApprovedAt = customerApprovedAt
        self.notes = notes
        self.createdAt = createdAt
    }

    var catalogLineSnapshots: [CatalogLineItemSnapshot] {
        CatalogLineItemSnapshot.decoded(from: catalogSnapshotJSON)
    }

    var hasRecordedCustomerApproval: Bool {
        status.caseInsensitiveCompare("accepted") == .orderedSame && customerApprovedAt != nil
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

    func recordCustomerApproval(by name: String? = nil, at date: Date = Date()) {
        status = "accepted"
        let normalizedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if customerApprovedByName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            customerApprovedByName = normalizedName?.isEmpty == false ? normalizedName : customer.name
        }
        customerApprovedAt = customerApprovedAt ?? date
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
        if let serviceCallID = estimate.serviceCallID {
            return "call:\(serviceCallID.uuidString.lowercased()):\(String(format: "%.2f", estimate.amount))"
        }
        if let quickBooksID = estimate.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !quickBooksID.isEmpty {
            return "qb:\(quickBooksID.lowercased())"
        }
        let customerKey = estimate.customer.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
