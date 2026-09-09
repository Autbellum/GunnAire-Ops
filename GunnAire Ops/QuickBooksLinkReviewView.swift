import SwiftUI
import SwiftData

/// A focused setup/recovery page inside the existing QuickBooks navigation.
/// It never becomes a second invoice editor or a new top-level workspace.
@MainActor struct QuickBooksLinkReviewView: View {
    private let context: ModelContext
    private let client: QuickBooksLinkReviewClient
    private let store: QuickBooksLinkReviewStore
    private let fixtureCompanyID: UUID?
    @State private var visit = UUID()
    @State private var isVisible = false
    @State private var owner: QuickBooksLinkReviewOwner?
    @State private var candidates: [QuickBooksExistingLink] = []
    @State private var selected: Set<String> = []
    @State private var kind: QuickBooksLinkKind = .customer
    @State private var search = ""
    @State private var limit = 50
    @State private var record: QuickBooksLinkReviewRecord?
    @State private var hasPending = false
    @State private var busy = false
    @State private var message: String?
    @State private var confirmation = false
    @State private var retirementConfirmation = false

    init(context: ModelContext) {
        self.context = context
        var client = GunnAireBackendService.qboLinkReviewClient
        var store = QuickBooksLinkReviewStore.device
        var fixtureCompanyID: UUID?
        #if DEBUG
        if GunnAireCloudKit.usesTestDatabase, ProcessInfo.processInfo.arguments.contains("-uiTestExistingQuickBooksLinks") {
            let company = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
            fixtureCompanyID = company
            var saved: QuickBooksLinkReviewRequest?
            var review: QuickBooksLinkReviewRecord?
            store = .init(read: { _ in saved }, write: { _, value in saved = value })
            client = .init { path, method, body in
                if ProcessInfo.processInfo.arguments.contains("-uiTestExistingLinksOffline") { throw QuickBooksLinkReviewError.unavailable }
                if method == "GET" {
                    if URLComponents(string: path)?.path == "/api/qbo-link-reviews/context" {
                        return try JSONEncoder().encode(SharedLinkReviewConnection(companyID: company, realmID: "link-review-fixture",
                            environment: Config.QuickBooks.environment, connectionRevision: String(repeating: "a", count: 64), protocolVersion: 1))
                    }
                    let operation = URLComponents(string: path)?.queryItems?.first(where: { $0.name == "operationID" })?.value
                    let matching = operation.flatMap(UUID.init(uuidString:)) == review?.operationID ? review : nil
                    let reconnected = review != nil && ProcessInfo.processInfo.arguments.contains("-uiTestExistingLinksReconnected")
                    let value: [String: Any] = ["connectionRevision": String(repeating: reconnected ? "c" : "a", count: 64),
                        "review": try matching.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) } ?? NSNull()]
                    return try JSONSerialization.data(withJSONObject: value)
                }
                if path == "/api/qbo-link-reviews" {
                    let request = try JSONDecoder().decode(QuickBooksLinkReviewRequest.self, from: body!)
                    review = .init(id: UUID(), companyID: request.companyID, realmID: request.realmID, environment: request.environment,
                        operationID: request.operationID, revision: String(repeating: "b", count: 64), state: .review,
                        expiresAt: Date().addingTimeInterval(900).ISO8601Format(), links: request.links.map { value in
                            .init(kind: value.kind, localID: value.localID, providerID: value.providerID, localName: value.localName,
                                localCustomerID: value.localCustomerID, serviceCallID: value.serviceCallID,
                                quickBooks: .init(Id: value.providerID, SyncToken: "0", DisplayName: value.localName, Active: true))
                        })
                } else if let old = review {
                    review = .init(id: old.id, companyID: old.companyID, realmID: old.realmID, environment: old.environment,
                        operationID: old.operationID, revision: old.revision, state: path.hasSuffix("/confirm") ? .confirmed : .cancelled,
                        expiresAt: old.expiresAt, links: old.links)
                    if path.hasSuffix("/confirm"), ProcessInfo.processInfo.arguments.contains("-uiTestExistingLinksLostReply") {
                        throw QuickBooksLinkReviewError.unavailable
                    }
                }
                guard let review else { throw QuickBooksLinkReviewError.invalid }
                return try JSONEncoder().encode(review)
            }
        }
        #endif
        self.client = client; self.store = store; self.fixtureCompanyID = fixtureCompanyID
    }

    private var visible: [QuickBooksExistingLink] {
        candidates.filter { $0.kind == kind && (search.isEmpty || $0.localName.localizedCaseInsensitiveContains(search)) }
    }

    private var selectionReady: Bool {
        owner != nil && (try? QuickBooksLinkSelection.batch(selected, from: candidates)) != nil
    }

    var body: some View {
        List {
            Section {
                Text("Use the QuickBooks records already linked in this app. Review the names side by side before adding their shared links.")
                Text("No customers, items, invoices, prices or payments are changed in QuickBooks.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let message { Section { Text(message).accessibilityIdentifier("ExistingQBOLinkMessage") } }
            if busy { ProgressView("Checking existing links…") }
            if !busy && owner == nil {
                Section {
                    Text("Connect to the shared business service to review existing links. Your saved records stay on this device.")
                    Button("Retry connection") {
                        let originalVisit = visit
                        Task { await start(visit: originalVisit) }
                    }
                        .accessibilityIdentifier("ExistingQBOLinkRetryConnection")
                }
            }
            if let record {
                Section {
                    Label(record.state == .confirmed ? "Shared links confirmed" : record.state == .cancelled ? "Review cancelled" : "Review existing records",
                          systemImage: record.state == .confirmed ? "checkmark.circle" : "link")
                        .accessibilityIdentifier("ExistingQBOLinkStatus")
                    ForEach(record.links) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.localName).font(.headline)
                            LabeledContent("QuickBooks", value: entry.quickBooks.title)
                            if entry.quickBooks.Active == false { Text("Inactive in QuickBooks; historical link only").foregroundStyle(.orange) }
                            if let price = entry.quickBooks.UnitPrice { LabeledContent("Current QuickBooks price", value: price.formatted(.currency(code: "USD"))) }
                            if let total = entry.quickBooks.TotalAmt { LabeledContent("QuickBooks total", value: total.formatted(.currency(code: "USD"))) }
                            DisclosureGroup("Record identifiers") {
                                LabeledContent("QuickBooks ID", value: entry.providerID)
                                Text(entry.kind.rawValue).foregroundStyle(.secondary)
                            }.font(.caption)
                        }.padding(.vertical, 4)
                    }
                    if record.state == .review && owner?.decisionNeedsRecovery == false {
                        Button("Confirm existing links") { confirmation = true }
                            .disabled(busy || owner?.connectionChanged == true || (record.expiry ?? .distantPast) <= Date())
                            .accessibilityIdentifier("ExistingQBOLinkConfirm")
                        Button("Cancel this review") {
                            let originalVisit = visit
                            Task { await decide(confirm: false, visit: originalVisit) }
                        }.disabled(busy)
                            .accessibilityIdentifier("ExistingQBOLinkCancel")
                        Text("Review expires after 15 minutes. Changed QuickBooks records require a fresh review.").font(.caption).foregroundStyle(.secondary)
                        if owner?.connectionChanged == true {
                            Text("QuickBooks was reconnected. Cancel this old review, then review the records with the current connection.").font(.callout)
                        }
                    } else if record.state != .review {
                        Button("Review another batch") {
                            do { try owner?.nextBatch(); self.record = nil; hasPending = false; selected = []; message = nil }
                            catch { message = error.localizedDescription }
                        }.disabled(busy)
                    }
                }
            } else if !hasPending && owner != nil {
                Section("Choose existing records") {
                    Picker("Record type", selection: $kind) { ForEach(QuickBooksLinkKind.allCases) { value in Text(value.plural).tag(value) } }
                    TextField("Search saved names", text: $search).accessibilityIdentifier("ExistingQBOLinkSearch")
                    ForEach(Array(visible.prefix(limit))) { value in
                        Button {
                            if selected.contains(value.id) { selected.remove(value.id) }
                            else { selected.insert(value.id) }
                        } label: {
                            HStack {
                                Text(value.localName).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: selected.contains(value.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(value.id) ? Color.accentColor : Color.secondary)
                                    .accessibilityHidden(true)
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(busy || (!selected.contains(value.id) && selected.count >= 25))
                        .accessibilityLabel(value.localName)
                        .accessibilityValue(selected.contains(value.id) ? "Selected" : "Not selected")
                        .accessibilityAddTraits(selected.contains(value.id) ? .isSelected : [])
                        .accessibilityIdentifier("ExistingQBOSelect-" + value.id)
                    }
                    if visible.count > limit { Button("Show more records") { limit += 50 } }
                    if visible.isEmpty { Text("No linked records of this type match. Sync new records using the existing customer or pricebook workflow.").foregroundStyle(.secondary) }
                    Button("Review selected (\(selected.count))") {
                        let originalVisit = visit, originalSelection = selected
                        Task { await preview(selected: originalSelection, visit: originalVisit) }
                    }
                        .disabled(busy || !selectionReady)
                        .accessibilityIdentifier("ExistingQBOLinkPreview")
                    Text("Up to 25 records per review. A selected document's customer is included automatically and counts toward that limit.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if hasPending {
                Section {
                    if owner?.connectionChanged == true {
                        Text("QuickBooks was reconnected. The shared service has no review for this old request. Start a fresh review with the current connection.")
                        Button("Start a fresh review") { retirementConfirmation = true }.disabled(busy)
                    } else {
                        Text("The original review request is saved. Recover its status, or read those same records again if the server has no review yet.")
                        Button("Read original records again") {
                            let originalVisit = visit
                            Task { await preview(selected: [], visit: originalVisit) }
                        }.disabled(busy)
                    }
                }
            }
            if hasPending {
                Section {
                    Button("Recover saved review") {
                        let originalVisit = visit
                        Task { await load(visit: originalVisit) }
                    }.disabled(busy).accessibilityIdentifier("ExistingQBOLinkRecover")
                }
            }
        }
        .navigationTitle("Existing QuickBooks links")
        .task {
            guard !Task.isCancelled else { return }
            visit = UUID(); isVisible = true
            await start(visit: visit)
        }
        .onDisappear { isVisible = false; visit = UUID(); owner?.cancel(); owner = nil; busy = false }
        .confirmationDialog("Use these existing QuickBooks links?", isPresented: $confirmation, titleVisibility: .visible) {
            Button("Use reviewed links") {
                let originalVisit = visit
                Task { await decide(confirm: true, visit: originalVisit) }
            }
        } message: { Text("Only the reviewed shared links are added. Existing records and sold prices stay unchanged.") }
        .confirmationDialog("Replace the unsubmitted review request?", isPresented: $retirementConfirmation, titleVisibility: .visible) {
            Button("Start fresh") {
                do { try owner?.retireUnsubmittedRequest(); hasPending = false; selected = []; message = nil }
                catch { message = error.localizedDescription }
            }
        } message: { Text("Only this device's old request is removed. Existing records and shared links stay unchanged.") }
    }

    private func start(visit originalVisit: UUID) async {
        guard isVisible, visit == originalVisit, !busy, !Task.isCancelled else { return }
        busy = true
        owner?.cancel(); owner = nil
        record = nil; candidates = []; selected = []; hasPending = false
        do {
            let preparation = try SharedLinkReviewPreparation(context: context, client: client,
                isCurrent: { isVisible && visit == originalVisit }, fixtureCompanyID: fixtureCompanyID)
            let incoming = try await preparation.owner(store: store)
            guard isVisible && visit == originalVisit, !Task.isCancelled else { incoming.cancel(); return }
            owner = incoming; busy = false
            await load(visit: originalVisit)
        } catch {
            guard isVisible && visit == originalVisit, !Task.isCancelled else { return }
            let safe = QuickBooksLinkReviewClient.safe(error)
            message = (safe as? QuickBooksLinkReviewError) == .unavailable
                ? "The shared business connection is unavailable. Your existing records and saved link reviews are unchanged."
                : safe.localizedDescription
            busy = false
        }
    }

    private func load(visit originalVisit: UUID) async {
        guard isVisible, visit == originalVisit, !busy, !Task.isCancelled, let owner else { return }
        busy = true; defer { if isVisible && visit == originalVisit { busy = false } }
        do {
            try await owner.recover(); try owner.check()
            guard isVisible && visit == originalVisit, !Task.isCancelled else { return }
            record = owner.record; hasPending = owner.request != nil; message = nil
            candidates = try owner.candidates()
        } catch {
            guard isVisible && visit == originalVisit, !Task.isCancelled else { return }
            hasPending = owner.request != nil; message = error.localizedDescription
        }
    }
    private func preview(selected originalSelection: Set<String>, visit originalVisit: UUID) async {
        guard isVisible, visit == originalVisit, !busy, !Task.isCancelled, let owner else { return }
        busy = true; defer { if isVisible && visit == originalVisit { busy = false } }
        do {
            try await owner.preview(selected: originalSelection); try owner.check()
            guard isVisible && visit == originalVisit, !Task.isCancelled else { return }
            record = owner.record; message = nil
        } catch {
            guard isVisible && visit == originalVisit, !Task.isCancelled else { return }
            message = error.localizedDescription
        }
        hasPending = owner.request != nil
    }
    private func decide(confirm: Bool, visit originalVisit: UUID) async {
        guard isVisible, visit == originalVisit, !busy, !Task.isCancelled, let owner else { return }
        busy = true; defer { if isVisible && visit == originalVisit { busy = false } }
        do {
            try await owner.decide(confirm: confirm); try owner.check()
            guard isVisible && visit == originalVisit, !Task.isCancelled else { return }
            record = owner.record; message = nil
        } catch {
            guard isVisible && visit == originalVisit, !Task.isCancelled else { return }
            message = error.localizedDescription
        }
    }
}
