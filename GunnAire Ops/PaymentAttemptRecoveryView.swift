import SwiftUI
import SwiftData

/// Recovery is an exceptional, invoice-scoped flow, not extra payment-form fields.
struct PaymentAttemptRecoveryView: View {
    let invoices: [Invoice]
    let initialInvoiceID: UUID?
    @Environment(\.dismiss) private var dismiss
    @Query private var payments: [Payment]
    @State private var selectedInvoiceID: UUID?
    @State private var attempts: [PaymentAttemptRecord] = []
    @State private var references: [UUID: String] = [:]
    @State private var isBusy = false
    @State private var message = ""
    @State private var cancelTarget: UUID?

    private var invoice: Invoice? { invoices.first { $0.id == selectedInvoiceID } }
    private var reviewAttempts: [PaymentAttemptRecord] {
        attempts.filter { record in
            switch record.state {
            case .cancelled, .declined: false
            case .completed: !payments.contains { $0.id == record.id && $0.collectionAttemptID == record.id }
            default: true
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Invoice", selection: $selectedInvoiceID) {
                        Text("Choose an invoice").tag(UUID?.none)
                        ForEach(invoices.filter { $0.quickBooksID != nil }) { invoice in
                            Text("\(invoice.customer?.name ?? "Customer") · \(invoice.amount.formatted(.currency(code: "USD")))")
                                .tag(Optional(invoice.id))
                        }
                    }
                    .disabled(isBusy)
                }
                Section {
                    Text("Review an interrupted payment here. Verification restores its records; it never sends another charge or refund.")
                        .foregroundStyle(.secondary)
                    if isBusy { ProgressView("Checking payment records…") }
                    if !message.isEmpty { Text(message).accessibilityIdentifier("payment-review-message") }
                    if invoice != nil, reviewAttempts.isEmpty, !isBusy, message.isEmpty {
                        Label("No unfinished payment records", systemImage: "checkmark.circle")
                    }
                }
                ForEach(reviewAttempts) { record in
                    Section {
                        LabeledContent(record.intent.kind == "refund" ? "Refund" : "Payment",
                                       value: (Double(record.intent.amountCents) / 100).formatted(.currency(code: "USD")))
                        Text(status(for: record)).foregroundStyle(.secondary)
                        if record.state == .reserved {
                            Button("Release unsent reservation") { cancelTarget = record.id }
                                .disabled(isBusy)
                        } else {
                            if record.providerID == nil && record.candidateProviderID == nil {
                                Text("Find the original transaction in QuickBooks. If its result is unknown, keep this invoice on hold and ask the office to review it.")
                                    .font(.callout)
                                TextField("Original QuickBooks transaction ID", text: referenceBinding(record.id))
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                            }
                            Button("Verify and restore records") {
                                Task { await recover(record) }
                            }
                            .disabled(isBusy || (record.providerID == nil && record.candidateProviderID == nil &&
                                !PaymentAttemptRecord.isReference(references[record.id] ?? "")))
                            .accessibilityIdentifier("recover-payment-attempt")
                        }
                        DisclosureGroup("Review details") {
                            LabeledContent("Method", value: record.intent.rail == "ach" ? "Bank transfer" : "Card")
                            LabeledContent("Attempt", value: record.id.uuidString)
                            if let id = record.providerID ?? record.candidateProviderID {
                                LabeledContent("QuickBooks reference", value: id)
                            }
                        }
                        .font(.footnote)
                    }
                }
            }
            .navigationTitle("Payment review")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }
                        .disabled(invoice == nil || isBusy)
                }
            }
            .task(id: selectedInvoiceID) { await refresh() }
            .onAppear { selectedInvoiceID = initialInvoiceID }
            .confirmationDialog("Release this unsent reservation?", isPresented: Binding(
                get: { cancelTarget != nil }, set: { if !$0 { cancelTarget = nil } }
            )) {
                Button("Release reservation") {
                    if let id = cancelTarget { Task { await cancel(id) } }
                }
            } message: {
                Text("Only a reservation that has not started sending can be released. A sent or uncertain payment remains on hold.")
            }
        }
    }

    private func referenceBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { references[id] ?? "" }, set: { references[id] = $0.trimmingCharacters(in: .whitespacesAndNewlines) })
    }

    private func status(for record: PaymentAttemptRecord) -> String {
        if record.intent.rail == "ach", record.providerStatus == "PENDING" {
            return "Bank transfer submitted; settlement is not yet confirmed."
        }
        switch record.state {
        case .reserved: return "Reserved, but not yet sent."
        case .sending, .unknown: return "Outcome needs verification. Do not collect again."
        case .confirmed: return "Payment verified; finish its accounting records."
        case .completed: return "QuickBooks records verified; restore the missing local record."
        case .cancelled: return "Unsent reservation released."
        case .declined: return "Payment declined."
        }
    }

    @MainActor private func refresh() async {
        attempts = []
        message = ""
        guard let invoice else { return }
        let selected = invoice.id
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await QuickBooksPaymentsService.shared.paymentAttempts(for: invoice)
            try result.validateWorkspace()
            guard selectedInvoiceID == selected else { return }
            attempts = result.value
        } catch {
            guard !Task.isCancelled, selectedInvoiceID == selected else { return }
            message = error.localizedDescription
        }
    }

    @MainActor private func recover(_ record: PaymentAttemptRecord) async {
        guard let invoice else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await QuickBooksPaymentsService.shared.recoverPaymentAttempt(record.id, for: invoice,
                providerReference: references[record.id])
            try result.validateWorkspace()
            await refresh()
            try result.validateWorkspace()
            message = result.accountingReviewMessage ?? "Payment records restored. No new charge or refund was sent."
        } catch { message = error.localizedDescription }
    }

    @MainActor private func cancel(_ id: UUID) async {
        guard let invoice else { return }
        isBusy = true
        defer { isBusy = false; cancelTarget = nil }
        do {
            let result = try await QuickBooksPaymentsService.shared.cancelPaymentReservation(id, for: invoice)
            await refresh()
            try result.validateWorkspace()
            message = result.accountingReviewMessage ?? "Unsent reservation released."
        } catch { message = error.localizedDescription }
    }
}
