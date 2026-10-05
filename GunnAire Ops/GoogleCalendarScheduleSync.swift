import Foundation
import SwiftData

@MainActor
enum GoogleCalendarScheduleSync {
    struct ImportSummary {
        let importedCount: Int
        let restrictedReviewCount: Int
    }

    struct SyncOutcome {
        let message: String
        /// Exact original IDs proved absent from every accessible calendar in
        /// this connected account during this Sync Google operation.
        let verifiedNotFoundIDs: [UUID: String]
    }

    struct AutomaticVerificationPage {
        let calls: [ServiceCall]
        let nextOffset: Int
    }

    struct BackgroundCandidatePage {
        let calls: [ServiceCall]
        let nextOffset: Int
    }

    private final class VerifiedLinkEvidence {
        var notFoundIDs: [UUID: String] = [:]
    }

    private struct QueuedWorkflow {
        let workflow: GoogleCalendarWorkflow
        let action: (GoogleCalendarWorkflow) async throws -> String
        let completion: (Result<String, Error>) -> Void
    }

    private static var queuedWorkflows: [ObjectIdentifier: [QueuedWorkflow]] = [:]
    private static var drainingWorkflowContainers: Set<ObjectIdentifier> = []

    /// An in-memory, single-job review retains the original provider and
    /// workspace operation across the operator's confirmation. It is never
    /// persisted or reused after a different account or job revision appears.
    struct MissingEventReview {
        let call: ServiceCall
        let callID: UUID
        let calendarID: String
        let eventID: String
        let accountEmail: String
        let scheduledDate: Date
        let duration: Double
        let workflow: GoogleCalendarWorkflow
    }

    /// A provider-supplied web link is usable only for the exact event just
    /// checked under the same connected account, workspace and local revision.
    /// It is kept in view state, never persisted as publication evidence.
    struct VerifiedGoogleEventLink {
        let url: URL
        private let revision: LinkRevision
        private let connectedEmail: String
        private let workspaceStamp: CompanyWorkspaceOperationStamp

        init?(remote: GoogleCalendarEvent, call: ServiceCall, connectedEmail: String?,
              workspaceStamp: CompanyWorkspaceOperationStamp?) {
            guard let raw = remote.htmlLink,
                  let url = Self.safeProviderURL(raw),
                  let connectedEmail = GoogleCalendarStaffDelivery.email(connectedEmail),
                  let workspaceStamp else { return nil }
            self.url = url
            revision = LinkRevision(call)
            self.connectedEmail = connectedEmail
            self.workspaceStamp = workspaceStamp
        }

        func matches(call: ServiceCall, connectedEmail: String?,
                     workspaceStamp: CompanyWorkspaceOperationStamp?) -> Bool {
            guard let workspaceStamp else { return false }
            return revision == LinkRevision(call) &&
                self.connectedEmail == GoogleCalendarStaffDelivery.email(connectedEmail) &&
                self.workspaceStamp == workspaceStamp
        }

        static func safeProviderURL(_ raw: String) -> URL? {
            guard let components = URLComponents(string: raw),
                  components.scheme?.lowercased() == "https",
                  let host = components.host?.lowercased(),
                  ["www.google.com", "calendar.google.com"].contains(host),
                  components.user == nil, components.password == nil,
                  components.port == nil,
                  components.path.hasPrefix("/calendar/"),
                  let url = components.url else { return nil }
            return url
        }
    }

    struct GoogleLinkCheck {
        let missingEventReview: MissingEventReview?
        let verifiedLink: VerifiedGoogleEventLink?
        let alertGuidance: String?
    }

    fileprivate struct LinkRevision: Equatable {
        let id: UUID
        let calendarID: String?
        let eventID: String?
        let managedByApp: Bool
        let confirmedAt: Date?
        let pendingAt: Date?
        let scheduledDate: Date
        let duration: TimeInterval
        let title: String?
        let siteAddress: String?
        let notes: String?
        let type: ServiceCallType
        let status: JobStatus
        let technicianID: UUID?
        let technicianEmail: String?
        let additionalTechnicianIDsJSON: String?
        let customerID: UUID?
        let customerName: String?
        let customerAddress: String?

        init(_ call: ServiceCall) {
            id = call.id
            calendarID = call.googleCalendarID
            eventID = call.googleEventID
            managedByApp = call.googleEventManagedByApp
            confirmedAt = call.googleEventConfirmedAt
            pendingAt = call.googleCalendarPendingAt
            scheduledDate = call.scheduledDate
            duration = call.duration
            title = call.eventTitle
            siteAddress = call.siteAddress
            notes = call.notes
            type = call.type
            status = call.status
            technicianID = call.assignedTechnician?.id
            technicianEmail = call.assignedTechnician?.contactInfo
            additionalTechnicianIDsJSON = call.additionalTechnicianIDsJSON
            customerID = call.customer?.id
            customerName = call.customer?.name
            customerAddress = call.customer?.address
        }
    }

    private static let deletedCalendarEventKeysStorageKey = "GunnAireDeletedGoogleCalendarEventKeys"
    private static let locallyEditedCalendarCallIDsStorageKey = "GunnAireLocallyEditedGoogleCalendarCallIDs"
    private static let staffInvitationReviewStorageKey = "GunnAireGoogleCalendarStaffInvitationReview"
    private static let writeBackCalendarCallIDsStorageKey = "GunnAireGoogleCalendarWriteBackCallIDs"
    // The existing CloudKit-synced outbox date carries the unresolved repair
    // proof across app relaunches and devices without a Production schema change.
    private static let replacementPopupProofPendingAt = Date(timeIntervalSince1970: 946_684_800)
    private static var retryTask: Task<Void, Never>?
    private static let retryDelays: [Duration] = [.seconds(30), .seconds(120), .seconds(600)]

    static func shouldQuarantineImportedCalendarEvent(
        existingCallFound: Bool,
        hasSchedulingBlocker: Bool
    ) -> Bool {
        !existingCallFound && hasSchedulingBlocker
    }

    static func operationalCustomerForCalendarImport(
        existingCall: ServiceCall?,
        matchedCustomer: Customer?
    ) -> Customer? {
        existingCall?.customer ?? matchedCustomer
    }

    static func markCalendarEventDeleted(calendarID: String?, eventID: String?) {
        guard let eventID, !eventID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var deletedKeys = Set(UserDefaults.standard.stringArray(forKey: deletedCalendarEventKeysStorageKey) ?? [])
        deletedKeys.insert(calendarEventStorageKey(calendarID: calendarID, eventID: eventID))
        UserDefaults.standard.set(Array(deletedKeys), forKey: deletedCalendarEventKeysStorageKey)
    }

    static func isCalendarEventDeleted(calendarID: String?, eventID: String?) -> Bool {
        guard let eventID, !eventID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let deletedKeys = Set(UserDefaults.standard.stringArray(forKey: deletedCalendarEventKeysStorageKey) ?? [])
        return deletedKeys.contains(calendarEventStorageKey(calendarID: calendarID, eventID: eventID))
    }

    static func markCalendarCallLocallyEdited(_ call: ServiceCall) {
        guard shouldPublishAfterLocalSave(for: call) else { return }
        if !call.googleEventManagedByApp {
            var writeBack = Set(UserDefaults.standard.stringArray(forKey: writeBackCalendarCallIDsStorageKey) ?? [])
            writeBack.insert(call.id.uuidString)
            UserDefaults.standard.set(Array(writeBack), forKey: writeBackCalendarCallIDsStorageKey)
        }
        // Confirmation describes the exact local appointment and staff delivery.
        // A later edit must remain pending even if device-local defaults vanish.
        call.googleEventConfirmedAt = nil
        call.googleCalendarPendingAt = pendingDateAfterLocalEdit(call)
        clearStaffInvitationReview(for: call)
        var callIDs = Set(UserDefaults.standard.stringArray(forKey: locallyEditedCalendarCallIDsStorageKey) ?? [])
        callIDs.insert(call.id.uuidString)
        UserDefaults.standard.set(Array(callIDs), forKey: locallyEditedCalendarCallIDsStorageKey)
    }

    static func pendingDateAfterLocalEdit(_ call: ServiceCall) -> Date {
        call.googleCalendarPendingAt == replacementPopupProofPendingAt
            ? replacementPopupProofPendingAt : Date()
    }

    private static func replacementPopupProofRequired(_ call: ServiceCall) -> Bool {
        call.googleCalendarPendingAt == replacementPopupProofPendingAt
    }

    /// An event was confirmed on its original Google route, but its staff
    /// invitations still need a corrected contact. A new local edit clears
    /// this proof so the Schedule card cannot describe an unsent change as saved.
    static func staffInvitationsNeedAttention(for call: ServiceCall, connectedGoogleEmail: String?,
                                              workspaceEmail: String?) -> Bool {
        guard let route = staffInvitationReviewRoute(for: call, connectedGoogleEmail: connectedGoogleEmail,
                                                      workspaceEmail: workspaceEmail) else { return false }
        let reviews = UserDefaults.standard.dictionary(forKey: staffInvitationReviewStorageKey) as? [String: String] ?? [:]
        return reviews[call.id.uuidString] == route
    }

    private static func staffInvitationReviewRoute(for call: ServiceCall, connectedGoogleEmail: String?,
                                                    workspaceEmail: String?) -> String? {
        guard let eventID = normalizedOptional(call.googleEventID) else { return nil }
        let googleEmail = AppAccess.normalizedEmail(connectedGoogleEmail)
        let businessEmail = AppAccess.normalizedEmail(workspaceEmail)
        guard !googleEmail.isEmpty, !businessEmail.isEmpty else { return nil }
        let values = [googleEmail, businessEmail, call.googleCalendarID ?? "primary", eventID]
        return values.map { "\($0.utf8.count):\($0)" }.joined()
    }

    private static func markStaffInvitationReview(for call: ServiceCall, workflow: GoogleCalendarWorkflow) {
        guard let route = staffInvitationReviewRoute(for: call,
            connectedGoogleEmail: workflow.auth.signedInEmail, workspaceEmail: workflow.signedInEmail) else { return }
        var reviews = UserDefaults.standard.dictionary(forKey: staffInvitationReviewStorageKey) as? [String: String] ?? [:]
        reviews[call.id.uuidString] = route
        UserDefaults.standard.set(reviews, forKey: staffInvitationReviewStorageKey)
    }

    private static func clearStaffInvitationReview(for call: ServiceCall) {
        var reviews = UserDefaults.standard.dictionary(forKey: staffInvitationReviewStorageKey) as? [String: String] ?? [:]
        guard reviews.removeValue(forKey: call.id.uuidString) != nil else { return }
        UserDefaults.standard.set(reviews, forKey: staffInvitationReviewStorageKey)
    }

    private static func isCalendarCallLocallyEdited(_ call: ServiceCall) -> Bool {
        let callIDs = Set(UserDefaults.standard.stringArray(forKey: locallyEditedCalendarCallIDsStorageKey) ?? [])
        return callIDs.contains(call.id.uuidString)
    }

    static func isWriteBackRequested(_ call: ServiceCall) -> Bool {
        guard canWriteBackImportedEvent(call) else { return false }
        let marked = Set(UserDefaults.standard.stringArray(forKey: writeBackCalendarCallIDsStorageKey) ?? [])
            .contains(call.id.uuidString)
        return marked || call.googleCalendarPendingAt != nil
    }

    private static func clearWriteBackRequest(_ call: ServiceCall) {
        var callIDs = Set(UserDefaults.standard.stringArray(forKey: writeBackCalendarCallIDsStorageKey) ?? [])
        guard callIDs.remove(call.id.uuidString) != nil else { return }
        UserDefaults.standard.set(Array(callIDs), forKey: writeBackCalendarCallIDsStorageKey)
    }

    static func canWriteBackImportedEvent(_ call: ServiceCall) -> Bool {
        !call.googleEventManagedByApp && isExternalGoogleCalendarEvent(call) &&
            (call.status == .scheduled || call.status == .inProgress)
    }

    private static func clearCalendarCallLocallyEdited(_ call: ServiceCall) {
        var callIDs = Set(UserDefaults.standard.stringArray(forKey: locallyEditedCalendarCallIDsStorageKey) ?? [])
        guard callIDs.remove(call.id.uuidString) != nil else { return }
        UserDefaults.standard.set(Array(callIDs), forKey: locallyEditedCalendarCallIDsStorageKey)
    }

    private static func calendarEventStorageKey(calendarID: String?, eventID: String) -> String {
        "\((calendarID ?? "primary").trimmingCharacters(in: .whitespacesAndNewlines))|\(eventID)"
    }

    static func calendarRouteLabel(for call: ServiceCall, connectedEmail: String?) -> String {
        let route = call.googleCalendarID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let connected = AppAccess.normalizedEmail(connectedEmail)
        if route.isEmpty || route.caseInsensitiveCompare("primary") == .orderedSame ||
            (!connected.isEmpty && AppAccess.normalizedEmail(route) == connected) {
            return "Google calendar: Primary\(connected.isEmpty ? "" : " (\(connected))")"
        }
        if let technician = call.assignedTechnician,
           AppAccess.normalizedEmail(technician.contactInfo) == AppAccess.normalizedEmail(route) {
            return "Google calendar: \(technician.name) (\(route))"
        }
        return "Google calendar: \(route)"
    }

    static func sync(
        auth: GoogleAuthManager, modelContext: ModelContext, signedInEmail: String?, isAdminUser: Bool,
        verifyConfirmedCalls: [ServiceCall] = [],
        completion: @escaping (Result<SyncOutcome, Error>) -> Void
    ) {
        let evidence = VerifiedLinkEvidence()
        startWorkflow(auth: auth, context: modelContext, email: signedInEmail,
                      completion: { result in
                          completion(result.map { SyncOutcome(message: $0,
                              verifiedNotFoundIDs: evidence.notFoundIDs) })
                      }) {
            try await synchronize(workflow: $0, verifyConfirmedCalls: verifyConfirmedCalls,
                                  verifiedNotFound: { callID, eventID in
                                      evidence.notFoundIDs[callID] = eventID
                                  })
        }
    }

    static func exportImmediately(
        call: ServiceCall, auth: GoogleAuthManager, modelContext: ModelContext,
        signedInEmail: String?, isAdminUser: Bool,
        completion: ((Result<String, Error>) -> Void)? = nil
    ) {
        startWorkflow(auth: auth, context: modelContext, email: signedInEmail, scope: [call],
                      completion: { result in
            if case .failure = result {
                scheduleRetry(auth: auth, modelContext: modelContext, signedInEmail: signedInEmail, attempt: 0)
            }
            completion?(result)
        },
                      prepare: {
            guard (try? containsOriginalCall(call, in: modelContext)) == true else {
                throw GoogleCalendarWorkflowError.changed
            }
            markCalendarCallLocallyEdited(call)
            do { try modelContext.save() }
            catch { throw GoogleCalendarWorkflowError.saveFailed }
        }) {
            try await publish(call: call, workflow: $0)
        }
    }

    /// Recover saved outbound intents on Schedule entry and after a failed
    /// immediate send. This publishes only; it never imports unrelated events.
    static func retryPendingIfNeeded(auth: GoogleAuthManager, modelContext: ModelContext,
                                     signedInEmail: String?, attempt: Int = 0) {
        guard auth.isAuthenticated,
              hasPotentialOutboundSync(in: modelContext) else { return }
        retryTask?.cancel()
        retryTask = nil
        startWorkflow(auth: auth, context: modelContext, email: signedInEmail, completion: { result in
            if case .failure = result {
                scheduleRetry(auth: auth, modelContext: modelContext,
                              signedInEmail: signedInEmail, attempt: attempt + 1)
            }
        }) { workflow in
            let outcome = try await publishPending(workflow: workflow)
            return "Sent \(outcome.published) pending calendar update(s) to Google.\(outcome.reviewSummary)"
        }
    }

    private static func scheduleRetry(auth: GoogleAuthManager, modelContext: ModelContext,
                                      signedInEmail: String?, attempt: Int) {
        guard retryDelays.indices.contains(attempt),
              hasPotentialOutboundSync(in: modelContext) else { return }
        let delay = retryDelays[attempt]
        retryTask?.cancel()
        retryTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            retryTask = nil
            retryPendingIfNeeded(auth: auth, modelContext: modelContext,
                                 signedInEmail: signedInEmail, attempt: attempt)
        }
    }

    /// A failed full recovery may have left a durable saved appointment in the
    /// outbox. Use the existing bounded publish-only retry without importing.
    static func retryPendingAfterAutomaticFailure(auth: GoogleAuthManager, modelContext: ModelContext,
                                                  signedInEmail: String?) {
        scheduleRetry(auth: auth, modelContext: modelContext, signedInEmail: signedInEmail, attempt: 0)
    }

    /// The Schedule entry and retry timer need only know whether a durable
    /// outbound candidate exists. Decode at most one row here; the publication
    /// pass applies the exact eligibility and provider checks.
    static func hasPotentialOutboundSync(in context: ModelContext, now: Date = Date()) -> Bool {
        let today = Calendar.current.startOfDay(for: now)
        var descriptor = FetchDescriptor<ServiceCall>(
            predicate: #Predicate {
                $0.googleCalendarPendingAt != nil ||
                    ($0.googleEventManagedByApp && $0.googleEventConfirmedAt == nil &&
                     $0.scheduledDate >= today)
            })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor).isEmpty) == false
    }

    static func checkGoogleLink(call: ServiceCall, workflow: GoogleCalendarWorkflow) async
        -> Result<GoogleLinkCheck, Error> {
        await checkGoogleLink(call: call, workflow: workflow,
            workspaceStamp: CompanyWorkspaceAccessController.shared.operationStamp)
    }

    static func checkGoogleLink(call: ServiceCall, workflow: GoogleCalendarWorkflow,
                                workspaceStamp: CompanyWorkspaceOperationStamp?) async
        -> Result<GoogleLinkCheck, Error> {
        var review: MissingEventReview?
        var verifiedRemote: GoogleCalendarEvent?
        let result = await workflow.run { current in
            let (calendar, id, remote): (GoogleCalendar, String, GoogleCalendarEvent?)
            if call.googleEventManagedByApp {
                (calendar, id, remote) = try await inspectStoredEvent(call: call, workflow: current)
            } else {
                (calendar, id, remote) = try await inspectExternalStoredEvent(call: call, workflow: current)
            }
            if remote == nil {
                guard let accountEmail = current.auth.signedInEmail,
                      !accountEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw GoogleCalendarWorkflowError.identity
                }
                review = MissingEventReview(call: call, callID: call.id, calendarID: calendar.id,
                                            eventID: id, accountEmail: accountEmail,
                                            scheduledDate: call.scheduledDate, duration: call.duration,
                                            workflow: current)
            } else {
                verifiedRemote = remote
            }
            return remote == nil ? "The saved Google event was not found. Review the original calendar before choosing Recreate Missing Event." :
                "The original Google event is present. No new event was created."
        }
        return result.map { _ in
            GoogleLinkCheck(missingEventReview: review,
                verifiedLink: verifiedRemote.flatMap {
                    VerifiedGoogleEventLink(remote: $0, call: call,
                        connectedEmail: workflow.auth.signedInEmail,
                        workspaceStamp: workspaceStamp)
                }, alertGuidance: verifiedRemote.flatMap { alertGuidance(for: $0, call: call) })
        }
    }

    /// A saved imported route can be inspected without adopting the event or
    /// granting publication authority. A missing or changed route is review-only.
    private static func inspectExternalStoredEvent(call: ServiceCall, workflow: GoogleCalendarWorkflow)
        async throws -> (GoogleCalendar, String, GoogleCalendarEvent?) {
        try requireCall(call, workflow: workflow)
        guard !call.googleEventManagedByApp,
              call.status == .scheduled || call.status == .inProgress,
              let id = normalizedOptional(call.googleEventID),
              GoogleAuthManager.calendarPathComponent(id) != nil else {
            throw GoogleCalendarWorkflowError.needsReview
        }
        let list = try await calendars(workflow: workflow)
        guard list.count <= 25 else { throw GoogleCalendarWorkflowError.needsReview }
        let calendar = try canonicalCalendar(call.googleCalendarID, in: list, email: workflow.signedInEmail)
        var descriptor = FetchDescriptor<ServiceCall>(predicate: #Predicate { $0.googleEventID == id })
        descriptor.fetchLimit = 2
        let linked = try workflow.context.fetch(descriptor)
        guard linked.count == 1, linked.first === call else { throw GoogleCalendarWorkflowError.identity }
        let remote: GoogleCalendarEvent
        do {
            remote = try await workflow.receive {
                workflow.auth.fetchCalendarEvent(calendarID: calendar.id, eventID: id,
                    operation: workflow.operation, completion: $0)
            }
        } catch GoogleAuthError.http(statusCode: 404) {
            throw GoogleCalendarWorkflowError.alertReview(
                "The saved Google event was not found on its original calendar. Review that calendar; no replacement was created.")
        }
        try requireCall(call, workflow: workflow)
        guard remote.id == id, remote.status != "cancelled" else {
            throw GoogleCalendarWorkflowError.needsReview
        }
        guard remoteEventMatchesExactSchedule(call: call, remoteEvent: remote) else {
            throw GoogleCalendarWorkflowError.alertReview(scheduleMismatchGuidance(for: remote, call: call))
        }
        return (calendar, id, remote)
    }

    private static func alertGuidance(for remote: GoogleCalendarEvent, call: ServiceCall) -> String? {
        var warnings: [String] = []
        if remote.start.date != nil || remote.end.date != nil {
            let localHasSpecificTime = call.promisedArrivalWindow != nil ||
                !remoteEventMatchesExactSchedule(call: call, remoteEvent: remote)
            warnings.append(localHasSpecificTime
                ? "Google lists this as an all-day event, but GunnAire has a specific appointment time or arrival window. A time in notes does not make the Google event timed; review it in Google Calendar."
                : "Google lists this as an all-day event. A time in notes does not make it a timed appointment; review the event time in Google Calendar.")
        }
        if let warning = appointmentAlertGuidance(for: remote) { warnings.append(warning) }
        return warnings.isEmpty ? nil : warnings.joined(separator: " ")
    }

    private static func appointmentAlertGuidance(for event: GoogleCalendarEvent) -> String? {
        guard !hasExplicitAppointmentPopup(event) else { return nil }
        if event.reminders?.useDefault == false && event.reminders?.overrides?.isEmpty != false {
            return "Google event reminders are turned off. The 30-minute popup alert is not confirmed. Turn one on in Google Calendar if you want an event alert."
        }
        return "The Google event is linked, but its 30-minute popup alert is not confirmed. Check this event's reminders and calendar defaults in Google Calendar."
    }

    private static func scheduleMismatchGuidance(for remote: GoogleCalendarEvent, call: ServiceCall) -> String {
        let alert = alertGuidance(for: remote, call: call).map { " \($0)" } ?? ""
        return "The saved Google event does not match the appointment time. Review the original event in Google Calendar; no event was created or changed.\(alert)"
    }

    static func checkMissingEvent(call: ServiceCall, workflow: GoogleCalendarWorkflow) async
        -> Result<MissingEventReview?, Error> {
        (await checkGoogleLink(call: call, workflow: workflow)).map(\.missingEventReview)
    }

    enum UnlinkedMatchReason: String, Equatable {
        case appMarker, deterministicID, sameSchedule

        var displayName: String {
            switch self {
            case .appMarker: "GunnAire job marker"
            case .deterministicID: "GunnAire event ID"
            case .sameSchedule: "same appointment time"
            }
        }
    }

    struct UnlinkedCalendarCandidate: Equatable {
        let calendarID: String
        let eventID: String
        let summary: String?
        let reason: UnlinkedMatchReason
        let linkEligible: Bool
    }

    struct UnlinkedCalendarInspection {
        let accountEmail: String
        let originalCalendarID: String
        let windowStart: Date
        let windowEnd: Date
        let searchedCalendarIDs: [String]
        let writableCalendarIDs: [String]
        let candidates: [UnlinkedCalendarCandidate]

        /// A complete scoped search found no matching ID, marker, or schedule.
        /// It is not proof that no event exists in another account or time slot.
        var noMatchWithinScope: Bool { candidates.isEmpty }

        var singleProvableCandidate: UnlinkedCalendarCandidate? {
            let proven = candidates.filter { $0.reason != .sameSchedule }
            guard proven.count == 1, let candidate = proven.first, candidate.linkEligible,
                  writableCalendarIDs.contains(candidate.calendarID) else { return nil }
            return candidate
        }
    }

    struct UnlinkedEventLinkReview {
        let call: ServiceCall
        let workflow: GoogleCalendarWorkflow
        let accountEmail: String
        let originalCalendarID: String
        let candidate: UnlinkedCalendarCandidate
        fileprivate let revision: LinkRevision
    }

    struct ExistingEventLinkOutcome {
        let message: String
        let verifiedEvent: GoogleCalendarEvent?
    }

    static func linkReview(call: ServiceCall, workflow: GoogleCalendarWorkflow,
                           inspection: UnlinkedCalendarInspection) -> UnlinkedEventLinkReview? {
        guard let candidate = inspection.singleProvableCandidate,
              AppAccess.normalizedEmail(workflow.auth.signedInEmail) == inspection.accountEmail,
              !workflow.context.hasChanges, normalizedOptional(call.googleEventID) == nil,
              !call.googleEventManagedByApp else { return nil }
        return UnlinkedEventLinkReview(call: call, workflow: workflow,
            accountEmail: inspection.accountEmail, originalCalendarID: inspection.originalCalendarID,
            candidate: candidate, revision: LinkRevision(call))
    }

    /// A user-confirmed link only records the route and opaque ID of an event
    /// already owned by this job. It performs no provider mutation.
    static func linkExistingEvent(_ review: UnlinkedEventLinkReview) async -> Result<ExistingEventLinkOutcome, Error> {
        var outcome: ExistingEventLinkOutcome?
        let result = await review.workflow.run { workflow in
            let call = review.call
            guard LinkRevision(call) == review.revision,
                  AppAccess.normalizedEmail(workflow.auth.signedInEmail) == review.accountEmail else {
                throw GoogleCalendarWorkflowError.changed
            }
            let fresh = try await inspectUnlinkedCalendarJobReadOnly(call: call, workflow: workflow)
            guard fresh.accountEmail == review.accountEmail,
                  fresh.originalCalendarID == review.originalCalendarID,
                  fresh.singleProvableCandidate == review.candidate,
                  LinkRevision(call) == review.revision,
                  fresh.writableCalendarIDs.contains(review.candidate.calendarID) else {
                throw GoogleCalendarWorkflowError.changed
            }
            let candidate = review.candidate
            guard GoogleAuthManager.calendarPathComponent(candidate.eventID) != nil,
                  !isCalendarEventDeleted(calendarID: candidate.calendarID, eventID: candidate.eventID) else {
                throw GoogleCalendarWorkflowError.needsReview
            }
            let remote: GoogleCalendarEvent = try await workflow.receive {
                workflow.auth.fetchCalendarEvent(calendarID: candidate.calendarID, eventID: candidate.eventID,
                    operation: workflow.operation, completion: $0)
            }
            try validateLegacyLinkRemote(remote, candidate: candidate, call: call)
            guard try containsOriginalCall(call, in: workflow.context), !workflow.context.hasChanges,
                  LinkRevision(call) == review.revision else { throw GoogleCalendarWorkflowError.changed }
            try requireNoOtherLocalLink(eventID: candidate.eventID, callID: call.id, context: workflow.context)
            let oldCalendar = call.googleCalendarID
            let oldEvent = call.googleEventID
            call.googleCalendarID = candidate.calendarID
            call.googleEventID = candidate.eventID
            let linkedRevision = LinkRevision(call)
            workflow.setAdditionalValidation {
                guard LinkRevision(call) == linkedRevision,
                      !isCalendarEventDeleted(calendarID: candidate.calendarID, eventID: candidate.eventID) else {
                    throw GoogleCalendarWorkflowError.changed
                }
                try requireNoOtherLocalLink(eventID: candidate.eventID, callID: call.id, context: workflow.context)
            }
            defer { workflow.setAdditionalValidation(nil) }
            do { try workflow.saveChanges() }
            catch {
                call.googleCalendarID = oldCalendar
                call.googleEventID = oldEvent
                throw error
            }
            do {
                let checked: GoogleCalendarEvent = try await workflow.receive {
                    workflow.auth.fetchCalendarEvent(calendarID: candidate.calendarID, eventID: candidate.eventID,
                        operation: workflow.operation, completion: $0)
                }
                try validateLegacyLinkRemote(checked, candidate: candidate, call: call)
                outcome = ExistingEventLinkOutcome(message:
                    "Linked the existing Google event for \(review.accountEmail) on \(candidate.calendarID). The saved link was verified again. No event or invitation was sent.",
                    verifiedEvent: checked)
            } catch {
                outcome = ExistingEventLinkOutcome(message:
                    "The existing Google event link was saved, but its follow-up verification could not finish. Check this link again before relying on it. No event or invitation was sent.",
                    verifiedEvent: nil)
            }
            return outcome?.message ?? "The existing Google event link was saved without a provider write."
        }
        return result.flatMap { _ in
            guard let outcome else { return .failure(GoogleCalendarWorkflowError.needsReview) }
            return .success(outcome)
        }
    }

    private static func validateLegacyLinkRemote(_ event: GoogleCalendarEvent,
                                                  candidate: UnlinkedCalendarCandidate,
                                                  call: ServiceCall) throws {
        let marker = event.extendedProperties?.privateProperties?["gunnaireServiceCallID"]
        guard event.id == candidate.eventID, event.status != "cancelled", event.isManagedByGunnAire,
              marker == nil || marker == call.id.uuidString,
              marker == call.id.uuidString || event.id == eventID(for: call.id),
              remoteEventMatchesExactSchedule(call: call, remoteEvent: event) else {
            throw GoogleCalendarWorkflowError.identity
        }
    }

    private static func requireNoOtherLocalLink(eventID: String, callID: UUID, context: ModelContext) throws {
        var descriptor = FetchDescriptor<ServiceCall>(predicate: #Predicate { $0.googleEventID == eventID })
        descriptor.fetchLimit = 2
        guard try context.fetch(descriptor).allSatisfy({ $0.id == callID }) else {
            throw GoogleCalendarWorkflowError.identity
        }
    }

    /// An explicit office decision is bound to the exact local appointment,
    /// connected account, original writable calendar, and workspace operation.
    /// The inspection is repeated before any publication, so this is never
    /// treated as durable proof that a Google event does not exist elsewhere.
    struct UnlinkedPublishReview {
        let call: ServiceCall
        let accountEmail: String
        let originalCalendarID: String
        let searchedCalendarCount: Int
        fileprivate let searchedCalendarIDs: [String]
        let workflow: GoogleCalendarWorkflow
        private let revision: LinkRevision

        fileprivate init(call: ServiceCall, inspection: UnlinkedCalendarInspection,
                         workflow: GoogleCalendarWorkflow) {
            self.call = call
            accountEmail = inspection.accountEmail
            originalCalendarID = inspection.originalCalendarID
            searchedCalendarCount = inspection.searchedCalendarIDs.count
            searchedCalendarIDs = inspection.searchedCalendarIDs
            self.workflow = workflow
            revision = LinkRevision(call)
        }

        fileprivate func matchesCurrentAppointment() -> Bool { revision == LinkRevision(call) }
    }

    static func prepareUnlinkedPublishReview(call: ServiceCall, inspection: UnlinkedCalendarInspection,
                                             workflow: GoogleCalendarWorkflow) throws -> UnlinkedPublishReview {
        try requireCall(call, workflow: workflow)
        guard inspection.noMatchWithinScope, !inspection.searchedCalendarIDs.isEmpty,
              inspection.searchedCalendarIDs.contains(inspection.originalCalendarID),
              inspection.accountEmail == AppAccess.normalizedEmail(workflow.auth.signedInEmail),
              workflow.auth.googleCalendarAuthorizationState == .ready else {
            throw GoogleCalendarWorkflowError.needsReview
        }
        return UnlinkedPublishReview(call: call, inspection: inspection, workflow: workflow)
    }

    static func hasUnconfirmedLegacyCreateReservation(_ call: ServiceCall) -> Bool {
        !call.googleEventManagedByApp && call.googleEventID == eventID(for: call.id) &&
            call.googleEventConfirmedAt == nil && call.googleCalendarPendingAt != nil &&
            (call.status == .scheduled || call.status == .inProgress)
    }

    /// Recover only the exact ID reserved by an explicit legacy create. A
    /// complete bounded read may prove it is still missing in this account,
    /// but never grants another POST or clears the local reservation.
    static func checkReservedLegacyPublication(call: ServiceCall, workflow: GoogleCalendarWorkflow)
        async -> Result<String, Error> {
        await workflow.run { current in
            try requireCall(call, workflow: current)
            guard try containsOriginalCall(call, in: current.context), !current.context.hasChanges,
                  hasUnconfirmedLegacyCreateReservation(call),
                  current.auth.googleCalendarAuthorizationState == .ready,
                  let id = normalizedOptional(call.googleEventID),
                  !AppAccess.normalizedEmail(current.auth.signedInEmail).isEmpty else {
                throw GoogleCalendarWorkflowError.needsReview
            }
            let calendars: [GoogleCalendar] = try await current.receive {
                current.auth.fetchCalendarListForInspection(operation: current.operation, completion: $0)
            }
            guard !calendars.isEmpty, calendars.count <= 25,
                  Set(calendars.map(\.id)).count == calendars.count,
                  calendars.allSatisfy({ GoogleAuthManager.calendarPathComponent($0.id) != nil }) else {
                throw GoogleCalendarWorkflowError.needsReview
            }
            let original = try canonicalCalendar(call.googleCalendarID, in: calendars,
                email: current.signedInEmail)
            guard original.isWritable else { throw GoogleCalendarWorkflowError.readOnly }
            var found: [(GoogleCalendar, GoogleCalendarEvent)] = []
            for calendar in calendars.sorted(by: { $0.id < $1.id }) {
                do {
                    let event: GoogleCalendarEvent = try await current.receive {
                        current.auth.fetchCalendarEvent(calendarID: calendar.id, eventID: id,
                            operation: current.operation, completion: $0)
                    }
                    found.append((calendar, event))
                    guard found.count <= 1 else { throw GoogleCalendarWorkflowError.needsReview }
                } catch GoogleAuthError.http(statusCode: 404) {
                    // Only an exact 404 for every accessible calendar yields
                    // a scoped missing result. Any other read failure stops.
                }
            }
            try requireCall(call, workflow: current)
            guard let (calendar, remote) = found.first else {
                return "The reserved Google event ID was not found in this account's \(calendars.count) accessible calendar(s). No new event was sent. The original ID remains reserved to prevent a duplicate. Check the connected account and other possible time slots with your administrator before any new publication attempt."
            }
            guard calendar.isWritable else { throw GoogleCalendarWorkflowError.readOnly }
            try validateRemote(remote, id: id, call: call)
            guard remoteEventMatchesExactSchedule(call: call, remoteEvent: remote) else {
                throw GoogleCalendarWorkflowError.needsReview
            }
            let previousCalendar = call.googleCalendarID
            call.googleCalendarID = calendar.id
            call.googleEventManagedByApp = true
            do { try current.saveChanges() }
            catch {
                call.googleCalendarID = previousCalendar
                call.googleEventManagedByApp = false
                throw error
            }
            return try await publish(call: call, workflow: current)
        }
    }

    /// The user has confirmed a new event after reviewing a scoped absence.
    /// A second full scan runs inside the serialized workflow immediately
    /// before a durable deterministic-ID reservation. It remains unmanaged
    /// until Google proves the new event exists, so a failed local rollback
    /// or an ambiguous POST response cannot authorize automatic recreation.
    static func publishUnlinkedCalendarJob(_ review: UnlinkedPublishReview) async -> Result<String, Error> {
        await review.workflow.run { workflow in
            let call = review.call
            guard review.matchesCurrentAppointment(),
                  workflow.auth.googleCalendarAuthorizationState == .ready,
                  AppAccess.normalizedEmail(workflow.auth.signedInEmail) == review.accountEmail else {
                throw GoogleCalendarWorkflowError.changed
            }
            let fresh = try await inspectUnlinkedCalendarJobReadOnly(call: call, workflow: workflow)
            guard review.matchesCurrentAppointment(), fresh.noMatchWithinScope,
                  fresh.accountEmail == review.accountEmail,
                  fresh.originalCalendarID == review.originalCalendarID,
                  fresh.searchedCalendarIDs == review.searchedCalendarIDs else {
                throw GoogleCalendarWorkflowError.needsReview
            }
            try workflow.check()
            let id = eventID(for: call.id)
            let previousCalendar = call.googleCalendarID
            let previousPending = call.googleCalendarPendingAt
            call.googleCalendarID = fresh.originalCalendarID
            call.googleEventID = id
            call.googleCalendarPendingAt = Date()
            do { try workflow.saveChanges() }
            catch {
                call.googleCalendarID = previousCalendar
                call.googleEventID = nil
                call.googleCalendarPendingAt = previousPending
                throw error
            }
            let calendarID = fresh.originalCalendarID
            let saved: GoogleCalendarEvent
            do {
                saved = try await workflow.receive {
                    workflow.auth.fetchCalendarEvent(calendarID: calendarID, eventID: id,
                        operation: workflow.operation, completion: $0)
                }
            } catch GoogleAuthError.http(statusCode: 404) {
                // This is the only path that may POST. It is reached after a
                // complete fresh scan and a saved, single-use reservation.
                let recipients: [GoogleWritableCalendarAttendee]?
                do { recipients = try staffAttendees(for: call, workflow: workflow) }
                catch GoogleCalendarStaffDeliveryError.staffEmail { recipients = nil }
                var proposal = makeCalendarCreateEvent(for: call)
                proposal.attendees = recipients?.filter {
                    $0.email != GoogleCalendarStaffDelivery.email(calendarID)
                }
                var properties = proposal.extendedProperties?.privateProperties ?? [:]
                properties[GoogleCalendarStaffDelivery.managedEmailsKey] =
                    (proposal.attendees ?? []).map(\.email).sorted().joined(separator: ",")
                proposal.extendedProperties = .init(privateProperties: properties)
                proposal.id = id
                do {
                    saved = try await workflow.receive {
                        workflow.auth.createCalendarEvent(calendarID: calendarID, event: proposal,
                            operation: workflow.operation, completion: $0)
                    }
                } catch GoogleAuthError.http(statusCode: let code) where code == 401 || code == 403 {
                    // Google's explicit denial did not create an event. If
                    // access also disappeared before local rollback, the
                    // unmanaged reservation is still safe and reviewable.
                    try workflow.check()
                    guard call.googleCalendarID == calendarID, call.googleEventID == id,
                          !call.googleEventManagedByApp else {
                        throw GoogleCalendarWorkflowError.changed
                    }
                    call.googleCalendarID = previousCalendar
                    call.googleEventID = nil
                    call.googleCalendarPendingAt = previousPending
                    do { try workflow.saveChanges() }
                    catch {
                        call.googleCalendarID = calendarID
                        call.googleEventID = id
                        call.googleCalendarPendingAt = Date()
                        throw error
                    }
                    throw GoogleAuthError.http(statusCode: code)
                }
            }
            try requireCall(call, workflow: workflow)
            try validateRemote(saved, id: id, call: call)
            guard remoteEventMatchesExactSchedule(call: call, remoteEvent: saved) else {
                throw GoogleCalendarWorkflowError.needsReview
            }
            call.googleEventManagedByApp = true
            do { try workflow.saveChanges() }
            catch {
                call.googleEventManagedByApp = false
                throw error
            }
            return try await publish(call: call, workflow: workflow)
        }
    }

    /// Inspect a legacy nil-ID job without saving a link or issuing a write.
    /// A failed calendar read, overfull page, or changed job never yields a
    /// negative result that could later be mistaken for creation authority.
    static func inspectUnlinkedCalendarJob(call: ServiceCall, workflow: GoogleCalendarWorkflow) async
        -> Result<UnlinkedCalendarInspection, Error> {
        var inspection: UnlinkedCalendarInspection?
        let result = await workflow.run { current in
            inspection = try await inspectUnlinkedCalendarJobReadOnly(call: call, workflow: current)
            return "Read-only Google Calendar inspection finished. No event was created or linked."
        }
        return result.flatMap { _ in
            guard let inspection else { return .failure(GoogleCalendarWorkflowError.needsReview) }
            return .success(inspection)
        }
    }

    private static func inspectUnlinkedCalendarJobReadOnly(call: ServiceCall, workflow: GoogleCalendarWorkflow)
        async throws -> UnlinkedCalendarInspection {
        try requireCall(call, workflow: workflow)
        guard try containsOriginalCall(call, in: workflow.context), !workflow.context.hasChanges,
              !call.googleEventManagedByApp, normalizedOptional(call.googleEventID) == nil,
              call.googleCalendarPendingAt == nil, call.googleEventConfirmedAt == nil,
              call.status == .scheduled || call.status == .inProgress,
              call.scheduledDate.timeIntervalSince1970.isFinite,
              call.duration.isFinite, call.duration > 0, call.duration <= 24 * 60 * 60 else {
            throw GoogleCalendarWorkflowError.needsReview
        }
        let account = AppAccess.normalizedEmail(workflow.auth.signedInEmail)
        guard !account.isEmpty else {
            throw GoogleCalendarWorkflowError.identity
        }
        let end = call.scheduledDate.addingTimeInterval(call.duration)
        let windowStart = call.scheduledDate.addingTimeInterval(-2 * 60 * 60)
        let windowEnd = end.addingTimeInterval(2 * 60 * 60)
        guard end.timeIntervalSince1970.isFinite,
              windowStart.timeIntervalSince1970.isFinite,
              windowEnd.timeIntervalSince1970.isFinite else {
            throw GoogleCalendarWorkflowError.invalidDates
        }
        // Include every calendar the account lists, including calendars that
        // normal schedule import omits. A scoped absence result is not sound
        // if a moved event could be hidden by that import filter.
        let listed: [GoogleCalendar] = try await workflow.receive {
            workflow.auth.fetchCalendarListForInspection(operation: workflow.operation, completion: $0)
        }
        guard !listed.isEmpty, listed.count <= 25,
              listed.allSatisfy({ !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(listed.map(\.id)).count == listed.count,
              listed.filter({ $0.primary == true }).count <= 1 else {
            throw GoogleCalendarWorkflowError.needsReview
        }
        let list = listed.sorted(by: { $0.id < $1.id })
        let original = try canonicalCalendar(call.googleCalendarID, in: list, email: workflow.signedInEmail)
        guard original.isWritable else { throw GoogleCalendarWorkflowError.readOnly }
        let deterministicID = eventID(for: call.id)
        var candidates: [String: UnlinkedCalendarCandidate] = [:]
        for calendar in list {
            let key = "\(calendar.id)|\(deterministicID)"
            do {
                let event: GoogleCalendarEvent = try await workflow.receive {
                    workflow.auth.fetchCalendarEvent(calendarID: calendar.id, eventID: deterministicID,
                        operation: workflow.operation, completion: $0)
                }
                guard event.id == deterministicID else { throw GoogleCalendarWorkflowError.identity }
                let candidate = UnlinkedCalendarCandidate(calendarID: calendar.id, eventID: event.id,
                    summary: event.summary, reason: .deterministicID, linkEligible: false)
                candidates[key] = UnlinkedCalendarCandidate(calendarID: calendar.id, eventID: event.id,
                    summary: event.summary, reason: .deterministicID,
                    linkEligible: (try? validateLegacyLinkRemote(event, candidate: candidate, call: call)) != nil)
                guard candidates.count <= 20 else { throw GoogleCalendarWorkflowError.needsReview }
            } catch GoogleAuthError.http(statusCode: 404) {
                // Only an exact 404 on this ID may be treated as absent here.
            }
            let events: [GoogleCalendarEvent] = try await workflow.receive {
                workflow.auth.fetchCalendarInspectionWindow(calendarID: calendar.id,
                    timeMin: windowStart, timeMax: windowEnd,
                    operation: workflow.operation, completion: $0)
            }
            for event in events {
                guard GoogleAuthManager.calendarPathComponent(event.id) != nil,
                      let start = parseEventDate(event.start), let finish = parseEventDate(event.end) else {
                    throw GoogleCalendarWorkflowError.needsReview
                }
                let marker = event.extendedProperties?.privateProperties?["gunnaireServiceCallID"]
                let matchesMarker = marker?.caseInsensitiveCompare(call.id.uuidString) == .orderedSame
                let matchesSchedule = abs(start.timeIntervalSince(call.scheduledDate)) <= 60 &&
                    abs(finish.timeIntervalSince(end)) <= 60
                let reason: UnlinkedMatchReason
                if matchesMarker { reason = .appMarker }
                else if event.id == deterministicID { reason = .deterministicID }
                else if matchesSchedule { reason = .sameSchedule }
                else { continue }
                let key = "\(calendar.id)|\(event.id)"
                let candidate = UnlinkedCalendarCandidate(calendarID: calendar.id, eventID: event.id,
                    summary: event.summary, reason: reason, linkEligible: false)
                candidates[key] = UnlinkedCalendarCandidate(calendarID: calendar.id, eventID: event.id,
                    summary: event.summary, reason: reason,
                    linkEligible: reason != .sameSchedule &&
                        (try? validateLegacyLinkRemote(event, candidate: candidate, call: call)) != nil)
                guard candidates.count <= 20 else { throw GoogleCalendarWorkflowError.needsReview }
            }
        }
        try requireCall(call, workflow: workflow)
        return UnlinkedCalendarInspection(accountEmail: account, originalCalendarID: original.id,
            windowStart: windowStart, windowEnd: windowEnd, searchedCalendarIDs: list.map(\.id),
            writableCalendarIDs: list.filter(\.isWritable).map(\.id),
            candidates: candidates.values.sorted {
                $0.calendarID == $1.calendarID ? $0.eventID < $1.eventID : $0.calendarID < $1.calendarID
            })
    }

    static func repairMissingEvent(_ review: MissingEventReview) async -> Result<String, Error> {
        await review.workflow.run { workflow in
            let call = review.call
            guard AppAccess.normalizedEmail(workflow.auth.signedInEmail) ==
                    AppAccess.normalizedEmail(review.accountEmail),
                  call.scheduledDate == review.scheduledDate, call.duration == review.duration else {
                throw GoogleCalendarWorkflowError.changed
            }
            let (calendar, id, remote) = try await inspectStoredEvent(call: call, workflow: workflow)
            guard call.id == review.callID, calendar.id == review.calendarID,
                  id == review.eventID else {
                throw GoogleCalendarWorkflowError.changed
            }
            if let remote {
                try validateRemote(remote, id: id, call: call)
                guard remoteEventMatchesExactSchedule(call: call, remoteEvent: remote) else {
                    throw GoogleCalendarWorkflowError.needsReview
                }
                return "The original Google event is present. No new event was created."
            }
            // The old confirmation described an event that is now absent.
            // Keep the original reserved route, but persist an unconfirmed
            // state before another provider write or a possible app exit.
            try requireCall(call, workflow: workflow)
            let initialConfirmation = call.googleEventConfirmedAt
            let initialPending = call.googleCalendarPendingAt
            call.googleEventConfirmedAt = nil
            call.googleCalendarPendingAt = replacementPopupProofPendingAt
            do { try workflow.saveChanges() }
            catch {
                call.googleEventConfirmedAt = initialConfirmation
                call.googleCalendarPendingAt = initialPending
                throw error
            }
            let recipients: [GoogleWritableCalendarAttendee]?
            do { recipients = try staffAttendees(for: call, workflow: workflow) }
            catch GoogleCalendarStaffDeliveryError.staffEmail { recipients = nil }
            var proposal = makeCalendarCreateEvent(for: call)
            proposal.attendees = recipients?.filter {
                $0.email != GoogleCalendarStaffDelivery.email(calendar.id)
            }
            var properties = proposal.extendedProperties?.privateProperties ?? [:]
            properties[GoogleCalendarStaffDelivery.managedEmailsKey] =
                (proposal.attendees ?? []).map(\.email).sorted().joined(separator: ",")
            proposal.extendedProperties = .init(privateProperties: properties)
            proposal.id = id
            var accepted: GoogleCalendarEvent
            do {
                accepted = try await workflow.receive {
                    workflow.auth.createCalendarEvent(calendarID: calendar.id, event: proposal,
                        operation: workflow.operation, completion: $0)
                }
            } catch GoogleAuthError.http(statusCode: 409) {
                // Another writer may have created the reserved ID between the
                // last GET and POST. Reconcile only the exact original route.
                accepted = try await workflow.receive {
                    workflow.auth.fetchCalendarEvent(calendarID: calendar.id, eventID: id,
                        operation: workflow.operation, completion: $0)
                }
            }
            try requireCall(call, workflow: workflow)
            try validateRemote(accepted, id: id, call: call)
            guard accepted.extendedProperties?.privateProperties?["gunnaireServiceCallID"] == call.id.uuidString,
                  remoteEventMatchesExactSchedule(call: call, remoteEvent: accepted) else {
                throw GoogleCalendarWorkflowError.needsReview
            }
            // A successful POST response or a 409 race is not proof that the
            // replacement is visible in this calendar with its popup alert.
            let saved: GoogleCalendarEvent
            do {
                saved = try await workflow.receive {
                    workflow.auth.fetchCalendarEvent(calendarID: calendar.id, eventID: id,
                        operation: workflow.operation, completion: $0)
                }
            } catch GoogleAuthError.http(statusCode: 404) {
                throw GoogleCalendarWorkflowError.unconfirmedReadback
            }
            try requireCall(call, workflow: workflow)
            try validateRemote(saved, id: id, call: call)
            guard saved.extendedProperties?.privateProperties?["gunnaireServiceCallID"] == call.id.uuidString,
                  remoteEventMatchesExactSchedule(call: call, remoteEvent: saved) else {
                throw GoogleCalendarWorkflowError.needsReview
            }
            let delivered = recipients != nil
                ? try await deliverToStaff(call: call, remote: saved, calendarID: calendar.id,
                                           workflow: workflow)
                : saved
            guard delivered.extendedProperties?.privateProperties?["gunnaireServiceCallID"] == call.id.uuidString else {
                throw GoogleCalendarWorkflowError.needsReview
            }
            guard hasExplicitAppointmentPopup(delivered) else {
                throw GoogleCalendarWorkflowError.alertReview(
                    "The replacement Google event exists, but its 30-minute popup reminder was not confirmed. Check the original event in Google Calendar before relying on an alert.")
            }
            try requireCall(call, workflow: workflow)
            if recipients == nil {
                let previousPending = call.googleCalendarPendingAt
                markCalendarCallLocallyEdited(call)
                // The organizer event and popup are proven; keep only the
                // outstanding staff invitation work in the normal outbox.
                call.googleCalendarPendingAt = Date()
                do { try workflow.saveChanges() }
                catch {
                    call.googleCalendarPendingAt = previousPending
                    throw error
                }
                markStaffInvitationReview(for: call, workflow: workflow)
                return "Google event confirmed. Staff invitations need attention: assign every technician and crew member a unique valid calendar email, then use Sync Google."
            }
            let previousConfirmation = call.googleEventConfirmedAt
            let previousPending = call.googleCalendarPendingAt
            call.googleEventConfirmedAt = Date()
            call.googleCalendarPendingAt = nil
            do { try workflow.saveChanges() }
            catch {
                call.googleEventConfirmedAt = previousConfirmation
                call.googleCalendarPendingAt = previousPending
                throw error
            }
            clearStaffInvitationReview(for: call)
            clearCalendarCallLocallyEdited(call)
            return "Original appointment schedule confirmed in Google Calendar. Assigned staff invitations, if any, use each recipient's Google Calendar notification settings."
        }
    }

    /// A 404 proves only that one route is missing. Check every accessible
    /// calendar by the same opaque ID; a moved or colliding event needs review.
    private static func inspectStoredEvent(call: ServiceCall, workflow: GoogleCalendarWorkflow)
        async throws -> (GoogleCalendar, String, GoogleCalendarEvent?) {
        try requireCall(call, workflow: workflow)
        guard call.googleEventManagedByApp,
              call.status == .scheduled || call.status == .inProgress,
              call.scheduledDate.timeIntervalSince1970.isFinite, call.duration.isFinite,
              call.duration > 0,
              call.scheduledDate.addingTimeInterval(call.duration).timeIntervalSince1970.isFinite,
              let id = normalizedOptional(call.googleEventID),
              GoogleAuthManager.calendarPathComponent(id) != nil,
              !isCalendarEventDeleted(calendarID: call.googleCalendarID, eventID: id) else {
            throw GoogleCalendarWorkflowError.needsReview
        }
        let list = try await calendars(workflow: workflow)
        guard list.count <= 25 else { throw GoogleCalendarWorkflowError.needsReview }
        let calendar = try canonicalCalendar(call.googleCalendarID, in: list, email: workflow.signedInEmail)
        guard calendar.isWritable else { throw GoogleCalendarWorkflowError.readOnly }
        guard !isCalendarEventDeleted(calendarID: calendar.id, eventID: id) else {
            throw GoogleCalendarWorkflowError.needsReview
        }
        // Event IDs are scoped by calendar, but another local call holding
        // the same ID could use the `primary` alias for this exact calendar.
        // Conservatively refuse any duplicate local ID rather than guess.
        var linkedDescriptor = FetchDescriptor<ServiceCall>(predicate: #Predicate { $0.googleEventID == id })
        linkedDescriptor.fetchLimit = 2
        let linked = try workflow.context.fetch(linkedDescriptor)
        guard linked.count == 1, linked.first === call else {
            throw GoogleCalendarWorkflowError.identity
        }
        var original: GoogleCalendarEvent?
        for candidate in list.sorted(by: { $0.id < $1.id }) {
            do {
                let remote: GoogleCalendarEvent = try await workflow.receive {
                    workflow.auth.fetchCalendarEvent(calendarID: candidate.id, eventID: id,
                        operation: workflow.operation, completion: $0)
                }
                guard candidate.id == calendar.id else {
                    throw GoogleCalendarWorkflowError.needsReview
                }
                original = remote
            } catch GoogleAuthError.http(statusCode: 404) {
                continue
            }
        }
        try requireCall(call, workflow: workflow)
        if let original {
            try validateRemote(original, id: id, call: call)
            guard remoteEventMatchesExactSchedule(call: call, remoteEvent: original) else {
                throw GoogleCalendarWorkflowError.alertReview(scheduleMismatchGuidance(for: original, call: call))
            }
        }
        return (calendar, id, original)
    }

    static func cancelManagedEventImmediately(
        for call: ServiceCall, auth: GoogleAuthManager, modelContext: ModelContext,
        completion: ((Result<String, Error>) -> Void)? = nil
    ) {
        guard (try? containsOriginalCall(call, in: modelContext)) == true else {
            completion?(.failure(GoogleCalendarWorkflowError.changed)); return
        }
        markCalendarCallLocallyEdited(call)
        do { try modelContext.save() }
        catch { completion?(.failure(GoogleCalendarWorkflowError.saveFailed)); return }
        startWorkflow(auth: auth, context: modelContext, email: AppIdentity.currentEmail,
                      scope: [call], completion: completion) {
            try await cancel(call: call, workflow: $0)
        }
    }

    private static func startWorkflow(
        auth: GoogleAuthManager, context: ModelContext, email: String?, scope: [ServiceCall]? = nil,
        completion: ((Result<String, Error>) -> Void)?,
        prepare: () throws -> Void = {},
        action: @escaping (GoogleCalendarWorkflow) async throws -> String
    ) {
        let requestID = UUID()
        auth.calendarSyncRequestID = requestID
        auth.calendarSyncMessage = "Saved locally. Sending calendar changes to Google…"
        let report: (Result<String, Error>) -> Void = { result in
            // An older successful operation must not hide a newer pending/busy
            // failure, nor update the status of a replacement Google account.
            if auth.calendarSyncRequestID == requestID {
                switch result {
                case .success(let message): auth.calendarSyncMessage = message
                case .failure(let error):
                    auth.calendarSyncMessage = "Calendar update is not confirmed. Your saved appointment is retained. \(error.localizedDescription) Use Sync Google to retry."
                }
            }
            completion?(result)
        }
        do {
            try prepare()
            // Capture before Task scheduling; a later callback cannot capture a
            // replacement provider for an old retained job.
            let workflow = try GoogleCalendarWorkflow(auth: auth, context: context,
                signedInEmail: email, scope: scope)
            runQueued(workflow: workflow, container: context.container, action: action, completion: report)
        } catch { report(.failure(error)) }
    }

    /// Calendar writes for one store run in save order. Each queued workflow
    /// retains its original provider/workspace operation, which is rechecked
    /// before any provider request after an account or workspace switch.
    static func runQueued(workflow: GoogleCalendarWorkflow, container: ModelContainer,
                          action: @escaping (GoogleCalendarWorkflow) async throws -> String,
                          completion: @escaping (Result<String, Error>) -> Void) {
        let key = ObjectIdentifier(container)
        queuedWorkflows[key, default: []].append(
            QueuedWorkflow(workflow: workflow, action: action, completion: completion))
        guard drainingWorkflowContainers.insert(key).inserted else { return }
        Task { @MainActor in
            while let item = queuedWorkflows[key]?.first {
                var result: Result<String, Error> = .failure(GoogleCalendarWorkflowError.busy)
                for attempt in 0..<60 {
                    result = await item.workflow.run(item.action)
                    guard case .failure(let error) = result,
                          error as? GoogleCalendarWorkflowError == .busy,
                          attempt < 59 else { break }
                    do { try await Task.sleep(for: .milliseconds(500)) }
                    catch { result = .failure(error); break }
                }
                queuedWorkflows[key]?.removeFirst()
                if queuedWorkflows[key]?.isEmpty == true { queuedWorkflows.removeValue(forKey: key) }
                item.completion(result)
            }
            drainingWorkflowContainers.remove(key)
        }
    }

    /// Retry only explicitly edited app-owned jobs and upcoming never-linked
    /// app-owned appointments. Imports and completed history are not an outbox.
    static func needsOutboundSync(_ call: ServiceCall, now: Date = Date()) -> Bool {
        guard call.googleEventManagedByApp || isWriteBackRequested(call),
              !isCalendarEventDeleted(calendarID: call.googleCalendarID, eventID: call.googleEventID) else { return false }
        if call.status == .cancelled {
            return isCalendarCallLocallyEdited(call) ||
                call.googleCalendarPendingAt != nil
        }
        guard call.status == .scheduled || call.status == .inProgress else { return false }
        return isCalendarCallLocallyEdited(call) || call.googleCalendarPendingAt != nil ||
            (call.googleEventConfirmedAt == nil && call.scheduledDate >= Calendar.current.startOfDay(for: now))
    }

    /// One small SwiftData page per automatic pass. The cursor advances past
    /// every inspected row, including ineligible rows, so frequent foreground
    /// wakes cannot repeatedly spend the request budget on the same jobs.
    static func automaticVerificationPage(context: ModelContext, now: Date, offset: Int,
                                          pageSize: Int = 32, maxLinks: Int = 2) throws -> AutomaticVerificationPage {
        guard pageSize > 0, maxLinks > 0 else { return AutomaticVerificationPage(calls: [], nextOffset: 0) }
        let lower = Calendar.current.date(byAdding: .day, value: -7, to: Calendar.current.startOfDay(for: now)) ?? now
        let upper = Calendar.current.date(byAdding: .day, value: 90, to: now) ?? now
        var descriptor = FetchDescriptor<ServiceCall>(
            predicate: #Predicate { $0.googleEventManagedByApp &&
                $0.scheduledDate >= lower && $0.scheduledDate <= upper },
            sortBy: [SortDescriptor(\.scheduledDate), SortDescriptor(\.id)])
        descriptor.fetchLimit = pageSize
        descriptor.fetchOffset = max(0, offset)
        var page = try context.fetch(descriptor)
        var baseOffset = max(0, offset)
        if page.isEmpty, baseOffset > 0 {
            descriptor.fetchOffset = 0
            page = try context.fetch(descriptor)
            baseOffset = 0
        }
        var inspected = 0
        var calls: [ServiceCall] = []
        for call in page {
            inspected += 1
            if call.googleEventConfirmedAt != nil, call.googleCalendarPendingAt == nil,
               normalizedOptional(call.googleEventID) != nil,
               (call.status == .scheduled || call.status == .inProgress),
               !isCalendarEventDeleted(calendarID: call.googleCalendarID, eventID: call.googleEventID) {
                calls.append(call)
                if calls.count == maxLinks { break }
            }
        }
        let nextOffset = inspected == page.count && page.count < pageSize ? 0 : baseOffset + inspected
        return AutomaticVerificationPage(calls: calls, nextOffset: nextOffset)
    }

    static func synchronize(workflow: GoogleCalendarWorkflow,
                            verifyConfirmedCalls: [ServiceCall] = [],
                            verifiedNotFound: ((UUID, String) -> Void)? = nil) async throws -> String {
        let outcome = try await publishPending(workflow: workflow)
        var reviewErrors = outcome.reviewErrors
        try workflow.focus(on: nil)
        // Foreground recovery and explicit Sync Google check selected confirmed
        // links before an unrelated import can fail. Confirmation is historical.
        let confirmed = verifyConfirmedCalls.filter {
            $0.googleEventManagedByApp && $0.googleEventConfirmedAt != nil &&
            $0.googleCalendarPendingAt == nil && $0.googleEventID != nil &&
            ($0.status == .scheduled || $0.status == .inProgress)
        }
        var checked = 0
        let confirmationCalendars = confirmed.isEmpty ? [] : try await calendars(workflow: workflow)
        for call in confirmed.prefix(25) {
            do {
                try workflow.focus(on: [call])
                let remote = try await verifyConfirmedLink(call: call, calendars: confirmationCalendars,
                                                           workflow: workflow)
                checked += 1
                if let remote, let warning = appointmentAlertGuidance(for: remote) {
                    reviewErrors.append(warning)
                }
                if remote == nil {
                    guard let originalID = normalizedOptional(call.googleEventID) else {
                        throw GoogleCalendarWorkflowError.identity
                    }
                    markCalendarCallLocallyEdited(call)
                    try workflow.saveChanges()
                    verifiedNotFound?(call.id, originalID)
                    reviewErrors.append("A saved Google link was not found in this connected account's accessible calendars. Use Check Google Link before any repair.")
                }
            } catch {
                try workflow.check()
                if error is CancellationError { throw error }
                if let issue = error as? GoogleCalendarWorkflowError,
                   issue == .accessDenied || issue == .changed || issue == .busy ||
                   issue == .saveFailed || issue == .unconfirmedWrite { throw error }
                if case GoogleAuthError.http(statusCode: let status) = error,
                   status == 401 || status == 403 { throw error }
                reviewErrors.append("A confirmed Google link could not be verified (\(error.localizedDescription)). Use Check Google Link on its appointment.")
            }
        }
        try workflow.focus(on: nil)
        let imported = try await importSchedule(workflow: workflow)
        let visibleUnlinkedIDs = Set(verifyConfirmedCalls.filter { call in
            !call.googleEventManagedByApp && normalizedOptional(call.googleEventID) == nil &&
                (call.status == .scheduled || call.status == .inProgress)
        }.map(\.id))
        let review = reviewErrors.first.map { " \(reviewErrors.count) update(s) still need review. \($0)" } ?? ""
        let linkCheck = verifyConfirmedCalls.isEmpty ? "" :
            " Checked \(checked) confirmed selected-day/upcoming Google link(s) (up to 25 per sync)." +
            (confirmed.count > 25 ? " \(confirmed.count - 25) more link(s) were not checked; use Check Google Link on those appointments." : "")
        let unlinkedReview: String
        if !visibleUnlinkedIDs.isEmpty {
            let account = AppAccess.normalizedEmail(workflow.auth.signedInEmail)
            let accountLabel = account.isEmpty ? "the connected Google account" : account
            let singular = visibleUnlinkedIDs.count == 1
            let job = singular ? "job has" : "jobs have"
            let published = singular ? "was" : "were"
            unlinkedReview = " \(visibleUnlinkedIDs.count) displayed scheduled \(job) no Google event link and \(published) not published for \(accountLabel). Open each affected job in Schedule and choose Review Google publication. That read-only review checks only calendars accessible to this account near the saved appointment time; an event may exist in another account or time slot."
        } else if outcome.published == 0 {
            unlinkedReview = " Older scheduled jobs without a Google event link are not included in automatic publication; check their Schedule cards for review."
        } else {
            unlinkedReview = ""
        }
        let publication = outcome.published == 0
            ? "No pending app-managed calendar updates were published."
            : "Published \(outcome.published) pending calendar update(s)."
        return "\(publication)\(review)\(linkCheck)\(unlinkedReview) \(imported)"
    }

    struct PendingOutcome {
        let published: Int
        let reviewErrors: [String]
        var reviewSummary: String {
            reviewErrors.first.map { " \(reviewErrors.count) update(s) still need review. \($0)" } ?? ""
        }
    }

    static func publishPending(workflow: GoogleCalendarWorkflow, pageSize: Int = 100,
                               maximumPages: Int? = nil, maximumPublications: Int? = nil,
                               startingOffset: Int = 0, backgroundCandidatesOnly: Bool = false,
                               onBackgroundPage: ((Int) -> Void)? = nil) async throws -> PendingOutcome {
        guard pageSize > 0, maximumPages.map({ $0 > 0 }) ?? true,
              maximumPublications.map({ $0 > 0 }) ?? true else {
            return PendingOutcome(published: 0, reviewErrors: [])
        }
        try workflow.focus(on: nil)
        try workflow.check()
        guard !workflow.context.hasChanges else { throw GoogleCalendarWorkflowError.changed }
        var published = 0
        var reviewErrors: [String] = []
        var offset = max(0, startingOffset)
        var pages = 0
        while true {
            try workflow.focus(on: nil)
            try workflow.check()
            let page: [ServiceCall]
            if backgroundCandidatesOnly {
                let candidatePage = try backgroundCandidatePage(context: workflow.context,
                                                                offset: offset, pageSize: pageSize)
                page = candidatePage.calls
                onBackgroundPage?(candidatePage.nextOffset)
            } else {
                var descriptor = FetchDescriptor<ServiceCall>(
                    predicate: #Predicate { $0.googleEventManagedByApp || $0.googleCalendarPendingAt != nil },
                    sortBy: [SortDescriptor(\.scheduledDate), SortDescriptor(\.id)])
                descriptor.fetchLimit = pageSize
                descriptor.fetchOffset = offset
                page = try workflow.context.fetch(descriptor)
            }
            guard !page.isEmpty else { break }
            pages += 1
            for call in page where needsOutboundSync(call) {
                try workflow.focus(on: [call])
                // Keep the same company/provider operation throughout the batch.
                // Any failed/uncertain write stops this run; its pending marker stays.
                markCalendarCallLocallyEdited(call)
                try workflow.saveChanges()
                do {
                    if call.status == .cancelled { _ = try await cancel(call: call, workflow: workflow) }
                    else {
                        _ = try await publish(call: call, workflow: workflow,
                            reminderWarning: { reviewErrors.append($0) })
                        if staffInvitationsNeedAttention(for: call, connectedGoogleEmail: workflow.auth.signedInEmail,
                                                         workspaceEmail: workflow.signedInEmail) {
                            reviewErrors.append(GoogleCalendarStaffDeliveryError.staffEmail.localizedDescription)
                        }
                    }
                    published += 1
                    if maximumPublications.map({ published >= $0 }) == true {
                        return PendingOutcome(published: published, reviewErrors: reviewErrors)
                    }
                } catch {
                    // A stale route or legacy guest review must not starve unrelated
                    // pending jobs. Session changes and uncertain transport stop all.
                    try workflow.check()
                    let issue = error as? GoogleCalendarWorkflowError
                    guard error is GoogleCalendarStaffDeliveryError || issue == .readOnly || issue == .needsReview || issue == .invalidDates else { throw error }
                    reviewErrors.append(error.localizedDescription)
                }
            }
            offset += page.count
            if maximumPages.map({ pages >= $0 }) == true { break }
            await Task.yield()
        }
        return PendingOutcome(published: published, reviewErrors: reviewErrors)
    }

    /// The short refresh scans only durable outbound candidates. A rotating
    /// cursor also advances past stale/review-only rows and survives relaunches.
    static func backgroundCandidatePage(context: ModelContext, offset: Int, pageSize: Int = 8,
                                        now: Date = Date()) throws -> BackgroundCandidatePage {
        guard pageSize > 0 else { return BackgroundCandidatePage(calls: [], nextOffset: 0) }
        let today = Calendar.current.startOfDay(for: now)
        var descriptor = FetchDescriptor<ServiceCall>(
            predicate: #Predicate {
                $0.googleCalendarPendingAt != nil ||
                    ($0.googleEventManagedByApp && $0.googleEventConfirmedAt == nil &&
                     $0.scheduledDate >= today)
            }, sortBy: [SortDescriptor(\.scheduledDate), SortDescriptor(\.id)])
        descriptor.fetchLimit = pageSize
        var start = max(0, offset)
        descriptor.fetchOffset = start
        var calls = try context.fetch(descriptor)
        if calls.isEmpty, start > 0 {
            start = 0
            descriptor.fetchOffset = 0
            calls = try context.fetch(descriptor)
        }
        return BackgroundCandidatePage(calls: calls,
            nextOffset: calls.count < pageSize ? 0 : start + calls.count)
    }

    /// A short iOS refresh handles at most one saved outbound appointment.
    /// The original workspace/provider operation and reservation rules are the
    /// same as the foreground publisher; cancellation belongs to this task.
    static func backgroundPublishPending(auth: GoogleAuthManager, context: ModelContext,
                                         signedInEmail: String?,
                                         isExpired: @escaping () -> Bool) async -> Result<PendingOutcome, Error> {
        guard auth.googleCalendarAuthorizationState == .ready,
              hasPotentialOutboundSync(in: context) else {
            return .success(PendingOutcome(published: 0, reviewErrors: []))
        }
        do {
            guard let companyID = CompanyWorkspaceAccessController.shared.verifiedCompanyID else {
                return .failure(GoogleCalendarWorkflowError.accessDenied)
            }
            let cursorKey = "GunnAireCalendarBackgroundCursor.v1.\(companyID.uuidString)." +
                "\(AppAccess.normalizedEmail(signedInEmail)).\(AppAccess.normalizedEmail(auth.signedInEmail))"
            let startingOffset = UserDefaults.standard.integer(forKey: cursorKey)
            let workflow = try GoogleCalendarWorkflow(auth: auth, context: context,
                                                       signedInEmail: signedInEmail)
            installBackgroundExpirationFence(on: workflow, isExpired: isExpired)
            var outcome: PendingOutcome?
            let result = await workflow.run { active in
                let published = try await publishPending(workflow: active, pageSize: 8,
                                                         maximumPages: 1, maximumPublications: 1,
                                                         startingOffset: startingOffset,
                                                         backgroundCandidatesOnly: true,
                                                         onBackgroundPage: { nextOffset in
                                                             UserDefaults.standard.set(nextOffset, forKey: cursorKey)
                                                         })
                outcome = published
                return "Published \(published.published) pending calendar update(s)."
            }
            switch result {
            case .success:
                guard let outcome else { return .failure(GoogleCalendarWorkflowError.changed) }
                return .success(outcome)
            case .failure(let error):
                return .failure(error)
            }
        } catch {
            return .failure(error)
        }
    }

    static func installBackgroundExpirationFence(on workflow: GoogleCalendarWorkflow,
                                                 isExpired: @escaping () -> Bool) {
        workflow.setAdditionalValidation {
            guard !isExpired() else { throw CancellationError() }
        }
    }

    /// Read the saved route first. Only its 404 triggers a bounded same-ID
    /// search across accessible calendars. Neither result authorizes creation;
    /// Check Google Link retains the operator's guarded repair decision.
    private static func verifyConfirmedLink(call: ServiceCall, calendars: [GoogleCalendar],
                                            workflow: GoogleCalendarWorkflow) async throws -> GoogleCalendarEvent? {
        try requireCall(call, workflow: workflow)
        guard let id = normalizedOptional(call.googleEventID),
              GoogleAuthManager.calendarPathComponent(id) != nil else {
            throw GoogleCalendarWorkflowError.identity
        }
        let calendar = try canonicalCalendar(call.googleCalendarID, in: calendars, email: workflow.signedInEmail)
        let remote: GoogleCalendarEvent
        do {
            remote = try await workflow.receive {
                workflow.auth.fetchCalendarEvent(calendarID: calendar.id, eventID: id,
                    operation: workflow.operation, completion: $0)
            }
        } catch GoogleAuthError.http(statusCode: 404) {
            try requireCall(call, workflow: workflow)
            try await requireNoMovedEvent(id: id, originalCalendarID: calendar.id,
                                          calendars: calendars, workflow: workflow)
            return nil
        }
        try requireCall(call, workflow: workflow)
        try validateRemote(remote, id: id, call: call)
        guard remoteEventMatchesExactSchedule(call: call, remoteEvent: remote) else {
            throw GoogleCalendarWorkflowError.needsReview
        }
        return remote
    }

    static func deleteImmediately(call: ServiceCall, auth: GoogleAuthManager, modelContext: ModelContext,
                                  completion: @escaping (Result<String, Error>) -> Void) {
        startWorkflow(auth: auth, context: modelContext, email: AppIdentity.currentEmail, completion: completion) {
            try await remove(call: call, workflow: $0)
        }
    }

    static func validateRemoval(_ call: ServiceCall, context: ModelContext) throws {
        let calls = try context.fetch(FetchDescriptor<ServiceCall>())
        guard calls.contains(where: { $0 === call }) else { throw GoogleCalendarWorkflowError.changed }
        let id = call.id
        guard call.status == .scheduled, call.linkedInvoiceID == nil, call.linkedEstimateID == nil,
              call.maintenanceAgreementID == nil, call.originatingServiceCallID == nil,
              call.scheduledFollowUpServiceCallID == nil,
              !calls.contains(where: { $0.originatingServiceCallID == id || $0.scheduledFollowUpServiceCallID == id }),
              try !context.fetch(FetchDescriptor<Invoice>()).contains(where: { $0.serviceCallID == id }),
              try !context.fetch(FetchDescriptor<Estimate>()).contains(where: { $0.serviceCallID == id }),
              try !context.fetch(FetchDescriptor<TimeEntry>()).contains(where: { $0.serviceCall?.id == id }),
              try !context.fetch(FetchDescriptor<ServiceDocumentAttachment>()).contains(where: { $0.serviceCallID == id }),
              try !context.fetch(FetchDescriptor<InventoryMovement>()).contains(where: { $0.serviceCallID == id }),
              try !context.fetch(FetchDescriptor<PurchaseOrder>()).contains(where: { $0.serviceCallID == id }),
              try !context.fetch(FetchDescriptor<FieldFormResponse>()).contains(where: { $0.serviceCallID == id }),
              try !context.fetch(FetchDescriptor<FieldExpenseClaim>()).contains(where: { $0.serviceCallID == id }),
              try !context.fetch(FetchDescriptor<CustomerCommunication>()).contains(where: { $0.serviceCallID == id }),
              try !context.fetch(FetchDescriptor<BusinessTask>()).contains(where: { $0.serviceCallID == id }),
              try !context.fetch(FetchDescriptor<ServiceRequest>()).contains(where: { $0.convertedServiceCallID == id }),
              try !context.fetch(FetchDescriptor<RecurringMaintenanceContract>()).contains(where: { $0.lifecycle?.sourceServiceCallID == id }),
              try !context.fetch(FetchDescriptor<ServiceCallActivity>()).contains(where: { $0.serviceCallID == id }) else {
            throw GoogleCalendarWorkflowError.hasJobHistory
        }
    }

    static func removeLocalEntry(_ call: ServiceCall, context: ModelContext,
                                 save: (() throws -> Void)? = nil) throws {
        try validateRemoval(call, context: context)
        // The narrowly scoped rollback below is allowed only with no preexisting
        // unsaved work, and no await between this check, deletion and save.
        guard !context.hasChanges else { throw GoogleCalendarWorkflowError.changed }
        let calendarID = call.googleCalendarID, eventID = call.googleEventID
        context.delete(call)
        do {
            if let save { try save() } else { try context.save() }
        } catch {
            context.rollback()
            throw GoogleCalendarWorkflowError.saveFailed
        }
        markCalendarEventDeleted(calendarID: calendarID, eventID: eventID)
    }

    static func remove(call: ServiceCall, workflow: GoogleCalendarWorkflow) async throws -> String {
        try requireCall(call, workflow: workflow)
        try validateRemoval(call, context: workflow.context)
        guard !workflow.context.hasChanges else { throw GoogleCalendarWorkflowError.changed }
        workflow.setAdditionalValidation {
            try validateRemoval(call, context: workflow.context)
            guard !workflow.context.hasChanges else { throw GoogleCalendarWorkflowError.changed }
        }
        defer { workflow.setAdditionalValidation(nil) }
        guard shouldAttemptManagedCalendarDeletion(for: call), let id = normalizedOptional(call.googleEventID) else {
            throw GoogleCalendarWorkflowError.needsReview
        }
        let list = try await calendars(workflow: workflow)
        guard list.count <= 25 else { throw GoogleCalendarWorkflowError.needsReview }
        let calendar = try canonicalCalendar(call.googleCalendarID, in: list, email: workflow.signedInEmail)
        guard calendar.isWritable else { throw GoogleCalendarWorkflowError.readOnly }
        let remote: GoogleCalendarEvent?
        do {
            remote = try await workflow.receive {
                workflow.auth.fetchCalendarEvent(calendarID: calendar.id, eventID: id,
                    operation: workflow.operation, completion: $0)
            }
        } catch GoogleAuthError.http(statusCode: 404) {
            try await requireNoMovedEvent(id: id, originalCalendarID: calendar.id,
                calendars: list, workflow: workflow)
            remote = nil
        }
        if let remote {
            try validateRemote(remote, id: id, call: call)
            let version = try etag(remote)
            let _: Void = try await workflow.receive {
                workflow.auth.deleteCalendarEvent(calendarID: calendar.id, eventID: id,
                    ifMatch: version, operation: workflow.operation, completion: $0)
            }
        }
        try requireCall(call, workflow: workflow)
        workflow.setAdditionalValidation(nil)
        try removeLocalEntry(call, context: workflow.context, save: { try workflow.saveChanges() })
        return remote == nil ? "Removed the local entry. The original calendar no longer returned this event." :
            "Deleted the event from the app and its original Google Calendar."
    }

    private static func calendars(workflow: GoogleCalendarWorkflow) async throws -> [GoogleCalendar] {
        let values: [GoogleCalendar] = try await workflow.receive {
            workflow.auth.fetchCalendars(operation: workflow.operation, completion: $0)
        }
        let filtered = values.filter { !isExcludedCalendarID($0.id) }
        guard filtered.allSatisfy({ !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(filtered.map(\.id)).count == filtered.count,
              filtered.filter({ $0.primary == true }).count <= 1 else {
            throw GoogleCalendarWorkflowError.identity
        }
        return filtered
    }

    private static func requireNoMovedEvent(id: String, originalCalendarID: String,
                                            calendars: [GoogleCalendar], workflow: GoogleCalendarWorkflow) async throws {
        guard calendars.count <= 25 else { throw GoogleCalendarWorkflowError.needsReview }
        for candidate in calendars where candidate.id != originalCalendarID {
            do {
                let _: GoogleCalendarEvent = try await workflow.receive {
                    workflow.auth.fetchCalendarEvent(calendarID: candidate.id, eventID: id,
                        operation: workflow.operation, completion: $0)
                }
                throw GoogleCalendarWorkflowError.needsReview
            } catch GoogleAuthError.http(statusCode: 404) {
                continue
            } catch GoogleAuthError.http(statusCode: 403) {
                // A listed calendar may grant only free/busy access. That
                // denial cannot prove the same ID is absent there.
                throw GoogleCalendarWorkflowError.needsReview
            }
        }
    }

    private static func canonicalCalendar(_ requested: String?, in calendars: [GoogleCalendar],
                                          email: String?) throws -> GoogleCalendar {
        let requested = normalizedOptional(requested) ?? "primary"
        let normalizedRequest = normalized(requested)
        let matches: [GoogleCalendar]
        if requested == "primary" {
            let primary = calendars.filter { $0.primary == true }
            matches = primary.isEmpty ? calendars.filter { $0.normalizedID == normalized(email ?? "") } : primary
        } else {
            matches = calendars.filter {
                normalized($0.id) == normalizedRequest || normalized($0.summary ?? "") == normalizedRequest
                || $0.matchesTechnicianEmail(requested)
            }
        }
        guard matches.count == 1, let calendar = matches.first else { throw GoogleCalendarWorkflowError.readOnly }
        return calendar
    }

    static func importSchedule(workflow: GoogleCalendarWorkflow) async throws -> String {
        try await workflow.beginImportFence()
        let calendars = try await calendars(workflow: workflow)
        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now
        let end = Calendar.current.date(byAdding: .day, value: 90, to: now) ?? now
        var events: [(calendarID: String, event: GoogleCalendarEvent)] = []
        // A single retained operation covers every calendar and every page.
        // Do not enumerate "primary" again as an alias of an actual calendar.
        for calendar in calendars.sorted(by: { $0.id < $1.id }) {
            let values: [GoogleCalendarEvent] = try await workflow.receive {
                workflow.auth.fetchCalendarEvents(calendarID: calendar.id, timeMin: start, timeMax: end,
                    operation: workflow.operation, completion: $0)
            }
            events += values.map { (calendar.id, $0) }
        }
        try workflow.check()
        let primaryID = try? canonicalCalendar("primary", in: calendars, email: workflow.signedInEmail).id
        let summary = try importEvents(events, into: workflow.context,
            signedInEmail: workflow.signedInEmail, primaryCalendarID: primaryID, save: { try workflow.saveChanges() })
        let review = summary.restrictedReviewCount == 0 ? "" :
            " \(summary.restrictedReviewCount) event(s) need office review; existing jobs and restricted customers were not reassigned."
        return "Imported \(summary.importedCount) Google Calendar events. Existing job details and local schedule edits were retained.\(review)"
    }

    private static func requireCall(_ call: ServiceCall, workflow: GoogleCalendarWorkflow) throws {
        try workflow.track(call)
        guard call.customer != nil else { throw GoogleCalendarWorkflowError.identity }
    }

    private static func containsOriginalCall(_ call: ServiceCall, in context: ModelContext) throws -> Bool {
        let id = call.id
        var descriptor = FetchDescriptor<ServiceCall>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 2
        let matches = try context.fetch(descriptor)
        return matches.count == 1 && matches.first === call
    }

    static func eventID(for callID: UUID) -> String {
        "ga" + callID.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func validateRemote(_ event: GoogleCalendarEvent, id: String, call: ServiceCall) throws {
        guard event.id == id, event.status != "cancelled", event.isManagedByGunnAire else {
            throw GoogleCalendarWorkflowError.needsReview
        }
        if let marker = event.extendedProperties?.privateProperties?["gunnaireServiceCallID"] {
            guard marker == call.id.uuidString else { throw GoogleCalendarWorkflowError.identity }
        } else if id == eventID(for: call.id) {
            throw GoogleCalendarWorkflowError.identity
        }
    }

    private static func etag(_ event: GoogleCalendarEvent) throws -> String {
        guard let value = event.etag, !value.isEmpty, value != "*",
              !value.contains("\r"), !value.contains("\n") else { throw GoogleCalendarWorkflowError.needsReview }
        return value
    }

    static func publish(call: ServiceCall, workflow: GoogleCalendarWorkflow,
                        reminderWarning: ((String) -> Void)? = nil) async throws -> String {
        try requireCall(call, workflow: workflow)
        if !call.googleEventManagedByApp {
            guard isWriteBackRequested(call), canWriteBackImportedEvent(call) else {
                return "Skipped externally managed Google event."
            }
            try await adoptImportedEvent(call: call, workflow: workflow)
        }
        guard call.status == .scheduled || call.status == .inProgress,
              call.scheduledDate.timeIntervalSince1970.isFinite, call.duration.isFinite, call.duration > 0,
              call.scheduledDate.addingTimeInterval(call.duration).timeIntervalSince1970.isFinite else {
            throw GoogleCalendarWorkflowError.invalidDates
        }
        // An invalid staff contact must not suppress the organizer's event.
        // Keep the invitation work pending without claiming that guests were sent.
        let recipients: [GoogleWritableCalendarAttendee]?
        do { recipients = try staffAttendees(for: call, workflow: workflow) }
        catch GoogleCalendarStaffDeliveryError.staffEmail { recipients = nil }
        let list = try await calendars(workflow: workflow)
        let calendar = try canonicalCalendar(call.googleCalendarID, in: list, email: workflow.signedInEmail)
        guard calendar.isWritable else { throw GoogleCalendarWorkflowError.readOnly }
        try requireCall(call, workflow: workflow)
        let originalID = normalizedOptional(call.googleEventID)
        let id = originalID ?? eventID(for: call.id)
        let remote: GoogleCalendarEvent?
        do {
            remote = try await workflow.receive {
                workflow.auth.fetchCalendarEvent(calendarID: calendar.id, eventID: id,
                    operation: workflow.operation, completion: $0)
            }
        } catch GoogleAuthError.http(statusCode: 404) {
            // Only a never-linked proposal may reserve a first create. A
            // reserved/previously linked missing event is NOT safe to resend.
            guard originalID == nil else { throw GoogleCalendarWorkflowError.needsReview }
            remote = nil
        }
        try requireCall(call, workflow: workflow)
        let saved: GoogleCalendarEvent
        if let remote {
            try validateRemote(remote, id: id, call: call)
            if remoteEventMatchesExactSchedule(call: call, remoteEvent: remote) {
                saved = remote
            } else {
                // Recovery of a previously reserved create must not reprice or
                // move an older uncertain proposal from changed local values.
                if originalID == nil { throw GoogleCalendarWorkflowError.needsReview }
                // A schedule PATCH can notify every existing guest. If staff
                // assignment is invalid, we cannot safely reconcile a former
                // assignee first, and an omitted guest list is equally unsafe.
                // Leave the Google event untouched until staff can be reviewed.
                let managedGuests = remote.extendedProperties?.privateProperties?[GoogleCalendarStaffDelivery.managedEmailsKey] ?? ""
                if recipients == nil && (remote.attendeesOmitted == true ||
                    !(remote.attendees ?? []).isEmpty ||
                    !managedGuests.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    markCalendarCallLocallyEdited(call)
                    try workflow.saveChanges()
                    throw GoogleCalendarStaffDeliveryError.unsafeScheduleUpdate
                }
                let version = try etag(remote)
                saved = try await workflow.receive {
                    workflow.auth.patchCalendarEvent(calendarID: calendar.id, eventID: id,
                        patch: makeManagedEventPatch(for: call, remoteEvent: remote), ifMatch: version,
                        notifyAttendees: canNotifyStaff(remote, workflow: workflow),
                        operation: workflow.operation, completion: $0)
                }
            }
        } else {
            // Persist the exact route/identity before POST. Restart, a lost
            // response or local confirmation failure retains the original ID.
            let previousCalendar = call.googleCalendarID
            let previousConfirmation = call.googleEventConfirmedAt
            let previousPending = call.googleCalendarPendingAt
            call.googleCalendarID = calendar.id
            call.googleEventID = id
            call.googleEventConfirmedAt = nil
            call.googleCalendarPendingAt = Date()
            do { try workflow.saveChanges() }
            catch {
                call.googleCalendarID = previousCalendar
                call.googleEventID = originalID
                call.googleEventConfirmedAt = previousConfirmation
                call.googleCalendarPendingAt = previousPending
                throw error
            }
            var proposal = makeCalendarCreateEvent(for: call)
            proposal.attendees = recipients?.filter {
                $0.email != GoogleCalendarStaffDelivery.email(calendar.id)
            }
            var properties = proposal.extendedProperties?.privateProperties ?? [:]
            properties[GoogleCalendarStaffDelivery.managedEmailsKey] = (proposal.attendees ?? []).map(\.email).sorted().joined(separator: ",")
            proposal.extendedProperties = .init(privateProperties: properties)
            proposal.id = id
            let created: GoogleCalendarEvent
            do {
                created = try await workflow.receive {
                    workflow.auth.createCalendarEvent(calendarID: calendar.id, event: proposal,
                        operation: workflow.operation, completion: $0)
                }
            } catch GoogleAuthError.http(statusCode: let code) where code == 401 || code == 403 {
                // An explicit authorization denial means Google did not
                // create this event. Release only this newly reserved link so
                // reconnecting can publish it later. Transport failures and
                // ambiguous server responses keep the reservation intact.
                try workflow.check()
                guard call.googleCalendarID == calendar.id, call.googleEventID == id else {
                    throw GoogleCalendarWorkflowError.changed
                }
                call.googleCalendarID = previousCalendar
                call.googleEventID = originalID
                call.googleEventConfirmedAt = previousConfirmation
                call.googleCalendarPendingAt = previousPending
                do { try workflow.saveChanges() }
                catch {
                    call.googleCalendarID = calendar.id
                    call.googleEventID = id
                    call.googleEventConfirmedAt = nil
                    call.googleCalendarPendingAt = previousPending ?? Date()
                    throw error
                }
                throw GoogleAuthError.http(statusCode: code)
            }
            try requireCall(call, workflow: workflow)
            try validateRemote(created, id: id, call: call)
            guard remoteEventMatchesExactSchedule(call: call, remoteEvent: created) else {
                throw GoogleCalendarWorkflowError.needsReview
            }
            // A POST response is not evidence that the event is visible on
            // the selected Google calendar. Read back only the reserved ID;
            // a failed read retains it so recovery cannot create twice.
            do {
                saved = try await workflow.receive {
                    workflow.auth.fetchCalendarEvent(calendarID: calendar.id, eventID: id,
                        operation: workflow.operation, completion: $0)
                }
            } catch GoogleAuthError.http(statusCode: 404) {
                throw GoogleCalendarWorkflowError.unconfirmedReadback
            }
        }
        try requireCall(call, workflow: workflow)
        try validateRemote(saved, id: id, call: call)
        guard remoteEventMatchesExactSchedule(call: call, remoteEvent: saved) else {
            throw GoogleCalendarWorkflowError.needsReview
        }
        let delivered = recipients != nil
            ? try await deliverToStaff(call: call, remote: saved, calendarID: calendar.id, workflow: workflow)
            : saved
        if (id == eventID(for: call.id) && call.googleEventConfirmedAt == nil) ||
           replacementPopupProofRequired(call),
           !hasExplicitAppointmentPopup(delivered) {
            throw GoogleCalendarWorkflowError.alertReview(
                "The Google event exists, but its 30-minute popup reminder was not confirmed. Check the original event in Google Calendar before relying on an alert.")
        }
        try requireCall(call, workflow: workflow)
        let previousCalendar = call.googleCalendarID, previousID = call.googleEventID
        let previousConfirmation = call.googleEventConfirmedAt
        let previousPending = call.googleCalendarPendingAt
        call.googleCalendarID = calendar.id
        call.googleEventID = id
        if recipients != nil {
            call.googleEventConfirmedAt = Date()
            call.googleCalendarPendingAt = nil
        }
        else {
            let popupProofCompleted = replacementPopupProofRequired(call)
            markCalendarCallLocallyEdited(call)
            if popupProofCompleted { call.googleCalendarPendingAt = Date() }
        }
        do { try workflow.saveChanges() }
        catch {
            call.googleCalendarID = previousCalendar
            call.googleEventID = previousID
            call.googleEventConfirmedAt = previousConfirmation
            call.googleCalendarPendingAt = previousPending
            throw error
        }
        let alert = appointmentAlertGuidance(for: delivered)
        if let alert { reminderWarning?(alert) }
        let alertSuffix = alert.map { " \($0)" } ?? ""
        if recipients == nil {
            markStaffInvitationReview(for: call, workflow: workflow)
            return "Google event confirmed. Staff invitations need attention: assign every technician and crew member a unique valid calendar email, then use Sync Google.\(alertSuffix)"
        }
        clearStaffInvitationReview(for: call)
        clearCalendarCallLocallyEdited(call)
        return "Schedule confirmed in Google Calendar. Assigned staff invitations, if any, use each recipient's Google Calendar notification settings; enable this calendar and alerts in your calendar app.\(alertSuffix)"
    }

    private static func hasExplicitAppointmentPopup(_ event: GoogleCalendarEvent) -> Bool {
        guard let reminders = event.reminders, !reminders.useDefault else { return false }
        return reminders.overrides?.contains { $0.method == "popup" && $0.minutes == 30 } == true
    }

    /// Adopt only the original, explicitly edited imported event. A marker
    /// patch keeps Google's title, notes, location and existing guests intact.
    /// A lost reply can be retried against the same event ID and job marker.
    private static func adoptImportedEvent(call: ServiceCall, workflow: GoogleCalendarWorkflow) async throws {
        guard let id = normalizedOptional(call.googleEventID) else { throw GoogleCalendarWorkflowError.identity }
        let list = try await calendars(workflow: workflow)
        let calendar = try canonicalCalendar(call.googleCalendarID, in: list, email: workflow.signedInEmail)
        guard calendar.isWritable else { throw GoogleCalendarWorkflowError.readOnly }
        let remote: GoogleCalendarEvent
        do {
            remote = try await workflow.receive {
                workflow.auth.fetchCalendarEvent(calendarID: calendar.id, eventID: id,
                    operation: workflow.operation, completion: $0)
            }
        } catch GoogleAuthError.http(statusCode: 404) {
            throw GoogleCalendarWorkflowError.needsReview
        }
        try requireCall(call, workflow: workflow)
        guard remote.id == id, remote.status != "cancelled" else { throw GoogleCalendarWorkflowError.needsReview }
        var properties = remote.extendedProperties?.privateProperties ?? [:]
        if id == eventID(for: call.id), call.googleCalendarPendingAt != nil {
            // A legacy create reservation must never adopt an unrelated
            // Google event with the same ID, or move a remotely changed job
            // after a lost reply. It may only recover the exact create that
            // this appointment requested.
            guard remote.isManagedByGunnAire,
                  properties["gunnaireServiceCallID"] == call.id.uuidString,
                  remoteEventMatchesExactSchedule(call: call, remoteEvent: remote) else {
                throw GoogleCalendarWorkflowError.needsReview
            }
        }
        if let marker = properties["gunnaireServiceCallID"] {
            guard marker == call.id.uuidString else { throw GoogleCalendarWorkflowError.identity }
        } else if remote.isManagedByGunnAire {
            throw GoogleCalendarWorkflowError.identity
        }
        if !(remote.isManagedByGunnAire && properties["gunnaireServiceCallID"] == call.id.uuidString) {
            properties["gunnaireManaged"] = "true"
            properties["gunnaireManagedVersion"] = "4"
            properties["gunnaireOrigin"] = "ios-app"
            properties["gunnaireServiceCallID"] = call.id.uuidString
            var patch = GoogleCalendarStaffDeliveryPatch()
            patch.extendedProperties = .init(privateProperties: properties)
            let version = try etag(remote)
            let updated: GoogleCalendarEvent = try await workflow.receive {
                workflow.auth.patchCalendarStaffDelivery(calendarID: calendar.id, eventID: id,
                    patch: patch, ifMatch: version, operation: workflow.operation, completion: $0)
            }
            try requireCall(call, workflow: workflow)
            try validateRemote(updated, id: id, call: call)
        }
        let previousCalendar = call.googleCalendarID
        call.googleCalendarID = calendar.id
        call.googleEventManagedByApp = true
        do { try workflow.saveChanges() }
        catch {
            call.googleCalendarID = previousCalendar
            call.googleEventManagedByApp = false
            throw error
        }
        clearWriteBackRequest(call)
    }

    static func cancel(call: ServiceCall, workflow: GoogleCalendarWorkflow) async throws -> String {
        try requireCall(call, workflow: workflow)
        guard call.status == .cancelled else { throw GoogleCalendarWorkflowError.changed }
        guard shouldAttemptManagedCalendarDeletion(for: call), let id = normalizedOptional(call.googleEventID) else {
            let previousPending = call.googleCalendarPendingAt
            call.googleCalendarPendingAt = nil
            do { try workflow.saveChanges() }
            catch { call.googleCalendarPendingAt = previousPending; throw error }
            clearCalendarCallLocallyEdited(call)
            return "No app-managed Google Calendar event to cancel."
        }
        let list = try await calendars(workflow: workflow)
        guard list.count <= 25 else { throw GoogleCalendarWorkflowError.needsReview }
        let calendar = try canonicalCalendar(call.googleCalendarID, in: list, email: workflow.signedInEmail)
        guard calendar.isWritable else { throw GoogleCalendarWorkflowError.readOnly }
        let remote: GoogleCalendarEvent?
        do {
            remote = try await workflow.receive {
                workflow.auth.fetchCalendarEvent(calendarID: calendar.id, eventID: id,
                    operation: workflow.operation, completion: $0)
            }
        } catch GoogleAuthError.http(statusCode: 404) {
            // A previous DELETE may have succeeded even when its reply was
            // lost, but the same ID may have moved to another accessible route.
            // Never treat that moved event as a confirmed deletion.
            try await requireNoMovedEvent(id: id, originalCalendarID: calendar.id,
                calendars: list, workflow: workflow)
            remote = nil
        }
        try requireCall(call, workflow: workflow)
        if let remote {
            try validateRemote(remote, id: id, call: call)
            let version = try etag(remote)
            do {
                let _: Void = try await workflow.receive {
                    workflow.auth.deleteCalendarEvent(calendarID: calendar.id, eventID: id,
                        ifMatch: version, notifyAttendees: canNotifyStaff(remote, workflow: workflow),
                        operation: workflow.operation, completion: $0)
                }
            } catch GoogleAuthError.http(statusCode: 404) {
                // The exact validated event disappeared before deletion.
            }
        }
        try requireCall(call, workflow: workflow)
        let previousPending = call.googleCalendarPendingAt
        call.googleCalendarPendingAt = nil
        do { try workflow.saveChanges() }
        catch { call.googleCalendarPendingAt = previousPending; throw error }
        markCalendarEventDeleted(calendarID: calendar.id, eventID: id)
        clearCalendarCallLocallyEdited(call)
        return "Cancelled the app-managed Google Calendar event."
    }

    private static func staffAttendees(for call: ServiceCall, workflow: GoogleCalendarWorkflow) throws -> [GoogleWritableCalendarAttendee] {
        var ids = call.additionalTechnicianIDs
        if let assigned = call.assignedTechnician { ids.insert(assigned.id) }
        guard ids.count <= 26 else { throw GoogleCalendarStaffDeliveryError.staffEmail }
        var emails = Set<String>()
        return try ids.sorted(by: { $0.uuidString < $1.uuidString }).map { id in
            var descriptor = FetchDescriptor<Technician>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 2
            let matches = try workflow.context.fetch(descriptor)
            guard matches.count == 1, let technician = matches.first,
                  let email = GoogleCalendarStaffDelivery.email(technician.contactInfo), emails.insert(email).inserted else {
                throw GoogleCalendarStaffDeliveryError.staffEmail
            }
            return GoogleWritableCalendarAttendee(email: email, displayName: technician.name)
        }
    }

    private static func knownStaff(workflow: GoogleCalendarWorkflow) -> Set<String> {
        workflow.knownStaffForDelivery.union(
            [GoogleCalendarStaffDelivery.email(workflow.signedInEmail)].compactMap { $0 }
        )
    }

    private static func canNotifyStaff(_ remote: GoogleCalendarEvent, workflow: GoogleCalendarWorkflow) -> Bool {
        GoogleCalendarStaffDelivery.canNotify(remote, knownStaff: knownStaff(workflow: workflow))
    }

    private static func deliverToStaff(call: ServiceCall, remote: GoogleCalendarEvent, calendarID: String,
                                       workflow: GoogleCalendarWorkflow) async throws -> GoogleCalendarEvent {
        let desired = try staffAttendees(for: call, workflow: workflow)
            .filter { $0.email != GoogleCalendarStaffDelivery.email(calendarID) }
        guard let patch = try GoogleCalendarStaffDelivery.patch(remote: remote, desired: desired,
            knownStaff: knownStaff(workflow: workflow), restoreReminder: isCalendarCallLocallyEdited(call)) else { return remote }
        let version = try etag(remote)
        let result: GoogleCalendarEvent = try await workflow.receive {
            workflow.auth.patchCalendarStaffDelivery(calendarID: calendarID, eventID: remote.id,
                patch: patch, ifMatch: version, operation: workflow.operation, completion: $0)
        }
        try validateRemote(result, id: remote.id, call: call)
        guard remoteEventMatchesExactSchedule(call: call, remoteEvent: result),
              try GoogleCalendarStaffDelivery.patch(remote: result, desired: desired,
                  knownStaff: knownStaff(workflow: workflow), restoreReminder: isCalendarCallLocallyEdited(call)) == nil else {
            throw GoogleCalendarWorkflowError.needsReview
        }
        return result
    }

    private static func remoteEventMatchesExactSchedule(call: ServiceCall, remoteEvent: GoogleCalendarEvent) -> Bool {
        guard let start = parseEventDate(remoteEvent.start), let end = parseEventDate(remoteEvent.end) else { return false }
        return abs(start.timeIntervalSince(call.scheduledDate)) < 0.001 &&
            abs(end.timeIntervalSince(call.scheduledDate.addingTimeInterval(call.duration))) < 0.001
    }

    private struct CalendarImportPlan {
        let calendarID: String
        let event: GoogleCalendarEvent
        let existing: ServiceCall?
        let customer: Customer?
        let technician: Technician?
        let start: Date
        let duration: TimeInterval
        let notes: String?
    }

    static func importEvents(
        _ calendarEvents: [(calendarID: String, event: GoogleCalendarEvent)],
        into modelContext: ModelContext,
        signedInEmail: String?,
        primaryCalendarID: String? = nil,
        save: (() throws -> Void)? = nil
    ) throws -> ImportSummary {
        let calls = try modelContext.fetch(FetchDescriptor<ServiceCall>())
        let customers = try modelContext.fetch(FetchDescriptor<Customer>())
        let technicians = try modelContext.fetch(FetchDescriptor<Technician>())
        let locations = try modelContext.fetch(FetchDescriptor<CustomerServiceLocation>())
        let alerts = try modelContext.fetch(FetchDescriptor<CustomerOperationalAlert>())
        let placeholders = customers.filter(CustomerDataMaintenance.isSystemCalendarCustomer)
        guard placeholders.count <= 1 else { throw GoogleCalendarWorkflowError.identity }
        var placeholder = placeholders.first
        func canonicalID(_ id: String?) -> String {
            let id = normalizedOptional(id) ?? "primary"
            return id == "primary" ? primaryCalendarID ?? id : id
        }
        let linkedCalls = Dictionary(grouping: calls.filter { normalizedOptional($0.googleEventID) != nil }) {
            calendarEventStorageKey(calendarID: canonicalID($0.googleCalendarID), eventID: $0.googleEventID!)
        }
        let customersByEmail = Dictionary(grouping: customers.filter { normalizedOptional($0.email) != nil }) {
            normalized($0.email!)
        }
        let techniciansByEmail = Dictionary(grouping: technicians.filter { normalizedOptional($0.contactInfo) != nil }) {
            normalized($0.contactInfo!)
        }
        var keys: Set<String> = []
        var plans: [CalendarImportPlan] = []
        var reviews = 0
        for entry in calendarEvents {
            let event = entry.event
            let calendarID = canonicalID(entry.calendarID)
            let key = calendarEventStorageKey(calendarID: calendarID, eventID: event.id)
            guard !event.id.isEmpty, keys.insert(key).inserted else { throw GoogleCalendarWorkflowError.identity }
            guard !isCalendarEventDeleted(calendarID: calendarID, eventID: event.id) else { continue }
            guard let start = parseEventDate(event.start), let end = parseEventDate(event.end),
                  start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite,
                  end > start, event.status != "cancelled" else { reviews += 1; continue }
            let matches = linkedCalls[key] ?? []
            guard matches.count <= 1 else { throw GoogleCalendarWorkflowError.identity }
            let existing = matches.first
            if existing == nil, event.isManagedByGunnAire,
               let marker = event.extendedProperties?.privateProperties?["gunnaireServiceCallID"],
               let callID = UUID(uuidString: marker), calls.contains(where: { $0.id == callID }) {
                throw GoogleCalendarWorkflowError.needsReview
            }
            if let existing {
                // A Google refresh must not move a committed HVAC job, replace
                // its customer/crew, or erase a pending dispatcher edit.
                let protected = existing.googleEventManagedByApp ||
                    isCalendarCallLocallyEdited(existing) || existing.status != .scheduled ||
                    !CustomerDataMaintenance.isSystemCalendarCustomer(existing.customer)
                if protected {
                    if !remoteEventMatchesExactSchedule(call: existing, remoteEvent: event) ||
                        normalizedOptional(existing.eventTitle) != normalizedOptional(event.summary) ||
                        normalizedOptional(existing.siteAddress) != normalizedOptional(event.location) {
                        reviews += 1
                    }
                    continue
                }
            }
            let candidate = inferCustomer(from: event, signedInEmail: signedInEmail,
                technicianEmails: Set(techniciansByEmail.keys))
            // Names, titles and appointment times are not customer identity.
            let customerMatches = candidate?.email.flatMap { customersByEmail[normalized($0)] } ?? []
            let matched = customerMatches.count == 1 ? customerMatches.first : nil
            let locationID = matched.flatMap {
                CustomerServiceLocationPolicy.matchingLocation(address: event.location, customerID: $0.id, in: locations)?.id
            }
            let hold = matched.flatMap {
                CustomerOperationalAlertPolicy.schedulingBlocker(customerID: $0.id, serviceLocationID: locationID, in: alerts)
            }
            let assignedMatches = techniciansByEmail[normalized(calendarID)] ?? []
            let assigned = assignedMatches.count == 1 ? assignedMatches.first : nil
            let review = hold != nil || matched == nil
            if review { reviews += 1 }
            var notes = calendarNotes(description: event.description)
            if let hold {
                notes = [notes, "Office review required. " + CustomerOperationalAlertPolicy.bookingRestrictionMessage(for: hold)]
                    .compactMap { $0 }.joined(separator: "\n\n")
            }
            plans.append(CalendarImportPlan(calendarID: calendarID, event: event, existing: existing,
                customer: hold == nil ? matched : nil, technician: hold == nil ? assigned : nil,
                start: start, duration: end.timeIntervalSince(start), notes: notes))
        }

        var restorations: [() -> Void] = []
        var insertedCalls: [ServiceCall] = []
        var insertedPlaceholder: Customer?
        do {
            for plan in plans {
                let customer: Customer
                if let matched = plan.customer {
                    customer = matched
                } else if let existing = placeholder {
                    customer = existing
                } else {
                    let created = Customer(quickBooksID: CustomerDataMaintenance.unassignedCalendarCustomerMarker,
                        name: CustomerDataMaintenance.unassignedCalendarCustomerName)
                    modelContext.insert(created)
                    placeholder = created
                    insertedPlaceholder = created
                    customer = created
                }
                let call: ServiceCall
                if let existing = plan.existing {
                    call = existing
                    restorations.append(importRestoration(for: existing))
                } else {
                    call = ServiceCall(type: .service, scheduledDate: plan.start, customer: customer)
                    modelContext.insert(call)
                    insertedCalls.append(call)
                }
                call.googleCalendarID = plan.calendarID
                call.googleEventID = plan.event.id
                // A route-only manual link must not silently acquire
                // automatic publication authority during later import.
                call.googleEventManagedByApp = plan.existing == nil
                    ? plan.event.isManagedByGunnAire : call.googleEventManagedByApp
                call.eventTitle = mergedImportedCalendarTitle(remoteValue: plan.event.summary,
                    existingValue: call.eventTitle, isManagedByApp: call.googleEventManagedByApp)
                call.type = inferCallType(from: plan.event.summary, description: plan.event.description)
                call.scheduledDate = plan.start
                call.duration = plan.duration
                call.customer = customer
                call.assignedTechnician = plan.technician
                call.siteAddress = mergedImportedCalendarText(remoteValue: plan.event.location,
                    existingValue: call.siteAddress, isManagedByApp: call.googleEventManagedByApp)
                call.notes = mergedImportedCalendarBody(remoteValue: plan.notes,
                    existingValue: call.notes, isManagedByApp: call.googleEventManagedByApp)
            }
            if !plans.isEmpty {
                if let save { try save() } else { try modelContext.save() }
            }
        } catch {
            // Restore only this batch. Never roll back unrelated unsaved work.
            for restore in restorations.reversed() { restore() }
            for call in insertedCalls { modelContext.delete(call) }
            if let insertedPlaceholder { modelContext.delete(insertedPlaceholder) }
            throw GoogleCalendarWorkflowError.saveFailed
        }
        return ImportSummary(importedCount: plans.count, restrictedReviewCount: reviews)
    }

    private static func importRestoration(for call: ServiceCall) -> () -> Void {
        let calendar = call.googleCalendarID, event = call.googleEventID, managed = call.googleEventManagedByApp
        let title = call.eventTitle, type = call.type, start = call.scheduledDate, duration = call.duration
        let customer = call.customer, technician = call.assignedTechnician, site = call.siteAddress, notes = call.notes
        return {
            call.googleCalendarID = calendar; call.googleEventID = event; call.googleEventManagedByApp = managed
            call.eventTitle = title; call.type = type; call.scheduledDate = start; call.duration = duration
            call.customer = customer; call.assignedTechnician = technician; call.siteAddress = site; call.notes = notes
        }
    }

    static func shouldExportDuringCalendarSync(_ call: ServiceCall) -> Bool {
        call.status != .cancelled && shouldAllowGoogleCalendarWrite(for: call)
    }

    static func shouldAllowGoogleCalendarWrite(for call: ServiceCall) -> Bool {
        call.googleEventManagedByApp
    }

    static func isExternalGoogleCalendarEvent(_ call: ServiceCall) -> Bool {
        call.googleEventID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    static func shouldPreserveExternalGoogleCalendarDetails(for call: ServiceCall) -> Bool {
        isExternalGoogleCalendarEvent(call)
    }

    static func shouldPublishAfterLocalSave(for call: ServiceCall) -> Bool {
        shouldAllowGoogleCalendarWrite(for: call) || canWriteBackImportedEvent(call)
    }

    static func shouldCreateGoogleCalendarEvent(for call: ServiceCall) -> Bool {
        call.googleEventID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false &&
            call.googleEventManagedByApp &&
            shouldAllowGoogleCalendarWrite(for: call)
    }

    static func shouldPatchExistingGoogleCalendarEvent(for call: ServiceCall, remoteEvent: GoogleCalendarEvent?) -> Bool {
        shouldDeleteExistingGoogleCalendarEvent(
            hasGoogleEventID: call.googleEventID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            isLocallyMarkedManagedByApp: call.googleEventManagedByApp,
            remoteEvent: remoteEvent
        )
    }

    static func shouldDeleteExistingGoogleCalendarEvent(for call: ServiceCall, remoteEvent: GoogleCalendarEvent?) -> Bool {
        shouldDeleteExistingGoogleCalendarEvent(
            hasGoogleEventID: call.googleEventID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            isLocallyMarkedManagedByApp: call.googleEventManagedByApp,
            remoteEvent: remoteEvent
        )
    }

    static func shouldDeleteExistingGoogleCalendarEvent(
        hasGoogleEventID: Bool,
        isLocallyMarkedManagedByApp: Bool,
        remoteEvent: GoogleCalendarEvent?
    ) -> Bool {
        hasGoogleEventID && isLocallyMarkedManagedByApp && remoteEvent?.isManagedByGunnAire == true
    }

    static func shouldAttemptManagedCalendarDeletion(for call: ServiceCall) -> Bool {
        call.googleEventManagedByApp &&
            call.googleEventID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    static func isImportedEventManagedByApp(_ event: GoogleCalendarEvent) -> Bool {
        event.isManagedByGunnAire
    }

    static func shouldSelectGoogleCalendarBeforeCreate(for call: ServiceCall) -> Bool {
        call.googleEventID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false &&
            call.googleEventManagedByApp &&
            shouldAllowGoogleCalendarWrite(for: call)
    }

    static func makeScheduleOnlyPatch(for call: ServiceCall) -> GoogleCalendarEventPatch {
        let timeZone = TimeZone.current.identifier
        let endDate = call.scheduledDate.addingTimeInterval(call.duration)
        return GoogleCalendarEventPatch(
            start: GoogleWritableCalendarEventDate(
                dateTime: calendarDateString(call.scheduledDate),
                timeZone: timeZone
            ),
            end: GoogleWritableCalendarEventDate(
                dateTime: calendarDateString(endDate),
                timeZone: timeZone
            )
        )
    }

    static func makeManagedEventPatch(for call: ServiceCall, remoteEvent _: GoogleCalendarEvent?) -> GoogleCalendarEventPatch {
        makeScheduleOnlyPatch(for: call)
    }

    static func makeCalendarCreateEvent(for call: ServiceCall) -> GoogleWritableCalendarEvent {
        makeGoogleEvent(for: call, existingSummary: nil, preserveExternalDetails: false)
    }

    private static func makeGoogleEvent(
        for call: ServiceCall,
        existingSummary: String?,
        preserveExternalDetails: Bool
    ) -> GoogleWritableCalendarEvent {
        let timeZone = TimeZone.current.identifier
        let endDate = call.scheduledDate.addingTimeInterval(call.duration)
        let summary = calendarEventTitle(for: call, existingSummary: existingSummary)
        let eventDescription = preserveExternalDetails ? nil : calendarEventUserDescription(for: call)
        let eventLocation = preserveExternalDetails ? nil : calendarEventLocation(for: call)
        return GoogleWritableCalendarEvent(
            summary: summary,
            description: eventDescription,
            location: eventLocation,
            start: GoogleWritableCalendarEventDate(
                dateTime: calendarDateString(call.scheduledDate),
                timeZone: timeZone
            ),
            end: GoogleWritableCalendarEventDate(
                dateTime: calendarDateString(endDate),
                timeZone: timeZone
            ),
            // Dispatch is an internal staff notification. Customer messages
            // require their separate consent-aware communication workflow.
            attendees: nil,
            extendedProperties: GoogleCalendarExtendedProperties(privateProperties: [
                "gunnaireManaged": "true",
                "gunnaireManagedVersion": "4",
                "gunnaireServiceCallID": call.id.uuidString,
                "gunnaireOrigin": "ios-app"
            ]),
            reminders: .appointmentDefault
        )
    }

    private static func calendarEventTitle(for call: ServiceCall, existingSummary: String?) -> String {
        let storedTitle = normalizedOptional(call.eventTitle)
        let remoteTitle = normalizedOptional(existingSummary)
        let recoveredTitle = calendarEventSummary(from: call.notes) ?? firstMeaningfulLine(from: call.notes)
        if let storedTitle,
           isGeneratedTypeTitle(storedTitle) {
            if let remoteTitle,
               normalized(storedTitle) != normalized(remoteTitle) {
                return remoteTitle
            }
            if let recoveredTitle,
               normalized(storedTitle) != normalized(recoveredTitle) {
                return recoveredTitle
            }
        }
        return storedTitle
            ?? remoteTitle
            ?? recoveredTitle
            ?? fallbackCalendarTitle(for: call)
    }

    private static func calendarEventLocation(for call: ServiceCall) -> String? {
        normalizedOptional(call.siteAddress) ?? normalizedOptional(call.customer?.address)
    }

    private static func calendarEventUserDescription(for call: ServiceCall) -> String? {
        let arrivalWindow = call.promisedArrivalWindowSummary.map { "Customer arrival window: \($0)" }
        let parts = [normalizedOptional(call.notes), arrivalWindow]
            .compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n\n")
    }

    static func isGeneratedCalendarTitle(_ title: String) -> Bool {
        isGeneratedTypeTitle(title)
    }

    private static func isGeneratedTypeTitle(_ title: String) -> Bool {
        let value = normalized(title)
        let generatedTitles = Set(ServiceCallType.allCases.map { normalized($0.displayName) } + ["service call"])
        return generatedTitles.contains(value)
    }

    private static func fallbackCalendarTitle(for call: ServiceCall) -> String {
        // A job can arrive before its customer syncs; it then keeps the plain
        // type title rather than a placeholder name in the calendar.
        if let customer = call.customer,
           !CustomerDataMaintenance.isSystemCalendarCustomer(customer),
           call.type != .meeting,
           call.type != .reminder,
           call.type != .siteVisit,
           call.type != .other {
            return "\(call.type.displayName): \(customer.name)"
        }
        return call.type.displayName
    }

    static func remoteEventMatchesScheduleSlot(call: ServiceCall, remoteEvent: GoogleCalendarEvent) -> Bool {
        guard let remoteStart = parseEventDate(remoteEvent.start),
              let remoteEnd = parseEventDate(remoteEvent.end) else {
            return false
        }
        let callStartMinute = Int(call.scheduledDate.timeIntervalSince1970 / 60)
        let callEndMinute = Int(call.scheduledDate.addingTimeInterval(call.duration).timeIntervalSince1970 / 60)
        let remoteStartMinute = Int(remoteStart.timeIntervalSince1970 / 60)
        let remoteEndMinute = Int(remoteEnd.timeIntervalSince1970 / 60)
        return callStartMinute == remoteStartMinute && callEndMinute == remoteEndMinute
    }

    private static func resolveExistingCustomer(
        for candidate: CalendarCustomerCandidate?,
        customersByEmail: inout [String: Customer],
        customersByName: inout [String: Customer]
    ) -> Customer? {
        guard let candidate else { return nil }
        let nameKey = normalized(candidate.name)
        return candidate.email.flatMap { customersByEmail[$0] } ?? customersByName[nameKey]
    }

    private static func resolveUnassignedCalendarCustomer(
        existing: inout Customer?,
        modelContext: ModelContext
    ) -> Customer {
        if let existing {
            existing.name = CustomerDataMaintenance.unassignedCalendarCustomerName
            existing.quickBooksID = CustomerDataMaintenance.unassignedCalendarCustomerMarker
            return existing
        }
        let customer = Customer(
            quickBooksID: CustomerDataMaintenance.unassignedCalendarCustomerMarker,
            name: CustomerDataMaintenance.unassignedCalendarCustomerName
        )
        modelContext.insert(customer)
        existing = customer
        return customer
    }

    private static func calendarNotes(description: String?) -> String? {
        normalizedCalendarBody(description)
    }

    static func calendarEventSummary(from notes: String?) -> String? {
        guard let firstLine = notes?.components(separatedBy: .newlines).first,
              firstLine.localizedCaseInsensitiveCompare("Calendar event:") != .orderedSame,
              firstLine.localizedCaseInsensitiveContains("Calendar event:") else {
            return nil
        }
        let value = firstLine.replacingOccurrences(of: "Calendar event:", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func mergedImportedCalendarText(remoteValue: String?, existingValue: String?, isManagedByApp: Bool) -> String? {
        let remote = normalizedOptional(remoteValue)
        let existing = normalizedOptional(existingValue)
        if isManagedByApp {
            return remote ?? existing
        }
        return remote ?? existing
    }

    static func mergedImportedCalendarTitle(remoteValue: String?, existingValue: String?, isManagedByApp: Bool) -> String? {
        let remote = normalizedOptional(remoteValue)
        let existing = normalizedOptional(existingValue)
        if isManagedByApp {
            return remote
        }
        guard let remote else { return existing }
        if let existing,
           !isGeneratedTypeTitle(existing),
           isGeneratedTypeTitle(remote) {
            return existing
        }
        return remote
    }

    static func mergedImportedCalendarBody(remoteValue: String?, existingValue: String?, isManagedByApp: Bool) -> String? {
        let remote = normalizedOptional(remoteValue)
        let existing = normalizedOptional(existingValue)
        if isManagedByApp {
            return remote ?? existing
        }
        guard let remote else { return existing }
        if let existing,
           !isGeneratedGunnAireCalendarBody(existing),
           isGeneratedGunnAireCalendarBody(remote) {
            return existing
        }
        return remote
    }

    private static func isGeneratedGunnAireCalendarBody(_ value: String) -> Bool {
        let lines = value
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        let generatedPrefixes = [
            "customer:",
            "phone:",
            "email:",
            "service address:",
            "call type:",
            "technician:",
            "equipment:",
            "equipment location:"
        ]
        let generatedLineCount = lines.filter { line in
            generatedPrefixes.contains { line.hasPrefix($0) }
        }.count
        return generatedLineCount >= 2 || lines.first?.hasPrefix("call type:") == true
    }

    private static func firstMeaningfulLine(from notes: String?) -> String? {
        guard let notes else { return nil }
        let ignoredPrefixes = ["calendar event:", "scheduled from", "scheduled follow-up"]
        return notes
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { line in
                guard !line.isEmpty else { return false }
                let lowercased = line.lowercased()
                return !ignoredPrefixes.contains { lowercased.hasPrefix($0) }
            }
    }

    private static func eventFingerprint(
        summary: String?,
        location: String?,
        startDate: Date,
        endDate: Date
    ) -> String {
        [
            normalized(summary ?? ""),
            normalized(location ?? ""),
            String(Int(startDate.timeIntervalSince1970 / 60)),
            String(Int(endDate.timeIntervalSince1970 / 60))
        ].joined(separator: "|")
    }

    private static func eventCollisionKey(for call: ServiceCall) -> String {
        eventCollisionKey(
            summary: calendarEventTitle(for: call, existingSummary: nil),
            startDate: call.scheduledDate,
            endDate: call.scheduledDate.addingTimeInterval(call.duration)
        )
    }

    private static func eventCollisionKey(
        summary: String?,
        startDate: Date,
        endDate: Date
    ) -> String {
        [
            normalized(summary ?? ""),
            String(Int(startDate.timeIntervalSince1970 / 60)),
            String(Int(endDate.timeIntervalSince1970 / 60))
        ].joined(separator: "|")
    }

    private static func calendarDateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        if date.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) != 0 {
            formatter.formatOptions.insert(.withFractionalSeconds)
        }
        return formatter.string(from: date)
    }

    private static func parseEventDate(_ value: GoogleCalendarEventDate) -> Date? {
        if let dateTime = value.dateTime {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions.insert(.withFractionalSeconds)
            return fractional.date(from: dateTime) ?? ISO8601DateFormatter().date(from: dateTime)
        }
        if let date = value.date {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: date)
        }
        return nil
    }

    private struct CalendarCustomerCandidate {
        let name: String
        let email: String?
        let address: String?
    }

    private static func inferCustomer(
        from event: GoogleCalendarEvent,
        signedInEmail: String?,
        technicianEmails: Set<String>
    ) -> CalendarCustomerCandidate? {
        let normalizedSignedInEmail = signedInEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let excludedEmails = technicianEmails.union([normalizedSignedInEmail].compactMap { $0 })
        if let attendee = event.attendees?.first(where: { attendee in
            guard attendee.selfAttendee != true,
                  attendee.resource != true,
                  let email = attendee.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !email.isEmpty,
                  !excludedEmails.contains(email),
                  !email.contains("calendar.google.com"),
                  !email.hasSuffix("@resource.calendar.google.com") else {
                return false
            }
            return true
        }) {
            let email = attendee.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let displayName = cleanCustomerName(attendee.displayName, eventSummary: event.summary)
            let fallbackName = email.map(nameFromEmail) ?? "Google Calendar Customer"
            return CalendarCustomerCandidate(
                name: displayName ?? fallbackName,
                email: email,
                address: normalizedOptional(event.location)
            )
        }

        return inferCustomerFromDescription(
            event.description,
            eventSummary: event.summary,
            address: normalizedOptional(event.location)
        )
    }

    private static func nameFromEmail(_ email: String) -> String {
        let localPart = email.components(separatedBy: "@").first ?? email
        let separators = CharacterSet(charactersIn: "._-+")
        let words = localPart
            .components(separatedBy: separators)
            .filter { !$0.isEmpty && !$0.allSatisfy(\.isNumber) }
        return words.isEmpty ? email : words.joined(separator: " ").capitalized
    }

    private static func inferCustomerFromDescription(_ description: String?, eventSummary: String?, address: String?) -> CalendarCustomerCandidate? {
        guard let body = normalizedCalendarBody(description) else { return nil }
        let email = firstEmail(in: body)
        let labeledName = cleanCustomerName(firstLabeledValue(
            in: body,
            labels: ["customer", "customer name", "client", "client name", "name"]
        ), eventSummary: eventSummary)
        let name = labeledName ?? email.map(nameFromEmail)
        guard let name, !name.isEmpty else { return nil }
        return CalendarCustomerCandidate(
            name: name,
            email: email,
            address: address ?? firstLabeledValue(in: body, labels: ["address", "service address", "location"])
        )
    }

    private static func normalizedCalendarBody(_ value: String?) -> String? {
        guard let value else { return nil }
        let withoutBreaks = value
            .replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<br/>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<br />", with: "\n", options: .caseInsensitive)
        let withoutTags = withoutBreaks.replacingOccurrences(
            of: "<[^>]+>",
            with: " ",
            options: .regularExpression
        )
        let decoded = withoutTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func cleanCustomerName(_ value: String?, eventSummary: String?) -> String? {
        guard let trimmed = normalizedOptional(value),
              !isGenericCustomerName(trimmed, matching: eventSummary) else {
            return nil
        }
        return trimmed
    }

    private static func isGenericCustomerName(_ value: String, matching eventSummary: String?) -> Bool {
        let name = normalized(value)
        guard !name.isEmpty else { return true }
        if let eventSummary, normalized(eventSummary) == name {
            return true
        }

        let genericTitles: Set<String> = [
            "service",
            "service call",
            "install",
            "installation",
            "maintenance",
            "maintenance call",
            "repair",
            "estimate",
            "quote",
            "job",
            "appointment",
            "site visit",
            "tune up",
            "no heat",
            "no cool",
            "ac call",
            "hvac service"
        ]
        return genericTitles.contains(name)
    }

    private static func firstLabeledValue(in body: String, labels: [String]) -> String? {
        let lines = body
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for line in lines {
            guard let separator = line.firstIndex(where: { $0 == ":" || $0 == "-" }) else { continue }
            let label = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard labels.contains(label) else { continue }
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func firstEmail(in body: String) -> String? {
        let pattern = #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#
        guard let range = body.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        return String(body[range]).lowercased()
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func inferCallType(from summary: String?, description: String?) -> ServiceCallType {
        let haystack = [summary, description].compactMap { $0?.lowercased() }.joined(separator: " ")
        if haystack.contains("estimate") { return .estimate }
        if haystack.contains("meeting") { return .meeting }
        if haystack.contains("reminder") || haystack.contains("due date") || haystack.contains("deadline") || haystack.contains("holiday") { return .reminder }
        if haystack.contains("site visit") || haystack.contains("walkthrough") || haystack.contains("walk through") { return .siteVisit }
        if haystack.contains("install") { return .install }
        if haystack.contains("maintenance") { return .maintenance }
        if haystack.contains("service") || haystack.contains("repair") || haystack.contains("no heat") || haystack.contains("no cool") || haystack.contains("hvac") {
            return .service
        }
        return .other
    }

    private static func resolveTechnician(
        calendarID: String? = nil,
        signedInEmail: String?,
        techniciansByEmail: inout [String: Technician],
        modelContext: ModelContext
    ) -> Technician? {
        if let calendarID,
           calendarID != "primary",
           calendarID.contains("@") {
            let normalizedCalendarID = calendarID.lowercased()
            if let existing = techniciansByEmail[normalizedCalendarID] {
                return existing
            }
            let inferredName = normalizedCalendarID.components(separatedBy: "@").first?
                .replacingOccurrences(of: ".", with: " ")
                .capitalized ?? normalizedCalendarID
            let technician = Technician(name: inferredName, contactInfo: normalizedCalendarID)
            modelContext.insert(technician)
            techniciansByEmail[normalizedCalendarID] = technician
            return technician
        }
        guard let signedInEmail, !signedInEmail.isEmpty else { return nil }
        if let existing = techniciansByEmail[signedInEmail.lowercased()] {
            return existing
        }
        let inferredName = signedInEmail.components(separatedBy: "@").first?
            .replacingOccurrences(of: ".", with: " ")
            .capitalized ?? signedInEmail
        let technician = Technician(name: inferredName, contactInfo: signedInEmail)
        modelContext.insert(technician)
        techniciansByEmail[signedInEmail.lowercased()] = technician
        return technician
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func preferredCalendarID(
        for call: ServiceCall,
        availableCalendarIDs: Set<String>,
        writableCalendarIDs: Set<String>
    ) -> String? {
        if let existingCalendarID = normalizedOptional(call.googleCalendarID) {
            return contains(existingCalendarID, in: writableCalendarIDs) ? existingCalendarID : nil
        }
        if let technicianCalendarID = call.assignedTechnician?.contactInfo?.trimmingCharacters(in: .whitespacesAndNewlines),
           !technicianCalendarID.isEmpty {
            if contains(technicianCalendarID, in: writableCalendarIDs) {
                return technicianCalendarID
            }
            if contains(technicianCalendarID.lowercased(), in: writableCalendarIDs) {
                return technicianCalendarID.lowercased()
            }
        }
        if contains("primary", in: writableCalendarIDs) {
            return "primary"
        }
        return nil
    }

    private static func isExcludedCalendarID(_ id: String) -> Bool {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Common Google holiday calendars end with or contain "holiday@group.v.calendar.google.com".
        if normalizedID.contains("#holiday@group.v.calendar.google.com") { return true }
        if normalizedID.contains("holiday@group.v.calendar.google.com") { return true }
        // Exclude Contacts/Birthdays calendar as well.
        if normalizedID.contains("addressbook#contacts@group.v.calendar.google.com") { return true }
        return false
    }

    private static func contains(_ calendarID: String, in calendarIDs: Set<String>) -> Bool {
        calendarIDs.contains(calendarID) || calendarIDs.contains(calendarID.lowercased())
    }

}
