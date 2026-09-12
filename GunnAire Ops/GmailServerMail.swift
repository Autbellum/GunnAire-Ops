import Foundation
import SwiftData

enum GmailServerMailError: Error, LocalizedError, Equatable {
    case access, connect, unavailable, invalid, storage, pending, rejected
    var errorDescription: String? {
        switch self {
        case .access: "Your Mail access changed. Reopen Mail with the original business account."
        case .connect: "Approve Mail in Google Access, then return to your inbox."
        case .unavailable: "Shared Mail is not available right now. Your saved drafts have been kept."
        case .invalid: "The Mail reply could not be verified. Check the original request before trying again."
        case .storage: "This Mail change could not be saved securely. Existing work has been kept."
        case .pending: "An earlier change needs confirmation. Check Mail Changes before changing this message again."
        case .rejected: "Gmail did not send this message. Review the saved draft before trying again."
        }
    }
    static func safe(_ error: Error) -> Self {
        if let own = error as? Self { return own }
        if error is CompanyWorkspaceFailure || error is WorkspaceProviderAccessError { return .access }
        if error is DecodingError { return .invalid }
        if error is KeychainStore.KeychainError { return .storage }
        if let draft = error as? GmailDraftError {
            switch draft {
            case .access, .businessChanged: return .access
            case .storage, .limit: return .storage
            case .changed, .locked: return .pending
            }
        }
        if let connection = error as? GoogleServerConnectionError {
            switch connection {
            case .access, .changed: return .access
            case .storage: return .storage
            case .invalid: return .invalid
            default: return .unavailable
            }
        }
        if case GunnAireBackendError.server(let status, _) = error {
            if status == 401 || status == 403 { return .access }
            if status == 409 { return .pending }
        }
        return .unavailable
    }
}

struct GmailServerScope: Codable, Equatable {
    let company: GoogleServerScope
    let grantID: UUID
    var storageKey: String { company.storageKey + "-MailActions-" + grantID.uuidString.lowercased() }
    var draftScope: GmailDraftScope {
        .init(companyID: company.companyID, backendOrigin: company.backendOrigin,
              actorEmail: company.actorEmail, googleEmail: company.actorEmail)
    }
}

struct GmailServerStamp: Decodable {
    let companyID: UUID
    let actorEmail: String
    let grantID: UUID
    func validate(_ scope: GmailServerScope) throws {
        guard companyID == scope.company.companyID, actorEmail == scope.company.actorEmail,
              grantID == scope.grantID else { throw GmailServerMailError.access }
    }
}

enum GmailServerOperationState: String, Codable {
    case prepared, dispatching, accepted, confirmed, rejected, review, cancelled
    var title: String {
        switch self {
        case .prepared: "Not sent"
        case .confirmed: "Saved in Sent"
        case .rejected, .cancelled: "Not sent"
        default: "Check sending status"
        }
    }
}

struct GmailServerOperation: Decodable, Identifiable {
    let id: UUID
    let kind: String
    let state: GmailServerOperationState
    let messageID: String?
    let threadID: String?
    func validate(id: UUID, kind: String) throws {
        guard self.id == id, self.kind == kind,
              messageID.map(GmailServerMail.validID) != false, threadID.map(GmailServerMail.validID) != false,
              (messageID == nil) == (threadID == nil),
              state != .confirmed || messageID != nil else { throw GmailServerMailError.invalid }
    }
}

struct GmailServerMessage: Codable, Equatable {
    struct File: Codable, Equatable { let name: String; let mimeType: String; let data: Data }
    struct Reply: Codable, Equatable {
        let parentID: String; let threadID: String; let messageID: String; let subject: String; let references: [String]
    }
    let to: [String]
    let subject: String
    let body: String
    let attachments: [File]
    let reply: Reply?

    init(_ outgoing: GmailOutgoingMessage) throws {
        to = try GmailAddressList.parse(outgoing.to).map { $0.lowercased() }
        subject = outgoing.subject; body = outgoing.body
        attachments = outgoing.attachments.map { .init(name: $0.fileName, mimeType: $0.mimeType, data: $0.data) }
        if let original = outgoing.reply {
            guard let parent = original.parentID, GmailServerMail.validID(parent) else { throw GmailComposeError.header }
            reply = .init(parentID: parent, threadID: original.threadID, messageID: original.messageID,
                          subject: original.subject, references: original.references)
        } else { reply = nil }
    }
    func validate() throws {
        guard !to.isEmpty, to.count <= 100, Set(to).count == to.count,
              to.allSatisfy({ (try? GmailAddressList.parse($0)) == [$0] && $0 == $0.lowercased() &&
                  $0.split(separator: "@").last?.split(separator: ".").last.map {
                      (2...63).contains($0.utf8.count) && $0.utf8.allSatisfy { (97...122).contains($0) }
                  } == true }),
              body.utf8.count <= 2 * 1024 * 1024,
              !body.unicodeScalars.contains(where: { ($0.value < 32 && ![9, 10, 13].contains($0.value)) || $0.value == 127 }),
              attachments.allSatisfy({ file in
                  file.name.utf8.count <= 255 && ![".", ".."].contains(file.name) &&
                  !file.name.contains("/") && !file.name.contains("\\") &&
                  file.mimeType.range(of: #"^[A-Za-z0-9!#$&^_.+-]+/[A-Za-z0-9!#$&^_.+-]+$"#, options: .regularExpression) != nil
              }) else { throw GmailServerMailError.invalid }
        _ = try GmailOutgoingMessage(to: to.joined(separator: ", "), subject: subject, body: body,
            attachments: attachments.map { .init(fileName: $0.name, mimeType: $0.mimeType, data: $0.data) })
        if let reply {
            guard GmailServerMail.validID(reply.parentID), GmailServerMail.validID(reply.threadID),
                  GmailReplyContext.isValidMessageID(reply.messageID), reply.subject == subject,
                  reply.references.count <= 50, reply.references.allSatisfy(GmailReplyContext.isValidMessageID)
            else { throw GmailServerMailError.invalid }
        }
    }
}

struct GmailServerActionRecord: Codable, Equatable {
    let id: UUID
    let messageID: String
    let threadID: String
    let action: GmailMailboxAction
}

struct GmailServerActionStore {
    var read: (GmailServerScope) throws -> [GmailServerActionRecord]
    var replace: (GmailServerScope, [GmailServerActionRecord], [GmailServerActionRecord]) throws -> Void
    static var device: Self {
        .init(read: { try KeychainStore.loadCodable([GmailServerActionRecord].self, account: $0.storageKey) ?? [] },
              replace: { scope, expected, next in
            guard (try KeychainStore.loadCodable([GmailServerActionRecord].self, account: scope.storageKey) ?? []) == expected
            else { throw GmailServerMailError.pending }
            try KeychainStore.saveCodable(next, account: scope.storageKey)
        })
    }
}

/// One original company/login/grant. Children inherit this capability, not a
/// device Google token. Neither an error nor a refreshed page adopts a new grant.
@MainActor final class GmailServerMail {
    typealias Request = (String, String, Data?, Int) async throws -> Data
    let scope: GmailServerScope
    private let checkAccess: () throws -> Void
    private let transport: Request
    private let store: GmailServerActionStore
    private var revoked = false

    init(scope: GmailServerScope, store: GmailServerActionStore? = nil,
         check: @escaping () throws -> Void, request: @escaping Request) throws {
        try scope.company.validate(); try check()
        self.scope = scope; self.store = store ?? .device; checkAccess = check; transport = request
    }
    static func capture(context: ModelContext) async throws -> WorkspaceProviderOperation {
        let dependencies = try GoogleServerConnectionDependencies.live(context: context)
        func check() throws {
            try dependencies.check()
            try GmailSendWorkflow.requireAccess(context: context, business: nil, sender: dependencies.scope.actorEmail)
        }
        try check()
        let data = try await dependencies.request("/api/google/connection?companyID=" + dependencies.scope.companyID.uuidString.lowercased(), "GET", nil)
        try check()
        let snapshot = try JSONDecoder().decode(GoogleServerSnapshot.self, from: data)
        try snapshot.validate(scope: dependencies.scope)
        guard snapshot.state == .active, snapshot.features.contains(.mail), let grant = snapshot.id else { throw GmailServerMailError.connect }
        let client = try Self(scope: .init(company: dependencies.scope, grantID: grant), check: check,
            request: { try await GunnAireBackendService.googleMailRequest(path: $0, method: $1, body: $2, maximum: $3) })
        let operation = WorkspaceProviderOperation(serverMail: client) { (try? client.check()) != nil }
        try operation.check()
        return operation
    }
    func check() throws {
        guard !revoked else { throw GmailServerMailError.access }
        try checkAccess(); try Task.checkCancellation()
    }
    static func validID(_ id: String) -> Bool {
        (1...2048).contains(id.utf8.count) && id.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
    private func endpoint(_ resource: String, query: [URLQueryItem] = []) throws -> String {
        var url = URLComponents()
        url.path = "/api/google/mail/" + resource
        url.queryItems = [.init(name: "companyID", value: scope.company.companyID.uuidString.lowercased()),
                          .init(name: "grantID", value: scope.grantID.uuidString.lowercased())] + query
        guard let path = url.string else { throw GmailServerMailError.invalid }; return path
    }
    private func request<T: Decodable>(_ type: T.Type, resource: String, operation: WorkspaceProviderOperation,
                                      body: [String: Any]? = nil, query: [URLQueryItem] = [], maximum: Int = 68 * 1024 * 1024) async throws -> T {
        try check(); try operation.check()
        let path: String, payload: Data?
        if var body {
            body["companyID"] = scope.company.companyID.uuidString.lowercased(); body["grantID"] = scope.grantID.uuidString.lowercased()
            payload = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            guard payload!.count <= 48 * 1024 * 1024 else { throw GmailServerMailError.invalid }
            path = "/api/google/mail/" + resource
        } else { payload = nil; path = try endpoint(resource, query: query) }
        do {
            let data: Data
            if payload != nil {
                data = try await operation.performExternalMutation { try await transport(path, "POST", payload, maximum) }
            } else { data = try await transport(path, "GET", nil, maximum) }
            try check(); try operation.check()
            guard data.count <= maximum else { throw GmailServerMailError.invalid }
            let decoder = JSONDecoder()
            // Backend messages use base64url; Foundation's Data decoder only
            // accepts standard base64. Validate characters before normalization.
            decoder.dataDecodingStrategy = .custom { decoder in
                let value = try decoder.singleValueContainer().decode(String.self)
                guard value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [43, 47, 45, 95, 61].contains($0) }) else { throw GmailServerMailError.invalid }
                var normalized = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
                guard let data = Data(base64Encoded: normalized) else { throw GmailServerMailError.invalid }; return data
            }
            try decoder.decode(GmailServerStamp.self, from: data).validate(scope)
            return try decoder.decode(type, from: data)
        } catch {
            try check(); try operation.check()
            if case GunnAireBackendError.server(let code, _) = error, code == 401 || code == 403 { revoked = true }
            throw GmailServerMailError.safe(error)
        }
    }
    private struct Page: Decodable { let messages: [GmailMessageDetail]; let nextPageToken: String? }
    private struct Message: Decodable { let message: GmailMessageDetail }
    private struct Attachment: Decodable { let messageID: String; let attachmentID: String; let body: GmailMessageBody }
    private struct Saved: Decodable { let id: UUID; let kind: String; let message: GmailServerMessage }

    func page(folder: GmailMailboxFolder, query: String, pageToken: String?, maximum: Int,
              operation: WorkspaceProviderOperation) async throws -> GmailMailboxPage {
        guard (1...50).contains(maximum), query.utf8.count <= 8192,
              !query.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              GmailMailboxPage.validToken(pageToken) else { throw GmailServerMailError.invalid }
        var items = [URLQueryItem(name: "folder", value: folder.rawValue), .init(name: "maxResults", value: String(maximum))]
        if !query.isEmpty { items.append(.init(name: "query", value: query)) }
        if let pageToken { items.append(.init(name: "pageToken", value: pageToken)) }
        let page = try await request(Page.self, resource: "messages", operation: operation, query: items, maximum: 8 * 1024 * 1024)
        guard page.messages.count <= maximum, Set(page.messages.map(\.id)).count == page.messages.count,
              GmailMailboxPage.validToken(page.nextPageToken), pageToken == nil || pageToken != page.nextPageToken else { throw GmailServerMailError.invalid }
        for message in page.messages { try validate(message) }
        return .init(messages: page.messages, nextPageToken: page.nextPageToken)
    }
    private func validate(_ message: GmailMessageDetail, id: String? = nil, thread: String? = nil) throws {
        guard Self.validID(message.id), let threadID = message.threadId, Self.validID(threadID),
              id == nil || id == message.id, thread == nil || thread == threadID,
              let labels = message.labelIds, labels.count <= 100, Set(labels).count == labels.count,
              labels.allSatisfy(Self.validID) else { throw GmailServerMailError.invalid }
    }
    func message(id: String, operation: WorkspaceProviderOperation) async throws -> GmailMessageDetail {
        guard Self.validID(id) else { throw GmailServerMailError.invalid }
        let result = try await request(Message.self, resource: "messages/" + id, operation: operation)
        try validate(result.message, id: id); return result.message
    }
    func attachment(messageID: String, attachmentID: String, operation: WorkspaceProviderOperation) async throws -> GmailMessageBody {
        guard Self.validID(messageID), Self.validID(attachmentID) else { throw GmailServerMailError.invalid }
        let result = try await request(Attachment.self, resource: "messages/" + messageID + "/attachments/" + attachmentID, operation: operation, maximum: 34 * 1024 * 1024)
        guard result.messageID == messageID, result.attachmentID == attachmentID else { throw GmailServerMailError.invalid }
        return result.body // GmailAttachmentLoader verifies advertised size and exact bytes.
    }
    private func actions() throws -> [GmailServerActionRecord] {
        try check()
        let values = try store.read(scope)
        guard values.count <= 128, Set(values.map(\.id)).count == values.count,
              Set(values.map(\.messageID)).count == values.count,
              values.allSatisfy({ Self.validID($0.messageID) && Self.validID($0.threadID) }) else { throw GmailServerMailError.storage }
        return values
    }
    private func remove(_ record: GmailServerActionRecord) throws {
        let current = try actions()
        guard current.contains(record) else { throw GmailServerMailError.pending }
        try store.replace(scope, current, current.filter { $0.id != record.id })
    }
    func change(id: String, threadID: String?, action: GmailMailboxAction, operation: WorkspaceProviderOperation) async throws -> GmailMessageDetail {
        guard Self.validID(id), let threadID, Self.validID(threadID) else { throw GmailServerMailError.invalid }
        let current = try actions()
        let record: GmailServerActionRecord
        if let original = current.first(where: { $0.messageID == id }) {
            guard original.threadID == threadID, original.action == action else { throw GmailServerMailError.pending }
            record = original
        } else {
            guard current.count < 128 else { throw GmailServerMailError.storage }
            record = .init(id: UUID(), messageID: id, threadID: threadID, action: action)
            try store.replace(scope, current, current + [record])
        }
        // Explicit repeats reuse the original server claim. They never create a
        // new operation after an uncertain reply, including across app restarts.
        let data: ActionReply = try await request(ActionReply.self, resource: "messages/" + id + "/actions", operation: operation,
            body: ["id": record.id.uuidString.lowercased(), "threadID": threadID, "action": action.rawValue])
        let message = try confirm(data, record: record)
        try remove(record)
        return message
    }
    private struct ActionReply: Decodable {
        let id: UUID; let kind: String; let state: GmailServerOperationState; let message: GmailMessageDetail?
    }
    private func confirm(_ response: ActionReply, record: GmailServerActionRecord) throws -> GmailMessageDetail {
        guard response.id == record.id, response.kind == "action", response.state == .confirmed, let message = response.message,
              record.action.confirmed(by: message) else { throw GmailServerMailError.pending }
        try validate(message, id: record.messageID, thread: record.threadID); return message
    }
    func recoverActions(operation: WorkspaceProviderOperation) async throws -> Int {
        for record in try actions() {
            do {
                let result = try await request(ActionReply.self, resource: "operations/" + record.id.uuidString.lowercased() + "/recovery", operation: operation)
                _ = try confirm(result, record: record); try remove(record)
            } catch { try check(); try operation.check() }
        }
        return try actions().count
    }
    func operation(id: UUID, recovery: Bool = false, operation: WorkspaceProviderOperation) async throws -> GmailServerOperation {
        let result = try await request(GmailServerOperation.self, resource: "operations/" + id.uuidString.lowercased() + (recovery ? "/recovery" : ""), operation: operation, maximum: 65536)
        try result.validate(id: id, kind: "send"); return result
    }
    func savedMessage(id: UUID, operation: WorkspaceProviderOperation) async throws -> GmailServerMessage {
        let result = try await request(Saved.self, resource: "operations/" + id.uuidString.lowercased() + "/message", operation: operation)
        guard result.id == id, result.kind == "send" else { throw GmailServerMailError.invalid }
        try result.message.validate(); return result.message
    }
    func send(id: UUID, message: GmailServerMessage, operation: WorkspaceProviderOperation) async throws -> GmailServerOperation {
        try message.validate()
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(message))
        let prepared = try await request(GmailServerOperation.self, resource: "outbox", operation: operation,
                                        body: ["id": id.uuidString.lowercased(), "message": encoded], maximum: 65536)
        try prepared.validate(id: id, kind: "send")
        guard prepared.state == .prepared else { return prepared }
        let sent = try await request(GmailServerOperation.self, resource: "operations/" + id.uuidString.lowercased() + "/send", operation: operation, body: [:], maximum: 65536)
        try sent.validate(id: id, kind: "send"); return sent
    }
    func cancel(id: UUID, operation: WorkspaceProviderOperation) async throws -> GmailServerOperation {
        let result = try await request(GmailServerOperation.self, resource: "operations/" + id.uuidString.lowercased() + "/cancel", operation: operation, body: [:], maximum: 65536)
        try result.validate(id: id, kind: "send"); return result
    }
    struct OutboxItem: Decodable, Identifiable {
        struct Summary: Decodable { let to: [String]; let subject: String; let attachmentNames: [String] }
        let id: UUID; let state: GmailServerOperationState; let createdAt: String; let summary: Summary
    }
    struct OutboxPage: Decodable { let operations: [OutboxItem]; let nextPageToken: String? }
    func outbox(pageToken: String? = nil, operation: WorkspaceProviderOperation) async throws -> OutboxPage {
        guard GmailMailboxPage.validToken(pageToken) else { throw GmailServerMailError.invalid }
        let result = try await request(OutboxPage.self, resource: "outbox", operation: operation,
            query: pageToken.map { [.init(name: "pageToken", value: $0)] } ?? [], maximum: 2 * 1024 * 1024)
        guard result.operations.count <= 25, Set(result.operations.map(\.id)).count == result.operations.count,
              GmailMailboxPage.validToken(result.nextPageToken), pageToken == nil || pageToken != result.nextPageToken else { throw GmailServerMailError.invalid }
        for item in result.operations {
            guard !item.summary.to.isEmpty, item.summary.to.count <= 100,
                  item.summary.to.allSatisfy({ (try? GmailAddressList.parse($0)) == [$0] }),
                  item.summary.subject.utf8.count <= 900, item.summary.attachmentNames.count <= 50,
                  item.summary.attachmentNames.allSatisfy({ $0.utf8.count <= 255 }),
                  item.createdAt.utf8.count <= 64 else { throw GmailServerMailError.invalid }
        }
        return result
    }
}
