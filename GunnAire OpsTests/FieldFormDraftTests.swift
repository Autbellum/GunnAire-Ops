import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor struct FieldFormDraftTests {
    enum Fault: Error { case disk }
    @MainActor final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FieldFormJournalTest-" + UUID().uuidString)
        let scope = FieldFormDraftScope(companyID: UUID(), backendOrigin: "https://fixture.example.invalid",
                                       actorEmail: "form-fixture@gunnaire.com", storeID: UUID().uuidString)
        let question = FieldFormQuestion(label: "Supply temperature °F", kind: .text, required: true)
        let confirmation = FieldFormQuestion(label: "Safety checked", kind: .toggle, required: true)
        let container: ModelContainer
        let context: ModelContext
        let customer = Customer(name: "Original fixture customer")
        let template: FieldFormTemplate
        let job: ServiceCall
        let user: AppUser
        var allowed = true
        var keyAvailable = true
        var failAcknowledgement = false
        lazy var disk = FieldFormDraftStore.encrypted(directory: root.appendingPathComponent("drafts")) { [unowned self] _ in
            guard keyAvailable else { throw Fault.disk }; return Data(repeating: 53, count: 32)
        }
        var store: FieldFormDraftStore {
            .init(read: disk.read, write: { [unowned self] record, expected in
                if failAcknowledgement && record.state == .completed { throw Fault.disk }
                try disk.write(record, expected)
            }, list: disk.list)
        }
        var workflow: FieldFormDraftWorkflow {
            .init(context: context, scope: scope, store: store) { [unowned self] in
                guard allowed else { throw FieldFormDraftError.access }
            }
        }
        init() throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let schema = GunnAireModelSchema.schema
            container = try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, url: root.appendingPathComponent("forms.sqlite"), cloudKitDatabase: .none)
            ])
            context = ModelContext(container); context.autosaveEnabled = false
            template = FieldFormTemplate(title: "Original service readings", questions: [question, confirmation],
                applicableServiceTypes: [.service], requiresCompletionForCloseout: true)
            job = ServiceCall(siteAddress: "Original fixture site", equipmentSerialNumber: "FIXTURE-SERIAL",
                              type: .service, scheduledDate: Date(), customer: customer)
            user = AppUser(email: scope.actorEmail, role: .admin)
            context.insert(customer); context.insert(template); context.insert(job); context.insert(user)
            try context.save()
        }
        func open() throws -> FieldFormDraftSession { try workflow.open(jobID: job.id, templateID: template.id) }
        func ready() throws -> FieldFormDraftSession {
            let session = try open(); try session.save([question.id: "82.5 °F — café", confirmation.id: "true"]); return session
        }
        func file(_ record: FieldFormDraftRecord) -> URL {
            root.appendingPathComponent("drafts").appendingPathComponent(scope.storageKey)
                .appendingPathComponent(record.slot.key + ".sealed")
        }
        func export(_ response: FieldFormResponse, _ job: ServiceCall, _ template: FieldFormTemplate) throws -> URL {
            let url = root.appendingPathComponent(response.id.uuidString + ".pdf")
            try Data("%PDF-fixture-original".utf8).write(to: url, options: .atomic); return url
        }
        func counts() throws -> [Int] {
            let read = ModelContext(container); read.autosaveEnabled = false
            return [try read.fetchCount(FetchDescriptor<FieldFormResponse>()),
                    try read.fetchCount(FetchDescriptor<ServiceDocumentAttachment>()),
                    try read.fetchCount(FetchDescriptor<ServiceCallActivity>())]
        }
        deinit { try? FileManager.default.removeItem(at: root) }
    }

    @Test func unfinishedRequiredAnswersResumeWithoutCompletingTheJob() throws {
        let f = try Fixture(); let draft = try f.open()
        try draft.save([f.question.id: "82.5 °F — café"])
        let reopened = try f.open()
        #expect(reopened.record == draft.record)
        #expect(reopened.record.content?.answers[f.question.id] == "82.5 °F — café")
        #expect(try f.counts() == [0, 0, 0])
        #expect(throws: FieldFormDraftError.locked) { try reopened.begin() }
        #expect(try f.workflow.drafts(jobID: f.job.id).count == 1)
    }

    @Test func savedBytesArePrivateAuthenticatedAndExcludedFromBackup() throws {
        let f = try Fixture(); let draft = try f.ready()
        let bytes = try Data(contentsOf: f.file(draft.record))
        for text in [f.scope.actorEmail, f.customer.name, f.job.siteAddress!, "82.5", "FIXTURE-SERIAL"] {
            #expect(bytes.range(of: Data(text.utf8)) == nil)
        }
        let root = f.root.appendingPathComponent("drafts")
        #expect(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func freshStoreInstanceReadsExactOriginalAnswers() throws {
        let f = try Fixture(); let draft = try f.ready()
        let independent = FieldFormDraftStore.encrypted(directory: f.root.appendingPathComponent("drafts")) { _ in Data(repeating: 53, count: 32) }
        #expect(try independent.read(draft.record.slot) == draft.record)
    }

    @Test func anotherCompanyAccountServerOrStoreCannotAdoptDraft() throws {
        let f = try Fixture(); let draft = try f.ready()
        let scopes = [
            FieldFormDraftScope(companyID: UUID(), backendOrigin: f.scope.backendOrigin, actorEmail: f.scope.actorEmail, storeID: f.scope.storeID),
            FieldFormDraftScope(companyID: f.scope.companyID, backendOrigin: "https://other.example.invalid", actorEmail: f.scope.actorEmail, storeID: f.scope.storeID),
            FieldFormDraftScope(companyID: f.scope.companyID, backendOrigin: f.scope.backendOrigin, actorEmail: "other@example.invalid", storeID: f.scope.storeID),
            FieldFormDraftScope(companyID: f.scope.companyID, backendOrigin: f.scope.backendOrigin, actorEmail: f.scope.actorEmail, storeID: UUID().uuidString)
        ]
        for scope in scopes {
            #expect(try f.disk.read(.init(scope: scope, jobID: f.job.id, templateID: f.template.id)) == nil)
            #expect(try f.disk.list(scope, f.job.id).isEmpty)
        }
        #expect(try f.disk.list(f.scope, UUID()).isEmpty)
        #expect(try f.disk.read(draft.record.slot) == draft.record)
    }

    @Test func staleWindowCannotReplaceSavedAnswersOrResurrectDiscardedDraft() throws {
        let f = try Fixture(); let original = try f.ready(); let stale = try f.open()
        try original.save([f.question.id: "Newer reading"])
        #expect(throws: FieldFormDraftError.changed) { try stale.save([f.question.id: "Stale reading"]) }
        try original.discard()
        #expect(try f.workflow.drafts(jobID: f.job.id).isEmpty)
        #expect(try f.disk.read(original.record.slot)?.content == nil)
        #expect(throws: FieldFormDraftError.changed) { try stale.discard() }
        let next = try f.open()
        #expect(next.record.id != original.record.id)
        #expect(next.record.content?.answers.isEmpty == true)
        #expect(throws: FieldFormDraftError.locked) { try original.save([f.question.id: "Old"]) }
    }

    @Test func tamperedOrCopiedFilesAreRetainedAndNeverBecomeEmptyDrafts() throws {
        let f = try Fixture(); let draft = try f.ready()
        let other = FieldFormDraftSlot(scope: f.scope, jobID: UUID(), templateID: f.template.id)
        let copied = f.file(draft.record).deletingLastPathComponent().appendingPathComponent(other.key + ".sealed")
        try FileManager.default.copyItem(at: f.file(draft.record), to: copied)
        #expect(throws: FieldFormDraftError.storage) { try f.disk.read(other) }
        var data = try Data(contentsOf: f.file(draft.record)); data[data.count - 1] ^= 1
        try data.write(to: f.file(draft.record))
        #expect(throws: FieldFormDraftError.storage) { try f.open() }
        #expect(throws: FieldFormDraftError.storage) { try draft.save([:]) }
        #expect(try Data(contentsOf: f.file(draft.record)) == data)
    }

    @Test func lostKeyDoesNotRegenerateOrEraseAnyAccountDraft() throws {
        let f = try Fixture(); let draft = try f.ready(); let before = try Data(contentsOf: f.file(draft.record))
        f.keyAvailable = false
        #expect(throws: FieldFormDraftError.storage) { try f.open() }
        #expect(try Data(contentsOf: f.file(draft.record)) == before)
        var requestedCreation: Bool?
        let missing = FieldFormDraftStore.encrypted(directory: f.root.appendingPathComponent("drafts")) { create in
            requestedCreation = create; throw Fault.disk
        }
        var record = FieldFormDraftRecord(slot: .init(scope: .init(companyID: UUID(), backendOrigin: f.scope.backendOrigin,
            actorEmail: f.scope.actorEmail, storeID: f.scope.storeID), jobID: UUID(), templateID: UUID()), content: draft.record.content!)
        record.revision = 0
        #expect(throws: FieldFormDraftError.storage) { try missing.write(record, nil) }
        #expect(requestedCreation == false)
    }

    @Test func unknownVersionInvalidAnswersAndOversizeTextCannotReplaceSavedRecord() throws {
        let f = try Fixture(); let draft = try f.ready()
        var future = draft.record; future.version = 99; future.revision += 1
        #expect(throws: FieldFormDraftError.storage) { try f.disk.write(future, draft.record.revision) }
        #expect(throws: FieldFormDraftError.storage) { try draft.save([UUID(): "Unrelated question"]) }
        #expect(throws: FieldFormDraftError.storage) { try draft.save([f.confirmation.id: "yes"]) }
        #expect(throws: FieldFormDraftError.limit) { try draft.save([f.question.id: String(repeating: "x", count: 262_145)]) }
        #expect(try f.disk.read(draft.record.slot) == draft.record)
    }

    @Test func revokedMembershipAndReadOnlyRoleCannotOpenEditCompleteOrDiscard() throws {
        let f = try Fixture(); let draft = try f.ready(); f.allowed = false
        #expect(throws: FieldFormDraftError.access) { try f.open() }
        #expect(throws: FieldFormDraftError.access) { try draft.save([:]) }
        #expect(throws: FieldFormDraftError.access) { try draft.discard() }
        #expect(throws: FieldFormDraftError.access) { try f.workflow.complete(draft, export: f.export) }
        f.allowed = true; f.user.role = .accounting
        #expect(throws: FieldFormDraftError.access) { try f.open() }
        #expect(try f.counts() == [0, 0, 0])
    }

    @Test func reassignedTechnicianLosesDraftAccessWithoutDeletingIt() throws {
        let f = try Fixture(); let draft = try f.ready()
        f.user.role = .fieldTechnician
        #expect(throws: FieldFormDraftError.access) { try draft.verify() }
        #expect(throws: FieldFormDraftError.access) { try f.workflow.drafts(jobID: f.job.id) }
        #expect(try f.disk.read(draft.record.slot) == draft.record)
    }

    @Test func changedEquipmentAndRetiredTemplateKeepOriginalReviewAnswers() throws {
        let f = try Fixture(); let draft = try f.ready()
        f.job.equipmentSerialNumber = "DIFFERENT-UNIT"
        #expect(throws: FieldFormDraftError.contextChanged) { try f.workflow.complete(draft, export: f.export) }
        #expect(draft.record.content?.job.equipment[3] == "FIXTURE-SERIAL")
        f.job.equipmentSerialNumber = "FIXTURE-SERIAL"; f.template.isActive = false
        #expect(try f.open().record == draft.record)
        #expect(try f.workflow.drafts(jobID: f.job.id).first?.id == draft.record.id)
        #expect(throws: FieldFormDraftError.contextChanged) { try f.workflow.verifyContext(draft.record) }
        try draft.discard()
        #expect(try f.counts() == [0, 0, 0])
    }

    @Test func duplicateJobIdentityIsNotAnAuthorizationShortcut() throws {
        let f = try Fixture(); let draft = try f.ready()
        f.context.insert(ServiceCall(id: f.job.id, type: .service, scheduledDate: Date(), customer: f.customer))
        #expect(throws: FieldFormDraftError.access) { try draft.verify() }
        #expect(try f.disk.read(draft.record.slot) == draft.record)
    }

    @Test func completionHasOneOriginalResponseFileAndActivityAfterRepeatedRequests() throws {
        let f = try Fixture(); let draft = try f.ready()
        let first = try f.workflow.complete(draft, export: f.export)
        #expect(first.newFileData != nil)
        #expect(first.attachment.id == draft.record.attachmentID)
        #expect(try f.counts() == [1, 1, 1])
        let reopened = try f.open()
        let recovered = try f.workflow.complete(reopened, export: { _, _, _ in throw Fault.disk })
        #expect(recovered.newFileData == nil)
        #expect(recovered.attachment.id == first.attachment.id)
        #expect(try f.counts() == [1, 1, 1])
        #expect(try f.workflow.drafts(jobID: f.job.id).isEmpty)
        #expect(throws: FieldFormDraftError.locked) { try reopened.discard() }
    }

    @Test func crashAfterJournalLockRequiresExplicitCompletionAndKeepsIDs() throws {
        let f = try Fixture(); let draft = try f.ready(); try draft.begin()
        let original = draft.record
        let reopened = try f.open()
        #expect(reopened.record == original)
        #expect(try f.counts() == [0, 0, 0])
        #expect(throws: FieldFormDraftError.locked) { try reopened.save([:]) }
        #expect(throws: FieldFormDraftError.locked) { try reopened.discard() }
        _ = try f.workflow.complete(reopened, export: f.export)
        #expect(reopened.record.id == original.id)
        #expect(reopened.record.completedAt == original.completedAt)
        #expect(try f.counts() == [1, 1, 1])
    }

    @Test func failedPDFOrDatabaseSaveLeavesNoCompletionAndRetryUsesOriginalIDs() throws {
        let f = try Fixture(); let draft = try f.ready(); let originalID = draft.record.id
        #expect(throws: Fault.self) { try f.workflow.complete(draft, export: { _, _, _ in throw Fault.disk }) }
        #expect(try f.counts() == [0, 0, 0])
        #expect(throws: Fault.self) { try f.workflow.complete(draft, export: f.export, save: { _ in throw Fault.disk }) }
        #expect(try f.counts() == [0, 0, 0])
        let reopened = try f.open()
        _ = try f.workflow.complete(reopened, export: f.export)
        #expect(reopened.record.id == originalID)
        #expect(try f.counts() == [1, 1, 1])
    }

    @Test func lostAcknowledgementRecoversCommittedOriginalWithoutAnotherExportOrFile() throws {
        let f = try Fixture(); let draft = try f.ready(); f.failAcknowledgement = true
        #expect(throws: Fault.self) { try f.workflow.complete(draft, export: f.export) }
        #expect(draft.record.state == .completing)
        #expect(try f.counts() == [1, 1, 1])
        f.failAcknowledgement = false
        let reopened = try f.open()
        _ = try f.workflow.complete(reopened, export: { _, _, _ in throw Fault.disk })
        #expect(reopened.record.state == .completed)
        #expect(try f.counts() == [1, 1, 1])
    }

    @Test func missingPreviouslyCompletedFileIsReviewNotPermissionToRecreate() throws {
        let f = try Fixture(); let draft = try f.ready()
        let saved = try f.workflow.complete(draft, export: f.export)
        saved.context.delete(saved.attachment); try saved.context.save()
        #expect(throws: FieldFormDraftError.completionReview) { try f.workflow.complete(try f.open(), export: f.export) }
        #expect(try f.counts() == [1, 0, 1])
    }

    @Test func explicitAnotherFormUsesNewIDsAndCannotBeStartedFromAnUnfinishedDraft() throws {
        let f = try Fixture(); let draft = try f.ready()
        #expect(throws: FieldFormDraftError.locked) { try f.workflow.open(jobID: f.job.id, templateID: f.template.id, startAnother: true) }
        _ = try f.workflow.complete(draft, export: f.export)
        let another = try f.workflow.open(jobID: f.job.id, templateID: f.template.id, startAnother: true)
        #expect(another.record.id != draft.record.id)
        #expect(another.record.attachmentID != draft.record.attachmentID)
        #expect(another.record.content?.answers.isEmpty == true)
        #expect(try f.counts() == [1, 1, 1])
    }

    @Test func formTransactionDoesNotSaveUnrelatedWindowEdits() throws {
        let f = try Fixture(); let unrelated = Customer(name: "Saved unrelated customer")
        f.context.insert(unrelated); try f.context.save()
        unrelated.name = "Unsaved unrelated edit"
        _ = try f.workflow.complete(try f.ready(), export: f.export)
        let fresh = ModelContext(f.container)
        #expect(try fresh.fetch(FetchDescriptor<Customer>()).first(where: { $0.id == unrelated.id })?.name == "Saved unrelated customer")
        #expect(unrelated.name == "Unsaved unrelated edit")
        #expect(f.context.hasChanges)
    }

    @Test func anotherCustomersInvoiceAndAnotherJobsEstimateCannotReceiveFormFiles() throws {
        let f = try Fixture(); let other = Customer(name: "Another fixture customer")
        let invoice = Invoice(serviceCallID: f.job.id, customer: other)
        f.context.insert(other); f.context.insert(invoice); f.job.linkedInvoiceID = invoice.id; try f.context.save()
        let draft = try f.ready()
        #expect(throws: FieldFormDraftError.fileLinkReview) { try f.workflow.complete(draft, export: f.export) }
        #expect(draft.record.state == .editing)
        #expect(try f.counts() == [0, 0, 0])
        let estimate = Estimate(scheduledServiceCallID: UUID(), customer: f.customer)
        f.context.insert(estimate); f.job.linkedInvoiceID = nil; f.job.linkedEstimateID = estimate.id
        #expect(throws: FieldFormDraftError.fileLinkReview) { try f.workflow.verifyFileLineage(job: f.job, in: f.context) }
    }

    @Test func propertyAndEquipmentMustBelongToOriginalCustomerAndSite() throws {
        let f = try Fixture(); let other = Customer(name: "Other property owner")
        let site = CustomerServiceLocation(customer: other, name: "Other site", address: "Fixture address")
        let equipment = CustomerEquipment(customer: other, name: "Other unit")
        f.context.insert(other); f.context.insert(site); f.context.insert(equipment)
        f.job.serviceLocationID = site.id
        #expect(throws: FieldFormDraftError.fileLinkReview) { try f.workflow.verifyFileLineage(job: f.job, in: f.context) }
        f.job.serviceLocationID = nil; f.job.customerEquipmentID = equipment.id
        #expect(throws: FieldFormDraftError.fileLinkReview) { try f.workflow.verifyFileLineage(job: f.job, in: f.context) }
        equipment.customer = f.customer; equipment.serviceLocationID = UUID(); f.job.serviceLocationID = site.id
        site.customer = f.customer
        #expect(throws: FieldFormDraftError.fileLinkReview) { try f.workflow.verifyFileLineage(job: f.job, in: f.context) }
    }

    @Test func correctScheduledEstimateAndInvoiceKeepTheirExactAttachmentLinks() throws {
        let f = try Fixture()
        let invoice = Invoice(serviceCallID: f.job.id, customer: f.customer)
        let estimate = Estimate(scheduledServiceCallID: f.job.id, customer: f.customer)
        f.context.insert(invoice); f.context.insert(estimate)
        f.job.linkedInvoiceID = invoice.id; f.job.linkedEstimateID = estimate.id; try f.context.save()
        let saved = try f.workflow.complete(try f.ready(), export: f.export)
        #expect(saved.attachment.invoiceID == invoice.id)
        #expect(saved.attachment.estimateID == estimate.id)
        #expect(saved.attachment.customer?.id == f.customer.id)
        #expect(try f.counts() == [1, 1, 1])
    }

    @Test func incompleteAnswersCannotBePersistedAsACompletingRecord() throws {
        let f = try Fixture(); let draft = try f.open()
        var invalid = draft.record; invalid.state = .completing; invalid.completedAt = Date(); invalid.revision += 1
        #expect(throws: FieldFormDraftError.storage) { try f.disk.write(invalid, draft.record.revision) }
        #expect(try f.disk.read(draft.record.slot)?.state == .editing)
    }

    @Test func removedResponseAndAttachmentDoNotEraseOriginalCompletionEvidence() throws {
        let f = try Fixture(); let draft = try f.ready(); f.failAcknowledgement = true
        #expect(throws: Fault.self) { try f.workflow.complete(draft, export: f.export) }
        let source = ModelContext(f.container); source.autosaveEnabled = false
        for response in try source.fetch(FetchDescriptor<FieldFormResponse>()) { source.delete(response) }
        for file in try source.fetch(FetchDescriptor<ServiceDocumentAttachment>()) { source.delete(file) }
        try source.save(); f.failAcknowledgement = false
        #expect(throws: FieldFormDraftError.completionReview) { try f.workflow.complete(try f.open(), export: f.export) }
        #expect(try f.counts() == [0, 0, 1])
    }

    @Test func changedCompletionActivityRequiresReviewWithoutRewritingHistory() throws {
        let f = try Fixture(); let draft = try f.ready()
        let saved = try f.workflow.complete(draft, export: f.export)
        let activity = try #require(saved.context.fetch(FetchDescriptor<ServiceCallActivity>()).first)
        #expect(activity.id == draft.record.activityID)
        activity.detail = "Changed audit evidence"; try saved.context.save()
        #expect(throws: FieldFormDraftError.completionReview) { try f.workflow.complete(try f.open(), export: f.export) }
        #expect(activity.detail == "Changed audit evidence")
        #expect(try f.counts() == [1, 1, 1])
    }

    @Test func confirmedUploadStoresItsOriginalIDAndIsNotAutomaticallyRepeated() async throws {
        let f = try Fixture(); let saved = try f.workflow.complete(try f.ready(), export: f.export)
        let id = UUID().uuidString
        var requests = 0
        await f.workflow.syncNewFile(saved) { bytes, attachment in
            requests += 1; #expect(bytes == saved.newFileData); #expect(attachment.id == saved.record.attachmentID); return id
        }
        await f.workflow.syncNewFile(saved) { _, _ in requests += 1; return UUID().uuidString }
        #expect(requests == 1)
        #expect(saved.attachment.backendDocumentID == id)
        #expect(saved.attachment.sharedCompanySyncStatus == "stored")
        let recovered = try f.workflow.complete(try f.open(), export: f.export)
        await f.workflow.syncNewFile(recovered) { _, _ in requests += 1; return UUID().uuidString }
        #expect(requests == 1)
    }

    @Test func revokedAccessBeforeUploadPreventsDispatch() async throws {
        let f = try Fixture(); let saved = try f.workflow.complete(try f.ready(), export: f.export)
        f.allowed = false; var requests = 0
        await f.workflow.syncNewFile(saved) { _, _ in requests += 1; return UUID().uuidString }
        #expect(requests == 0)
        #expect(saved.attachment.backendDocumentID == nil)
        #expect(saved.attachment.sharedCompanySyncStatus == nil)
    }

    @Test func lateUploadSuccessAndFailureCannotWriteAfterJobAccessIsRevoked() async throws {
        for fails in [false, true] {
            let f = try Fixture(); let saved = try f.workflow.complete(try f.ready(), export: f.export)
            await f.workflow.syncNewFile(saved) { _, _ in
                f.allowed = false
                if fails { throw Fault.disk }
                return UUID().uuidString
            }
            #expect(saved.attachment.backendDocumentID == nil)
            #expect(saved.attachment.sharedCompanySyncStatus == nil)
            #expect(try f.counts() == [1, 1, 1])
        }
    }

    @Test func failedOrMalformedUploadKeepsTheOriginalFileWithoutClaimingSharedSuccess() async throws {
        for malformed in [false, true] {
            let f = try Fixture(); let saved = try f.workflow.complete(try f.ready(), export: f.export)
            await f.workflow.syncNewFile(saved) { _, _ in
                if malformed { return "not-a-document-identity" }
                throw Fault.disk
            }
            #expect(saved.attachment.backendDocumentID == nil)
            #expect(saved.attachment.sharedCompanySyncStatus == "needs_attention")
            #expect(try Data(contentsOf: saved.attachment.localFileURL) == saved.newFileData)
            #expect(try f.counts() == [1, 1, 1])
        }
    }

    @Test func changedLocalFileOrOriginalHistoryCannotBeMarkedAsUploaded() async throws {
        let f = try Fixture(); let saved = try f.workflow.complete(try f.ready(), export: f.export)
        var requests = 0
        await f.workflow.syncNewFile(saved) { _, attachment in
            requests += 1
            attachment.caption = "Changed while upload was pending"
            return UUID().uuidString
        }
        #expect(requests == 1)
        #expect(saved.attachment.backendDocumentID == nil)
        #expect(saved.attachment.sharedCompanySyncStatus == nil)
        #expect(saved.attachment.caption == "Changed while upload was pending")
        let other = try Fixture(); let changedFile = try other.workflow.complete(try other.ready(), export: other.export)
        try Data("Changed local bytes".utf8).write(to: changedFile.attachment.localFileURL)
        await other.workflow.syncNewFile(changedFile) { _, _ in requests += 1; return UUID().uuidString }
        #expect(requests == 1)
        #expect(changedFile.attachment.backendDocumentID == nil)
        #expect(changedFile.attachment.sharedCompanySyncStatus == nil)
    }
}
