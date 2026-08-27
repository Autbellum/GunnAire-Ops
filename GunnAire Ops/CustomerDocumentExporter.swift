import Foundation
import UIKit

enum CustomerDocumentExportError: LocalizedError {
    case documentsDirectoryUnavailable

    var errorDescription: String? {
        switch self {
        case .documentsDirectoryUnavailable:
            return "The app documents folder is unavailable."
        }
    }
}

enum CustomerDocumentExporter {
    static func customerEmailAttachmentURLs(
        primaryDocumentURL: URL,
        serviceCallID: UUID?,
        invoiceID: UUID? = nil,
        estimateID: UUID? = nil,
        attachments: [ServiceDocumentAttachment]
    ) -> [URL] {
        var urls = [primaryDocumentURL]
        guard let serviceCallID else { return urls }

        let primaryPath = primaryDocumentURL.standardizedFileURL.path
        let onsiteReports = attachments
            .filter({
                $0.serviceCallID == serviceCallID &&
                    $0.kind == .serviceReport &&
                    !$0.localFilePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })
            .sorted(by: { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedDescending
                }
                return lhs.createdAt > rhs.createdAt
            })

        let latestOnsiteReport: ServiceDocumentAttachment?
        if let invoiceID {
            latestOnsiteReport = onsiteReports.first { $0.invoiceID == invoiceID } ??
                onsiteReports.first { report in
                    guard let estimateID else { return false }
                    return report.invoiceID == nil && report.estimateID == estimateID
                } ??
                singleConvertedEstimateReport(in: onsiteReports)
        } else if let estimateID {
            latestOnsiteReport = onsiteReports.first { $0.estimateID == estimateID }
        } else {
            latestOnsiteReport = onsiteReports.first
        }

        guard let latestOnsiteReport else {
            return urls
        }

        let onsiteReportURL = latestOnsiteReport.localFileURL.standardizedFileURL
        if onsiteReportURL.path != primaryPath {
            urls.append(onsiteReportURL)
        }
        return urls
    }

    private static func singleConvertedEstimateReport(in onsiteReports: [ServiceDocumentAttachment]) -> ServiceDocumentAttachment? {
        let convertedReports = onsiteReports.filter { report in
            report.invoiceID == nil && report.estimateID != nil
        }
        let estimateIDs = Set(convertedReports.compactMap(\.estimateID))
        guard estimateIDs.count == 1 else { return nil }
        return convertedReports.first
    }

    static func exportOnsiteReport(
        serviceCall: ServiceCall,
        estimate: Estimate?,
        invoice: Invoice?,
        payments: [Payment],
        attachments: [ServiceDocumentAttachment] = [],
        equipmentProfiles: [CustomerEquipment] = [],
        serviceCalls: [ServiceCall] = [],
        includeFinancials: Bool = true
    ) throws -> URL {
        let scopedAttachments = onsiteReportAttachments(
            for: attachments,
            serviceCall: serviceCall,
            estimate: estimate,
            invoice: invoice
        )
        let title = "\(serviceCall.type.displayName) Report"
        let fileName = makeFileName(
            prefix: "GunnAire-Onsite-Report",
            customerName: serviceCall.customer.name,
            descriptor: onsiteReportFileDescriptor(serviceCall: serviceCall, estimate: estimate, invoice: invoice)
        )
        let sections = onsiteReportSections(
            serviceCall: serviceCall,
            estimate: estimate,
            invoice: invoice,
            payments: payments,
            attachments: scopedAttachments,
            equipmentProfiles: equipmentProfiles,
            serviceCalls: serviceCalls,
            includeFinancials: includeFinancials
        )
        return try renderPDF(
            title: title,
            customer: serviceCall.customer,
            sections: sections,
            imageAttachments: scopedAttachments,
            imageServiceCall: serviceCall,
            imageEquipmentProfiles: equipmentProfiles,
            fileName: fileName
        )
    }

    static func exportEstimate(
        _ estimate: Estimate,
        serviceCall: ServiceCall?,
        attachments: [ServiceDocumentAttachment] = [],
        equipmentProfiles: [CustomerEquipment] = [],
        serviceCalls: [ServiceCall] = []
    ) throws -> URL {
        let fileName = makeFileName(prefix: "GunnAire-Estimate", customerName: estimate.customer.name)
        let sections = estimateSections(
            estimate: estimate,
            serviceCall: serviceCall,
            attachments: attachments,
            equipmentProfiles: equipmentProfiles,
            serviceCalls: serviceCalls
        )
        let title = estimate.isProposalOption ? "\(estimate.proposalOptionDisplayName) Estimate" : "Estimate"
        return try renderPDF(
            title: title,
            customer: estimate.customer,
            sections: sections,
            imageAttachments: billingPhotoAttachments(
                for: attachments,
                serviceCall: serviceCall,
                invoiceID: nil,
                estimateID: estimate.id
            ),
            approvalSignatureImageBase64: estimate.customerApprovalSignatureImageBase64,
            fileName: fileName
        )
    }

    static func exportInvoice(
        _ invoice: Invoice,
        serviceCall: ServiceCall?,
        payments: [Payment],
        attachments: [ServiceDocumentAttachment] = [],
        equipmentProfiles: [CustomerEquipment] = [],
        serviceCalls: [ServiceCall] = []
    ) throws -> URL {
        let paid = isInvoicePaid(invoice, payments: payments)
        let workPrefix = invoice.workType.displayName.replacingOccurrences(of: " ", with: "-")
        let fileName = makeFileName(prefix: paid ? "GunnAire-Paid-\(workPrefix)-Invoice" : "GunnAire-\(workPrefix)-Invoice", customerName: invoice.customer.name)
        let sections = invoiceSections(
            invoice: invoice,
            serviceCall: serviceCall,
            payments: payments,
            attachments: attachments,
            equipmentProfiles: equipmentProfiles,
            serviceCalls: serviceCalls
        )
        return try renderPDF(
            title: paid ? "Paid \(invoice.workType.documentTitle)" : invoice.workType.documentTitle,
            customer: invoice.customer,
            sections: sections,
            imageAttachments: billingPhotoAttachments(
                for: attachments,
                serviceCall: serviceCall,
                invoiceID: invoice.id,
                estimateID: nil
            ),
            approvalSignatureImageBase64: invoice.customerSignatureImageBase64,
            fileName: fileName
        )
    }

    static func exportPaidInvoice(
        _ invoice: Invoice,
        serviceCall: ServiceCall?,
        payments: [Payment],
        attachments: [ServiceDocumentAttachment] = [],
        equipmentProfiles: [CustomerEquipment] = [],
        serviceCalls: [ServiceCall] = []
    ) throws -> URL {
        try exportInvoice(
            invoice,
            serviceCall: serviceCall,
            payments: payments,
            attachments: attachments,
            equipmentProfiles: equipmentProfiles,
            serviceCalls: serviceCalls
        )
    }

    private static func onsiteReportSections(
        serviceCall: ServiceCall,
        estimate: Estimate?,
        invoice: Invoice?,
        payments: [Payment],
        attachments: [ServiceDocumentAttachment],
        equipmentProfiles: [CustomerEquipment],
        serviceCalls: [ServiceCall],
        includeFinancials: Bool = true
    ) -> [DocumentSection] {
        var sections: [DocumentSection] = [
            DocumentSection(
                title: "Job",
                rows: onsiteReportJobRows(for: serviceCall).map { row($0.label, $0.value) }
            ),
            linkedRecordSection(serviceCall: serviceCall, estimate: estimate, invoice: invoice, payments: payments, includeFinancials: includeFinancials),
            serviceReportReadinessSection(for: serviceCall),
            closeoutReadinessSection(
                for: serviceCall,
                invoice: invoice,
                payments: payments,
                attachments: attachments
            ),
            DocumentSection(
                title: "Equipment",
                rows: [
                    row("Type", serviceCall.equipmentType?.displayName),
                    row("Name", serviceCall.equipmentName),
                    row("Manufacturer", serviceCall.equipmentManufacturer),
                    row("Model", serviceCall.equipmentModel),
                    row("Serial", serviceCall.equipmentSerialNumber),
                    row("Location", serviceCall.equipmentLocation),
                    row("Install Date", serviceCall.equipmentInstallDate.map { formattedDate($0) }),
                    row("Warranty Expiration", serviceCall.equipmentWarrantyExpiration.map { formattedDate($0) }),
                    row("Filter Size", serviceCall.filterSize),
                    row("Filter Condition", serviceCall.filterCondition),
                    row("Equipment Notes", serviceCall.equipmentNotes)
                ]
            ),
            DocumentSection(
                title: "Service Notes",
                rows: [
                    row("Findings", serviceCall.findingsSummary),
                    row("Recommended Work", serviceCall.recommendedWorkSummary),
                    row("Notes", serviceCall.notes)
                ]
            ),
            checklistSection(for: serviceCall, attachments: attachments)
        ]

        if let equipmentHistorySection = equipmentHistorySection(
            serviceCall: serviceCall,
            equipmentProfiles: equipmentProfiles,
            serviceCalls: serviceCalls
        ) {
            sections.insert(equipmentHistorySection, at: 4)
        }

        sections.append(contentsOf: technicalReportSections(for: serviceCall))
        sections.append(contentsOf: photoEvidenceSections(
            for: attachments,
            serviceCall: serviceCall,
            estimate: estimate,
            invoice: invoice,
            equipmentProfiles: equipmentProfiles
        ))
        sections.append(contentsOf: attachmentSections(
            for: attachments,
            serviceCall: serviceCall,
            estimate: estimate,
            invoice: invoice,
            equipmentProfiles: equipmentProfiles
        ))

        if let estimate {
            sections.append(DocumentSection(
                title: "Estimate",
                rows: estimateDetailRows(for: estimate)
                    .filter { $0.label != "Created" && $0.label != "QuickBooks ID" }
                    .map { detailRow in
                        row(detailRow.label == "Total" ? "Amount" : detailRow.label, detailRow.value)
                    }
            ))
        }

        if let invoice {
            sections.append(contentsOf: invoiceSections(invoice: invoice, serviceCall: nil, payments: payments, includeCustomerHeader: false))
        }

        return sections
    }

    static func equipmentHistoryRows(
        serviceCall: ServiceCall,
        equipmentProfiles: [CustomerEquipment],
        serviceCalls: [ServiceCall],
        includeCurrentJob: Bool = true
    ) -> [(label: String, value: String)] {
        guard let equipment = matchingEquipmentProfile(
            for: serviceCall,
            equipmentProfiles: equipmentProfiles
        ) else { return [] }
        let relatedCalls = serviceCalls.filter {
            $0.customer.id == serviceCall.customer.id &&
                (includeCurrentJob || $0.id != serviceCall.id)
        }
        var rows: [(label: String, value: String)] = [
            ("Equipment Profile", equipment.displayName)
        ]
        if let history = equipment.serviceHistorySummary(in: relatedCalls, now: serviceCall.scheduledDate) {
            rows.append(("Service History", history))
        }
        if let latestContext = equipment.latestServiceContextSummary(
            in: relatedCalls.filter { $0.id != serviceCall.id },
            now: serviceCall.scheduledDate
        ) {
            rows.append(("Previous Service Context", latestContext))
        }
        if let trends = equipment.recentTechnicalTrendSummary(in: relatedCalls, now: serviceCall.scheduledDate) {
            rows.append(("Reading Trends", trends))
        } else if !includeCurrentJob,
                  let latestReadings = equipment.latestTechnicalReadingsSummary(
                    in: relatedCalls,
                    now: serviceCall.scheduledDate
                  ) {
            rows.append(("Reading Trends", latestReadings))
        }
        return rows.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func equipmentHistorySection(
        serviceCall: ServiceCall,
        equipmentProfiles: [CustomerEquipment],
        serviceCalls: [ServiceCall]
    ) -> DocumentSection? {
        let rows = equipmentHistoryRows(
            serviceCall: serviceCall,
            equipmentProfiles: equipmentProfiles,
            serviceCalls: serviceCalls
        )
        guard !rows.isEmpty else { return nil }
        return DocumentSection(
            title: "Equipment History",
            rows: rows.map { row($0.label, $0.value) }
        )
    }

    private static func matchingEquipmentProfile(
        for serviceCall: ServiceCall,
        equipmentProfiles: [CustomerEquipment]
    ) -> CustomerEquipment? {
        if let equipmentID = serviceCall.customerEquipmentID,
           let linked = equipmentProfiles.first(where: { $0.id == equipmentID }) {
            return linked
        }
        return equipmentProfiles.first {
            $0.customer?.id == serviceCall.customer.id && $0.matches(serviceCall)
        }
    }

    static func onsiteReportJobRows(for serviceCall: ServiceCall) -> [(label: String, value: String)] {
        [
            ("Customer", serviceCall.customer.name),
            ("Customer Address", serviceCall.customer.address ?? ""),
            ("Customer Phone", serviceCall.customer.phone ?? ""),
            ("Customer Email", serviceCall.customer.email ?? ""),
            ("Scheduled", formattedDateTime(serviceCall.scheduledDate)),
            ("Job Type", serviceCall.type.displayName),
            ("Status", serviceCall.status.rawValue.capitalized),
            ("Technician", serviceCall.assignedTechnician?.name ?? ""),
            ("Site Address", serviceCall.siteAddress ?? serviceCall.customer.address ?? "")
        ].filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    static func linkedRecordRows(
        serviceCall: ServiceCall,
        estimate: Estimate?,
        invoice: Invoice?,
        payments: [Payment] = [],
        includeFinancials: Bool = true
    ) -> [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = [
            ("Job ID", shortID(serviceCall.id))
        ]
        if let estimate {
            rows.append(("Estimate ID", shortID(estimate.id)))
            rows.append(("Estimate Status", estimate.status.capitalized))
            if let approvedAt = estimate.customerApprovedAt {
                rows.append(("Customer Approval", "\(estimate.customerApprovedByName ?? estimate.customer.name) • \(formattedDateTime(approvedAt))"))
            }
            if includeFinancials {
                rows.append(("Estimate Amount", currency(estimate.amount)))
            }
            if includeFinancials, let quickBooksID = normalizedValue(estimate.quickBooksID) {
                rows.append(("QuickBooks Estimate ID", quickBooksID))
            }
        } else if serviceCall.linkedEstimateID != nil {
            rows.append(("Estimate ID", shortID(serviceCall.linkedEstimateID)))
        }
        if let invoice {
            let resolvedStatus = Invoice.resolvedStatus(for: invoice, payments: payments)
            rows.append(("Invoice ID", shortID(invoice.id)))
            rows.append(("Invoice Status", resolvedStatus.capitalized))
            if includeFinancials {
                let balance = Invoice.outstandingBalance(for: invoice, payments: payments)
                rows.append(("Invoice Total", currency(invoice.amount)))
                rows.append(("Invoice Balance Due", currency(balance)))
            }
            if includeFinancials, let quickBooksID = normalizedValue(invoice.quickBooksID) {
                rows.append(("QuickBooks Invoice ID", quickBooksID))
            }
        } else if serviceCall.linkedInvoiceID != nil {
            rows.append(("Invoice ID", shortID(serviceCall.linkedInvoiceID)))
        }
        return rows
    }

    static func onsiteReportAttachmentCaption(
        serviceCall: ServiceCall,
        estimate: Estimate?,
        invoice: Invoice?,
        includeFinancials: Bool = true
    ) -> String {
        let details = linkedRecordRows(serviceCall: serviceCall, estimate: estimate, invoice: invoice, includeFinancials: includeFinancials)
            .filter { $0.label != "Job ID" || !$0.value.isEmpty }
            .map { "\($0.label): \($0.value)" }
            .joined(separator: " - ")
        let base = "Generated onsite \(serviceCall.type.displayName.lowercased()) report"
        return details.isEmpty ? base : "\(base) - \(details)"
    }

    private static func linkedRecordSection(
        serviceCall: ServiceCall,
        estimate: Estimate?,
        invoice: Invoice?,
        payments: [Payment],
        includeFinancials: Bool = true
    ) -> DocumentSection {
        DocumentSection(
            title: "Linked Records",
            rows: linkedRecordRows(serviceCall: serviceCall, estimate: estimate, invoice: invoice, payments: payments, includeFinancials: includeFinancials).map { row($0.label, $0.value) }
        )
    }

    static func serviceReportReadinessRows(for serviceCall: ServiceCall) -> [(label: String, value: String)] {
        let completionIssues = serviceCall.serviceReportMissingRequirementLabels
        let missing = serviceCall.serviceReportMissingRequiredItemLabels
        let validationIssues = serviceCall.serviceReportReadingValidationIssueLabels
        let safetyAlerts = serviceCall.serviceReportSafetyAlertLabels
        var rows: [(label: String, value: String)] = [
            ("Completion", completionIssues.isEmpty ? "Ready" : "Needs details"),
            ("Required Items", serviceCall.serviceReportReadinessSummary)
        ]
        if !safetyAlerts.isEmpty {
            rows.append(("Safety Alerts", safetyAlerts.joined(separator: ", ")))
        }
        if let nextAction = serviceCall.nextServiceReportActionLabel {
            rows.append(("Next Required Action", nextAction))
        }
        if let actionSummary = serviceCall.serviceReportActionSummary {
            rows.append(("Action Summary", actionSummary))
        }
        if !missing.isEmpty {
            rows.append(("Missing Required Items", missing.joined(separator: ", ")))
        }
        if !validationIssues.isEmpty {
            rows.append(("Reading Validation", validationIssues.joined(separator: ", ")))
        }
        return rows
    }

    private static func serviceReportReadinessSection(for serviceCall: ServiceCall) -> DocumentSection {
        DocumentSection(
            title: "Report Readiness",
            rows: serviceReportReadinessRows(for: serviceCall).map { row($0.label, $0.value) }
        )
    }

    static func closeoutReadinessRows(
        for serviceCall: ServiceCall,
        invoice: Invoice?,
        payments: [Payment],
        attachments: [ServiceDocumentAttachment]
    ) -> [(label: String, value: String)] {
        let readiness = serviceCall.closeoutReadiness(
            invoice: invoice,
            payments: payments,
            attachments: attachments
        )
        var rows: [(label: String, value: String)] = [
            ("Status", readiness.statusLabel),
            ("Progress", readiness.summary)
        ]
        if !readiness.missingItems.isEmpty {
            rows.append(("Missing Closeout Items", readiness.missingItems.joined(separator: ", ")))
        }
        return rows
    }

    private static func closeoutReadinessSection(
        for serviceCall: ServiceCall,
        invoice: Invoice?,
        payments: [Payment],
        attachments: [ServiceDocumentAttachment]
    ) -> DocumentSection {
        DocumentSection(
            title: "Closeout Readiness",
            rows: closeoutReadinessRows(
                for: serviceCall,
                invoice: invoice,
                payments: payments,
                attachments: attachments
            ).map { row($0.label, $0.value) }
        )
    }

    private static func technicalReportSections(for serviceCall: ServiceCall) -> [DocumentSection] {
        var sections: [DocumentSection] = []
        sections.append(contentsOf: technicalReportSectionSummaries(for: serviceCall).map { summary in
            DocumentSection(
                title: summary.title,
                rows: summary.rows.map { row($0.label, $0.value) }
            )
        })

        let conditionRows = [
            row("Indoor Coil", serviceCall.indoorCoilCondition),
            row("Outdoor Coil", serviceCall.outdoorCoilCondition),
            row("Drain Line", serviceCall.drainLineCondition),
            row("Thermostat", serviceCall.thermostatOperation),
            row("Report Summary", serviceCall.serviceReportSummary)
        ]
        if conditionRows.contains(where: { !$0.value.isEmpty }) {
            sections.append(DocumentSection(title: "Maintenance Observations", rows: conditionRows))
        }
        let actionRows = serviceCall.groupedServiceActionDefinitions.flatMap { group in
            group.definitions.compactMap { definition -> DocumentRow? in
                let status = serviceCall.serviceActionStatus(for: definition.key)
                if status == .notChecked {
                    return definition.required ? row("\(definition.label) Requirement", "Missing Required Action") : nil
                }
                return row("\(group.title) - \(definition.label)", status.label)
            }
        }
        if !actionRows.isEmpty {
            sections.append(DocumentSection(title: "Equipment Service Actions", rows: actionRows))
        }
        let safetyRows = serviceCall.serviceReportSafetyAlertLabels.map { row("Alert", $0) }
        if !safetyRows.isEmpty {
            sections.append(DocumentSection(title: "Safety Alerts", rows: safetyRows))
        }
        return sections
    }

    static func technicalReportSectionSummaries(for serviceCall: ServiceCall) -> [(title: String, rows: [(label: String, value: String)])] {
        let requiredDefinitions = Set(serviceCall.requiredTechnicalReadingDefinitions)
        return serviceCall.groupedTechnicalReadingDefinitions.compactMap { group -> (title: String, rows: [(label: String, value: String)])? in
            let rows = group.definitions.flatMap { definition -> [(label: String, value: String)] in
                let value = serviceCall.technicalReading(for: definition.key).trimmingCharacters(in: .whitespacesAndNewlines)
                let isRequired = requiredDefinitions.contains(definition)
                if value.isEmpty {
                    return isRequired
                        ? [(definition.displayLabel, "Missing Required Reading")]
                        : []
                }
                var rows: [(label: String, value: String)] = [(definition.displayLabel, value)]
                if isRequired { rows.append(("\(definition.displayLabel) Requirement", "Required")) }
                if let issue = serviceCall.technicalReadingValidationIssue(for: definition) {
                    rows.append(("\(definition.displayLabel) Validation", issue))
                }
                return rows
            }
            guard !rows.isEmpty else { return nil }
            return ("Technical Readings - \(group.title)", rows)
        }
    }

    private static func attachmentSections(
        for attachments: [ServiceDocumentAttachment],
        serviceCall: ServiceCall?,
        estimate: Estimate?,
        invoice: Invoice?,
        equipmentProfiles: [CustomerEquipment] = []
    ) -> [DocumentSection] {
        let rows = attachmentManifestSummaries(
            for: attachments,
            serviceCall: serviceCall,
            estimate: estimate,
            invoice: invoice,
            equipmentProfiles: equipmentProfiles
        ).map { summary in
            row(summary.label, summary.detail)
        }
        guard !rows.isEmpty else { return [] }
        return [DocumentSection(title: "Attached Job Files", rows: rows)]
    }

    private static func photoEvidenceSections(
        for attachments: [ServiceDocumentAttachment],
        serviceCall: ServiceCall?,
        estimate: Estimate?,
        invoice: Invoice?,
        equipmentProfiles: [CustomerEquipment] = []
    ) -> [DocumentSection] {
        let rows = photoEvidenceSummaries(
            for: attachments,
            serviceCall: serviceCall,
            estimate: estimate,
            invoice: invoice,
            equipmentProfiles: equipmentProfiles
        ).map { summary in
            row(summary.label, summary.detail)
        }
        guard !rows.isEmpty else { return [] }
        return [DocumentSection(title: "Photo Evidence", rows: rows)]
    }

    static func photoEvidenceSummaries(
        for attachments: [ServiceDocumentAttachment],
        serviceCall: ServiceCall? = nil,
        estimate: Estimate? = nil,
        invoice: Invoice? = nil,
        equipmentProfiles: [CustomerEquipment] = []
    ) -> [(label: String, detail: String)] {
        photoEvidenceAttachments(for: attachments)
            .map { attachment in
                let details = [
                    attachment.caption,
                    attachment.displayName,
                    formattedDateTime(attachment.createdAt),
                    attachmentEquipmentTrace(attachment, serviceCall: serviceCall, equipmentProfiles: equipmentProfiles),
                    attachmentRecordTrace(attachment, serviceCall: serviceCall, estimate: estimate, invoice: invoice)
                ]
                    .compactMap { value -> String? in
                        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            return nil
                        }
                        return value
                    }
                    .joined(separator: " - ")
                return (attachment.kind.label, details)
            }
    }

    static func photoEvidenceAttachments(for attachments: [ServiceDocumentAttachment]) -> [ServiceDocumentAttachment] {
        attachments
            .filter { $0.kind != .serviceReport }
            .filter { $0.kind != .customerProfilePhoto }
            .filter { $0.kind.isPhoto || $0.isImage }
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                }
                return lhs.createdAt < rhs.createdAt
            }
    }

    static func embeddedPhotoEvidenceAttachments(for attachments: [ServiceDocumentAttachment]) -> [ServiceDocumentAttachment] {
        photoEvidenceAttachments(for: attachments)
    }

    static func billingPhotoAttachments(
        for attachments: [ServiceDocumentAttachment],
        serviceCall: ServiceCall?,
        invoiceID: UUID?,
        estimateID: UUID?
    ) -> [ServiceDocumentAttachment] {
        guard let serviceCall else { return [] }
        return photoEvidenceAttachments(for: reportEvidenceAttachments(for: attachments, serviceCall: serviceCall))
            .filter { attachment in
                billingTargetMatches(attachment: attachment, invoiceID: invoiceID, estimateID: estimateID)
            }
    }

    static func onsiteReportAttachments(
        for attachments: [ServiceDocumentAttachment],
        serviceCall: ServiceCall,
        estimate: Estimate?,
        invoice: Invoice?
    ) -> [ServiceDocumentAttachment] {
        let invoiceID = invoice?.id ?? serviceCall.linkedInvoiceID
        let estimateID = estimate?.id ?? serviceCall.linkedEstimateID
        return reportEvidenceAttachments(for: attachments, serviceCall: serviceCall).filter { attachment in
            if let attachmentInvoiceID = attachment.invoiceID {
                return invoiceID == attachmentInvoiceID
            }
            if let attachmentEstimateID = attachment.estimateID {
                if invoiceID != nil {
                    return estimateID == attachmentEstimateID
                }
                return estimateID == attachmentEstimateID
            }
            return true
        }
    }

    static func reportEvidenceAttachments(
        for attachments: [ServiceDocumentAttachment],
        serviceCall: ServiceCall
    ) -> [ServiceDocumentAttachment] {
        attachments.filter { attachment in
            guard canIncludeInOnsiteReportEvidence(attachment) else {
                return false
            }
            if attachment.serviceCallID == serviceCall.id {
                return true
            }
            guard attachment.customerEquipmentID == serviceCall.customerEquipmentID,
                  attachment.serviceCallID == nil else {
                return false
            }
            return true
        }
    }

    private static func canIncludeInOnsiteReportEvidence(_ attachment: ServiceDocumentAttachment) -> Bool {
        switch attachment.kind {
        case .beforePhoto, .afterPhoto, .diagnosticPhoto, .equipmentDataPlatePhoto, .customerDocument, .other:
            return true
        case .serviceReport, .customerProfilePhoto, .invoiceSupport, .estimateSupport, .receipt:
            return false
        }
    }

    private static func billingTargetMatches(
        attachment: ServiceDocumentAttachment,
        invoiceID: UUID?,
        estimateID: UUID?
    ) -> Bool {
        if let invoiceID {
            if let attachmentInvoiceID = attachment.invoiceID {
                return attachmentInvoiceID == invoiceID
            }
            return attachment.estimateID == nil
        }
        if let estimateID {
            if attachment.invoiceID != nil {
                return false
            }
            if let attachmentEstimateID = attachment.estimateID {
                return attachmentEstimateID == estimateID
            }
            return true
        }
        return attachment.invoiceID == nil && attachment.estimateID == nil
    }

    static func photoAttachmentCaption(
        for attachment: ServiceDocumentAttachment,
        serviceCall: ServiceCall? = nil,
        equipmentProfiles: [CustomerEquipment] = []
    ) -> String {
        [
            attachment.kind.label,
            attachment.caption,
            attachment.displayName,
            attachmentEquipmentTrace(attachment, serviceCall: serviceCall, equipmentProfiles: equipmentProfiles),
            formattedDateTime(attachment.createdAt)
        ]
            .compactMap { value -> String? in
                guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return value
            }
            .joined(separator: " - ")
    }

    static func attachmentManifestSummaries(
        for attachments: [ServiceDocumentAttachment],
        serviceCall: ServiceCall? = nil,
        estimate: Estimate? = nil,
        invoice: Invoice? = nil,
        equipmentProfiles: [CustomerEquipment] = []
    ) -> [(label: String, detail: String)] {
        attachments
            .filter { $0.kind != .serviceReport }
            .sorted { lhs, rhs in
                if lhs.kind.label == rhs.kind.label {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.kind.label < rhs.kind.label
            }
            .map { attachment in
                let details = [
                    attachment.displayName,
                    attachment.caption,
                    attachment.fileSizeBytes > 0 ? formattedFileSize(attachment.fileSizeBytes) : nil,
                    attachmentEquipmentTrace(attachment, serviceCall: serviceCall, equipmentProfiles: equipmentProfiles),
                    attachmentRecordTrace(attachment, serviceCall: serviceCall, estimate: estimate, invoice: invoice),
                    attachmentQuickBooksTrace(attachment)
                ]
                    .compactMap { value -> String? in
                        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            return nil
                        }
                        return value
                    }
                    .joined(separator: " - ")
                return (attachment.kind.label, details)
            }
    }

    private static func attachmentRecordTrace(
        _ attachment: ServiceDocumentAttachment,
        serviceCall: ServiceCall?,
        estimate: Estimate?,
        invoice: Invoice?
    ) -> String? {
        var details: [String] = []
        let serviceCallID = attachment.serviceCallID ?? serviceCall?.id
        if let serviceCallID {
            details.append("Job ID: \(shortID(serviceCallID))")
        }
        let estimateID = attachment.estimateID ?? estimate?.id
        if let estimateID {
            details.append("Estimate ID: \(shortID(estimateID))")
        }
        let invoiceID = attachment.invoiceID ?? invoice?.id
        if let invoiceID {
            details.append("Invoice ID: \(shortID(invoiceID))")
        }
        return details.isEmpty ? nil : details.joined(separator: " | ")
    }

    private static func attachmentEquipmentTrace(
        _ attachment: ServiceDocumentAttachment,
        serviceCall: ServiceCall?,
        equipmentProfiles: [CustomerEquipment]
    ) -> String? {
        if let equipmentID = attachment.customerEquipmentID,
           let equipment = equipmentProfiles.first(where: { $0.id == equipmentID }) {
            return "Equipment: \(equipment.displayName)"
        }
        guard let serviceCall,
              attachment.serviceCallID == nil || attachment.serviceCallID == serviceCall.id else {
            return nil
        }
        if let equipment = matchingEquipmentProfile(for: serviceCall, equipmentProfiles: equipmentProfiles) {
            return "Equipment: \(equipment.displayName)"
        }
        return normalizedValue(serviceCall.equipmentSummary).map { "Equipment: \($0)" }
    }

    private static func attachmentQuickBooksTrace(_ attachment: ServiceDocumentAttachment) -> String? {
        if let attachableID = normalizedValue(attachment.quickBooksAttachableID) {
            return "QuickBooks Attachment ID: \(attachableID)"
        }
        if let error = normalizedValue(attachment.quickBooksSyncError) {
            return "QuickBooks Attachment Error: \(error)"
        }
        return nil
    }

    private static func estimateSections(
        estimate: Estimate,
        serviceCall: ServiceCall?,
        attachments: [ServiceDocumentAttachment] = [],
        equipmentProfiles: [CustomerEquipment] = [],
        serviceCalls: [ServiceCall] = []
    ) -> [DocumentSection] {
        var sections: [DocumentSection] = []
        if let serviceCall {
            sections.append(DocumentSection(
                title: "Job",
                rows: billingJobContextRows(
                    for: serviceCall,
                    equipmentProfiles: equipmentProfiles,
                    serviceCalls: serviceCalls
                )
            ))
            sections.append(contentsOf: billingDocumentationSections(for: serviceCall))
        }

        let documentationStatus = serviceCall?.estimateDocumentationStatus(estimate: estimate, attachments: attachments)
        sections.append(DocumentSection(
            title: "Estimate Detail",
            rows: estimateDetailRows(for: estimate, documentationStatus: documentationStatus).map { row($0.label, $0.value) }
        ))
        return sections
    }

    static func estimateDetailRows(
        for estimate: Estimate,
        documentationStatus: EstimateDocumentationStatus? = nil
    ) -> [(label: String, value: String)] {
        var rows = [
            ("Created", formattedDateTime(estimate.createdAt)),
            ("Status", estimate.status.capitalized),
            ("Service Address", estimate.siteAddress ?? ""),
            ("QuickBooks ID", estimate.quickBooksID ?? ""),
            ("Items", estimate.lineItemSummary),
            ("Notes", estimate.notes ?? ""),
            ("Total", currency(estimate.amount))
        ]
        if estimate.isProposalOption {
            rows.insert(
                ("Proposal Option", estimate.proposalOptionDisplayDetail),
                at: 2
            )
        }
        if let approvedAt = estimate.customerApprovedAt {
            rows.insert(
                ("Customer Approval", "\(estimate.customerApprovedByName ?? estimate.customer.name) • \(formattedDateTime(approvedAt))"),
                at: 2
            )
            if let method = estimate.customerApprovalMethod {
                rows.insert(("Approval Method", method.displayName), at: 3)
            }
            if let reference = normalizedValue(estimate.customerApprovalReference) {
                rows.insert(("Authorization Reference", reference), at: 4)
            }
            if let recorder = normalizedValue(estimate.customerApprovalRecordedByEmail) {
                rows.insert(("Recorded By", recorder), at: 5)
            }
        }
        if let documentationStatus {
            rows.append(("Documentation Status", documentationStatus.statusLabel))
            rows.append(("Documentation Summary", documentationStatus.summary))
            rows.append(("Documentation Action", documentationStatus.actionSummary))
        }
        return rows
    }

    private static func invoiceSections(
        invoice: Invoice,
        serviceCall: ServiceCall?,
        payments: [Payment],
        attachments: [ServiceDocumentAttachment] = [],
        includeCustomerHeader: Bool = true,
        equipmentProfiles: [CustomerEquipment] = [],
        serviceCalls: [ServiceCall] = []
    ) -> [DocumentSection] {
        var sections: [DocumentSection] = []
        if includeCustomerHeader, let serviceCall {
            sections.append(DocumentSection(
                title: "Job",
                rows: billingJobContextRows(
                    for: serviceCall,
                    equipmentProfiles: equipmentProfiles,
                    serviceCalls: serviceCalls
                )
            ))
            sections.append(contentsOf: billingDocumentationSections(for: serviceCall))
        }

        let documentationStatus = serviceCall?.invoiceDocumentationStatus(invoice: invoice, attachments: attachments)
        sections.append(DocumentSection(
            title: "Invoice Detail",
            rows: invoiceDetailRows(for: invoice, payments: payments, documentationStatus: documentationStatus).map { row($0.label, $0.value) }
        ))

        if !payments.isEmpty {
            sections.append(DocumentSection(
                title: "Payment History",
                rows: invoicePaymentHistoryRows(for: payments).map { paymentRow in
                    row(paymentRow.label, paymentRow.value)
                }
            ))
        }

        if invoice.customerSignatureName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false || invoice.customerSignedAt != nil {
            sections.append(DocumentSection(
                title: "Customer Approval",
                rows: [
                    row("Signed By", invoice.customerSignatureName),
                    row("Signed At", invoice.customerSignedAt.map { formattedDateTime($0) })
                ]
            ))
        }

        return sections
    }

    static func invoiceDetailRows(
        for invoice: Invoice,
        payments: [Payment],
        documentationStatus: InvoiceDocumentationStatus? = nil
    ) -> [(label: String, value: String)] {
        let paidTotal = payments.reduce(0) { partial, payment in
            partial + (payment.isRefund ? -payment.amount : payment.amount)
        }
        let balance = Invoice.outstandingBalance(for: invoice, payments: payments)
        let status = Invoice.resolvedStatus(for: invoice, payments: payments)
        var rows = [
            ("Created", formattedDateTime(invoice.createdAt)),
            ("Work Type", invoice.workType.displayName),
            ("Status", status.capitalized),
            ("QuickBooks ID", invoice.quickBooksID ?? ""),
            ("Items", invoice.lineItemSummary),
            ("Completion Notes", invoice.completionNotes ?? ""),
            ("Invoice Total", currency(invoice.amount)),
            ("Payments", currency(paidTotal)),
            ("Balance Due", currency(balance))
        ]
        if let siteAddress = normalizedValue(invoice.siteAddress) {
            rows.insert(("Service Address", siteAddress), at: 2)
        }
        if let documentationStatus {
            rows.append(("Documentation Status", documentationStatus.statusLabel))
            rows.append(("Documentation Summary", documentationStatus.summary))
            rows.append(("Documentation Action", documentationStatus.actionSummary))
        }
        return rows
    }

    static func billingJobContextSummaries(for serviceCall: ServiceCall) -> [(label: String, value: String)] {
        billingJobContextSummaries(for: serviceCall, equipmentProfiles: [], serviceCalls: [])
    }

    static func billingJobContextSummaries(
        for serviceCall: ServiceCall,
        equipmentProfiles: [CustomerEquipment],
        serviceCalls: [ServiceCall]
    ) -> [(label: String, value: String)] {
        billingJobContextRows(
            for: serviceCall,
            equipmentProfiles: equipmentProfiles,
            serviceCalls: serviceCalls
        )
        .map { ($0.label, $0.value) }
    }

    static func invoicePaymentHistoryRows(for payments: [Payment]) -> [(label: String, value: String)] {
        payments
            .sorted { $0.date < $1.date }
            .map { payment in
                let amount = payment.isRefund ? "-\(currency(abs(payment.amount)))" : currency(payment.amount)
                let kind = payment.isRefund ? "Refund" : "Payment"
                return (
                    label: formattedDateTime(payment.date),
                    value: "\(kind) \(amount) - \(payment.methodSummary)"
                )
            }
    }

    static func invoiceDocumentLabel(for invoice: Invoice, payments: [Payment]) -> String {
        isInvoicePaid(invoice, payments: payments) ? "Paid Invoice" : "Invoice"
    }

    static func invoiceDocumentCaption(for invoice: Invoice, payments: [Payment]) -> String {
        "Generated \(invoiceDocumentLabel(for: invoice, payments: payments).lowercased()) PDF"
    }

    private static func isInvoicePaid(_ invoice: Invoice, payments: [Payment]) -> Bool {
        Invoice.isPaid(invoice, payments: payments)
    }

    private static func billingJobContextRows(
        for serviceCall: ServiceCall,
        equipmentProfiles: [CustomerEquipment] = [],
        serviceCalls: [ServiceCall] = []
    ) -> [DocumentRow] {
        var rows = [
            row("Job ID", shortID(serviceCall.id)),
            row("Customer", serviceCall.customer.name),
            row("Customer Phone", serviceCall.customer.phone),
            row("Customer Email", serviceCall.customer.email),
            row("Scheduled", formattedDateTime(serviceCall.scheduledDate)),
            row("Job Type", serviceCall.type.displayName),
            row("Site Address", serviceCall.siteAddress ?? serviceCall.customer.address),
            row("Technician", serviceCall.assignedTechnician?.name),
            row("Equipment", serviceCall.equipmentSummary),
            row("Equipment Location", serviceCall.equipmentLocation),
            row("Equipment Notes", serviceCall.equipmentNotes)
        ]
        let historyRows = equipmentHistoryRows(
            serviceCall: serviceCall,
            equipmentProfiles: equipmentProfiles,
            serviceCalls: serviceCalls,
            includeCurrentJob: false
        )
        rows.append(contentsOf: historyRows.map { row($0.label, $0.value) })
        return rows
    }

    static func billingDocumentationSummaries(for serviceCall: ServiceCall) -> [(title: String, rows: [(label: String, value: String)])] {
        var summaries: [(title: String, rows: [(label: String, value: String)])] = []
        let readinessRows = serviceReportReadinessRows(for: serviceCall)
        if !readinessRows.isEmpty {
            summaries.append(("Onsite Documentation", readinessRows))
        }

        let serviceSummaryRows: [(label: String, value: String)] = [
            ("Findings", serviceCall.findingsSummary ?? ""),
            ("Recommended Work", serviceCall.recommendedWorkSummary ?? ""),
            ("Report Summary", serviceCall.serviceReportSummary ?? "")
        ].filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !serviceSummaryRows.isEmpty {
            summaries.append(("Service Summary", serviceSummaryRows))
        }

        let technicalRows = serviceCall.populatedTechnicalReadingRows
        if !technicalRows.isEmpty {
            summaries.append(("Technical Snapshot", technicalRows))
        }

        let serviceActionRows = serviceCall.populatedServiceActionRows.map { row in
            // Billing documents present a completed task in completion language,
            // while customer equipment history retains the inspection terminology.
            if row.label == "Electrical connections inspected" {
                return (label: "Electrical connections checked", value: row.value)
            }
            return row
        }
        if !serviceActionRows.isEmpty {
            summaries.append(("Service Actions", serviceActionRows))
        }
        let openConcernRows = serviceCall.openServiceConcernRows
        if !openConcernRows.isEmpty {
            summaries.append(("Open Service Concerns", openConcernRows))
        }
        return summaries
    }

    private static func billingDocumentationSections(for serviceCall: ServiceCall) -> [DocumentSection] {
        billingDocumentationSummaries(for: serviceCall).map { summary in
            DocumentSection(
                title: summary.title,
                rows: summary.rows.map { row($0.label, $0.value) }
            )
        }
    }

    static func checklistRows(for serviceCall: ServiceCall, attachments: [ServiceDocumentAttachment] = []) -> [(label: String, value: String)] {
        let photoEvidence = serviceCall.photoEvidenceStatus(from: attachments)
        return [
            ("Customer Notified", yesNo(serviceCall.customerNotified)),
            ("Arrival Confirmed", yesNo(serviceCall.arrivalConfirmed)),
            ("Work Completed", yesNo(serviceCall.workCompletedChecklist)),
            ("Documentation Completed", yesNo(serviceCall.documentationChecklist)),
            ("Payment Collected", yesNo(serviceCall.paymentCollectedChecklist)),
            ("Diagnostics Captured", yesNo(serviceCall.diagnosticsCaptured)),
            ("Safety Checklist", yesNo(serviceCall.safetyChecklistComplete)),
            ("Photo Evidence", "\(photoEvidence.statusLabel) - \(photoEvidence.summary)"),
            ("Before Photos", "\(photoEvidence.beforeCount)"),
            ("After Photos", "\(photoEvidence.afterCount)")
        ]
    }

    private static func checklistSection(for serviceCall: ServiceCall, attachments: [ServiceDocumentAttachment]) -> DocumentSection {
        DocumentSection(
            title: "Checklist",
            rows: checklistRows(for: serviceCall, attachments: attachments).map { row($0.label, $0.value) }
        )
    }

    private static func fieldPhotoCounts(
        for serviceCall: ServiceCall,
        attachments: [ServiceDocumentAttachment]
    ) -> (beforeCount: Int, afterCount: Int) {
        let jobAttachments = attachments.filter { $0.serviceCallID == serviceCall.id }
        let beforeCount = max(serviceCall.beforePhotoCount, jobAttachments.filter { $0.kind == .beforePhoto }.count)
        let afterCount = max(serviceCall.afterPhotoCount, jobAttachments.filter { $0.kind == .afterPhoto }.count)
        return (beforeCount, afterCount)
    }

    private static func renderPDF(
        title: String,
        customer: Customer,
        sections: [DocumentSection],
        imageAttachments: [ServiceDocumentAttachment] = [],
        imageServiceCall: ServiceCall? = nil,
        imageEquipmentProfiles: [CustomerEquipment] = [],
        approvalSignatureImageBase64: String? = nil,
        fileName: String
    ) throws -> URL {
        let folder = try exportFolder()
        let url = folder.appendingPathComponent(fileName)
        let pageBounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: pageBounds)

        try renderer.writePDF(to: url) { context in
            var y = startPage(context: context, bounds: pageBounds, title: title, customer: customer)
            for section in sections {
                y = drawSection(section, at: y, in: pageBounds, context: context, title: title, customer: customer)
            }
            y = drawApprovalSignature(
                approvalSignatureImageBase64,
                at: y,
                in: pageBounds,
                context: context,
                title: title,
                customer: customer
            )
            y = drawImageAttachments(
                imageAttachments,
                at: y,
                in: pageBounds,
                context: context,
                title: title,
                customer: customer,
                serviceCall: imageServiceCall,
                equipmentProfiles: imageEquipmentProfiles
            )
            drawFooter(in: pageBounds)
        }

        return url
    }

    private static func drawApprovalSignature(
        _ base64: String?,
        at initialY: CGFloat,
        in bounds: CGRect,
        context: UIGraphicsPDFRendererContext,
        title: String,
        customer: Customer
    ) -> CGFloat {
        guard let base64,
              let data = Data(base64Encoded: base64),
              let image = UIImage(data: data) else {
            return initialY
        }

        let margin: CGFloat = 42
        var y = initialY
        if y > bounds.height - 190 {
            drawFooter(in: bounds)
            y = startPage(context: context, bounds: bounds, title: title, customer: customer)
        }
        "Customer Signature".draw(at: CGPoint(x: margin, y: y), withAttributes: [
            .font: UIFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: UIColor.black
        ])
        y += 24
        let maxSize = CGSize(width: 260, height: 105)
        let scale = min(maxSize.width / max(image.size.width, 1), maxSize.height / max(image.size.height, 1), 1)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: CGRect(x: margin, y: y, width: size.width, height: size.height))
        return y + size.height + 18
    }

    private static func startPage(
        context: UIGraphicsPDFRendererContext,
        bounds: CGRect,
        title: String,
        customer: Customer
    ) -> CGFloat {
        context.beginPage()
        let margin: CGFloat = 42
        "GunnAire".draw(at: CGPoint(x: margin, y: 34), withAttributes: [
            .font: UIFont.systemFont(ofSize: 28, weight: .bold),
            .foregroundColor: UIColor.black
        ])
        "Targeting Solutions for Comfort".draw(at: CGPoint(x: margin, y: 66), withAttributes: [
            .font: UIFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: UIColor.darkGray
        ])
        title.draw(at: CGPoint(x: margin, y: 96), withAttributes: [
            .font: UIFont.systemFont(ofSize: 22, weight: .semibold),
            .foregroundColor: UIColor.black
        ])
        let customerBlock = [
            customer.name,
            customer.address,
            customer.phone,
            customer.email
        ]
            .compactMap { value -> String? in
                guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return value
            }
            .joined(separator: "\n")
        drawWrapped(customerBlock, in: CGRect(x: margin, y: 126, width: bounds.width - margin * 2, height: 84), font: .systemFont(ofSize: 11), color: .darkGray)
        return 216
    }

    private static func drawSection(
        _ section: DocumentSection,
        at initialY: CGFloat,
        in bounds: CGRect,
        context: UIGraphicsPDFRendererContext,
        title: String,
        customer: Customer
    ) -> CGFloat {
        let margin: CGFloat = 42
        let contentWidth = bounds.width - margin * 2
        var y = initialY
        if y > bounds.height - 140 {
            drawFooter(in: bounds)
            y = startPage(context: context, bounds: bounds, title: title, customer: customer)
        }

        section.title.draw(at: CGPoint(x: margin, y: y), withAttributes: [
            .font: UIFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: UIColor.black
        ])
        y += 24

        for row in section.rows where !row.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let labelWidth: CGFloat = 138
            let labelRect = CGRect(x: margin, y: y + 2, width: labelWidth, height: 20)
            row.label.draw(in: labelRect, withAttributes: [
                .font: UIFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: UIColor.darkGray
            ])

            let valueX = margin + labelWidth + 14
            let valueWidth = contentWidth - labelWidth - 14
            let valueHeight = measuredHeight(row.value, width: valueWidth, font: .systemFont(ofSize: 11))
            drawWrapped(row.value, in: CGRect(x: valueX, y: y, width: valueWidth, height: valueHeight), font: .systemFont(ofSize: 11), color: .black)
            y += max(22, valueHeight + 8)

            if y > bounds.height - 80 {
                drawFooter(in: bounds)
                y = startPage(context: context, bounds: bounds, title: title, customer: customer)
            }
        }

        return y + 12
    }

    private static func drawImageAttachments(
        _ attachments: [ServiceDocumentAttachment],
        at initialY: CGFloat,
        in bounds: CGRect,
        context: UIGraphicsPDFRendererContext,
        title: String,
        customer: Customer,
        serviceCall: ServiceCall? = nil,
        equipmentProfiles: [CustomerEquipment] = []
    ) -> CGFloat {
        let images = embeddedPhotoEvidenceAttachments(for: attachments)
            .compactMap { attachment -> (attachment: ServiceDocumentAttachment, image: UIImage)? in
                guard let image = UIImage(contentsOfFile: attachment.localFilePath) else { return nil }
                return (attachment, image)
            }
        guard !images.isEmpty else { return initialY }

        let margin: CGFloat = 42
        let contentWidth = bounds.width - margin * 2
        var y = initialY
        if y > bounds.height - 180 {
            drawFooter(in: bounds)
            y = startPage(context: context, bounds: bounds, title: title, customer: customer)
        }

        "Attached Photos".draw(at: CGPoint(x: margin, y: y), withAttributes: [
            .font: UIFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: UIColor.black
        ])
        y += 26

        for item in images {
            if y > bounds.height - 230 {
                drawFooter(in: bounds)
                y = startPage(context: context, bounds: bounds, title: title, customer: customer)
            }

            let maxHeight: CGFloat = 190
            let imageSize = item.image.size
            let scale = min(contentWidth / max(imageSize.width, 1), maxHeight / max(imageSize.height, 1))
            let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            let imageRect = CGRect(x: margin, y: y, width: drawSize.width, height: drawSize.height)
            item.image.draw(in: imageRect)
            y += drawSize.height + 6

            let caption = photoAttachmentCaption(
                for: item.attachment,
                serviceCall: serviceCall,
                equipmentProfiles: equipmentProfiles
            )
            drawWrapped(caption, in: CGRect(x: margin, y: y, width: contentWidth, height: 42), font: .systemFont(ofSize: 9), color: .darkGray)
            y += measuredHeight(caption, width: contentWidth, font: .systemFont(ofSize: 9)) + 16
        }

        return y
    }

    private static func drawFooter(in bounds: CGRect) {
        let footer = "Generated \(formattedDateTime(Date()))"
        footer.draw(at: CGPoint(x: 42, y: bounds.height - 44), withAttributes: [
            .font: UIFont.systemFont(ofSize: 9),
            .foregroundColor: UIColor.gray
        ])
    }

    private static func drawWrapped(_ text: String, in rect: CGRect, font: UIFont, color: UIColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 2
        NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]).draw(in: rect)
    }

    private static func measuredHeight(_ text: String, width: CGFloat, font: UIFont) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 2
        let rect = NSAttributedString(string: text, attributes: [
            .font: font,
            .paragraphStyle: paragraph
        ]).boundingRect(
            with: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return ceil(rect.height)
    }

    private static func exportFolder() throws -> URL {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw CustomerDocumentExportError.documentsDirectoryUnavailable
        }
        let folder = documents.appendingPathComponent("GunnAire Customer Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func onsiteReportFileDescriptor(
        serviceCall: ServiceCall,
        estimate: Estimate?,
        invoice: Invoice?
    ) -> String {
        let references = [
            "Job-\(shortID(serviceCall.id))",
            invoice.map { "Invoice-\(shortID($0.id))" },
            estimate.map { "Estimate-\(shortID($0.id))" }
        ]
            .compactMap { $0 }
        return references.joined(separator: "-")
    }

    private static func makeFileName(prefix: String, customerName: String, descriptor: String? = nil) -> String {
        let customer = sanitizeFileComponent(customerName)
        let cleanDescriptor = descriptor.flatMap { value -> String? in
            let sanitized = sanitizeFileComponent(value)
            return sanitized.isEmpty ? nil : sanitized
        }
        let date = fileDateFormatter.string(from: Date())
        return [prefix, customer, cleanDescriptor, date]
            .compactMap { $0 }
            .joined(separator: "-") + ".pdf"
    }

    private static func sanitizeFileComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value
            .replacingOccurrences(of: " ", with: "-")
            .unicodeScalars
            .map { allowed.contains($0) ? String($0) : "-" }
        let sanitized = scalars.joined()
            .split(separator: "-")
            .joined(separator: "-")
        return sanitized.isEmpty ? "Customer" : sanitized
    }

    private static func row(_ label: String, _ value: String?) -> DocumentRow {
        DocumentRow(label: label, value: value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    private static func normalizedValue(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func shortID(_ id: UUID?) -> String {
        guard let id else { return "" }
        return String(id.uuidString.prefix(8)).uppercased()
    }

    private static func yesNo(_ value: Bool) -> String {
        value ? "Yes" : "No"
    }

    private static func currency(_ value: Double) -> String {
        value.formatted(.currency(code: "USD"))
    }

    private static func formattedFileSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private static func formattedDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    private static func formattedDateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter
    }()
}

private struct DocumentSection {
    let title: String
    let rows: [DocumentRow]
}

private struct DocumentRow {
    let label: String
    let value: String
}
