import Foundation
import SwiftData

enum GoogleCalendarWorkflowError: LocalizedError, Equatable {
    case busy, accessDenied, changed, identity, readOnly, saveFailed, needsReview, invalidDates, hasJobHistory, remoteChanged, unconfirmedWrite

    var errorDescription: String? {
        switch self {
        case .busy: "A calendar operation is already running for this workspace. Wait for it to finish."
        case .accessDenied: "Current dispatcher or administrator access is required to sync company appointments."
        case .changed: "The appointment or related records changed during sync. Saved work was retained; review the latest schedule before retrying."
        case .identity: "Calendar identity is missing or ambiguous. Review the original calendar and appointment; no guessed link was saved."
        case .readOnly: "The selected calendar is unavailable or read-only. Choose a writable calendar before publishing."
        case .saveFailed: "The calendar result could not be saved. Review the original event before retrying; your local appointment was retained."
        case .needsReview: "The original Google event needs review before it can be changed. Its identity, ownership, or version could not be confirmed."
        case .invalidDates: "The appointment needs a valid start time and positive duration before calendar publication."
        case .hasJobHistory: "This job has work or billing history. Open job details and use Cancel Job to preserve its records."
        case .remoteChanged: "This event changed in Google Calendar. Your local appointment was retained. Review the latest event before trying again."
        case .unconfirmedWrite: "Google may have received the request. The original event link and appointment were retained; review the original calendar before retrying."
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
    private let save: (ModelContext) throws -> Void
    private var validateRecords: () throws -> Void
    private var additionalValidation: (() throws -> Void)?
    private let containerKey: ObjectIdentifier
    /// Jobs whose records must stay unchanged across awaits; nil guards the
    /// whole store. A single-job send must not fail because an unrelated job,
    /// customer or technician merged in from CloudKit while Google replied.
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
        self.validateAccess = validateAccess ?? {
            try Self.requireDispatchAccess(context: context, email: signedInEmail)
        }
        try self.validateAccess()
        provider = try auth.captureProviderOperation()
        scopeIDs = scope.map { Set($0.map(\.id)) }
        validateRecords = try Self.recordValidation(context: context, scope: scopeIDs)
    }

    /// Re-baselines the guard on the given jobs (nil: the whole store) at their
    /// current values. Only call this where no await separates the new
    /// baseline from the reads it protects.
    func focus(on calls: [ServiceCall]?) throws {
        try provider.check()
        try validateAccess()
        scopeIDs = calls.map { Set($0.map(\.id)) }
        validateRecords = try Self.recordValidation(context: context, scope: scopeIDs)
    }

    func run(_ action: (GoogleCalendarWorkflow) async throws -> String) async -> Result<String, Error> {
        guard Self.activeContainers.insert(containerKey).inserted else {
            return .failure(GoogleCalendarWorkflowError.busy)
        }
        defer { Self.activeContainers.remove(containerKey) }
        do {
            try check()
            let message = try await action(self)
            try check()
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
        try validateRecords()
        try additionalValidation?()
    }

    func setAdditionalValidation(_ validation: (() throws -> Void)?) { additionalValidation = validation }

    func receive<Value>(_ request: (@escaping (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        try check()
        let value: Value = try await withCheckedThrowingContinuation { continuation in
            request { continuation.resume(with: $0) }
        }
        try check()
        return value
    }

    /// Only the synchronous, validated import/link mutation may advance the
    /// baseline. A save error is propagated; callers restore their own fields.
    func saveChanges() throws {
        try provider.check()
        try validateAccess()
        let nextValidation = try Self.recordValidation(context: context, scope: scopeIDs)
        do { try save(context) }
        catch { throw GoogleCalendarWorkflowError.saveFailed }
        validateRecords = nextValidation
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

    static func allowsDispatch(email: String?, currentEmail: String?, users: [AppUser], verifiedRole: AppUserRole?) -> Bool {
        let email = AppAccess.normalizedEmail(email)
        let matches = users.filter { AppAccess.normalizedEmail($0.email) == email }
        return !email.isEmpty && email == AppAccess.normalizedEmail(currentEmail) && !matches.isEmpty &&
            (verifiedRole == .admin || verifiedRole == .dispatcher) &&
            matches.allSatisfy { $0.isActive && $0.role == verifiedRole }
    }

    private static func recordValidation(context: ModelContext, scope: Set<UUID>?) throws -> () throws -> Void {
        if let scope {
            let baseline = try ScopedRevision(context: context, scope: scope)
            return {
                guard try ScopedRevision(context: context, scope: scope) == baseline else {
                    throw GoogleCalendarWorkflowError.changed
                }
            }
        }
        let calls = try context.fetch(FetchDescriptor<ServiceCall>())
        let customers = try context.fetch(FetchDescriptor<Customer>())
        let technicians = try context.fetch(FetchDescriptor<Technician>())
        let callValues = Dictionary(uniqueKeysWithValues: calls.map { (ObjectIdentifier($0), CallRevision($0)) })
        let customerValues = Dictionary(uniqueKeysWithValues: customers.map { (ObjectIdentifier($0), CustomerRevision($0)) })
        let technicianValues = Dictionary(uniqueKeysWithValues: technicians.map {
            (ObjectIdentifier($0), [$0.id.uuidString, $0.name, $0.contactInfo ?? ""])
        })
        return {
            let currentCalls = try context.fetch(FetchDescriptor<ServiceCall>())
            let currentCustomers = try context.fetch(FetchDescriptor<Customer>())
            let currentTechnicians = try context.fetch(FetchDescriptor<Technician>())
            // Membership is checked before reading retained/deleted model fields.
            guard currentCalls.count == callValues.count,
                  currentCustomers.count == customerValues.count,
                  currentTechnicians.count == technicianValues.count,
                  currentCalls.allSatisfy({ callValues[ObjectIdentifier($0)] == CallRevision($0) }),
                  currentCustomers.allSatisfy({ customerValues[ObjectIdentifier($0)] == CustomerRevision($0) }),
                  currentTechnicians.allSatisfy({
                      technicianValues[ObjectIdentifier($0)] == [$0.id.uuidString, $0.name, $0.contactInfo ?? ""]
                  }) else { throw GoogleCalendarWorkflowError.changed }
        }
    }

    /// The scoped jobs plus the customer and staff records their Google event
    /// is built from. Membership and identity are compared, so a deleted or
    /// replaced record is a change just like an edited one.
    private struct ScopedRevision: Equatable {
        let calls: [ObjectIdentifier: CallRevision]
        let customers: [ObjectIdentifier: CustomerRevision]
        let technicians: [ObjectIdentifier: [String]]

        init(context: ModelContext, scope: Set<UUID>) throws {
            let scoped = try context.fetch(FetchDescriptor<ServiceCall>()).filter { scope.contains($0.id) }
            calls = Dictionary(uniqueKeysWithValues: scoped.map { (ObjectIdentifier($0), CallRevision($0)) })
            let customerKeys = Set(scoped.compactMap { $0.customer.map(ObjectIdentifier.init) })
            customers = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<Customer>())
                .filter { customerKeys.contains(ObjectIdentifier($0)) }
                .map { (ObjectIdentifier($0), CustomerRevision($0)) })
            let staffIDs = scoped.reduce(into: Set<UUID>()) { ids, call in
                ids.formUnion(call.additionalTechnicianIDs)
                if let assigned = call.assignedTechnician { ids.insert(assigned.id) }
            }
            technicians = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<Technician>())
                .filter { staffIDs.contains($0.id) }
                .map { (ObjectIdentifier($0), [$0.id.uuidString, $0.name, $0.contactInfo ?? ""]) })
        }
    }

    private struct CustomerRevision: Equatable {
        let id: UUID
        let name: String
        let email: String?
        let address: String?
        init(_ value: Customer) { id = value.id; name = value.name; email = value.email; address = value.address }
    }

    private struct CallRevision: Equatable {
        let id: UUID
        let strings: [String?]
        let dates: [Date?]
        let duration: Double
        let managed: Bool
        let customer: ObjectIdentifier?
        let technician: ObjectIdentifier?
        init(_ value: ServiceCall) {
            id = value.id
            strings = [value.googleCalendarID, value.googleEventID, value.eventTitle, value.siteAddress,
                       value.type.rawValue, value.status.rawValue, value.notes, value.additionalTechnicianIDsJSON,
                       value.serviceLocationID?.uuidString, value.cancellationReason]
            dates = [value.scheduledDate, value.promisedArrivalWindowStart, value.promisedArrivalWindowEnd, value.cancelledAt]
            duration = value.duration
            managed = value.googleEventManagedByApp
            customer = value.customer.map(ObjectIdentifier.init)
            technician = value.assignedTechnician.map(ObjectIdentifier.init)
        }
    }
}
