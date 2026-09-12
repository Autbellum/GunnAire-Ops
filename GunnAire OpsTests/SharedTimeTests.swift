import Foundation
import SwiftData
import CryptoKit
import Testing
@testable import GunnAire_Ops

@MainActor struct SharedTimeTests {
    @MainActor final class Fixture {
        let company = UUID()
        let context: ModelContext
        let entry: TimeEntry
        let technician = Technician(name: "Alex Technician", contactInfo: "alex@example.invalid")
        var actor = "office@example.invalid"
        var authorized = true
        var visible = true
        var realm = "fixture-realm"
        var epoch = String(repeating: "a", count: 64)
        var files: [String: Data] = [:]
        var calls: [(String, String, Data?)] = []
        var publication: [String: Any]?
        var workerOperations: [UUID: SharedTimeWorkerRequest] = [:]
        var workerRevision = 1
        var workerID = "55"
        var workerEnabled = true
        var offline = false
        var losePrepare = false
        var loseConfirm = false
        var loseWorker = false
        var loseLegacy = false
        var legacy = false
        var recoveryFound = true
        var failSave = false
        var failStore = false
        var creates = 0
        var beforeReply: ((String, String) async throws -> Void)?
        var mutateReply: ((inout [String: Any]) -> Void)?

        init() throws {
            let schema = GunnAireModelSchema.schema
            context = ModelContext(try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)]))
            context.autosaveEnabled = false
            let date = Date(timeIntervalSince1970: 1_788_000_000)
            entry = TimeEntry(userEmail: technician.contactInfo!, clockIn: date, clockOut: date.addingTimeInterval(7200),
                notes: "Reviewed repair training", activity: .training, reviewStatus: .approved,
                reviewedByEmail: actor, reviewedAt: date.addingTimeInterval(7500))
            context.insert(entry); context.insert(technician)
            context.insert(AppUser(email: actor, role: .admin)); context.insert(AppUser(email: entry.userEmail, role: .fieldTechnician))
            try context.save()
        }

        var identity: SharedTimeWorkerIdentity { .init(companyID: company, workerEmail: entry.userEmail) }
        var mapping: SharedTimeWorkerMapping { .init(companyID: company, realmID: realm, environment: "sandbox",
            workerEmail: entry.userEmail, revision: workerRevision, kind: "Employee", providerID: workerID,
            displayName: "Alex QuickBooks", referenceRevision: String(repeating: "b", count: 64), enabled: workerEnabled,
            usable: workerEnabled, updatedAt: "2026-08-29T12:00:00Z") }
        var connection: SharedTimeWorkerContext { .init(companyID: company, workerEmail: entry.userEmail, realmID: realm,
            environment: "sandbox", protocolVersion: 1, connectionRevision: epoch, mapping: mapping, candidate: nil) }
        var store: SharedTimeLocalStore { .init(read: { self.files[$0] }, write: {
            if self.failStore { throw SharedTimeError.storage }; self.files[$0] = $1
        }) }
        var client: SharedTimeClient { .init { try await self.request($0, method: $1, body: $2) } }
        func access() throws -> SharedTimeAccess {
            let captured = actor
            return try .init(context: context, isCurrent: { self.visible }, fixtureCompanyID: company, fixtureActor: actor,
                validateAccess: { guard self.authorized, self.actor == captured else { throw SharedTimeError.access } })
        }
        func owner() throws -> SharedTimeOwner {
            try .init(entry: entry, context: context, access: access(), client: client, store: store,
                saveModel: { if self.failSave { throw SharedTimeError.save }; try self.context.save() })
        }
        func worker() throws -> SharedTimeWorkerOwner {
            let email = technician.contactInfo
            return try .init(identity: identity, access: access(), client: client, store: store,
                validateMember: { guard self.technician.contactInfo == email, !self.technician.isDeleted else { throw SharedTimeError.changed } })
        }
        func object<T: Encodable>(_ value: T) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
        }
        func decodedPublication() throws -> SharedTimePublication {
            try JSONDecoder().decode(SharedTimePublication.self, from: JSONSerialization.data(withJSONObject: #require(publication)))
        }
        func prepare(_ owner: SharedTimeOwner) async throws -> SharedTimePublication {
            try #require(try await owner.prepare(itemID: nil).publication)
        }
        func confirmResult() {
            publication?["state"] = "confirmed"
            publication?["receipt"] = ["providerID": "T55", "syncToken": "0", "confirmedAt": SharedTimeError.instant(Date()), "legacyAdoption": legacy]
        }
        func response() -> [String: Any] {
            var result: [String: Any] = ["publication": publication!]
            if legacy, publication?["state"] as? String == "reserved" {
                result["needsLegacyReview"] = true
                result["legacyCandidate"] = ["providerID": "T55", "syncToken": "2", "description": "Older approved training\nGUNNAIRE-TIME:" + entry.id.uuidString,
                    "candidateRevision": String(repeating: "c", count: 64)]
            }
            return result
        }
        func request(_ path: String, method: String, body: Data?) async throws -> Data {
            calls.append((path, method, body))
            if offline { throw URLError(.notConnectedToInternet) }
            let url = try #require(URLComponents(string: path))
            var result: [String: Any]
            if url.path == "/api/time-worker-mappings", method == "POST" {
                let request = try JSONDecoder().decode(SharedTimeWorkerRequest.self, from: #require(body))
                let replay = workerOperations[request.operationID] != nil
                if !replay {
                    guard request.expectedRevision == workerRevision else { throw SharedTimeError.review }
                    workerRevision += 1; workerID = request.providerID; workerEnabled = request.enabled
                    workerOperations[request.operationID] = request
                }
                if loseWorker { throw URLError(.networkConnectionLost) }
                result = ["mapping": try object(mapping), "operationID": request.operationID.uuidString, "replayed": replay]
            } else if url.path.hasPrefix("/api/time-worker-mappings") {
                result = try object(connection)
                if url.path.hasSuffix("/candidate") {
                    let fields = url.queryItems ?? []
                    result["candidate"] = ["kind": fields.first { $0.name == "kind" }!.value!,
                        "providerID": fields.first { $0.name == "providerID" }!.value!, "displayName": "Alex QuickBooks",
                        "referenceRevision": String(repeating: "b", count: 64)]
                }
            } else if method == "GET" {
                result = ["publications": publication.map { [$0] } ?? []]
            } else if url.path == "/api/time-publications" {
                let request = try JSONDecoder().decode(SharedTimeRequest.self, from: #require(body))
                try request.validate()
                if publication == nil || publication?["state"] as? String == "cancelled" {
                    let id = UUID(), date = Date()
                    let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
                    formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: request.timeZone); formatter.dateFormat = "yyyy-MM-dd"
                    let description = ["Activity: " + TimeEntryActivity(rawValue: request.activity)!.displayName, request.notes,
                        "Clocked " + request.clockIn + " - " + request.clockOut, "GUNNAIRE-TIME:" + request.localEntryID.uuidString,
                        "GUNNAIRE-TIME-PUBLICATION:" + id.uuidString].filter { !$0.isEmpty }.joined(separator: "\n")
                    let document = SharedTimeDocument(TxnDate: formatter.string(from: SharedTimeError.date(request.clockIn)!), NameOf: "Employee",
                        EmployeeRef: .init(value: workerID), VendorRef: nil, CustomerRef: request.localCustomerID.map { _ in .init(value: "C55") },
                        ItemRef: request.localItemID.map { _ in .init(value: "I55") }, Hours: request.payableMinutes / 60,
                        Minutes: request.payableMinutes % 60, Description: description)
                    publication = try object(SharedTimePublication(id: id, companyID: company, realmID: realm, environment: "sandbox",
                        localEntryID: request.localEntryID, workerEmail: request.workerEmail, state: "reserved", entryRevision: request.entryRevision,
                        reviewHash: String(repeating: "d", count: 64), preparedByEmail: actor, review: request, worker: mapping,
                        timeActivity: document, receipt: nil, createdAt: SharedTimeError.instant(date), updatedAt: SharedTimeError.instant(date),
                        expiresAt: SharedTimeError.instant(date.addingTimeInterval(900))))
                }
                if losePrepare { throw URLError(.networkConnectionLost) }
                result = response()
            } else if url.path.hasSuffix("/confirm") {
                if legacy {
                    if loseLegacy { throw URLError(.networkConnectionLost) }
                } else {
                    creates += 1
                    if loseConfirm { publication?["state"] = "unknown"; throw URLError(.networkConnectionLost) }
                    confirmResult()
                }
                result = response()
            } else if url.path.hasSuffix("/recover") {
                if publication?["state"] as? String == "unknown", recoveryFound { confirmResult() }
                result = response()
            } else if url.path.hasSuffix("/adopt") {
                confirmResult(); result = response()
            } else if url.path.hasSuffix("/cancel") {
                guard publication?["state"] as? String == "reserved" else { throw SharedTimeError.review }
                publication?["state"] = "cancelled"; result = response()
            } else { throw SharedTimeError.invalid }
            try await beforeReply?(path, method)
            mutateReply?(&result)
            return try JSONSerialization.data(withJSONObject: result)
        }
    }

    @Test func failedApprovalSaveRestoresHoursReviewAuditAndLeavesUnrelatedEdits() throws {
        let f = try Fixture(); f.entry.reviewStatus = .submitted
        f.entry.quickBooksTimeActivitySyncError = "Retained local review"
        let original = try SharedTimeSource(f.entry, context: f.context)
        f.technician.name = "Unrelated unsaved name"
        let users = try f.context.fetch(FetchDescriptor<AppUser>())
        #expect(throws: SharedTimeError.save) {
            try TimeEntryReviewPolicy.approveAndSave([f.entry], actorEmail: f.actor, users: users) {
                #expect(f.entry.reviewStatus == .approved)
                throw SharedTimeError.save
            }
        }
        #expect(try SharedTimeSource(f.entry, context: f.context) == original)
        #expect(f.entry.quickBooksTimeActivitySyncError == "Retained local review")
        #expect(f.technician.name == "Unrelated unsaved name")
    }

    @Test func bulkApprovalIsAllOrNothingWhenOneEntryNeedsCorrection() throws {
        let f = try Fixture(); f.entry.reviewStatus = .submitted
        let second = TimeEntry(userEmail: f.entry.userEmail, clockIn: f.entry.clockIn,
            clockOut: f.entry.clockOut, activity: .training, reviewStatus: .correctionRequested)
        f.context.insert(second)
        let firstBefore = try SharedTimeSource(f.entry, context: f.context), secondBefore = try SharedTimeSource(second, context: f.context)
        var saves = 0
        #expect(throws: TimeEntryReviewError.correctionStillRequired) {
            try TimeEntryReviewPolicy.approveAndSave([f.entry, second], actorEmail: f.actor,
                users: f.context.fetch(FetchDescriptor<AppUser>())) { saves += 1 }
        }
        #expect(saves == 0)
        #expect(try SharedTimeSource(f.entry, context: f.context) == firstBefore)
        #expect(try SharedTimeSource(second, context: f.context) == secondBefore)
    }

    @Test func bulkApprovalSavesOnceAndPreservesEachAuthorsHours() throws {
        let f = try Fixture(); f.entry.reviewStatus = .submitted
        let second = TimeEntry(userEmail: "second@example.invalid", clockIn: f.entry.clockIn,
            clockOut: f.entry.clockOut, activity: .unpaidBreak)
        f.context.insert(second)
        let users = try f.context.fetch(FetchDescriptor<AppUser>())
        var saves = 0
        try TimeEntryReviewPolicy.approveAndSave([f.entry, second], actorEmail: f.actor, users: users) {
            saves += 1; try f.context.save()
        }
        #expect(saves == 1 && f.entry.reviewStatus == .approved && second.reviewStatus == .approved)
        #expect(second.userEmail == "second@example.invalid" && second.activity == .unpaidBreak)
        #expect(f.entry.reviewEvents.last?.actorEmail == f.actor && second.reviewEvents.last?.actorEmail == f.actor)
        #expect(f.calls.isEmpty && !f.context.hasChanges)
    }

    @Test func failedCorrectionSaveRestoresOriginalActivityDatesNotesAndAudit() throws {
        let f = try Fixture(); f.entry.reviewStatus = .submitted
        let before = try SharedTimeSource(f.entry, context: f.context)
        var draft = TimeEntryCorrectionDraft(entry: f.entry)
        draft.clockIn = f.entry.clockIn.addingTimeInterval(60); draft.activity = .meeting; draft.notes = "Correction draft"
        let users = try f.context.fetch(FetchDescriptor<AppUser>())
        #expect(throws: SharedTimeError.save) {
            try TimeEntryReviewPolicy.savingChanges(to: [f.entry], save: { throw SharedTimeError.save }) {
                try TimeEntryReviewPolicy.applyCorrection(draft, to: f.entry, serviceCall: nil,
                    allEntries: [f.entry], actorEmail: f.actor, users: users)
            }
        }
        #expect(try SharedTimeSource(f.entry, context: f.context) == before)
        #expect(throws: SharedTimeError.save) {
            try TimeEntryReviewPolicy.savingChanges(to: [f.entry], save: { throw SharedTimeError.save }) {
                try TimeEntryReviewPolicy.requestCorrection(for: f.entry, reason: "Check start time", actorEmail: f.actor, users: users)
            }
        }
        #expect(try SharedTimeSource(f.entry, context: f.context) == before)
    }

    @Test func defaultTimeAccessEnforcesEveryBusinessRoleAndRevocation() throws {
        for role in AppUserRole.allCases {
            for administrator in [false, true] {
                let f = try Fixture(), user = try #require(f.context.fetch(FetchDescriptor<AppUser>()).first { $0.email == f.actor })
                user.role = role
                let allowed = role == .admin || (!administrator && role == .accounting)
                func access() throws -> SharedTimeAccess {
                    try .init(context: f.context, administrator: administrator, isCurrent: { true },
                        fixtureCompanyID: f.company, fixtureActor: f.actor)
                }
                if allowed {
                    let grant = try access(); try grant.check(); user.isActive = false
                    #expect(throws: (any Error).self) { try grant.check() }
                } else { #expect(throws: SharedTimeError.access) { try access() } }
            }
        }
    }

    @Test func workerPlusAddressSurvivesFormQueryDecoding() throws {
        let identity = SharedTimeWorkerIdentity(companyID: UUID(), workerEmail: "alex+service@example.invalid")
        let path = identity.path()
        #expect(path.contains("alex%2Bservice"))
        let url = try #require(URLComponents(string: path.replacingOccurrences(of: "+", with: " ")))
        #expect(url.queryItems?.first { $0.name == "workerEmail" }?.value == identity.workerEmail)
        #expect(SharedTimeTransportPolicy.allows(path: path, method: "GET", bodyBytes: nil))
    }

    @Test func foreignWorkerResponseCannotPrepareAnotherWorkersTime() async throws {
        let f = try Fixture(), owner = try f.owner()
        f.mutateReply = { result in if result["workerEmail"] != nil { result["workerEmail"] = "other@example.invalid" } }
        await #expect(throws: SharedTimeError.invalid) { try await owner.prepare(itemID: nil) }
        #expect(f.files.isEmpty && !f.calls.contains { $0.1 == "POST" })
    }

    @Test func daylightSavingChangesDoNotChangeElapsedApprovedMinutes() throws {
        for (start, end, minutes) in [
            ("2026-03-08T01:30:00-05:00", "2026-03-08T03:30:00-04:00", 60),
            ("2026-11-01T01:30:00-04:00", "2026-11-01T01:30:00-05:00", 60)] {
            let f = try Fixture(); f.entry.clockIn = try #require(SharedTimeError.date(start))
            f.entry.clockOut = try #require(SharedTimeError.date(end)); f.entry.reviewedAt = f.entry.clockOut!.addingTimeInterval(60)
            let request = try SharedTimeRequest(source: .init(f.entry, context: f.context), connection: f.connection,
                itemID: nil, timeZone: #require(TimeZone(identifier: "America/New_York")))
            #expect(request.payableMinutes == minutes && request.timeZone == "America/New_York")
        }
    }

    @Test func duplicateCloudKitEntryIdentityFailsBeforeAnyProviderRequest() throws {
        let f = try Fixture()
        f.context.insert(TimeEntry(id: f.entry.id, userEmail: f.entry.userEmail))
        #expect(throws: SharedTimeError.changed) { try f.owner() }
        #expect(f.calls.isEmpty)
    }

    @Test func serviceItemRemovedDuringConnectionCheckCannotBePrepared() async throws {
        let f = try Fixture(), owner = try f.owner()
        let item = Item(name: "Reviewed service", unitPrice: 100); f.context.insert(item); try f.context.save()
        f.beforeReply = { path, _ in
            if path.hasPrefix("/api/time-worker-mappings") { f.context.delete(item); try f.context.save() }
        }
        await #expect(throws: SharedTimeError.changed) { try await owner.prepare(itemID: item.id) }
        #expect(f.files.isEmpty && !f.calls.contains { $0.1 == "POST" })
    }

    @Test func confirmedReceiptCannotBeReplacedByANewerRead() async throws {
        let f = try Fixture(), owner = try f.owner(), review = try await f.prepare(owner)
        _ = try await owner.decide(review)
        let retained = f.files
        var receipt = try #require(f.publication?["receipt"] as? [String: Any]); receipt["providerID"] = "different-time"
        f.publication?["receipt"] = receipt
        await #expect(throws: SharedTimeError.invalid) { try await owner.refresh() }
        #expect(f.files == retained && f.entry.quickBooksTimeActivityID == "T55" && f.creates == 1)
    }

    @Test func preparationIsReadOnlyAndExplicitConfirmationLinksOriginalTimeOnce() async throws {
        let f = try Fixture(), owner = try f.owner(), originalSource = try SharedTimeSource(f.entry, context: f.context)
        let review = try await f.prepare(owner)
        #expect(f.creates == 0 && f.entry.quickBooksTimeActivityID == nil)
        #expect(review.timeActivity.Hours == 2 && review.timeActivity.Minutes == 0)
        _ = try await owner.decide(review)
        #expect(f.creates == 1 && f.entry.quickBooksTimeActivityID == "T55" && !f.context.hasChanges)
        #expect(try SharedTimeSource(f.entry, context: f.context) == originalSource)
        await #expect(throws: SharedTimeError.review) { try await owner.decide(review) }
        #expect(f.creates == 1)
    }

    @Test func lostPreparationRestartsThroughOriginalServerRecordWithoutPublishing() async throws {
        let f = try Fixture(), owner = try f.owner(); f.losePrepare = true
        await #expect(throws: SharedTimeError.unavailable) { try await owner.prepare(itemID: nil) }
        let request = try #require(try owner.journal().request)
        #expect(try owner.journal().publication == nil && f.creates == 0)
        let restarted = try f.owner(), restored = try await restarted.refresh()
        #expect(restored.publication?.review == request && f.creates == 0)
        let before = f.calls.count
        _ = try await restarted.cancel(#require(restored.publication))
        #expect(f.calls.count == before + 1 && f.calls.last?.0.hasSuffix("/cancel") == true)
        #expect(f.entry.reviewStatus == .approved)
    }

    @Test func lostConfirmationRelaunchNeverResendsAndRecoveryLinksOriginal() async throws {
        let f = try Fixture(), owner = try f.owner(), review = try await f.prepare(owner)
        f.loseConfirm = true
        await #expect(throws: SharedTimeError.unavailable) { try await owner.decide(review) }
        #expect(try owner.journal().confirmationRequested && f.creates == 1)
        let restarted = try f.owner()
        await #expect(throws: SharedTimeError.review) { try await restarted.decide(review) }
        let original = try #require(try await restarted.refresh().publication)
        _ = try await restarted.recover(original)
        #expect(f.creates == 1 && f.entry.quickBooksTimeActivityID == "T55")
    }

    @Test func emptyRecoveryDoesNotUnlockAnotherDispatch() async throws {
        let f = try Fixture(), owner = try f.owner(), review = try await f.prepare(owner)
        f.loseConfirm = true; f.recoveryFound = false
        await #expect(throws: SharedTimeError.unavailable) { try await owner.decide(review) }
        let current = try #require(try await owner.refresh().publication)
        _ = try await owner.recover(current)
        await #expect(throws: SharedTimeError.review) { try await owner.decide(current) }
        #expect(f.creates == 1 && f.entry.quickBooksTimeActivityID == nil)
    }

    @Test func lostLegacyReviewCanBeRecoveredThenExplicitlyAdoptedWithoutCreate() async throws {
        let f = try Fixture(), owner = try f.owner(), review = try await f.prepare(owner)
        f.legacy = true; f.loseLegacy = true
        await #expect(throws: SharedTimeError.unavailable) { try await owner.decide(review) }
        let restarted = try f.owner(), recovered = try await restarted.recover(review)
        #expect(try restarted.journal().confirmationRequested == false)
        _ = try await restarted.decide(review, legacy: #require(recovered.legacyCandidate))
        #expect(f.creates == 0 && f.entry.quickBooksTimeActivityID == "T55")
    }

    @Test func confirmedReceiptSurvivesLocalSaveFailureAndRestoresWithoutNetwork() async throws {
        let f = try Fixture(), owner = try f.owner(), review = try await f.prepare(owner)
        f.failSave = true
        await #expect(throws: SharedTimeError.save) { try await owner.decide(review) }
        #expect(try owner.journal().publication?.receipt?.providerID == "T55" && f.entry.quickBooksTimeActivityID == nil)
        f.failSave = false; f.offline = true
        let calls = f.calls.count
        _ = try f.owner().restoreSavedLink()
        #expect(f.calls.count == calls && f.creates == 1 && f.entry.quickBooksTimeActivityID == "T55")
    }

    @Test func changedEntryAfterDispatchCannotReceiveOldReceiptOrPublishAgain() async throws {
        let f = try Fixture(), owner = try f.owner(), review = try await f.prepare(owner)
        f.beforeReply = { path, _ in if path.hasSuffix("/confirm") { f.entry.notes = "Changed after dispatch"; try f.context.save() } }
        await #expect(throws: SharedTimeError.changed) { try await owner.decide(review) }
        #expect(f.creates == 1 && f.entry.quickBooksTimeActivityID == nil)
        f.beforeReply = nil
        let restarted = try f.owner(), recovered = try #require(try await restarted.refresh().publication)
        #expect(recovered.receipt?.providerID == "T55")
        #expect(throws: SharedTimeError.changed) { try restarted.restoreSavedLink() }
        #expect(f.entry.notes == "Changed after dispatch" && f.entry.quickBooksTimeActivityID == nil)
    }

    @Test func entryRoleUserAndNavigationChangesCannotCompleteDiscoveryOrPrepare() async throws {
        for change in 0..<4 {
            let f = try Fixture(), owner = try f.owner()
            f.beforeReply = { _, _ in
                if change == 0 { f.entry.notes = "Changed" }
                if change == 1 { f.authorized = false }
                if change == 2 { f.actor = "other@example.invalid" }
                if change == 3 { f.visible = false }
            }
            await #expect(throws: (any Error).self) { try await owner.prepare(itemID: nil) }
            #expect(f.files.isEmpty && f.creates == 0 && !f.calls.contains { $0.1 == "POST" })
        }
    }

    @Test func changedRealmGrantMappingAndReviewerCannotConfirm() async throws {
        for change in 0..<4 {
            let f = try Fixture(), owner = try f.owner(), review = try await f.prepare(owner)
            if change == 0 { f.realm = "other-realm" }
            if change == 1 { f.epoch = String(repeating: "c", count: 64) }
            if change == 2 { f.workerRevision += 1 }
            if change == 3 { f.actor = "other@example.invalid" }
            await #expect(throws: (any Error).self) { try await owner.decide(review) }
            #expect(f.creates == 0 && !f.calls.contains { $0.0.hasSuffix("/confirm") })
        }
    }

    @Test func workerLostSaveReplaysExactOperationWithoutReassigningCurrentMapping() async throws {
        let f = try Fixture(), worker = try f.worker()
        let reviewed = try await worker.refresh(kind: "Employee", providerID: "66")
        f.loseWorker = true
        await #expect(throws: SharedTimeError.unavailable) { try await worker.save(reviewed, enabled: true) }
        let original = try #require(try worker.journal().pending)
        #expect(f.workerOperations.count == 1)
        f.loseWorker = false; f.workerRevision += 1; f.workerID = "77"
        let restarted = try f.worker(), recovered = try await restarted.recover()
        #expect(recovered.providerID == "77" && f.workerOperations.count == 1)
        #expect(f.workerOperations[original.operationID] == original)
        #expect(try restarted.journal().pending == nil)
    }

    @Test func workerChangesOrCorruptJournalNeverAuthorizeMappingPost() async throws {
        for changed in [false, true] {
            let f = try Fixture(), worker = try f.worker(), reviewed = try await worker.refresh(kind: "Employee", providerID: "66")
            if changed { f.beforeReply = { _, _ in f.technician.contactInfo = "other@example.invalid" } }
            else { f.files[worker.key] = Data("corrupt".utf8) }
            await #expect(throws: (any Error).self) { try await worker.save(reviewed, enabled: true) }
            #expect(f.workerOperations.isEmpty)
        }
    }

    @Test func requestEncodesEveryNullableReferenceAndRejectsUnpaidOpenUnapprovedTime() throws {
        let f = try Fixture()
        let request = try SharedTimeRequest(source: .init(f.entry, context: f.context), connection: f.connection, itemID: nil)
        let fields = try f.object(request)
        #expect(fields.count == 19)
        for key in ["serviceCallID", "localCustomerID", "localItemID"] { #expect(fields[key] is NSNull) }
        f.entry.activity = .unpaidBreak
        #expect(throws: SharedTimeError.approval) { try SharedTimeRequest(source: .init(f.entry, context: f.context), connection: f.connection, itemID: nil) }
        f.entry.activity = .training; f.entry.reviewStatus = .submitted
        #expect(throws: SharedTimeError.approval) { try SharedTimeRequest(source: .init(f.entry, context: f.context), connection: f.connection, itemID: nil) }
        f.entry.reviewStatus = .approved; f.entry.clockOut = nil
        #expect(throws: SharedTimeError.approval) { try SharedTimeRequest(source: .init(f.entry, context: f.context), connection: f.connection, itemID: nil) }
    }

    @Test func corruptedLocalJournalNeverBecomesAnEmptyPrepare() async throws {
        let f = try Fixture(), owner = try f.owner()
        f.files[owner.key] = Data("broken original journal".utf8)
        let saved = f.files
        await #expect(throws: SharedTimeError.storage) { try await owner.prepare(itemID: nil) }
        #expect(f.files == saved && f.calls.isEmpty)
    }

    @Test func missingStoragePreventsDispatchAndRetainsUnsentReview() async throws {
        let f = try Fixture(), owner = try f.owner(), review = try await f.prepare(owner)
        let saved = f.files; f.failStore = true
        await #expect(throws: SharedTimeError.storage) { try await owner.decide(review) }
        #expect(f.files == saved && f.creates == 0)
    }

    @Test func confirmedStateAndImmutableReceiptCannotBeDowngradedByARead() async throws {
        let f = try Fixture(), owner = try f.owner(), review = try await f.prepare(owner)
        _ = try await owner.decide(review)
        let saved = f.files
        f.publication?["state"] = "reserved"; f.publication?.removeValue(forKey: "receipt")
        await #expect(throws: SharedTimeError.invalid) { try await owner.refresh() }
        #expect(f.files == saved && f.creates == 1)
    }

    @Test func changedDescriptionOrReferencesCannotReuseAnOldReviewHash() async throws {
        for field in ["Description", "ItemRef"] {
            let f = try Fixture(), owner = try f.owner(), _ = try await f.prepare(owner)
            let saved = f.files
            var document = f.publication!["timeActivity"] as! [String: Any]
            document[field] = field == "Description" ? "Changed note" : ["value": "other"]
            f.publication?["timeActivity"] = document
            await #expect(throws: SharedTimeError.invalid) { try await owner.refresh() }
            #expect(f.files == saved && f.creates == 0)
        }
    }

    @Test func cancellationWorksWithoutCurrentWorkerConnectionAndKeepsHours() async throws {
        let f = try Fixture(), owner = try f.owner(), review = try await f.prepare(owner)
        f.realm = "replacement-realm"
        let before = f.calls.count
        _ = try await owner.cancel(review)
        #expect(f.calls.count == before + 1 && f.calls.last?.0.hasSuffix("/cancel") == true)
        #expect(f.entry.reviewStatus == .approved && f.entry.durationMinutes == 120 && f.creates == 0)
    }

    @Test func clearingUnsentPreparationRequiresNoServerReservationAndNoDispatchRisk() async throws {
        let f = try Fixture(), owner = try f.owner(); f.losePrepare = true
        await #expect(throws: SharedTimeError.unavailable) { try await owner.prepare(itemID: nil) }
        await #expect(throws: SharedTimeError.review) { try await owner.clearUnsentPreparation() }
        #expect(try owner.journal().publication != nil && f.creates == 0)
        let second = try Fixture(), pending = try second.owner()
        let request = try SharedTimeRequest(source: pending.source, connection: second.connection, itemID: nil)
        second.files[pending.key] = try JSONEncoder().encode(SharedTimeJournal(companyID: second.company, actorEmail: second.actor,
            localEntryID: second.entry.id, request: request))
        second.entry.notes = "Changed unsent hours note"
        let restarted = try second.owner()
        _ = try await restarted.clearUnsentPreparation()
        #expect(try restarted.journal().request == nil && second.creates == 0 && second.entry.notes == "Changed unsent hours note")
    }

    @Test func simultaneousWindowCannotOverwriteAnInFlightEntryJournal() async throws {
        let f = try Fixture(), first = try f.owner(), second = try f.owner()
        var checked = false
        f.beforeReply = { _, _ in
            guard !checked else { return }; checked = true
            await #expect(throws: SharedTimeError.review) { try await second.refresh() }
        }
        _ = try await first.prepare(itemID: nil)
        #expect(checked && f.calls.count == 3 && f.creates == 0)
    }

    @Test func existingLocalQuickBooksLinkNeverAllowsANewTimeCreate() async throws {
        let f = try Fixture(); f.entry.quickBooksTimeActivityID = "T55"; try f.context.save()
        let owner = try f.owner(), review = try await f.prepare(owner)
        await #expect(throws: SharedTimeError.review) { try await owner.decide(review) }
        f.legacy = true
        let found = try await owner.recover(review)
        _ = try await owner.decide(review, legacy: #require(found.legacyCandidate))
        #expect(f.creates == 0 && f.entry.quickBooksTimeActivityID == "T55")
    }

    @Test func transportAllowsOnlyBoundedBusinessTimeRoutes() {
        let company = UUID().uuidString.lowercased(), entry = UUID().uuidString.lowercased()
        #expect(SharedTimeTransportPolicy.allows(path: "/api/time-publications?companyID=\(company)&localEntryID=\(entry)", method: "GET", bodyBytes: nil))
        for path in ["https://evil.invalid/api/time-publications", "//evil.invalid/api/time-publications", "/api/time-publications?x=1",
                     "/api/%74ime-publications", "/api/time-publications/\(entry)/delete", "/api/time-publications/\(entry.uppercased())/confirm"] {
            #expect(!SharedTimeTransportPolicy.allows(path: path, method: "POST", bodyBytes: 2))
        }
        #expect(!SharedTimeTransportPolicy.allows(path: "/api/time-publications", method: "POST", bodyBytes: 32769))
        #expect(!SharedTimeTransportPolicy.allows(path: "/api/time-worker-mappings", method: "POST", bodyBytes: 8193))
    }

    @Test func encryptedStorageRetainsCorruptionAndNeverReplacesAMissingKeyForAnotherScope() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data(repeating: 7, count: 32)
        var keyAvailable = true, creationFlags: [Bool] = []
        let store = SharedTimeLocalStore.encrypted(directory: directory, key: { create in
            creationFlags.append(create)
            guard keyAvailable else { throw SharedTimeError.storage }; return bytes
        })
        let secret = Data("original worker and time note".utf8)
        try store.write("original", secret)
        let file = directory.appendingPathComponent(SharedTimeError.digest(Data("original".utf8)) + ".sealed")
        let encrypted = try Data(contentsOf: file)
        #expect(encrypted.range(of: secret) == nil)
        #expect(try store.read("original") == secret)
        keyAvailable = false
        #expect(throws: SharedTimeError.storage) { try store.write("different", secret) }
        #expect(creationFlags.last == false)
        #expect(try Data(contentsOf: file) == encrypted)
        keyAvailable = true
        try Data("corrupt retained bytes".utf8).write(to: file)
        #expect(throws: SharedTimeError.storage) { try store.read("original") }
        #expect(try Data(contentsOf: file) == Data("corrupt retained bytes".utf8))
    }
}
