import SwiftUI
import SwiftData

struct SharedTimeReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Item.name) private var items: [Item]
    @Query private var users: [AppUser]
    let entry: TimeEntry
    let workerName: String
    @State private var owner: SharedTimeOwner?
    @State private var journal: SharedTimeJournal?
    @State private var connection: SharedTimeWorkerContext?
    @State private var legacy: SharedTimeLegacyCandidate?
    @State private var itemID: UUID?
    @State private var busy = false
    @State private var message: String?
    @State private var visit = UUID()
    @State private var visible = false
    @State private var confirming = false
    @State private var adopting = false
    @State private var cancelling = false
    @State private var clearingPreparation = false

    private var isAdministrator: Bool { AppAccess.activeRole(email: AppIdentity.currentEmail, users: users) == .admin }
    private var currentMatches: Bool {
        guard let owner, let publication = journal?.publication else { return false }
        return (try? SharedTimeSource(entry, context: modelContext).revision) == publication.entryRevision &&
            (try? owner.source.revision) == publication.entryRevision
    }
    private var canConfirm: Bool {
        guard let publication = journal?.publication, let owner else { return false }
        return publication.state == "reserved" && journal?.confirmationRequested == false && currentMatches &&
            publication.preparedByEmail == owner.access.actorEmail &&
            (SharedTimeError.date(publication.expiresAt) ?? .distantPast) > Date()
    }
    private func status(_ publication: SharedTimePublication) -> String {
        switch publication.state {
        case "confirmed": "QuickBooks result confirmed"
        case "cancelled": "Unsent proposal cancelled"
        case "sending", "unknown": "Original result needs recovery"
        default: journal?.confirmationRequested == true ? "Original confirmation needs recovery" : "Ready for office review"
        }
    }

    var body: some View {
        Form {
            Section {
                Text(workerName).font(.headline)
                if let source = owner?.source {
                    LabeledContent("Work", value: TimeEntryActivity(rawValue: source.activity)?.displayName ?? "Time entry")
                    Text(source.clockIn.formatted(date: .abbreviated, time: .shortened))
                    if let end = source.clockOut { Text("Ended " + end.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary) }
                }
            }
            if let publication = journal?.publication, publication.state != "cancelled" {
                Section("Original QuickBooks review") {
                    Text(status(publication)).font(.headline).accessibilityIdentifier("SharedTimePublicationStatus")
                    LabeledContent(publication.worker.kind, value: publication.worker.displayName)
                    LabeledContent("Approved time", value: "\(publication.timeActivity.Hours) hr \(publication.timeActivity.Minutes) min")
                        .accessibilityIdentifier("SharedTimeApprovedDuration")
                    LabeledContent("Work date", value: publication.timeActivity.TxnDate)
                    if !publication.review.notes.isEmpty { Text(publication.review.notes).textSelection(.enabled) }
                    if !currentMatches {
                        Text("The local entry changed. Recover or cancel this original proposal; its result will not overwrite the changed time.")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    if publication.state == "reserved" {
                        if canConfirm, legacy == nil, entry.quickBooksTimeActivityID == nil {
                            Button("Publish Approved Time") { confirming = true }.disabled(busy)
                                .accessibilityIdentifier("SharedTimePublish")
                        }
                        Button("Cancel Unsent Proposal", role: .destructive) { cancelling = true }.disabled(busy)
                            .accessibilityIdentifier("SharedTimeCancelProposal")
                    }
                    if publication.state == "confirmed" {
                        Button("Restore Time Link") { run { try $0.restoreSavedLink() } }
                            .disabled(busy || !currentMatches).accessibilityIdentifier("SharedTimeRestore")
                    } else {
                        if entry.quickBooksTimeActivityID != nil {
                            Text("This entry already has a QuickBooks link. Only the same existing record can be recovered or adopted; no new time will be sent.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Button("Recover Original Result") {
                            run { owner in
                                let result = try await owner.recover(publication); legacy = result.legacyCandidate
                                return try owner.journal()
                            }
                        }.disabled(busy).accessibilityIdentifier("SharedTimeRecover")
                    }
                }
                if let legacy {
                    Section("Existing QuickBooks time") {
                        Text("One older time record matches these hours, worker, date and references. Review its note before linking it.")
                        Text(legacy.description.split(separator: "\n").filter { !$0.hasPrefix("GUNNAIRE-TIME") }.joined(separator: "\n"))
                            .font(.footnote).textSelection(.enabled)
                        if canConfirm, entry.quickBooksTimeActivityID == nil || entry.quickBooksTimeActivityID == legacy.providerID {
                            Button("Link Existing Time") { adopting = true }.disabled(busy)
                                .accessibilityIdentifier("SharedTimeAdopt")
                        }
                    }
                }
            } else {
                if journal?.publication?.state == "cancelled" {
                    Section { Text("Unsent proposal cancelled. Approved local hours are unchanged.")
                        .accessibilityIdentifier("SharedTimeCancelled") }
                }
                Section("QuickBooks worker") {
                    if let mapping = connection?.mapping {
                        LabeledContent(mapping.kind, value: mapping.displayName)
                        Text(mapping.usable ? "Ready for approved time" : "Administrator review is needed").foregroundStyle(.secondary)
                    } else { Text("Review the business worker mapping before publishing time.").foregroundStyle(.secondary) }
                    if isAdministrator {
                        NavigationLink("Review Worker Mapping") {
                            SharedTimeWorkerReview(workerEmail: AppAccess.normalizedEmail(entry.userEmail), workerName: workerName)
                        }.accessibilityIdentifier("SharedTimeReviewWorker")
                    }
                }
                Section {
                    Picker("Service item", selection: $itemID) {
                        Text("No service item").tag(UUID?.none)
                        ForEach(items.filter { $0.itemType == .service }) { item in Text(item.name).tag(Optional(item.id)) }
                    }.disabled(journal?.request != nil && journal?.publication == nil)
                    Button("Prepare Time Review") {
                        run { owner in try await owner.prepare(itemID: itemID) }
                    }.disabled(busy).accessibilityIdentifier("SharedTimePrepare")
                } header: { Text("Time details") } footer: {
                    Text("Preparation keeps the original hours for review. Publishing requires a separate office confirmation. No invoice, payment or payroll run is created.")
                }
                if journal?.request != nil, journal?.publication == nil {
                    Section("Saved preparation") {
                        Text("An earlier preparation is retained. Prepare Time Review checks that original request; it does not send time to QuickBooks.")
                        Button("Clear Unsent Preparation") { clearingPreparation = true }
                            .disabled(busy).accessibilityIdentifier("SharedTimeClearPreparation")
                    }
                }
            }
            if let message { Section { Text(message).foregroundStyle(.secondary).accessibilityIdentifier("SharedTimeReviewMessage") } }
            Section {
                Button {
                    run { owner in
                        let saved = try await owner.refresh()
                        if saved.publication == nil || saved.publication?.state == "cancelled" { connection = try await owner.connection() }
                        return saved
                    }
                } label: {
                    if busy { ProgressView("Checking original time…") } else { Label("Refresh Review", systemImage: "arrow.clockwise") }
                }.disabled(busy).accessibilityIdentifier("SharedTimeRefresh")
            }
        }
        .navigationTitle("QuickBooks Time")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("SharedTimeReview")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        .task {
            visible = true
            run { owner in
                let saved = try owner.journal(); journal = saved; itemID = saved.request?.localItemID
                let fresh = try await owner.refresh()
                if fresh.publication == nil || fresh.publication?.state == "cancelled" { connection = try await owner.connection() }
                return fresh
            }
        }
        .onDisappear { visible = false; visit = UUID(); owner = nil; busy = false; journal = nil; connection = nil; legacy = nil }
        .alert("Clear this unfinished preparation?", isPresented: $clearingPreparation) {
            Button("Keep Preparation", role: .cancel) { }
            Button("Clear Preparation") { run { try await $0.clearUnsentPreparation() } }
        } message: { Text("The business service is checked first. If it already holds a proposal, recover or cancel that proposal instead. Your original local hours are kept.") }
        .alert("Publish this approved time?", isPresented: $confirming) {
            Button("Cancel", role: .cancel) { }
            if let publication = journal?.publication {
                Button("Publish Time") { run { owner in let result = try await owner.decide(publication); legacy = result.legacyCandidate; return try owner.journal() } }
                    .accessibilityIdentifier("SharedTimeConfirmPublication")
            }
        } message: { Text("This records the displayed worker, date and hours in the business QuickBooks account. An uncertain send can only be recovered, not repeated.") }
        .alert("Link this existing time?", isPresented: $adopting) {
            Button("Cancel", role: .cancel) { }
            if let publication = journal?.publication, let legacy {
                Button("Link Existing Record") { run { owner in _ = try await owner.decide(publication, legacy: legacy); self.legacy = nil; return try owner.journal() } }
            }
        } message: { Text("No new time record will be created. The existing record's current identity and values will be checked again.") }
        .alert("Cancel this unsent proposal?", isPresented: $cancelling) {
            Button("Keep Proposal", role: .cancel) { }
            if let publication = journal?.publication {
                Button("Cancel Proposal", role: .destructive) { run { owner in let value = try await owner.cancel(publication); legacy = nil; return value } }
                    .accessibilityIdentifier("SharedTimeConfirmCancellation")
            }
        } message: { Text("Your local approved hours are kept. A request already being sent cannot be cancelled here.") }
    }

    private func run(_ action: @escaping (SharedTimeOwner) async throws -> SharedTimeJournal) {
        guard !busy else { return }
        busy = true; message = nil
        let original = visit
        Task { @MainActor in
            defer { if visit == original { busy = false } }
            do {
                let current: SharedTimeOwner
                if let owner { current = owner }
                else {
                    let fixture = try SharedTimeUIFixture.services(context: modelContext, workerEmail: AppAccess.normalizedEmail(entry.userEmail),
                        isCurrent: { visible && visit == original })
                    let access = try fixture?.access ?? SharedTimeAccess(context: modelContext, isCurrent: { visible && visit == original })
                    current = try SharedTimeOwner(entry: entry, context: modelContext, access: access, client: fixture?.client, store: fixture?.store); owner = current
                }
                let value = try await action(current)
                guard visible, visit == original else { return }
                journal = value; itemID = value.request?.localItemID
            } catch {
                if visible, visit == original {
                    if let saved = try? owner?.journal() { journal = saved }
                    message = SharedTimeError.safe(error).localizedDescription
                }
            }
        }
    }
}
