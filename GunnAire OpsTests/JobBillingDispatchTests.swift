import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor
struct JobBillingDispatchTests {
    @MainActor final class Fixture {
        let company = UUID()
        let context: ModelContext
        let customer: Customer
        let call: ServiceCall
        let first = Technician(name: "Alex", contactInfo: "alex@example.invalid")
        let second = Technician(name: "Sam", contactInfo: "sam@example.invalid")
        var email = "office@example.invalid"
        var authorized = true
        var epoch = String(repeating: "a", count: 64)
        var remote: JobBillingAssignment?
        var files: [String: Data] = [:]
        var writes: [JobBillingAssignmentRequest] = []
        var reads = 0
        var failRead = false
        var loseWriteResponse = false
        var failStoreWrite = false
        var storeWrites = 0
        var afterStoreWrite: (() throws -> Void)?
        var failStoreWriteNumber: Int?
        var beforeReply: (() async throws -> Void)?
        var beforeDiscovery: (() async throws -> Void)?
        var discoveryChanges: [String: Any] = [:]
        var discoveryError: Error?
        var bootstrapFiles: [String: Data] = [:]
        var failBootstrapWrite = false
        var discoveries = 0
        lazy var bootstrapStore = JobBillingBootstrapStore(read: { [unowned self] scope in
            if let data = bootstrapFiles[scope.storageKey] { return try JSONDecoder().decode(JobBillingBootstrap.self, from: data) }
            return .init(business: scope)
        }, write: { [unowned self] value in
            if failBootstrapWrite { throw JobBillingDispatchError.storage }
            bootstrapFiles[value.business.storageKey] = try JSONEncoder().encode(value)
        })
        lazy var api = QuickBooksDataAPI(testTokens: .init(accessToken: "fixture", expiration: .distantFuture),
            realmID: "dispatch-fixture", environment: Config.QuickBooks.environment, catalogCompanyID: company,
            transport: { _ in Issue.record("Job access reached direct QuickBooks transport"); throw JobBillingDispatchError.connection })
        lazy var store = JobBillingJournalStore(read: { [unowned self] scope in
            if let data = files[scope.storageKey] { return try JSONDecoder().decode(JobBillingQueue.self, from: data) }
            return JobBillingQueue(scope: scope)
        }, write: { [unowned self] queue in
            storeWrites += 1
            if failStoreWrite || failStoreWriteNumber == storeWrites { throw JobBillingDispatchError.storage }
            files[queue.scope.storageKey] = try JSONEncoder().encode(queue)
            try afterStoreWrite?()
        })

        init() throws {
            let schema = GunnAireModelSchema.schema
            context = ModelContext(try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            ]))
            context.autosaveEnabled = false
            customer = Customer(name: "Fixture customer")
            call = ServiceCall(type: .repair, scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
                               duration: 3600, assignedTechnician: first, customer: customer)
            context.insert(customer); context.insert(first); context.insert(second); context.insert(call)
            context.insert(AppUser(email: "alex@example.invalid", role: .fieldTechnician))
            context.insert(AppUser(email: "sam@example.invalid", role: .fieldTechnician))
            context.insert(AppUser(email: email, role: .dispatcher))
            try context.save()
        }

        var scope: JobBillingQueueScope { .init(companyID: company, realmID: "dispatch-fixture", environment: Config.QuickBooks.environment, actorEmail: email) }

        func coordinator(shared: Bool = false) -> JobBillingDispatch {
            JobBillingDispatch(store: store, api: shared ? nil : api, client: .init { [unowned self] path, method, body in
                #expect(path.hasPrefix("/api/job-billing-assignments"))
                if path.hasPrefix("/api/job-billing-assignments/connection?") {
                    #expect(method == "GET" && body == nil)
                    discoveries += 1
                    try await beforeDiscovery?()
                    if let discoveryError { throw discoveryError }
                    var result: [String: Any] = ["companyID": company.uuidString.lowercased(), "realmID": scope.realmID,
                        "environment": scope.environment, "connectionRevision": epoch, "protocolVersion": 1]
                    result.merge(discoveryChanges) { _, new in new }
                    return try JSONSerialization.data(withJSONObject: result)
                }
                try await beforeReply?()
                if method == "GET" {
                    reads += 1
                    if failRead { throw BillingPublicationError.unavailable }
                } else {
                    let request = try JSONDecoder().decode(JobBillingAssignmentRequest.self, from: #require(body))
                    writes.append(request)
                    guard request.connectionRevision == epoch, request.expectedRevision == (remote?.revision ?? 0) else {
                        throw GunnAireBackendError.server(statusCode: 409, message: "fixture conflict")
                    }
                    remote = .init(companyID: company, realmID: scope.realmID, environment: scope.environment, serviceCallID: request.serviceCallID,
                        localCustomerID: customer.id, revision: request.expectedRevision + 1, technicianEmails: request.technicianEmails,
                        enabled: request.enabled, usable: request.enabled, updatedAt: "2026-09-07T00:00:00Z")
                    if loseWriteResponse { throw BillingPublicationError.unavailable }
                }
                return try JSONEncoder().encode(JobBillingAssignmentSnapshot(assignment: remote, connectionRevision: epoch))
            }, actor: { [unowned self] in email }, validateAccess: { [unowned self] _, actor in
                guard authorized, actor == "office@example.invalid" else { throw JobBillingDispatchError.access }
            }, fixture: true, bootstrapStore: bootstrapStore, fixtureCompanyID: shared ? company : nil)
        }

        func setRemote(revision: Int = 1, emails: [String] = ["alex@example.invalid"], enabled: Bool = true, usable: Bool? = nil) {
            remote = .init(companyID: company, realmID: scope.realmID, environment: scope.environment, serviceCallID: call.id,
                localCustomerID: customer.id, revision: revision, technicianEmails: emails, enabled: enabled,
                usable: usable ?? enabled, updatedAt: "2026-09-07T00:00:00Z")
        }

        func save(_ dispatch: JobBillingDispatch, original: JobBillingTarget? = nil) throws {
            try dispatch.save(call, original: original, context: context, startSync: false)
        }

        func liveSync(_ dispatch: JobBillingDispatch) async throws -> JobBillingDispatch.Review {
            try await dispatch.synchronize(call, context: context, handle: dispatch.discover(context: context), allowInitialBinding: true, send: true)
        }

        func pending(_ dispatch: JobBillingDispatch) throws -> JobBillingPendingEdit? { try dispatch.record(jobID: call.id, context: context)?.pending }
    }

    @Test func savedJobCreatesOneRevisionedCrewGrantWithoutAccountingWrites() async throws {
        let f = try Fixture(), d = f.coordinator()
        try f.save(d)
        let edit = try #require(try f.pending(d))
        #expect(!f.context.hasChanges)
        let result = try await f.liveSync(d)
        #expect(result.snapshot.assignment?.usable == true)
        #expect(f.writes.count == 1); #expect(f.writes[0].operationID == edit.id)
        #expect(f.writes[0].expectedRevision == 0); #expect(f.writes[0].connectionRevision == f.epoch)
        #expect(try f.pending(d) == nil)
    }

    @Test func restartRecoversAcceptedAssignmentByReadingWithoutSecondPost() async throws {
        let f = try Fixture(), d = f.coordinator()
        try f.save(d); f.loseWriteResponse = true
        await #expect(throws: BillingPublicationError.unavailable) { try await f.liveSync(d) }
        #expect(try f.pending(d)?.request != nil)
        let restarted = f.coordinator()
        await restarted.resume(context: f.context)
        #expect(try f.pending(restarted) == nil); #expect(f.writes.count == 1)
    }

    @Test func unboundOfflineEditSurvivesRestartAndRequiresVisibleConnectionReview() async throws {
        let f = try Fixture(), d = f.coordinator()
        try f.save(d); f.failRead = true
        await #expect(throws: BillingPublicationError.unavailable) { try await f.liveSync(d) }
        f.failRead = false; f.epoch = String(repeating: "b", count: 64)
        let restarted = f.coordinator()
        await restarted.resume(context: f.context)
        #expect(try f.pending(restarted)?.state == .review); #expect(f.writes.isEmpty)
        let review = try await restarted.refresh(f.call, context: f.context)
        _ = try await restarted.applySavedCrew(f.call, context: f.context, reviewed: review)
        #expect(f.writes.count == 1); #expect(f.writes[0].connectionRevision == f.epoch)
    }

    @Test func knownOriginalRevisionResumesOrdinaryOfflineReassignment() async throws {
        let f = try Fixture(), d = f.coordinator()
        f.setRemote()
        _ = try await d.refresh(f.call, context: f.context)
        let original = try JobBillingTarget.capture(f.call, context: f.context).1
        f.call.assignedTechnician = f.second
        try f.save(d, original: original)
        let restarted = f.coordinator()
        await restarted.resume(context: f.context)
        #expect(f.writes.count == 1); #expect(f.remote?.revision == 2)
        #expect(f.remote?.technicianEmails == ["sam@example.invalid"])
    }

    @Test func newlyCreatedOfflineJobRetainsThePreviouslyVerifiedBusinessConnection() async throws {
        let f = try Fixture(), d = f.coordinator()
        f.setRemote(); _ = try await d.refresh(f.call, context: f.context)
        f.remote = nil
        let newJob = ServiceCall(type: .service, scheduledDate: Date(), duration: 3600, assignedTechnician: f.first, customer: f.customer)
        f.context.insert(newJob)
        try d.save(newJob, original: nil, context: f.context, startSync: false)
        let pending = try d.record(jobID: newJob.id, context: f.context)?.pending
        #expect(pending?.baseline?.connectionRevision == f.epoch)
        #expect(pending?.baseline?.assignment == nil)
        let restarted = f.coordinator()
        await restarted.resume(context: f.context)
        #expect(f.writes.count == 1); #expect(f.remote?.serviceCallID == newJob.id)
        #expect(f.remote?.technicianEmails == ["alex@example.invalid"])
    }

    @Test func newerDispatcherDecisionNeedsExplicitCompareAndSetConfirmation() async throws {
        let f = try Fixture(), d = f.coordinator()
        f.setRemote(); _ = try await d.refresh(f.call, context: f.context)
        let original = try JobBillingTarget.capture(f.call, context: f.context).1
        f.call.assignedTechnician = f.second; try f.save(d, original: original)
        f.setRemote(revision: 2, emails: [], enabled: false)
        await d.resume(context: f.context)
        #expect(f.writes.isEmpty); #expect(try f.pending(d)?.state == .review)
        let review = try await d.refresh(f.call, context: f.context)
        _ = try await d.applySavedCrew(f.call, context: f.context, reviewed: review)
        #expect(f.writes.count == 1); #expect(f.writes[0].expectedRevision == 2)
    }

    @Test func changedReviewSnapshotNeverBlindlyUsesTheLatestRevision() async throws {
        let f = try Fixture(), d = f.coordinator()
        let reviewed = try await d.refresh(f.call, context: f.context)
        f.setRemote(revision: 1, emails: [], enabled: false)
        await #expect(throws: BillingPublicationError.reviewRequired) {
            try await d.applySavedCrew(f.call, context: f.context, reviewed: reviewed)
        }
        #expect(f.writes.isEmpty)
    }

    @Test func reconnectWithSameRealmDoesNotReviveAnOldQueuedGrant() async throws {
        let f = try Fixture(), d = f.coordinator()
        f.setRemote(); _ = try await d.refresh(f.call, context: f.context)
        let old = try JobBillingTarget.capture(f.call, context: f.context).1
        f.call.assignedTechnician = f.second; try f.save(d, original: old)
        f.epoch = String(repeating: "b", count: 64); f.setRemote(usable: false)
        await d.resume(context: f.context)
        #expect(f.writes.isEmpty); #expect(try f.pending(d)?.state == .review)
    }

    @Test func anotherOfficeAccountCannotReadOrReplayTheOriginalQueue() async throws {
        let f = try Fixture(), d = f.coordinator()
        try f.save(d)
        let saved = f.files
        f.email = "other@example.invalid"
        await d.resume(context: f.context)
        #expect(throws: JobBillingDispatchError.access) { try d.record(jobID: f.call.id, context: f.context) }
        #expect(f.files == saved); #expect(f.writes.isEmpty); #expect(f.reads == 0)
    }

    @Test func roleLossDuringReadCannotSendOrApplyLateResults() async throws {
        let f = try Fixture(), d = f.coordinator()
        try f.save(d)
        f.beforeReply = { f.authorized = false }
        await #expect(throws: JobBillingDispatchError.access) { try await f.liveSync(d) }
        #expect(f.writes.isEmpty)
        f.authorized = true
        #expect(try f.pending(d) != nil)
    }

    @Test func changedCrewDuringReadDoesNotGrantTheOldCrew() async throws {
        let f = try Fixture(), d = f.coordinator()
        try f.save(d)
        f.beforeReply = { f.call.assignedTechnician = f.second; try f.context.save() }
        await #expect(throws: JobBillingDispatchError.changed) { try await f.liveSync(d) }
        #expect(f.writes.isEmpty); #expect(try f.pending(d) != nil)
    }

    @Test func unrelatedNotesAndAppointmentTimeDoNotInvalidateCrewAuthority() async throws {
        let f = try Fixture(), d = f.coordinator()
        try f.save(d)
        f.call.notes = "Saved findings"; f.call.scheduledDate.addTimeInterval(3600); try f.context.save()
        _ = try await f.liveSync(d)
        #expect(f.writes.count == 1); #expect(f.call.notes == "Saved findings")
    }

    @Test func failedLocalSaveRetainsPreparedIntentAndSendsNothing() async throws {
        let f = try Fixture(), d = f.coordinator()
        f.call.assignedTechnician = f.second
        #expect(throws: JobBillingDispatchError.save) {
            try d.save(f.call, original: nil, context: f.context, saveLocal: { _ in throw JobBillingDispatchError.save }, startSync: false)
        }
        #expect(try f.pending(d)?.state == .prepared)
        await d.resume(context: f.context)
        #expect(f.reads == 0); #expect(f.writes.isEmpty)
        try f.save(d)
        _ = try await f.liveSync(d)
        #expect(f.remote?.technicianEmails == ["sam@example.invalid"])
    }

    @Test func journalFailureBeforeSaveDoesNotRunTheLocalSaveOrAnyNetwork() throws {
        let f = try Fixture(), d = f.coordinator()
        f.failStoreWrite = true
        var saves = 0
        #expect(throws: JobBillingDispatchError.storage) {
            try d.save(f.call, original: nil, context: f.context, saveLocal: { _ in saves += 1 }, startSync: false)
        }
        #expect(saves == 0); #expect(f.writes.isEmpty); #expect(f.reads == 0)
    }

    @Test func journalFailureAfterSuccessfulModelSaveDoesNotReportTheJobUnsaved() async throws {
        let f = try Fixture(), d = f.coordinator()
        f.call.assignedTechnician = f.second
        f.failStoreWriteNumber = 2
        try f.save(d)
        #expect(!f.context.hasChanges); #expect(try f.pending(d)?.state == .prepared)
        f.failStoreWriteNumber = nil
        _ = try await f.liveSync(d)
        #expect(f.remote?.technicianEmails == ["sam@example.invalid"])
    }

    @Test func missingCrewBusinessAccountRevokesOldGrantInsteadOfPartiallyApproving() async throws {
        let f = try Fixture(), d = f.coordinator()
        f.setRemote(); _ = try await d.refresh(f.call, context: f.context)
        let original = try JobBillingTarget.capture(f.call, context: f.context).1
        f.second.contactInfo = "phone-only"
        f.call.additionalTechnicianIDs = [f.second.id]
        try f.save(d, original: original)
        _ = try await f.liveSync(d)
        #expect(f.remote?.enabled == false); #expect(f.remote?.technicianEmails == [])
        #expect(try JobBillingTarget.capture(f.call, context: f.context).1.needsCrewAccounts)
    }

    @Test(arguments: ["cancelled", "no-access", "meeting", "reminder"])
    func nonbillableVisitNeverReceivesFieldAuthority(_ reason: String) async throws {
        let f = try Fixture(), d = f.coordinator()
        switch reason {
        case "cancelled": f.call.status = .cancelled
        case "no-access": f.call.visitDisposition = .noAccess
        case "meeting": f.call.type = .meeting
        default: f.call.type = .reminder
        }
        try f.save(d); _ = try await f.liveSync(d)
        #expect(f.remote?.enabled == false)
    }

    @Test func unsentEditsCoalesceButPreserveTheOriginalRevision() async throws {
        let f = try Fixture(), d = f.coordinator()
        f.setRemote(); _ = try await d.refresh(f.call, context: f.context)
        let original = try JobBillingTarget.capture(f.call, context: f.context).1
        f.call.assignedTechnician = f.second; try f.save(d, original: original)
        let firstID = try f.pending(d)?.id
        f.call.additionalTechnicianIDs = [f.first.id]; try f.save(d)
        let edit = try #require(try f.pending(d))
        #expect(edit.id != firstID); #expect(edit.original == original); #expect(edit.baseline?.assignment?.revision == 1)
        await d.resume(context: f.context)
        #expect(f.writes.count == 1); #expect(f.remote?.technicianEmails == ["alex@example.invalid", "sam@example.invalid"])
    }

    @Test func uncertainOlderRequestIsRetainedButNeverResentAfterAnotherLocalEdit() async throws {
        let f = try Fixture(), d = f.coordinator()
        try f.save(d); f.loseWriteResponse = true
        await #expect(throws: BillingPublicationError.unavailable) { try await f.liveSync(d) }
        let oldRequest = try #require(f.pending(d)?.request)
        f.call.assignedTechnician = f.second; try f.save(d)
        #expect(try f.pending(d)?.supersededRequests == [oldRequest])
        #expect(try f.pending(d)?.state == .review)
        await d.resume(context: f.context)
        #expect(f.writes.count == 1)
        f.loseWriteResponse = false
        let reviewed = try await d.refresh(f.call, context: f.context)
        _ = try await d.applySavedCrew(f.call, context: f.context, reviewed: reviewed)
        #expect(f.writes.count == 2); #expect(f.writes[1].expectedRevision == 1)
        #expect(f.remote?.technicianEmails == ["sam@example.invalid"])
    }

    @Test func deletedOrDuplicateJobsAreNotRecoveredThroughAReplacementRecord() async throws {
        let f = try Fixture(), d = f.coordinator()
        try f.save(d)
        let duplicate = ServiceCall(id: f.call.id, type: .repair, scheduledDate: Date(), duration: 3600, customer: f.customer)
        f.context.insert(duplicate); try f.context.save()
        await d.resume(context: f.context)
        #expect(f.reads == 0); #expect(f.writes.isEmpty)
    }

    @Test func encryptedJournalRoundTripsAcrossInstancesWithoutPlaintextBusinessData() throws {
        let f = try Fixture(), d = f.coordinator()
        try f.save(d)
        let queue = try f.store.read(f.scope)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("job-billing-fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = Data(repeating: 7, count: 32)
        let first = JobBillingJournalStore.encrypted(directory: directory) { _ in key }
        try first.write(queue)
        let file = directory.appendingPathComponent(f.scope.storageKey + ".sealed")
        let ciphertext = try Data(contentsOf: file)
        #expect(ciphertext.range(of: Data("alex@example.invalid".utf8)) == nil)
        #expect(ciphertext.range(of: Data(f.customer.id.uuidString.utf8)) == nil)
        let restarted = JobBillingJournalStore.encrypted(directory: directory) { _ in key }
        #expect(try restarted.read(f.scope) == queue)
        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        var damaged = ciphertext; damaged[damaged.count - 1] ^= 1
        try damaged.write(to: file)
        #expect(throws: JobBillingDispatchError.storage) { try restarted.read(f.scope) }
        #expect(try Data(contentsOf: file) == damaged)
    }

    @Test func failedEditRollbackRestoresCrewWorkAndOnlyItsOwnActivity() throws {
        let f = try Fixture()
        let unrelated = Customer(name: "Unrelated unsaved customer")
        f.context.insert(unrelated)
        let originalActivity = ServiceCallActivity.record(for: f.call, action: "Existing history", detail: "Keep this", in: f.context)
        f.call.notes = "Original observations"
        let date = f.call.scheduledDate
        let restore = try ServiceCallEditRollback.capture(f.call, context: f.context)
        f.call.assignedTechnician = f.second; f.call.notes = "Edited observations"
        f.call.scheduledDate.addTimeInterval(3600); f.call.visitDisposition = .noAccess
        f.call.setTechnicalReading("45", for: "temperature_split")
        let added = ServiceCallActivity.record(for: f.call, action: "Failed edit", detail: "Not committed", in: f.context)
        restore()
        #expect(f.call.assignedTechnician === f.first); #expect(f.call.notes == "Original observations")
        #expect(f.call.scheduledDate == date); #expect(f.call.visitDisposition == .standard)
        #expect(f.call.technicalReading(for: "temperature_split").isEmpty)
        let customers = try f.context.fetch(FetchDescriptor<Customer>())
        #expect(customers.contains { $0 === unrelated })
        let history = try f.context.fetch(FetchDescriptor<ServiceCallActivity>())
        #expect(history.contains { $0 === originalActivity }); #expect(!history.contains { $0 === added })
    }

    @Test func queuedAuthorityAddsJobHistorySoDeletionCannotOrphanTheGrant() throws {
        let f = try Fixture(), d = f.coordinator()
        try f.save(d)
        #expect(throws: GoogleCalendarWorkflowError.hasJobHistory) {
            try GoogleCalendarScheduleSync.validateRemoval(f.call, context: f.context)
        }
        let activities = try f.context.fetch(FetchDescriptor<ServiceCallActivity>())
        #expect(activities.filter { $0.serviceCallID == f.call.id && $0.action == "Job billing access queued" }.count == 1)
        try f.save(d)
        #expect(try f.context.fetch(FetchDescriptor<ServiceCallActivity>()).count == 1)
    }

    @Test func ciphertextCannotMoveToAnotherOfficeQueueAndMissingKeyDoesNotResetIt() throws {
        let f = try Fixture(), d = f.coordinator()
        try f.save(d)
        let queue = try f.store.read(f.scope)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("job-billing-fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JobBillingJournalStore.encrypted(directory: directory) { _ in Data(repeating: 8, count: 32) }
        try store.write(queue)
        let other = JobBillingQueueScope(companyID: f.company, realmID: f.scope.realmID, environment: f.scope.environment, actorEmail: "other@example.invalid")
        try FileManager.default.copyItem(at: directory.appendingPathComponent(f.scope.storageKey + ".sealed"),
                                        to: directory.appendingPathComponent(other.storageKey + ".sealed"))
        #expect(throws: JobBillingDispatchError.storage) { try store.read(other) }
        let locked = JobBillingJournalStore.encrypted(directory: directory) { _ in throw JobBillingDispatchError.storage }
        #expect(throws: JobBillingDispatchError.storage) { try locked.read(f.scope) }
        #expect(throws: JobBillingDispatchError.storage) { try locked.write(queue) }
        #expect(try store.read(f.scope) == queue)
    }
}
