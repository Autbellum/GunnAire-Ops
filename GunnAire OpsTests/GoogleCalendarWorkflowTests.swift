import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor
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
        var beforeReply: ((URLRequest) async throws -> Void)?
        var afterWrite: ((URLRequest) throws -> Void)?
        lazy var auth = GoogleAuthManager(testTokens: .init(accessToken: "fixture-only",
            refreshToken: nil, idToken: nil, expiration: .distantFuture), email: email,
            businessEmail: { self.email }) { [unowned self] request in
                self.requests.append(request)
                try await self.beforeReply?(request)
                return try self.reply(request)
            }

        init(linked: Bool = false) throws {
            let schema = GunnAireModelSchema.schema
            context = ModelContext(try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            ]))
            customer = Customer(name: "Fixture customer", email: "customer@example.invalid", address: "Local service address")
            call = ServiceCall(googleCalendarID: "primary", googleEventID: linked ? "fixture-event" : nil,
                googleEventManagedByApp: true, eventTitle: "Repair visit", type: .repair,
                scheduledDate: Date(timeIntervalSince1970: 1_800_000_000), duration: 3600,
                customer: customer, notes: "Saved field observations")
            context.insert(customer); context.insert(call)
            try context.save()
            calendarList = [["id": email, "primary": true, "accessRole": "owner"]]
            if linked { remote[key(email, "fixture-event")] = event(id: "fixture-event") }
        }

        func flow(save: @escaping (ModelContext) throws -> Void = { try $0.save() }) throws -> GoogleCalendarWorkflow {
            try GoogleCalendarWorkflow(auth: auth, context: context, signedInEmail: email,
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
            } else if request.httpMethod == "GET" && path.hasSuffix("/events") {
                payload = ["items": remote.filter { $0.key.hasPrefix(calendar + "|") }.map(\.value)]
            } else if request.httpMethod == "GET" {
                if let existing = remote[key(calendar, id)] { payload = existing }
                else { status = 404 }
            } else if request.httpMethod == "POST" {
                payload = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
                let createdID = try #require(payload["id"] as? String)
                if remote[key(calendar, createdID)] != nil { status = 409 }
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
        #expect(f.remote.isEmpty)
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

    @Test func localEditDuringReadIsPreservedWithoutPublishingStaleValues() async throws {
        let f = try Fixture()
        f.beforeReply = { _ in f.call.notes = "New technician findings during sync" }
        failed(try await f.publish())
        #expect(f.writes.isEmpty)
        #expect(f.call.notes == "New technician findings during sync")
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
