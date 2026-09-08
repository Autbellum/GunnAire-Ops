import SwiftUI
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

    private var published: Bool { invoice.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }

    var body: some View {
        NavigationStack {
            Form {
                Section("Collection") {
                    LabeledContent("Customer", value: invoice.customer?.name ?? "Unavailable")
                    LabeledContent("Saved balance", value: localBalance.formatted(.currency(code: "USD")))
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
                            LabeledContent("Invoice date", value: dateText(snapshot.invoiceDate))
                            LabeledContent("Invoice total", value: money(snapshot.totalCents))
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
                        Button("Check QuickBooks for Payment") { refreshID = UUID() }
                            .disabled(isLoading).accessibilityIdentifier("VerifyContactlessQuickBooksPayment")
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
                                Text("Match the invoice number, customer and amount in QuickBooks. The internal API ID is not an invoice number. Handoff contains only the expiring local invoice reference.")
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
                        Text("This check reads QuickBooks accounting records. It does not send a charge, prove bank settlement, or change your saved invoice and receipts. Opening another app never confirms payment.")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("ContactlessReadOnlyReviewNotice")
                    }
                }
                Section {
                    Button("Record Cash, Check, or Another Verified Payment") {
                        recordVerifiedPayment(snapshot.map { Double($0.collectionLimitCents) / 100 })
                    }
                    .disabled(isLoading || snapshot.map { $0.hasOpenAttempt || $0.collectionLimitCents == 0 } == true)
                }
            }
            .navigationTitle("Contactless Payment")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: refreshID) { await refresh() }
            .onDisappear { client = nil; snapshot = nil; loadedAt = nil }
            .onChange(of: scenePhase) { _, phase in
                client = nil; snapshot = nil; loadedAt = nil
                if phase == .active { refreshID = UUID() }
            }
        }
        .tint(Color.brandGold)
    }

    @MainActor private func refresh() async {
        let originalRefresh = refreshID
        snapshot = nil; client = nil; loadedAt = nil; message = ""
        guard published else { return }
        isLoading = true
        defer { if refreshID == originalRefresh { isLoading = false } }
        do {
            let client = try FieldPaymentReviewFixture.client(invoice: invoice) ?? FieldPaymentReviewClient.live(invoice: invoice)
            let result = try await client.review()
            try client.check()
            guard originalRefresh == refreshID else { return }
            self.client = client; snapshot = result; loadedAt = Date()
        } catch {
            guard !Task.isCancelled, originalRefresh == refreshID else { return }
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
    private func dateText(_ value: String) -> String {
        QuickBooksDateOnly.date(from: value)?.formatted(date: .abbreviated, time: .omitted) ?? "Date unavailable"
    }
}
