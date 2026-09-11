import SwiftUI

struct StaffOwnerInvoiceReviewLink: View {
    @ObservedObject private var access = CompanyWorkspaceAccessController.shared
    var body: some View {
        if !GunnAireCloudKit.usesTestDatabase, access.verifiedRole == .admin {
            Section {
                NavigationLink {
                    StaffOwnerInvoiceRequestsView()
                } label: {
                    Label("Field Invoice Requests", systemImage: "doc.text.magnifyingglass")
                }.accessibilityIdentifier("FieldInvoiceRequests")
            }
        }
    }
}

private struct StaffOwnerInvoiceRequestsView: View {
    @ObservedObject private var source = StaffReplicaSourceCoordinator.shared
    var body: some View {
        List {
            if let invoices = source.ownerInvoices { StaffOwnerInvoicesReview(invoices: invoices, source: source) }
            Section {
                Button("Check Again") { Task { await source.sync() } }.disabled(source.isRunning)
                if source.isRunning { ProgressView("Checking company records…") }
                Text(source.message).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Field Invoice Requests")
        .task { await source.sync() }
    }
}

/// A focused office decision, separate from transport diagnostics and billing publication.
struct StaffOwnerInvoicesReview: View {
    @ObservedObject var invoices: StaffOwnerInvoiceCoordinator
    @ObservedObject var source: StaffReplicaSourceCoordinator
    @State private var selected: StaffOwnerInvoiceRow?
    var body: some View {
        Section("Invoice Requests") {
            Text(invoices.message).font(.footnote).foregroundStyle(.secondary)
            ForEach(invoices.reviews) { row in
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.customer).font(.headline)
                    Text(row.review.request.line.name)
                    Text("Quantity: " + row.review.request.line.quantity.formatted()).font(.subheadline)
                    Text(row.message).font(.footnote).foregroundStyle(.secondary)
                    if row.canReview {
                        Button("Review Invoice Change") { selected = row }.disabled(source.isRunning)
                    }
                }.padding(.vertical, 4)
            }
        }
        .sheet(item: $selected) { row in StaffOwnerInvoiceReviewSheet(row: row, source: source) }
        .onChange(of: invoices.displayGeneration) { _, _ in selected = nil }
    }
}

struct StaffOwnerInvoicePreview {
    let amount: Double
    let lines: [CatalogLineItemSnapshot]
    let createsItem: Bool
    let discountSummary: String?
    init(_ proposal: StaffOwnerInvoiceProposal) throws {
        amount = try StaffOwnerInvoicePlanner.number(proposal.invoiceFields, "amount")
        let raw = try StaffOwnerInvoicePlanner.text(proposal.invoiceFields, "catalogSnapshotJSON")
        guard let snapshot = try CatalogSnapshotPayload.read(raw) else {
            throw StaffOwnerInvoiceError.changed
        }
        try CatalogSnapshotPayload.validateBusinessEvidence(snapshot)
        lines = snapshot.lines; createsItem = proposal.newItemFields != nil
        discountSummary = BillingDocumentDiscountAudit.customerDocumentSummary(snapshotJSON: raw)
    }
}

private struct StaffOwnerInvoiceReviewSheet: View {
    let row: StaffOwnerInvoiceRow
    @ObservedObject var source: StaffReplicaSourceCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    @State private var draft: StaffOwnerInvoiceDraft?
    @State private var preview: StaffOwnerInvoicePreview?
    @State private var working = false
    @State private var message: String?
    var body: some View {
        NavigationStack {
            Form {
                Section(row.customer) {
                    LabeledContent("Requested work", value: row.review.request.line.name)
                    LabeledContent("Quantity", value: row.review.request.line.quantity.formatted())
                    Text(row.review.request.reason).textSelection(.enabled)
                    if row.review.request.line.kind == "new" {
                        Text("Approval also creates this item in the company pricebook, keeping the technician's authorship and system assignment.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("Office Review") {
                    TextField("Reason for approval", text: $reason, axis: .vertical).lineLimit(2...5)
                        .disabled(working)
                        .onChange(of: reason) { _, _ in draft = nil; preview = nil }
                    if let preview {
                        LabeledContent("Complete invoice before tax", value: preview.amount.formatted(.currency(code: "USD")))
                        if let discount = preview.discountSummary { LabeledContent("Retained discount", value: discount) }
                        DisclosureGroup("Review All Invoice Lines (\(preview.lines.count))") {
                            ForEach(preview.lines) { line in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(line.customerSummary).textSelection(.enabled)
                                    if let assembly = line.assembly { Text(assembly.lineContext).font(.footnote).foregroundStyle(.secondary) }
                                    if let bundle = line.bundle, !bundle.printGroupedItems {
                                        DisclosureGroup("Bundle contents") {
                                            ForEach(Array(bundle.members.enumerated()), id: \.offset) { _, member in
                                                Text(member.line.customerSummary).textSelection(.enabled)
                                            }
                                        }
                                    }
                                }.padding(.vertical, 4)
                            }
                        }
                        Text("Existing sold lines and discounts are retained. Tax must be reviewed again, and any earlier customer signature is cleared. This saves company records only; it does not send an invoice, charge a payment, or publish to QuickBooks.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let message { Text(message).foregroundStyle(.secondary).accessibilityIdentifier("OfficeInvoiceReviewMessage") }
                    if working { ProgressView("Checking the original invoice…") }
                    if let draft {
                        Button("Approve and Apply to Invoice") {
                            working = true; message = nil
                            Task { @MainActor in
                                defer { working = false }
                                do { try await source.applyInvoice(draft); dismiss() }
                                catch {
                                    self.draft = nil; preview = nil
                                    message = StaffOwnerInvoiceCoordinator.safe(error) + " Close this review and choose Check Again to recover any saved approval."
                                }
                            }
                        }.disabled(working || source.isRunning).buttonStyle(.borderedProminent)
                    } else {
                        Button("Preview Invoice Change") {
                            working = true; message = nil
                            Task { @MainActor in
                                defer { working = false }
                                do {
                                    let proposed = try await source.reviewInvoice(row.id, reason: reason.trimmingCharacters(in: .whitespacesAndNewlines))
                                    preview = try StaffOwnerInvoicePreview(proposed.proposal); draft = proposed
                                } catch { message = StaffOwnerInvoiceCoordinator.safe(error) }
                            }
                        }.disabled(working || source.isRunning || !StaffInvoiceLine.text(reason.trimmingCharacters(in: .whitespacesAndNewlines), maximum: 2000))
                    }
                }
            }
            .navigationTitle("Review Invoice Change")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(working) } }
            .interactiveDismissDisabled(working)
        }
    }
}
