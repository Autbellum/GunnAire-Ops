import Foundation
import SwiftData

enum ServiceDocumentAttachmentKind: String, Codable, CaseIterable, Identifiable {
    case serviceReport = "service_report"
    case beforePhoto = "before_photo"
    case afterPhoto = "after_photo"
    case diagnosticPhoto = "diagnostic_photo"
    case customerDocument = "customer_document"
    case invoiceSupport = "invoice_support"
    case estimateSupport = "estimate_support"
    case receipt = "receipt"
    case other = "other"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .serviceReport: return "Service Report"
        case .beforePhoto: return "Before Photo"
        case .afterPhoto: return "After Photo"
        case .diagnosticPhoto: return "Diagnostic Photo"
        case .customerDocument: return "Customer Document"
        case .invoiceSupport: return "Invoice Support"
        case .estimateSupport: return "Estimate Support"
        case .receipt: return "Receipt"
        case .other: return "Other"
        }
    }

    var isPhoto: Bool {
        switch self {
        case .beforePhoto, .afterPhoto, .diagnosticPhoto:
            return true
        case .serviceReport, .customerDocument, .invoiceSupport, .estimateSupport, .receipt, .other:
            return false
        }
    }
}

struct EquipmentAttachmentGroup: Identifiable {
    let equipment: CustomerEquipment
    let attachments: [ServiceDocumentAttachment]

    var id: UUID { equipment.id }

    var serviceReportCount: Int {
        attachments.filter { $0.kind == .serviceReport }.count
    }

    var photoCount: Int {
        attachments.filter { $0.kind.isPhoto }.count
    }

    var billingDocumentCount: Int {
        attachments.filter { [.invoiceSupport, .estimateSupport, .receipt].contains($0.kind) }.count
    }

    var otherDocumentCount: Int {
        attachments.count - serviceReportCount - photoCount - billingDocumentCount
    }

    var latestAttachmentDate: Date? {
        attachments.map(\.createdAt).max()
    }

    var summary: String {
        let parts = [
            countedLabel(serviceReportCount, singular: "report", plural: "reports"),
            countedLabel(photoCount, singular: "photo", plural: "photos"),
            countedLabel(billingDocumentCount, singular: "billing file", plural: "billing files"),
            countedLabel(otherDocumentCount, singular: "file", plural: "files")
        ].compactMap { $0 }
        return parts.isEmpty ? "No files" : parts.joined(separator: " - ")
    }

    private func countedLabel(_ count: Int, singular: String, plural: String) -> String? {
        guard count > 0 else { return nil }
        return "\(count) \(count == 1 ? singular : plural)"
    }
}

@Model
final class ServiceDocumentAttachment {
    @Attribute(.unique) var id: UUID
    var customer: Customer?
    var serviceCallID: UUID?
    var customerEquipmentID: UUID?
    var invoiceID: UUID?
    var estimateID: UUID?
    var kindRaw: String
    var displayName: String
    var caption: String?
    var localFilePath: String
    var contentType: String
    var fileSizeBytes: Int
    var backendDocumentID: String?
    var quickBooksAttachableID: String?
    var quickBooksSyncError: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        customer: Customer?,
        serviceCallID: UUID?,
        customerEquipmentID: UUID? = nil,
        invoiceID: UUID? = nil,
        estimateID: UUID? = nil,
        kind: ServiceDocumentAttachmentKind,
        displayName: String,
        caption: String? = nil,
        localFilePath: String,
        contentType: String,
        fileSizeBytes: Int,
        backendDocumentID: String? = nil,
        quickBooksAttachableID: String? = nil,
        quickBooksSyncError: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.customer = customer
        self.serviceCallID = serviceCallID
        self.customerEquipmentID = customerEquipmentID
        self.invoiceID = invoiceID
        self.estimateID = estimateID
        self.kindRaw = kind.rawValue
        self.displayName = displayName
        self.caption = caption
        self.localFilePath = localFilePath
        self.contentType = contentType
        self.fileSizeBytes = fileSizeBytes
        self.backendDocumentID = backendDocumentID
        self.quickBooksAttachableID = quickBooksAttachableID
        self.quickBooksSyncError = quickBooksSyncError
        self.createdAt = createdAt
    }

    var kind: ServiceDocumentAttachmentKind {
        get { ServiceDocumentAttachmentKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }

    var localFileURL: URL {
        URL(fileURLWithPath: localFilePath)
    }

    var isImage: Bool {
        contentType.lowercased().hasPrefix("image/")
    }

    var canUseAsCustomerProfilePhoto: Bool {
        guard isImage else { return false }
        switch kind {
        case .beforePhoto, .afterPhoto, .diagnosticPhoto, .customerDocument, .other:
            return true
        case .serviceReport, .invoiceSupport, .estimateSupport, .receipt:
            return false
        }
    }

    var canShowInActiveEquipmentHistory: Bool {
        switch kind {
        case .serviceReport, .beforePhoto, .afterPhoto, .diagnosticPhoto, .customerDocument, .other:
            return true
        case .invoiceSupport, .estimateSupport, .receipt:
            return false
        }
    }

    var canLinkToInvoiceReport: Bool {
        kind == .serviceReport
    }

    var canLinkToQuickBooksInvoiceAttachment: Bool {
        switch kind {
        case .serviceReport, .beforePhoto, .afterPhoto, .diagnosticPhoto, .customerDocument, .invoiceSupport, .estimateSupport, .other:
            return true
        case .receipt:
            return false
        }
    }

    var canLinkToQuickBooksInvoiceDocument: Bool {
        switch kind {
        case .serviceReport, .beforePhoto, .afterPhoto, .diagnosticPhoto, .customerDocument, .invoiceSupport, .other:
            return true
        case .estimateSupport, .receipt:
            return false
        }
    }

    var canLinkToQuickBooksEstimateDocument: Bool {
        switch kind {
        case .serviceReport, .beforePhoto, .afterPhoto, .diagnosticPhoto, .customerDocument, .estimateSupport, .other:
            return true
        case .invoiceSupport, .receipt:
            return false
        }
    }

    func canUploadToQuickBooksInvoice(_ invoice: Invoice) -> Bool {
        canLinkToQuickBooksInvoiceDocument &&
            invoiceID == invoice.id &&
            quickBooksAttachableID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false &&
            invoice.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false &&
            customerMatches(invoice.customer)
    }

    func canUploadToQuickBooksEstimate(_ estimate: Estimate) -> Bool {
        canLinkToQuickBooksEstimateDocument &&
            estimateID == estimate.id &&
            quickBooksAttachableID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false &&
            estimate.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false &&
            customerMatches(estimate.customer)
    }

    func linkToInvoiceIfNeeded(_ invoice: Invoice) {
        if invoiceID == nil {
            invoiceID = invoice.id
        }
    }

    func linkToEstimateIfNeeded(_ estimate: Estimate) {
        if estimateID == nil {
            estimateID = estimate.id
        }
    }

    func linkedServiceCall(in serviceCalls: [ServiceCall]) -> ServiceCall? {
        guard let serviceCallID else { return nil }
        return serviceCalls.first { $0.id == serviceCallID }
    }

    func linkedEquipment(in equipmentProfiles: [CustomerEquipment]) -> CustomerEquipment? {
        guard let customerEquipmentID else { return nil }
        return equipmentProfiles.first { $0.id == customerEquipmentID }
    }

    func linkedInvoice(in invoices: [Invoice]) -> Invoice? {
        guard let invoiceID else { return nil }
        return invoices.first { $0.id == invoiceID }
    }

    func linkedEstimate(in estimates: [Estimate]) -> Estimate? {
        guard let estimateID else { return nil }
        return estimates.first { $0.id == estimateID }
    }

    func customerMatches(_ billingCustomer: Customer) -> Bool {
        guard let customer else { return true }
        return customer.id == billingCustomer.id
    }

    func customerProfileDetailLines(
        serviceCalls: [ServiceCall],
        invoices: [Invoice],
        estimates: [Estimate],
        equipmentProfiles: [CustomerEquipment],
        canViewFinancials: Bool
    ) -> [String] {
        var lines: [String] = []
        if let equipment = linkedEquipment(in: equipmentProfiles) {
            lines.append("Equipment: \(equipment.displayName)")
        }
        if let call = linkedServiceCall(in: serviceCalls) {
            lines.append("Job: \(call.type.displayName) - \(call.status.rawValue.capitalized)")
            if kind == .serviceReport {
                if let blockedMessage = call.documentationCompletionBlockedMessage {
                    lines.append(blockedMessage)
                } else {
                    lines.append("Report: Ready")
                }
                if let summary = call.serviceReportSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !summary.isEmpty {
                    lines.append("Summary: \(summary)")
                }
                if let readings = call.technicalReadingServiceHistorySummary?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !readings.isEmpty {
                    lines.append("Readings: \(readings)")
                }
            }
        }
        if canViewFinancials, let invoice = linkedInvoice(in: invoices) {
            let quickBooksStatus = invoice.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? " - QuickBooks synced"
                : ""
            lines.append("Invoice: \(invoice.status.capitalized)\(quickBooksStatus)")
        }
        if canViewFinancials, let estimate = linkedEstimate(in: estimates) {
            let quickBooksStatus = estimate.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? " - QuickBooks synced"
                : ""
            lines.append("Estimate: \(estimate.status.capitalized)\(quickBooksStatus)")
        }
        if quickBooksAttachableID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            if estimateID != nil && invoiceID == nil {
                lines.append("Attached to QuickBooks estimate")
            } else if invoiceID != nil {
                lines.append("Attached to QuickBooks invoice")
            } else {
                lines.append("Attached to QuickBooks")
            }
        } else if canViewFinancials,
                  let quickBooksSyncError,
                  !quickBooksSyncError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("QuickBooks attachment failed: \(quickBooksSyncError)")
        }
        if backendDocumentID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            lines.append("Synced to company storage")
        }
        return lines
    }

    static func reusableGeneratedServiceReport(
        in attachments: [ServiceDocumentAttachment],
        serviceCallID: UUID,
        invoiceID: UUID?,
        estimateID: UUID?
    ) -> ServiceDocumentAttachment? {
        let matchingJobReports = attachments
            .filter { attachment in
                attachment.kind == .serviceReport &&
                    attachment.serviceCallID == serviceCallID
            }
        let exactMatch = matchingJobReports
            .filter { attachment in
                attachment.invoiceID == invoiceID &&
                    attachment.estimateID == estimateID
            }
            .sorted { $0.createdAt > $1.createdAt }
            .first
        if let exactMatch {
            return exactMatch
        }

        return matchingJobReports
            .filter { attachment in
                attachment.invoiceID == nil &&
                    attachment.estimateID == nil
            }
            .sorted { $0.createdAt > $1.createdAt }
            .first
    }

    static func reusableGeneratedBillingDocument(
        in attachments: [ServiceDocumentAttachment],
        kind: ServiceDocumentAttachmentKind,
        serviceCallID: UUID?,
        invoiceID: UUID?,
        estimateID: UUID?
    ) -> ServiceDocumentAttachment? {
        attachments
            .filter { attachment in
                attachment.kind == kind &&
                    attachment.serviceCallID == serviceCallID &&
                    attachment.invoiceID == invoiceID &&
                    attachment.estimateID == estimateID
            }
            .sorted { $0.createdAt > $1.createdAt }
            .first
    }

    static func equipmentHistoryAttachments(
        for serviceCall: ServiceCall,
        in attachments: [ServiceDocumentAttachment]
    ) -> [ServiceDocumentAttachment] {
        guard let equipmentID = serviceCall.customerEquipmentID else { return [] }
        return attachments
            .filter { attachment in
                attachment.customerEquipmentID == equipmentID &&
                    attachment.serviceCallID != serviceCall.id &&
                    attachment.canShowInActiveEquipmentHistory
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    static func groupedEquipmentAttachments(
        equipmentProfiles: [CustomerEquipment],
        attachments: [ServiceDocumentAttachment]
    ) -> [EquipmentAttachmentGroup] {
        equipmentProfiles
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            .compactMap { equipment in
                let matching = attachments
                    .filter { $0.customerEquipmentID == equipment.id }
                    .sorted { $0.createdAt > $1.createdAt }
                guard !matching.isEmpty else { return nil }
                return EquipmentAttachmentGroup(equipment: equipment, attachments: matching)
            }
    }

    static func primaryCustomerPhoto(
        for customer: Customer,
        in attachments: [ServiceDocumentAttachment]
    ) -> ServiceDocumentAttachment? {
        attachments
            .filter { attachment in
                attachment.customer?.id == customer.id &&
                    attachment.canUseAsCustomerProfilePhoto
            }
            .sorted { lhs, rhs in
                let lhsScore = customerProfilePhotoScore(lhs)
                let rhsScore = customerProfilePhotoScore(rhs)
                if lhsScore == rhsScore {
                    return lhs.createdAt > rhs.createdAt
                }
                return lhsScore > rhsScore
            }
            .first
    }

    private static func customerProfilePhotoScore(_ attachment: ServiceDocumentAttachment) -> Int {
        let searchableText = [
            attachment.caption,
            attachment.displayName
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .joined(separator: " ")
        if searchableText.contains("profile") || searchableText.contains("customer photo") {
            return 300
        }
        if attachment.kind == .diagnosticPhoto {
            return 200
        }
        if attachment.kind.isPhoto {
            return 150
        }
        return 100
    }

    func replaceGeneratedFile(
        displayName: String,
        localFilePath: String,
        contentType: String,
        fileSizeBytes: Int,
        caption: String?
    ) {
        self.displayName = displayName
        self.localFilePath = localFilePath
        self.contentType = contentType
        self.fileSizeBytes = fileSizeBytes
        self.caption = caption
        self.quickBooksAttachableID = nil
        self.quickBooksSyncError = nil
        self.createdAt = Date()
    }
}
