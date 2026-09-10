import Foundation
import SwiftData
import XCTest
@testable import GunnAire_Ops

@MainActor final class StaffOwnerFieldEditTests: XCTestCase {
    @MainActor final class Fixture {
        let base: StaffWorkspaceContentCoordinatorTests.Fixture
        let directory: URL
        let container: ModelContainer
        let job: ServiceCall
        let original: StaffWorkspaceOperationalCommandRequest
        let receipt: StaffWorkspaceOperationalCommandReceipt
        let memory = StaffWorkspaceRecoveryBoundaryTests.Memory()
        var allowed = true
        var serverValue: StaffWorkspaceValue = .text("Original office note")
        var serverRevision = 1
        var application: StaffOwnerFieldEditApplication?
        var resolution: StaffOwnerFieldEditResolution?
        var keepRequests: [StaffOwnerFieldEditKeepRequest] = []
        var loseKeep = false
        var beforeKeep: (() throws -> Void)?
        var prepareRequests: [StaffOwnerFieldEditPrepare] = []
        var losePrepare = false, loseConfirm = false
        var afterResponse: (() -> Void)?
        var escapeUnicode = false
        var saveModel: ((ModelContext) throws -> Void)?
        var applyCalls = 0
        var source: StaffReplicaSourceContext { base.source }
        init() throws {
            base = try .init()
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("OwnerFieldEditTests-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let schema = GunnAireModelSchema.schema
            container = try ModelContainer(for: schema, configurations: [.init(schema: schema,
                url: directory.appendingPathComponent("Owner.store"), cloudKitDatabase: .none)])
            container.mainContext.autosaveEnabled = false
            let customer = Customer(name: "Morgan")
            let tech = Technician(name: "Field Technician", contactInfo: "tech@example.invalid")
            job = ServiceCall(type: .repair, scheduledDate: base.now, assignedTechnician: tech, customer: customer)
            job.notes = "Original office note"
            container.mainContext.insert(customer); container.mainContext.insert(tech); container.mainContext.insert(job)
            try container.mainContext.save()
            let c = base.row.contentReceipt
            original = try .init(companyID: c.companyID, environment: c.environment, replicaID: c.replicaID,
                commandID: UUID(), selectionID: c.selectionID, sourceSequence: 1, contentSHA256: c.contentSHA256,
                candidate: .init(recordKind: "job", recordID: job.id.uuidString.lowercased(), revision: 1,
                    fieldName: "notes", currentValue: .text("Original office note")), value: .text("Technician found a failed capacitor"))
            receipt = .init(schema: original.schema, commandID: original.commandID, selectionID: original.selectionID,
                sourceSequence: 1, contentSHA256: original.contentSHA256, recordKind: original.recordKind,
                recordID: original.recordID, expectedRevision: 1, fieldName: "notes", value: original.value,
                actorEmail: "field.technician@gunnaire.com", createdAt: "2026-09-10T08:00:00Z", state: "recorded", operationalWorkspaceReady: false)
        }
        // SwiftData can retain live SQLite handles through registered models.
        // Never unlink an open store; the simulator owns these temporary files.
        func cleanup() { base.cleanup() }
        var edit: StaffOwnerFieldEdit {
            .init(schema: StaffOwnerFieldEdit.schema, shareID: base.plan.id.uuidString.lowercased(), request: original,
                receipt: receipt, baseValue: .text("Original office note"), current: .init(revision: serverRevision,
                    deleted: false, value: serverValue), eligible: resolution == nil, sourceSequence: serverRevision, application: application, resolution: resolution)
        }
        func check(_ context: StaffReplicaSourceContext) throws {
            guard allowed, context.scope == source.scope, context.stamp == source.stamp else { throw StaffReplicaSourceSyncError.access }
        }
        func response(_ path: String, method: String, bytes: Data?) throws -> Data {
            XCTAssertTrue(StaffOwnerFieldEditTransport.allows(path: path, method: method, body: bytes))
            var result: Data
            if method == "GET" {
                if URLComponents(string: path)?.path == StaffOwnerFieldEditTransport.root {
                    result = try StaffWorkspacePublicationContract.encode(StaffOwnerFieldEditPage(schema: StaffOwnerFieldEdit.schema,
                        companyID: original.companyID, environment: original.environment, replicaID: original.replicaID,
                        commandIDs: application?.state == "published" || resolution != nil ? [] : [original.commandID], nextCursor: nil))
                } else { result = try StaffWorkspacePublicationContract.encode(edit) }
            } else if path.hasSuffix("/keep-office") {
                let request = try StaffWorkspacePublicationContract.decode(StaffOwnerFieldEditKeepRequest.self, from: XCTUnwrap(bytes))
                keepRequests.append(request)
                try beforeKeep?()
                if let resolution {
                    guard resolution.request == request else { throw StaffReplicaSourceRejected(code: "edit_resolved") }
                } else {
                    guard application?.state != "published" else { throw StaffReplicaSourceRejected(code: "edit_published") }
                    guard request.claimOperationID == (application?.operationID ?? "") else { throw StaffReplicaSourceRejected(code: "edit_claimed") }
                    guard request.expectedRevision == serverRevision, request.expectedValue == serverValue else { throw StaffReplicaSourceRejected(code: "field_changed") }
                    resolution = .init(schema: StaffOwnerFieldEditKeepRequest.schema, request: request,
                        ownerEmail: source.scope.actorEmail, resolvedAt: "2026-09-10T08:03:00Z", outcome: "keptOffice")
                }
                if loseKeep { loseKeep = false; throw StaffReplicaSourceSyncError.unavailable }
                result = try StaffWorkspacePublicationContract.encode(XCTUnwrap(resolution))
            } else if path.hasSuffix("/prepare") {
                guard resolution == nil else { throw StaffReplicaSourceRejected(code: "edit_resolved") }
                let request = try StaffWorkspacePublicationContract.decode(StaffOwnerFieldEditPrepare.self, from: XCTUnwrap(bytes))
                if let first = prepareRequests.first { XCTAssertEqual(first, request) }
                prepareRequests.append(request)
                if application == nil {
                    guard request.expectedValue == serverValue, request.expectedRevision == serverRevision,
                          request.reviewedConflict || serverValue == edit.baseValue else { throw StaffReplicaSourceRejected(code: "field_changed") }
                    application = .init(schema: StaffOwnerFieldEdit.schema, commandID: original.commandID,
                        operationID: request.operationID, ownerStoreID: request.ownerStoreID, ownerEmail: source.scope.actorEmail,
                        preparedAt: "2026-09-10T08:01:00Z", expectedRevision: request.expectedRevision,
                        expectedValue: request.expectedValue, reviewedConflict: request.reviewedConflict, state: "prepared", publishedAt: nil)
                }
                if losePrepare { losePrepare = false; throw StaffReplicaSourceSyncError.unavailable }
                result = try StaffWorkspacePublicationContract.encode(XCTUnwrap(application))
            } else {
                guard resolution == nil else { throw StaffReplicaSourceRejected(code: "edit_resolved") }
                let request = try StaffWorkspacePublicationContract.decode(StaffOwnerFieldEditConfirmation.self, from: XCTUnwrap(bytes))
                let prepared = try XCTUnwrap(application)
                XCTAssertEqual(request.operationID, prepared.operationID)
                guard serverValue == original.value else { throw StaffReplicaSourceRejected(code: "edit_not_published") }
                application = .init(schema: prepared.schema, commandID: prepared.commandID, operationID: prepared.operationID,
                    ownerStoreID: prepared.ownerStoreID, ownerEmail: prepared.ownerEmail, preparedAt: prepared.preparedAt,
                    expectedRevision: prepared.expectedRevision, expectedValue: prepared.expectedValue,
                    reviewedConflict: prepared.reviewedConflict, state: "published", publishedAt: "2026-09-10T08:02:00Z")
                if loseConfirm { loseConfirm = false; throw StaffReplicaSourceSyncError.unavailable }
                result = try StaffWorkspacePublicationContract.encode(XCTUnwrap(application))
            }
            // Match Python's actual HTTP representation, including explicit
            // optional nulls; Swift-only round trips previously hid this gap.
            var wire = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
            if wire["commandIDs"] != nil { wire["nextCursor"] = wire["nextCursor"] ?? NSNull() }
            if wire["shareID"] != nil && wire["receipt"] != nil {
                wire["current"] = wire["current"] ?? NSNull()
                wire["application"] = wire["application"] ?? NSNull()
                if var receipt = wire["application"] as? [String: Any] {
                    receipt["publishedAt"] = receipt["publishedAt"] ?? NSNull(); wire["application"] = receipt
                }
            }
            if wire["operationID"] != nil { wire["publishedAt"] = wire["publishedAt"] ?? NSNull() }
            result = try JSONSerialization.data(withJSONObject: wire, options: [.sortedKeys])
            afterResponse?()
            if escapeUnicode { return Data(String(decoding: result, as: UTF8.self).replacingOccurrences(of: "é", with: "\\u00e9").utf8) }
            return result
        }
        func coordinator() -> StaffOwnerFieldEditCoordinator {
            .init(dependencies: .init(check: check, request: { try self.response($0, method: $1, bytes: $2) }, store: memory.store,
                read: { edit, context in try self.check(context); return try StaffOwnerFieldEditModels.read(edit, container: self.container) },
                apply: { edit, expected, context in
                    self.applyCalls += 1
                    try StaffOwnerFieldEditModels.apply(edit, expected: expected, container: self.container,
                        check: { try self.check(context) }, save: self.saveModel)
                }))
        }
        func savedValue() throws -> StaffWorkspaceValue {
            let context = ModelContext(container); context.autosaveEnabled = false
            return try StaffOwnerFieldEditModels.target(edit, context: context).value()
        }
        func officeChange(_ text: String) throws {
            let context = ModelContext(container); context.autosaveEnabled = false
            try StaffOwnerFieldEditModels.target(edit, context: context).write(.text(text)); try context.save()
        }
        func publishSaved() throws { serverValue = try savedValue(); serverRevision += 1 }
        func journal() throws -> StaffOwnerFieldEditJournal {
            try StaffWorkspacePublicationContract.decode(StaffOwnerFieldEditJournal.self,
                from: XCTUnwrap(memory.saved[StaffOwnerFieldEditCoordinator.key(source.scope)]), maximum: 64 * 1024 * 1024)
        }
    }

    func testRealSavedJobChangesThenConfirmsSourceWithoutReapplying() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let coordinator = f.coordinator()
        try await coordinator.synchronize(f.source)
        XCTAssertEqual(try f.savedValue(), f.original.value)
        await Task.yield()
        XCTAssertEqual(f.job.notes, "Technician found a failed capacitor", "The office's existing model must observe the saved field edit")
        XCTAssertFalse(f.container.mainContext.hasChanges)
        let authored = try f.container.mainContext.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>())
            .filter { $0.author == "staff-field-edit-v1:" + f.original.commandID }
        XCTAssertEqual(authored.count, 1, "One actual model transaction, not a second UI-refresh save")
        XCTAssertEqual(try f.journal().pending[f.original.commandID]?.phase, "saved")
        XCTAssertEqual(try f.journal().pending[f.original.commandID]?.edit.receipt, f.receipt)
        try await coordinator.confirmPublished(f.source)
        XCTAssertEqual(f.application?.state, "prepared", "A local journal alone cannot confirm publication")
        try f.publishSaved()
        try await coordinator.confirmPublished(f.source)
        XCTAssertEqual(f.application?.state, "published")
        XCTAssertTrue(try f.journal().pending.isEmpty)
        try f.officeChange("Later office correction")
        try await f.coordinator().synchronize(f.source)
        XCTAssertEqual(try f.savedValue(), .text("Later office correction"))
        XCTAssertEqual(f.applyCalls, 1)
    }

    func testUnsavedOfficeDraftIsNeitherSavedNorRolledBack() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.job.notes = "Office draft in progress"
        let coordinator = f.coordinator()
        try await coordinator.synchronize(f.source)
        XCTAssertTrue(f.container.mainContext.hasChanges)
        XCTAssertEqual(f.job.notes, "Office draft in progress")
        XCTAssertEqual(try f.savedValue(), .text("Original office note"))
        XCTAssertNil(f.application)
        XCTAssertEqual(f.applyCalls, 0)
    }

    func testStaleOfficeObjectCannotOverwriteAnotherSavedField() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let background = ModelContext(f.container); background.autosaveEnabled = false
        let other = try XCTUnwrap(background.fetch(FetchDescriptor<ServiceCall>()).first { $0.id == f.job.id })
        other.findingsSummary = "Newer equipment finding on another device"
        try background.save()
        XCTAssertNil(f.job.findingsSummary, "Exercise an actually stale registered office object")
        try await f.coordinator().synchronize(f.source)
        let verified = ModelContext(f.container); verified.autosaveEnabled = false
        let saved = try XCTUnwrap(verified.fetch(FetchDescriptor<ServiceCall>()).first { $0.id == f.job.id })
        XCTAssertEqual(saved.notes, "Technician found a failed capacitor")
        XCTAssertEqual(saved.findingsSummary, "Newer equipment finding on another device")
        XCTAssertEqual(f.job.notes, saved.notes)
    }

    func testSavedConflictRequiresReviewAndStaleReviewCannotOverwriteOffice() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.officeChange("Reviewed office value"); try f.publishSaved()
        let coordinator = f.coordinator()
        try await coordinator.synchronize(f.source)
        let review = try XCTUnwrap(coordinator.reviews.first)
        XCTAssertTrue(review.canApplyReviewed)
        XCTAssertNil(f.application)
        try f.officeChange("Newer office edit")
        do { try await coordinator.applyReviewed(review, context: f.source); XCTFail("Stale review must fail") } catch {}
        XCTAssertEqual(try f.savedValue(), .text("Newer office edit"))
        XCTAssertNil(f.application)
        try f.publishSaved()
        try await coordinator.synchronize(f.source)
        try await coordinator.applyReviewed(XCTUnwrap(coordinator.reviews.first), context: f.source)
        XCTAssertEqual(try f.savedValue(), f.original.value)
        XCTAssertEqual(f.prepareRequests.first?.reviewedConflict, true)
    }

    func testLostClaimReplyAndLostConfirmationPreserveOriginalOperation() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.losePrepare = true
        try await f.coordinator().synchronize(f.source)
        XCTAssertEqual(try f.savedValue(), .text("Original office note"))
        try await f.coordinator().synchronize(f.source)
        XCTAssertEqual(try f.savedValue(), f.original.value)
        XCTAssertEqual(Set(f.prepareRequests.map(\.operationID)).count, 1)
        try f.publishSaved(); f.loseConfirm = true
        try await f.coordinator().confirmPublished(f.source)
        XCTAssertEqual(f.application?.state, "published")
        XCTAssertFalse(try f.journal().pending.isEmpty)
        try f.officeChange("Office edited after publication")
        try await f.coordinator().synchronize(f.source)
        XCTAssertTrue(try f.journal().pending.isEmpty)
        XCTAssertEqual(try f.savedValue(), .text("Office edited after publication"))
    }

    func testModelSaveFailureLeavesOnlyOriginalSavedOfficeValue() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.saveModel = { _ in throw StaffReplicaSourceSyncError.storage }
        try await f.coordinator().synchronize(f.source)
        XCTAssertEqual(try f.savedValue(), .text("Original office note"))
        XCTAssertFalse(f.container.mainContext.hasChanges)
        XCTAssertEqual(try f.journal().pending[f.original.commandID]?.phase, "prepared")
        f.saveModel = nil
        try await f.coordinator().synchronize(f.source)
        XCTAssertEqual(try f.savedValue(), f.original.value)
        XCTAssertEqual(Set(f.prepareRequests.map(\.operationID)).count, 1)
    }

    func testSaveSucceededButReplyFailedDoesNotOverwriteLaterOfficeValue() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.saveModel = { context in try context.save(); throw StaffReplicaSourceSyncError.storage }
        try await f.coordinator().synchronize(f.source)
        XCTAssertEqual(try f.savedValue(), f.original.value)
        try f.officeChange("Office intervened after interrupted save")
        f.saveModel = nil
        try await f.coordinator().synchronize(f.source)
        XCTAssertEqual(try f.savedValue(), .text("Office intervened after interrupted save"))
        XCTAssertEqual(try f.journal().pending[f.original.commandID]?.phase, "prepared")
    }

    func testAccountChangeDuringResponseStopsBeforeAnyModelWrite() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.afterResponse = { f.allowed = false }
        do { try await f.coordinator().synchronize(f.source); XCTFail("Authority loss must escape") } catch {}
        XCTAssertEqual(try f.savedValue(), .text("Original office note"))
        XCTAssertNil(f.application)
        XCTAssertEqual(f.applyCalls, 0)
    }

    func testFailedSaveDoesNotDiscardAnUnrelatedDraftAddedBySaveObserver() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.saveModel = { _ in
            f.job.customer?.name = "Unrelated office draft"
            throw StaffReplicaSourceSyncError.storage
        }
        try await f.coordinator().synchronize(f.source)
        XCTAssertEqual(try f.savedValue(), .text("Original office note"))
        XCTAssertEqual(f.job.notes, "Original office note")
        XCTAssertEqual(f.job.customer?.name, "Unrelated office draft")
        XCTAssertTrue(f.container.mainContext.hasChanges)
    }

    func testEveryJournalWriteBoundaryRetainsOriginalAndRecovers() async throws {
        let baseline = try Fixture(); defer { baseline.cleanup() }
        try await baseline.coordinator().synchronize(baseline.source)
        let boundaries = baseline.memory.writes
        for boundary in 1...boundaries {
            for after in [false, true] {
                let f = try Fixture(); defer { f.cleanup() }
                if after { f.memory.failAfter = boundary } else { f.memory.failBefore = boundary }
                do { try await f.coordinator().synchronize(f.source) } catch {}
                f.memory.failBefore = nil; f.memory.failAfter = nil
                try await f.coordinator().synchronize(f.source)
                XCTAssertEqual(try f.savedValue(), f.original.value, "Boundary \(boundary), after=\(after)")
                XCTAssertEqual(try f.journal().pending[f.original.commandID]?.edit.receipt, f.receipt)
                XCTAssertEqual(Set(f.prepareRequests.map(\.operationID)).count, 1)
                let authored = try f.container.mainContext.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>())
                    .filter { $0.author == "staff-field-edit-v1:" + f.original.commandID }
                XCTAssertEqual(authored.count, 1)
                try f.publishSaved(); try await f.coordinator().confirmPublished(f.source)
                XCTAssertTrue(try f.journal().pending.isEmpty)
            }
        }
    }

    func testLargeEscapedOfficeValueCanBeReviewedAndApplied() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let note = String(repeating: "é", count: 500_000)
        try f.officeChange(note); try f.publishSaved(); f.escapeUnicode = true
        let coordinator = f.coordinator()
        try await coordinator.synchronize(f.source)
        let review = try XCTUnwrap(coordinator.reviews.first)
        XCTAssertTrue(review.canApplyReviewed)
        try await coordinator.applyReviewed(review, context: f.source)
        XCTAssertEqual(try f.savedValue(), f.original.value)
        let bytes = try f.response(StaffOwnerFieldEditTransport.path(f.source.scope, id: f.original.commandID), method: "GET", bytes: nil)
        XCTAssertGreaterThan(bytes.count, 4 * 1024 * 1024)
        try await f.coordinator().synchronize(f.source)
        try f.publishSaved(); try await f.coordinator().confirmPublished(f.source)
        XCTAssertTrue(try f.journal().pending.isEmpty)
    }

    func testInterruptedConfirmationCleanupRecoversWithoutAnotherModelSave() async throws {
        for after in [false, true] {
            let f = try Fixture(); defer { f.cleanup() }
            try await f.coordinator().synchronize(f.source); try f.publishSaved()
            if after { f.memory.failAfter = f.memory.writes + 1 } else { f.memory.failBefore = f.memory.writes + 1 }
            try await f.coordinator().confirmPublished(f.source)
            XCTAssertEqual(f.application?.state, "published")
            f.memory.failAfter = nil; f.memory.failBefore = nil
            try await f.coordinator().synchronize(f.source)
            XCTAssertTrue(try f.journal().pending.isEmpty)
            XCTAssertEqual(f.applyCalls, 1)
        }
    }

    func testOwnerTransportLimitsAndExactPaths() {
        let id = UUID().uuidString.lowercased()
        XCTAssertTrue(StaffOwnerFieldEditTransport.allows(path: StaffOwnerFieldEditTransport.root + "/" + id + "/prepare",
            method: "POST", body: Data(repeating: 32, count: StaffOwnerFieldEditTransport.maximumRequestBytes)))
        XCTAssertFalse(StaffOwnerFieldEditTransport.allows(path: StaffOwnerFieldEditTransport.root + "/" + id + "/prepare",
            method: "POST", body: Data(repeating: 32, count: StaffOwnerFieldEditTransport.maximumRequestBytes + 1)))
        for path in [StaffOwnerFieldEditTransport.root + "/", StaffOwnerFieldEditTransport.root + "/" + id + "/", "https://foreign.invalid" + StaffOwnerFieldEditTransport.root] {
            XCTAssertFalse(StaffOwnerFieldEditTransport.allows(path: path, method: "GET", body: nil))
        }
    }

    func testOwnerSyncActuallyInvokesFieldApplicationBeforeCapturingSource() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let sourceStore = StaffWorkspaceRecoveryBoundaryTests.Memory()
        var captured = false
        let coordinator = StaffReplicaSourceCoordinator(dependencies: .init(context: { f.source }, check: f.check,
            capture: { _, _ in
                captured = true; XCTAssertEqual(try f.savedValue(), f.original.value)
                throw StaffReplicaSourceSyncError.history
            }, request: { _, _, _ in XCTFail("Unexpected core network call"); throw StaffReplicaSourceSyncError.invalid },
            store: sourceStore.store, ownerFieldEdits: f.coordinator()))
        await coordinator.sync()
        XCTAssertTrue(captured)
        XCTAssertEqual(try f.savedValue(), f.original.value)
    }
}
