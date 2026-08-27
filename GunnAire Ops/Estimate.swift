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
