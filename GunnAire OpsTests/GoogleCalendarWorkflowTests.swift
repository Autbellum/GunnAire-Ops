import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor
@Suite(.serialized)
struct GoogleCalendarWorkflowTests {
    @MainActor private final class Fixture {
        let email = "calendar-fixture@gunnaire.com"
        let context: ModelContext
        let customer: Customer
        let call: ServiceCall
        var requests: [URLRequest] = []
        var remote: [String: [String: Any]] = [:]
        var calendarList: [[String: Any]] = []
        var authorized = true
        var failPatch = false
        var rejectedCreateStatus: Int?
        var deniedEventCalendarID: String?
        var createdEventReadbackStatus: Int?
        var inspectionNextPageToken: String?
        var inspectionCalendarListNextPageToken: String?
        var excludedWindowCalendarIDs: Set<String> = []
        var beforeReply: ((URLRequest) async throws -> Void)?
        var afterWrite: ((URLRequest) throws -> Void)?
        lazy var auth = GoogleAuthManager(testTokens: .init(accessToken: "fixture-only",
            refreshToken: nil, idToken: nil, expiration: .distantFuture,
            scopeSignature: Config.Google.scopeSignature(for: [Config.Google.calendarScope])), email: email,
            businessEmail: { self.email }) { [unowned self] request in
                self.requests.append(request)
                try await self.beforeReply?(request)
                return try self.reply(request)
            }

        init(linked: Bool = false) throws {
            // Every fixture models a fresh synthetic Google calendar. Earlier
            // cancellation tests must not suppress a later fixture's pending job.
            let deletedKey = "GunnAireDeletedGoogleCalendarEventKeys"
            let fixtureKeys: Set<String> = ["calendar-fixture@gunnaire.com|fixture-event", "primary|fixture-event"]
            UserDefaults.standard.set((UserDefaults.standard.stringArray(forKey: deletedKey) ?? [])
                .filter { !fixtureKeys.contains($0) }, forKey: deletedKey)
            let schema = GunnAireModelSchema.schema
            context = ModelContext(try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            ]))
            customer = Customer(name: "Fixture customer", email: "customer@example.invalid", address: "Local service address")
            call = ServiceCall(googleCalendarID: "primary", googleEventID: linked ? "fixture-event" : nil,
                googleEventConfirmedAt: linked ? Date(timeIntervalSince1970: 1_799_000_000) : nil,
                googleEventManagedByApp: true, eventTitle: "Repair visit", type: .repair,
                scheduledDate: Date(timeIntervalSince1970: 1_800_000_000), duration: 3600,
                customer: customer, notes: "Saved field observations")
            context.insert(customer); context.insert(call)
            try context.save()
            calendarList = [["id": email, "primary": true, "accessRole": "owner"]]
            if linked { remote[key(email, "fixture-event")] = event(id: "fixture-event") }
        }

        func flow(scope: [ServiceCall]? = nil,
                  save: @escaping (ModelContext) throws -> Void = { try $0.save() }) throws -> GoogleCalendarWorkflow {
            try GoogleCalendarWorkflow(auth: auth, context: context, signedInEmail: email, scope: scope,
                validateAccess: { if !self.authorized { throw GoogleCalendarWorkflowError.accessDenied } }, save: save)
        }

        func publish(save: @escaping (ModelContext) throws -> Void = { try $0.save() }) async throws -> Result<String, Error> {
            await (try flow(save: save)).run { try await GoogleCalendarScheduleSync.publish(call: self.call, workflow: $0) }
        }

        func sync() async throws -> Result<String, Error> {
            await (try flow()).run { try await GoogleCalendarScheduleSync.importSchedule(workflow: $0) }
        }

        func key(_ calendar: String, _ id: String) -> String { calendar + "|" + id }
        var writes: [URLRequest] { requests.filter { $0.httpMethod != "GET" } }
        var staffInvitationsNeedAttention: Bool {
            GoogleCalendarScheduleSync.staffInvitationsNeedAttention(for: call,
                connectedGoogleEmail: auth.signedInEmail, workspaceEmail: email)
        }
        func loseDeviceLocalCalendarMarkers() {
            UserDefaults.standard.removeObject(forKey: "GunnAireLocallyEditedGoogleCalendarCallIDs")
            UserDefaults.standard.removeObject(forKey: "GunnAireGoogleCalendarStaffInvitationReview")
        }
        func event(id: String, start: Date? = nil, managed: Bool = true) -> [String: Any] {
            let start = start ?? call.scheduledDate
            var value: [String: Any] = [
                "id": id, "etag": "\"version-1\"", "status": "confirmed", "summary": "Repair visit",
                "location": "Google location", "description": "Google notes",
                "start": ["dateTime": ISO8601DateFormatter().string(from: start), "timeZone": "UTC"],
                "end": ["dateTime": ISO8601DateFormatter().string(from: start.addingTimeInterval(3600)), "timeZone": "UTC"]
            ]
            if managed {
                value["extendedProperties"] = ["private": [
                    "gunnaireManaged": "true", "gunnaireManagedVersion": "4", "gunnaireOrigin": "ios-app",
                    "gunnaireServiceCallID": call.id.uuidString
                ]]
            }
            return value
        }

        func decoded(_ value: [String: Any]) throws -> GoogleCalendarEvent {
            try JSONDecoder().decode(GoogleCalendarEvent.self, from: JSONSerialization.data(withJSONObject: value))
        }

        func reply(_ request: URLRequest) throws -> (Data, URLResponse) {
            let path = request.url!.path
            let parts = path.components(separatedBy: "/")
            let calendar = parts.count > 4 ? parts[4] : ""
            let id = parts.last ?? ""
            var status = 200
            var payload: [String: Any] = [:]
            if path.hasSuffix("/calendarList") {
                payload = ["items": calendarList]
                if request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) })?.queryItems?
                    .contains(where: { $0.name == "maxResults" && $0.value == "25" }) == true,
                   let inspectionCalendarListNextPageToken {
                    payload["nextPageToken"] = inspectionCalendarListNextPageToken
                }
            } else if request.httpMethod == "GET" && path.hasSuffix("/events") {
                payload = ["items": excludedWindowCalendarIDs.contains(calendar) ? [] :
                    remote.filter { $0.key.hasPrefix(calendar + "|") }.map(\.value)]
                if request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) })?.queryItems?
                    .contains(where: { $0.name == "maxResults" && $0.value == "100" }) == true,
                   let inspectionNextPageToken {
                    payload["nextPageToken"] = inspectionNextPageToken
                }
            } else if request.httpMethod == "GET" {
                if remote[key(calendar, id)] != nil,
                   requests.contains(where: { $0.httpMethod == "POST" }),
                   let createdEventReadbackStatus { status = createdEventReadbackStatus }
                else if calendar == deniedEventCalendarID { status = 403 }
                else if let existing = remote[key(calendar, id)] { payload = existing }
                else { status = 404 }
            } else if request.httpMethod == "POST" {
                payload = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
                let createdID = try #require(payload["id"] as? String)
                if let rejectedCreateStatus {
                    status = rejectedCreateStatus
                    payload = ["error": ["code": rejectedCreateStatus,
                                         "message": "Calendar permission rejected by Google"]]
                }
                else if remote[key(calendar, createdID)] != nil { status = 409 }
                else {
                    payload["etag"] = "\"version-created\""
                    remote[key(calendar, createdID)] = payload
                    try afterWrite?(request)
                }
            } else if request.httpMethod == "PATCH" {
                payload = try #require(remote[key(calendar, id)])
                if failPatch || request.value(forHTTPHeaderField: "If-Match") != payload["etag"] as? String {
                    status = 412
                } else {
                    let patch = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
                    for (field, value) in patch { payload[field] = value }
                    payload["etag"] = "\"version-updated\""
                    remote[key(calendar, id)] = payload
                    try afterWrite?(request)
                }
            } else if request.httpMethod == "DELETE" {
                let existing = try #require(remote[key(calendar, id)])
                if request.value(forHTTPHeaderField: "If-Match") != existing["etag"] as? String { status = 412 }
                else { remote.removeValue(forKey: key(calendar, id)); status = 204; try afterWrite?(request) }
            } else { Issue.record("Unexpected calendar fixture request"); status = 500 }
            return (try JSONSerialization.data(withJSONObject: payload),
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func failed(_ result: Result<String, Error>) {
        if case .success(let value) = result { Issue.record("Unexpected success: \(value)") }
    }

    @Test func bidirectionalSyncPublishesUpcomingOwnedJobBeforeImport() async throws {
        let f = try Fixture()
        f.call.scheduledDate = Date().addingTimeInterval(3600)
        try f.context.save()
        let result = await (try f.flow()).run { try await GoogleCalendarScheduleSync.synchronize(workflow: $0) }
        #expect(try result.get().contains("Published 1"))
        #expect(try !result.get().contains("Review Google publication"))
        #expect(f.writes.count == 1)
        #expect(!GoogleCalendarScheduleSync.needsOutboundSync(f.call))
        _ = try await (try f.flow()).run { try await GoogleCalendarScheduleSync.synchronize(workflow: $0) }.get()
        #expect(f.writes.count == 1)
    }

    @Test(arguments: [false, true])
    func pendingCustomerDoesNotBlockOtherCalendarJobsAndRecoversOnce(backgroundOnly: Bool) async throws {
        let f = try Fixture()
        f.call.scheduledDate = Date().addingTimeInterval(7200)
        let pendingAt = Date()
        let incomplete = ServiceCall(googleCalendarID: "primary", googleEventManagedByApp: true,
            eventTitle: "Waiting for customer", type: .repair,
            scheduledDate: f.call.scheduledDate.addingTimeInterval(-3600), duration: 3600,
            customer: f.customer)
        f.context.insert(incomplete)
        incomplete.customer = nil
        incomplete.googleCalendarPendingAt = pendingAt
        try f.context.save()

        let first = try await (try f.flow()).run {
            let outcome = try await GoogleCalendarScheduleSync.publishPending(workflow: $0,
                pageSize: 2, maximumPages: backgroundOnly ? 1 : nil,
                maximumPublications: backgroundOnly ? 1 : nil,
                backgroundCandidatesOnly: backgroundOnly)
            #expect(outcome.published == 1)
            #expect(outcome.reviewErrors.count == 1)
            #expect(outcome.reviewErrors.first?.contains("customer") == true)
            return "First batch completed"
        }.get()
        #expect(first == "First batch completed")
        #expect(incomplete.customer == nil)
        #expect(incomplete.googleCalendarPendingAt == pendingAt)
        #expect(incomplete.googleEventID == nil)
        #expect(incomplete.googleEventConfirmedAt == nil)
        #expect(f.call.googleEventConfirmedAt != nil)
        #expect(f.writes.filter { $0.httpMethod == "POST" }.count == 1)
        #expect(f.remote[f.key(f.email, GoogleCalendarScheduleSync.eventID(for: incomplete.id))] == nil)

        incomplete.customer = f.customer
        try f.context.save()
        for expectedPublications in [1, 0] {
            _ = try await (try f.flow()).run {
                let outcome = try await GoogleCalendarScheduleSync.publishPending(workflow: $0,
                    pageSize: 2, maximumPages: backgroundOnly ? 1 : nil,
                    maximumPublications: backgroundOnly ? 1 : nil,
                    backgroundCandidatesOnly: backgroundOnly)
                #expect(outcome.published == expectedPublications)
                #expect(outcome.reviewErrors.isEmpty)
                return "Recovery completed"
            }.get()
        }
        #expect(incomplete.googleEventConfirmedAt != nil)
        #expect(incomplete.googleCalendarPendingAt == nil)
        #expect(incomplete.googleEventID == GoogleCalendarScheduleSync.eventID(for: incomplete.id))
        #expect(f.writes.filter { $0.httpMethod == "POST" }.count == 2)
    }

    @Test func directCalendarPublicationStillRejectsAnUnresolvedCustomerBeforeRequests() async throws {
        let f = try Fixture()
        f.call.customer = nil
        try f.context.save()
        let result = try await f.publish()
        switch result {
        case .success:
            Issue.record("An incomplete appointment must not be sent to Google.")
        case .failure(let error):
            #expect(error as? GoogleCalendarWorkflowError == .identity)
        }
        #expect(f.requests.isEmpty)
        #expect(f.call.googleEventID == nil)
        #expect(f.call.googleEventConfirmedAt == nil)
    }

    @Test func verifiedWritableSelectionPublishesOnThatCalendarWithoutPrimaryRetarget() async throws {
        let f = try Fixture()
        var primary = GoogleCalendar(id: f.email, summary: "Owner", timeZone: nil, accessRole: "reader")
        primary.primary = true
        let writable = GoogleCalendar(id: "dispatch@group.calendar.google.com", summary: "Dispatch",
                                      timeZone: nil, accessRole: "writer")
        let calendars = [primary, writable]
        #expect(ServiceCalendarRouting.validSelection("primary", technician: nil, calendars: calendars) == nil)
        #expect(ServiceCalendarRouting.routeIssue(
            selectedCalendarID: "primary", calendars: calendars, verified: true
        ) != nil)
        let selected = try #require(ServiceCalendarRouting.validSelection(
            writable.id, technician: nil, calendars: calendars
        ))
        f.calendarList = [
            ["id": primary.id, "primary": true, "accessRole": "reader"],
            ["id": writable.id, "accessRole": "writer"]
        ]
        f.call.googleCalendarID = selected
        try ServiceCallCalendarOutbox.save(f.call) { try f.context.save() }

        let result = await (try f.flow()).run { try await GoogleCalendarScheduleSync.synchronize(workflow: $0) }
        #expect(try result.get().contains("Published 1"))
        let posts = f.writes.filter { $0.httpMethod == "POST" }
        #expect(posts.count == 1)
        #expect(posts.first?.url?.path.contains("/calendars/\(writable.id)/events") == true)
        #expect(f.call.googleCalendarID == writable.id)
        #expect(f.call.googleEventConfirmedAt != nil)
        #expect(f.call.googleCalendarPendingAt == nil)
    }

    @Test func durablePendingMarkerPublishesBackdatedRequestOnce() async throws {
        let f = try Fixture()
        f.call.scheduledDate = try #require(Calendar.current.date(
            byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date())))
        f.call.googleCalendarPendingAt = Date()
        try f.context.save()

        #expect(GoogleCalendarScheduleSync.needsOutboundSync(f.call))
        #expect(!ScheduleGoogleLinkStatus.needsUnlinkedReview(f.call))
        let first = await (try f.flow()).run { try await GoogleCalendarScheduleSync.synchronize(workflow: $0) }
        #expect(try first.get().contains("Published 1"))
        #expect(f.writes.filter { $0.httpMethod == "POST" }.count == 1)
        #expect(f.call.googleEventID != nil)
        #expect(f.call.googleEventConfirmedAt != nil)
        #expect(f.call.googleCalendarPendingAt == nil)

        _ = try await (try f.flow()).run { try await GoogleCalendarScheduleSync.synchronize(workflow: $0) }.get()
        #expect(f.writes.filter { $0.httpMethod == "POST" }.count == 1)
    }

    @Test func firstLocalSaveRetainsBackdatedCalendarOutboxAfterContextRestart() async throws {
        let f = try Fixture()
        f.call.scheduledDate = try #require(Calendar.current.date(
            byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date())))
        try ServiceCallCalendarOutbox.save(f.call) { try f.context.save() }
        f.loseDeviceLocalCalendarMarkers()

        let resumedContext = ModelContext(f.context.container)
        let callID = f.call.id
        let resumed = try #require(resumedContext.fetch(FetchDescriptor<ServiceCall>(
            predicate: #Predicate { $0.id == callID })).first)
        #expect(resumed.googleCalendarPendingAt != nil)
        #expect(GoogleCalendarScheduleSync.needsOutboundSync(resumed))
        let workflow = try GoogleCalendarWorkflow(auth: f.auth, context: resumedContext,
            signedInEmail: f.email, validateAccess: {})
        _ = try await workflow.run { try await GoogleCalendarScheduleSync.synchronize(workflow: $0) }.get()
        #expect(f.writes.filter { $0.httpMethod == "POST" }.count == 1)
    }

    @Test func retryProbeFindsSavedPendingAndUpcomingUnconfirmedJobs() throws {
        let f = try Fixture(linked: true)
        #expect(!GoogleCalendarScheduleSync.hasPotentialOutboundSync(in: f.context))

        f.call.googleEventManagedByApp = false
        f.call.googleCalendarPendingAt = Date()
        try f.context.save()
        #expect(GoogleCalendarScheduleSync.hasPotentialOutboundSync(in: f.context))

        f.call.googleCalendarPendingAt = nil
        f.call.googleEventManagedByApp = true
        f.call.googleEventConfirmedAt = nil
        try f.context.save()
        #expect(GoogleCalendarScheduleSync.hasPotentialOutboundSync(in: f.context))

        f.call.googleEventConfirmedAt = Date()
        try f.context.save()
        #expect(!GoogleCalendarScheduleSync.hasPotentialOutboundSync(in: f.context))
    }

    @Test func failedAutomaticRecoveryRetriesOnlySavedPendingCalendarWork() throws {
        let fixture = try Fixture(linked: true)
        let failed: Result<Void, Error> = .failure(GoogleCalendarWorkflowError.unconfirmedWrite)
        let succeeded: Result<Void, Error> = .success(())

        fixture.call.googleEventConfirmedAt = nil
        fixture.call.googleCalendarPendingAt = Date()
        try fixture.context.save()
        #expect(AutomaticOutboundSync.calendarRecoveryFollowUp(
            result: failed, queued: false,
            hasPendingOutbound: GoogleCalendarScheduleSync.hasPotentialOutboundSync(in: fixture.context)) == .retryPending)

        fixture.call.googleEventConfirmedAt = Date()
        fixture.call.googleCalendarPendingAt = nil
        try fixture.context.save()
        #expect(AutomaticOutboundSync.calendarRecoveryFollowUp(
            result: failed, queued: false,
            hasPendingOutbound: GoogleCalendarScheduleSync.hasPotentialOutboundSync(in: fixture.context)) == .none)
        #expect(AutomaticOutboundSync.calendarRecoveryFollowUp(
            result: succeeded, queued: false, hasPendingOutbound: true) == .none)
        #expect(AutomaticOutboundSync.calendarRecoveryFollowUp(
            result: failed, queued: true, hasPendingOutbound: true) == .queuedPass)
        #expect(AutomaticOutboundSync.calendarRecoveryFollowUp(
            result: succeeded, queued: true, hasPendingOutbound: false) == .queuedPass)
    }

    @Test func scheduleReconnectWakeRequiresActiveAuthorizedDispatcher() throws {
        let f = try Fixture()
        f.call.googleCalendarPendingAt = Date()
        try f.context.save()
        #expect(GoogleCalendarScheduleSync.hasPotentialOutboundSync(in: f.context))

        let mayWake = ScheduleGoogleLinkStatus.shouldWakePendingCalendar
        #expect(mayWake(true, true, .ready))
        #expect(!mayWake(false, true, .ready))
        #expect(!mayWake(true, false, .ready))
        #expect(!mayWake(true, true, .disconnected))
        #expect(!mayWake(true, true, .businessAccountMismatch))
        #expect(!mayWake(true, true, .reauthorizationRequired))
    }

    @Test func firstLocalSaveRetainsLinkedEditAfterContextRestart() async throws {
        let f = try Fixture(linked: true)
        let originalID = try #require(f.call.googleEventID)
        f.call.scheduledDate = f.call.scheduledDate.addingTimeInterval(3_600)
        try ServiceCallCalendarOutbox.save(f.call) { try f.context.save() }
        f.loseDeviceLocalCalendarMarkers()

        let resumedContext = ModelContext(f.context.container)
        let callID = f.call.id
        let resumed = try #require(resumedContext.fetch(FetchDescriptor<ServiceCall>(
            predicate: #Predicate { $0.id == callID })).first)
        #expect(resumed.googleEventID == originalID)
        #expect(resumed.googleEventConfirmedAt == nil)
        #expect(GoogleCalendarScheduleSync.needsOutboundSync(resumed))
        let workflow = try GoogleCalendarWorkflow(auth: f.auth, context: resumedContext,
            signedInEmail: f.email, validateAccess: {})
        _ = try await workflow.run { try await GoogleCalendarScheduleSync.synchronize(workflow: $0) }.get()
        #expect(f.writes.filter { $0.httpMethod == "POST" }.isEmpty)
        #expect(f.writes.contains { $0.httpMethod == "PATCH" })
        let remote = try #require(f.remote[f.key(f.email, originalID)])
        let remoteStart = try #require(remote["start"] as? [String: String])
        #expect(remoteStart["dateTime"] == ISO8601DateFormatter().string(from: resumed.scheduledDate))
        #expect(resumed.googleEventID == originalID)
    }

    @Test func failedLocalSaveRestoresCalendarProofWithoutDeviceMarker() throws {
        let f = try Fixture(linked: true)
        let previousConfirmation = f.call.googleEventConfirmedAt
        let previousPending = f.call.googleCalendarPendingAt
        struct SaveRejected: Error {}
        do {
            try ServiceCallCalendarOutbox.save(f.call) { throw SaveRejected() }
            Issue.record("The local save should have failed")
        } catch is SaveRejected {
            // The helper restores the exact prior proof on a failed save.
        }

        #expect(f.call.googleEventConfirmedAt == previousConfirmation)
        #expect(f.call.googleCalendarPendingAt == previousPending)
        #expect(!(UserDefaults.standard.stringArray(forKey: "GunnAireLocallyEditedGoogleCalendarCallIDs") ?? [])
            .contains(f.call.id.uuidString))
        #expect(!GoogleCalendarScheduleSync.needsOutboundSync(f.call))
        let resumedContext = ModelContext(f.context.container)
        let callID = f.call.id
        let resumed = try #require(resumedContext.fetch(FetchDescriptor<ServiceCall>(
            predicate: #Predicate { $0.id == callID })).first)
        #expect(resumed.googleEventConfirmedAt == previousConfirmation)
        #expect(resumed.googleCalendarPendingAt == previousPending)
    }

    @Test func backdatedUnmarkedJobIsNotAutomaticallyPublished() async throws {
        let f = try Fixture()
        f.call.scheduledDate = try #require(Calendar.current.date(
            byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date())))
        try f.context.save()

        #expect(!GoogleCalendarScheduleSync.needsOutboundSync(f.call))
        #expect(ScheduleGoogleLinkStatus.needsUnlinkedReview(f.call))
        _ = try await (try f.flow()).run { try await GoogleCalendarScheduleSync.synchronize(workflow: $0) }.get()
        #expect(f.writes.isEmpty)
        f.call.googleEventManagedByApp = false
        #expect(ScheduleGoogleLinkStatus.needsUnlinkedReview(f.call))
        #expect(ScheduleGoogleLinkStatus.unlinkedReviewGuidance(f.call,
            connectedGoogleEmail: f.email)?.contains("saving this job will not publish it") == true)
    }

    @Test func legacyUnlinkedJobShowsReviewWithoutAutomaticGoogleWrite() async throws {
        let f = try Fixture()
        f.call.googleEventManagedByApp = false
        f.call.scheduledDate = Date().addingTimeInterval(3600)
        try f.context.save()

        #expect(ScheduleGoogleLinkStatus.needsUnlinkedReview(f.call))
        #expect(ScheduleGoogleLinkStatus.unlinkedReviewGuidance(f.call,
            connectedGoogleEmail: f.email)?.contains(f.email) == true)
        let disconnectedGuidance = try #require(ScheduleGoogleLinkStatus.unlinkedReviewGuidance(
            f.call, connectedGoogleEmail: nil))
        #expect(disconnectedGuidance.contains("your intended Google account"))
        #expect(disconnectedGuidance.contains("Review Google publication"))
        #expect(!disconnectedGuidance.contains("connected Google account"))
        #expect(!GoogleCalendarScheduleSync.needsOutboundSync(f.call))
        let queued = try ServiceCallCalendarOutbox.save(f.call) { try f.context.save() }
        #expect(!queued)
        #expect(f.call.googleCalendarPendingAt == nil)

        let result = try await (try f.flow()).run {
            try await GoogleCalendarScheduleSync.synchronize(workflow: $0, verifyConfirmedCalls: [f.call])
        }.get()
        #expect(f.writes.isEmpty)
        #expect(f.call.googleEventID == nil)
        #expect(result.contains("Review Google publication"))
        #expect(result.contains("not published"))
        #expect(result.contains("1 displayed scheduled job has no Google event link and was not published"))
        #expect(result.contains(f.email))
        #expect(result.contains("another account or time slot"))

        let background = try await (try f.flow()).run {
            try await GoogleCalendarScheduleSync.synchronize(workflow: $0)
        }.get()
        #expect(background.contains("No pending app-managed calendar updates were published"))
        #expect(background.contains("Older scheduled jobs without a Google event link are not included"))
        #expect(f.writes.isEmpty)

        f.call.googleEventID = "existing-external-event"
        #expect(!ScheduleGoogleLinkStatus.needsUnlinkedReview(f.call))
        #expect(ScheduleGoogleLinkStatus.unlinkedReviewGuidance(f.call,
            connectedGoogleEmail: f.email) == nil)
        f.call.googleEventID = nil
        f.call.status = .completed
        #expect(!ScheduleGoogleLinkStatus.needsUnlinkedReview(f.call))
    }

    @Test func legacyReviewCountDeduplicatesVisibleJobsAndExcludesCompletedWork() async throws {
        let f = try Fixture()
        f.call.googleEventManagedByApp = false
        f.call.scheduledDate = Date().addingTimeInterval(3600)
        let second = ServiceCall(googleCalendarID: "primary", googleEventManagedByApp: false,
            eventTitle: "Second visit", type: .repair,
            scheduledDate: Date().addingTimeInterval(7200), duration: 3600,
            customer: f.customer, notes: "Synthetic appointment")
        let completed = ServiceCall(googleCalendarID: "primary", googleEventManagedByApp: false,
            eventTitle: "Completed visit", type: .repair,
            scheduledDate: Date().addingTimeInterval(10_800), duration: 3600,
            customer: f.customer, notes: "Synthetic completed appointment")
        completed.status = .completed
        f.context.insert(second)
        f.context.insert(completed)
        try f.context.save()

        #expect(ScheduleGoogleLinkStatus.unlinkedReviewCount(
            selectedDay: [f.call, second, completed], upcoming: [second, f.call]) == 2)
        let result = try await (try f.flow()).run {
            try await GoogleCalendarScheduleSync.synchronize(workflow: $0,
                verifyConfirmedCalls: [f.call, second, f.call, completed])
        }.get()
        #expect(result.contains("2 displayed scheduled jobs have no Google event link and were not published"))
        #expect(result.contains("another account or time slot"))
        #expect(f.requests.filter { $0.httpMethod == "GET" }.count > 0)
        #expect(f.writes.isEmpty)
        #expect(f.call.googleEventID == nil)
        #expect(second.googleEventID == nil)
    }

    @Test func completedUnlinkedJobDoesNotWarnAboutCurrentGooglePublication() async throws {
        let f = try Fixture()
        f.call.googleEventManagedByApp = false
        f.call.status = .completed
        try f.context.save()

        let message = try await (try f.flow()).run {
            try await GoogleCalendarScheduleSync.synchronize(workflow: $0, verifyConfirmedCalls: [f.call])
        }.get()
        #expect(!message.contains("Review Google publication"))
        #expect(f.writes.isEmpty)
    }

    @Test func legacyInspectionFindsGoogleChosenIDAtSavedTimeWithoutWriting() async throws {
        let f = try Fixture()
        f.call.googleEventManagedByApp = false
        f.remote[f.key(f.email, "google-chosen-id")] = f.event(id: "google-chosen-id", managed: false)
        try f.context.save()

        let inspection = try await GoogleCalendarScheduleSync.inspectUnlinkedCalendarJob(
            call: f.call, workflow: f.flow(scope: [f.call])).get()
        #expect(!inspection.noMatchWithinScope)
        #expect(inspection.candidates.count == 1)
        #expect(inspection.candidates.first?.eventID == "google-chosen-id")
        #expect(inspection.candidates.first?.reason == .sameSchedule)
        #expect(f.writes.isEmpty)
        #expect(f.call.googleEventID == nil)
    }

    @Test func legacyInspectionFindsJobMarkerAtDifferentTime() async throws {
        let f = try Fixture()
        f.call.googleEventManagedByApp = false
        f.remote[f.key(f.email, "marker-event")] = f.event(id: "marker-event",
            start: f.call.scheduledDate.addingTimeInterval(30 * 60))
        try f.context.save()

        let inspection = try await GoogleCalendarScheduleSync.inspectUnlinkedCalendarJob(
            call: f.call, workflow: f.flow(scope: [f.call])).get()
        #expect(inspection.candidates.first?.reason == .appMarker)
        #expect(f.writes.isEmpty)
    }

    @Test func legacyInspectionFindsDeterministicIDOnAnotherCalendar() async throws {
        let f = try Fixture()
        f.call.googleEventManagedByApp = false
        let other = "moved-calendar@example.invalid"
        let deterministicID = GoogleCalendarScheduleSync.eventID(for: f.call.id)
        f.calendarList.append(["id": other, "accessRole": "writer"])
        f.remote[f.key(other, deterministicID)] = f.event(id: deterministicID, managed: false)
        try f.context.save()

        let inspection = try await GoogleCalendarScheduleSync.inspectUnlinkedCalendarJob(
            call: f.call, workflow: f.flow(scope: [f.call])).get()
        #expect(inspection.originalCalendarID == f.email)
        #expect(inspection.candidates.first?.calendarID == other)
        #expect(inspection.candidates.first?.reason == .deterministicID)
        #expect(f.writes.isEmpty)
    }

    @Test func legacyInspectionRequiresCompleteCalendarReadsForNoMatchProof() async throws {
        let f = try Fixture()
        f.call.googleEventManagedByApp = false
        try f.context.save()
        let empty = try await GoogleCalendarScheduleSync.inspectUnlinkedCalendarJob(
            call: f.call, workflow: f.flow(scope: [f.call])).get()
        #expect(empty.noMatchWithinScope)
        #expect(empty.searchedCalendarIDs == [f.email])
        #expect(f.writes.isEmpty)

        let denied = try Fixture()
        denied.call.googleEventManagedByApp = false
        denied.calendarList.append(["id": "unreadable@example.invalid", "accessRole": "freeBusyReader"])
        denied.deniedEventCalendarID = "unreadable@example.invalid"
        try denied.context.save()
        let deniedResult = await GoogleCalendarScheduleSync.inspectUnlinkedCalendarJob(
            call: denied.call, workflow: try denied.flow(scope: [denied.call]))
        if case .success = deniedResult { Issue.record("A 403 cannot prove a Google event absent") }
        #expect(denied.writes.isEmpty)

        let paginated = try Fixture()
        paginated.call.googleEventManagedByApp = false
        paginated.inspectionNextPageToken = "another-page"
        try paginated.context.save()
        let paginatedResult = await GoogleCalendarScheduleSync.inspectUnlinkedCalendarJob(
            call: paginated.call, workflow: try paginated.flow(scope: [paginated.call]))
        if case .success = paginatedResult { Issue.record("A second page cannot prove a Google event absent") }
        #expect(paginated.writes.isEmpty)

        let paginatedCalendars = try Fixture()
        paginatedCalendars.call.googleEventManagedByApp = false
        paginatedCalendars.inspectionCalendarListNextPageToken = "more-calendars"
        try paginatedCalendars.context.save()
        let calendarListResult = await GoogleCalendarScheduleSync.inspectUnlinkedCalendarJob(
            call: paginatedCalendars.call,
            workflow: try paginatedCalendars.flow(scope: [paginatedCalendars.call]))
        if case .success = calendarListResult { Issue.record("A second calendar page cannot prove an event absent") }
        #expect(paginatedCalendars.writes.isEmpty)
    }

    @Test func legacyInspectionRefusesChangedJobRevision() async throws {
        let f = try Fixture()
        f.call.googleEventManagedByApp = false
        try f.context.save()
        f.beforeReply = { request in
            guard request.url?.path.hasSuffix("/calendarList") == true else { return }
            f.call.scheduledDate = f.call.scheduledDate.addingTimeInterval(15 * 60)
            try f.context.save()
        }

        let result = await GoogleCalendarScheduleSync.inspectUnlinkedCalendarJob(
            call: f.call, workflow: try f.flow(scope: [f.call]))
        if case .success = result { Issue.record("A changed appointment cannot yield a scan result") }
        #expect(f.writes.isEmpty)
        #expect(f.call.googleEventID == nil)
    }

    private func linkReview(for f: Fixture, eventID: String = "legacy-marker-event") async throws
        -> GoogleCalendarScheduleSync.UnlinkedEventLinkReview {
        f.call.googleEventManagedByApp = false
        f.remote[f.key(f.email, eventID)] = f.event(id: eventID)
        try f.context.save()
        let workflow = try f.flow(scope: [f.call])
        let inspection = try await GoogleCalendarScheduleSync.inspectUnlinkedCalendarJob(
            call: f.call, workflow: workflow).get()
        return try #require(GoogleCalendarScheduleSync.linkReview(
            call: f.call, workflow: workflow, inspection: inspection))
    }

    @Test func explicitlyLinkedLegacyEventSavesOnlyRouteAfterFreshGoogleRefetch() async throws {
        let f = try Fixture()
        let review = try await linkReview(for: f)
        let originalDate = f.call.scheduledDate
        let originalTitle = f.call.eventTitle
        let outcome = try await GoogleCalendarScheduleSync.linkExistingEvent(review).get()

        #expect(outcome.verifiedEvent?.id == "legacy-marker-event")
        #expect(f.call.googleCalendarID == f.email)
        #expect(f.call.googleEventID == "legacy-marker-event")
        #expect(f.call.scheduledDate == originalDate)
        #expect(f.call.eventTitle == originalTitle)
        #expect(!f.call.googleEventManagedByApp)
        #expect(f.call.googleEventConfirmedAt == nil)
        #expect(f.call.googleCalendarPendingAt == nil)
        #expect(f.writes.isEmpty)
        #expect(f.requests.filter { $0.url?.path.hasSuffix("/legacy-marker-event") == true }.count >= 2)
        let reopened = ModelContext(f.context.container)
        let id = f.call.id
        let saved = try #require(reopened.fetch(FetchDescriptor<ServiceCall>(
            predicate: #Predicate { $0.id == id })).first)
        #expect(saved.googleEventID == "legacy-marker-event")
        #expect(!saved.googleEventManagedByApp)
    }

    @Test func legacyLinkNeverOffersSameTimeOrWrongMarkerEvent() async throws {
        let f = try Fixture()
        f.call.googleEventManagedByApp = false
        f.remote[f.key(f.email, "same-time-event")] = f.event(id: "same-time-event", managed: false)
        let deterministic = GoogleCalendarScheduleSync.eventID(for: f.call.id)
        var wrong = f.event(id: deterministic)
        var properties = try #require(wrong["extendedProperties"] as? [String: [String: String]])
        properties["private"]?["gunnaireServiceCallID"] = UUID().uuidString
        wrong["extendedProperties"] = properties
        f.remote[f.key(f.email, deterministic)] = wrong
        try f.context.save()
        let workflow = try f.flow(scope: [f.call])
        let scan = try await GoogleCalendarScheduleSync.inspectUnlinkedCalendarJob(
            call: f.call, workflow: workflow).get()
        #expect(scan.candidates.count == 2)
        #expect(scan.singleProvableCandidate == nil)
        #expect(GoogleCalendarScheduleSync.linkReview(call: f.call, workflow: workflow,
            inspection: scan) == nil)
        #expect(f.writes.isEmpty)
    }

    @Test func legacyLinkRefusesDuplicateLocalEventID() async throws {
        let f = try Fixture()
        let review = try await linkReview(for: f)
        let other = ServiceCall(googleCalendarID: f.email, googleEventID: review.candidate.eventID,
            type: .repair, scheduledDate: f.call.scheduledDate, customer: f.customer)
        f.context.insert(other)
        try f.context.save()

        let result = await GoogleCalendarScheduleSync.linkExistingEvent(review)
        if case .success = result { Issue.record("A local duplicate cannot be linked") }
        #expect(f.call.googleEventID == nil)
        #expect(f.writes.isEmpty)
    }

    @Test func legacyLinkRefusesChangedJobAccountAndRemoteSchedule() async throws {
        let changed = try Fixture()
        let changedReview = try await linkReview(for: changed)
        changed.call.scheduledDate = changed.call.scheduledDate.addingTimeInterval(60)
        try changed.context.save()
        if case .success = await GoogleCalendarScheduleSync.linkExistingEvent(changedReview) {
            Issue.record("A changed job cannot be linked")
        }
        #expect(changed.call.googleEventID == nil)
        #expect(changed.writes.isEmpty)

        let account = try Fixture()
        let accountReview = try await linkReview(for: account)
        account.auth.signOut()
        if case .success = await GoogleCalendarScheduleSync.linkExistingEvent(accountReview) {
            Issue.record("A different Google account cannot be linked")
        }
        #expect(account.call.googleEventID == nil)
        #expect(account.writes.isEmpty)

        let workspace = try Fixture()
        let workspaceReview = try await linkReview(for: workspace)
        workspace.authorized = false
        if case .success = await GoogleCalendarScheduleSync.linkExistingEvent(workspaceReview) {
            Issue.record("Lost workspace authority cannot link an event")
        }
        #expect(workspace.call.googleEventID == nil)
        #expect(workspace.writes.isEmpty)

        let remote = try Fixture()
        let remoteReview = try await linkReview(for: remote)
        remote.remote[remote.key(remote.email, remoteReview.candidate.eventID)] = remote.event(
            id: remoteReview.candidate.eventID, start: remote.call.scheduledDate.addingTimeInterval(30))
        if case .success = await GoogleCalendarScheduleSync.linkExistingEvent(remoteReview) {
            Issue.record("A remotely retimed event cannot be linked")
        }
        #expect(remote.call.googleEventID == nil)
        #expect(remote.writes.isEmpty)
    }

    @Test func importNeverPromotesExistingUnmanagedLinkToAutomaticPublication() throws {
        let f = try Fixture()
        let placeholder = Customer(quickBooksID: CustomerDataMaintenance.unassignedCalendarCustomerMarker,
            name: CustomerDataMaintenance.unassignedCalendarCustomerName)
        f.context.insert(placeholder)
        f.call.customer = placeholder
        f.call.googleEventID = "legacy-marker-event"
        f.call.googleEventManagedByApp = false
        try f.context.save()
        let event = try f.decoded(f.event(id: "legacy-marker-event"))
        let summary = try GoogleCalendarScheduleSync.importEvents([(f.email, event)],
            into: f.context, signedInEmail: f.email, primaryCalendarID: f.email)
        #expect(summary.importedCount == 1)
        #expect(f.call.googleEventID == "legacy-marker-event")
        #expect(!f.call.googleEventManagedByApp)
        #expect(!GoogleCalendarScheduleSync.shouldAllowGoogleCalendarWrite(for: f.call))
        #expect(f.writes.isEmpty)
    }

    private func unlinkedPublishReview(_ f: Fixture) async throws
        -> GoogleCalendarScheduleSync.UnlinkedPublishReview {
        f.call.googleEventManagedByApp = false
        try f.context.save()
        let workflow = try f.flow(scope: [f.call])
        let inspection = try await GoogleCalendarScheduleSync.inspectUnlinkedCalendarJob(
            call: f.call, workflow: workflow).get()
        return try GoogleCalendarScheduleSync.prepareUnlinkedPublishReview(
            call: f.call, inspection: inspection, workflow: workflow)
    }

    @Test func legacyPublishRequiresConfirmationAndFreshNoMatchScan() async throws {
        let f = try Fixture()
        let review = try await unlinkedPublishReview(f)
        #expect(f.writes.isEmpty)
        #expect(!f.call.googleEventManagedByApp)
        #expect(f.call.googleEventID == nil)

        let result = await GoogleCalendarScheduleSync.publishUnlinkedCalendarJob(review)
        #expect(try result.get().contains("Schedule confirmed in Google Calendar"))
        let posts = f.writes.filter { $0.httpMethod == "POST" }
        #expect(posts.count == 1)
        #expect(posts.first?.url?.query?.contains("sendUpdates=all") == true)
        let postedBody = try #require(posts.first?.httpBody)
        let postedJSON = try #require(JSONSerialization.jsonObject(with: postedBody) as? [String: Any])
        let reminders = try #require(postedJSON["reminders"] as? [String: Any])
        #expect(reminders["useDefault"] as? Bool == false)
        let overrides = try #require(reminders["overrides"] as? [[String: Any]])
        #expect(overrides.count == 1)
        #expect(overrides.first?["method"] as? String == "popup")
        #expect(overrides.first?["minutes"] as? Int == 30)
        #expect(f.call.googleEventManagedByApp)
        #expect(f.call.googleEventID == GoogleCalendarScheduleSync.eventID(for: f.call.id))
        #expect(f.call.googleEventConfirmedAt != nil)
        #expect(f.call.googleCalendarPendingAt == nil)
        #expect(f.remote[f.key(f.email, GoogleCalendarScheduleSync.eventID(for: f.call.id))] != nil)
    }

    @Test func legacyPublishRefusesAProviderMatchFoundAfterConfirmation() async throws {
        let f = try Fixture()
        let review = try await unlinkedPublishReview(f)
        f.remote[f.key(f.email, "old-google-chosen-id")] =
            f.event(id: "old-google-chosen-id", managed: false)

        let result = await GoogleCalendarScheduleSync.publishUnlinkedCalendarJob(review)
        if case .success = result { Issue.record("A newly discovered provider event must stop creation") }
        #expect(f.writes.isEmpty)
        #expect(!f.call.googleEventManagedByApp)
        #expect(f.call.googleEventID == nil)
    }

    @Test func legacyPublishRefusesAnEditedAppointmentOrIncompleteProviderRead() async throws {
        let edited = try Fixture()
        let editedReview = try await unlinkedPublishReview(edited)
        edited.call.scheduledDate = edited.call.scheduledDate.addingTimeInterval(15 * 60)
        try edited.context.save()
        let changed = await GoogleCalendarScheduleSync.publishUnlinkedCalendarJob(editedReview)
        if case .success = changed { Issue.record("A changed appointment must stop creation") }
        #expect(edited.writes.isEmpty)

        let denied = try Fixture()
        let deniedReview = try await unlinkedPublishReview(denied)
        denied.calendarList.append(["id": "unreadable@example.invalid", "accessRole": "freeBusyReader"])
        denied.deniedEventCalendarID = "unreadable@example.invalid"
        let unreadable = await GoogleCalendarScheduleSync.publishUnlinkedCalendarJob(deniedReview)
        if case .success = unreadable { Issue.record("An inaccessible calendar must stop creation") }
        #expect(denied.writes.isEmpty)
        #expect(!denied.call.googleEventManagedByApp)
    }

    @Test(arguments: [401, 403])
    func legacyPublishRestoresUnmanagedStatusAfterExplicitGoogleDenial(status: Int) async throws {
        let f = try Fixture()
        let review = try await unlinkedPublishReview(f)
        f.rejectedCreateStatus = status

        let denied = await GoogleCalendarScheduleSync.publishUnlinkedCalendarJob(review)
        if case .success = denied { Issue.record("An HTTP denial must not be presented as publication") }
        #expect(f.writes.filter { $0.httpMethod == "POST" }.count == 1)
        #expect(!f.call.googleEventManagedByApp)
        #expect(f.call.googleEventID == nil)
        #expect(f.call.googleCalendarPendingAt == nil)
        #expect(f.remote.isEmpty)
    }

    @Test func legacyPublishKeepsReservedIdentityAfterLostProviderReply() async throws {
        let f = try Fixture()
        let review = try await unlinkedPublishReview(f)
        f.afterWrite = { request in
            guard request.httpMethod == "POST" else { return }
            throw URLError(.timedOut)
        }

        let uncertain = await GoogleCalendarScheduleSync.publishUnlinkedCalendarJob(review)
        if case .success = uncertain { Issue.record("A lost provider reply must not claim confirmation") }
        let id = GoogleCalendarScheduleSync.eventID(for: f.call.id)
        #expect(f.writes.filter { $0.httpMethod == "POST" }.count == 1)
        #expect(!f.call.googleEventManagedByApp)
        #expect(f.call.googleEventID == id)
        #expect(f.call.googleCalendarPendingAt != nil)
        #expect(f.call.googleEventConfirmedAt == nil)
        #expect(f.remote[f.key(f.email, id)] != nil)
        #expect(GoogleCalendarScheduleSync.hasUnconfirmedLegacyCreateReservation(f.call))

        f.afterWrite = nil
        let recovered = try await GoogleCalendarScheduleSync.checkReservedLegacyPublication(
            call: f.call, workflow: f.flow(scope: [f.call])).get()
        #expect(recovered.contains("Schedule confirmed in Google Calendar"))
        #expect(f.writes.filter { $0.httpMethod == "POST" }.count == 1)
        #expect(f.call.googleEventID == id)
        #expect(f.call.googleEventManagedByApp)
        #expect(f.call.googleEventConfirmedAt != nil)
    }

    @Test func legacyPublishNeverAutomaticallyRetriesAnUnreceivedCreate() async throws {
        let f = try Fixture()
        let review = try await unlinkedPublishReview(f)
        f.beforeReply = { request in
            guard request.httpMethod == "POST" else { return }
            throw URLError(.timedOut)
        }

        let uncertain = await GoogleCalendarScheduleSync.publishUnlinkedCalendarJob(review)
        if case .success = uncertain { Issue.record("A timed-out create is not confirmation") }
        let id = GoogleCalendarScheduleSync.eventID(for: f.call.id)
        #expect(f.writes.filter { $0.httpMethod == "POST" }.count == 1)
        #expect(!f.call.googleEventManagedByApp)
        #expect(f.call.googleEventID == id)
        #expect(f.call.googleCalendarPendingAt != nil)
        #expect(f.remote.isEmpty)
        #expect(GoogleCalendarScheduleSync.hasUnconfirmedLegacyCreateReservation(f.call))

        f.beforeReply = nil
        let recovery = try await GoogleCalendarScheduleSync.checkReservedLegacyPublication(
            call: f.call, workflow: f.flow(scope: [f.call])).get()
        #expect(recovery.contains("reserved Google event ID was not found"))
        #expect(f.writes.filter { $0.httpMethod == "POST" }.count == 1)
        let automatic = try await f.publish()
        if case .success = automatic { Issue.record("Automatic recovery may not recreate a missing reservation") }
        #expect(f.writes.filter { $0.httpMethod == "POST" }.count == 1)
        let callID = f.call.id
        let persisted = try #require(ModelContext(f.context.container).fetch(
            FetchDescriptor<ServiceCall>(predicate: #Predicate { $0.id == callID })).first)
        #expect(!persisted.googleEventManagedByApp)
        #expect(persisted.googleEventID == id)
    }

    @Test func legacyPublishRetainsReservationOnCreateConflict() async throws {
        let f = try Fixture()
        let review = try await unlinkedPublishReview(f)
        f.beforeReply = { request in
            guard request.httpMethod == "POST" else { return }
            let id = GoogleCalendarScheduleSync.eventID(for: f.call.id)
            f.remote[f.key(f.email, id)] = f.event(id: id)
        }

        let conflict = await GoogleCalendarScheduleSync.publishUnlinkedCalendarJob(review)
        if case .success = conflict { Issue.record("A 409 needs a fresh exact-ID inspection") }
        #expect(f.writes.filter { $0.httpMethod == "POST" }.count == 1)
        #expect(!f.call.googleEventManagedByApp)
        #expect(f.call.googleEventID == GoogleCalendarScheduleSync.eventID(for: f.call.id))
        #expect(f.call.googleCalendarPendingAt != nil)
    }

    @Test func legacyReservationCannotAdoptAConflictingUnownedGoogleEvent() async throws {
        let f = try Fixture()
        let review = try await unlinkedPublishReview(f)
        f.beforeReply = { request in
            guard request.httpMethod == "POST" else { return }
            let id = GoogleCalendarScheduleSync.eventID(for: f.call.id)
            f.remote[f.key(f.email, id)] = f.event(id: id, managed: false)
        }

        let conflict = await GoogleCalendarScheduleSync.publishUnlinkedCalendarJob(review)
        if case .success = conflict { Issue.record("A conflicting ID is not an app-owned event") }
        f.beforeReply = nil
        let recovery = await GoogleCalendarScheduleSync.checkReservedLegacyPublication(
            call: f.call, workflow: try f.flow(scope: [f.call]))
        if case .success = recovery { Issue.record("An unowned event cannot be linked after a 409") }
        let automatic = try await f.publish()
        if case .success = automatic { Issue.record("An unowned event cannot be adopted after a 409") }
        #expect(f.writes.filter { $0.httpMethod == "POST" }.count == 1)
        #expect(f.writes.filter { $0.httpMethod == "PATCH" }.isEmpty)
        #expect(!f.call.googleEventManagedByApp)
        #expect(f.call.googleEventID == GoogleCalendarScheduleSync.eventID(for: f.call.id))
    }

    @Test func immediateExportReportsMissingSavedCallBeforeProviderAccess() throws {
        let f = try Fixture()
        let detachedCustomer = Customer(name: "Detached fixture customer")
        let unsaved = ServiceCall(googleCalendarID: "primary", googleEventManagedByApp: true,
            type: .repair, scheduledDate: Date(), customer: detachedCustomer)
        var reported: Result<String, Error>?

        GoogleCalendarScheduleSync.exportImmediately(call: unsaved, auth: f.auth,
            modelContext: f.context, signedInEmail: f.email, isAdminUser: true) { reported = $0 }

        if case .some(.failure(let error)) = reported {
            #expect(error as? GoogleCalendarWorkflowError == .changed)
        } else {
            Issue.record("A missing saved call must report a Calendar failure.")
        }
        #expect(f.auth.calendarSyncMessage?.contains("Calendar update is not confirmed") == true)
        #expect(f.requests.isEmpty)
    }

    @Test func publishThenImportMaySaveAnUnrelatedCalendarShellInTheSameRun() async throws {
        let f = try Fixture()
        f.call.scheduledDate = Date().addingTimeInterval(3600)
        try f.context.save()
        f.remote[f.key(f.email, "external-visit")] = f.event(id: "external-visit", managed: false)
        let result = await (try f.flow()).run { try await GoogleCalendarScheduleSync.synchronize(workflow: $0) }
        #expect(try result.get().contains("Published 1"))
        #expect(f.writes.filter { $0.httpMethod == "POST" }.count == 1)
        #expect(try f.context.fetch(FetchDescriptor<ServiceCall>()).count == 2)
    }

    @Test func fractionalSecondScheduleSurvivesCreateAndPatchConfirmation() async throws {
        let f = try Fixture()
        f.call.scheduledDate = Date(timeIntervalSince1970: 1_800_000_000.1234)
        try f.context.save()
        _ = try await f.publish().get()
        f.call.scheduledDate = f.call.scheduledDate.addingTimeInterval(60.2345)
        try f.context.save()
        _ = try await f.publish().get()
        #expect(f.writes.map(\.httpMethod) == ["POST", "PATCH"])
        #expect(f.remote.count == 1)
    }

    @Test func failedPublishRemainsPendingAndRetryRetainsIdentity() async throws {
        let f = try Fixture()
        GoogleCalendarScheduleSync.markCalendarCallLocallyEdited(f.call)
        f.afterWrite = { _ in throw URLError(.networkConnectionLost) }
        failed(try await f.publish())
        #expect(GoogleCalendarScheduleSync.needsOutboundSync(f.call))
        let reserved = f.call.googleEventID
        f.afterWrite = nil
        _ = try await (try f.flow()).run { try await GoogleCalendarScheduleSync.synchronize(workflow: $0) }.get()
        #expect(f.call.googleEventID == reserved)
        #expect(f.writes.count == 1)
        #expect(!GoogleCalendarScheduleSync.needsOutboundSync(f.call))
    }

    @Test(arguments: [401, 403])
    func rejectedCalendarPermissionReleasesOnlyUnsentReservationForReconnect(status: Int) async throws {
        let f = try Fixture()
        f.rejectedCreateStatus = status
        failed(try await f.publish())
        #expect(f.call.googleEventID == nil)
        #expect(f.call.googleCalendarID == "primary")
        #expect(f.remote.isEmpty)
        f.rejectedCreateStatus = nil
        _ = try await f.publish().get()
        #expect(f.writes.map(\.httpMethod) == ["POST", "POST"])
        #expect(f.remote.count == 1)
    }

    @Test func calendarPermissionReadinessDoesNotDependOnDriveScope() {
        #expect(GoogleCalendarAuthorizationState.evaluate(
            isAuthenticated: false, businessIdentityMatches: false, hasCalendarScope: false) == .disconnected)
        #expect(GoogleCalendarAuthorizationState.evaluate(
            isAuthenticated: true, businessIdentityMatches: false, hasCalendarScope: true) == .businessAccountMismatch)
        #expect(GoogleCalendarAuthorizationState.evaluate(
            isAuthenticated: true, businessIdentityMatches: true, hasCalendarScope: false) == .reauthorizationRequired)
        #expect(GoogleCalendarAuthorizationState.evaluate(
            isAuthenticated: true, businessIdentityMatches: true, hasCalendarScope: true) == .ready)
    }

    @Test func pendingPolicyExcludesExternalAndCompletedJobs() throws {
        let f = try Fixture()
        GoogleCalendarScheduleSync.markCalendarCallLocallyEdited(f.call)
        f.call.googleEventManagedByApp = false
        #expect(!GoogleCalendarScheduleSync.needsOutboundSync(f.call))
        f.call.googleEventManagedByApp = true
        f.call.status = .completed
        #expect(!GoogleCalendarScheduleSync.needsOutboundSync(f.call))
    }

    @Test func newAppointmentInvitesStaffNotCustomerAndAddsReminder() async throws {
        let f = try Fixture()
        let technician = Technician(name: "Assigned technician", contactInfo: " Tech@Example.invalid ")
        let crew = Technician(name: "Crew", contactInfo: "crew@example.invalid")
        f.context.insert(technician); f.context.insert(crew)
        f.call.assignedTechnician = technician
        f.call.additionalTechnicianIDs = [crew.id]
        try f.context.save()
        _ = try await f.publish().get()
        let post = try #require(f.writes.first)
        #expect(post.url?.query == "sendUpdates=all")
        let body = try #require(JSONSerialization.jsonObject(with: post.httpBody!) as? [String: Any])
        let guests = try #require(body["attendees"] as? [[String: String]])
        #expect(Set(guests.compactMap { $0["email"] }) == ["tech@example.invalid", "crew@example.invalid"])
        #expect(!(post.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? "").contains(f.customer.email!))
        let reminders = try #require(body["reminders"] as? [String: Any])
        #expect(reminders["useDefault"] as? Bool == false)
        #expect((reminders["overrides"] as? [[String: Any]])?.first?["minutes"] as? Int == 30)
    }

    @Test func invalidStaffEmailPublishesOrganizerEventAndRetainsInvitationWarning() async throws {
        let f = try Fixture()
        let technician = Technician(name: "Missing calendar email", contactInfo: "555-0100")
        f.context.insert(technician); f.call.assignedTechnician = technician
        try f.context.save()
        let result = try await f.publish().get()
        #expect(result.contains("Staff invitations need attention"))
        #expect(f.writes.count == 1)
        #expect(f.writes[0].httpMethod == "POST")
        let body = try #require(f.writes[0].httpBody)
        let created = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect((created["attendees"] as? [[String: String]])?.isEmpty != false)
        #expect(f.call.googleEventID == GoogleCalendarScheduleSync.eventID(for: f.call.id))
        #expect(f.staffInvitationsNeedAttention)
        #expect(!GoogleCalendarScheduleSync.staffInvitationsNeedAttention(for: f.call,
            connectedGoogleEmail: "another@gunnaire.com", workspaceEmail: f.email))
        #expect(!GoogleCalendarScheduleSync.staffInvitationsNeedAttention(for: f.call,
            connectedGoogleEmail: f.email, workspaceEmail: "another@gunnaire.com"))
        #expect(GoogleCalendarScheduleSync.needsOutboundSync(f.call))
        technician.contactInfo = "tech@example.invalid"
        try f.context.save()
        _ = try await f.publish().get()
        #expect(f.writes.count == 2)
        #expect(f.writes[1].httpMethod == "PATCH")
        #expect(f.writes[1].url?.query == "sendUpdates=all")
        #expect(!f.staffInvitationsNeedAttention)
        #expect(!GoogleCalendarScheduleSync.needsOutboundSync(f.call))
    }

    @Test func duplicateStaffEmailPublishesOrganizerEventWithoutClaimingInvitations() async throws {
        let f = try Fixture()
        let lead = Technician(name: "Lead", contactInfo: "shared@example.invalid")
        let crew = Technician(name: "Crew", contactInfo: "shared@example.invalid")
        f.context.insert(lead); f.context.insert(crew)
        f.call.assignedTechnician = lead
        f.call.additionalTechnicianIDs = [crew.id]
        try f.context.save()
        let result = try await f.publish().get()
        #expect(result.contains("Staff invitations need attention"))
        #expect(f.writes.count == 1)
        #expect(f.writes[0].httpMethod == "POST")
        #expect(f.staffInvitationsNeedAttention)
        crew.contactInfo = "crew@example.invalid"
        try f.context.save()
        _ = try await f.publish().get()
        #expect(f.writes.count == 2)
        #expect(f.writes[1].httpMethod == "PATCH")
        #expect(!f.staffInvitationsNeedAttention)
    }

    @Test func invalidReplacementStaffCannotMoveEventAndNotifyFormerAssignee() async throws {
        let f = try Fixture(linked: true)
        let former = Technician(name: "Former technician", contactInfo: "former@example.invalid")
        let replacement = Technician(name: "Replacement", contactInfo: "555-0100")
        f.context.insert(former); f.context.insert(replacement)
        f.call.assignedTechnician = replacement
        let oldStart = f.call.scheduledDate
        f.call.scheduledDate = oldStart.addingTimeInterval(3600)
        try f.context.save()
        var existing = f.event(id: "fixture-event", start: oldStart)
        existing["attendees"] = [["email": "former@example.invalid"]]
        existing["extendedProperties"] = ["private": [
            "gunnaireManaged": "true", "gunnaireManagedVersion": "4",
            "gunnaireOrigin": "ios-app", "gunnaireServiceCallID": f.call.id.uuidString,
            GoogleCalendarStaffDelivery.managedEmailsKey: "former@example.invalid"
        ]]
        f.remote[f.key(f.email, "fixture-event")] = existing

        let result = try await f.publish()
        guard case .failure(let error) = result else {
            Issue.record("A moved event with an invalid replacement must remain pending")
            return
        }
        #expect(error as? GoogleCalendarStaffDeliveryError == .unsafeScheduleUpdate)
        #expect(f.writes.isEmpty)
        f.loseDeviceLocalCalendarMarkers()
        let restarted = ModelContext(f.context.container)
        let retained = try #require(restarted.fetch(FetchDescriptor<ServiceCall>()).first { $0.id == f.call.id })
        #expect(retained.googleCalendarPendingAt != nil)
        #expect(GoogleCalendarScheduleSync.needsOutboundSync(retained))
        let unchanged = try #require(f.remote[f.key(f.email, "fixture-event")])
        let start = try #require(unchanged["start"] as? [String: String])
        #expect(start["dateTime"] == ISO8601DateFormatter().string(from: oldStart))
        let guests = try #require(unchanged["attendees"] as? [[String: String]])
        #expect(guests.compactMap { $0["email"] } == ["former@example.invalid"])
    }

    @Test func invalidStaffCanMoveOrganizerOnlyEventWithoutSendingGuestUpdates() async throws {
        let f = try Fixture(linked: true)
        let replacement = Technician(name: "Replacement", contactInfo: "555-0100")
        f.context.insert(replacement)
        f.call.assignedTechnician = replacement
        f.call.scheduledDate = f.call.scheduledDate.addingTimeInterval(3600)
        try f.context.save()

        let message = try await f.publish().get()
        #expect(message.contains("Staff invitations need attention"))
        #expect(f.writes.count == 1)
        #expect(f.writes.first?.httpMethod == "PATCH")
        #expect(f.writes.first?.url?.query == "sendUpdates=none")
        #expect(f.staffInvitationsNeedAttention)
        #expect(GoogleCalendarScheduleSync.needsOutboundSync(f.call))
    }

    @Test func automaticSyncReportsConfirmedEventAndPendingStaffInvitations() async throws {
        let f = try Fixture()
        let technician = Technician(name: "Missing calendar email", contactInfo: "555-0100")
        f.context.insert(technician)
        f.call.assignedTechnician = technician
        try f.context.save()
        let message = try await (try f.flow()).run {
            try await GoogleCalendarScheduleSync.synchronize(workflow: $0)
        }.get()
        #expect(message.contains("Published 1 pending calendar update"))
        #expect(message.contains("need review"))
        #expect(message.contains("valid calendar email"))
        #expect(f.writes.count == 1)
        #expect(f.writes.first?.httpMethod == "POST")
        #expect(f.staffInvitationsNeedAttention)
    }

    @Test func assignmentOnlyChangeInvitesNewStaffWithoutMovingOrDuplicatingEvent() async throws {
        let f = try Fixture()
        let first = Technician(name: "First", contactInfo: "first@example.invalid")
        let second = Technician(name: "Second", contactInfo: "second@example.invalid")
        f.context.insert(first); f.context.insert(second)
        f.call.assignedTechnician = first
        try f.context.save()
        _ = try await f.publish().get()
        let id = try #require(f.call.googleEventID)
        f.call.assignedTechnician = second
        GoogleCalendarScheduleSync.markCalendarCallLocallyEdited(f.call)
        try f.context.save()
        _ = try await f.publish().get()
        #expect(f.call.googleEventID == id)
        #expect(f.writes.count == 2)
        let patch = try #require(f.writes.last)
        #expect(patch.httpMethod == "PATCH")
        #expect(patch.url?.query == "sendUpdates=all")
        #expect(patch.value(forHTTPHeaderField: "If-Match") == "\"version-created\"")
        let body = try #require(JSONSerialization.jsonObject(with: patch.httpBody!) as? [String: Any])
        #expect(Set(body.keys) == ["attendees", "extendedProperties"])
        #expect((body["attendees"] as? [[String: Any]])?.compactMap { $0["email"] as? String } == ["second@example.invalid"])
        #expect(f.remote.count == 1)
    }

    @Test func changedTechnicianEmailReplacesItsManagedInvitationAfterLocalMarkersAreLost() async throws {
        let f = try Fixture()
        let technician = Technician(name: "Assigned", contactInfo: "old@example.invalid")
        f.context.insert(technician)
        f.call.assignedTechnician = technician
        try f.context.save()
        _ = try await f.publish().get()
        let eventID = try #require(f.call.googleEventID)

        let affected = try TechnicianCalendarInvitationRecovery.save(
            email: "new@example.invalid", for: technician, calls: [f.call], context: f.context)
        #expect(affected == 1)
        f.loseDeviceLocalCalendarMarkers()
        #expect(GoogleCalendarScheduleSync.needsOutboundSync(f.call))

        _ = try await (try f.flow()).run {
            try await GoogleCalendarScheduleSync.synchronize(workflow: $0)
        }.get()
        #expect(f.call.googleEventID == eventID)
        #expect(f.writes.map(\.httpMethod) == ["POST", "PATCH"])
        let patch = try #require(f.writes.last)
        #expect(patch.url?.query == "sendUpdates=all")
        let event = try #require(f.remote[f.key(f.email, eventID)])
        let guests = try #require(event["attendees"] as? [[String: Any]])
        #expect(guests.compactMap { $0["email"] as? String } == ["new@example.invalid"])
        let properties = try #require(event["extendedProperties"] as? [String: [String: String]])
        #expect(properties["private"]?[GoogleCalendarStaffDelivery.managedEmailsKey] == "new@example.invalid")
        #expect(f.call.googleEventConfirmedAt != nil && f.call.googleCalendarPendingAt == nil)
    }

    @Test(arguments: [false, true])
    func savedScheduleEditRetriesAfterDeviceLocalMarkersAreLost(past: Bool) async throws {
        let f = try Fixture(linked: true)
        let originalID = try #require(f.call.googleEventID)
        if past {
            let originalStart = Date().addingTimeInterval(-7 * 86_400)
            f.remote[f.key(f.email, originalID)] = f.event(id: originalID, start: originalStart)
            f.call.scheduledDate = originalStart
            try f.context.save()
        }
        f.remote[f.key(f.email, originalID)]?["reminders"] = [
            "useDefault": false, "overrides": [["method": "popup", "minutes": 30]]
        ]
        f.call.scheduledDate = f.call.scheduledDate.addingTimeInterval(900)
        GoogleCalendarScheduleSync.markCalendarCallLocallyEdited(f.call)
        try f.context.save()
        f.loseDeviceLocalCalendarMarkers()

        #expect(f.call.googleEventConfirmedAt == nil)
        #expect(GoogleCalendarScheduleSync.needsOutboundSync(f.call))
        _ = try await (try f.flow()).run {
            try await GoogleCalendarScheduleSync.synchronize(workflow: $0)
        }.get()
        #expect(f.call.googleEventID == originalID)
        #expect(f.writes.map(\.httpMethod) == ["PATCH"])
        #expect(f.call.googleEventConfirmedAt != nil)
        #expect(!GoogleCalendarScheduleSync.needsOutboundSync(f.call))
    }

    @Test func failedStaffInvitationStaysPendingAfterDeviceLocalMarkersAreLost() async throws {
        let f = try Fixture(linked: true)
        let technician = Technician(name: "Missing calendar email", contactInfo: "555-0100")
        f.context.insert(technician)
        f.call.assignedTechnician = technician
        GoogleCalendarScheduleSync.markCalendarCallLocallyEdited(f.call)
        try f.context.save()
        let message = try await f.publish().get()
        #expect(message.contains("Staff invitations need attention"))
        #expect(f.call.googleEventConfirmedAt == nil)
        #expect(f.writes.isEmpty)

        f.loseDeviceLocalCalendarMarkers()
        #expect(GoogleCalendarScheduleSync.needsOutboundSync(f.call))
        technician.contactInfo = "staff@example.invalid"
        try f.context.save()
        _ = try await (try f.flow()).run {
            try await GoogleCalendarScheduleSync.synchronize(workflow: $0)
        }.get()
        #expect(f.writes.map(\.httpMethod) == ["PATCH"])
        #expect(f.call.googleEventConfirmedAt != nil)
        #expect(!GoogleCalendarScheduleSync.needsOutboundSync(f.call))
    }

    @Test func detailOnlyJobEditConfirmsScheduleWithoutOverwritingGoogleDetails() async throws {
        let f = try Fixture(linked: true)
        f.remote[f.key(f.email, "fixture-event")]?["reminders"] = [
            "useDefault": false, "overrides": [["method": "popup", "minutes": 30]]
        ]
        f.call.notes = "Updated internal field notes"
        GoogleCalendarScheduleSync.markCalendarCallLocallyEdited(f.call)
        try f.context.save()

        let message = try await f.publish().get()
        #expect(message.contains("Schedule confirmed"))
        #expect(f.writes.isEmpty)
        #expect(f.remote[f.key(f.email, "fixture-event")]?["description"] as? String == "Google notes")
        #expect(f.call.googleCalendarPendingAt == nil)
        #expect(f.call.googleEventConfirmedAt != nil)
    }

    @Test func externalGuestReviewNeverEmailsCustomerOrClearsPending() async throws {
        let f = try Fixture(linked: true)
        let technician = Technician(name: "Staff", contactInfo: "staff@example.invalid")
        f.context.insert(technician); f.call.assignedTechnician = technician
        f.remote[f.key(f.email, "fixture-event")]?["attendees"] = [["email": f.customer.email!]]
        GoogleCalendarScheduleSync.markCalendarCallLocallyEdited(f.call)
        try f.context.save()
        failed(try await f.publish())
        #expect(f.writes.isEmpty)
        #expect(GoogleCalendarScheduleSync.needsOutboundSync(f.call))
    }

    @Test func explicitPendingLegacyEventReceivesReminderWithoutCustomerEmail() async throws {
        let f = try Fixture(linked: true)
        f.remote[f.key(f.email, "fixture-event")]?["attendees"] = [["email": f.customer.email!]]
        GoogleCalendarScheduleSync.markCalendarCallLocallyEdited(f.call)
        _ = try await f.publish().get()
        let patch = try #require(f.writes.first)
        #expect(patch.url?.query == "sendUpdates=none")
        let body = try #require(JSONSerialization.jsonObject(with: patch.httpBody!) as? [String: Any])
        #expect(Set(body.keys) == ["reminders"])
    }

    @Test func staffDeliveryLostResponseRecoversWithoutAnotherInvitation() async throws {
        let f = try Fixture(linked: true)
        let technician = Technician(name: "Staff", contactInfo: "staff@example.invalid")
        f.context.insert(technician); f.call.assignedTechnician = technician
        try f.context.save()
        f.afterWrite = { _ in throw URLError(.networkConnectionLost) }
        failed(try await f.publish())
        f.afterWrite = nil
        _ = try await f.publish().get()
        #expect(f.writes.count == 1)
    }

    @Test func cancelledPendingJobDeletesOriginalAndDoesNotRecreateIt() async throws {
        let f = try Fixture(linked: true)
        f.call.status = .cancelled
        GoogleCalendarScheduleSync.markCalendarCallLocallyEdited(f.call)
        try f.context.save()
        _ = try await (try f.flow()).run { try await GoogleCalendarScheduleSync.synchronize(workflow: $0) }.get()
        #expect(f.writes.map(\.httpMethod) == ["DELETE"])
        #expect(!GoogleCalendarScheduleSync.needsOutboundSync(f.call))
    }

    @Test func cancelledEventDeletionWithLostReplyReconcilesOnNextSync() async throws {
        let f = try Fixture(linked: true)
        f.call.status = .cancelled
        GoogleCalendarScheduleSync.markCalendarCallLocallyEdited(f.call)
        try f.context.save()
        f.afterWrite = { _ in throw URLError(.networkConnectionLost) }
        let first = await (try f.flow()).run { try await GoogleCalendarScheduleSync.cancel(call: f.call, workflow: $0) }
        failed(first)
        #expect(f.remote.isEmpty)
        #expect(GoogleCalendarScheduleSync.needsOutboundSync(f.call))

        f.afterWrite = nil
        _ = try await (try f.flow()).run {
            try await GoogleCalendarScheduleSync.cancel(call: f.call, workflow: $0)
        }.get()
        #expect(f.writes.map(\.httpMethod) == ["DELETE"])
        #expect(!GoogleCalendarScheduleSync.needsOutboundSync(f.call))
        #expect(GoogleCalendarScheduleSync.isCalendarEventDeleted(
            calendarID: f.email, eventID: f.call.googleEventID))
    }

    @Test func cancellationDoesNotTreatAnEventMovedToAnotherCalendarAsDeleted() async throws {
        let f = try Fixture(linked: true)
        f.call.status = .cancelled
        GoogleCalendarScheduleSync.markCalendarCallLocallyEdited(f.call)
        try f.context.save()
        f.remote.removeValue(forKey: f.key(f.email, "fixture-event"))
        let otherCalendar = "other-calendar@example.invalid"
        f.calendarList.append(["id": otherCalendar, "primary": false, "accessRole": "writer"])
        f.remote[f.key(otherCalendar, "fixture-event")] = f.event(id: "fixture-event")

        let result = await (try f.flow()).run {
            try await GoogleCalendarScheduleSync.cancel(call: f.call, workflow: $0)
        }
        guard case .failure(let error) = result else {
            Issue.record("A moved Google event must require review before cancellation")
            return
        }
        #expect(error as? GoogleCalendarWorkflowError == .needsReview)
        #expect(f.writes.isEmpty)
        #expect(f.call.googleCalendarPendingAt != nil)
        #expect(f.remote[f.key(otherCalendar, "fixture-event")] != nil)
    }

    @Test func oneInvalidRouteDoesNotStarveOtherPendingJobs() async throws {
        let f = try Fixture()
        f.call.googleCalendarID = "not-shared@example.invalid"
        GoogleCalendarScheduleSync.markCalendarCallLocallyEdited(f.call)
        let second = ServiceCall(googleCalendarID: "primary", googleEventManagedByApp: true,
            type: .service, scheduledDate: f.call.scheduledDate.addingTimeInterval(3600), customer: f.customer)
        f.context.insert(second)
        GoogleCalendarScheduleSync.markCalendarCallLocallyEdited(second)
        try f.context.save()
        let result = try await (try f.flow()).run { try await GoogleCalendarScheduleSync.synchronize(workflow: $0) }.get()
        #expect(result.contains("Published 1"))
        #expect(result.contains("1 update(s) still need review"))
        #expect(GoogleCalendarScheduleSync.needsOutboundSync(f.call))
        #expect(!GoogleCalendarScheduleSync.needsOutboundSync(second))
        #expect(f.writes.count == 1)
    }

    @Test func staffPatchRejectsOmittedAndDuplicateGuestLists() throws {
        let f = try Fixture(linked: true)
        var value = f.event(id: "fixture-event")
        value["attendeesOmitted"] = true
        let desired = [GoogleWritableCalendarAttendee(email: "staff@example.invalid", displayName: nil)]
        #expect(throws: GoogleCalendarStaffDeliveryError.self) {
            try GoogleCalendarStaffDelivery.patch(remote: f.decoded(value), desired: desired,
                knownStaff: ["staff@example.invalid"], restoreReminder: false)
        }
        value["attendeesOmitted"] = false
        value["attendees"] = [["email": "old@example.invalid"], ["email": "old@example.invalid"]]
        #expect(throws: GoogleCalendarStaffDeliveryError.self) {
            try GoogleCalendarStaffDelivery.patch(remote: f.decoded(value), desired: desired,
                knownStaff: ["old@example.invalid", "staff@example.invalid"], restoreReminder: false)
        }
    }

    @Test func staffPatchPreservesRSVPAndUnmanagedInternalGuests() throws {
        let f = try Fixture(linked: true)
        var value = f.event(id: "fixture-event")
        value["attendees"] = [
            ["email": "old@example.invalid"],
            ["email": "office@example.invalid", "responseStatus": "accepted", "comment": "Joining remotely", "optional": true]
        ]
        var props = try #require(value["extendedProperties"] as? [String: [String: String]])
        props["private"]?[GoogleCalendarStaffDelivery.managedEmailsKey] = "old@example.invalid"
        value["extendedProperties"] = props
        let proposed = try GoogleCalendarStaffDelivery.patch(remote: f.decoded(value),
            desired: [.init(email: "new@example.invalid", displayName: "New")],
            knownStaff: ["old@example.invalid", "office@example.invalid", "new@example.invalid"], restoreReminder: false)
        let patch = try #require(proposed)
        #expect(Set(patch.attendees?.compactMap(\.email) ?? []) == ["office@example.invalid", "new@example.invalid"])
        let retained = try #require(patch.attendees?.first { $0.email == "office@example.invalid" })
        #expect(retained.responseStatus == "accepted")
        #expect(retained.comment == "Joining remotely")
        #expect(retained.optional == true)
        #expect(patch.extendedProperties?.privateProperties?["gunnaireServiceCallID"] == f.call.id.uuidString)
    }

    @Test func reminderOptOutIsPreserved() throws {
        let f = try Fixture(linked: true)
        var value = f.event(id: "fixture-event")
        value["reminders"] = ["useDefault": false, "overrides": []] as [String: Any]
        let patch = try GoogleCalendarStaffDelivery.patch(remote: f.decoded(value), desired: [], knownStaff: [], restoreReminder: true)
        #expect(patch == nil)
    }

    @Test func duplicateOrUnknownDesiredStaffCannotAuthorizeInvitations() throws {
        let f = try Fixture(linked: true)
        let remote = try f.decoded(f.event(id: "fixture-event"))
        let desired = GoogleWritableCalendarAttendee(email: "staff@example.invalid", displayName: nil)
        #expect(throws: GoogleCalendarStaffDeliveryError.self) {
            try GoogleCalendarStaffDelivery.patch(remote: remote, desired: [desired, desired],
                knownStaff: [desired.email], restoreReminder: false)
        }
        #expect(throws: GoogleCalendarStaffDeliveryError.self) {
            try GoogleCalendarStaffDelivery.patch(remote: remote, desired: [desired], knownStaff: [], restoreReminder: false)
        }
        #expect(GoogleCalendarStaffDelivery.email("555-0100") == nil)
        #expect(GoogleCalendarStaffDelivery.email("tech@example.invalid\nBcc:customer@example.invalid") == nil)
    }

    @Test func changedProviderBlocksStaffInvitationBeforeSend() async throws {
        let f = try Fixture(linked: true)
        let technician = Technician(name: "Staff", contactInfo: "staff@example.invalid")
        f.context.insert(technician); f.call.assignedTechnician = technician
        try f.context.save()
        f.beforeReply = { request in
            if request.httpMethod == "GET", request.url?.path.hasSuffix("fixture-event") == true {
                f.auth.signOut()
            }
        }
        failed(try await f.publish())
        #expect(f.writes.isEmpty)
    }

    @Test func firstCreatePersistsOriginalCalendarAndStableIdentityBeforeSending() async throws {
        let f = try Fixture()
        let id = GoogleCalendarScheduleSync.eventID(for: f.call.id)
        f.beforeReply = { request in
            if request.httpMethod == "POST" {
                #expect(f.call.googleEventID == id)
                #expect(f.call.googleCalendarID == f.email)
                #expect(!f.context.hasChanges)
            }
        }
        _ = try await f.publish().get()
        #expect(f.writes.count == 1)
        #expect(f.call.googleEventID == id)
        #expect(f.call.notes == "Saved field observations")
        #expect(f.customer.address == "Local service address")
        #expect(f.requests.allSatisfy { !$0.url!.path.contains("/primary/") })
        #expect(f.requests.contains { $0.httpMethod == "GET" &&
            $0.url?.path.hasSuffix("/calendars/\(f.email)/events/\(id)") == true })
        let reminders = try #require(f.remote[f.key(f.email, id)]?["reminders"] as? [String: Any])
        #expect(reminders["useDefault"] as? Bool == false)
        let overrides = try #require(reminders["overrides"] as? [[String: Any]])
        #expect(overrides.contains { $0["method"] as? String == "popup" && $0["minutes"] as? Int == 30 })
    }

    @Test func acceptedCreateWithoutExactReadbackRetainsReservationAndNeverPostsAgain() async throws {
        let f = try Fixture()
        f.createdEventReadbackStatus = 404
        let result = try await f.publish()
        failed(result)
        if case .failure(let error) = result {
            #expect(error as? GoogleCalendarWorkflowError == .unconfirmedReadback)
        }
        let reserved = try #require(f.call.googleEventID)
        #expect(f.call.googleEventConfirmedAt == nil)
        #expect(f.call.googleCalendarPendingAt != nil)
        #expect(f.writes.filter { $0.httpMethod == "POST" }.count == 1)
        f.createdEventReadbackStatus = nil
        _ = try await f.publish().get()
        #expect(f.call.googleEventID == reserved)
        #expect(f.call.googleEventConfirmedAt != nil)
        #expect(f.writes.filter { $0.httpMethod == "POST" }.count == 1)
    }

    @Test func deniedReadbackAfterAcceptedCreateCannotReleaseReservedIdentity() async throws {
        let f = try Fixture()
        f.createdEventReadbackStatus = 403
        failed(try await f.publish())
        let reserved = try #require(f.call.googleEventID)
        #expect(f.call.googleCalendarID == f.email)
        #expect(f.call.googleEventConfirmedAt == nil)
        #expect(f.writes.filter { $0.httpMethod == "POST" }.count == 1)
        f.createdEventReadbackStatus = nil
        _ = try await f.publish().get()
        #expect(f.call.googleEventID == reserved)
        #expect(f.writes.filter { $0.httpMethod == "POST" }.count == 1)
    }

    @Test func strippedPopupCannotBeReportedAsConfirmedDelivery() async throws {
        let f = try Fixture()
        let id = GoogleCalendarScheduleSync.eventID(for: f.call.id)
        f.afterWrite = { request in
            if request.httpMethod == "POST" {
                f.remote[f.key(f.email, id)]?["reminders"] =
                    ["useDefault": false, "overrides": []] as [String: Any]
            }
        }
        let result = try await f.publish()
        failed(result)
        if case .failure(let error) = result {
            #expect(error.localizedDescription.contains("30-minute popup"))
        }
        #expect(f.call.googleEventID == id)
        #expect(f.call.googleEventConfirmedAt == nil)
        #expect(f.call.googleCalendarPendingAt != nil)
        #expect(f.writes.filter { $0.httpMethod == "POST" }.count == 1)
        f.afterWrite = nil
        failed(try await f.publish())
        #expect(f.writes.filter { $0.httpMethod == "POST" }.count == 1)
    }

    @Test func lostCreateResponseRecoversOriginalEventWithoutAnotherPost() async throws {
        let f = try Fixture()
        f.afterWrite = { _ in throw URLError(.networkConnectionLost) }
        failed(try await f.publish())
        let original = f.call.googleEventID
        #expect(original != nil)
        f.afterWrite = nil
        _ = try await f.publish().get()
        #expect(f.call.googleEventID == original)
        #expect(f.writes.count == 1)
        #expect(f.remote.count == 1)
    }

    @Test func reservedMissingEventCannotTurnIntoAnotherCreate() async throws {
        let f = try Fixture()
        f.beforeReply = { request in
            if request.httpMethod == "POST" { throw URLError(.timedOut) }
        }
        failed(try await f.publish())
        f.beforeReply = nil
        failed(try await f.publish())
        #expect(f.writes.count == 1)
        #expect(f.call.googleEventID != nil)
        #expect(f.call.googleEventConfirmedAt == nil)
        #expect(f.remote.isEmpty)
    }

    @Test func unconfirmedLinkedEventIsRecoveredAfterLocalRetryMarkerLoss() async throws {
        let f = try Fixture(linked: true)
        f.call.googleEventConfirmedAt = nil
        try f.context.save()
        #expect(GoogleCalendarScheduleSync.needsOutboundSync(f.call))
        _ = try await (try f.flow()).run {
            try await GoogleCalendarScheduleSync.synchronize(workflow: $0)
        }.get()
        #expect(f.call.googleEventConfirmedAt != nil)
        #expect(!f.writes.contains { $0.httpMethod == "POST" },
                "A confirmed original event must not be posted again.")
        #expect(!GoogleCalendarScheduleSync.needsOutboundSync(f.call))
    }

    @Test func unconfirmedMissingLinkStaysForExplicitSameIDReview() async throws {
        let f = try Fixture(linked: true)
        f.call.googleEventConfirmedAt = nil
        try f.context.save()
        f.remote.removeValue(forKey: f.key(f.email, "fixture-event"))
        #expect(GoogleCalendarScheduleSync.needsOutboundSync(f.call))
        let message = try await (try f.flow()).run {
            try await GoogleCalendarScheduleSync.synchronize(workflow: $0)
        }.get()
        #expect(message.contains("need review"))
        #expect(f.call.googleEventConfirmedAt == nil)
        #expect(f.call.googleEventID == "fixture-event")
        #expect(f.writes.isEmpty, "A missing reserved link requires the guarded repair action.")
    }

    @Test func legacyMissingLinkNeedsExplicitReviewAndKeepsItsOriginalID() async throws {
        let f = try Fixture(linked: true)
        f.remote.removeValue(forKey: f.key(f.email, "fixture-event"))
        #expect(!GoogleCalendarScheduleSync.needsOutboundSync(f.call))
        let review = try #require(try await GoogleCalendarScheduleSync.checkMissingEvent(
            call: f.call, workflow: f.flow()).get())
        #expect(review.eventID == "fixture-event")
        #expect(review.calendarID == f.email)
        #expect(f.call.googleEventID == "fixture-event")
        #expect(f.writes.isEmpty)
        failed(try await f.publish())
        #expect(f.writes.isEmpty, "Ordinary sync must never recreate a previously linked 404.")
    }

    @Test func explicitSyncRechecksConfirmedVisibleLinkAndPersistsMissingReview() async throws {
        let f = try Fixture(linked: true)
        f.remote.removeValue(forKey: f.key(f.email, "fixture-event"))
        #expect(!GoogleCalendarScheduleSync.needsOutboundSync(f.call))
        var verifiedNotFound: [UUID: String] = [:]

        let message = try await (try f.flow()).run {
            try await GoogleCalendarScheduleSync.synchronize(workflow: $0, verifyConfirmedCalls: [f.call],
                verifiedNotFound: { verifiedNotFound[$0] = $1 })
        }.get()
        #expect(message.contains("not found in this connected account's accessible calendars"))
        #expect(message.contains("Checked 1 confirmed selected-day/upcoming Google link"))
        #expect(f.call.googleEventID == "fixture-event")
        #expect(f.call.googleEventConfirmedAt == nil)
        #expect(f.call.googleCalendarPendingAt != nil)
        #expect(f.writes.isEmpty, "A missing confirmed event must not be recreated during sync.")
        let missingIDs = ScheduleGoogleLinkStatus.reconciledMissingIDs(existing: [:],
            verifiedNotFoundIDs: verifiedNotFound, visibleCalls: [f.call])
        #expect(missingIDs[f.call.id] == "fixture-event",
                "Schedule must show the missing-event status after Sync Google detects the 404.")

        f.loseDeviceLocalCalendarMarkers()
        let restarted = ModelContext(f.context.container)
        let retained = try #require(restarted.fetch(FetchDescriptor<ServiceCall>()).first { $0.id == f.call.id })
        #expect(GoogleCalendarScheduleSync.needsOutboundSync(retained))
    }

    @Test func automaticVerificationRotatesPastIneligibleRowsAndThrottlesWakes() throws {
        let f = try Fixture(linked: true)
        let now = f.call.scheduledDate.addingTimeInterval(-3600)
        let pending = ServiceCall(googleCalendarID: "primary", googleEventManagedByApp: true,
            type: .repair, scheduledDate: f.call.scheduledDate.addingTimeInterval(1800), customer: f.customer)
        let second = ServiceCall(googleCalendarID: "primary", googleEventID: "second-event",
            googleEventConfirmedAt: now, googleEventManagedByApp: true,
            type: .repair, scheduledDate: f.call.scheduledDate.addingTimeInterval(3600), customer: f.customer)
        let third = ServiceCall(googleCalendarID: "primary", googleEventID: "third-event",
            googleEventConfirmedAt: now, googleEventManagedByApp: true,
            type: .repair, scheduledDate: f.call.scheduledDate.addingTimeInterval(7200), customer: f.customer)
        f.context.insert(pending); f.context.insert(second); f.context.insert(third)
        try f.context.save()

        let first = try GoogleCalendarScheduleSync.automaticVerificationPage(
            context: f.context, now: now, offset: 0)
        #expect(first.calls.map(\.id) == [f.call.id, second.id])
        let next = try GoogleCalendarScheduleSync.automaticVerificationPage(
            context: f.context, now: now, offset: first.nextOffset)
        #expect(next.calls.map(\.id) == [third.id])
        #expect(next.nextOffset == 0)
        #expect(AutomaticOutboundSync.calendarVerificationIsDue(lastAttempt: nil, now: now, interval: 600))
        #expect(!AutomaticOutboundSync.calendarVerificationIsDue(
            lastAttempt: now.addingTimeInterval(-599), now: now, interval: 600))
        #expect(AutomaticOutboundSync.calendarVerificationIsDue(
            lastAttempt: now.addingTimeInterval(-600), now: now, interval: 600))
    }

    @Test func automaticCandidateFindsDeletedOriginalWithoutPosting() async throws {
        let f = try Fixture(linked: true)
        let page = try GoogleCalendarScheduleSync.automaticVerificationPage(context: f.context,
            now: f.call.scheduledDate.addingTimeInterval(-3600), offset: 0)
        #expect(page.calls.map(\.id) == [f.call.id])
        f.remote.removeValue(forKey: f.key(f.email, "fixture-event"))
        var verifiedNotFound: [UUID: String] = [:]

        let message = try await (try f.flow()).run {
            try await GoogleCalendarScheduleSync.synchronize(workflow: $0,
                verifyConfirmedCalls: page.calls, verifiedNotFound: { verifiedNotFound[$0] = $1 })
        }.get()
        #expect(message.contains("not found in this connected account's accessible calendars"))
        #expect(verifiedNotFound[f.call.id] == "fixture-event")
        #expect(f.call.googleEventID == "fixture-event")
        #expect(f.call.googleEventConfirmedAt == nil && f.call.googleCalendarPendingAt != nil)
        #expect(f.writes.isEmpty)
    }

    @Test func automaticMissingLinkIsPersistedEvenWhenLaterImportNeedsReview() async throws {
        let f = try Fixture(linked: true)
        f.remote.removeValue(forKey: f.key(f.email, "fixture-event"))
        let conflicting = ServiceCall(googleCalendarID: "not-shared@example.invalid",
            googleEventID: "import-conflict", googleEventConfirmedAt: Date(),
            googleEventManagedByApp: true, type: .repair,
            scheduledDate: f.call.scheduledDate.addingTimeInterval(3600), customer: f.customer)
        f.context.insert(conflicting)
        try f.context.save()
        f.remote[f.key(f.email, "import-conflict")] = f.event(id: "import-conflict")
        var verifiedNotFound: [UUID: String] = [:]

        let result = await (try f.flow()).run {
            try await GoogleCalendarScheduleSync.synchronize(workflow: $0,
                verifyConfirmedCalls: [f.call], verifiedNotFound: { verifiedNotFound[$0] = $1 })
        }
        guard case .failure = result else {
            Issue.record("Duplicate imported identities must still fail closed")
            return
        }
        #expect(verifiedNotFound[f.call.id] == "fixture-event")
        #expect(f.call.googleEventConfirmedAt == nil && f.call.googleCalendarPendingAt != nil)
        #expect(f.call.googleEventID == "fixture-event")
        #expect(f.writes.isEmpty)
    }

    @Test func explicitSyncKeepsPresentConfirmedLinkWithoutProviderWrite() async throws {
        let f = try Fixture(linked: true)
        let originalConfirmation = f.call.googleEventConfirmedAt
        var verifiedNotFound: [UUID: String] = [:]
        let deduplicated = ScheduleGoogleLinkStatus.verificationCalls(
            selectedDay: [f.call], upcoming: [f.call])
        #expect(deduplicated.count == 1)
        let message = try await (try f.flow()).run {
            try await GoogleCalendarScheduleSync.synchronize(workflow: $0, verifyConfirmedCalls: deduplicated,
                verifiedNotFound: { verifiedNotFound[$0] = $1 })
        }.get()
        #expect(message.contains("Checked 1 confirmed selected-day/upcoming Google link"))
        #expect(f.call.googleEventID == "fixture-event")
        #expect(f.call.googleEventConfirmedAt == originalConfirmation)
        #expect(f.call.googleCalendarPendingAt == nil)
        #expect(f.writes.isEmpty)
        #expect(f.requests.filter { $0.url?.path.hasSuffix("/events/fixture-event") == true }.count == 1)
        let missingIDs = ScheduleGoogleLinkStatus.reconciledMissingIDs(existing: [f.call.id: "fixture-event"],
            verifiedNotFoundIDs: verifiedNotFound, visibleCalls: [f.call])
        #expect(missingIDs[f.call.id] == nil)
    }

    @Test func movedConfirmedEventNeedsReviewWithoutBeingMarkedMissing() async throws {
        let f = try Fixture(linked: true)
        let originalConfirmation = f.call.googleEventConfirmedAt
        f.remote.removeValue(forKey: f.key(f.email, "fixture-event"))
        let otherCalendar = "other-calendar@example.invalid"
        f.calendarList.append(["id": otherCalendar, "primary": false, "accessRole": "writer"])
        f.remote[f.key(otherCalendar, "fixture-event")] = f.event(id: "fixture-event")
        // The fixture's list endpoint otherwise ignores its 90-day timeMin/timeMax.
        // This saved appointment is outside that import window, but exact-ID GET
        // must still discover its moved event.
        f.excludedWindowCalendarIDs.insert(otherCalendar)
        var verifiedNotFound: [UUID: String] = [:]

        let message = try await (try f.flow()).run {
            try await GoogleCalendarScheduleSync.synchronize(workflow: $0, verifyConfirmedCalls: [f.call],
                verifiedNotFound: { verifiedNotFound[$0] = $1 })
        }.get()
        #expect(message.contains("needs review"))
        #expect(verifiedNotFound.isEmpty)
        #expect(f.call.googleEventConfirmedAt == originalConfirmation)
        #expect(f.call.googleCalendarPendingAt == nil)
        #expect(f.writes.isEmpty)
    }

    @Test func unreadableCandidateCalendarCannotProveConfirmedEventAbsent() async throws {
        let f = try Fixture(linked: true)
        f.remote.removeValue(forKey: f.key(f.email, "fixture-event"))
        let unreadable = "free-busy@example.invalid"
        f.calendarList.append(["id": unreadable, "primary": false, "accessRole": "freeBusyReader"])
        f.deniedEventCalendarID = unreadable
        var verifiedNotFound: [UUID: String] = [:]

        let message = try await (try f.flow()).run {
            try await GoogleCalendarScheduleSync.synchronize(workflow: $0, verifyConfirmedCalls: [f.call],
                verifiedNotFound: { verifiedNotFound[$0] = $1 })
        }.get()
        #expect(message.contains("could not be verified"))
        #expect(verifiedNotFound.isEmpty)
        #expect(f.call.googleEventConfirmedAt != nil)
        #expect(f.call.googleCalendarPendingAt == nil)
        #expect(f.writes.isEmpty)
    }

    @Test func inaccessibleConfirmedRouteDoesNotAbortSyncOrCreateFalseMissingBadge() async throws {
        let f = try Fixture(linked: true)
        f.call.googleCalendarID = "not-shared@example.invalid"
        f.excludedWindowCalendarIDs.insert(f.email)
        try f.context.save()
        var verifiedNotFound: [UUID: String] = [:]

        let message = try await (try f.flow()).run {
            try await GoogleCalendarScheduleSync.synchronize(workflow: $0, verifyConfirmedCalls: [f.call],
                verifiedNotFound: { verifiedNotFound[$0] = $1 })
        }.get()
        #expect(message.contains("could not be verified"))
        #expect(verifiedNotFound.isEmpty)
        #expect(f.call.googleEventConfirmedAt != nil)
        #expect(f.call.googleCalendarPendingAt == nil)
        let missingIDs = ScheduleGoogleLinkStatus.reconciledMissingIDs(existing: [:],
            verifiedNotFoundIDs: verifiedNotFound, visibleCalls: [f.call])
        #expect(missingIDs.isEmpty)

        f.call.googleEventConfirmedAt = nil
        GoogleCalendarScheduleSync.markCalendarCallLocallyEdited(f.call)
        let editedWithout404 = ScheduleGoogleLinkStatus.reconciledMissingIDs(existing: [:],
            verifiedNotFoundIDs: [:], visibleCalls: [f.call])
        #expect(editedWithout404.isEmpty, "A local edit cannot be misreported as a remote 404.")
    }

    @Test func explicitMissingLinkRepairRechecksAndReusesTheSavedID() async throws {
        let f = try Fixture(linked: true)
        f.remote.removeValue(forKey: f.key(f.email, "fixture-event"))
        let review = try #require(try await GoogleCalendarScheduleSync.checkMissingEvent(
            call: f.call, workflow: f.flow()).get())
        _ = try await GoogleCalendarScheduleSync.repairMissingEvent(review).get()
        #expect(f.writes.count == 1)
        #expect(f.writes.first?.httpMethod == "POST")
        let requestBody = try #require(f.writes.first?.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        #expect(body["id"] as? String == "fixture-event")
        #expect(f.call.googleEventID == "fixture-event")
        #expect(f.remote[f.key(f.email, "fixture-event")] != nil)
        _ = try await f.publish().get()
        #expect(f.writes.count == 1, "A later sync must reconcile, not create twice.")
    }

    @Test func repairedEventNeedsExactReadbackBeforeOldConfirmationCanReturn() async throws {
        let f = try Fixture(linked: true)
        f.remote.removeValue(forKey: f.key(f.email, "fixture-event"))
        let review = try #require(try await GoogleCalendarScheduleSync.checkMissingEvent(
            call: f.call, workflow: f.flow()).get())
        f.createdEventReadbackStatus = 404
        failed(await GoogleCalendarScheduleSync.repairMissingEvent(review))
        #expect(f.call.googleEventID == "fixture-event")
        #expect(f.call.googleEventConfirmedAt == nil)
        #expect(f.call.googleCalendarPendingAt != nil)
        #expect(f.writes.filter { $0.httpMethod == "POST" }.count == 1)
        f.createdEventReadbackStatus = nil
        _ = try await f.publish().get()
        #expect(f.call.googleEventConfirmedAt != nil)
        #expect(f.call.googleCalendarPendingAt == nil)
        #expect(f.writes.filter { $0.httpMethod == "POST" }.count == 1)
    }

    @Test func repairedLegacyIDWithoutPopupCannotBeConfirmedByLaterSync() async throws {
        let f = try Fixture(linked: true)
        f.remote.removeValue(forKey: f.key(f.email, "fixture-event"))
        let review = try #require(try await GoogleCalendarScheduleSync.checkMissingEvent(
            call: f.call, workflow: f.flow()).get())
        f.afterWrite = { request in
            if request.httpMethod == "POST" {
                f.remote[f.key(f.email, "fixture-event")]?["reminders"] =
                    ["useDefault": false, "overrides": []] as [String: Any]
            }
        }
        failed(await GoogleCalendarScheduleSync.repairMissingEvent(review))
        #expect(f.call.googleEventConfirmedAt == nil)
        #expect(f.call.googleCalendarPendingAt != nil)
        #expect(f.writes.filter { $0.httpMethod == "POST" }.count == 1)
        f.afterWrite = nil
        failed(try await f.publish())
        #expect(f.call.googleEventConfirmedAt == nil)
        #expect(f.writes.filter { $0.httpMethod == "POST" }.count == 1)

        let proof = try #require(f.call.googleCalendarPendingAt)
        #expect(proof == Date(timeIntervalSince1970: 946_684_800))
        GoogleCalendarScheduleSync.markCalendarCallLocallyEdited(f.call)
        #expect(f.call.googleCalendarPendingAt == proof)
        f.call.notes = "An edited saved appointment"
        try ServiceCallCalendarOutbox.save(f.call) { try f.context.save() }
        #expect(f.call.googleCalendarPendingAt == proof)
        let resumedContext = ModelContext(f.context.container)
        let callID = f.call.id
        let resumed = try #require(resumedContext.fetch(FetchDescriptor<ServiceCall>(
            predicate: #Predicate { $0.id == callID })).first)
        #expect(resumed.googleCalendarPendingAt == proof)
        let workflow = try GoogleCalendarWorkflow(auth: f.auth, context: resumedContext,
            signedInEmail: f.email, validateAccess: {})
        let automatic = await workflow.run {
            let outcome = try await GoogleCalendarScheduleSync.publishPending(workflow: $0)
            return String(outcome.published)
        }
        switch automatic {
        case .success:
            Issue.record("Automatic retry confirmed a replacement without its popup reminder.")
        case .failure(let error):
            if let workflowError = error as? GoogleCalendarWorkflowError,
               case .alertReview(let message) = workflowError {
                #expect(message.contains("30-minute popup"))
            } else {
                Issue.record("Automatic retry failed for a reason other than the missing popup: \(error)")
            }
        }
        #expect(resumed.googleEventConfirmedAt == nil)
        #expect(resumed.googleCalendarPendingAt == proof)
        #expect(f.writes.filter { $0.httpMethod == "POST" }.count == 1)
        f.remote[f.key(f.email, "fixture-event")]?["reminders"] = ["useDefault": false,
            "overrides": [["method": "popup", "minutes": 30]]] as [String: Any]
        let recovered = try GoogleCalendarWorkflow(auth: f.auth, context: resumedContext,
            signedInEmail: f.email, validateAccess: {})
        let published = try await recovered.run {
            let outcome = try await GoogleCalendarScheduleSync.publishPending(workflow: $0)
            return String(outcome.published)
        }.get()
        #expect(published == "1")
        #expect(resumed.googleEventConfirmedAt != nil)
        #expect(resumed.googleCalendarPendingAt == nil)
        #expect(f.writes.filter { $0.httpMethod == "POST" }.count == 1)
    }

    @Test func laterDeliberateReminderOptOutDoesNotReopenCompletedRepairProof() async throws {
        let f = try Fixture(linked: true)
        f.remote.removeValue(forKey: f.key(f.email, "fixture-event"))
        let review = try #require(try await GoogleCalendarScheduleSync.checkMissingEvent(
            call: f.call, workflow: f.flow()).get())
        _ = try await GoogleCalendarScheduleSync.repairMissingEvent(review).get()
        #expect(f.call.googleEventConfirmedAt != nil)
        f.remote[f.key(f.email, "fixture-event")]?["reminders"] =
            ["useDefault": false, "overrides": []] as [String: Any]
        GoogleCalendarScheduleSync.markCalendarCallLocallyEdited(f.call)
        f.call.googleCalendarPendingAt = Date().addingTimeInterval(1)
        try f.context.save()
        _ = try await f.publish().get()
        #expect(f.call.googleEventConfirmedAt != nil)
        #expect(f.call.googleCalendarPendingAt == nil)
        #expect(f.writes.filter { $0.httpMethod == "POST" }.count == 1)
        let event = try #require(f.remote[f.key(f.email, "fixture-event")])
        let reminders = try #require(event["reminders"] as? [String: Any])
        #expect((reminders["overrides"] as? [[String: Any]])?.isEmpty == true)
    }

    @Test func verifiedProviderLinkOpensOnlyTheUnchangedOriginalGoogleEvent() async throws {
        let f = try Fixture(linked: true)
        let url = "https://www.google.com/calendar/event?eid=verified-fixture"
        f.remote[f.key(f.email, "fixture-event")]?["htmlLink"] = url
        f.remote[f.key(f.email, "fixture-event")]?["reminders"] = [
            "useDefault": false, "overrides": [["method": "popup", "minutes": 30]]
        ]
        let session = CompanyWorkspaceSession(backendOrigin: "https://backend.example.invalid",
            email: f.email, tokenFingerprint: "fixture", expiresAt: .distantFuture)
        let stamp = CompanyWorkspaceOperationStamp(generation: UUID(), session: session)
        let noWorkspaceCheck = try await GoogleCalendarScheduleSync.checkGoogleLink(
            call: f.call, workflow: f.flow(), workspaceStamp: nil).get()
        #expect(noWorkspaceCheck.verifiedLink == nil)
        let check = try await GoogleCalendarScheduleSync.checkGoogleLink(
            call: f.call, workflow: f.flow(), workspaceStamp: stamp).get()
        #expect(check.missingEventReview == nil)
        #expect(check.alertGuidance == nil)
        let link = try #require(check.verifiedLink)
        #expect(link.url.absoluteString == url)
        #expect(link.matches(call: f.call, connectedEmail: f.email, workspaceStamp: stamp))
        #expect(!link.matches(call: f.call, connectedEmail: "other@gunnaire.com", workspaceStamp: stamp))
        #expect(!link.matches(call: f.call, connectedEmail: f.email, workspaceStamp: nil))
        let changedWorkspace = CompanyWorkspaceOperationStamp(generation: UUID(), session: session)
        #expect(!link.matches(call: f.call, connectedEmail: f.email, workspaceStamp: changedWorkspace))
        f.call.scheduledDate.addTimeInterval(60)
        #expect(!link.matches(call: f.call, connectedEmail: f.email, workspaceStamp: stamp))
        #expect(f.writes.isEmpty)
    }

    @Test func exactLinkedEventReportsExplicitReminderOptOutWithoutChangingGoogle() async throws {
        let f = try Fixture(linked: true)
        f.remote[f.key(f.email, "fixture-event")]?["reminders"] =
            ["useDefault": false, "overrides": []] as [String: Any]

        let check = try await GoogleCalendarScheduleSync.checkGoogleLink(
            call: f.call, workflow: f.flow()).get()

        #expect(check.missingEventReview == nil)
        #expect(check.alertGuidance?.contains("reminders are turned off") == true)
        #expect(check.alertGuidance?.contains("alert is not confirmed") == true)
        #expect(check.alertGuidance?.contains("Google Calendar") == true)
        let published = try await f.publish().get()
        #expect(published.contains("alert is not confirmed"))
        #expect(f.call.googleEventConfirmedAt != nil)
        #expect(f.writes.isEmpty)
        #expect(f.remote[f.key(f.email, "fixture-event")]?["reminders"] as? [String: Any] != nil)
    }

    @Test func linkedCalendarDefaultDoesNotMasqueradeAsAConfirmedPopup() async throws {
        let f = try Fixture(linked: true)
        f.remote[f.key(f.email, "fixture-event")]?["reminders"] = ["useDefault": true] as [String: Any]

        let checked = try await GoogleCalendarScheduleSync.checkGoogleLink(
            call: f.call, workflow: f.flow()).get()
        #expect(checked.missingEventReview == nil)
        #expect(checked.alertGuidance?.contains("30-minute popup alert is not confirmed") == true)

        let published = try await f.publish().get()
        #expect(published.contains("30-minute popup alert is not confirmed"))
        #expect(f.call.googleEventConfirmedAt != nil)
        let synchronized = try await (try f.flow()).run {
            try await GoogleCalendarScheduleSync.synchronize(workflow: $0,
                verifyConfirmedCalls: [f.call])
        }.get()
        #expect(synchronized.contains("30-minute popup alert is not confirmed"))
        #expect(f.writes.isEmpty)
        let unchanged = try #require(f.remote[f.key(f.email, "fixture-event")]?["reminders"] as? [String: Any])
        #expect(unchanged["useDefault"] as? Bool == true)
    }

    @Test func pendingLinkedReminderOptOutSurfacesInSyncWithoutOverwritingGoogle() async throws {
        let f = try Fixture(linked: true)
        f.remote[f.key(f.email, "fixture-event")]?["reminders"] = [
            "useDefault": false, "overrides": []
        ] as [String: Any]
        GoogleCalendarScheduleSync.markCalendarCallLocallyEdited(f.call)
        try f.context.save()

        let synchronized = try await (try f.flow()).run {
            try await GoogleCalendarScheduleSync.synchronize(workflow: $0)
        }.get()
        #expect(synchronized.contains("alert is not confirmed"))
        #expect(f.call.googleEventConfirmedAt != nil)
        #expect(f.writes.isEmpty)
        let unchanged = try #require(f.remote[f.key(f.email, "fixture-event")]?["reminders"] as? [String: Any])
        #expect((unchanged["overrides"] as? [[String: Any]])?.isEmpty == true)
    }

    @Test func allDayGoogleEventWithTimedAppointmentNeedsSpecificReview() async throws {
        let f = try Fixture(linked: true)
        f.remote[f.key(f.email, "fixture-event")]?["htmlLink"] =
            "https://www.google.com/calendar/event?eid=all-day"
        f.remote[f.key(f.email, "fixture-event")]?["start"] = ["date": "2027-01-15"]
        f.remote[f.key(f.email, "fixture-event")]?["end"] = ["date": "2027-01-16"]
        f.remote[f.key(f.email, "fixture-event")]?["reminders"] =
            ["useDefault": false, "overrides": []] as [String: Any]

        let result = await GoogleCalendarScheduleSync.checkGoogleLink(
            call: f.call, workflow: try f.flow())
        switch result {
        case .success:
            Issue.record("An all-day remote event must not verify a different timed appointment.")
        case .failure(let error):
            #expect(error.localizedDescription.contains("all-day event"))
            #expect(error.localizedDescription.contains("reminders are turned off"))
        }
        #expect(f.writes.isEmpty)
    }

    @Test func importedLinkedEventCanReportReminderOptOutReadOnly() async throws {
        let f = try Fixture(linked: true)
        f.call.googleEventManagedByApp = false
        try f.context.save()
        f.remote[f.key(f.email, "fixture-event")] = f.event(id: "fixture-event", managed: false)
        f.remote[f.key(f.email, "fixture-event")]?["reminders"] =
            ["useDefault": false, "overrides": []] as [String: Any]

        let check = try await GoogleCalendarScheduleSync.checkGoogleLink(
            call: f.call, workflow: f.flow()).get()

        #expect(check.missingEventReview == nil)
        #expect(check.alertGuidance?.contains("reminders are turned off") == true)
        #expect(f.call.googleEventManagedByApp == false)
        #expect(f.writes.isEmpty)
    }

    @Test func importedAllDayEventDoesNotHideStructuredArrivalWindowOrReminderOptOut() async throws {
        let f = try Fixture(linked: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let start = try #require(formatter.date(from: "2027-01-15"))
        f.call.googleEventManagedByApp = false
        f.call.scheduledDate = start
        f.call.duration = 86_400
        f.call.promisedArrivalWindowStart = start.addingTimeInterval(10 * 3600)
        f.call.promisedArrivalWindowEnd = start.addingTimeInterval(11 * 3600)
        try f.context.save()
        var event = f.event(id: "fixture-event", managed: false)
        event["start"] = ["date": "2027-01-15"]
        event["end"] = ["date": "2027-01-16"]
        event["reminders"] = ["useDefault": false, "overrides": []] as [String: Any]
        f.remote[f.key(f.email, "fixture-event")] = event

        let check = try await GoogleCalendarScheduleSync.checkGoogleLink(
            call: f.call, workflow: f.flow()).get()

        #expect(check.alertGuidance?.contains("all-day event") == true)
        #expect(check.alertGuidance?.contains("arrival window") == true)
        #expect(check.alertGuidance?.contains("reminders are turned off") == true)
        #expect(f.call.googleEventManagedByApp == false)
        #expect(f.writes.isEmpty)
    }

    @Test func unsafeOrUnverifiedProviderLinksAreNeverOffered() async throws {
        #expect(GoogleCalendarScheduleSync.VerifiedGoogleEventLink.safeProviderURL(
            "https://calendar.google.com/calendar/event?eid=valid") != nil)
        for raw in [
            "http://www.google.com/calendar/event?eid=unsafe",
            "https://evil.example/calendar/event?eid=unsafe",
            "https://user:pass@www.google.com/calendar/event?eid=unsafe",
            "https://www.google.com/redirect?to=calendar",
            "https://www.google.com:8443/calendar/event?eid=unsafe"
        ] {
            #expect(GoogleCalendarScheduleSync.VerifiedGoogleEventLink.safeProviderURL(raw) == nil)
        }
        let missing = try Fixture(linked: true)
        missing.remote.removeValue(forKey: missing.key(missing.email, "fixture-event"))
        let missingCheck = try await GoogleCalendarScheduleSync.checkGoogleLink(
            call: missing.call, workflow: missing.flow()).get()
        #expect(missingCheck.missingEventReview != nil)
        #expect(missingCheck.verifiedLink == nil)

        let changed = try Fixture(linked: true)
        changed.remote[changed.key(changed.email, "fixture-event")]?["htmlLink"] =
            "https://www.google.com/calendar/event?eid=old-slot"
        changed.remote[changed.key(changed.email, "fixture-event")]?["start"] = [
            "dateTime": ISO8601DateFormatter().string(from: changed.call.scheduledDate.addingTimeInterval(3600)),
            "timeZone": "UTC"
        ]
        let mismatched = await GoogleCalendarScheduleSync.checkGoogleLink(
            call: changed.call, workflow: try changed.flow())
        if case .success = mismatched {
            Issue.record("A mismatched remote event must not expose its provider link.")
        }
    }

    @Test func explicitMissingLinkRepairPublishesOwnerEventWhenStaffEmailIsInvalid() async throws {
        let f = try Fixture(linked: true)
        f.remote.removeValue(forKey: f.key(f.email, "fixture-event"))
        let technician = Technician(name: "Missing calendar email", contactInfo: "555-0100")
        f.context.insert(technician)
        f.call.assignedTechnician = technician
        try f.context.save()
        let review = try #require(try await GoogleCalendarScheduleSync.checkMissingEvent(
            call: f.call, workflow: f.flow()).get())
        let message = try await GoogleCalendarScheduleSync.repairMissingEvent(review).get()
        #expect(message.contains("Staff invitations need attention"))
        #expect(f.writes.count == 1)
        #expect(f.writes.first?.httpMethod == "POST")
        #expect(f.remote[f.key(f.email, "fixture-event")] != nil)
        #expect(f.staffInvitationsNeedAttention)
        #expect(GoogleCalendarScheduleSync.needsOutboundSync(f.call))
        technician.contactInfo = "tech@example.invalid"
        try f.context.save()
        _ = try await f.publish().get()
        #expect(f.writes.count == 2)
        #expect(f.writes.last?.httpMethod == "PATCH")
        #expect(!f.staffInvitationsNeedAttention)
    }

    @Test func missingLinkRepairRefusesMovedEventAndChangedJob() async throws {
        let moved = try Fixture(linked: true)
        moved.remote.removeValue(forKey: moved.key(moved.email, "fixture-event"))
        moved.calendarList.append(["id": "other@example.invalid", "primary": false, "accessRole": "owner"])
        moved.remote[moved.key("other@example.invalid", "fixture-event")] = moved.event(id: "fixture-event")
        let movedResult = await GoogleCalendarScheduleSync.checkMissingEvent(call: moved.call,
            workflow: try moved.flow())
        if case .success = movedResult { Issue.record("A moved event was offered for recreation") }
        #expect(moved.writes.isEmpty)

        let changed = try Fixture(linked: true)
        changed.remote.removeValue(forKey: changed.key(changed.email, "fixture-event"))
        let review = try #require(try await GoogleCalendarScheduleSync.checkMissingEvent(
            call: changed.call, workflow: changed.flow()).get())
        changed.call.scheduledDate = changed.call.scheduledDate.addingTimeInterval(3600)
        failed(await GoogleCalendarScheduleSync.repairMissingEvent(review))
        #expect(changed.writes.isEmpty)
        #expect(changed.call.googleEventID == "fixture-event")

        let durationChanged = try Fixture(linked: true)
        durationChanged.remote.removeValue(forKey: durationChanged.key(durationChanged.email, "fixture-event"))
        let durationReview = try #require(try await GoogleCalendarScheduleSync.checkMissingEvent(
            call: durationChanged.call, workflow: durationChanged.flow()).get())
        durationChanged.call.duration += 900
        try durationChanged.context.save()
        failed(await GoogleCalendarScheduleSync.repairMissingEvent(durationReview))
        #expect(durationChanged.writes.isEmpty)
    }

    @Test func missingLinkRepairReconcilesA409AndKeepsLostRepliesReserved() async throws {
        let raced = try Fixture(linked: true)
        raced.remote.removeValue(forKey: raced.key(raced.email, "fixture-event"))
        let review = try #require(try await GoogleCalendarScheduleSync.checkMissingEvent(
            call: raced.call, workflow: raced.flow()).get())
        raced.beforeReply = { request in
            if request.httpMethod == "POST" {
                var event = raced.event(id: "fixture-event")
                event["reminders"] = ["useDefault": false,
                    "overrides": [["method": "popup", "minutes": 30]]] as [String: Any]
                raced.remote[raced.key(raced.email, "fixture-event")] = event
            }
        }
        _ = try await GoogleCalendarScheduleSync.repairMissingEvent(review).get()
        #expect(raced.writes.map(\.httpMethod) == ["POST"])
        #expect(raced.call.googleEventID == "fixture-event")

        let noPopup = try Fixture(linked: true)
        noPopup.remote.removeValue(forKey: noPopup.key(noPopup.email, "fixture-event"))
        let noPopupReview = try #require(try await GoogleCalendarScheduleSync.checkMissingEvent(
            call: noPopup.call, workflow: noPopup.flow()).get())
        noPopup.beforeReply = { request in
            if request.httpMethod == "POST" {
                noPopup.remote[noPopup.key(noPopup.email, "fixture-event")] =
                    noPopup.event(id: "fixture-event")
            }
        }
        failed(await GoogleCalendarScheduleSync.repairMissingEvent(noPopupReview))
        #expect(noPopup.call.googleEventConfirmedAt == nil)
        #expect(noPopup.call.googleCalendarPendingAt != nil)
        #expect(noPopup.writes.filter { $0.httpMethod == "POST" }.count == 1)

        let collision = try Fixture(linked: true)
        collision.remote.removeValue(forKey: collision.key(collision.email, "fixture-event"))
        let collisionReview = try #require(try await GoogleCalendarScheduleSync.checkMissingEvent(
            call: collision.call, workflow: collision.flow()).get())
        collision.beforeReply = { request in
            if request.httpMethod == "POST" {
                var event = collision.event(id: "fixture-event", managed: false)
                event["reminders"] = ["useDefault": false,
                    "overrides": [["method": "popup", "minutes": 30]]] as [String: Any]
                collision.remote[collision.key(collision.email, "fixture-event")] = event
            }
        }
        failed(await GoogleCalendarScheduleSync.repairMissingEvent(collisionReview))
        #expect(collision.call.googleEventConfirmedAt == nil)
        #expect(collision.call.googleCalendarPendingAt != nil)
        #expect(collision.writes.filter { $0.httpMethod == "POST" }.count == 1)

        let lost = try Fixture(linked: true)
        lost.remote.removeValue(forKey: lost.key(lost.email, "fixture-event"))
        let lostReview = try #require(try await GoogleCalendarScheduleSync.checkMissingEvent(
            call: lost.call, workflow: lost.flow()).get())
        lost.afterWrite = { _ in throw URLError(.networkConnectionLost) }
        failed(await GoogleCalendarScheduleSync.repairMissingEvent(lostReview))
        #expect(lost.call.googleEventID == "fixture-event")
        #expect(lost.writes.count == 1)
        lost.afterWrite = nil
        let next = try await GoogleCalendarScheduleSync.checkMissingEvent(call: lost.call,
            workflow: lost.flow()).get()
        #expect(next == nil)
        #expect(lost.writes.count == 1)
    }

    @Test func failedReservationSavePreventsAnyPostAndRestoresOnlyLinkFields() async throws {
        let f = try Fixture()
        f.customer.name = "Unrelated unsaved customer edit"
        failed(try await f.publish(save: { _ in throw GoogleCalendarWorkflowError.saveFailed }))
        #expect(f.writes.isEmpty)
        #expect(f.call.googleEventID == nil)
        #expect(f.call.googleCalendarID == "primary")
        #expect(f.customer.name == "Unrelated unsaved customer edit")
    }

    @Test func failedConfirmationSaveRetainsReservationAndRecoveryDoesNotCreateTwice() async throws {
        let f = try Fixture()
        var saves = 0
        failed(try await f.publish(save: { context in
            saves += 1
            if saves == 2 { throw GoogleCalendarWorkflowError.saveFailed }
            try context.save()
        }))
        _ = try await f.publish().get()
        #expect(f.writes.count == 1)
        #expect(f.remote.count == 1)
    }

    @Test func schedulePatchUsesFreshEtagAndNeverImportsOverTheLocalJob() async throws {
        let f = try Fixture(linked: true)
        f.call.scheduledDate = f.call.scheduledDate.addingTimeInterval(7200)
        let scheduled = f.call.scheduledDate
        try f.context.save()
        _ = try await f.publish().get()
        #expect(f.writes.count == 1)
        #expect(f.writes.first?.httpMethod == "PATCH")
        #expect(f.writes.first?.value(forHTTPHeaderField: "If-Match") == "\"version-1\"")
        let body = try #require(JSONSerialization.jsonObject(with: f.writes[0].httpBody!) as? [String: Any])
        #expect(Set(body.keys) == ["start", "end"])
        #expect(f.call.scheduledDate == scheduled)
        #expect(f.call.notes == "Saved field observations")
    }

    @Test func concurrentGoogleEditStopsPatchWithoutRetryingOrChangingTheLocalSchedule() async throws {
        let f = try Fixture(linked: true)
        f.call.scheduledDate = f.call.scheduledDate.addingTimeInterval(7200)
        let expected = f.call.scheduledDate
        f.failPatch = true
        failed(try await f.publish())
        #expect(f.writes.count == 1)
        #expect(f.call.scheduledDate == expected)
    }

    @Test func missingEtagCannotAuthorizeAnUpdate() async throws {
        let f = try Fixture(linked: true)
        f.remote[f.key(f.email, "fixture-event")]?.removeValue(forKey: "etag")
        f.call.scheduledDate = f.call.scheduledDate.addingTimeInterval(7200)
        failed(try await f.publish())
        #expect(f.writes.isEmpty)
    }

    @Test func changedRolePreventsTheNextRequestAndEveryLocalSave() async throws {
        let f = try Fixture()
        f.beforeReply = { _ in f.authorized = false }
        failed(try await f.publish())
        #expect(f.requests.count == 1)
        #expect(f.writes.isEmpty)
        #expect(f.call.googleEventID == nil)
    }

    @Test func changedProviderBeforeTaskStartsCannotReuseTheRetainedJob() async throws {
        let f = try Fixture()
        let flow = try f.flow()
        f.auth.signOut()
        failed(await flow.run { try await GoogleCalendarScheduleSync.publish(call: f.call, workflow: $0) })
        #expect(f.requests.isEmpty)
    }

    @Test func changedProviderDuringReadCannotStartAReplacementAccountWrite() async throws {
        let f = try Fixture()
        f.beforeReply = { _ in f.auth.signOut() }
        failed(try await f.publish())
        #expect(f.requests.count == 1)
        #expect(f.writes.isEmpty)
        #expect(f.auth.accessToken == nil)
    }

    @Test func expiredBackgroundRefreshCannotWriteAfterCalendarCallbackRead() async throws {
        let f = try Fixture(linked: true)
        f.call.scheduledDate = f.call.scheduledDate.addingTimeInterval(3600)
        f.call.googleCalendarPendingAt = Date()
        try f.context.save()
        var expired = false
        let workflow = try f.flow()
        GoogleCalendarScheduleSync.installBackgroundExpirationFence(on: workflow) { expired }
        f.beforeReply = { request in
            if request.httpMethod == "GET", request.url?.path.hasSuffix("fixture-event") == true {
                expired = true
            }
        }
        failed(await workflow.run { try await GoogleCalendarScheduleSync.publish(call: f.call, workflow: $0) })
        #expect(f.writes.isEmpty)
        #expect(f.call.googleCalendarPendingAt != nil)
    }

    @Test func expiredBackgroundRefreshRetainsExactReservationDuringSuspendedCreate() async throws {
        let f = try Fixture()
        var expired = false
        let workflow = try f.flow()
        GoogleCalendarScheduleSync.installBackgroundExpirationFence(on: workflow) { expired }
        f.beforeReply = { request in
            guard request.httpMethod == "POST" else { return }
            // The request has left the app; iOS can expire the refresh while
            // the transport waits for a response it cannot safely recall.
            expired = true
            try await Task.sleep(for: .milliseconds(30))
        }
        failed(await workflow.run { try await GoogleCalendarScheduleSync.publish(call: f.call, workflow: $0) })
        let reservedID = GoogleCalendarScheduleSync.eventID(for: f.call.id)
        #expect(f.call.googleEventID == reservedID)
        #expect(f.call.googleCalendarPendingAt != nil)
        #expect(f.call.googleEventConfirmedAt == nil)
        #expect(f.writes.map(\.httpMethod) == ["POST"])
        #expect(f.remote[f.key(f.email, reservedID)] != nil)
    }

    @Test func localEditDuringReadIsPreservedWithoutPublishingStaleValues() async throws {
        let f = try Fixture()
        f.beforeReply = { _ in f.call.notes = "New technician findings during sync" }
        failed(try await f.publish())
        #expect(f.writes.isEmpty)
        #expect(f.call.notes == "New technician findings during sync")
    }

    @Test func unrelatedSavedJobChangeDuringGoogleReadDoesNotDelayThisAppointment() async throws {
        let f = try Fixture()
        let unrelated = ServiceCall(type: .service, scheduledDate: f.call.scheduledDate,
                                    customer: f.customer, notes: "Unrelated job")
        f.context.insert(unrelated)
        try f.context.save()
        var changed = false
        f.beforeReply = { request in
            guard !changed, request.httpMethod == "GET", request.url?.path.contains("/events/") == true else { return }
            changed = true
            unrelated.notes = "Field update for another job"
            try f.context.save()
        }
        _ = try await f.publish().get()
        #expect(changed)
        #expect(f.writes.filter { $0.httpMethod == "POST" }.count == 1)
        #expect(unrelated.notes == "Field update for another job")
    }

    @Test func savedTargetChangeDuringGoogleReadCannotStartAWriteFromOldSnapshot() async throws {
        let f = try Fixture()
        var changed = false
        f.beforeReply = { request in
            guard !changed, request.httpMethod == "GET", request.url?.path.contains("/events/") == true else { return }
            changed = true
            f.call.notes = "New target findings"
            try f.context.save()
        }
        failed(try await f.publish())
        #expect(changed)
        #expect(f.writes.isEmpty)
        #expect(f.call.notes == "New target findings")
    }

    @Test func crewEmailChangeDuringGoogleReadCannotInviteThePreviousRecipient() async throws {
        let f = try Fixture()
        let crew = Technician(name: "Crew", contactInfo: "first-crew@example.invalid")
        f.context.insert(crew)
        f.call.additionalTechnicianIDs = [crew.id]
        try f.context.save()
        var changed = false
        f.beforeReply = { request in
            guard !changed, request.httpMethod == "GET", request.url?.path.contains("/events/") == true else { return }
            changed = true
            crew.contactInfo = "second-crew@example.invalid"
            try f.context.save()
        }
        failed(try await f.publish())
        #expect(changed)
        #expect(f.writes.isEmpty)
    }

    @Test func savedGoogleRouteNamesPrimaryAndAssignedTechnicianCalendar() throws {
        let f = try Fixture(linked: true)
        #expect(GoogleCalendarScheduleSync.calendarRouteLabel(for: f.call, connectedEmail: f.email) ==
                "Google calendar: Primary (\(f.email))")
        let technician = Technician(name: "Riley", contactInfo: "riley@example.invalid")
        f.context.insert(technician)
        f.call.assignedTechnician = technician
        f.call.googleCalendarID = "riley@example.invalid"
        #expect(GoogleCalendarScheduleSync.calendarRouteLabel(for: f.call, connectedEmail: f.email) ==
                "Google calendar: Riley (riley@example.invalid)")
    }

    @Test func pendingAppManagedJobShowsSavedCalendarWithoutClaimingPublication() throws {
        let f = try Fixture()
        f.call.status = .scheduled
        f.call.googleCalendarPendingAt = Date()
        #expect(ScheduleGoogleLinkStatus.selectedPendingRouteLabel(f.call) ==
                "Selected Google calendar: Primary (pending)")

        f.call.googleCalendarID = "dispatch@group.calendar.google.com"
        #expect(ScheduleGoogleLinkStatus.selectedPendingRouteLabel(f.call) ==
                "Selected Google calendar: dispatch@group.calendar.google.com (pending)")

        f.call.googleEventManagedByApp = false
        #expect(ScheduleGoogleLinkStatus.selectedPendingRouteLabel(f.call) == nil)
        f.call.googleEventManagedByApp = true
        f.call.googleCalendarPendingAt = nil
        #expect(ScheduleGoogleLinkStatus.selectedPendingRouteLabel(f.call) == nil)
        f.call.googleCalendarPendingAt = Date()
        f.call.googleEventID = "confirmed-event"
        #expect(ScheduleGoogleLinkStatus.selectedPendingRouteLabel(f.call) == nil)
    }

    /// The schedule's immediate send failed on-device with "The appointment or
    /// related records changed during sync" because any record in the store
    /// changing mid-request (a CloudKit merge from another device) aborted it.
    @Test func unrelatedRecordChangesDuringASingleJobSendStillPublishIt() async throws {
        let f = try Fixture()
        let other = Customer(name: "Other customer")
        let otherCall = ServiceCall(googleEventManagedByApp: true, eventTitle: "Other visit", type: .service,
            scheduledDate: Date(timeIntervalSince1970: 1_800_100_000), duration: 1800, customer: other)
        f.context.insert(other); f.context.insert(otherCall)
        try f.context.save()
        var merged = false
        f.beforeReply = { _ in
            guard !merged else { return }
            merged = true
            other.name = "Renamed on another device"
            otherCall.notes = "Edited on another device"
            f.context.insert(Customer(name: "Created on another device"))
            try f.context.save()
        }
        let result = await (try f.flow(scope: [f.call])).run {
            try await GoogleCalendarScheduleSync.publish(call: f.call, workflow: $0)
        }
        #expect(try result.get().contains("Schedule confirmed in Google Calendar"))
        #expect(f.writes.map(\.httpMethod) == ["POST"])
        #expect(f.call.googleEventID == GoogleCalendarScheduleSync.eventID(for: f.call.id))
    }

    @Test func scopedSendStillStopsWhenTheJobsOwnCustomerChanges() async throws {
        let f = try Fixture()
        f.beforeReply = { _ in f.customer.address = "Moved during sync" }
        let result = await (try f.flow(scope: [f.call])).run {
            try await GoogleCalendarScheduleSync.publish(call: f.call, workflow: $0)
        }
        // The in-flight request's own validity check reports the change, as in
        // localEditDuringReadIsPreservedWithoutPublishingStaleValues.
        failed(result)
        #expect(!f.requests.isEmpty)
        #expect(f.writes.isEmpty)
        #expect(f.customer.address == "Moved during sync")
    }

    @Test func scopedSendStillStopsWhenTheAssignedTechnicianChanges() async throws {
        let f = try Fixture()
        let technician = Technician(name: "Fixture technician", contactInfo: "technician@gunnaire.com")
        f.context.insert(technician)
        f.call.assignedTechnician = technician
        try f.context.save()
        f.beforeReply = { _ in technician.contactInfo = "changed@gunnaire.com" }
        let result = await (try f.flow(scope: [f.call])).run {
            try await GoogleCalendarScheduleSync.publish(call: f.call, workflow: $0)
        }
        // The in-flight request's own validity check reports the change, as in
        // localEditDuringReadIsPreservedWithoutPublishingStaleValues.
        failed(result)
        #expect(!f.requests.isEmpty)
        #expect(f.writes.isEmpty)
    }

    @Test func syncPublishesAPendingJobDespiteAnUnrelatedMergeDuringItsSend() async throws {
        let f = try Fixture()
        f.call.scheduledDate = Date().addingTimeInterval(3600)
        let other = Customer(name: "Other customer")
        f.context.insert(other)
        try f.context.save()
        var merged = false
        f.beforeReply = { _ in
            guard !merged else { return }
            merged = true
            other.name = "Renamed on another device"
            try f.context.save()
        }
        let result = await (try f.flow()).run { try await GoogleCalendarScheduleSync.synchronize(workflow: $0) }
        #expect(try result.get().contains("Published 1"))
        #expect(f.writes.map(\.httpMethod) == ["POST"])
    }

    /// Imported events used to be read-only, so rescheduling or staffing an
    /// imported job never reached Google.
    private func importedFixture(marker: String? = nil) throws -> Fixture {
        let f = try Fixture(linked: true)
        f.call.googleEventManagedByApp = false
        var remote = f.event(id: "fixture-event", managed: false)
        remote["description"] = "Owner's Google notes"
        if let marker {
            remote["extendedProperties"] = ["private": ["gunnaireServiceCallID": marker, "ownerKey": "kept"]]
        } else {
            remote["extendedProperties"] = ["private": ["ownerKey": "kept"]]
        }
        f.remote[f.key(f.email, "fixture-event")] = remote
        try f.context.save()
        return f
    }

    @Test func rescheduledImportedEventIsMarkedManagedAndPatchedInPlace() async throws {
        let f = try importedFixture()
        f.call.scheduledDate = f.call.scheduledDate.addingTimeInterval(7200)
        try f.context.save()
        GoogleCalendarScheduleSync.markCalendarCallLocallyEdited(f.call)
        #expect(GoogleCalendarScheduleSync.isWriteBackRequested(f.call))
        #expect(GoogleCalendarScheduleSync.needsOutboundSync(f.call))
        let result = await (try f.flow(scope: [f.call])).run {
            try await GoogleCalendarScheduleSync.publish(call: f.call, workflow: $0)
        }
        #expect(try result.get().contains("Schedule confirmed in Google Calendar"))
        #expect(!f.writes.isEmpty)
        #expect(f.writes.allSatisfy { $0.httpMethod == "PATCH" })
        let first = try #require(f.writes.first)
        #expect(first.url?.query == "sendUpdates=none")
        let firstBodyData = try #require(first.httpBody)
        let firstBody = try #require(JSONSerialization.jsonObject(with: firstBodyData) as? [String: Any])
        #expect(Set(firstBody.keys) == ["extendedProperties"])
        let remote = try #require(f.remote[f.key(f.email, "fixture-event")])
        let event = try f.decoded(remote)
        #expect(event.isManagedByGunnAire)
        #expect(event.extendedProperties?.privateProperties?["gunnaireServiceCallID"] == f.call.id.uuidString)
        #expect(event.extendedProperties?.privateProperties?["ownerKey"] == "kept")
        #expect(event.description == "Owner's Google notes")
        #expect(event.summary == "Repair visit")
        #expect(GoogleCalendarScheduleSync.remoteEventMatchesScheduleSlot(call: f.call, remoteEvent: event))
        #expect(f.call.googleEventManagedByApp)
        #expect(f.remote.count == 1)
        #expect(!GoogleCalendarScheduleSync.isWriteBackRequested(f.call))
        #expect(!GoogleCalendarScheduleSync.needsOutboundSync(f.call))
    }

    @Test func importedEventWithoutAWriteBackRequestIsNeverWritten() async throws {
        let f = try importedFixture()
        let result = await (try f.flow(scope: [f.call])).run {
            try await GoogleCalendarScheduleSync.publish(call: f.call, workflow: $0)
        }
        #expect(try result.get().contains("Skipped"))
        #expect(f.writes.isEmpty)
        #expect(!f.call.googleEventManagedByApp)
    }

    @Test func importedCustomerOnlySaveDoesNotQueueButPersistedScheduleIntentSurvivesMarkerLoss() throws {
        let f = try importedFixture()
        f.customer.address = "Updated billing address"
        #expect(try ServiceCallCalendarOutbox.save(f.call, shouldPublish: false) {
            try f.context.save()
        } == false)
        #expect(f.call.googleCalendarPendingAt == nil)
        #expect(!GoogleCalendarScheduleSync.isWriteBackRequested(f.call))
        #expect(!GoogleCalendarScheduleSync.needsOutboundSync(f.call))

        f.call.scheduledDate = f.call.scheduledDate.addingTimeInterval(3600)
        #expect(try ServiceCallCalendarOutbox.save(f.call, shouldPublish: true) {
            try f.context.save()
        })
        // The app can stop before markCalendarCallLocallyEdited writes defaults.
        // The saved outbox date alone must recover the intended adoption.
        #expect(f.call.googleCalendarPendingAt != nil)
        #expect(GoogleCalendarScheduleSync.isWriteBackRequested(f.call))
        #expect(GoogleCalendarScheduleSync.needsOutboundSync(f.call))
    }

    @Test func importedEventMarkedForAnotherJobIsNotAdopted() async throws {
        let f = try importedFixture(marker: UUID().uuidString)
        GoogleCalendarScheduleSync.markCalendarCallLocallyEdited(f.call)
        failed(await (try f.flow(scope: [f.call])).run {
            try await GoogleCalendarScheduleSync.publish(call: f.call, workflow: $0)
        })
        #expect(f.writes.isEmpty)
        #expect(!f.call.googleEventManagedByApp)
    }

    @Test func cancelledImportedJobIsNeverQueuedForWriteBack() throws {
        let f = try importedFixture()
        f.call.status = .cancelled
        GoogleCalendarScheduleSync.markCalendarCallLocallyEdited(f.call)
        #expect(!GoogleCalendarScheduleSync.isWriteBackRequested(f.call))
        #expect(!GoogleCalendarScheduleSync.needsOutboundSync(f.call))
    }

    @Test func deletedModelDuringReadCannotBeLinkedOrDereferencedForPublication() async throws {
        let f = try Fixture()
        f.beforeReply = { _ in f.context.delete(f.call); try f.context.save() }
        failed(try await f.publish())
        #expect(f.writes.isEmpty)
        #expect(try f.context.fetch(FetchDescriptor<ServiceCall>()).isEmpty)
    }

    @Test func overlappingCalendarOperationsAreRejectedWhileTheOriginalContinues() async throws {
        let f = try Fixture()
        var checked = false
        f.beforeReply = { _ in
            guard !checked else { return }
            checked = true
            let second = try f.flow()
            let outcome = await second.run { _ in Issue.record("Overlapping action ran"); return "Unexpected" }
            if case .failure(let error) = outcome { #expect(error as? GoogleCalendarWorkflowError == .busy) }
            else { Issue.record("Overlapping calendar action succeeded") }
        }
        _ = try await f.publish().get()
        #expect(checked)
        #expect(f.writes.count == 1)
    }

    @Test func closeSavedAppointmentsPublishInOrderWithoutLosingTheSecondOutboxEntry() async throws {
        let f = try Fixture()
        f.call.googleCalendarPendingAt = Date()
        let secondCall = ServiceCall(googleCalendarID: "primary", googleCalendarPendingAt: Date(),
            googleEventManagedByApp: true,
            eventTitle: "Second repair visit", type: .repair,
            scheduledDate: f.call.scheduledDate.addingTimeInterval(7200), duration: 3600,
            customer: f.customer)
        f.context.insert(secondCall)
        try f.context.save()
        let firstWorkflow = try f.flow()
        let secondWorkflow = try f.flow()

        let outcomes: [Result<String, Error>] = await withCheckedContinuation { continuation in
            var completed: [Result<String, Error>] = []
            let record: (Result<String, Error>) -> Void = { result in
                completed.append(result)
                if completed.count == 2 { continuation.resume(returning: completed) }
            }
            GoogleCalendarScheduleSync.runQueued(workflow: firstWorkflow, container: f.context.container,
                action: { try await GoogleCalendarScheduleSync.publish(call: f.call, workflow: $0) },
                completion: record)
            GoogleCalendarScheduleSync.runQueued(workflow: secondWorkflow, container: f.context.container,
                action: { try await GoogleCalendarScheduleSync.publish(call: secondCall, workflow: $0) },
                completion: record)
        }

        #expect(outcomes.count == 2)
        for outcome in outcomes { _ = try outcome.get() }
        #expect(f.writes.filter { $0.httpMethod == "POST" }.count == 2)
        #expect(f.call.googleEventID != nil)
        #expect(secondCall.googleEventID != nil)
        #expect(f.call.googleEventID != secondCall.googleEventID)
        #expect(f.call.googleEventConfirmedAt != nil)
        #expect(secondCall.googleEventConfirmedAt != nil)
        #expect(f.call.googleCalendarPendingAt == nil)
        #expect(secondCall.googleCalendarPendingAt == nil)
    }

    @Test func staleOrReadOnlySelectedCalendarNeverFallsBackToPrimary() async throws {
        for missing in [false, true] {
            let f = try Fixture()
            f.call.googleCalendarID = "selected-calendar"
            if !missing { f.calendarList.append(["id": "selected-calendar", "accessRole": "reader"]) }
            failed(try await f.publish())
            #expect(f.requests.count == 1)
            #expect(f.writes.isEmpty)
            #expect(f.call.googleCalendarID == "selected-calendar")
        }
    }

    @Test func selectedCalendarIDMatchingSummaryOrCaseDoesNotFallbackToPrimary() async throws {
        let f = try Fixture()
        f.call.scheduledDate = Date().addingTimeInterval(3600)
        f.call.googleCalendarID = "TEAM@GUNNAIRE.EXAMPLE.COM"
        f.calendarList = [
            ["id": "team-calendar-id", "summary": "team@gunnaire.example.com", "accessRole": "owner"],
            ["id": f.email, "primary": true, "accessRole": "owner"]
        ]
        _ = try await f.publish().get()
        #expect(f.requests.contains { request in
            request.httpMethod == "POST" && request.url?.path == "/calendar/v3/calendars/team-calendar-id/events"
        })
    }

    @Test func requestedCalendarIDIsCaseInsensitiveIfNoPrimaryMatch() async throws {
        let f = try Fixture()
        f.call.scheduledDate = Date().addingTimeInterval(3600)
        f.call.googleCalendarID = "Primary@GUNNAIRE.EXAMPLE.COM"
        f.calendarList.append(["id": "primary@gunnaire.example.com", "accessRole": "owner", "summary": "Primary GunnAire Calendar"])
        f.calendarList.append(["id": "secondary@gunnaire.example.com", "accessRole": "owner", "summary": "Secondary"])
        _ = try await f.publish().get()
        #expect(f.requests.contains { request in
            request.httpMethod == "POST" && request.url?.path == "/calendar/v3/calendars/primary@gunnaire.example.com/events"
        })
    }

    @Test func foreignRemoteIdentityCannotBeSavedAsTheOriginalEvent() async throws {
        let f = try Fixture(linked: true)
        f.remote[f.key(f.email, "fixture-event")] = f.event(id: "different-event")
        failed(try await f.publish())
        #expect(f.writes.isEmpty)
        #expect(f.call.googleEventID == "fixture-event")
    }

    @Test func markerForAnotherLocalJobCannotAuthorizePatchOrRecovery() async throws {
        let f = try Fixture(linked: true)
        f.remote[f.key(f.email, "fixture-event")]?["extendedProperties"] = ["private": [
            "gunnaireManaged": "true", "gunnaireManagedVersion": "4", "gunnaireOrigin": "ios-app",
            "gunnaireServiceCallID": UUID().uuidString
        ]]
        failed(try await f.publish())
        #expect(f.writes.isEmpty)
    }

    @Test func cancelledJobDeletesOnlyItsExactCurrentManagedEventVersion() async throws {
        let f = try Fixture(linked: true)
        f.call.googleEventID = UUID().uuidString
        let id = try #require(f.call.googleEventID)
        f.remote = [f.key(f.email, id): f.event(id: id)]
        f.call.status = .cancelled
        let result = await (try f.flow()).run { try await GoogleCalendarScheduleSync.cancel(call: f.call, workflow: $0) }
        _ = try result.get()
        #expect(f.writes.count == 1)
        #expect(f.writes[0].httpMethod == "DELETE")
        #expect(f.writes[0].value(forHTTPHeaderField: "If-Match") == "\"version-1\"")
        #expect(f.call.status == .cancelled)
        #expect(f.call.googleEventID == id)
    }

    @Test func activeJobCannotSendCancellation() async throws {
        let f = try Fixture(linked: true)
        failed(await (try f.flow()).run { try await GoogleCalendarScheduleSync.cancel(call: f.call, workflow: $0) })
        #expect(f.requests.isEmpty)
    }

    @Test func cancelledExternalEventIsNeverDeletedByTheApp() async throws {
        let f = try Fixture(linked: true)
        f.call.status = .cancelled
        f.remote[f.key(f.email, "fixture-event")] = f.event(id: "fixture-event", managed: false)
        failed(await (try f.flow()).run { try await GoogleCalendarScheduleSync.cancel(call: f.call, workflow: $0) })
        #expect(f.writes.isEmpty)
    }

    @Test func importEnumeratesThePrimaryCalendarOnceUsingItsCanonicalID() async throws {
        let f = try Fixture()
        _ = try await f.sync().get()
        #expect(f.requests.count == 2)
        #expect(f.requests.last?.url?.path == "/calendar/v3/calendars/\(f.email)/events")
        #expect(f.writes.isEmpty)
    }

    @Test func importDoesNotMatchJobsByTitleTimeOrAnUnscopedEventID() throws {
        let f = try Fixture(linked: true)
        let remote = try f.decoded(f.event(id: "fixture-event", managed: false))
        let summary = try GoogleCalendarScheduleSync.importEvents([
            ("different-calendar", remote),
            ("third-calendar", remote)
        ], into: f.context, signedInEmail: f.email, primaryCalendarID: f.email)
        let calls = try f.context.fetch(FetchDescriptor<ServiceCall>())
        #expect(summary.importedCount == 2)
        #expect(calls.count == 3)
        #expect(f.call.googleCalendarID == "primary")
        #expect(calls.filter { $0.googleCalendarID == "different-calendar" }.count == 1)
        #expect(calls.filter { $0.googleCalendarID == "third-calendar" }.count == 1)
    }

    @Test func duplicateRemoteIdentityFailsBeforeAnyPartialImport() throws {
        let f = try Fixture()
        let event = try f.decoded(f.event(id: "duplicate", managed: false))
        #expect(throws: GoogleCalendarWorkflowError.identity) {
            try GoogleCalendarScheduleSync.importEvents([(f.email, event), (f.email, event)],
                into: f.context, signedInEmail: f.email)
        }
        #expect(try f.context.fetch(FetchDescriptor<ServiceCall>()).count == 1)
    }

    @Test func duplicateLocalLinksRequireReviewInsteadOfPickingOne() throws {
        let f = try Fixture(linked: true)
        let duplicate = ServiceCall(googleCalendarID: f.email, googleEventID: "fixture-event",
            type: .repair, scheduledDate: f.call.scheduledDate, customer: f.customer)
        f.context.insert(duplicate)
        let event = try f.decoded(f.event(id: "fixture-event", managed: false))
        #expect(throws: GoogleCalendarWorkflowError.identity) {
            try GoogleCalendarScheduleSync.importEvents([(f.email, event)], into: f.context,
                signedInEmail: f.email, primaryCalendarID: f.email)
        }
        #expect(f.call.googleCalendarID == "primary")
    }

    @Test func importPreservesCommittedJobsCustomerDetailsAndLocalSchedule() throws {
        let f = try Fixture(linked: true)
        let original = f.call.scheduledDate
        let event = try f.decoded(f.event(id: "fixture-event", start: original.addingTimeInterval(7200)))
        let result = try GoogleCalendarScheduleSync.importEvents([(f.email, event)],
            into: f.context, signedInEmail: f.email, primaryCalendarID: f.email)
        #expect(result.importedCount == 0)
        #expect(result.restrictedReviewCount == 1)
        #expect(f.call.scheduledDate == original)
        #expect(f.call.customer === f.customer)
        #expect(f.customer.address == "Local service address")
        #expect(f.call.notes == "Saved field observations")
    }

    @Test func duplicateCustomerEmailsRemainUnassignedAndNeverModifyEitherCustomer() throws {
        let f = try Fixture()
        let duplicate = Customer(name: "Second customer", email: f.customer.email)
        f.context.insert(duplicate)
        var data = f.event(id: "new-event", managed: false)
        data["attendees"] = [["email": f.customer.email!, "displayName": f.customer.name]]
        let event = try f.decoded(data)
        _ = try GoogleCalendarScheduleSync.importEvents([(f.email, event)], into: f.context, signedInEmail: f.email)
        let imported = try #require(f.context.fetch(FetchDescriptor<ServiceCall>()).first { $0.googleEventID == "new-event" })
        #expect(CustomerDataMaintenance.isSystemCalendarCustomer(imported.customer))
        #expect(f.customer.address == "Local service address")
        #expect(duplicate.address == nil)
    }

    @Test func importedSharedCalendarDoesNotInventATechnician() throws {
        let f = try Fixture()
        let event = try f.decoded(f.event(id: "shared-event", managed: false))
        _ = try GoogleCalendarScheduleSync.importEvents([("shared@group.calendar.google.com", event)],
            into: f.context, signedInEmail: f.email)
        #expect(try f.context.fetch(FetchDescriptor<Technician>()).isEmpty)
    }

    @Test func importSaveFailureRemovesOnlyNewBatchRecordsAndPreservesUnrelatedEdits() throws {
        let f = try Fixture()
        f.customer.name = "Unrelated unsaved edit"
        let event = try f.decoded(f.event(id: "new-event", managed: false))
        #expect(throws: GoogleCalendarWorkflowError.saveFailed) {
            try GoogleCalendarScheduleSync.importEvents([(f.email, event)], into: f.context,
                signedInEmail: f.email, save: { throw GoogleCalendarWorkflowError.saveFailed })
        }
        #expect(try f.context.fetch(FetchDescriptor<ServiceCall>()).count == 1)
        #expect(try f.context.fetch(FetchDescriptor<Customer>()).count == 1)
        #expect(f.customer.name == "Unrelated unsaved edit")
    }

    @Test func lateImportAfterLocalChangeDoesNotApplyAnyCalendarRows() async throws {
        let f = try Fixture()
        f.remote[f.key(f.email, "new-event")] = f.event(id: "new-event", managed: false)
        f.beforeReply = { request in
            if request.url!.path.hasSuffix("/events") { f.customer.name = "Local edit while fetching" }
        }
        failed(try await f.sync())
        #expect(try f.context.fetch(FetchDescriptor<ServiceCall>()).count == 1)
        #expect(f.customer.name == "Local edit while fetching")
    }

    @Test func savedCustomerChangeDuringCalendarFetchCannotImportFromStaleSnapshot() async throws {
        let f = try Fixture()
        f.remote[f.key(f.email, "new-event")] = f.event(id: "new-event", managed: false)
        f.beforeReply = { request in
            guard request.url?.path.hasSuffix("/events") == true else { return }
            f.customer.name = "Saved during remote read"
            try f.context.save()
        }
        failed(try await f.sync())
        #expect(try f.context.fetch(FetchDescriptor<ServiceCall>()).count == 1)
        #expect(f.customer.name == "Saved during remote read")
    }

    @Test func lostAuthorityOnAnotherCalendarRejectsTheWholeImport() async throws {
        let f = try Fixture()
        f.calendarList.append(["id": "second-calendar", "accessRole": "reader"])
        f.remote[f.key(f.email, "new-event")] = f.event(id: "new-event", managed: false)
        f.beforeReply = { request in
            if request.url!.path.contains("/second-calendar/") { f.authorized = false }
        }
        failed(try await f.sync())
        #expect(try f.context.fetch(FetchDescriptor<ServiceCall>()).count == 1)
        #expect(f.writes.isEmpty)
    }

    @Test func exactEventIDsAreCaseSensitiveAndDoNotCollapseDistinctRows() throws {
        let f = try Fixture()
        let upper = try f.decoded(f.event(id: "Event-A", managed: false))
        let lower = try f.decoded(f.event(id: "event-a", managed: false))
        let result = try GoogleCalendarScheduleSync.importEvents([(f.email, upper), (f.email, lower)],
            into: f.context, signedInEmail: f.email)
        #expect(result.importedCount == 2)
    }

    @Test func malformedPrimaryCalendarListFailsWithoutGuessingAnAlias() async throws {
        let f = try Fixture()
        f.calendarList.append(["id": "other-primary", "primary": true, "accessRole": "owner"])
        failed(try await f.publish())
        #expect(f.requests.count == 1)
        #expect(f.writes.isEmpty)
    }


    @Test func serverVerifiedDispatchRoleAndExactActiveLocalIdentityAreBothRequired() {
        for role in AppUserRole.allCases {
            let user = AppUser(email: "dispatcher@example.invalid", role: role)
            #expect(GoogleCalendarWorkflow.allowsDispatch(email: user.email, currentEmail: user.email,
                users: [user], verifiedRole: role) == (role == .admin || role == .dispatcher))
            #expect(!GoogleCalendarWorkflow.allowsDispatch(email: user.email, currentEmail: "other@example.invalid",
                users: [user], verifiedRole: role))
        }
        let user = AppUser(email: AppAccess.primaryAdminEmail, role: .admin)
        #expect(!GoogleCalendarWorkflow.allowsDispatch(email: user.email, currentEmail: user.email, users: [], verifiedRole: .admin))
        #expect(!GoogleCalendarWorkflow.allowsDispatch(email: user.email, currentEmail: user.email, users: [user], verifiedRole: .dispatcher))
        #expect(!GoogleCalendarWorkflow.allowsDispatch(email: user.email, currentEmail: user.email, users: [user], verifiedRole: nil))
        let inactive = AppUser(email: user.email, role: .admin, isActive: false)
        #expect(!GoogleCalendarWorkflow.allowsDispatch(email: user.email, currentEmail: user.email, users: [user, inactive], verifiedRole: .admin))
    }

    @Test func confirmedManagedRemovalDeletesRemoteBeforeRemovingTheLocalEntry() async throws {
        let f = try Fixture(linked: true)
        f.beforeReply = { request in
            if request.httpMethod == "DELETE" {
                let retained = try f.context.fetch(FetchDescriptor<ServiceCall>())
                #expect(retained.contains { $0 === f.call })
            }
        }
        let result = await (try f.flow()).run { try await GoogleCalendarScheduleSync.remove(call: f.call, workflow: $0) }
        _ = try result.get()
        #expect(f.writes.count == 1)
        #expect(f.remote.isEmpty)
        #expect(try f.context.fetch(FetchDescriptor<ServiceCall>()).isEmpty)
    }

    @Test func failedManagedRemovalRetainsTheLocalEntryAndItsExactLink() async throws {
        let f = try Fixture(linked: true)
        f.beforeReply = { request in
            if request.httpMethod == "DELETE" { throw URLError(.timedOut) }
        }
        failed(await (try f.flow()).run { try await GoogleCalendarScheduleSync.remove(call: f.call, workflow: $0) })
        #expect(try f.context.fetch(FetchDescriptor<ServiceCall>()).contains { $0 === f.call })
        #expect(f.call.googleEventID == "fixture-event")
        #expect(f.remote.count == 1)
    }

    @Test func removalKeepsLocalJobWhenOriginalIDMovedToAnotherCalendar() async throws {
        let f = try Fixture(linked: true)
        f.remote.removeValue(forKey: f.key(f.email, "fixture-event"))
        let otherCalendar = "other-calendar@example.invalid"
        f.calendarList.append(["id": otherCalendar, "primary": false, "accessRole": "writer"])
        f.remote[f.key(otherCalendar, "fixture-event")] = f.event(id: "fixture-event")

        let result = await (try f.flow()).run { try await GoogleCalendarScheduleSync.remove(call: f.call, workflow: $0) }
        guard case .failure(let error) = result else {
            Issue.record("A moved event must not allow local job removal")
            return
        }
        #expect(error as? GoogleCalendarWorkflowError == .needsReview)
        #expect(f.writes.isEmpty)
        #expect(f.call.googleEventID == "fixture-event")
        #expect(try f.context.fetch(FetchDescriptor<ServiceCall>()).contains { $0 === f.call })
    }

    @Test func lostDeleteResponseIsReconciledByReadWithoutAnotherDelete() async throws {
        let f = try Fixture(linked: true)
        f.afterWrite = { _ in throw URLError(.networkConnectionLost) }
        failed(await (try f.flow()).run { try await GoogleCalendarScheduleSync.remove(call: f.call, workflow: $0) })
        #expect(try f.context.fetch(FetchDescriptor<ServiceCall>()).contains { $0 === f.call })
        f.afterWrite = nil
        _ = try await (try f.flow()).run { try await GoogleCalendarScheduleSync.remove(call: f.call, workflow: $0) }.get()
        #expect(f.writes.count == 1)
        #expect(try f.context.fetch(FetchDescriptor<ServiceCall>()).isEmpty)
    }

    @Test func localDeletionSaveFailureRestoresTheEntryWithoutTouchingOtherRecords() throws {
        let f = try Fixture(linked: true)
        #expect(throws: GoogleCalendarWorkflowError.saveFailed) {
            try GoogleCalendarScheduleSync.removeLocalEntry(f.call, context: f.context,
                save: { throw GoogleCalendarWorkflowError.saveFailed })
        }
        #expect(try f.context.fetch(FetchDescriptor<ServiceCall>()).contains { $0.id == f.call.id })
        #expect(f.customer.name == "Fixture customer")
    }

    @Test func deletionNeverRollsBackPreexistingUnsavedWork() throws {
        let f = try Fixture()
        f.customer.name = "Unrelated pending work"
        #expect(throws: GoogleCalendarWorkflowError.changed) {
            try GoogleCalendarScheduleSync.removeLocalEntry(f.call, context: f.context)
        }
        #expect(f.customer.name == "Unrelated pending work")
        #expect(try f.context.fetch(FetchDescriptor<ServiceCall>()).contains { $0 === f.call })
    }

    @Test func invoicesAndHistoryProtectTheJobFromCalendarRemoval() async throws {
        let f = try Fixture(linked: true)
        let invoice = Invoice(serviceCallID: f.call.id, customer: f.customer, amount: 150)
        f.context.insert(invoice)
        try f.context.save()
        failed(await (try f.flow()).run { try await GoogleCalendarScheduleSync.remove(call: f.call, workflow: $0) })
        #expect(f.requests.isEmpty)
        #expect(try f.context.fetch(FetchDescriptor<ServiceCall>()).count == 1)
        #expect(invoice.serviceCallID == f.call.id)
    }

    @Test func importSaveFailureRestoresAnExistingUnassignedCalendarShell() throws {
        let f = try Fixture()
        let placeholder = Customer(quickBooksID: CustomerDataMaintenance.unassignedCalendarCustomerMarker,
            name: CustomerDataMaintenance.unassignedCalendarCustomerName)
        f.context.insert(placeholder)
        let shell = ServiceCall(googleCalendarID: f.email, googleEventID: "shell", eventTitle: "Old title",
            type: .other, scheduledDate: f.call.scheduledDate, duration: 1800, customer: placeholder, notes: "Old note")
        f.context.insert(shell)
        try f.context.save()
        let event = try f.decoded(f.event(id: "shell", managed: false))
        #expect(throws: GoogleCalendarWorkflowError.saveFailed) {
            try GoogleCalendarScheduleSync.importEvents([(f.email, event)], into: f.context,
                signedInEmail: f.email, save: { throw GoogleCalendarWorkflowError.saveFailed })
        }
        #expect(shell.eventTitle == "Old title")
        #expect(shell.notes == "Old note")
        #expect(shell.duration == 1800)
        #expect(shell.customer === placeholder)
    }

    @Test func pathLikeProviderIdentifiersCannotEscapeTheEventEndpoint() async throws {
        for id in ["../other", "..", "event/\nother", " event "] {
            let f = try Fixture()
            let outcome: Result<GoogleCalendarEvent, Error> = await withCheckedContinuation { continuation in
                f.auth.fetchCalendarEvent(calendarID: f.email, eventID: id) { continuation.resume(returning: $0) }
            }
            if case .success = outcome { Issue.record("Unsafe path component was accepted") }
            #expect(f.requests.isEmpty)
        }
    }

    @Test func invalidScheduleCannotPublishAndMalformedEventCannotBeImported() async throws {
        let f = try Fixture()
        f.call.duration = -.infinity
        failed(try await f.publish())
        #expect(f.requests.isEmpty)
        let original = f.call.scheduledDate
        var data = f.event(id: "invalid", managed: false)
        data["end"] = ["dateTime": ISO8601DateFormatter().string(from: original.addingTimeInterval(-3600))]
        let event = try f.decoded(data)
        let summary = try GoogleCalendarScheduleSync.importEvents([(f.email, event)], into: f.context, signedInEmail: f.email)
        #expect(summary.importedCount == 0)
        #expect(summary.restrictedReviewCount == 1)
    }

    @Test func inventoryHistoryPreventsDeletingTheJobOrItsCalendarEvent() async throws {
        let f = try Fixture(linked: true)
        let item = Item(name: "Test capacitor", unitPrice: 25)
        f.context.insert(item)
        f.context.insert(InventoryMovement(item: item, type: .consume, quantity: 1, serviceCallID: f.call.id))
        try f.context.save()
        failed(await (try f.flow()).run { try await GoogleCalendarScheduleSync.remove(call: f.call, workflow: $0) })
        #expect(f.requests.isEmpty)
        #expect(try f.context.fetch(FetchDescriptor<ServiceCall>()).count == 1)
    }

    @Test func newBillingHistoryDuringCalendarReadPreventsSubsequentDeletion() async throws {
        let f = try Fixture(linked: true)
        f.beforeReply = { request in
            if request.url!.path.hasSuffix("/fixture-event") {
                f.context.insert(Invoice(serviceCallID: f.call.id, customer: f.customer, amount: 25))
                try f.context.save()
            }
        }
        failed(await (try f.flow()).run { try await GoogleCalendarScheduleSync.remove(call: f.call, workflow: $0) })
        #expect(f.writes.isEmpty)
        #expect(try f.context.fetch(FetchDescriptor<ServiceCall>()).count == 1)
    }

    @Test func stableCreateIDUsesOnlyGoogleAllowedCharactersAndCarriesNoCustomerData() throws {
        let first = UUID(), second = UUID()
        let id = GoogleCalendarScheduleSync.eventID(for: first)
        #expect(id == GoogleCalendarScheduleSync.eventID(for: first))
        #expect(id != GoogleCalendarScheduleSync.eventID(for: second))
        #expect(id.count >= 5 && id.count <= 1024)
        #expect(id.allSatisfy { "0123456789abcdefghijklmnopqrstuv".contains($0) })
    }
}
