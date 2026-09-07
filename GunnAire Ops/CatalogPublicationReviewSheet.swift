import SwiftUI
import SwiftData

@MainActor
struct CatalogPublicationReviewClient {
    var list: (UUID, UUID) async throws -> [CatalogPublicationRecord]
    var cancel: (UUID) async throws -> Void

    static let live = Self(list: GunnAireBackendService.catalogPublications, cancel: GunnAireBackendService.cancelCatalogPublication)

    #if DEBUG
    static func fixture(environment: String) -> Self {
        precondition(GunnAireCloudKit.usesTestDatabase)
        var cancelled = false
        let identifier = UUID(uuidString: "10000000-0000-4000-8000-000000000003")!
        return Self(list: { company, item in
            [.init(id: identifier, companyID: company, realmID: "catalog-ui-fixture", environment: environment,
                   localItemID: item, operation: "update", state: cancelled ? "cancelled" : "reserved",
                   providerID: nil, updatedAt: "2026-09-07T00:00:00+00:00")]
        }, cancel: { id in
            guard id == identifier else { throw CatalogPublicationError.invalidResponse }
            cancelled = true
        })
    }
    #endif
}

/// A focused recovery surface; the normal catalog remains uncluttered.
@MainActor
struct CatalogPublicationReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: Item
    let context: ModelContext
    @State private var workflow: QuickBooksDataAPI.CapturedWorkspaceWorkflow?
    @State private var client: CatalogPublicationReviewClient
    let onRecover: (UUID) -> Void
    private let itemID: UUID
    private let itemName: String
    @State private var records: [CatalogPublicationRecord] = []
    @State private var message: String?
    @State private var busy = false
    @State private var cancellation: CatalogPublicationRecord?

    init(item: Item, context: ModelContext, api: QuickBooksDataAPI,
         client: CatalogPublicationReviewClient? = nil, onRecover: @escaping (UUID) -> Void) {
        self.item = item
        self.itemID = item.id
        self.itemName = item.name
        self.context = context
        self._workflow = State(initialValue: try? api.captureWorkspaceWorkflow())
        self._client = State(initialValue: client ?? .live)
        self.onRecover = onRecover
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(itemName).font(.headline)
                    Text("Recover the original QuickBooks result without sending another item. Only a proposal that was never sent can be cancelled.")
                        .foregroundStyle(.secondary)
                }
                if let message {
                    Section { Text(message).accessibilityIdentifier("CatalogPublicationReviewMessage") }
                }
                if busy { ProgressView("Checking saved publications…") }
                if !busy && records.isEmpty && message == nil {
                    ContentUnavailableView("No saved publications", systemImage: "checkmark.circle",
                        description: Text("Return to the catalog to review and publish this item."))
                }
                ForEach(records) { record in
                    Section {
                        Label(record.title, systemImage: record.state == "confirmed" ? "checkmark.circle" : "clock")
                            .font(.headline)
                        Text(record.operation == "create" ? "Original item publication" : "Reviewed catalog update")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if record.state != "cancelled" {
                            Button("Recover original link") {
                                do {
                                    try check()
                                    dismiss()
                                    onRecover(record.id)
                                } catch { message = error.localizedDescription }
                            }
                            .disabled(busy)
                            .accessibilityIdentifier("RecoverCatalogPublication-\(record.id.uuidString)")
                        }
                        if record.state == "reserved" {
                            Button("Cancel unsent proposal", role: .destructive) { cancellation = record }
                                .disabled(busy)
                        }
                    }
                }
            }
            .navigationTitle("Catalog publication review")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }.disabled(busy)
                }
            }
            .task { await refresh() }
            .confirmationDialog("Cancel this unsent proposal?", isPresented: Binding(
                get: { cancellation != nil }, set: { if !$0 { cancellation = nil } }
            ), titleVisibility: .visible, presenting: cancellation) { record in
                Button("Cancel unsent proposal", role: .destructive) {
                    cancellation = nil
                    Task { await cancel(record) }
                }
            } message: { _ in
                Text("Your local item stays saved. You can then review its corrected values and publish again.")
            }
        }
        .presentationDetents([.large])
        .presentationSizing(.page)
    }

    private func check() throws {
        guard let workflow, workflow.companyID != nil, workflow.realmID != nil else {
            throw CatalogPublicationError.accessRequired
        }
        try workflow.check()
        try QuickBooksSyncAccessPolicy.validate(context: context)
        let matches = try context.fetch(FetchDescriptor<Item>()).filter { $0.id == itemID }
        guard matches.count == 1, matches.first === item else { throw QuickBooksCatalogWorkflowError.itemChanged }
    }

    private func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try check()
            guard let workflow, let companyID = workflow.companyID, let realmID = workflow.realmID else {
                throw CatalogPublicationError.accessRequired
            }
            let incoming = try await client.list(companyID, itemID)
            try check()
            guard Set(incoming.map(\.id)).count == incoming.count else { throw CatalogPublicationError.invalidResponse }
            for record in incoming {
                try record.validate(companyID: companyID, realmID: realmID, environment: workflow.environment, itemID: itemID)
            }
            records = incoming
            message = nil
        } catch {
            records = []
            message = error.localizedDescription
        }
    }

    private func cancel(_ record: CatalogPublicationRecord) async {
        guard !busy else { return }
        busy = true
        do {
            try check()
            try await client.cancel(record.id)
            try check()
            busy = false
            await refresh()
        } catch {
            message = error.localizedDescription
            busy = false
        }
    }
}
