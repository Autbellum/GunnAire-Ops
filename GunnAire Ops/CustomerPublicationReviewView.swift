import SwiftUI
import SwiftData

@MainActor
struct CustomerPublicationReviewClient {
    var list: (UUID, UUID) async throws -> [CustomerPublicationRecord]
    var recover: (UUID) async throws -> CustomerPublicationResponse
    var cancel: (UUID) async throws -> Void

    static let live = Self(list: GunnAireBackendService.customerPublications,
                           recover: GunnAireBackendService.recoverCustomerPublication,
                           cancel: GunnAireBackendService.cancelCustomerPublication)
}

/// This pushes inside the customer editor's existing navigation stack, rather
/// than stacking another modal sheet above the customer record.
@MainActor
struct CustomerPublicationReviewView: View {
    @State private var owner: CustomerPublicationWorkflow?
    @State private var client: CustomerPublicationReviewClient
    @State private var records: [CustomerPublicationRecord] = []
    @State private var message: String?
    @State private var busy = false
    @State private var cancellation: CustomerPublicationRecord?
    private let customerName: String

    init(customer: Customer, context: ModelContext, api: QuickBooksDataAPI? = nil,
         client: CustomerPublicationReviewClient? = nil) {
        customerName = customer.name
        var resolvedAPI = api ?? .shared
        var resolvedClient = client ?? .live
        #if DEBUG
        if GunnAireCloudKit.usesTestDatabase && ProcessInfo.processInfo.arguments.contains("-uiTestCustomerPublicationReview") {
            let company = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
            let identifier = UUID(uuidString: "10000000-0000-4000-8000-000000000004")!
            let localID = customer.id, providerID = customer.quickBooksID ?? "customer-ui-fixture"
            let draft = QuickBooksCustomerCreateOperation.payload(for: QuickBooksCustomerCreateOperation.draft(for: customer))
            var state = "reserved"
            func record() -> CustomerPublicationRecord {
                .init(id: identifier, companyID: company, realmID: "customer-ui-fixture", environment: Config.QuickBooks.environment,
                      localCustomerID: localID, state: state, providerID: state == "confirmed" ? providerID : nil,
                      updatedAt: "2026-09-07T00:00:00+00:00")
            }
            resolvedAPI = QuickBooksDataAPI(testTokens: .init(accessToken: "fixture", expiration: .distantFuture),
                realmID: "customer-ui-fixture", environment: Config.QuickBooks.environment, catalogCompanyID: company,
                transport: { _ in throw CustomerPublicationError.unavailable })
            resolvedClient = .init(list: { _, _ in [record()] }, recover: { id in
                guard id == identifier else { throw CustomerPublicationError.invalidResponse }
                state = "confirmed"
                return .init(publication: record(), customer: .init(Id: providerID, DisplayName: draft.DisplayName,
                    PrimaryPhone: draft.PrimaryPhone, PrimaryEmailAddr: draft.PrimaryEmailAddr, BillAddr: draft.BillAddr, Active: true), created: false)
            }, cancel: { id in
                guard id == identifier && state == "reserved" else { throw CustomerPublicationError.needsReview }
                state = "cancelled"
            })
        }
        #endif
        do {
            _owner = State(initialValue: try CustomerPublicationWorkflow(customer: customer, context: context, api: resolvedAPI))
            _message = State(initialValue: nil)
        } catch {
            _owner = State(initialValue: nil)
            _message = State(initialValue: error.localizedDescription)
        }
        _client = State(initialValue: resolvedClient)
    }

    var body: some View {
        List {
            Section {
                Text(customerName).font(.headline)
                Text("Recover the original customer link without sending a second customer. Only a proposal that was never sent can be cancelled.")
                    .foregroundStyle(.secondary)
            }
            if let message { Section { Text(message).accessibilityIdentifier("CustomerPublicationReviewMessage") } }
            if busy { ProgressView("Checking saved customer sync…") }
            if !busy && records.isEmpty && message == nil {
                ContentUnavailableView("No saved customer sync", systemImage: "checkmark.circle",
                    description: Text("Return to Customer Actions to sync this saved customer."))
            }
            ForEach(records) { record in
                Section {
                    Label(record.title, systemImage: record.state == "confirmed" ? "checkmark.circle" : "clock").font(.headline)
                    if record.state != "cancelled" {
                        Button("Recover original customer link") { Task { await recover(record) } }.disabled(busy)
                    }
                    if record.state == "reserved" {
                        Button("Cancel unsent customer sync", role: .destructive) { cancellation = record }.disabled(busy)
                    }
                }
            }
        }
        .navigationTitle("Customer sync review")
        .toolbar { ToolbarItem(placement: .primaryAction) {
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }.disabled(busy)
        } }
        .task { await refresh() }
        .onDisappear { owner?.cancel() }
        .confirmationDialog("Cancel this unsent customer sync?", isPresented: Binding(
            get: { cancellation != nil }, set: { if !$0 { cancellation = nil } }),
            titleVisibility: .visible, presenting: cancellation) { record in
                Button("Cancel unsent customer sync", role: .destructive) {
                    cancellation = nil
                    Task { await cancel(record) }
                }
            } message: { _ in Text("The customer and all saved jobs, files and invoices stay in the app. No QuickBooks customer is deleted.") }
    }

    private func load() async throws {
        guard let owner, let companyID = owner.workflow.companyID, let realmID = owner.workflow.realmID else {
            throw CustomerPublicationError.accessRequired
        }
        try owner.check()
        let incoming = try await client.list(companyID, owner.draft.localCustomerID)
        try owner.check()
        guard Set(incoming.map(\.id)).count == incoming.count else { throw CustomerPublicationError.invalidResponse }
        for record in incoming {
            try record.validate(companyID: companyID, realmID: realmID,
                environment: owner.workflow.environment, customerID: owner.draft.localCustomerID)
        }
        records = incoming
    }

    private func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { try await load(); message = nil }
        catch { records = []; message = error.localizedDescription }
    }

    private func recover(_ record: CustomerPublicationRecord) async {
        guard !busy, let owner else { return }
        busy = true
        defer { busy = false }
        do {
            try await owner.recover(record.id, transport: client.recover)
            try await load()
            message = "Original customer link recovered. Your saved contact details were kept."
        } catch { message = error.localizedDescription }
    }

    private func cancel(_ record: CustomerPublicationRecord) async {
        guard !busy, let owner else { return }
        busy = true
        defer { busy = false }
        do {
            try owner.check()
            try await client.cancel(record.id)
            try owner.check()
            try await load()
            message = "Unsent sync cancelled. Return to Customer Actions to review and sync the saved customer."
        } catch { message = error.localizedDescription }
    }
}
