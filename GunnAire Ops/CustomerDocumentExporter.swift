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
    static func exportOnsiteReport(
        serviceCall: ServiceCall,
        estimate: Estimate?,
        invoice: Invoice?,
        payments: [Payment]
    ) throws -> URL {
        let title = "\(serviceCall.type.displayName) Report"
        let fileName = makeFileName(prefix: "GunnAire-Onsite-Report", customerName: serviceCall.customer.name)
        let sections = onsiteReportSections(serviceCall: serviceCall, estimate: estimate, invoice: invoice, payments: payments)
        return try renderPDF(title: title, customer: serviceCall.customer, sections: sections, fileName: fileName)
    }

    static func exportEstimate(_ estimate: Estimate, serviceCall: ServiceCall?) throws -> URL {
        let fileName = makeFileName(prefix: "GunnAire-Estimate", customerName: estimate.customer.name)
        let sections = estimateSections(estimate: estimate, serviceCall: serviceCall)
        return try renderPDF(title: "Estimate", customer: estimate.customer, sections: sections, fileName: fileName)
    }

    static func exportPaidInvoice(_ invoice: Invoice, serviceCall: ServiceCall?, payments: [Payment]) throws -> URL {
        let fileName = makeFileName(prefix: "GunnAire-Paid-Invoice", customerName: invoice.customer.name)
        let sections = invoiceSections(invoice: invoice, serviceCall: serviceCall, payments: payments)
        return try renderPDF(title: "Paid Invoice", customer: invoice.customer, sections: sections, fileName: fileName)
    }

    private static func onsiteReportSections(
        serviceCall: ServiceCall,
        estimate: Estimate?,
        invoice: Invoice?,
        payments: [Payment]
    ) -> [DocumentSection] {
        var sections: [DocumentSection] = [
            DocumentSection(
                title: "Job",
                rows: [
                    row("Customer", serviceCall.customer.name),
                    row("Scheduled", formattedDateTime(serviceCall.scheduledDate)),
                    row("Job Type", serviceCall.type.displayName),
                    row("Status", serviceCall.status.rawValue.capitalized),
                    row("Technician", serviceCall.assignedTechnician?.name),
                    row("Site Address", serviceCall.siteAddress ?? serviceCall.customer.address)
                ]
            ),
            DocumentSection(
                title: "Equipment",
                rows: [
                    row("Name", serviceCall.equipmentName),
                    row("Model", serviceCall.equipmentModel),
                    row("Serial", serviceCall.equipmentSerialNumber),
                    row("Warranty Expiration", serviceCall.equipmentWarrantyExpiration.map { formattedDate($0) })
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
            checklistSection(for: serviceCall)
        ]

        if let estimate {
            sections.append(DocumentSection(
                title: "Estimate",
                rows: [
                    row("Status", estimate.status.capitalized),
                    row("Amount", currency(estimate.amount)),
                    row("Items", estimate.lineItemSummary),
                    row("Notes", estimate.notes)
                ]
            ))
        }

        if let invoice {
            sections.append(contentsOf: invoiceSections(invoice: invoice, serviceCall: nil, payments: payments, includeCustomerHeader: false))
        }

        return sections
    }

    private static func estimateSections(estimate: Estimate, serviceCall: ServiceCall?) -> [DocumentSection] {
        var sections: [DocumentSection] = []
        if let serviceCall {
            sections.append(DocumentSection(
                title: "Job",
                rows: [
                    row("Scheduled", formattedDateTime(serviceCall.scheduledDate)),
                    row("Job Type", serviceCall.type.displayName),
                    row("Site Address", serviceCall.siteAddress ?? serviceCall.customer.address),
                    row("Technician", serviceCall.assignedTechnician?.name)
                ]
            ))
        }

        sections.append(DocumentSection(
            title: "Estimate Detail",
            rows: [
                row("Created", formattedDateTime(estimate.createdAt)),
                row("Status", estimate.status.capitalized),
                row("QuickBooks ID", estimate.quickBooksID),
                row("Items", estimate.lineItemSummary),
                row("Notes", estimate.notes),
                row("Total", currency(estimate.amount))
            ]
        ))
        return sections
    }

    private static func invoiceSections(
        invoice: Invoice,
        serviceCall: ServiceCall?,
        payments: [Payment],
        includeCustomerHeader: Bool = true
    ) -> [DocumentSection] {
        var sections: [DocumentSection] = []
        if includeCustomerHeader, let serviceCall {
            sections.append(DocumentSection(
                title: "Job",
                rows: [
                    row("Scheduled", formattedDateTime(serviceCall.scheduledDate)),
                    row("Job Type", serviceCall.type.displayName),
                    row("Site Address", serviceCall.siteAddress ?? serviceCall.customer.address),
                    row("Technician", serviceCall.assignedTechnician?.name)
                ]
            ))
        }

        let paidTotal = payments.reduce(0) { $0 + $1.amount }
        let balance = max(invoice.amount - paidTotal, 0)
        sections.append(DocumentSection(
            title: "Invoice Detail",
            rows: [
                row("Created", formattedDateTime(invoice.createdAt)),
                row("Status", invoice.status.capitalized),
                row("QuickBooks ID", invoice.quickBooksID),
                row("Items", invoice.lineItemSummary),
                row("Completion Notes", invoice.completionNotes),
                row("Invoice Total", currency(invoice.amount)),
                row("Payments", currency(paidTotal)),
                row("Balance Due", currency(balance))
            ]
        ))

        if !payments.isEmpty {
            sections.append(DocumentSection(
                title: "Payment History",
                rows: payments.map { payment in
                    row(
                        formattedDateTime(payment.date),
                        "\(currency(payment.amount)) - \(payment.methodSummary)"
                    )
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

    private static func checklistSection(for serviceCall: ServiceCall) -> DocumentSection {
        DocumentSection(
            title: "Checklist",
            rows: [
                row("Customer Notified", yesNo(serviceCall.customerNotified)),
                row("Arrival Confirmed", yesNo(serviceCall.arrivalConfirmed)),
                row("Work Completed", yesNo(serviceCall.workCompletedChecklist)),
                row("Documentation Completed", yesNo(serviceCall.documentationChecklist)),
                row("Payment Collected", yesNo(serviceCall.paymentCollectedChecklist)),
                row("Diagnostics Captured", yesNo(serviceCall.diagnosticsCaptured)),
                row("Safety Checklist", yesNo(serviceCall.safetyChecklistComplete)),
                row("Before Photos", "\(serviceCall.beforePhotoCount)"),
                row("After Photos", "\(serviceCall.afterPhotoCount)")
            ]
        )
    }

    private static func renderPDF(
        title: String,
        customer: Customer,
        sections: [DocumentSection],
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
            drawFooter(in: pageBounds)
        }

        return url
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

    private static func makeFileName(prefix: String, customerName: String) -> String {
        let customer = sanitizeFileComponent(customerName)
        let date = fileDateFormatter.string(from: Date())
        return "\(prefix)-\(customer)-\(date).pdf"
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

    private static func yesNo(_ value: Bool) -> String {
        value ? "Yes" : "No"
    }

    private static func currency(_ value: Double) -> String {
        value.formatted(.currency(code: "USD"))
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
