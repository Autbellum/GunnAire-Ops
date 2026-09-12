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
    let connectionClient: SharedCatalogClient
    let fixtureCompanyID: UUID?
    @State private var preparation: SharedCatalogPreparation?
    @State private var connection: SharedCatalogConnection?
    @State private var visit = UUID()
    @State private var visible = false
    @State private var client: CatalogPublicationReviewClient
    let onRecover: (UUID) -> Void
    private let itemID: UUID
    private let itemName: String
    @State private var records: [CatalogPublicationRecord] = []
    @State private var message: String?
    @State private var busy = false
    @State private var cancellation: CatalogPublicationRecord?

    init(item: Item, context: ModelContext, connectionClient: SharedCatalogClient? = nil, fixtureCompanyID: UUID? = nil,
         client: CatalogPublicationReviewClient? = nil, onRecover: @escaping (UUID) -> Void) {
        self.item = item
        self.itemID = item.id
        self.itemName = item.name
        self.context = context
        self.connectionClient = connectionClient ?? .live
        self.fixtureCompanyID = fixtureCompanyID
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
            .task {
                visit = UUID(); visible = true
                let originalVisit = visit
                do {
                    preparation = try SharedCatalogPreparation(item: item, context: context,
                        isCurrent: { visible && visit == originalVisit },
                        client: connectionClient, fixtureCompanyID: fixtureCompanyID)
                    await refresh()
                } catch { message = error.localizedDescription }
            }
            .onDisappear { visible = false; visit = UUID(); preparation = nil; connection = nil; cancellation = nil; busy = false }
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
        guard visible, let preparation else {
            throw CatalogPublicationError.accessRequired
        }
        try preparation.check()
    }

    private func refresh() async {
        guard !busy else { return }
        let originalVisit = visit
        busy = true
        defer { if visible && visit == originalVisit { busy = false } }
        do {
            try check()
            guard let preparation else {
                throw CatalogPublicationError.accessRequired
            }
            let current = try await preparation.connection()
            if let connection {
                guard connection.realmID == current.realmID, connection.environment == current.environment,
                      connection.connectionRevision == current.connectionRevision else { throw CatalogPublicationError.needsReview }
            }
            let incoming = try await client.list(current.companyID, itemID)
            try check()
            let after = try await preparation.connection()
            guard after.realmID == current.realmID, after.environment == current.environment,
                  after.connectionRevision == current.connectionRevision,
                  incoming.count <= 100, Set(incoming.map(\.id)).count == incoming.count else { throw CatalogPublicationError.invalidResponse }
            for record in incoming {
                try record.validate(companyID: current.companyID, realmID: current.realmID, environment: current.environment, itemID: itemID)
            }
            connection = current
            records = incoming
            message = nil
        } catch {
            guard visible && visit == originalVisit, !Task.isCancelled else { return }
            records = []
            message = error.localizedDescription
        }
    }

    private func cancel(_ record: CatalogPublicationRecord) async {
        guard !busy else { return }
        let originalVisit = visit
        busy = true
        do {
            try check()
            guard let connection, record.state == "reserved" else { throw CatalogPublicationError.needsReview }
            try record.validate(companyID: connection.companyID, realmID: connection.realmID,
                environment: connection.environment, itemID: itemID)
            try await client.cancel(record.id)
            try check()
            busy = false
            await refresh()
        } catch {
            guard visible && visit == originalVisit, !Task.isCancelled else { return }
            message = error.localizedDescription
            busy = false
        }
    }
}
