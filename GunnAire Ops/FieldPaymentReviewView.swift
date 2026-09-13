import SwiftUI
import SwiftData
import UIKit

/// The collection handoff stays compact. Provider IDs and payloads never appear
/// in the ordinary flow; optional accounting history contains dates and amounts.
struct FieldPaymentReviewView: View {
    let invoice: Invoice
    let localBalance: Double
    let recordVerifiedPayment: (Double?) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var refreshID = UUID()
    @State private var client: FieldPaymentReviewClient?
    @State private var snapshot: FieldPaymentReviewSnapshot?
    @State private var isLoading = false
    @State private var message = ""
    @State private var showsSteps = false
    @State private var loadedAt: Date?
    @State private var updateSavedInvoice = false
    @State private var saveMessage = ""
    @State private var savedBalanceOverride: Double?

    private var published: Bool { invoice.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }

    var body: some View {
        NavigationStack {
            Form {
                Section("Collection") {
                    LabeledContent("Customer", value: invoice.customer?.name ?? "Unavailable")
                    LabeledContent("Saved balance", value: (savedBalanceOverride ?? localBalance).formatted(.currency(code: "USD")))
                        .accessibilityIdentifier("ContactlessSavedBalance")
                    if let receipt = FieldPaymentReceiptReconciliation.receipt(for: invoice) {
                        Text("Accounting check saved \(CompanyWorkspaceClock.parse(receipt.snapshot.observedAt)?.formatted(date: .abbreviated, time: .shortened) ?? "previously").")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("ContactlessSavedReceipt")
                    }
                }
                if !published {
                    Section("QuickBooks Invoice Required") {
                        Label("Contactless collection is waiting for QuickBooks publication.", systemImage: "exclamationmark.triangle")
                        Text("Ask the office to publish this invoice to QuickBooks, then reopen the collection task.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("QuickBooks Invoice") {
                        if isLoading { ProgressView("Checking this invoice…").accessibilityIdentifier("ContactlessReviewLoading") }
                        if let snapshot {
                            if let number = snapshot.invoiceNumber {
                                LabeledContent("Invoice number", value: number)
                                    .accessibilityIdentifier("ContactlessQuickBooksInvoiceNumber")
                            } else {
                                Text("QuickBooks has not assigned an invoice number. Match the customer, invoice date and total in QuickBooks.")
                                    .accessibilityIdentifier("ContactlessMissingInvoiceNumber")
                            }
                            LabeledContent("QuickBooks balance", value: money(snapshot.balanceCents))
                                .accessibilityIdentifier("ContactlessVerifiedBalance")
                            if snapshot.invoiceNumber == nil {
                                invoiceDetails(snapshot)
                            } else {
                                DisclosureGroup("Invoice details") { invoiceDetails(snapshot) }
                            }
                            if snapshot.hasOpenAttempt {
                                Label("Another payment needs review. Do not collect again.", systemImage: "exclamationmark.triangle")
                                    .accessibilityIdentifier("ContactlessOpenAttemptHold")
                            } else if snapshot.balanceCents == 0 {
                                Label("No balance due in QuickBooks", systemImage: "checkmark.circle")
                            } else if snapshot.collectionLimitCents < snapshot.balanceCents {
                                LabeledContent("Remaining collection assignment", value: money(snapshot.collectionLimitCents))
                            }
                            if let loadedAt {
                                Text("Checked \(loadedAt.formatted(date: .omitted, time: .shortened)). Refresh after collecting in QuickBooks.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if !message.isEmpty {
                            Text(message).foregroundStyle(.secondary).accessibilityIdentifier("ContactlessReviewMessage")
                        }
                        Button("Check QuickBooks for Payment") { updateSavedInvoice = false; refreshID = UUID() }
                            .disabled(isLoading).accessibilityIdentifier("VerifyContactlessQuickBooksPayment")
                        Button("Update Saved Invoice") { updateSavedInvoice = true; refreshID = UUID() }
                            .disabled(isLoading || snapshot == nil)
                            .accessibilityIdentifier("SaveContactlessAccountingReview")
                    }
                    if let snapshot, !snapshot.hasOpenAttempt, snapshot.collectionLimitCents > 0 {
                        Section("Use Tap to Pay on iPhone in QuickBooks") {
                            Button {
                                openPaymentApp(FieldPaymentHandoff.quickBooksMobileAppStoreURL)
                            } label: {
                                Label(snapshot.invoiceNumber == nil ? "Open QuickBooks" : "Copy Invoice Number & Open QuickBooks", systemImage: "arrow.up.forward.app")
                            }
                            .accessibilityIdentifier("CopyInvoiceNumberAndOpenQuickBooks")
                            Button(snapshot.invoiceNumber == nil ? "Open GoPayment" : "Copy Invoice Number & Open GoPayment") {
                                openPaymentApp(FieldPaymentHandoff.goPaymentAppStoreURL)
                            }
                            .accessibilityIdentifier("CopyInvoiceNumberAndOpenGoPayment")
                            DisclosureGroup("Show collection steps", isExpanded: $showsSteps) {
                                ForEach(Array(FieldPaymentHandoff.quickBooksTapToPaySteps.enumerated()), id: \.offset) { index, step in
                                    Text("\(index + 1). \(step)")
                                }
                                Text("Match the invoice number, customer and amount in QuickBooks. Handoff carries only a temporary invoice reference.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .accessibilityIdentifier("ContactlessQuickBooksCollectionSteps")
                        }
                    }
                    if let snapshot, !snapshot.payments.isEmpty {
                        Section {
                            DisclosureGroup("Applied payments (\(snapshot.payments.count))") {
                                ForEach(snapshot.payments, id: \.paymentQuickBooksID) { payment in
                                    VStack(alignment: .leading) {
                                        LabeledContent(dateText(payment.postingDate), value: money(payment.appliedCents))
                                        if payment.includesCreditOrAdjustment {
                                            Text("Includes a credit or adjustment").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Section {
                        Text("This check reads QuickBooks accounting records. It does not send a charge or prove bank settlement. Update Saved Invoice refreshes its balance and saves accounting evidence; it does not create another payment or replace capture history. Opening another app never confirms payment.")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("ContactlessReadOnlyReviewNotice")
                    }
                }
                Section {
                    Button("Record Cash, Check, or Another Verified Payment") {
                        openVerifiedEntry()
                    }
                    .disabled(isLoading || (published && snapshot == nil) || snapshot.map { $0.hasOpenAttempt || $0.collectionLimitCents == 0 } == true)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !saveMessage.isEmpty {
                    Text(saveMessage)
                        .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                        .padding().background(.regularMaterial)
                        .accessibilityIdentifier("ContactlessSaveMessage")
                }
            }
            .navigationTitle("Contactless Payment")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: refreshID) { await refresh() }
            .onDisappear { client = nil; snapshot = nil; loadedAt = nil }
            .onChange(of: scenePhase) { _, phase in
                client = nil; snapshot = nil; loadedAt = nil
                updateSavedInvoice = false
                if phase == .active { refreshID = UUID() }
            }
        }
        .tint(Color.brandGold)
    }

    @MainActor private func refresh() async {
        let originalRefresh = refreshID
        let shouldSave = updateSavedInvoice
        updateSavedInvoice = false
        snapshot = nil; client = nil; loadedAt = nil; message = ""; saveMessage = ""
        guard published else { return }
        isLoading = true
        defer { if refreshID == originalRefresh { isLoading = false } }
        do {
            let client = try FieldPaymentReviewFixture.client(invoice: invoice) ?? FieldPaymentReviewClient.live(invoice: invoice)
            let result = try await client.review()
            try client.check()
            guard originalRefresh == refreshID else { return }
            if shouldSave {
                guard let context = invoice.modelContext else { throw FieldPaymentReceiptError.changed }
                try FieldPaymentReceiptReconciliation.apply(result, to: invoice, identity: client.identity,
                    context: context, check: client.check, persist: { try context.save() })
                savedBalanceOverride = invoice.quickBooksBalanceDue
                saveMessage = "Invoice balance and accounting check saved. No new payment was created."
                // The old client's original model stamp intentionally cannot
                // authorize more actions after our own successful local save.
                self.client = try FieldPaymentReviewFixture.client(invoice: invoice) ?? FieldPaymentReviewClient.live(invoice: invoice)
            } else { self.client = client }
            snapshot = result; loadedAt = Date()
        } catch {
            guard !Task.isCancelled, originalRefresh == refreshID else { return }
            message = (error as? FieldPaymentReceiptError)?.localizedDescription ?? FieldPaymentReviewError.safe(error).localizedDescription
        }
    }

    @MainActor private func openVerifiedEntry() {
        guard published else { recordVerifiedPayment(nil); return }
        do {
            guard let client, let snapshot, let loadedAt, Date().timeIntervalSince(loadedAt) < 60,
                  !snapshot.hasOpenAttempt, snapshot.collectionLimitCents > 0 else { throw FieldPaymentReviewError.changed }
            try client.check()
            recordVerifiedPayment(Double(snapshot.collectionLimitCents) / 100)
        } catch {
            snapshot = nil; loadedAt = nil
            message = FieldPaymentReviewError.safe(error).localizedDescription
        }
    }

    @MainActor private func openPaymentApp(_ url: URL) {
        do {
            guard let client, let snapshot, let loadedAt, Date().timeIntervalSince(loadedAt) < 60,
                  !snapshot.hasOpenAttempt, snapshot.collectionLimitCents > 0 else { throw FieldPaymentReviewError.changed }
            try client.check()
            if let number = snapshot.invoiceNumber { UIPasteboard.general.string = number }
            openURL(url) { accepted in
                if !accepted { message = "QuickBooks could not be opened. Install the QuickBooks app on your field iPhone, then refresh this invoice." }
            }
        } catch {
            snapshot = nil; loadedAt = nil
            message = FieldPaymentReviewError.safe(error).localizedDescription
        }
    }

    private func money(_ cents: Int) -> String { (Double(cents) / 100).formatted(.currency(code: "USD")) }
    @ViewBuilder private func invoiceDetails(_ snapshot: FieldPaymentReviewSnapshot) -> some View {
        LabeledContent("Invoice date", value: dateText(snapshot.invoiceDate))
        LabeledContent("Invoice total", value: money(snapshot.totalCents))
    }
    private func dateText(_ value: String) -> String {
        QuickBooksDateOnly.date(from: value)?.formatted(date: .abbreviated, time: .omitted) ?? "Date unavailable"
    }
}

/// Available with the original invoice even when the field device is offline.
/// Archived amounts are never presented as a new collection authorization.
struct SavedFieldPaymentReceiptDisclosure: View {
    let invoice: Invoice
    @Environment(\.scenePhase) private var scenePhase
    @State private var refreshID: UUID?
    @State private var refreshing = false
    @State private var message = ""
    var body: some View {
        if invoice.quickBooksPaymentReviewJSON != nil {
            DisclosureGroup {
                if let receipt = FieldPaymentReceiptReconciliation.receipt(for: invoice) {
                    if let number = receipt.snapshot.invoiceNumber {
                        LabeledContent("QuickBooks invoice", value: number)
                    }
                    if let date = CompanyWorkspaceClock.parse(receipt.snapshot.observedAt) {
                        LabeledContent("Checked", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                    LabeledContent("Balance at check", value: (Double(receipt.snapshot.balanceCents) / 100).formatted(.currency(code: "USD")))
                    ForEach(receipt.snapshot.payments, id: \.paymentQuickBooksID) { payment in
                        LabeledContent(payment.includesCreditOrAdjustment ? "Accounting credit / adjustment" : "Accounting payment applied",
                            value: (Double(payment.appliedCents) / 100).formatted(.currency(code: "USD")))
                    }
                    Text("Saved QuickBooks accounting evidence, not proof of bank settlement or permission to collect again. Original payment captures are kept separately.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("The saved check no longer matches this invoice. Refresh it, or ask Accounting to review its original records.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Button("Refresh accounting check") { message = ""; refreshID = UUID() }
                    .buttonStyle(.plain).disabled(refreshing)
                    .accessibilityIdentifier("RefreshSavedInvoiceAccountingCheck")
                if refreshing { ProgressView("Refreshing accounting check…") }
                if !message.isEmpty {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier("SavedInvoiceAccountingRefreshMessage")
                }
            } label: {
                Text("Saved accounting check")
                    .accessibilityIdentifier("SavedInvoiceAccountingCheck-\(invoice.id.uuidString)")
            }
            .disclosureGroupStyle(CatalogBundleDisclosureStyle())
            .task(id: refreshID) {
                guard let id = refreshID else { return }
                refreshing = true
                defer { if refreshID == id { refreshing = false } }
                do {
                    let client = try FieldPaymentReviewFixture.client(invoice: invoice) ?? FieldPaymentReviewClient.live(invoice: invoice)
                    let stamp = CompanyWorkspaceAccessController.shared.operationStamp
                    let review = try await FieldPaymentReceiptRefresh.ifSaved(invoice: invoice, check: {
                        guard refreshID == id, scenePhase == .active,
                              CompanyWorkspaceAccessController.shared.operationStamp == stamp
                        else { throw FieldPaymentReviewError.access }
                    }, makeClient: { _ in client })
                    guard refreshID == id, !Task.isCancelled else { return }
                    message = review ?? "Accounting check refreshed. No new payment was created."
                } catch {
                    guard refreshID == id, !Task.isCancelled else { return }
                    message = FieldPaymentReviewError.safe(error).localizedDescription
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { refreshID = nil; refreshing = false; message = "" }
            }
            .onDisappear { refreshID = nil; refreshing = false }
        }
    }
}
