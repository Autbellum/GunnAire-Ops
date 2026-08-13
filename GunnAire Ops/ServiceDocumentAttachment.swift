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

@Model
final class ServiceDocumentAttachment {
    @Attribute(.unique) var id: UUID
    var customer: Customer?
    var serviceCallID: UUID?
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

    var canLinkToInvoiceReport: Bool {
        kind == .serviceReport
    }

    func canUploadToQuickBooksInvoice(_ invoice: Invoice) -> Bool {
        canLinkToInvoiceReport &&
            invoiceID == invoice.id &&
            quickBooksAttachableID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false &&
            invoice.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    func linkToInvoiceIfNeeded(_ invoice: Invoice) {
        if invoiceID == nil {
            invoiceID = invoice.id
        }
    }

    func linkedServiceCall(in serviceCalls: [ServiceCall]) -> ServiceCall? {
        guard let serviceCallID else { return nil }
        return serviceCalls.first { $0.id == serviceCallID }
    }

    func linkedInvoice(in invoices: [Invoice]) -> Invoice? {
        guard let invoiceID else { return nil }
        return invoices.first { $0.id == invoiceID }
    }

    func linkedEstimate(in estimates: [Estimate]) -> Estimate? {
        guard let estimateID else { return nil }
        return estimates.first { $0.id == estimateID }
    }

    func customerProfileDetailLines(
        serviceCalls: [ServiceCall],
        invoices: [Invoice],
        estimates: [Estimate],
        canViewFinancials: Bool
    ) -> [String] {
        var lines: [String] = []
        if let call = linkedServiceCall(in: serviceCalls) {
            lines.append("Job: \(call.type.displayName) - \(call.status.rawValue.capitalized)")
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
            lines.append("Attached to QuickBooks invoice")
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
        attachments
            .filter { attachment in
                attachment.kind == .serviceReport &&
                    attachment.serviceCallID == serviceCallID &&
                    attachment.invoiceID == invoiceID &&
                    attachment.estimateID == estimateID
            }
            .sorted { $0.createdAt > $1.createdAt }
            .first
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
