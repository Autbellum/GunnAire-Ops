import SwiftUI
import SwiftData

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
    @State private var openedInvoice: StaffOwnerInvoiceRoute?
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
        .sheet(item: $openedInvoice) { route in StaffOwnerInvoiceDestination(route: route, approvals: invoices) }
        .onChange(of: invoices.displayGeneration) { _, _ in selected = nil; openedInvoice = nil }
        if !invoices.recentInvoices.isEmpty {
            Section("Invoice Follow-up") {
                ForEach(invoices.recentInvoices) { route in
                    Button { openedInvoice = route } label: {
                        Label("Open Invoice · " + route.customer, systemImage: "doc.text")
                    }.accessibilityIdentifier("OfficeInvoiceOpen-" + route.id)
                }
                Text("Review saved items, tax and QuickBooks status. Opening an invoice does not send or charge it.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

/// Resolve live models at the destination, never retain a SwiftData invoice
/// across account changes. The existing stack-safe invoice workspace owns its
/// normal edit, PDF, publication and collection actions.
@MainActor private struct StaffOwnerInvoiceDestination: View {
    let route: StaffOwnerInvoiceRoute
    @ObservedObject var approvals: StaffOwnerInvoiceCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var access = CompanyWorkspaceAccessController.shared
    @Query private var invoices: [Invoice]
    @Query private var customers: [Customer]
    @Query private var jobs: [ServiceCall]
    @State private var expired = false

    private var available: Bool {
        guard !expired, approvals.canOpenInvoice(route),
              access.authorizedContainer === modelContext.container else { return false }
        return (try? route.resolve(invoices: invoices, customers: customers, jobs: jobs,
                                  check: { try StaffReplicaSourceDependencies.verify($0) })) != nil
    }
    var body: some View {
        Group {
            if available {
                BillingDocumentsView(workspaceMode: .invoices, showsDismissButton: true,
                                     dismissButtonTitle: "Close", focusedInvoiceID: route.invoiceID)
            } else {
                NavigationStack {
                    ContentUnavailableView("Invoice Needs Another Check", systemImage: "doc.text.magnifyingglass",
                        description: Text("Reopen the current business workspace and check this invoice again. It may still be syncing or its customer or job may have changed. No replacement was created."))
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
                }
            }
        }
        .task {
            let delay = max(0, route.context.stamp.session.expiresAt.timeIntervalSinceNow)
            do { try await Task.sleep(for: .seconds(delay)); expired = true }
            catch { /* Dismissal cancels the expiry observer. */ }
        }
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
