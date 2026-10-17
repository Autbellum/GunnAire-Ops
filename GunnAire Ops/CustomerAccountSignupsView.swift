import SwiftUI
import SwiftData

/// Staff review queue for customer self-service account signups from the web
/// portal. A signup is never treated as a real business Customer until it is
/// explicitly linked here to an existing Customer record or used to create a
/// new one — this is the only place that authoritative decision is made.
struct CustomerAccountSignupsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Customer.name) private var customers: [Customer]
    @State private var pendingAccounts: [BackendCustomerAccountRecord] = []
    @State private var isLoading = false
    @State private var message: String?
    @State private var linkingAccount: BackendCustomerAccountRecord?
    @State private var isCreatingCustomer = false
    @State private var localCustomerStore: CustomerAccountLocalCustomerStore?

    private var formatter: ISO8601DateFormatter { ISO8601DateFormatter() }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && pendingAccounts.isEmpty {
                    ProgressView("Loading customer signups…")
                } else if pendingAccounts.isEmpty {
                    ContentUnavailableView(
                        "No pending signups",
                        systemImage: "person.crop.circle.badge.questionmark",
                        description: Text("New customer account signups from the web portal appear here for review."))
                } else {
                    List(pendingAccounts) { account in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(account.name).font(.headline)
                            Text(account.email).font(.subheadline).foregroundStyle(.secondary)
                            if let phone = account.phone, !phone.isEmpty {
                                Text(phone).font(.caption).foregroundStyle(.secondary)
                            }
                            Text("Signed up \(dateText(account.createdAt))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Button("Link to Customer…") {
                                linkingAccount = account
                            }
                            .font(.caption.weight(.semibold))
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .navigationTitle("Customer Signups")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await loadAccounts() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
            .overlay(alignment: .bottom) {
                if let message {
                    Text(message)
                        .font(.caption)
                        .padding(10)
                        .background(.regularMaterial, in: Capsule())
                        .padding()
                }
            }
            .task { await loadAccounts() }
            .sheet(item: $linkingAccount) { account in
                CustomerAccountLinkSheet(
                    account: account,
                    customers: customers,
                    onLinkExisting: { customer in
                        Task { await link(account, to: customer) }
                    },
                    onCreateNew: {
                        Task { await createAndLink(account) }
                    }
                )
            }
        }
    }

    private func dateText(_ value: String) -> String {
        formatter.date(from: value)?.formatted(date: .abbreviated, time: .shortened) ?? value
    }

    @MainActor
    private func loadAccounts() async {
        guard GunnAireBackendService.isConfigured else {
            message = "Configure the shared business server before loading customer signups."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            pendingAccounts = try await GunnAireBackendService.fetchCustomerAccounts()
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    @MainActor
    private func link(_ account: BackendCustomerAccountRecord, to customer: Customer) async {
        linkingAccount = nil
        do {
            _ = try await GunnAireBackendService.linkCustomerAccount(
                id: account.id, customerID: customer.id, quickBooksID: customer.quickBooksID
            )
            message = "Linked \(account.name) to \(customer.name)."
            await loadAccounts()
        } catch {
            message = error.localizedDescription
        }
    }

    @MainActor
    private func createAndLink(_ account: BackendCustomerAccountRecord) async {
        linkingAccount = nil
        guard !isCreatingCustomer else { return }
        isCreatingCustomer = true
        defer { isCreatingCustomer = false }

        let customerID: UUID
        do {
            customerID = try CustomerAccountLinkIdentity.customerID(for: account.id)
            let store = localCustomerStore ?? CustomerAccountLocalCustomerStore(container: modelContext.container)
            localCustomerStore = store
            try await store.prepare(id: customerID, name: account.name, email: account.email, phone: account.phone)
        } catch {
            message = error.localizedDescription
            return
        }

        do {
            _ = try await GunnAireBackendService.linkCustomerAccount(
                id: account.id, customerID: customerID, quickBooksID: nil
            )
            await loadAccounts()
            message = "Created a new customer record for \(account.name)."
        } catch {
            await reconcileFailedCreation(account: account, customerID: customerID, linkError: error)
        }
    }

    @MainActor
    private func reconcileFailedCreation(
        account: BackendCustomerAccountRecord, customerID: UUID, linkError: Error
    ) async {
        let status = try? await GunnAireBackendService.fetchCustomerAccount(id: account.id)
        let definiteRejection: Bool
        if case GunnAireBackendError.server(let code, _) = linkError {
            definiteRejection = (400..<500).contains(code)
        } else {
            definiteRejection = false
        }
        switch CustomerAccountLinkResolution.decide(
            status: status?.linkStatus, linkedCustomerID: status?.linkedCustomerID,
            linkedQuickBooksID: status?.linkedCustomerQuickBooksID,
            customerID: customerID, definitiveRejection: definiteRejection
        ) {
        case .confirmed:
            await loadAccounts()
            message = "Created a new customer record for \(account.name)."
            return
        case .keepForRetry:
            message = "The link result is unconfirmed. The customer record is kept for a safe retry."
            return
        case .reviewExistingLink:
            message = "This signup has a link that needs review. The local customer record is kept."
            return
        case .discardUnlinked:
            break
        }
        guard let store = localCustomerStore else { return }
        do {
            let removed = try await store.discardUnlinked(
                id: customerID, name: account.name, email: account.email, phone: account.phone
            )
            message = removed
                ? "The signup was not linked. No new customer record was kept."
                : "The signup was not linked. Review the local customer record before retrying."
        } catch {
            message = "The signup was not linked. Review the local customer record before retrying."
        }
    }
}

private struct CustomerAccountLinkSheet: View {
    @Environment(\.dismiss) private var dismiss
    let account: BackendCustomerAccountRecord
    let customers: [Customer]
    let onLinkExisting: (Customer) -> Void
    let onCreateNew: () -> Void
    @State private var searchText = ""

    private var matches: [Customer] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Array(customers.prefix(25))
        }
        let query = searchText.lowercased()
        return customers.filter {
            $0.name.lowercased().contains(query)
                || ($0.email?.lowercased().contains(query) ?? false)
                || ($0.phone?.lowercased().contains(query) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Signup") {
                    Text(account.name)
                    Text(account.email).foregroundStyle(.secondary)
                }
                Section {
                    Button("Create New Customer") {
                        onCreateNew()
                        dismiss()
                    }
                }
                Section("Or Link to an Existing Customer") {
                    ForEach(matches) { customer in
                        Button {
                            onLinkExisting(customer)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading) {
                                Text(customer.name)
                                if let email = customer.email, !email.isEmpty {
                                    Text(email).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search customers")
            .navigationTitle("Link Signup")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
