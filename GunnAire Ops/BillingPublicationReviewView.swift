import SwiftUI
import SwiftData

/// A single review page reached from the original invoice/estimate or job.
/// No raw payload, account-email footer, or additional top-level workspace.
@MainActor struct BillingPublicationReviewView: View {
    let document: QuickBooksBillingDocument
    let context: ModelContext
    private let customerName: String
    @State private var lifecycle = QuickBooksSyncLifecycle()
    @State private var flow: QuickBooksBillingWorkflow?
    @State private var shared: BillingNativePublication?
    @State private var original: BillingOriginalProposal?
    @State private var pending: BillingNativePending?
    @State private var busy = false
    @State private var message: String?
    @State private var confirmSend = false
    @State private var confirmApproval = false
    @State private var visibleLines = 20
    @State private var didLoad = false

    init(document: QuickBooksBillingDocument, context: ModelContext) {
        self.document = document; self.context = context
        customerName = document.customer?.name ?? "Saved customer"
    }

    private var proposal: BillingPublicationRequest? { original?.proposal ?? pending?.request }
    private var status: String {
        switch original?.publication.state {
        case .reserved: "Not yet sent to QuickBooks"
        case .sending, .unknown: "Checking the original request"
        case .confirmed: "Confirmed in QuickBooks"
        case .cancelled: "Unsent request cancelled"
        case nil: !didLoad ? "Billing review not yet confirmed" : pending == nil ? "No request awaiting review" : pending?.submitted == true ? "Original request needs confirmation" : "Original proposal saved on this device"
        }
    }

    var body: some View {
        List {
            Section {
                Text(customerName).font(.headline)
                Text(status).font(.headline).accessibilityIdentifier("BillingReviewStatus")
                Text("Review the original saved prices. Checking status does not send another invoice or estimate.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let message { Section { Text(message).accessibilityIdentifier("BillingReviewMessage") } }
            if busy { ProgressView("Checking billing…") }
            if let proposal {
                Section("Original proposal") {
                    LabeledContent("Document", value: proposal.documentType.rawValue)
                    LabeledContent("Date", value: proposal.document.TxnDate)
                    if let due = proposal.document.DueDate { LabeledContent("Due", value: due) }
                    ForEach(Array(proposal.document.Line.prefix(visibleLines).enumerated()), id: \.offset) { _, line in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(line.Description?.isEmpty == false ? line.Description! : line.DetailType == "DiscountLineDetail" ? "Discount" : "Saved item")
                                Spacer()
                                Text(line.DetailType == "DiscountLineDetail" ? -line.Amount : line.Amount, format: .currency(code: "USD"))
                            }
                            if let qty = line.SalesItemLineDetail.Qty, let price = line.SalesItemLineDetail.UnitPrice {
                                Text("\(qty.formatted()) × \(price.formatted(.currency(code: "USD")))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if visibleLines < proposal.document.Line.count { Button("Show more items") { visibleLines += 20 } }
                    if let note = proposal.document.PrivateNote, !note.isEmpty {
                        DisclosureGroup("Saved notes") { Text(note).font(.callout) }
                    }
                }
                Section {
                    Button("Check original status") { Task { await recover() } }.disabled(busy)
                        .accessibilityIdentifier("BillingReviewRecover")
                    if pending != nil, pending?.settled == false, original?.connectionChanged != true,
                       original == nil || original?.publication.state == .reserved {
                        Button("Publish original proposal") { confirmSend = true }.disabled(busy)
                            .accessibilityIdentifier("BillingReviewPublish")
                    }
                    if original?.reviewableByOffice == true, flow?.canApproveSharedDraft == true {
                        Button("Approve these field prices") { confirmApproval = true }.disabled(busy)
                            .accessibilityIdentifier("BillingReviewApprove")
                    }
                    if pending != nil, pending?.settled == false,
                       pending?.submitted == false || [.reserved, .cancelled].contains(original?.publication.state) {
                        Button("Cancel unsent request", role: .destructive) { Task { await cancel() } }.disabled(busy)
                            .accessibilityIdentifier("BillingReviewCancel")
                    }
                } footer: {
                    Text("Approval keeps the prices already sold. It does not send an email, collect payment, or publish on behalf of the technician.")
                }
            }
        }
        .navigationTitle("Billing Review")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onDisappear { lifecycle.cancel() }
        .confirmationDialog("Publish this original proposal?", isPresented: $confirmSend, titleVisibility: .visible) {
            Button("Publish original proposal") { Task { await publish() } }
        } message: { Text("QuickBooks will receive the saved lines, prices and dates shown here. Changed local drafts are not substituted.") }
        .confirmationDialog("Approve these exact field prices?", isPresented: $confirmApproval, titleVisibility: .visible) {
            Button("Approve field prices") { Task { await approve() } }
        } message: { Text("The original technician may publish this unchanged proposal. A different price or draft requires a new review.") }
    }

    private func load() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            if flow == nil {
                #if DEBUG
                if GunnAireCloudKit.usesTestDatabase, ProcessInfo.processInfo.arguments.contains("-uiTestNativeBillingReview") {
                    try loadFixture()
                }
                #endif
            }
            if flow == nil {
                let value = try QuickBooksBillingWorkflow(document: document, context: context, api: .shared, lifecycle: lifecycle)
                flow = value; shared = try value.openSharedReview()
            }
            try await refresh()
        } catch { message = error.localizedDescription }
    }
    private func refresh() async throws {
        guard let shared, let customer = document.customer else { throw BillingNativeError.pending }
        original = try await shared.original(customerID: customer.id)
        try shared.check()
        if shared.journal.pending == nil, let original, let flow,
           original.proposal.draftRevision == (try flow.billingDraftRevision()), original.publication.state != .cancelled {
            try shared.adoptOriginal(original, revision: flow.billingDraftRevision())
        }
        pending = shared.journal.pending
        didLoad = true
    }
    private func recover() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            try await refresh()
            if pending != nil, let flow,
               [.sending, .unknown, .confirmed].contains(original?.publication.state) {
                let result = try await flow.recoverOriginalFromReview()
                message = result.message
                try await refresh()
            } else { message = status }
        } catch { message = error.localizedDescription }
    }
    private func publish() async {
        guard !busy, let flow else { return }; busy = true; defer { busy = false }
        do {
            let result = try await flow.resumeOriginalFromReview()
            message = result.message
            try await refresh()
            do { try await flow.uploadLinkedAttachments() }
            catch { message = result.message + " Supporting files remain pending." }
        } catch { message = error.localizedDescription; try? await refresh() }
    }
    private func approve() async {
        guard !busy, let shared, let original, flow?.canApproveSharedDraft == true else { return }
        busy = true; defer { busy = false }
        do {
            try await shared.client.approveOriginal(original, workflow: shared.workflow)
            message = "Field prices approved. The original technician can now publish this unchanged proposal."
            try await refresh()
        } catch { message = error.localizedDescription }
    }
    private func cancel() async {
        guard !busy, let shared else { return }; busy = true; defer { busy = false }
        do {
            try await shared.cancelUnsent()
            original = nil; pending = nil
            message = "Unsent request cancelled. Return to this document to review and save your changes. No QuickBooks record was deleted."
        } catch { message = error.localizedDescription }
    }

    #if DEBUG
    private func loadFixture() throws {
        let company = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
        let attempt = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
        let recover = ProcessInfo.processInfo.arguments.contains("-uiTestNativeBillingAccepted")
        var state = recover ? "confirmed" : "reserved"
        var request: BillingPublicationRequest?
        var saved: BillingNativeJournal?
        let store = BillingNativeJournalStore(read: { scope in saved ?? .init(scope: scope) }, write: { saved = $0 })
        let client = BillingPublicationClient { path, method, _ in
            guard let request else { throw BillingNativeError.pending }
            let row: [String: Any] = ["id": attempt.uuidString, "companyID": company.uuidString, "realmID": request.realmID,
                "environment": request.environment, "documentType": request.documentType.rawValue,
                "localDocumentID": request.localDocumentID.uuidString, "localCustomerID": request.localCustomerID.uuidString,
                "operation": "create", "state": state, "providerID": state == "confirmed" ? "BILLING-UI-189" : NSNull(),
                "updatedAt": "2026-09-07T12:00:00Z"]
            if method == "GET" {
                return try JSONSerialization.data(withJSONObject: ["publication": row,
                    "proposal": JSONSerialization.jsonObject(with: JSONEncoder().encode(request)), "reviewableByOffice": false])
            }
            if path.hasSuffix("/cancel"), state == "reserved" {
                state = "cancelled"
                var cancelled = row; cancelled["state"] = state
                return try JSONSerialization.data(withJSONObject: ["publication": cancelled])
            }
            if path.hasSuffix("/recover"), state == "confirmed" {
                var remote = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request.document)) as! [String: Any]
                remote.merge(["Id": "BILLING-UI-189", "SyncToken": "1", "TotalAmt": 189, "Balance": 189, "TxnTaxDetail": ["TotalTax": 0],
                    "PrivateNote": "GunnAire Invoice ID: \(request.localDocumentID.uuidString.uppercased())"]) { _, new in new }
                return try JSONSerialization.data(withJSONObject: ["publication": row, "document": remote])
            }
            // No fixture may fall through to real accounting or any send.
            throw BillingPublicationError.unavailable
        }
        let api = QuickBooksDataAPI(testTokens: .init(accessToken: "fixture", expiration: .distantFuture),
            realmID: "billing-review-fixture", environment: Config.QuickBooks.environment, catalogCompanyID: company,
            billingPublisher: client, transport: { _ in throw BillingPublicationError.unavailable })
        let fixtureItems = try context.fetch(FetchDescriptor<Item>())
        let selected = Set(CatalogLineItemSnapshot.decoded(from: document.snapshotJSON).map(\.catalogItemID))
        for item in fixtureItems where selected.contains(item.id) && item.quickBooksID == nil {
            item.quickBooksID = "BILLING-UI-ITEM-" + item.id.uuidString
        }
        if document.customer?.quickBooksID == nil { document.customer?.quickBooksID = "BILLING-UI-CUSTOMER" }
        try context.save()
        let value = try QuickBooksBillingWorkflow(document: document, context: context, api: api, lifecycle: lifecycle, billingJournal: store)
        guard let customer = document.customer else { throw BillingNativeError.pending }
        let lines = try QuickBooksDocumentLinePublication.lines(snapshotJSON: document.snapshotJSON,
            expectedSubtotal: document.subtotal, catalogItems: fixtureItems)
        let revision = try value.billingDraftRevision()
        request = .init(companyID: company, realmID: "billing-review-fixture", environment: Config.QuickBooks.environment,
            documentType: .invoice, localDocumentID: document.id, localCustomerID: customer.id, operation: .create,
            document: .init(CustomerRef: .init(value: customer.quickBooksID ?? "C1", name: nil), Line: lines, TxnDate: "2026-09-07"),
            connectionRevision: String(repeating: "a", count: 64), serviceCallID: document.serviceCallID, draftRevision: revision)
        let journalScope = BillingNativeJournalScope(document: request!.scope, actorEmail: AppAccess.normalizedEmail(AppIdentity.currentEmail))
        saved = .init(scope: journalScope, pending: .init(request: request!, draftRevision: revision, submitted: true, publicationID: attempt))
        flow = value; shared = try value.openSharedReview()
    }
    #endif
}

@MainActor struct BillingPublicationReviewLink: View {
    let document: QuickBooksBillingDocument
    let context: ModelContext
    var body: some View {
        NavigationLink {
            BillingPublicationReviewView(document: document, context: context)
        } label: { Label("Billing Review", systemImage: "doc.text.magnifyingglass") }
        .accessibilityIdentifier("BillingReview-\(document.id.uuidString)")
    }
}
