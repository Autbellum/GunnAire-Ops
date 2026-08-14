import Foundation
import SwiftData

enum ServiceDocumentAttachmentKind: String, Codable, CaseIterable, Identifiable {
    case serviceReport = "service_report"
    case beforePhoto = "before_photo"
    case afterPhoto = "after_photo"
    case diagnosticPhoto = "diagnostic_photo"
    case customerProfilePhoto = "customer_profile_photo"
    case equipmentDataPlatePhoto = "equipment_data_plate_photo"
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
        case .customerProfilePhoto: return "Customer Profile Photo"
        case .equipmentDataPlatePhoto: return "Equipment Data Plate Photo"
        case .customerDocument: return "Customer Document"
        case .invoiceSupport: return "Invoice Support"
        case .estimateSupport: return "Estimate Support"
        case .receipt: return "Receipt"
        case .other: return "Other"
        }
    }

    var isPhoto: Bool {
        switch self {
        case .beforePhoto, .afterPhoto, .diagnosticPhoto, .customerProfilePhoto, .equipmentDataPlatePhoto:
            return true
        case .serviceReport, .customerDocument, .invoiceSupport, .estimateSupport, .receipt, .other:
            return false
        }
    }

    var isFinancialCustomerProfileAttachment: Bool {
        switch self {
        case .invoiceSupport, .estimateSupport, .receipt:
            return true
        case .serviceReport, .beforePhoto, .afterPhoto, .diagnosticPhoto, .customerProfilePhoto, .equipmentDataPlatePhoto, .customerDocument, .other:
            return false
        }
    }

    var customerProfileGroupTitle: String {
        switch self {
        case .serviceReport:
            return "Service Reports"
        case .estimateSupport:
            return "Estimate Documents"
        case .invoiceSupport:
            return "Invoice Documents"
        case .receipt:
            return "Receipts & Bills"
        case .beforePhoto, .afterPhoto, .diagnosticPhoto, .customerProfilePhoto, .equipmentDataPlatePhoto:
            return "Photos"
        case .customerDocument, .other:
            return "Customer Files"
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

    var dataPlatePhotoCount: Int {
        attachments.filter { $0.kind == .equipmentDataPlatePhoto }.count
    }

    var photoCount: Int {
        attachments.filter { $0.kind.isPhoto && $0.kind != .equipmentDataPlatePhoto }.count
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
            countedLabel(dataPlatePhotoCount, singular: "data plate", plural: "data plates"),
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
    var quickBooksAttachedEntityKeysRaw: String?
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
        quickBooksAttachedEntityKeysRaw: String? = nil,
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
        self.quickBooksAttachedEntityKeysRaw = quickBooksAttachedEntityKeysRaw
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
        case .beforePhoto, .afterPhoto, .diagnosticPhoto, .customerProfilePhoto, .customerDocument, .other:
            return true
        case .equipmentDataPlatePhoto, .serviceReport, .invoiceSupport, .estimateSupport, .receipt:
            return false
        }
    }

    var canShowInActiveEquipmentHistory: Bool {
        switch kind {
        case .serviceReport, .beforePhoto, .afterPhoto, .diagnosticPhoto, .customerProfilePhoto, .equipmentDataPlatePhoto, .customerDocument, .other:
            return true
        case .invoiceSupport, .estimateSupport, .receipt:
            return false
        }
    }

    var isFinancialCustomerProfileAttachment: Bool {
        kind.isFinancialCustomerProfileAttachment
    }

    var canLinkToInvoiceReport: Bool {
        kind == .serviceReport
    }

    var canLinkToQuickBooksInvoiceAttachment: Bool {
        switch kind {
        case .serviceReport, .beforePhoto, .afterPhoto, .diagnosticPhoto, .equipmentDataPlatePhoto, .customerDocument, .invoiceSupport, .estimateSupport, .other:
            return true
        case .customerProfilePhoto, .receipt:
            return false
        }
    }

    var canLinkToQuickBooksInvoiceDocument: Bool {
        switch kind {
        case .serviceReport, .beforePhoto, .afterPhoto, .diagnosticPhoto, .equipmentDataPlatePhoto, .customerDocument, .invoiceSupport, .other:
            return true
        case .customerProfilePhoto, .estimateSupport, .receipt:
            return false
        }
    }

    var canLinkToQuickBooksEstimateDocument: Bool {
        switch kind {
        case .serviceReport, .beforePhoto, .afterPhoto, .diagnosticPhoto, .equipmentDataPlatePhoto, .customerDocument, .estimateSupport, .other:
            return true
        case .customerProfilePhoto, .invoiceSupport, .receipt:
            return false
        }
    }

    func canUploadToQuickBooksInvoice(_ invoice: Invoice) -> Bool {
        guard canLinkToQuickBooksInvoiceDocument,
            invoiceID == invoice.id &&
            invoice.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false &&
            customerMatches(invoice.customer),
            let reference = quickBooksInvoiceReference(for: invoice) else {
            return false
        }
        return !isQuickBooksAttached(to: [reference])
    }

    func canBePendingQuickBooksInvoiceAttachment(for invoice: Invoice) -> Bool {
        guard canLinkToQuickBooksInvoiceDocument,
            (invoiceID == nil || invoiceID == invoice.id) &&
            invoice.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false &&
            customerMatches(invoice.customer),
            let reference = quickBooksInvoiceReference(for: invoice) else {
            return false
        }
        return !isQuickBooksAttached(to: [reference])
    }

    func canUploadToQuickBooksEstimate(_ estimate: Estimate) -> Bool {
        guard canLinkToQuickBooksEstimateDocument,
            estimateID == estimate.id &&
            estimate.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false &&
            customerMatches(estimate.customer),
            let reference = quickBooksEstimateReference(for: estimate) else {
            return false
        }
        return !isQuickBooksAttached(to: [reference])
    }

    func linkToInvoiceIfNeeded(_ invoice: Invoice) {
        if invoiceID == nil {
            invoiceID = invoice.id
            clearQuickBooksAttachmentSyncStateIfTargetTrackingIsUnsafe()
        }
        if customer?.id != invoice.customer.id {
            customer = invoice.customer
        }
    }

    func linkToEstimateIfNeeded(_ estimate: Estimate) {
        if estimateID == nil {
            estimateID = estimate.id
            clearQuickBooksAttachmentSyncStateIfTargetTrackingIsUnsafe()
        }
        if customer?.id != estimate.customer.id {
            customer = estimate.customer
        }
    }

    private func clearQuickBooksAttachmentSyncState() {
        quickBooksAttachableID = nil
        quickBooksSyncError = nil
        quickBooksAttachedEntityKeysRaw = nil
    }

    private func clearQuickBooksAttachmentSyncStateIfTargetTrackingIsUnsafe() {
        if quickBooksAttachableID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false &&
            quickBooksAttachedEntityKeys.isEmpty {
            clearQuickBooksAttachmentSyncState()
        } else {
            quickBooksSyncError = nil
        }
    }

    func refreshGeneratedDocumentContext(
        customer: Customer,
        serviceCallID: UUID?,
        customerEquipmentID: UUID?,
        invoiceID: UUID?,
        estimateID: UUID?
    ) {
        let changedQuickBooksTarget = self.invoiceID != invoiceID || self.estimateID != estimateID
        self.customer = customer
        self.serviceCallID = serviceCallID
        self.customerEquipmentID = customerEquipmentID
        self.invoiceID = invoiceID
        self.estimateID = estimateID
        if changedQuickBooksTarget {
            clearQuickBooksAttachmentSyncStateIfTargetTrackingIsUnsafe()
        }
    }

    var quickBooksAttachedEntityKeys: Set<String> {
        get {
            guard let quickBooksAttachedEntityKeysRaw else { return [] }
            return Set(
                quickBooksAttachedEntityKeysRaw
                    .components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        }
        set {
            let sortedKeys = newValue
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .sorted()
            quickBooksAttachedEntityKeysRaw = sortedKeys.isEmpty ? nil : sortedKeys.joined(separator: "\n")
        }
    }

    func markQuickBooksAttached(to references: [QuickBooksAttachableReference]) {
        var keys = quickBooksAttachedEntityKeys
        for reference in references {
            let key = Self.quickBooksAttachedEntityKey(
                type: reference.EntityRef.type,
                value: reference.EntityRef.value
            )
            if !key.isEmpty {
                keys.insert(key)
            }
        }
        quickBooksAttachedEntityKeys = keys
    }

    func isQuickBooksAttached(to references: [QuickBooksAttachableReference]) -> Bool {
        if quickBooksAttachableID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            return false
        }
        let requiredKeys = references
            .map { Self.quickBooksAttachedEntityKey(type: $0.EntityRef.type, value: $0.EntityRef.value) }
            .filter { !$0.isEmpty }
        guard !requiredKeys.isEmpty else { return true }
        let syncedKeys = quickBooksAttachedEntityKeys
        guard !syncedKeys.isEmpty else {
            return true
        }
        return requiredKeys.allSatisfy { syncedKeys.contains($0) }
    }

    func quickBooksInvoiceReference(for invoice: Invoice) -> QuickBooksAttachableReference? {
        guard let quickBooksID = invoice.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !quickBooksID.isEmpty else { return nil }
        return QuickBooksAttachableReference(
            EntityRef: QuickBooksAttachableEntityRef(type: QuickBooksAttachableEntityType.invoice.rawValue, value: quickBooksID),
            IncludeOnSend: true
        )
    }

    func quickBooksEstimateReference(for estimate: Estimate) -> QuickBooksAttachableReference? {
        guard let quickBooksID = estimate.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !quickBooksID.isEmpty else { return nil }
        return QuickBooksAttachableReference(
            EntityRef: QuickBooksAttachableEntityRef(type: QuickBooksAttachableEntityType.estimate.rawValue, value: quickBooksID),
            IncludeOnSend: true
        )
    }

    static func quickBooksAttachedEntityKey(type: String, value: String) -> String {
        let normalizedType = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedType.isEmpty, !normalizedValue.isEmpty else { return "" }
        return "\(normalizedType):\(normalizedValue)"
    }

    func linkedServiceCall(in serviceCalls: [ServiceCall]) -> ServiceCall? {
        guard let serviceCallID else { return nil }
        return serviceCalls.first { $0.id == serviceCallID }
    }

    func linkedEquipment(in equipmentProfiles: [CustomerEquipment], serviceCalls: [ServiceCall] = []) -> CustomerEquipment? {
        let resolvedEquipmentID = customerEquipmentID ?? linkedServiceCall(in: serviceCalls)?.customerEquipmentID
        guard let resolvedEquipmentID else { return nil }
        return equipmentProfiles.first { $0.id == resolvedEquipmentID }
    }

    func linkedInvoice(in invoices: [Invoice]) -> Invoice? {
        guard let invoiceID else { return nil }
        return invoices.first { $0.id == invoiceID }
    }

    func linkedEstimate(in estimates: [Estimate]) -> Estimate? {
        guard let estimateID else { return nil }
        return estimates.first { $0.id == estimateID }
    }

    func refreshFromBackendDocument(
        _ document: BackendDocumentRecord,
        customer: Customer?,
        serviceCallID: UUID?,
        customerEquipmentID: UUID?,
        localFilePath: String,
        fileSizeBytes: Int
    ) {
        self.customer = customer
        self.serviceCallID = serviceCallID
        self.customerEquipmentID = customerEquipmentID
        invoiceID = document.invoiceUUID
        estimateID = document.estimateUUID
        kindRaw = document.kind
        displayName = document.filename
        caption = Self.normalizedBackendText(document.equipmentName)
        self.localFilePath = localFilePath
        contentType = document.contentType
        self.fileSizeBytes = fileSizeBytes
        backendDocumentID = document.id
    }

    static func localAttachment(
        from document: BackendDocumentRecord,
        existingAttachments: [ServiceDocumentAttachment],
        customer: Customer?,
        serviceCallID fallbackServiceCallID: UUID?,
        customerEquipmentID fallbackCustomerEquipmentID: UUID?,
        localFilePath: String,
        fileSizeBytes: Int
    ) -> ServiceDocumentAttachment {
        let serviceCallID = document.serviceCallUUID ?? fallbackServiceCallID
        let customerEquipmentID = document.customerEquipmentUUID ?? fallbackCustomerEquipmentID
        let invoiceID = document.invoiceUUID
        let estimateID = document.estimateUUID
        let existing = existingAttachments.first { attachment in
            attachment.backendDocumentID == document.id ||
                (
                    attachment.backendDocumentID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false &&
                    attachment.serviceCallID == serviceCallID &&
                    attachment.invoiceID == invoiceID &&
                    attachment.estimateID == estimateID &&
                    attachment.customerEquipmentID == customerEquipmentID &&
                    attachment.displayName == document.filename &&
                    attachment.kindRaw == document.kind
                )
        }
        if let existing {
            existing.refreshFromBackendDocument(
                document,
                customer: customer,
                serviceCallID: serviceCallID,
                customerEquipmentID: customerEquipmentID,
                localFilePath: localFilePath,
                fileSizeBytes: fileSizeBytes
            )
            return existing
        }

        return ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            customerEquipmentID: customerEquipmentID,
            invoiceID: invoiceID,
            estimateID: estimateID,
            kind: ServiceDocumentAttachmentKind(rawValue: document.kind) ?? .other,
            displayName: document.filename,
            caption: normalizedBackendText(document.equipmentName),
            localFilePath: localFilePath,
            contentType: document.contentType,
            fileSizeBytes: fileSizeBytes,
            backendDocumentID: document.id
        )
    }

    func customerMatches(_ billingCustomer: Customer) -> Bool {
        guard let customer else { return true }
        return customer.id == billingCustomer.id
    }

    private static func normalizedBackendText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    func customerProfileDetailLines(
        serviceCalls: [ServiceCall],
        invoices: [Invoice],
        estimates: [Estimate],
        equipmentProfiles: [CustomerEquipment],
        canViewFinancials: Bool
    ) -> [String] {
        var lines: [String] = [
            "Added: \(createdAt.formatted(date: .abbreviated, time: .shortened))"
        ]
        if fileSizeBytes > 0 {
            lines.append("Size: \(Self.formattedFileSize(fileSizeBytes))")
        }
        if !localFilePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let localStatus = FileManager.default.fileExists(atPath: localFilePath)
                ? "Available on this device"
                : "Not downloaded on this device"
            lines.append("Local File: \(localStatus)")
        }
        if let equipment = linkedEquipment(in: equipmentProfiles, serviceCalls: serviceCalls) {
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
                if let actions = call.serviceActionServiceHistorySummary?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !actions.isEmpty {
                    lines.append("Actions: \(actions)")
                }
                let openConcerns = call.openServiceConcernRows
                if !openConcerns.isEmpty {
                    let summary = openConcerns
                        .map { "\($0.label): \($0.value)" }
                        .joined(separator: "; ")
                    lines.append("Open Service Concerns: \(summary)")
                }
            }
        }
        if canViewFinancials, let invoice = linkedInvoice(in: invoices) {
            let quickBooksStatus = invoice.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? " - QuickBooks synced"
                : ""
            let resolvedInvoiceStatus = Invoice.resolvedStatus(for: invoice, payments: [])
            lines.append("Invoice: \(resolvedInvoiceStatus.capitalized)\(quickBooksStatus)")
            if invoice.hasQuickBooksBalance {
                let balance = Invoice.outstandingBalance(for: invoice, payments: [])
                lines.append("Invoice Balance: \(balance.formatted(.currency(code: "USD")))")
            }
        }
        if canViewFinancials, let estimate = linkedEstimate(in: estimates) {
            let quickBooksStatus = estimate.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? " - QuickBooks synced"
                : ""
            lines.append("Estimate: \(estimate.status.capitalized)\(quickBooksStatus)")
        }
        if canViewFinancials,
           quickBooksAttachableID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
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
        } else if canViewFinancials,
                  let invoice = linkedInvoice(in: invoices),
                  canBePendingQuickBooksInvoiceAttachment(for: invoice) {
            lines.append("Queued for QuickBooks invoice attachment")
        } else if canViewFinancials,
                  let estimate = linkedEstimate(in: estimates),
                  canUploadToQuickBooksEstimate(estimate) {
            lines.append("Queued for QuickBooks estimate attachment")
        }
        if backendDocumentID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            lines.append("Synced to company storage")
        }
        return lines
    }

    func matchesCustomerProfileSearch(
        _ query: String,
        serviceCalls: [ServiceCall],
        invoices: [Invoice],
        estimates: [Estimate],
        equipmentProfiles: [CustomerEquipment],
        canViewFinancials: Bool
    ) -> Bool {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else { return true }
        guard canViewFinancials || !isFinancialCustomerProfileAttachment else { return false }

        let detailLines = customerProfileDetailLines(
            serviceCalls: serviceCalls,
            invoices: invoices,
            estimates: estimates,
            equipmentProfiles: equipmentProfiles,
            canViewFinancials: canViewFinancials
        )
        let haystack = [
            displayName,
            caption,
            kind.label,
            kind.customerProfileGroupTitle,
            contentType
        ] + detailLines
        return haystack
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
            .contains(normalizedQuery)
    }

    func matchesJobAttachmentSearch(
        _ query: String,
        serviceCall: ServiceCall?,
        equipmentProfiles: [CustomerEquipment]
    ) -> Bool {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else { return true }

        let equipment = linkedEquipment(in: equipmentProfiles, serviceCalls: serviceCall.map { [$0] } ?? [])
        let concernRows = serviceCall?.openServiceConcernRows.map { "\($0.label) \($0.value)" } ?? []
        let haystack = [
            displayName,
            caption,
            kind.label,
            kind.customerProfileGroupTitle,
            contentType,
            backendDocumentID == nil ? nil : "company storage",
            quickBooksAttachableID == nil ? nil : "quickbooks",
            quickBooksSyncError == nil ? nil : "sync error",
            equipment?.name,
            equipment?.displayName,
            equipment?.equipmentType?.displayName,
            equipment?.manufacturer,
            equipment?.modelNumber,
            equipment?.serialNumber,
            equipment?.location,
            equipment?.filterSize,
            serviceCall?.eventTitle,
            serviceCall?.siteAddress,
            serviceCall?.equipmentName,
            serviceCall?.equipmentManufacturer,
            serviceCall?.equipmentModel,
            serviceCall?.equipmentSerialNumber,
            serviceCall?.equipmentLocation,
            serviceCall?.filterSize,
            serviceCall?.serviceReportSummary,
            serviceCall?.recommendedWorkSummary,
            serviceCall?.findingsSummary,
            serviceCall?.followUpAction,
            serviceCall?.nextServiceReportActionLabel,
            serviceCall?.serviceReportActionSummary,
            serviceCall?.serviceReportReadinessSummary,
            serviceCall?.technicalReadingServiceHistorySummary,
            serviceCall?.serviceActionServiceHistorySummary
        ] + concernRows

        return haystack
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .contains(normalizedQuery)
    }

    private static func formattedFileSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
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

        if invoiceID != nil, let estimateID {
            let estimateOnlyMatch = matchingJobReports
                .filter { attachment in
                    attachment.invoiceID == nil &&
                        attachment.estimateID == estimateID
                }
                .sorted { $0.createdAt > $1.createdAt }
                .first
            if let estimateOnlyMatch {
                return estimateOnlyMatch
            }
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
        in attachments: [ServiceDocumentAttachment],
        serviceCalls: [ServiceCall] = []
    ) -> [ServiceDocumentAttachment] {
        guard let equipmentID = serviceCall.customerEquipmentID else { return [] }
        return attachments
            .filter { attachment in
                let resolvedEquipmentID = attachment.customerEquipmentID ??
                    attachment.linkedServiceCall(in: serviceCalls)?.customerEquipmentID
                return resolvedEquipmentID == equipmentID &&
                    attachment.serviceCallID != serviceCall.id &&
                    attachment.canShowInActiveEquipmentHistory
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    static func backfillMissingEquipmentLinks(
        for serviceCall: ServiceCall,
        in attachments: [ServiceDocumentAttachment]
    ) -> Int {
        guard let equipmentID = serviceCall.customerEquipmentID else { return 0 }
        var updatedCount = 0
        for attachment in attachments where attachment.serviceCallID == serviceCall.id {
            guard attachment.customerEquipmentID == nil,
                  attachment.customer?.id == nil || attachment.customer?.id == serviceCall.customer.id else {
                continue
            }
            attachment.customerEquipmentID = equipmentID
            updatedCount += 1
        }
        return updatedCount
    }

    static func groupedEquipmentAttachments(
        equipmentProfiles: [CustomerEquipment],
        attachments: [ServiceDocumentAttachment],
        serviceCalls: [ServiceCall] = []
    ) -> [EquipmentAttachmentGroup] {
        equipmentProfiles
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            .compactMap { equipment in
                let matching = equipmentAttachments(
                    for: equipment,
                    in: attachments,
                    serviceCalls: serviceCalls
                )
                guard !matching.isEmpty else { return nil }
                return EquipmentAttachmentGroup(equipment: equipment, attachments: matching)
            }
    }

    static func equipmentAttachments(
        for equipment: CustomerEquipment,
        in attachments: [ServiceDocumentAttachment],
        serviceCalls: [ServiceCall] = []
    ) -> [ServiceDocumentAttachment] {
        attachments
            .filter { attachment in
                attachment.customerEquipmentID == equipment.id ||
                    attachment.linkedServiceCall(in: serviceCalls)?.customerEquipmentID == equipment.id
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    static func detachEquipmentProfileLinks(
        for equipment: CustomerEquipment,
        from attachments: [ServiceDocumentAttachment],
        serviceCalls: [ServiceCall] = []
    ) -> Int {
        var updatedCount = 0
        for attachment in attachments {
            if attachment.customerEquipmentID == equipment.id {
                attachment.customerEquipmentID = nil
                updatedCount += 1
            }
        }
        return updatedCount
    }

    func isLinkedToEquipment(
        equipmentProfiles: [CustomerEquipment],
        serviceCalls: [ServiceCall] = []
    ) -> Bool {
        linkedEquipment(in: equipmentProfiles, serviceCalls: serviceCalls) != nil
    }

    static func customerLevelAttachments(
        in attachments: [ServiceDocumentAttachment],
        equipmentProfiles: [CustomerEquipment],
        serviceCalls: [ServiceCall] = []
    ) -> [ServiceDocumentAttachment] {
        attachments.filter {
            !$0.isLinkedToEquipment(equipmentProfiles: equipmentProfiles, serviceCalls: serviceCalls)
        }
    }

    static func visibleCustomerProfileAttachments(
        in attachments: [ServiceDocumentAttachment],
        canViewFinancials: Bool
    ) -> [ServiceDocumentAttachment] {
        guard !canViewFinancials else { return attachments }
        return attachments.filter { !$0.isFinancialCustomerProfileAttachment }
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
        let isCustomerLevel = attachment.serviceCallID == nil && attachment.customerEquipmentID == nil
        if attachment.kind == .customerProfilePhoto {
            return isCustomerLevel ? 500 : 350
        }
        if searchableText.contains("profile") || searchableText.contains("customer photo") {
            return isCustomerLevel ? 400 : 300
        }
        if isCustomerLevel {
            return 250
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
        self.quickBooksAttachedEntityKeysRaw = nil
        self.createdAt = Date()
    }
}
