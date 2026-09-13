import Foundation
import Testing
@testable import GunnAire_Ops

@MainActor struct GmailDraftJournalTests {
    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MailJournalTest-" + UUID().uuidString)
        let scope = GmailDraftScope(companyID: UUID(), backendOrigin: "https://fixture.example.invalid",
            actorEmail: "mail-fixture@gunnaire.com", googleEmail: "mail-fixture@gunnaire.com")
        var key = Data(repeating: 33, count: 32)
        var keyAvailable = true
        var allowed = true
        var activeLimit = 512
        lazy var store = GmailDraftStore.encrypted(directory: root, activeDraftLimit: activeLimit) { [unowned self] _ in
            guard keyAvailable else { throw GmailDraftError.storage }; return key
        }
        var content: GmailDraftContent {
            .init(to: "incomplete@", subject: "Repair estimate — draft", body: "Private fixture body",
                files: [.init(.init(fileName: "Equipment.txt", mimeType: "text/plain", data: Data("Private fixture equipment".utf8)))],
                reply: .init(threadID: "original-thread", messageID: "<original@example.invalid>", references: [], subject: "Repair estimate — draft"),
                business: .init(customerID: UUID(), serviceCallID: UUID(), workflow: .appointmentConfirmation),
                requiresBusinessContext: true)
        }
        func session(_ content: GmailDraftContent? = nil) throws -> GmailDraftSession {
            try open(.init(id: UUID(), scope: scope, content: content ?? self.content))
        }
        func open(_ record: GmailDraftRecord) throws -> GmailDraftSession {
            try .init(record: record, store: store) { if !self.allowed { throw GmailDraftError.access } }
        }
        func file(_ id: UUID) -> URL { root.appendingPathComponent(scope.storageKey).appendingPathComponent(id.uuidString.lowercased() + ".sealed") }
        deinit { try? FileManager.default.removeItem(at: root) }
    }

    @Test func incompleteDraftAndEveryFileSurviveReopening() throws {
        let f = Fixture(); let session = try f.session()
        let reopened = try f.open(#require(try f.store.read(f.scope, session.record.id)))
        #expect(reopened.record == session.record)
        #expect(reopened.record.content.files.first?.data == Data("Private fixture equipment".utf8))
        #expect(reopened.record.content.to == "incomplete@")
        #expect(reopened.record.content.business != nil)
    }

    @Test func storageContainsNeitherBodyNorAddressesAndIsExcludedFromBackup() throws {
        let f = Fixture(); let session = try f.session()
        let data = try Data(contentsOf: f.file(session.record.id))
        for text in ["Private fixture", "mail-fixture", "incomplete@", "Equipment.txt"] { #expect(data.range(of: Data(text.utf8)) == nil) }
        #expect(try f.root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func staleWindowsCannotReplaceNewerText() throws {
        let f = Fixture(); let first = try f.session(); let second = try f.open(first.record)
        var content = first.record.content; content.body = "Newer work"
        try first.save(content)
        #expect(throws: GmailDraftError.changed) { try second.save(second.record.content) }
        #expect(try f.store.read(f.scope, first.record.id)?.content.body == "Newer work")
    }

    @Test func restartDuringSendingNeverUnlocksOrResends() throws {
        let f = Fixture(); let original = try f.session(); try original.begin()
        let reopened = try f.open(#require(try f.store.read(f.scope, original.record.id)))
        #expect(!reopened.record.editable)
        #expect(throws: GmailDraftError.locked) { try reopened.begin() }
        #expect(throws: GmailDraftError.locked) { try reopened.save(reopened.record.content) }
        #expect(throws: GmailDraftError.locked) { try reopened.finish(.notSent(GmailComposeError.recipients)) }
        #expect(throws: GmailDraftError.locked) { try reopened.discard() }
    }

    @Test func uncertainOutcomeRetainsOriginalContentAndMessageIdentity() throws {
        let f = Fixture(); let session = try f.session(); let original = session.record
        try session.begin(); try session.finish(.uncertain)
        let reopened = try f.open(#require(try f.store.read(f.scope, original.id)))
        #expect(reopened.record.state == .review)
        #expect(reopened.record.content == original.content)
        #expect(reopened.record.messageID == original.messageID)
        #expect(try f.store.list(f.scope).first?.state == .review)
        #expect(throws: GmailDraftError.locked) { try reopened.begin() }
    }

    @Test func definiteRejectionAllowsExplicitEditButNotAnAutomaticSend() throws {
        let f = Fixture(); let session = try f.session()
        try session.begin(); try session.finish(.notSent(GmailComposeError.recipients))
        #expect(session.record.editable)
        var content = session.record.content; content.to = "customer@example.invalid"
        try session.save(content)
        #expect(session.record.state == .editing)
    }

    @Test func acceptedSendCannotBeReopenedForSendingOrListedAsDraft() throws {
        let f = Fixture(); let session = try f.session()
        try session.begin(); try session.finish(.init(state: .sent, message: "Accepted"))
        let reopened = try f.open(session.record)
        #expect(try f.store.list(f.scope).isEmpty)
        #expect(throws: GmailDraftError.locked) { try reopened.begin() }
    }

    @Test func discardClearsContentAndTombstoneStopsStaleResurrection() throws {
        let f = Fixture(); let session = try f.session(); let stale = try f.open(session.record)
        try session.discard()
        #expect(try f.store.list(f.scope).isEmpty)
        #expect(try f.store.read(f.scope, session.record.id)?.content.hasContent == false)
        #expect(throws: GmailDraftError.changed) { try stale.save(stale.record.content) }
    }

    @Test func revokedAccessCannotReadIntoSessionSaveOrStartDispatch() throws {
        let f = Fixture(); let session = try f.session(); f.allowed = false
        #expect(throws: GmailDraftError.access) { try f.open(session.record) }
        #expect(throws: GmailDraftError.access) { try session.save(session.record.content) }
        #expect(throws: GmailDraftError.access) { try session.begin() }
        #expect(try f.store.read(f.scope, session.record.id)?.state == .editing)
    }

    @Test func anotherCompanyMailboxAndBackendCannotSeeOriginalDraft() throws {
        let f = Fixture(); let session = try f.session()
        let variants = [
            GmailDraftScope(companyID: UUID(), backendOrigin: f.scope.backendOrigin, actorEmail: f.scope.actorEmail, googleEmail: f.scope.googleEmail),
            GmailDraftScope(companyID: f.scope.companyID, backendOrigin: "https://other.example.invalid", actorEmail: f.scope.actorEmail, googleEmail: f.scope.googleEmail),
            GmailDraftScope(companyID: f.scope.companyID, backendOrigin: f.scope.backendOrigin, actorEmail: "other@gunnaire.com", googleEmail: "other@gunnaire.com")
        ]
        for scope in variants {
            #expect(try f.store.list(scope).isEmpty)
            #expect(try f.store.read(scope, session.record.id) == nil)
        }
    }

    @Test func copiedCiphertextCannotChangeItsScopeOrDraftID() throws {
        let f = Fixture(); let session = try f.session(); let id = UUID()
        try FileManager.default.copyItem(at: f.file(session.record.id), to: f.file(id))
        #expect(throws: GmailDraftError.storage) { try f.store.read(f.scope, id) }
        #expect(throws: GmailDraftError.storage) { try f.store.list(f.scope) }
    }

    @Test func corruptedFileIsNotAnEmptyDraftOrOverwritten() throws {
        let f = Fixture(); let session = try f.session(); let url = f.file(session.record.id)
        let corrupt = Data("damaged fixture".utf8); try corrupt.write(to: url)
        #expect(throws: GmailDraftError.storage) { try f.store.list(f.scope) }
        #expect(throws: GmailDraftError.storage) { try session.save(session.record.content) }
        #expect(try Data(contentsOf: url) == corrupt)
    }

    @Test func missingKeyDoesNotEraseOrReplaceEncryptedDrafts() throws {
        let f = Fixture(); let session = try f.session(); let data = try Data(contentsOf: f.file(session.record.id))
        f.keyAvailable = false
        #expect(throws: GmailDraftError.storage) { try f.store.list(f.scope) }
        #expect(throws: GmailDraftError.storage) { try f.session() }
        #expect(try Data(contentsOf: f.file(session.record.id)) == data)
    }

    @Test func outcomeWriteFailureLeavesPersistentSendingLock() throws {
        let f = Fixture(); let session = try f.session(); try session.begin(); f.keyAvailable = false
        #expect(throws: GmailDraftError.storage) { try session.finish(.notSent(GmailComposeError.recipients)) }
        f.keyAvailable = true
        #expect(try f.store.read(f.scope, session.record.id)?.state == .sending)
    }

    @Test func invalidScopeAndOversizeDraftFailBeforeCreatingFiles() throws {
        let f = Fixture()
        let scope = GmailDraftScope(companyID: f.scope.companyID, backendOrigin: "http://fixture.example.invalid",
            actorEmail: f.scope.actorEmail, googleEmail: "different@gunnaire.com")
        #expect(throws: GmailDraftError.access) { try f.store.list(scope) }
        var content = f.content; content.body = String(repeating: "x", count: 2 * 1024 * 1024 + 1)
        #expect(throws: GmailDraftError.limit) { try f.session(content) }
        #expect(!FileManager.default.fileExists(atPath: f.root.path))
    }

    @Test func sentAndDiscardedTombstonesDoNotConsumeTheActiveDraftLimit() throws {
        let f = Fixture(); f.activeLimit = 2
        for _ in 0..<3 { let draft = try f.session(); try draft.discard() }
        let sent = try f.session(); try sent.begin(); try sent.finish(.init(state: .sent, message: "Accepted"))
        _ = try f.session(); _ = try f.session()
        #expect(try f.store.list(f.scope).count == 2)
        #expect(throws: GmailDraftError.limit) { try f.session() }
    }

    @Test func listingReadsOnlyAuthenticatedSummaryAndOpeningVerifiesTheWholePayload() throws {
        let f = Fixture(); let draft = try f.session()
        var bytes = try Data(contentsOf: f.file(draft.record.id)); bytes[bytes.count - 1] ^= 1
        try bytes.write(to: f.file(draft.record.id))
        #expect(try f.store.list(f.scope).first?.subject == draft.record.content.subject)
        #expect(throws: GmailDraftError.storage) { try f.store.read(f.scope, draft.record.id) }
        #expect(throws: GmailDraftError.storage) { try draft.begin() }
    }

    @Test func oldSummaryCannotUnlockANewerSendingPayload() throws {
        let f = Fixture(); let draft = try f.session()
        let old = try Data(contentsOf: f.file(draft.record.id))
        let oldOffset = 12 + old[8..<12].reduce(0) { ($0 << 8) | Int($1) }
        try draft.begin()
        let current = try Data(contentsOf: f.file(draft.record.id))
        let currentOffset = 12 + current[8..<12].reduce(0) { ($0 << 8) | Int($1) }
        try (old.prefix(oldOffset) + current.dropFirst(currentOffset)).write(to: f.file(draft.record.id))
        #expect(throws: GmailDraftError.storage) { try f.store.read(f.scope, draft.record.id) }
    }
}
