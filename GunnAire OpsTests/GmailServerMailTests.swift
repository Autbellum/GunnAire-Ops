import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor @Suite("Native shared Mail transport and recovery")
struct GmailServerMailTests {
    @MainActor final class Fixture {
        let scope = GmailServerScope(company: .init(companyID: UUID(), backendOrigin: "https://mail.example.invalid",
            actorEmail: "office@example.invalid"), grantID: UUID())
        var allowed = true
        var storageAvailable = true
        var actionRecords: [GmailServerActionRecord] = []
        var serverActions: Set<UUID> = []
        var requests: [(String, String, Data?)] = []
        var providerWrites = 0
        var labels = ["INBOX", "UNREAD"]
        var saved: [UUID: GmailServerMessage] = [:]
        var states: [UUID: GmailServerOperationState] = [:]
        var before: ((String, String, Data?) async throws -> Void)?
        var after: ((String, String) throws -> Void)?
        var modify: ((inout [String: Any]) -> Void)?
        var rejectSend = false
        var pageToken: String?
        var rawOverride: Data?
        var draftRecord: GmailDraftRecord?
        var draftStorageAvailable = true
        lazy var auth = GoogleAuthManager(testTokens: .init(accessToken: "", refreshToken: nil, idToken: nil, expiration: .distantPast),
            email: "not-the-current-mailbox@example.invalid", businessEmail: { nil }) { _ in
                Issue.record("Shared Mail must not use a device Google token or a direct Gmail URL")
                throw URLError(.userAuthenticationRequired)
            }
        var actionStore: GmailServerActionStore {
            .init(read: { [self] retained in
                #expect(retained == scope)
                guard storageAvailable else { throw GmailServerMailError.storage }; return actionRecords
            }, replace: { [self] retained, expected, next in
                #expect(retained == scope)
                guard storageAvailable else { throw GmailServerMailError.storage }
                guard actionRecords == expected else { throw GmailServerMailError.pending }
                actionRecords = next
            })
        }
        var draftStore: GmailDraftStore {
            .init(read: { [self] _, _ in
                guard draftStorageAvailable else { throw GmailDraftError.storage }; return draftRecord
            }, write: { [self] record, revision in
                guard draftStorageAvailable else { throw GmailDraftError.storage }
                guard draftRecord?.revision == revision else { throw GmailDraftError.changed }
                try record.validate(); draftRecord = record
            }, list: { _ in [] })
        }
        func client() throws -> GmailServerMail {
            try .init(scope: scope, store: actionStore, check: { [self] in
                guard allowed else { throw GmailServerMailError.access }
            }, request: { [self] path, method, body, _ in try await request(path, method, body) })
        }
        func provider() throws -> WorkspaceProviderOperation {
            let client = try client()
            return WorkspaceProviderOperation(serverMail: client) { (try? client.check()) != nil }
        }
        func journal(reopen: Bool = false) throws -> GmailDraftSession {
            let record = reopen ? try #require(draftRecord) : GmailDraftRecord(id: UUID(), scope: scope.draftScope,
                content: .init(to: "customer@example.invalid", subject: "Repair visit", body: "Fixture only.",
                    files: [.init(.init(fileName: "Equipment.txt", mimeType: "text/plain", data: Data("Fixture equipment".utf8)))]))
            return try .init(record: record, store: draftStore) { [self] in
                guard allowed else { throw GmailDraftError.access }
            }
        }
        func message(_ id: String = "message", sentID: UUID? = nil) -> [String: Any] {
            var headers = [["name": "From", "value": scope.company.actorEmail],
                ["name": "To", "value": "customer@example.invalid"], ["name": "Subject", "value": "Repair visit"]]
            if let sentID { headers.append(["name": "Message-ID", "value": "<gunnaire-\(sentID.uuidString.lowercased())@gunnaire.com>"]) }
            return ["id": id, "threadId": "thread", "labelIds": sentID == nil ? labels : ["SENT"], "snippet": "Fixture mail",
                "payload": ["headers": headers, "mimeType": "text/plain", "body": ["data": Data("Fixture only.".utf8).base64EncodedString(), "size": 13]]]
        }
        func outcome(_ id: UUID) -> [String: Any] {
            let state = states[id] ?? .prepared
            var value: [String: Any] = ["id": id.uuidString.lowercased(), "kind": "send", "state": state.rawValue]
            if state == .confirmed || state == .accepted { value["messageID"] = "sent-" + id.uuidString.lowercased(); value["threadID"] = "thread" }
            return value
        }
        func request(_ path: String, _ method: String, _ body: Data?) async throws -> Data {
            requests.append((path, method, body)); try await before?(path, method, body)
            if let rawOverride { return rawOverride }
            let components = URLComponents(string: path)!
            let route = String(components.path.dropFirst("/api/google/mail/".count))
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            let payload = try body.map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] } ?? [:]
            #expect((method == "GET" ? query["companyID"] : payload["companyID"] as? String) == scope.company.companyID.uuidString.lowercased())
            #expect((method == "GET" ? query["grantID"] : payload["grantID"] as? String) == scope.grantID.uuidString.lowercased())
            #expect(!path.contains("gmail.googleapis.com"))
            var value: [String: Any]
            if route == "messages" {
                value = ["messages": [message()]]
                if let pageToken { value["nextPageToken"] = pageToken }
            } else if route.hasSuffix("/attachments/attachment") {
                value = ["messageID": "message", "attachmentID": "attachment", "body": ["data": Data("file".utf8).base64EncodedString(), "size": 4]]
            } else if route.hasSuffix("/actions") {
                let id = UUID(uuidString: payload["id"] as! String)!
                #expect(actionRecords.contains { $0.id == id })
                if serverActions.insert(id).inserted {
                    providerWrites += 1
                    switch payload["action"] as! String {
                    case "read": labels.removeAll { $0 == "UNREAD" }
                    case "unread": if !labels.contains("UNREAD") { labels.append("UNREAD") }
                    case "archive": labels.removeAll { $0 == "INBOX" }
                    case "trash": labels.append("TRASH")
                    default: labels.removeAll { $0 == "TRASH" }
                    }
                }
                value = ["id": id.uuidString, "kind": "action", "state": "confirmed", "message": message()]
            } else if route.hasPrefix("messages/sent-") {
                let id = UUID(uuidString: String(route.dropFirst("messages/sent-".count)))!
                value = ["message": message("sent-" + id.uuidString.lowercased(), sentID: id)]
            } else if route.hasPrefix("messages/") { value = ["message": message()] }
            else if route == "outbox", method == "POST" {
                let id = UUID(uuidString: payload["id"] as! String)!
                let message = try JSONDecoder().decode(GmailServerMessage.self, from: JSONSerialization.data(withJSONObject: payload["message"]!))
                if let original = saved[id] { #expect(original == message) }
                else { saved[id] = message; states[id] = .prepared }
                value = outcome(id)
            } else if route == "outbox" {
                value = ["operations": saved.map { id, message in
                    ["id": id.uuidString, "state": (states[id] ?? .prepared).rawValue, "createdAt": "2026-09-07T12:00:00+00:00",
                     "summary": ["to": message.to, "subject": message.subject, "attachmentNames": message.attachments.map(\.name)]] as [String: Any]
                }]
                if let pageToken { value["nextPageToken"] = pageToken }
            } else {
                let parts = route.split(separator: "/"); let id = UUID(uuidString: String(parts[1]))!
                if serverActions.contains(id) {
                    value = ["id": id.uuidString, "kind": "action", "state": "confirmed", "message": message()]
                } else {
                    guard saved[id] != nil else { throw GunnAireBackendError.server(statusCode: 404, message: "private") }
                    if route.hasSuffix("/send"), states[id] == .prepared {
                        #expect(draftRecord == nil || draftRecord?.serverAttempt?.id == id)
                        #expect(draftRecord == nil || draftRecord?.state == .sending)
                        providerWrites += 1; states[id] = rejectSend ? .rejected : .confirmed
                    }
                    if route.hasSuffix("/cancel"), states[id] == .prepared { states[id] = .cancelled }
                    value = outcome(id)
                    if route.hasSuffix("/message") {
                        value["message"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved[id]!))
                    }
                }
            }
            value["companyID"] = scope.company.companyID.uuidString; value["actorEmail"] = scope.company.actorEmail; value["grantID"] = scope.grantID.uuidString
            modify?(&value); try after?(path, method)
            return try JSONSerialization.data(withJSONObject: value)
        }
        func flow(journal: GmailDraftSession, provider: WorkspaceProviderOperation? = nil,
                  business: GmailBusinessContext? = nil) throws -> GmailSendWorkflow {
            let schema = GunnAireModelSchema.schema
            let context = ModelContext(try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)]))
            let content = journal.record.content
            return try GmailSendWorkflow(auth: auth, context: context,
                message: GmailOutgoingMessage(to: content.to, subject: content.subject, body: content.body,
                    attachments: content.files.map(\.attachment), reply: content.reply), business: business,
                provider: try provider ?? self.provider(), validateAccess: { [self] in if !allowed { throw GmailComposeError.access } }, journal: journal)
        }
    }

    @Test func defaultMailboxLoadsFromServerWithoutDeviceGoogleCredentials() async throws {
        let f = Fixture(); let provider = try f.provider(); let mailbox = GmailMailbox(auth: f.auth)
        await mailbox.refresh(folder: .inbox, query: "from:customer@example.invalid & subject:Repair", provider: provider)?.value
        #expect(mailbox.messages.map(\.id) == ["message"])
        #expect(f.requests.count == 1)
        let query = URLComponents(string: f.requests[0].0)!.queryItems!
        #expect(query.first { $0.name == "query" }?.value == "from:customer@example.invalid & subject:Repair")
        #expect(f.providerWrites == 0)
    }
    @Test func childOperationsKeepOriginalServerAndLateRevocationRejectsResult() async throws {
        let f = Fixture(); let parent = try f.provider(); let child = WorkspaceProviderOperation(parent: parent) { true }
        #expect(child.serverMail === parent.serverMail)
        f.after = { _, _ in f.allowed = false }
        await #expect(throws: (any Error).self) { try await child.serverMail!.message(id: "message", operation: child) }
        #expect(child.failure != nil)
    }
    @Test(arguments: ["companyID", "actorEmail", "grantID"])
    func wrongScopeIsRejectedBeforeAnyContentIsReturned(_ key: String) async throws {
        let f = Fixture(); let p = try f.provider()
        f.modify = { value in value[key] = key == "actorEmail" ? "other@example.invalid" : UUID().uuidString }
        await #expect(throws: GmailServerMailError.access) { try await p.serverMail!.message(id: "message", operation: p) }
    }
    @Test(arguments: ["/escape", "../other", "one?grantID=two", "", String(repeating: "a", count: 2049)])
    func invalidMessagePathNeverTouchesTransport(_ id: String) async throws {
        let f = Fixture(); let p = try f.provider()
        await #expect(throws: GmailServerMailError.invalid) { try await p.serverMail!.message(id: id, operation: p) }
        #expect(f.requests.isEmpty)
    }
    @Test func duplicatePageAndRepeatedTokenAreRejected() async throws {
        let f = Fixture(); let p = try f.provider()
        f.modify = { value in value["messages"] = [f.message(), f.message()] }
        await #expect(throws: GmailServerMailError.invalid) { try await p.serverMail!.page(folder: .inbox, query: "", pageToken: nil, maximum: 25, operation: p) }
        f.modify = nil; f.pageToken = "same"
        await #expect(throws: GmailServerMailError.invalid) { try await p.serverMail!.page(folder: .inbox, query: "", pageToken: "same", maximum: 25, operation: p) }
    }
    @Test func fullMessageAndAttachmentUseOriginalParentWithoutGoogleToken() async throws {
        let f = Fixture(); let p = try f.provider()
        let message: GmailMessageDetail = try await withCheckedThrowingContinuation { continuation in
            f.auth.fetchGmailMessage(id: "message", operation: p) { continuation.resume(with: $0) }
        }
        let attachment: GmailMessageBody = try await withCheckedThrowingContinuation { continuation in
            f.auth.fetchGmailAttachment(messageID: "message", attachmentID: "attachment", operation: p) { continuation.resume(with: $0) }
        }
        #expect(message.id == "message"); #expect(attachment.size == 4)
        f.modify = { $0["attachmentID"] = "other" }
        await #expect(throws: GmailServerMailError.invalid) { try await p.serverMail!.attachment(messageID: "message", attachmentID: "attachment", operation: p) }
    }
    @Test func actionSavesOriginalBeforePOSTAndLostReplyRecoversAfterRelaunch() async throws {
        let f = Fixture(); let p = try f.provider()
        f.after = { _, method in if method == "POST" { throw URLError(.networkConnectionLost) } }
        await #expect(throws: (any Error).self) { try await p.serverMail!.change(id: "message", threadID: "thread", action: .trash, operation: p) }
        #expect(f.actionRecords.count == 1 && f.providerWrites == 1)
        f.after = nil
        let reopened = try f.provider(); let previous = f.requests.count
        #expect(try await reopened.serverMail!.recoverActions(operation: reopened) == 0)
        #expect(f.requests.dropFirst(previous).allSatisfy { $0.1 == "GET" })
        #expect(f.providerWrites == 1 && f.actionRecords.isEmpty)
    }
    @Test func anotherActionCannotReplaceAnUnconfirmedOriginal() async throws {
        let f = Fixture(); let p = try f.provider()
        f.after = { _, _ in throw URLError(.networkConnectionLost) }
        await #expect(throws: (any Error).self) { try await p.serverMail!.change(id: "message", threadID: "thread", action: .archive, operation: p) }
        let count = f.requests.count
        await #expect(throws: GmailServerMailError.pending) { try await p.serverMail!.change(id: "message", threadID: "thread", action: .trash, operation: p) }
        #expect(f.requests.count == count && f.actionRecords.first?.action == .archive)
    }
    @Test func repeatingSameActionUsesSameImmutableServerClaim() async throws {
        let f = Fixture(); let p = try f.provider()
        f.after = { _, _ in throw URLError(.networkConnectionLost) }
        await #expect(throws: (any Error).self) { try await p.serverMail!.change(id: "message", threadID: "thread", action: .archive, operation: p) }
        let original = try #require(f.actionRecords.first)
        f.after = nil; let reopened = try f.provider()
        _ = try await reopened.serverMail!.change(id: "message", threadID: "thread", action: .archive, operation: reopened)
        let body = try JSONSerialization.jsonObject(with: f.requests.last!.2!) as! [String: Any]
        #expect(body["id"] as? String == original.id.uuidString.lowercased())
        #expect(f.providerWrites == 1)
    }
    @Test func failedActionStoragePreventsNetworkAndFailedCleanupKeepsOriginal() async throws {
        let f = Fixture(); let p = try f.provider(); f.storageAvailable = false
        await #expect(throws: GmailServerMailError.storage) { try await p.serverMail!.change(id: "message", threadID: "thread", action: .read, operation: p) }
        #expect(f.requests.isEmpty)
        f.storageAvailable = true; f.after = { _, _ in f.storageAvailable = false }
        await #expect(throws: GmailServerMailError.storage) { try await p.serverMail!.change(id: "message", threadID: "thread", action: .read, operation: p) }
        #expect(f.actionRecords.count == 1 && f.providerWrites == 1)
    }
    @Test func generalSendUsesJournalAttemptAndOriginalBodyThenConfirmsSent() async throws {
        let f = Fixture(); let journal = try f.journal(); let flow = try f.flow(journal: journal)
        #expect(journal.record.serverAttempt != nil)
        #expect(await flow.send().state == .sent)
        #expect(f.providerWrites == 1 && journal.record.state == .sent)
        #expect(flow.messageID == journal.record.messageID)
        #expect(f.saved.values.first?.attachments.first?.data == Data("Fixture equipment".utf8))
        #expect(await flow.send().state == .sent && f.providerWrites == 1)
    }
    @Test func lostSendReplyKeepsDraftLockedAndRestartUsesReadOnlyRecovery() async throws {
        let f = Fixture(); let journal = try f.journal(); let flow = try f.flow(journal: journal)
        f.after = { path, _ in if path.hasSuffix("/send") { throw URLError(.networkConnectionLost) } }
        #expect(await flow.send().state == .reviewRequired)
        #expect(journal.record.state == .review && f.providerWrites == 1)
        let original = journal.record.serverAttempt
        f.after = nil; let reopened = try f.journal(reopen: true); let previous = f.requests.count
        #expect(try await reopened.recoverServer(provider: f.provider()).state == .sent)
        #expect(reopened.record.serverAttempt == original)
        #expect(f.requests.dropFirst(previous).allSatisfy { $0.1 == "GET" })
        #expect(f.providerWrites == 1)
    }
    @Test func failedSentVerificationNeverMakesAnotherSendAvailable() async throws {
        let f = Fixture(); let journal = try f.journal(); let flow = try f.flow(journal: journal)
        f.before = { path, _, _ in
            if path.contains("messages/sent-") { throw GunnAireBackendError.server(statusCode: 403, message: "private") }
        }
        #expect(await flow.send().state == .reviewRequired)
        #expect(journal.record.state != .editing)
        #expect(f.providerWrites == 1)
    }
    @Test func confirmedRejectionRetainsPriorAttemptAndAllowsExplicitNewReviewedAttempt() async throws {
        let f = Fixture(); f.rejectSend = true; let journal = try f.journal(); let flow = try f.flow(journal: journal)
        let original = try #require(journal.record.serverAttempt)
        #expect(await flow.send().state == .notSent)
        #expect(journal.record.editable && journal.record.serverAttempt == nil)
        #expect(journal.record.retiredServerAttempts == [original])
        f.rejectSend = false; let second = try f.flow(journal: journal)
        #expect(journal.record.serverAttempt?.id != original.id)
        #expect(await second.send().state == .sent && f.providerWrites == 2)
    }
    @Test func interruptedPreparationRequiresOriginalCancellationBeforeEditing() async throws {
        let f = Fixture(); let journal = try f.journal(); let flow = try f.flow(journal: journal)
        f.after = { path, method in if path == "/api/google/mail/outbox" && method == "POST" { throw URLError(.networkConnectionLost) } }
        #expect(await flow.send().state == .reviewRequired && f.providerWrites == 0)
        f.after = nil; let reopened = try f.journal(reopen: true); let p = try f.provider()
        #expect(try await reopened.recoverServer(provider: p).state == .reviewRequired)
        #expect(reopened.serverCanCancel && !reopened.record.editable)
        #expect(try await reopened.recoverServer(provider: p, cancelUnsent: true).state == .notSent)
        #expect(reopened.record.editable && f.providerWrites == 0)
    }
    @Test func anotherGrantCannotAdoptInterruptedSend() async throws {
        let f = Fixture(); let journal = try f.journal(); let flow = try f.flow(journal: journal)
        f.after = { _, _ in throw URLError(.networkConnectionLost) }; _ = await flow.send()
        let other = try GmailServerMail(scope: .init(company: f.scope.company, grantID: UUID()), check: {}, request: { _, _, _, _ in
            Issue.record("Must not request another grant's original"); return Data()
        })
        let p = WorkspaceProviderOperation(serverMail: other) { true }
        await #expect(throws: GmailDraftError.access) { try await journal.recoverServer(provider: p) }
        #expect(journal.record.serverAttempt?.scope == f.scope)
    }
    @Test func modifiedOriginalContentDoesNotUnlockSavedDraft() async throws {
        let f = Fixture(); let journal = try f.journal(); let flow = try f.flow(journal: journal)
        f.after = { path, _ in if path.hasSuffix("/send") { throw URLError(.networkConnectionLost) } }; _ = await flow.send()
        f.after = nil
        f.modify = { value in
            if var message = value["message"] as? [String: Any], message["to"] != nil { message["body"] = "Changed"; value["message"] = message }
        }
        await #expect(throws: GmailDraftError.changed) { try await journal.recoverServer(provider: f.provider()) }
        #expect(journal.record.state == .review)
    }
    @Test func businessWorkflowCannotPassThroughGeneralOfficeServerSending() throws {
        let f = Fixture(); let journal = try f.journal()
        #expect(throws: GmailComposeError.access) {
            try f.flow(journal: journal, business: .init(customerID: UUID(), serviceCallID: UUID(), workflow: .appointmentConfirmation))
        }
        #expect(f.requests.isEmpty && f.providerWrites == 0)
    }
    @Test func replyRetainsExactParentAndOldDraftWithoutParentIsNotGuessed() throws {
        var reply = GmailReplyContext(threadID: "thread", messageID: "<original@example.invalid>", references: [], subject: "Repair visit")
        #expect(throws: GmailComposeError.header) { try GmailServerMessage(GmailOutgoingMessage(to: "customer@example.invalid", subject: "Repair visit", body: "Reply", reply: reply)) }
        reply.parentID = "parent"
        let message = try GmailServerMessage(GmailOutgoingMessage(to: "customer@example.invalid", subject: "Repair visit", body: "Reply", reply: reply))
        #expect(message.reply?.parentID == "parent")
    }
    @Test func outboxUsesSummariesAndRejectsWrongOriginalIdentity() async throws {
        let f = Fixture(); let journal = try f.journal(); _ = await (try f.flow(journal: journal)).send()
        let p = try f.provider(); let outbox = GmailServerOutbox(provider: p); await outbox.load()
        #expect(outbox.items.count == 1 && outbox.items[0].summary.attachmentNames == ["Equipment.txt"])
        f.modify = { $0["id"] = UUID().uuidString }
        await #expect(throws: GmailServerMailError.invalid) { try await p.serverMail!.savedMessage(id: journal.record.serverAttempt!.id, operation: p) }
    }
    @Test(arguments: [false, true])
    func encryptedDraftStoreAcceptsOnlyVerifiedOriginalRecovery(_ cancel: Bool) async throws {
        let f = Fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NativeServerMailRecovery-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GmailDraftStore.encrypted(directory: directory) { _ in Data(repeating: 97, count: 32) }
        let content = GmailDraftContent(to: "customer@example.invalid", subject: "Repair visit", body: "Fixture only.")
        let journal = try GmailDraftSession(record: .init(id: UUID(), scope: f.scope.draftScope, content: content), store: store, access: {})
        let flow = try f.flow(journal: journal)
        f.after = { path, method in
            if (cancel && path == "/api/google/mail/outbox" && method == "POST") || (!cancel && path.hasSuffix("/send")) {
                throw URLError(.networkConnectionLost)
            }
        }
        #expect(await flow.send().state == .reviewRequired)
        let saved = try #require(try store.read(f.scope.draftScope, journal.record.id))
        // A generic edit of the protected record is still rejected.
        var forged = saved; forged.revision += 1; forged.state = .editing
        #expect(throws: GmailDraftError.locked) { try store.write(forged, saved.revision) }
        let reopened = try GmailDraftSession(record: saved, store: store, access: {})
        f.after = nil
        let result = try await reopened.recoverServer(provider: f.provider(), cancelUnsent: cancel)
        #expect(result.state == (cancel ? .notSent : .sent))
        #expect(try store.read(f.scope.draftScope, journal.record.id)?.state == (cancel ? .editing : .sent))
        #expect(f.providerWrites == (cancel ? 0 : 1))
    }

    @Test(arguments: ["nullBody", "longName", "shortDomain"])
    func invalidServerCompositionIsRejectedBeforeAnyTransport(_ variant: String) async throws {
        let f = Fixture(); let p = try f.provider()
        let outgoing = try GmailOutgoingMessage(to: variant == "shortDomain" ? "customer@example.c" : "customer@example.invalid",
            subject: "Repair", body: variant == "nullBody" ? "invalid\u{0000}body" : "Fixture",
            attachments: variant == "longName" ? [.init(fileName: String(repeating: "é", count: 128), mimeType: "text/plain", data: Data())] : [])
        await #expect(throws: (any Error).self) { try await p.serverMail!.send(id: UUID(), message: GmailServerMessage(outgoing), operation: p) }
        #expect(f.requests.isEmpty)
    }

    @Test func oversizedAndMalformedResponsesFailWithoutProviderFallback() async throws {
        let f = Fixture(); let p = try f.provider(); f.rawOverride = Data(repeating: 32, count: 8 * 1024 * 1024 + 1)
        await #expect(throws: GmailServerMailError.invalid) { try await p.serverMail!.page(folder: .inbox, query: "", pageToken: nil, maximum: 25, operation: p) }
        f.rawOverride = Data("{\"private\":\"do not show this\"}".utf8)
        await #expect(throws: GmailServerMailError.invalid) { try await p.serverMail!.message(id: "message", operation: p) }
    }
}
