import SwiftUI
import SwiftData

/// A reviewed document keeps only its original main-context object. The user
/// census is read in an isolated context before this permit becomes visible.
@MainActor
final class BillingReviewAccessPermit {
    let document: QuickBooksBillingDocument
    private let context: ModelContext
    private let email: String?
    private let stamp: CompanyWorkspaceOperationStamp?
    private let unchanged: () throws -> Void

    private init(document: QuickBooksBillingDocument, context: ModelContext,
                 email: String?, stamp: CompanyWorkspaceOperationStamp?) {
        self.document = document; self.context = context; self.email = email; self.stamp = stamp
        unchanged = document.validation(context: context)
    }

    static func acquire(document: QuickBooksBillingDocument, context: ModelContext) async throws -> BillingReviewAccessPermit {
        let permit = BillingReviewAccessPermit(document: document, context: context,
            email: AppIdentity.currentEmail, stamp: CompanyWorkspaceAccessController.shared.operationStamp)
        try await QuickBooksBillingAccessPolicy.checkOffMain(context: context, document: document,
            email: permit.email, stamp: permit.stamp)
        try permit.check()
        return permit
    }

    func check() throws {
        try QuickBooksBillingAccessPolicy.checkLocalFence(context: context, document: document,
            email: email, stamp: stamp)
        try unchanged()
    }

    func covers(_ invoice: Invoice) -> Bool {
        guard case .invoice(let retained) = document, retained === invoice else { return false }
        return (try? check()) != nil
    }
}

/// A single review page reached from the original invoice/estimate or job.
/// No raw payload, account-email footer, or additional top-level workspace.
@MainActor struct BillingPublicationReviewView: View {
    let document: QuickBooksBillingDocument
    let context: ModelContext
    let availableItems: [Item]
    private let customerName: String
    @State private var lifecycle = QuickBooksSyncLifecycle()
    @State private var flow: QuickBooksBillingWorkflow?
    @State private var shared: BillingNativePublication?
    @State private var original: BillingOriginalProposal?
    @State private var pending: BillingNativePending?
    @State private var backgroundJob: BillingEstimateJobResponse?
    @State private var busy = false
    @State private var message: String?
    @State private var confirmSend = false
    @State private var confirmApproval = false
    @State private var visibleLines = 20
    @State private var didLoad = false
    @State private var milestoneOriginal: BillingMilestoneOriginal?
    @State private var retainedDraftPermit: BillingReviewAccessPermit?
    @State private var milestoneInvoicePermit: BillingReviewAccessPermit?
    @Query private var syncedInvoices: [Invoice]
    @State private var visitID = UUID()
    @State private var confirmRetain = false
    @Query private var reviewUsers: [AppUser]
    @Query private var reviewAttachments: [ServiceDocumentAttachment]
    @Query private var reviewPayments: [Payment]

    private var userAccessRevision: [String] {
        let email = AppAccess.normalizedEmail(AppIdentity.currentEmail)
        return reviewUsers.filter { AppAccess.normalizedEmail($0.email) == email }
            .map { "\($0.id.uuidString):\($0.roleRawValue):\($0.isActive)" }.sorted()
    }

    private var retainedDraft: Invoice? {
        guard case .invoice(let invoice) = document, invoice.milestoneDraftReceiptJSON != nil,
              retainedDraftPermit?.covers(invoice) == true else { return nil }
        return invoice
    }

    private var retainedOriginal: Invoice? {
        guard let retainedDraft else { return nil }
        guard let original = BillingMilestoneReconciliation.original(for: retainedDraft,
            in: syncedInvoices, payments: reviewPayments), milestoneInvoicePermit?.covers(original) == true else { return nil }
        return original
    }

    init(document: QuickBooksBillingDocument, context: ModelContext, availableItems: [Item] = []) {
        self.document = document; self.context = context; self.availableItems = availableItems
        customerName = document.customer?.name ?? "Saved customer"
    }

    private var proposal: BillingPublicationRequest? { original?.proposal ?? pending?.request }
    private var canApproveOfficeReview: Bool {
        guard flow != nil else { return false }
        let email = AppIdentity.currentEmail
        let role = AppAccess.activeRole(email: email, users: reviewUsers)
        let isInvoice: Bool
        switch document { case .invoice: isInvoice = true; case .estimate: isInvoice = false }
        guard role == .admin || (isInvoice ? role == .accounting : role == .dispatcher) else { return false }
        return QuickBooksBillingAccessPolicy.allows(email: email, users: reviewUsers,
            verifiedRole: role, isInvoice: isInvoice, assignedToJob: false)
    }
    private var status: String {
        if retainedDraft != nil { return retainedOriginal == nil ? "Retained draft needs review" : "Duplicate draft retained" }
        if milestoneOriginal != nil { return "Original milestone invoice found" }
        if backgroundJob?.background.state == .review { return "QuickBooks estimate needs review" }
        if pending?.backgroundState == .queueRequested { return "QuickBooks queue request needs confirmation" }
        if pending?.backgroundState == .queued, original?.publication.state != .confirmed {
            return "Queued for QuickBooks; not confirmed"
        }
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
                           canApproveOfficeReview, shared?.journal.pending == nil {
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
                    if pending != nil, pending?.settled == false, pending?.backgroundState == nil,
                       original?.connectionChanged != true,
                       original == nil || original?.publication.state == .reserved {
                        Button("Publish original proposal") { confirmSend = true }.disabled(busy)
                            .accessibilityIdentifier("BillingReviewPublish")
                    }
                    if pending?.backgroundState == .queued,
                       backgroundJob?.background.state == .review {
                        Button("Retry original QuickBooks queue") { Task { await retryQueued() } }.disabled(busy)
                            .accessibilityIdentifier("BillingReviewRetryEstimateQueue")
                    }
                    if original?.reviewableByOffice == true, canApproveOfficeReview {
                        Button("Approve these field prices") { confirmApproval = true }.disabled(busy)
                            .accessibilityIdentifier("BillingReviewApprove")
                    }
                    if pending != nil, pending?.settled == false, pending?.backgroundState == nil,
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
        .onChange(of: userAccessRevision) { _, _ in
            retainedDraftPermit = nil; milestoneInvoicePermit = nil
            Task { await load() }
        }
        .onChange(of: syncedInvoices.map(\.persistentModelID)) { _, _ in
            Task { await load() }
        }
        .onDisappear {
            visitID = UUID()
            lifecycle.cancel()
            // Retain the displayed navigation link while its child is pushed;
            // recreate only the cancelled workflow owner on the next appearance.
            flow = nil; shared = nil; message = nil; busy = false
            retainedDraftPermit = nil; milestoneInvoicePermit = nil
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
        let accessRevision = userAccessRevision
        busy = true
        defer {
            if visit == visitID {
                busy = false
                if accessRevision != userAccessRevision { Task { await load() } }
            }
        }
        do {
            if case .invoice(let invoice) = document, invoice.milestoneDraftReceiptJSON != nil {
                let permit = try await BillingReviewAccessPermit.acquire(document: document, context: context)
                guard visit == visitID, accessRevision == userAccessRevision else { throw CancellationError() }
                retainedDraftPermit = permit
                if let original = BillingMilestoneReconciliation.original(for: invoice,
                    in: syncedInvoices, payments: reviewPayments) {
                    milestoneInvoicePermit = try? await BillingReviewAccessPermit.acquire(
                        document: .invoice(original), context: context)
                    guard visit == visitID, accessRevision == userAccessRevision else { throw CancellationError() }
                } else { milestoneInvoicePermit = nil }
            }
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
                let selectedItemCapture: QuickBooksSelectedItemCapture?
                if case .estimate = document {
                    let selected = Set(CatalogLineItemSnapshot.decoded(from: document.snapshotJSON)
                        .flatMap { [$0.catalogItemID] + $0.soldLeaves.map(\.catalogItemID) })
                    guard !selected.isEmpty, selected.count <= 20 else { throw QuickBooksBillingWorkflowError.changed }
                    selectedItemCapture = try QuickBooksSelectedItemCapture(document: document,
                        items: availableItems.filter { selected.contains($0.id) }, context: context)
                } else { selectedItemCapture = nil }
                let preparation = try SharedBillingPreparation(document: document, context: context,
                    isCurrent: { visit == visitID }, selectedItemCapture: selectedItemCapture)
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
        let accessRevision = userAccessRevision
        if let found = try await flow?.originalMilestone(), found.localDocumentID != document.id {
            guard visit == visitID, accessRevision == userAccessRevision else { throw CancellationError() }
            let candidate = try? found.localInvoice(in: context, for: document)
            milestoneInvoicePermit = nil
            if let candidate {
                milestoneInvoicePermit = try? await BillingReviewAccessPermit.acquire(
                    document: .invoice(candidate), context: context)
                guard visit == visitID, accessRevision == userAccessRevision else { throw CancellationError() }
            }
            milestoneOriginal = found
            original = nil; pending = nil; backgroundJob = nil; didLoad = true
            return
        }
        let found = try await shared.original(customerID: customer.id)
        try shared.check()
        guard visit == visitID else { throw CancellationError() }
        milestoneOriginal = nil
        original = found
        if shared.journal.pending == nil, let original, let flow,
           original.publication.state != .cancelled {
            let revision = try await flow.billingDraftRevisionAsync()
            try shared.check()
            guard visit == visitID else { throw CancellationError() }
            if original.proposal.draftRevision == revision {
                try shared.adoptOriginal(original, revision: revision)
            }
        }
        pending = shared.journal.pending
        backgroundJob = nil
        if let pending, pending.backgroundState == .queued, let id = pending.publicationID {
            backgroundJob = try? await shared.client.estimateJob(id, request: pending.request, workflow: shared.workflow)
        }
        didLoad = true
    }

    private func matchingMilestoneInvoice(_ original: BillingMilestoneOriginal) -> Invoice? {
        // Observe CloudKit arrivals but never choose arbitrarily between duplicate
        // model UUIDs or a record from another customer, job or business access.
        guard syncedInvoices.filter({ $0.id == original.localDocumentID }).count == 1,
              let invoice = try? original.localInvoice(in: context, for: document) else { return nil }
        return milestoneInvoicePermit?.covers(invoice) == true ? invoice : nil
    }
    private func retainDraft() async {
        guard !busy, canApproveOfficeReview, let flow else { return }
        let visit = visitID
        busy = true; defer { if visit == visitID { busy = false } }
        do {
            try await flow.retainDuplicateMilestoneDraft()
            guard visit == visitID else { return }
            let renewedPermit = try? await BillingReviewAccessPermit.acquire(document: document, context: context)
            guard visit == visitID else { return }
            retainedDraftPermit = renewedPermit
            lifecycle.cancel(); self.flow = nil; shared = nil
            milestoneOriginal = nil; original = nil; pending = nil; didLoad = true
            message = renewedPermit == nil ? "Draft saved. Reopen it from your current business workspace to review access." : nil
        } catch is CancellationError {} catch { if visit == visitID { message = error.localizedDescription } }
    }
    private func recover() async {
        guard !busy else { return }; let visit = visitID
        busy = true; defer { if visit == visitID { busy = false } }
        do {
            try await refresh()
            if pending?.backgroundState != nil, let flow, let shared {
                let revision = try await flow.billingDraftRevisionAsync()
                let job = try await shared.enqueueOriginal(revision: revision,
                    checkRevision: flow.billingDraftRevision,
                    checkProof: {
                        try await AutomaticOutboundSync.requireBoundProof(for: flow)
                        try await flow.checkEstimateQueueMappingsOffMain()
                    })
                if job.publication.state == .confirmed {
                    let result = try await flow.recoverOriginalFromReview()
                    guard visit == visitID else { return }
                    message = result.message
                    try await refresh()
                } else {
                    guard visit == visitID else { return }
                    message = job.background.state == .review
                        ? "The original QuickBooks estimate needs office review. No second estimate was sent."
                        : "Queued for QuickBooks; not confirmed. Check again for its original status."
                    try await refresh()
                }
            } else if pending != nil, let flow,
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
            // Sending from review is the operator's explicit decision; the
            // original company is bound or verified before the provider write.
            try await AutomaticOutboundSync.bindExplicitlyReviewed(flow)
            guard visit == visitID else { return }
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
    private func retryQueued() async {
        guard !busy, let flow, let shared, backgroundJob?.background.state == .review else { return }
        let visit = visitID
        busy = true; defer { if visit == visitID { busy = false } }
        do {
            let revision = try await flow.billingDraftRevisionAsync()
            let result = try await shared.enqueueOriginal(revision: revision,
                checkRevision: flow.billingDraftRevision,
                checkProof: {
                    try await AutomaticOutboundSync.requireBoundProof(for: flow)
                    try await flow.checkEstimateQueueMappingsOffMain()
                },
                retryReview: true)
            guard visit == visitID else { return }
            message = result.background.state == .review
                ? "The original estimate still needs office review. No second QuickBooks create was sent."
                : "The original estimate was queued again; QuickBooks has not confirmed it yet."
            try await refresh()
        } catch is CancellationError {} catch { if visit == visitID { message = error.localizedDescription } }
    }
    private func approve() async {
        guard !busy, canApproveOfficeReview, let shared, let original, let flow else { return }
        let visit = visitID
        busy = true; defer { if visit == visitID { busy = false } }
        do {
            try await flow.checkOfficeReviewAccessOffMain()
            guard visit == visitID else { throw CancellationError() }
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
        let revision = try await value.billingDraftRevisionAsync()
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
    @State private var accessPermit: BillingReviewAccessPermit?

    private var userAccessRevision: [String] {
        let email = AppAccess.normalizedEmail(AppIdentity.currentEmail)
        return users.filter { AppAccess.normalizedEmail($0.email) == email }
            .map { "\($0.id.uuidString):\($0.roleRawValue):\($0.isActive)" }.sorted()
    }

    private var allowed: Bool {
        invoices.contains(where: { $0 === invoice }) && accessPermit?.covers(invoice) == true
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
        .task {
            await authorize()
        }
        .onChange(of: userAccessRevision) { _, _ in
            accessPermit = nil
            Task { await authorize() }
        }
        .onDisappear { accessPermit = nil }
    }

    private func authorize() async {
        let revision = userAccessRevision
        let permit = try? await BillingReviewAccessPermit.acquire(document: .invoice(invoice), context: context)
        guard revision == userAccessRevision else { return }
        accessPermit = permit
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

@MainActor struct EstimateQuickBooksReviewStatus: View {
    let estimate: Estimate
    let context: ModelContext
    @State private var state: AutomaticOutboundSync.EstimateReviewState?
    @State private var refreshRevision = 0

    private var isOpenForPublication: Bool {
        !QuickBooksEstimatePublicationRecovery.queuedEstimates(from: [estimate]).isEmpty
    }

    private var refreshKey: String {
        let workspace = CompanyWorkspaceAccessController.shared
        return [estimate.id.uuidString, estimate.customer?.id.uuidString ?? "missing-customer",
                String(estimate.createdAt.timeIntervalSinceReferenceDate), estimate.quickBooksID ?? "unsynced",
                estimate.status,
                workspace.verifiedCompanyID?.uuidString ?? "unverified",
                String(describing: workspace.operationStamp), QuickBooksDataAPI.shared.realmID ?? "disconnected",
                QuickBooksDataAPI.shared.currentEnvironment,
                QuickBooksDataAPI.shared.isAuthenticated ? "authenticated" : "disconnected",
                String(refreshRevision)].joined(separator: "|")
    }

    var body: some View {
        Group {
            if !QuickBooksEstimatePublicationRecovery.convertedEstimatesNeedingReview(from: [estimate]).isEmpty {
                Label("Converted estimate needs QuickBooks review", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("EstimateQuickBooksConvertedReview-\(estimate.id.uuidString)")
                Text("The invoice was created before this estimate's QuickBooks link was confirmed. Check the original request in Billing Review before sending another proposal.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if isOpenForPublication {
                switch state {
                case .reviewRequired:
                    Label("QuickBooks review required", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("EstimateQuickBooksReviewRequired-\(estimate.id.uuidString)")
                    Text("Automatic publication has no usable proof for this saved estimate. Use Sync Saved Estimate to verify the company and publish the original.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .automaticPending:
                    Label("QuickBooks publication pending", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("EstimateQuickBooksPublicationPending-\(estimate.id.uuidString)")
                case .queueUnconfirmed:
                    Label("QuickBooks queue request needs confirmation", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("EstimateQuickBooksQueueUnconfirmed-\(estimate.id.uuidString)")
                case .serverQueued:
                    Label("Queued for QuickBooks; not confirmed", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("EstimateQuickBooksServerQueued-\(estimate.id.uuidString)")
                case .unavailable:
                    Label("QuickBooks status needs review", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("EstimateQuickBooksStatusUnavailable-\(estimate.id.uuidString)")
                case .published, .none:
                    EmptyView()
                }
            }
        }
        .task(id: refreshKey) {
            state = nil
            let result = await AutomaticOutboundSync.shared.estimateReviewState(for: estimate, context: context)
            guard !Task.isCancelled else { return }
            state = result
        }
        .onAppear { refreshRevision &+= 1 }
        .onReceive(NotificationCenter.default.publisher(for: AutomaticOutboundSync.estimateProofDidChange)) { notification in
            guard let documentID = notification.object as? UUID, documentID == estimate.id else { return }
            refreshRevision &+= 1
        }
    }
}

@MainActor struct BillingPublicationReviewLink: View {
    let document: QuickBooksBillingDocument
    let context: ModelContext
    var availableItems: [Item] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if case .estimate(let estimate) = document {
                EstimateQuickBooksReviewStatus(estimate: estimate, context: context)
            }
            NavigationLink {
                BillingPublicationReviewView(document: document, context: context,
                    availableItems: availableItems)
            } label: { Label("Billing Review", systemImage: "doc.text.magnifyingglass") }
            .accessibilityIdentifier("BillingReview-\(document.id.uuidString)")
        }
    }
}
