import Foundation
import SwiftUI

/// Compact document identities for the authorized projection, without UUID or
/// restricted-field badges. Build one lookup for the list, not a fetch per row.
enum StaffWorkspaceBillingQueue {
    struct Summary: Equatable {
        let title: String
        let customer: String
        let status: String
        let amount: String
        let created: String?
        var searchText: String { [title, customer, status, amount, created].compactMap { $0 }.joined(separator: " ") }
    }
    static func summaries(_ records: [StaffWorkspaceOperationalImportRecord]) -> [StaffWorkspaceRecordRoute: Summary] {
        let groups = Dictionary(grouping: records) { StaffWorkspaceRecordRoute(kind: $0.kind, id: $0.id) }
        var result: [StaffWorkspaceRecordRoute: Summary] = [:]
        for record in records where ["invoice", "estimate"].contains(record.kind) {
            let route = StaffWorkspaceRecordRoute(kind: record.kind, id: record.id)
            guard groups[route]?.count == 1, case .billing(let document) = record.body,
                  document.kind == record.kind, document.id.uuidString.lowercased() == record.id else { continue }
            func text(_ field: String) -> String? {
                guard document.unavailableFields[field] == nil, case .text(let value) = document.fields[field], !value.isEmpty else { return nil }
                return value
            }
            var customer = "Customer unavailable"
            if !record.unavailableLinks.contains("customer"), document.unavailableFields["customer"] == nil,
               case .identifier(let id) = document.fields["customer"],
               let matches = groups[.init(kind: "customer", id: id.uuidString.lowercased())], matches.count == 1,
               case .operational(let partition) = matches[0].body, partition.unavailableFields["name"] == nil,
               case .text(let name) = partition.fields["name"], !name.isEmpty { customer = name }
            let workType = text("workTypeRaw").flatMap(InvoiceWorkType.init(rawValue:))
            let title = record.kind == "invoice" ? (workType?.documentTitle ?? "Invoice") : "Estimate"
            let amount: String
            if document.unavailableFields["amount"] == nil,
               let label = StaffWorkspaceBillingDetail.observedAmountLabel(document.fields["amount"]) {
                amount = label
            } else { amount = "Amount unavailable" }
            var created: String?
            if document.unavailableFields["createdAt"] == nil, case .date(let date) = document.fields["createdAt"] {
                created = date.formatted(date: .abbreviated, time: .omitted)
            }
            result[route] = .init(title: title, customer: customer, status: text("status")?.capitalized ?? "Status unavailable",
                                  amount: amount, created: created)
        }
        return result
    }
}

struct StaffWorkspaceBillingQueueRow: View {
    let summary: StaffWorkspaceBillingQueue.Summary
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary.customer).font(.headline)
            ViewThatFits(in: .horizontal) {
                HStack { Text(summary.title); Spacer(); Text(summary.amount).fontWeight(.semibold) }
                VStack(alignment: .leading) { Text(summary.title); Text(summary.amount).fontWeight(.semibold) }
            }
            Text([summary.status, summary.created].compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
