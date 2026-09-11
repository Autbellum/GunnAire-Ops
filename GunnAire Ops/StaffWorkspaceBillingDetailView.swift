import SwiftUI

/// One focused document inside the existing per-window navigation stack.
struct StaffWorkspaceBillingDetailView: View {
    let hosted: StaffWorkspaceOperationalHostedStore
    let route: StaffWorkspaceRecordRoute

    var body: some View {
        if let document = try? StaffWorkspaceBillingDetail.load(hosted: hosted, route: route) {
            List {
                Section {
                    LabeledContent("Status", value: document.status)
                    links(document.context)
                    facts(document.summary)
                }
                Section("Line items") {
                    if document.linesNotRecorded {
                        Text("Itemized lines were not recorded on this document.").foregroundStyle(.secondary)
                        if let summary = document.legacySummary { Text(summary) }
                    } else if document.lines.isEmpty {
                        Text("No saved line items.").foregroundStyle(.secondary)
                    } else {
                        ForEach(document.lines) { line in StaffWorkspaceSoldLineView(line: line) }
                    }
                }
                Section {
                    facts(document.totals)
                } footer: { Text(document.taxNotice) }
                if !document.notes.isEmpty {
                    Section { DisclosureGroup("Notes and approval") { facts(document.notes) } }
                }
                if !document.files.isEmpty || !document.messages.isEmpty || !document.payments.isEmpty {
                    Section("Related records") {
                        if !document.files.isEmpty { DisclosureGroup("Files (\(document.files.count))") { links(document.files) } }
                        if !document.messages.isEmpty { DisclosureGroup("Messages (\(document.messages.count))") { links(document.messages) } }
                        if !document.payments.isEmpty { DisclosureGroup("Payments (\(document.payments.count))") { links(document.payments) } }
                    }
                }
                Section {
                    DisclosureGroup("QuickBooks status") {
                        facts(document.connection)
                        Text("This is the last shared document. Opening it does not sync QuickBooks, send an email or collect payment.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(document.title)
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("StaffBillingDocument." + route.kind + "." + route.id)
        } else {
            ContentUnavailableView("Document unavailable", systemImage: "doc.questionmark",
                description: Text("Return to the list and refresh your shared workspace. This document could not be verified."))
        }
    }

    private func facts(_ values: [StaffWorkspaceBillingDetail.Fact]) -> some View {
        ForEach(values) { fact in
            LabeledContent(fact.label) { Text(fact.value).multilineTextAlignment(.trailing) }
                .accessibilityIdentifier("StaffBillingFact." + fact.id)
        }
    }
    private func links(_ values: [StaffWorkspaceBillingDetail.Link]) -> some View {
        ForEach(values) { link in
            NavigationLink(value: link.route) { LabeledContent(link.label, value: link.title) }
                .accessibilityIdentifier("StaffBillingLink." + link.id)
        }
    }
}

private struct StaffWorkspaceSoldLineView: View {
    let line: StaffWorkspaceBillingDetail.Line
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(line.name, value: line.amount.formatted(.currency(code: "USD")))
                .font(.headline)
            Text("\(line.quantity.formatted(.number.precision(.fractionLength(0...5)))) × \(QuickBooksSalesLineContract.unitPriceLabel(line.unitPrice))")
                .font(.subheadline).foregroundStyle(.secondary)
            if let description = line.description { Text(description).font(.callout) }
            if line.taxable { Text("Taxable").font(.caption).foregroundStyle(.secondary) }
            if let equipment = line.equipment {
                if let link = line.equipmentLink {
                    NavigationLink(value: link.route) { Label(equipment, systemImage: "air.conditioner.horizontal") }
                } else { Label(equipment, systemImage: "air.conditioner.horizontal") }
            }
            if !line.members.isEmpty {
                DisclosureGroup("Package contents") {
                    ForEach(line.members) { member in StaffWorkspaceSoldLineView(line: member) }
                }
            }
            if !line.parts.isEmpty {
                DisclosureGroup("Included parts per package") {
                    ForEach(line.parts) { part in
                        if let link = part.link {
                            NavigationLink(value: link.route) { LabeledContent(part.name, value: part.quantity.formatted(.number.precision(.fractionLength(0...5)))) }
                        } else { LabeledContent(part.name, value: part.quantity.formatted(.number.precision(.fractionLength(0...5)))) }
                    }
                }
            }
            if let link = line.catalogLink {
                DisclosureGroup("Item details") {
                    NavigationLink("Open current catalog item", value: link.route)
                    Text("The price above is the saved sale price, not today's catalog price.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("StaffBillingLine." + line.id)
    }
}
