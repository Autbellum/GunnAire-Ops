import Foundation
import SwiftData

nonisolated enum GoogleCalendarWorkflowError: LocalizedError, Equatable {
    case busy, accessDenied, changed, identity, readOnly, saveFailed, needsReview, invalidDates, hasJobHistory, remoteChanged, unconfirmedWrite, unconfirmedReadback
    case alertReview(String)

    var errorDescription: String? {
        switch self {
        case .busy: "A calendar operation is already running for this workspace. Wait for it to finish."
        case .accessDenied: "Current dispatcher or administrator access is required to sync company appointments."
        case .changed: "The appointment or related records changed during sync. Saved work was retained; review the latest schedule before retrying."
        case .identity: "Calendar identity is missing or ambiguous. Review the original calendar and appointment; no guessed link was saved."
        case .readOnly: "The selected calendar is unavailable or read-only. Choose a writable calendar before publishing."
        case .saveFailed: "The calendar result could not be saved. Review the original event before retrying; your local appointment was retained."
        case .needsReview: "The original Google event needs review before it can be changed. Its identity, ownership, or version could not be confirmed."
        case .alertReview(let detail): detail
        case .invalidDates: "The appointment needs a valid start time and positive duration before calendar publication."
        case .hasJobHistory: "This job has work or billing history. Open job details and use Cancel Job to preserve its records."
        case .remoteChanged: "This event changed in Google Calendar. Your local appointment was retained. Review the latest event before trying again."
        case .unconfirmedWrite: "Google may have received the request. The original event link and appointment were retained; review the original calendar before retrying."
        case .unconfirmedReadback: "Google accepted the event request, but the original event could not be read back from its calendar. The saved event ID was retained; check the original event before retrying."
        }
    }
}

/// One original company/provider operation covers all calendar reads, writes,
/// callback resumptions and local saves. No fixture constructor loads secrets.
@MainActor
final class GoogleCalendarWorkflow {
    private static var activeContainers: Set<ObjectIdentifier> = []
    let auth: GoogleAuthManager
    let context: ModelContext
    let signedInEmail: String?
    private let provider: WorkspaceProviderOperation
    private let validateAccess: () throws -> Void
    private let validatesDispatchMirrorOffMain: Bool
    private let save: (ModelContext) throws -> Void
    private var trackedCall: ServiceCall?
    private var trackedRevision: TrackedRevision?
    private var persistedRevision: TrackedRevision?
    private var trackedAdditionalTechnicians: [Technician] = []
    private var knownStaffBaseline: Set<String>?
    private var importRevision: ImportRevision?
    private var additionalValidation: (() throws -> Void)?
    private let containerKey: ObjectIdentifier
    private var scopeIDs: Set<UUID>?

    lazy var operation = WorkspaceProviderOperation(parent: provider) { [weak self] in
        guard let self else { return false }
        return (try? self.validateCurrent()) != nil
    }

    init(auth: GoogleAuthManager, context: ModelContext, signedInEmail: String?,
         scope: [ServiceCall]? = nil,
         validateAccess: (() throws -> Void)? = nil,
         save: @escaping (ModelContext) throws -> Void = { try $0.save() }) throws {
        self.auth = auth
        self.context = context
        self.signedInEmail = signedInEmail
        self.save = save
        containerKey = ObjectIdentifier(context.container)
        validatesDispatchMirrorOffMain = validateAccess == nil
        self.validateAccess = validateAccess ?? {
            try Self.requireDispatchSessionAccess(context: context, email: signedInEmail)
        }
        try self.validateAccess()
        provider = try auth.captureProviderOperation()
        scopeIDs = scope.map { Set($0.map(\.id)) }
    }

    /// Re-baseline each job when its turn arrives in a batch. The individual
    /// appointment and recipient fence is established by track(_:) before its
    /// first provider request; unrelated CloudKit merges cannot stale it.
    func focus(on calls: [ServiceCall]?) throws {
        try provider.check()
        try validateAccess()
        guard !context.hasChanges else { throw GoogleCalendarWorkflowError.changed }
        scopeIDs = calls.map { Set($0.map(\.id)) }
        trackedCall = nil
        trackedRevision = nil
        persistedRevision = nil
        trackedAdditionalTechnicians = []
        knownStaffBaseline = nil
    }

    func run(_ action: (GoogleCalendarWorkflow) async throws -> String) async -> Result<String, Error> {
        guard Self.activeContainers.insert(containerKey).inserted else {
            return .failure(GoogleCalendarWorkflowError.busy)
        }
        defer { Self.activeContainers.remove(containerKey) }
        do {
            try await checkOffMain()
            let message = try await action(self)
            try await checkOffMain()
            return .success(message)
        } catch {
            if case GoogleAuthError.http(statusCode: 412) = error { return .failure(GoogleCalendarWorkflowError.remoteChanged) }
            if operation.mayHaveReachedProvider, error is URLError { return .failure(GoogleCalendarWorkflowError.unconfirmedWrite) }
            return .failure(error)
        }
    }

    func check() throws {
        try provider.check()
        try validateCurrent()
        try Task.checkCancellation()
    }

    private func validateCurrent() throws {
        try validateAccess()
        if let trackedCall, let trackedRevision {
            guard !context.deletedModelsArray.contains(where: { $0.persistentModelID == trackedRevision.persistentID }),
                  trackedAdditionalTechnicians.allSatisfy({ technician in
                      !context.deletedModelsArray.contains { $0.persistentModelID == technician.persistentModelID }
                  }),
                  Self.revision(of: trackedCall, additional: trackedAdditionalTechnicians) == trackedRevision else {
                throw GoogleCalendarWorkflowError.changed
            }
        }
        try additionalValidation?()
    }

    /// Capture only the appointment that this operation may publish. The
    /// provider callback still performs the cheap in-memory check; every
    /// asynchronous boundary also compares a fresh private-context read.
    func track(_ call: ServiceCall) throws {
        try provider.check()
        try validateAccess()
        if let scopeIDs, !scopeIDs.contains(call.id) { throw GoogleCalendarWorkflowError.changed }
        if let trackedCall, trackedCall === call {
            try check()
        } else {
            let additional = try Self.fetchAdditionalTechnicians(for: call, in: context)
            trackedCall = call
            trackedAdditionalTechnicians = additional
            trackedRevision = Self.revision(of: call, additional: additional)
            persistedRevision = nil
            knownStaffBaseline = nil
        }
    }

    private func checkOffMain() async throws {
        try check()
        if importRevision != nil, context.hasChanges { throw GoogleCalendarWorkflowError.changed }
        let expected = trackedRevision
        let expectedImport = importRevision
        let email = signedInEmail
        let readMirror = validatesDispatchMirrorOffMain
        let readStaff = expected != nil
        let unsavedTargetBeforeRead = hasUnsavedTrackedDependency
        let testDatabase = GunnAireCloudKit.usesTestDatabase
        let current = try await Task.detached(priority: .userInitiated) { [container = context.container] in
            let revision = try expected.map { try Self.readRevision(container: container, callID: $0.call.id) }
            let mirror = readMirror ? try Self.readDispatchMirror(container: container, email: email) : nil
            let knownStaff = readStaff ? try Self.readKnownStaff(container: container) : nil
            let importState = expectedImport != nil ? try Self.readImportRevision(container: container) : nil
            // The three reads use private contexts. A save landing while they
            // run must not combine an old job with new recipient authority.
            if let expected {
                let stable = try Self.readRevision(container: container, callID: expected.call.id)
                guard stable == revision else { throw GoogleCalendarWorkflowError.changed }
                let stableStaff = try Self.readKnownStaff(container: container)
                guard stableStaff == knownStaff else { throw GoogleCalendarWorkflowError.changed }
            }
            if readMirror {
                let stableMirror = try Self.readDispatchMirror(container: container, email: email)
                guard stableMirror == mirror else { throw GoogleCalendarWorkflowError.accessDenied }
            }
            if expectedImport != nil {
                let stableImport = try Self.readImportRevision(container: container)
                guard stableImport == importState else { throw GoogleCalendarWorkflowError.changed }
            }
            return (revision, mirror, knownStaff, importState)
        }.value
        try check()
        if expectedImport != nil, context.hasChanges { throw GoogleCalendarWorkflowError.changed }
        if let mirror = current.1 {
            let role = testDatabase ? mirror.firstRole : CompanyWorkspaceAccessController.shared.verifiedRole
            guard mirror.count > 0, mirror.allActiveAndRole == role,
                  role == .admin || role == .dispatcher else {
                throw GoogleCalendarWorkflowError.accessDenied
            }
        }
        guard unsavedTargetBeforeRead == hasUnsavedTrackedDependency else {
            throw GoogleCalendarWorkflowError.changed
        }
        if let persistedRevision {
            guard current.0 == persistedRevision else { throw GoogleCalendarWorkflowError.changed }
        } else {
            guard current.0 == expected || unsavedTargetBeforeRead else {
                throw GoogleCalendarWorkflowError.changed
            }
            persistedRevision = current.0
        }
        if let knownStaffBaseline {
            guard current.2 == knownStaffBaseline else { throw GoogleCalendarWorkflowError.changed }
        } else {
            knownStaffBaseline = current.2
        }
        guard current.3 == expectedImport else { throw GoogleCalendarWorkflowError.changed }
    }

    func beginImportFence() async throws {
        try check()
        guard !context.hasChanges else { throw GoogleCalendarWorkflowError.changed }
        let first = try await Task.detached(priority: .userInitiated) { [container = context.container] in
            try Self.readImportRevision(container: container)
        }.value
        try check()
        guard !context.hasChanges else { throw GoogleCalendarWorkflowError.changed }
        let second = try await Task.detached(priority: .userInitiated) { [container = context.container] in
            try Self.readImportRevision(container: container)
        }.value
        try check()
        guard !context.hasChanges, first == second else { throw GoogleCalendarWorkflowError.changed }
        importRevision = second
    }

    var knownStaffForDelivery: Set<String> {
        knownStaffBaseline ?? []
    }

    private var hasUnsavedTrackedDependency: Bool {
        guard let trackedRevision else { return false }
        let identifiers = Set([trackedRevision.persistentID] +
            [trackedRevision.customer?.1, trackedRevision.technician?.1].compactMap { $0 } +
            trackedRevision.additional.map { $0.1 })
        return (context.changedModelsArray + context.insertedModelsArray + context.deletedModelsArray)
            .contains { identifiers.contains($0.persistentModelID) }
    }

    func setAdditionalValidation(_ validation: (() throws -> Void)?) { additionalValidation = validation }

    func receive<Value>(_ request: (@escaping (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        try await checkOffMain()
        let value: Value = try await withCheckedThrowingContinuation { continuation in
            request { continuation.resume(with: $0) }
        }
        try await checkOffMain()
        return value
    }

    /// Only the synchronous, validated import/link mutation may advance the
    /// baseline. A save error is propagated; callers restore their own fields.
    func saveChanges() throws {
        try provider.check()
        try validateAccess()
        try additionalValidation?()
        let removedTrackedCall = trackedCall.map { call in
            context.deletedModelsArray.contains { $0.persistentModelID == call.persistentModelID }
        } ?? false
        let nextAdditional = try trackedCall.flatMap { call in
            removedTrackedCall ? nil : try Self.fetchAdditionalTechnicians(for: call, in: context)
        } ?? []
        let nextRevision = trackedCall.flatMap { call in
            removedTrackedCall ? nil : Self.revision(of: call, additional: nextAdditional)
        }
        let wroteTechnician = (context.changedModelsArray + context.insertedModelsArray + context.deletedModelsArray)
            .contains { $0 is Technician }
        do { try save(context) }
        catch { throw GoogleCalendarWorkflowError.saveFailed }
        importRevision = nil
        if wroteTechnician { knownStaffBaseline = nil }
        if removedTrackedCall {
            trackedCall = nil
            trackedRevision = nil
            persistedRevision = nil
            trackedAdditionalTechnicians = []
            knownStaffBaseline = nil
        } else {
            trackedRevision = nextRevision
            persistedRevision = nil
            trackedAdditionalTechnicians = nextAdditional
        }
    }

    static func requireDispatchAccess(context: ModelContext, email: String?) throws {
        let email = AppAccess.normalizedEmail(email)
        let current = AppAccess.normalizedEmail(AppIdentity.currentEmail)
        let users = try context.fetch(FetchDescriptor<AppUser>()).filter {
            AppAccess.normalizedEmail($0.email) == email
        }
        let controller = CompanyWorkspaceAccessController.shared
        let role = GunnAireCloudKit.usesTestDatabase ? users.first?.role : controller.verifiedRole
        guard allowsDispatch(email: email, currentEmail: current, users: users, verifiedRole: role),
              GunnAireCloudKit.usesTestDatabase || controller.authorizedContainer === context.container else {
            throw GoogleCalendarWorkflowError.accessDenied
        }
    }

    private static func requireDispatchSessionAccess(context: ModelContext, email: String?) throws {
        let selected = AppAccess.normalizedEmail(email)
        let current = AppAccess.normalizedEmail(AppIdentity.currentEmail)
        let controller = CompanyWorkspaceAccessController.shared
        let pendingUserChange = (context.changedModelsArray + context.insertedModelsArray + context.deletedModelsArray)
            .contains { $0 is AppUser }
        guard !selected.isEmpty, selected == current,
              !pendingUserChange,
              GunnAireCloudKit.usesTestDatabase || controller.authorizedContainer === context.container,
              GunnAireCloudKit.usesTestDatabase || controller.verifiedRole == .admin || controller.verifiedRole == .dispatcher else {
            throw GoogleCalendarWorkflowError.accessDenied
        }
    }

    nonisolated private struct DispatchMirror: Equatable, Sendable {
        let count: Int
        let firstRole: AppUserRole?
        let allActiveAndRole: AppUserRole?
    }

    nonisolated private static func readDispatchMirror(container: ModelContainer, email: String?) throws -> DispatchMirror {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let selected = AppAccess.normalizedEmail(email)
        let matches = try context.fetch(FetchDescriptor<AppUser>()).filter {
            AppAccess.normalizedEmail($0.email) == selected
        }
        let role = matches.first.map { AppUserRole(rawValue: $0.roleRawValue) ?? .standard }
        let allMatch = role != nil && matches.allSatisfy {
            $0.isActive && (AppUserRole(rawValue: $0.roleRawValue) ?? .standard) == role
        }
        return DispatchMirror(count: matches.count, firstRole: role, allActiveAndRole: allMatch ? role : nil)
    }

    static func allowsDispatch(email: String?, currentEmail: String?, users: [AppUser], verifiedRole: AppUserRole?) -> Bool {
        let email = AppAccess.normalizedEmail(email)
        let matches = users.filter { AppAccess.normalizedEmail($0.email) == email }
        return !email.isEmpty && email == AppAccess.normalizedEmail(currentEmail) && !matches.isEmpty &&
            (verifiedRole == .admin || verifiedRole == .dispatcher) &&
            matches.allSatisfy { $0.isActive && $0.role == verifiedRole }
    }

    nonisolated private static func revision(of call: ServiceCall, additional: [Technician]) -> TrackedRevision {
        TrackedRevision(persistentID: call.persistentModelID, call: CallRevision(call),
                        customer: call.customer.map { (CustomerRevision($0), $0.persistentModelID) },
                        technician: call.assignedTechnician.map { (TechnicianRevision($0), $0.persistentModelID) },
                        additional: additional.map { (TechnicianRevision($0), $0.persistentModelID) })
    }

    nonisolated private static func fetchAdditionalTechnicians(for call: ServiceCall, in context: ModelContext) throws -> [Technician] {
        let rawIDs = call.additionalTechnicianIDsJSON?.data(using: .utf8)
        let values = rawIDs.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        let ids = Set(values.compactMap(UUID.init(uuidString:))).sorted { $0.uuidString < $1.uuidString }
        guard ids.count <= 25 else { throw GoogleCalendarWorkflowError.needsReview }
        return try ids.map { id in
            var descriptor = FetchDescriptor<Technician>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 2
            let matches = try context.fetch(descriptor)
            guard matches.count == 1, let technician = matches.first else { throw GoogleCalendarWorkflowError.changed }
            return technician
        }
    }

    nonisolated private static func readRevision(container: ModelContainer, callID: UUID) throws -> TrackedRevision {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var descriptor = FetchDescriptor<ServiceCall>(predicate: #Predicate { $0.id == callID })
        descriptor.fetchLimit = 2
        let matches = try context.fetch(descriptor)
        guard matches.count == 1, let call = matches.first else { throw GoogleCalendarWorkflowError.changed }
        let snapshot = try revision(of: call, additional: fetchAdditionalTechnicians(for: call, in: context))
        if let customer = snapshot.customer {
            let customerID = customer.0.id
            var match = FetchDescriptor<Customer>(predicate: #Predicate { $0.id == customerID })
            match.fetchLimit = 2
            let values = try context.fetch(match)
            guard values.count == 1, values.first?.persistentModelID == customer.1 else {
                throw GoogleCalendarWorkflowError.changed
            }
        }
        if let technician = snapshot.technician {
            let technicianID = technician.0.id
            var match = FetchDescriptor<Technician>(predicate: #Predicate { $0.id == technicianID })
            match.fetchLimit = 2
            let values = try context.fetch(match)
            guard values.count == 1, values.first?.persistentModelID == technician.1 else {
                throw GoogleCalendarWorkflowError.changed
            }
        }
        return snapshot
    }

    nonisolated private static func readKnownStaff(container: ModelContainer) throws -> Set<String> {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return Set(try context.fetch(FetchDescriptor<Technician>()).compactMap {
            GoogleCalendarStaffDelivery.email($0.contactInfo)
        })
    }

    nonisolated private struct ImportRevision: Equatable, Sendable {
        let calls: [PersistentIdentifier: CallRevision]
        let customers: [PersistentIdentifier: CustomerRevision]
        let technicians: [PersistentIdentifier: TechnicianRevision]
    }

    nonisolated private static func readImportRevision(container: ModelContainer) throws -> ImportRevision {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let calls = try context.fetch(FetchDescriptor<ServiceCall>())
        let customers = try context.fetch(FetchDescriptor<Customer>())
        let technicians = try context.fetch(FetchDescriptor<Technician>())
        return ImportRevision(
            calls: Dictionary(uniqueKeysWithValues: calls.map { ($0.persistentModelID, CallRevision($0)) }),
            customers: Dictionary(uniqueKeysWithValues: customers.map { ($0.persistentModelID, CustomerRevision($0)) }),
            technicians: Dictionary(uniqueKeysWithValues: technicians.map { ($0.persistentModelID, TechnicianRevision($0)) })
        )
    }

    nonisolated private struct TrackedRevision: Equatable, Sendable {
        let persistentID: PersistentIdentifier
        let call: CallRevision
        let customer: (CustomerRevision, PersistentIdentifier)?
        let technician: (TechnicianRevision, PersistentIdentifier)?
        let additional: [(TechnicianRevision, PersistentIdentifier)]

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.persistentID == rhs.persistentID && lhs.call == rhs.call &&
                lhs.customer?.0 == rhs.customer?.0 && lhs.customer?.1 == rhs.customer?.1 &&
                lhs.technician?.0 == rhs.technician?.0 && lhs.technician?.1 == rhs.technician?.1 &&
                lhs.additional.count == rhs.additional.count && zip(lhs.additional, rhs.additional).allSatisfy {
                    $0.0.0 == $0.1.0 && $0.0.1 == $0.1.1
                }
        }
    }

    nonisolated private struct CustomerRevision: Equatable, Sendable {
        let id: UUID
        let name: String
        let email: String?
        let address: String?
        init(_ value: Customer) { id = value.id; name = value.name; email = value.email; address = value.address }
    }

    nonisolated private struct TechnicianRevision: Equatable, Sendable {
        let id: UUID
        let name: String
        let contactInfo: String?
        init(_ value: Technician) { id = value.id; name = value.name; contactInfo = value.contactInfo }
    }

    nonisolated private struct CallRevision: Equatable, Sendable {
        let id: UUID
        let strings: [String?]
        let dates: [Date?]
        let duration: Double
        let managed: Bool
        let customer: PersistentIdentifier?
        let technician: PersistentIdentifier?
        init(_ value: ServiceCall) {
            id = value.id
            strings = [value.googleCalendarID, value.googleEventID, value.eventTitle, value.siteAddress,
                       value.type.rawValue, value.status.rawValue, value.notes, value.additionalTechnicianIDsJSON,
                       value.serviceLocationID?.uuidString, value.cancellationReason]
            dates = [value.scheduledDate, value.promisedArrivalWindowStart, value.promisedArrivalWindowEnd,
                     value.cancelledAt, value.googleEventConfirmedAt, value.googleCalendarPendingAt]
            duration = value.duration
            managed = value.googleEventManagedByApp
            customer = value.customer?.persistentModelID
            technician = value.assignedTechnician?.persistentModelID
        }
    }
}
