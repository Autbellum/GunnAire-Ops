import SwiftUI
import SwiftData

struct SharedTimeWorkerJournal: Codable {
    var version = 1
    let identity: SharedTimeWorkerIdentity
    let actorEmail: String
    var pending: SharedTimeWorkerRequest?
}

@MainActor final class SharedTimeWorkerOwner {
    let identity: SharedTimeWorkerIdentity
    let access: SharedTimeAccess
    let client: SharedTimeClient
    let store: SharedTimeLocalStore
    let validateMember: () throws -> Void
    var key: String { access.scope("worker", identity.workerEmail) }

    init(identity: SharedTimeWorkerIdentity, access: SharedTimeAccess, client: SharedTimeClient? = nil,
         store: SharedTimeLocalStore? = nil, validateMember: @escaping () throws -> Void = {}) throws {
        guard identity.companyID == access.companyID, SharedTimeError.validEmail(identity.workerEmail) else { throw SharedTimeError.mapping }
        self.identity = identity; self.access = access; self.client = client ?? .live; self.store = store ?? .device; self.validateMember = validateMember
        try check()
    }
    func check() throws { try access.check(); try validateMember() }
    func journal() throws -> SharedTimeWorkerJournal {
        try check()
        do {
            guard let data = try store.read(key) else { return .init(identity: identity, actorEmail: access.actorEmail) }
            let result = try JSONDecoder().decode(SharedTimeWorkerJournal.self, from: data)
            guard result.version == 1, result.identity == identity, result.actorEmail == access.actorEmail else { throw SharedTimeError.storage }
            try result.pending?.validate(identity); return result
        } catch { throw SharedTimeError.storage }
    }
    func persist(_ journal: SharedTimeWorkerJournal) throws { try check(); try store.write(key, JSONEncoder().encode(journal)) }
    func refresh(kind: String? = nil, providerID: String? = nil) async throws -> SharedTimeWorkerContext {
        try check()
        do {
            let result = try await client.worker(identity, kind: kind, providerID: providerID)
            try check(); return result
        } catch { try check(); throw SharedTimeError.safe(error) }
    }
    func save(_ reviewed: SharedTimeWorkerContext, enabled: Bool) async throws -> SharedTimeWorkerMapping {
        let claim = try SharedTimeMutationGate.begin(key); defer { SharedTimeMutationGate.finish(key, id: claim) }
        try check(); try reviewed.validate(identity)
        guard try journal().pending == nil else { throw SharedTimeError.review }
        let reference = enabled ? reviewed.candidate : reviewed.mapping?.reference
        guard let reference else { throw SharedTimeError.mapping }
        let fresh = try await refresh()
        guard fresh.realmID == reviewed.realmID, fresh.environment == reviewed.environment,
              fresh.connectionRevision == reviewed.connectionRevision, fresh.mapping == reviewed.mapping else { throw SharedTimeError.review }
        let request = SharedTimeWorkerRequest(reviewed, reference: reference, enabled: enabled)
        try persist(.init(identity: identity, actorEmail: access.actorEmail, pending: request))
        return try await finish(request)
    }
    func recover() async throws -> SharedTimeWorkerMapping {
        let claim = try SharedTimeMutationGate.begin(key); defer { SharedTimeMutationGate.finish(key, id: claim) }
        guard let request = try journal().pending else { throw SharedTimeError.review }
        let fresh = try await refresh()
        guard fresh.realmID == request.realmID, fresh.environment == request.environment,
              fresh.connectionRevision == request.connectionRevision else { throw SharedTimeError.review }
        return try await finish(request)
    }
    private func finish(_ request: SharedTimeWorkerRequest) async throws -> SharedTimeWorkerMapping {
        do {
            let response = try await access.operation.performExternalMutation { try await client.saveWorker(request) }
            try check()
            guard let mapping = response.mapping else { throw SharedTimeError.invalid }
            try persist(.init(identity: identity, actorEmail: access.actorEmail))
            return mapping
        } catch { try check(); throw SharedTimeError.safe(error) }
    }
    /// Explicitly keep a freshly checked server decision. This resolves only
    /// the local pending review; it never undoes a mapping accepted elsewhere.
    func keepCurrent(_ reviewed: SharedTimeWorkerContext) async throws {
        let claim = try SharedTimeMutationGate.begin(key); defer { SharedTimeMutationGate.finish(key, id: claim) }
        try check()
        let current = try await refresh()
        guard current == reviewed else { throw SharedTimeError.review }
        try persist(.init(identity: identity, actorEmail: access.actorEmail))
    }
}

struct SharedTimeWorkerReview: View {
    @Environment(\.modelContext) private var modelContext
    let workerEmail: String
    let workerName: String
    var suggestedKind = "Employee"
    var suggestedID = ""
    var technician: Technician?
    @State private var owner: SharedTimeWorkerOwner?
    @State private var review: SharedTimeWorkerContext?
    @State private var pending = false
    @State private var kind = "Employee"
    @State private var identifier = ""
    @State private var busy = false
    @State private var message: String?
    @State private var visit = UUID()
    @State private var visible = false
    @State private var confirmsDisable = false

    var body: some View {
        Form {
            Section { Text(workerName).font(.headline) } footer: {
                Text("Review this team member's identity in the business QuickBooks account. This does not create a worker, send time or run payroll.")
            }
            if let review {
                Section("Current worker") {
                    LabeledContent("Connection", value: review.environment == "production" ? "Business QuickBooks" : "QuickBooks sandbox")
                    if let mapping = review.mapping {
                        LabeledContent(mapping.kind, value: mapping.displayName)
                        Label(mapping.usable ? "Ready for approved time" : (mapping.enabled ? "Needs administrator review" : "Time mapping is off"),
                              systemImage: mapping.usable ? "checkmark.shield" : "exclamationmark.circle")
                            .accessibilityIdentifier("SharedTimeWorkerStatus")
                        if mapping.enabled {
                            Button("Turn Mapping Off", role: .destructive) { confirmsDisable = true }.disabled(busy || pending)
                        }
                    } else { Text("No worker has been linked yet.").foregroundStyle(.secondary) }
                }
            }
            if pending {
                Section("Saved review") {
                    Text("The previous save needs confirmation. Its original worker and operation were retained.")
                    Button("Recover Saved Change") { run { owner in _ = try await owner.recover(); return try await owner.refresh() } }
                        .disabled(busy).accessibilityIdentifier("SharedTimeWorkerRecover")
                    if let review {
                        Button("Keep Current Mapping") { run { owner in try await owner.keepCurrent(review); return try await owner.refresh() } }
                            .disabled(busy)
                    }
                }
            } else {
                Section {
                    Picker("Worker type", selection: $kind) { Text("Employee").tag("Employee"); Text("Vendor").tag("Vendor") }
                    TextField("Employee or vendor ID", text: $identifier)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("SharedTimeWorkerReference")
                    Button("Check Worker") { run { try await $0.refresh(kind: kind, providerID: identifier.trimmingCharacters(in: .whitespacesAndNewlines)) } }
                        .disabled(busy || !PaymentAttemptRecord.isReference(identifier.trimmingCharacters(in: .whitespacesAndNewlines)))
                        .accessibilityIdentifier("SharedTimeWorkerCheck")
                    if let reference = review?.candidate, reference.kind == kind, reference.providerID == identifier.trimmingCharacters(in: .whitespacesAndNewlines), let review {
                        Text(reference.displayName).font(.headline).accessibilityIdentifier("SharedTimeWorkerCandidate")
                        Button("Confirm This Worker") { run { owner in _ = try await owner.save(review, enabled: true); return try await owner.refresh() } }
                            .disabled(busy).accessibilityIdentifier("SharedTimeWorkerConfirm")
                    }
                } header: { Text("Choose QuickBooks worker") } footer: {
                    Text("Check the exact ID, then confirm the returned name. A legacy device reference is only a suggestion until this review is saved.")
                }
            }
            if let message { Section { Text(message).foregroundStyle(.secondary).accessibilityIdentifier("SharedTimeWorkerMessage") } }
            Section {
                Button { run { try await $0.refresh() } } label: {
                    if busy { ProgressView("Checking worker…") } else { Label("Refresh", systemImage: "arrow.clockwise") }
                }.disabled(busy)
            }
        }
        .navigationTitle("QuickBooks Worker")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("SharedTimeWorkerReview")
        .task {
            visible = true; kind = suggestedKind; identifier = suggestedID
            run { owner in
                let current = try await owner.refresh()
                if let mapping = current.mapping {
                    kind = mapping.kind; identifier = mapping.providerID
                }
                return current
            }
        }
        .onDisappear { visible = false; visit = UUID(); owner = nil; busy = false; review = nil; pending = false }
        .alert("Turn this time mapping off?", isPresented: $confirmsDisable) {
            Button("Cancel", role: .cancel) { }
            if let review {
                Button("Turn Off", role: .destructive) { run { owner in _ = try await owner.save(review, enabled: false); return try await owner.refresh() } }
            }
        } message: { Text("New time publications will require another administrator review. Existing time records in QuickBooks will not change.") }
    }

    private func run(_ action: @escaping (SharedTimeWorkerOwner) async throws -> SharedTimeWorkerContext) {
        guard !busy else { return }
        busy = true; message = nil
        let original = visit
        Task { @MainActor in
            defer { if visit == original { busy = false } }
            do {
                let current: SharedTimeWorkerOwner
                if let owner { current = owner }
                else {
                    let email = AppAccess.normalizedEmail(workerEmail)
                    let fixture = try SharedTimeUIFixture.services(context: modelContext, workerEmail: email, administrator: true,
                        isCurrent: { visible && visit == original })
                    let access = try fixture?.access ?? SharedTimeAccess(context: modelContext, administrator: true, isCurrent: { visible && visit == original })
                    current = try SharedTimeWorkerOwner(identity: .init(companyID: access.companyID, workerEmail: email), access: access,
                        client: fixture?.client, store: fixture?.store,
                        validateMember: {
                            if let technician {
                                let matches = try modelContext.fetch(FetchDescriptor<Technician>()).filter { $0.id == technician.id }
                                guard !technician.isDeleted, matches.count == 1, matches.first === technician,
                                      AppAccess.normalizedEmail(technician.contactInfo) == email,
                                      technician.name == workerName else { throw SharedTimeError.changed }
                            }
                        })
                    owner = current
                }
                pending = try current.journal().pending != nil
                let value = try await action(current)
                guard visible, visit == original else { return }
                review = value; pending = try current.journal().pending != nil
            } catch {
                if visible, visit == original {
                    pending = (try? owner?.journal().pending) != nil
                    message = SharedTimeError.safe(error).localizedDescription
                }
            }
        }
    }
}
