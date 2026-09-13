#if DEBUG
import Foundation

/// Synthetic transport only. It has no credentials, network or real mailbox;
/// the UI exercises the same service, journal and send coordinator as Release.
@MainActor enum GmailServerMailFixture {
    static var enabled: Bool { GunnAireCloudKit.usesTestDatabase && ProcessInfo.processInfo.arguments.contains("-uiTestServerMail") }
    private static let scope = GmailServerScope(company: .init(
        companyID: UUID(uuidString: "3BF63F8D-C536-4BC2-826B-EF5CA1B1C9DA")!,
        backendOrigin: "https://fixture.example.invalid", actorEmail: "mail-fixture@gunnaire.com"),
        grantID: UUID(uuidString: "769AD24B-E0C7-4435-81A1-11967470A5D9")!)
    private struct Record: Codable { let id: UUID; let message: GmailServerMessage; var state: GmailServerOperationState }
    private static var actions: [GmailServerActionRecord] = []
    private static var labels = ["INBOX"]
    private static var key: String {
        "NativeSharedMailFixture-" + (ProcessInfo.processInfo.environment["GUNNAIRE_MAIL_DRAFT_FIXTURE"] ?? "default")
    }
    private static func records() throws -> [Record] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return try JSONDecoder().decode([Record].self, from: data)
    }
    private static func save(_ records: [Record]) throws { UserDefaults.standard.set(try JSONEncoder().encode(records), forKey: key) }
    static func provider() throws -> WorkspaceProviderOperation {
        precondition(enabled)
        let store = GmailServerActionStore(read: { _ in actions }, replace: { _, expected, next in
            guard actions == expected else { throw GmailServerMailError.pending }; actions = next
        })
        let server = try GmailServerMail(scope: scope, store: store, check: {}, request: { path, method, body, _ in
            try request(path, method: method, body: body)
        })
        return WorkspaceProviderOperation(serverMail: server) { true }
    }
    private static func detail(_ record: Record? = nil) -> [String: Any] {
        let sent = record != nil
        var headers = [["name": "From", "value": sent ? scope.company.actorEmail : "Jordan Customer <jordan@example.invalid>"],
            ["name": "To", "value": record?.message.to.joined(separator: ", ") ?? scope.company.actorEmail],
            ["name": "Subject", "value": record?.message.subject ?? "Service appointment confirmed"],
            ["name": "Message-ID", "value": record.map { "<gunnaire-\($0.id.uuidString.lowercased())@gunnaire.com>" } ?? "<appointment@example.invalid>"]]
        if let reply = record?.message.reply { headers.append(["name": "References", "value": (reply.references + [reply.messageID]).joined(separator: " ")]) }
        let text = record?.message.body ?? "Your service visit is confirmed."
        return ["id": record.map { "sent-" + $0.id.uuidString.lowercased() } ?? "server-fixture-message",
            "threadId": "server-fixture-thread", "labelIds": sent ? ["SENT"] : labels, "snippet": text,
            "payload": ["headers": headers, "mimeType": "text/plain", "body": ["data": Data(text.utf8).base64EncodedString(), "size": text.utf8.count]]]
    }
    private static func outcome(_ record: Record) -> [String: Any] {
        var value: [String: Any] = ["id": record.id.uuidString, "kind": "send", "state": record.state.rawValue]
        if record.state == .confirmed { value["messageID"] = "sent-" + record.id.uuidString.lowercased(); value["threadID"] = "server-fixture-thread" }
        return value
    }
    private static func request(_ path: String, method: String, body: Data?) throws -> Data {
        let url = URLComponents(string: path)!
        let route = String(url.path.dropFirst("/api/google/mail/".count))
        let payload = try body.map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] } ?? [:]
        var all = try records(), value: [String: Any]
        if route == "messages" {
            let sent = url.queryItems?.contains { $0.name == "folder" && $0.value == "Sent" } == true
            value = ["messages": sent ? all.filter { $0.state == .confirmed }.map { detail($0) } : [detail()]]
        } else if route == "outbox", method == "POST" {
            let id = UUID(uuidString: payload["id"] as! String)!
            let message = try JSONDecoder().decode(GmailServerMessage.self, from: JSONSerialization.data(withJSONObject: payload["message"]!))
            if !all.contains(where: { $0.id == id }) { all.append(.init(id: id, message: message, state: .prepared)); try save(all) }
            value = outcome(all.first { $0.id == id }!)
        } else if route == "outbox" {
            value = ["operations": all.map { record in
                ["id": record.id.uuidString, "state": record.state.rawValue, "createdAt": "2026-09-07T12:00:00+00:00",
                 "summary": ["to": record.message.to, "subject": record.message.subject,
                             "attachmentNames": record.message.attachments.map(\.name)]] as [String: Any]
            }]
        } else if route.hasSuffix("/actions") {
            labels.removeAll { $0 == "UNREAD" }
            value = ["id": payload["id"]!, "kind": "action", "state": "confirmed", "message": detail()]
        } else if route.hasPrefix("messages/") {
            value = ["message": detail(all.first { route == "messages/sent-" + $0.id.uuidString.lowercased() })]
        } else {
            let id = UUID(uuidString: String(route.split(separator: "/")[1]))!
            guard let index = all.firstIndex(where: { $0.id == id }) else { throw GmailServerMailError.invalid }
            if route.hasSuffix("/send"), all[index].state == .prepared {
                all[index].state = .confirmed; try save(all)
                if ProcessInfo.processInfo.arguments.contains("-uiTestServerMailLostReply") { throw URLError(.networkConnectionLost) }
            }
            if route.hasSuffix("/cancel"), all[index].state == .prepared { all[index].state = .cancelled; try save(all) }
            value = outcome(all[index])
            if route.hasSuffix("/message") { value["message"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(all[index].message)) }
        }
        value["companyID"] = scope.company.companyID.uuidString; value["actorEmail"] = scope.company.actorEmail; value["grantID"] = scope.grantID.uuidString
        return try JSONSerialization.data(withJSONObject: value)
    }
}
#endif
