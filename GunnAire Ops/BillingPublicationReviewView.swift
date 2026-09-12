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
    @State private var milestoneOriginal: BillingMilestoneOriginal?
    @Query private var syncedInvoices: [Invoice]
    @State private var visitID = UUID()
    @State private var confirmRetain = false
    @Query private var reviewUsers: [AppUser]
    @Query private var reviewAttachments: [ServiceDocumentAttachment]
    @Query private var reviewPayments: [Payment]

    private var retainedDraft: Invoice? {
        guard case .invoice(let invoice) = document, invoice.milestoneDraftReceiptJSON != nil,
              (try? QuickBooksBillingAccessPolicy.validate(context: context, document: document)) != nil else { return nil }
        return invoice
    }

    private var retainedOriginal: Invoice? {
        guard let retainedDraft else { return nil }
        return BillingMilestoneReconciliation.original(for: retainedDraft, in: syncedInvoices, payments: reviewPayments)
    }

    init(document: QuickBooksBillingDocument, context: ModelContext) {
        self.document = document; self.context = context
        customerName = document.customer?.name ?? "Saved customer"
    }

    private var proposal: BillingPublicationRequest? { original?.proposal ?? pending?.request }
    private var status: String {
        if retainedDraft != nil { return retainedOriginal == nil ? "Retained draft needs review" : "Duplicate draft retained" }
        if milestoneOriginal != nil { return "Original milestone invoice found" }
        return switch original?.publication.state {
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
            if let retainedDraft {
                Section {
                    Text(BillingMilestoneReconciliation.retainedMessage).font(.callout)
                    if let invoice = retainedOriginal {
                        NavigationLink("Open original milestone invoice") {
                            BillingMilestoneInvoiceReview(invoice: invoice, context: context)
                        }.accessibilityIdentifier("BillingReviewOpenMilestoneOriginal")
                    } else {
                        Text("The saved review cannot yet be verified on this device. Keep both records and let accounting check the original and CloudKit status.")
                    }
                    DisclosureGroup("Retained draft details") {
                        Text(retainedDraft.lineItemSummary)
                        LabeledContent("Saved draft amount", value: retainedDraft.amount.formatted(.currency(code: "USD")))
                        if let notes = retainedDraft.notes, !notes.isEmpty { Text(notes) }
                        ForEach(reviewAttachments.filter { $0.invoiceID == retainedDraft.id && $0.customer === retainedDraft.customer }) { attachment in
                            Label(attachment.displayName, systemImage: "paperclip")
                        }
                        Text("Supporting files remain linked to this draft in the customer’s Files workspace.").font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("BillingReviewRetainedDraftDetails")
                }
            }
            if let milestoneOriginal {
                Section {
                    if let invoice = matchingMilestoneInvoice(milestoneOriginal) {
                        Text("Another device saved this milestone first. Open that invoice to review its saved items and QuickBooks status.")
                            .font(.callout).foregroundStyle(.secondary)
                        NavigationLink("Open original milestone invoice") {
                            BillingMilestoneInvoiceReview(invoice: invoice, context: context)
                        }
                        .accessibilityIdentifier("BillingReviewOpenMilestoneOriginal")
                        if milestoneOriginal.state == .confirmed, invoice.quickBooksID != nil,
                           flow?.canApproveSharedDraft == true, shared?.journal.pending == nil {
                            Button("Retain this unused draft") { confirmRetain = true }.disabled(busy)
                                .accessibilityIdentifier("BillingReviewRetainMilestoneDraft")
                        }
                    } else {
                        Text(syncedInvoices.contains(where: { $0.id == milestoneOriginal.localDocumentID })
                             ? "The original invoice needs review on this device. Reopen your business workspace and ask accounting to check its customer, job and saved identity."
                             : "The original invoice is still syncing to this device. Keep this local draft and check again when CloudKit finishes syncing.")
                            .accessibilityIdentifier("BillingReviewMilestoneSyncPending")
                    }
                    Button("Check again") { Task { await load() } }.disabled(busy)
                        .accessibilityIdentifier("BillingReviewCheckMilestoneOriginal")
                } header: {
                    Text("Original milestone invoice")
                } footer: {
                    Text("No invoice, attachment or payment is replaced or deleted.")
                }
            }
            if let proposal {
                Section("Original proposal") {
                    LabeledContent("Document", value: proposal.documentType.rawValue)
                    LabeledContent("Date", value: proposal.document.TxnDate)
                    if let due = proposal.document.DueDate { LabeledContent("Due", value: due) }
                    ForEach(Array(proposal.document.Line.prefix(visibleLines).enumerated()), id: \.offset) { _, line in
                        BillingPublicationLineReview(line: line)
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
        .onDisappear {
            visitID = UUID()
            lifecycle.cancel()
            // Retain the displayed navigation link while its child is pushed;
            // recreate only the cancelled workflow owner on the next appearance.
            flow = nil; shared = nil; message = nil; busy = false
        }
        .confirmationDialog("Publish this original proposal?", isPresented: $confirmSend, titleVisibility: .visible) {
            Button("Publish original proposal") { Task { await publish() } }
        } message: { Text("QuickBooks will receive the saved lines, prices and dates shown here. Changed local drafts are not substituted.") }
        .confirmationDialog("Approve these exact field prices?", isPresented: $confirmApproval, titleVisibility: .visible) {
            Button("Approve field prices") { Task { await approve() } }
        } message: { Text("The original technician may publish this unchanged proposal. A different price or draft requires a new review.") }
        .confirmationDialog("Retain this unused milestone draft?", isPresented: $confirmRetain, titleVisibility: .visible) {
            Button("Retain duplicate draft") { Task { await retainDraft() } }
        } message: {
            Text("The original confirmed invoice remains the bill. This draft and its files stay available, but this draft will not add a second amount to reports or customer statements. Nothing is deleted or changed in QuickBooks.")
        }
    }

    private func load() async {
        guard !busy else { return }
        let visit = visitID
        busy = true; defer { if visit == visitID { busy = false } }
        do {
            if retainedDraft != nil {
                milestoneOriginal = nil; original = nil; pending = nil; didLoad = true; message = nil
                return
            }
            if flow == nil {
                #if DEBUG
                if GunnAireCloudKit.usesTestDatabase, ProcessInfo.processInfo.arguments.contains("-uiTestNativeBillingReview") {
                    try await loadFixture()
                }
                #endif
            }
            if flow == nil {
                let preparation = try SharedBillingPreparation(document: document, context: context,
                    isCurrent: { visit == visitID })
                let value = try await preparation.makeWorkflow(lifecycle: lifecycle)
                guard visit == visitID else { throw CancellationError() }
                flow = value; shared = try value.openSharedReview()
            }
            try await refresh()
            if visit == visitID { message = nil }
        } catch is CancellationError {
            // Navigation invalidates the old owner; it is not a business error.
        } catch { if visit == visitID { message = error.localizedDescription } }
    }
    private func refresh() async throws {
        guard let shared, let customer = document.customer else { throw BillingNativeError.pending }
        let visit = visitID
        if let found = try await flow?.originalMilestone(), found.localDocumentID != document.id {
            guard visit == visitID else { throw CancellationError() }
            milestoneOriginal = found
            original = nil; pending = nil; didLoad = true
            return
        }
        let found = try await shared.original(customerID: customer.id)
        try shared.check()
        guard visit == visitID else { throw CancellationError() }
        milestoneOriginal = nil
        original = found
        if shared.journal.pending == nil, let original, let flow,
           original.proposal.draftRevision == (try flow.billingDraftRevision()), original.publication.state != .cancelled {
            try shared.adoptOriginal(original, revision: flow.billingDraftRevision())
        }
        pending = shared.journal.pending
        didLoad = true
    }

    private func matchingMilestoneInvoice(_ original: BillingMilestoneOriginal) -> Invoice? {
        // Observe CloudKit arrivals but never choose arbitrarily between duplicate
        // model UUIDs or a record from another customer, job or business access.
        guard syncedInvoices.filter({ $0.id == original.localDocumentID }).count == 1,
              let invoice = try? original.localInvoice(in: context, for: document) else { return nil }
        do { try QuickBooksBillingAccessPolicy.validate(context: context, document: .invoice(invoice)); return invoice }
        catch { return nil }
    }
    private func retainDraft() async {
        guard !busy, let flow else { return }
        let visit = visitID
        busy = true; defer { if visit == visitID { busy = false } }
        do {
            try await flow.retainDuplicateMilestoneDraft()
            guard visit == visitID else { return }
            lifecycle.cancel(); self.flow = nil; shared = nil
            milestoneOriginal = nil; original = nil; pending = nil; message = nil; didLoad = true
        } catch is CancellationError {} catch { if visit == visitID { message = error.localizedDescription } }
    }
    private func recover() async {
        guard !busy else { return }; let visit = visitID
        busy = true; defer { if visit == visitID { busy = false } }
        do {
            try await refresh()
            if pending != nil, let flow,
               [.sending, .unknown, .confirmed].contains(original?.publication.state) {
                let result = try await flow.recoverOriginalFromReview()
                guard visit == visitID else { return }
                message = result.message
                try await refresh()
            } else { message = status }
        } catch is CancellationError {} catch { if visit == visitID { message = error.localizedDescription } }
    }
    private func publish() async {
        guard !busy, let flow else { return }; let visit = visitID
        busy = true; defer { if visit == visitID { busy = false } }
        do {
            let result = try await flow.resumeOriginalFromReview()
            guard visit == visitID else { return }
            message = result.message
            try await refresh()
            do { try await flow.uploadLinkedAttachments() }
            catch { if visit == visitID { message = result.message + " Supporting files remain pending." } }
        } catch is CancellationError {} catch {
            guard visit == visitID else { return }
            message = error.localizedDescription; try? await refresh()
        }
    }
    private func approve() async {
        guard !busy, let shared, let original, flow?.canApproveSharedDraft == true else { return }
        let visit = visitID
        busy = true; defer { if visit == visitID { busy = false } }
        do {
            try await shared.client.approveOriginal(original, workflow: shared.workflow)
            guard visit == visitID else { return }
            message = "Field prices approved. The original technician can now publish this unchanged proposal."
            try await refresh()
        } catch is CancellationError {} catch { if visit == visitID { message = error.localizedDescription } }
    }
    private func cancel() async {
        guard !busy, let shared else { return }; let visit = visitID
        busy = true; defer { if visit == visitID { busy = false } }
        do {
            try await shared.cancelUnsent()
            guard visit == visitID else { return }
            original = nil; pending = nil
            message = "Unsent request cancelled. Return to this document to review and save your changes. No QuickBooks record was deleted."
        } catch is CancellationError {} catch { if visit == visitID { message = error.localizedDescription } }
    }

    #if DEBUG
    private func loadFixture() async throws {
        let company = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
        let attempt = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
        let stage = UUID(uuidString: "10000000-0000-4000-8000-000000000007")!
        let originalID = UUID(uuidString: "10000000-0000-4000-8000-000000000006")!
        let handoff = ProcessInfo.processInfo.arguments.contains("-uiTestMilestoneOriginalReview")
        let missingOriginal = ProcessInfo.processInfo.arguments.contains("-uiTestMilestoneOriginalMissing")
        let retain = ProcessInfo.processInfo.arguments.contains("-uiTestRetainMilestoneDraft")
        if handoff, case .invoice(let invoice) = document, let customer = invoice.customer {
            invoice.projectMilestoneID = stage; invoice.projectMilestoneTitle = "Deposit"
            invoice.serviceCallID = invoice.serviceCallID ?? UUID(uuidString: "10000000-0000-4000-8000-000000000008")!
            if !missingOriginal, !(try context.fetch(FetchDescriptor<Invoice>())).contains(where: { $0.id == originalID }) {
                context.insert(Invoice(id: originalID, serviceCallID: invoice.serviceCallID,
                    serviceLocationID: invoice.serviceLocationID, siteAddress: invoice.siteAddress, customer: customer,
                    quickBooksID: retain ? "BILLING-UI-189" : nil, quickBooksBalanceDue: retain ? 189 : nil,
                    catalogSnapshotJSON: invoice.catalogSnapshotJSON, amount: invoice.subtotalAmount,
                    projectMilestoneID: stage, projectMilestoneTitle: "Deposit",
                    dueDate: invoice.effectiveDueDate(), createdAt: invoice.createdAt))
            }
        }
        let recover = ProcessInfo.processInfo.arguments.contains("-uiTestNativeBillingAccepted")
        var state = recover || retain ? "confirmed" : "reserved"
        var request: BillingPublicationRequest?
        var saved: BillingNativeJournal?
        let store = BillingNativeJournalStore(read: { scope in saved ?? .init(scope: scope) }, write: { saved = $0 })
        let client = BillingPublicationClient { path, method, _ in
            if method == "GET", path.hasPrefix("/api/billing-publications/connection?") {
                let query = Dictionary(uniqueKeysWithValues: (URLComponents(string: path)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                var response: [String: Any] = query
                response.merge(["realmID": "billing-review-fixture", "environment": Config.QuickBooks.environment,
                    "connectionRevision": String(repeating: "a", count: 64), "protocolVersion": 1]) { _, new in new }
                return try JSONSerialization.data(withJSONObject: response)
            }
            guard let request else { throw BillingNativeError.pending }
            let row: [String: Any] = ["id": attempt.uuidString, "companyID": company.uuidString, "realmID": request.realmID,
                "environment": request.environment, "documentType": request.documentType.rawValue,
                "localDocumentID": request.localDocumentID.uuidString, "localCustomerID": request.localCustomerID.uuidString,
                "operation": "create", "state": state, "providerID": state == "confirmed" ? "BILLING-UI-189" : NSNull(),
                "updatedAt": "2026-09-07T12:00:00Z"]
            if method == "GET" {
                if handoff, path.hasPrefix("/api/billing-publications/context?") {
                    return try JSONSerialization.data(withJSONObject: ["companyID": company.uuidString, "realmID": request.realmID,
                        "environment": request.environment, "documentType": "Invoice", "localDocumentID": document.id.uuidString,
                        "localCustomerID": request.localCustomerID.uuidString, "serviceCallID": document.serviceCallID!.uuidString,
                        "connectionRevision": request.connectionRevision, "customerProviderID": request.document.CustomerRef.value,
                        "providerID": NSNull(), "authority": "office", "assignment": NSNull(), "document": NSNull(),
                        "milestoneIdentityVersion": 1,
                        "milestone": ["projectMilestoneID": stage.uuidString, "localDocumentID": originalID.uuidString,
                            "localCustomerID": request.localCustomerID.uuidString, "publicationID": attempt.uuidString, "state": state]])
                }
                if retain, path.hasPrefix("/api/billing-publications?") {
                    return try JSONSerialization.data(withJSONObject: ["publications": [], "nextCursor": NSNull()])
                }
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
        let fixtureItems = try context.fetch(FetchDescriptor<Item>())
        let selected = Set(CatalogLineItemSnapshot.decoded(from: document.snapshotJSON).map(\.catalogItemID))
        for item in fixtureItems where selected.contains(item.id) && item.quickBooksID == nil {
            item.quickBooksID = "BILLING-UI-ITEM-" + item.id.uuidString
        }
        if document.customer?.quickBooksID == nil { document.customer?.quickBooksID = "BILLING-UI-CUSTOMER" }
        try context.save()
        let visit = visitID
        let preparation = try SharedBillingPreparation(document: document, context: context,
            isCurrent: { visit == visitID }, client: client,
            catalog: { _ in throw CatalogPublicationError.unavailable },
            customer: { _ in throw CustomerPublicationError.unavailable }, fixtureCompanyID: company)
        let value = try await preparation.makeWorkflow(lifecycle: lifecycle, billingJournal: store)
        guard let customer = document.customer else { throw BillingNativeError.pending }
        var lines = try QuickBooksDocumentLinePublication.lines(snapshotJSON: document.snapshotJSON,
            expectedSubtotal: document.subtotal, catalogItems: fixtureItems)
        if ProcessInfo.processInfo.arguments.contains("-uiTestBillingBundleReview"), let first = lines.first {
            // A server-original bundle proposal can differ from this device's
            // current draft. This fixture only exercises read/review/cancel;
            // publish still has no fixture route and cannot reach accounting.
            let members = ["First retained labor", "Second retained labor"].map { name in
                QuickBooksLineItem(Amount: 94.5, DetailType: "SalesItemLineDetail", Description: name,
                    SalesItemLineDetail: .init(ItemRef: first.SalesItemLineDetail.ItemRef, Qty: 1, UnitPrice: 94.5,
                                               TaxCodeRef: .init(value: "NON", name: nil)))
            }
            lines = [.bundle(description: "Saved repair bundle", reference: .init(value: "BILLING-UI-GROUP", name: nil),
                             quantity: 2, components: members)]
        }
        let revision = try value.billingDraftRevision()
        request = .init(companyID: company, realmID: "billing-review-fixture", environment: Config.QuickBooks.environment,
            documentType: .invoice, localDocumentID: retain ? originalID : document.id, localCustomerID: customer.id, operation: .create,
            document: .init(CustomerRef: .init(value: customer.quickBooksID ?? "C1", name: nil), Line: lines, TxnDate: "2026-09-07"),
            connectionRevision: String(repeating: "a", count: 64), serviceCallID: document.serviceCallID, draftRevision: revision,
            projectMilestoneID: retain ? stage : nil)
        let journalScope = BillingNativeJournalScope(document: request!.scope, actorEmail: AppAccess.normalizedEmail(AppIdentity.currentEmail))
        if !retain { saved = .init(scope: journalScope, pending: .init(request: request!, draftRevision: revision, submitted: true, publicationID: attempt)) }
        flow = value; shared = try value.openSharedReview()
    }
    #endif
}

@MainActor private struct BillingMilestoneInvoiceReview: View {
    let invoice: Invoice
    let context: ModelContext
    @Query private var invoices: [Invoice]
    @Query private var users: [AppUser]

    private var allowed: Bool {
        guard !users.isEmpty, invoices.contains(where: { $0 === invoice }) else { return false }
        do { try QuickBooksBillingAccessPolicy.validate(context: context, document: .invoice(invoice)); return true }
        catch { return false }
    }

    var body: some View {
        List {
            if allowed {
                Section { ProjectProgressInvoiceReview(invoice: invoice) }
                Section {
                    NavigationLink("Billing Review") {
                        BillingPublicationReviewView(document: .invoice(invoice), context: context)
                    }
                }
            } else {
                Text("Reopen this invoice from your current business workspace.")
            }
        }
        .navigationTitle("Original Invoice")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Keep the bill readable, with exact repeated components one disclosure away.
/// No account references, receipt payloads, internal IDs or email footer.
@MainActor struct BillingPublicationLineReview: View {
    let line: QuickBooksLineItem
    var body: some View {
        if line.DetailType == "GroupLineDetail", let group = line.GroupLineDetail {
            DisclosureGroup {
                ForEach(Array(group.Line.enumerated()), id: \.offset) { _, member in
                    row(member)
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    row(line)
                    Text("\(group.Quantity.formatted()) \(group.Quantity == 1 ? "bundle" : "bundles") · \(group.Line.count) included items")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("BillingBundleComponents")
        } else { row(line) }
    }

    private func row(_ value: QuickBooksLineItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(value.Description?.isEmpty == false ? value.Description! : value.DetailType == "DiscountLineDetail" ? "Discount" : value.GroupLineDetail?.GroupItemRef.name ?? "Saved item")
                Spacer()
                if let amount = QuickBooksSalesLineContract.displayedAmount(value) {
                    Text(amount, format: .currency(code: "USD"))
                } else { Text("Review amount").foregroundStyle(.secondary) }
            }
            if value.DetailType == "SalesItemLineDetail", let qty = value.SalesItemLineDetail.Qty,
               let price = value.SalesItemLineDetail.UnitPrice {
                Text("\(qty.formatted()) × \(QuickBooksSalesLineContract.unitPriceLabel(price))")
                    .font(.caption).foregroundStyle(.secondary)
                if value.SalesItemLineDetail.TaxCodeRef?.value == "TAX" {
                    Text("Taxable").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
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
