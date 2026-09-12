import Foundation
import SwiftData

/// Test-only business transport. No provider, token or network is reachable.
/// Release builds always return nil and use the real authorized business client.
@MainActor enum SharedTimeUIFixture {
    struct Services { let access: SharedTimeAccess; let client: SharedTimeClient; let store: SharedTimeLocalStore }

    static func seedIfRequested(in context: ModelContext) throws {
        #if DEBUG
        guard enabled else { return }
        let id = try fixtureID()
        let entries = try context.fetch(FetchDescriptor<TimeEntry>())
        for entry in entries where entry.userEmail == email && entry.id != id { context.delete(entry) }
        if !entries.contains(where: { $0.id == id }) {
            let now = Date()
            context.insert(TimeEntry(id: id, userEmail: email, clockIn: now.addingTimeInterval(-4 * 3600),
                clockOut: now.addingTimeInterval(-2 * 3600), notes: "Reviewed heat-pump service training.", activity: .training,
                reviewStatus: .approved, reviewedByEmail: AppIdentity.currentEmail ?? AppAccess.primaryAdminEmail,
                reviewedAt: now.addingTimeInterval(-3600)))
        }
        if !(try context.fetch(FetchDescriptor<Technician>())).contains(where: { $0.contactInfo == email }) {
            context.insert(Technician(name: "Shared Time Technician", contactInfo: email))
        }
        if !(try context.fetch(FetchDescriptor<AppUser>())).contains(where: { $0.email == email }) {
            context.insert(AppUser(email: email, role: .fieldTechnician))
        }
        try context.save()
        #endif
    }

    static func services(context: ModelContext, workerEmail: String, administrator: Bool = false,
                         isCurrent: @escaping () -> Bool) throws -> Services? {
        #if DEBUG
        guard enabled else { return nil }
        let company = try fixtureID()
        let access = try SharedTimeAccess(context: context, administrator: administrator, isCurrent: isCurrent, fixtureCompanyID: company)
        let server = Server(company: company, actor: access.actorEmail, workerEmail: workerEmail)
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("UITestSharedTime-" + company.uuidString)
        return Services(access: access, client: .init { try server.request($0, method: $1, body: $2) },
            store: .encrypted(directory: directory, key: { _ in Data(repeating: 17, count: 32) }))
        #else
        return nil
        #endif
    }

    #if DEBUG
    private static let email = "shared-time@example.invalid"
    private static var enabled: Bool {
        GunnAireCloudKit.usesTestDatabase && ProcessInfo.processInfo.arguments.contains("-uiTestSharedTime")
    }
    private static func fixtureID() throws -> UUID {
        guard let raw = ProcessInfo.processInfo.environment["GUNNAIRE_TIME_FIXTURE"], let id = UUID(uuidString: raw) else { throw SharedTimeError.invalid }
        return id
    }
    private final class Server {
        let company: UUID
        let actor: String
        let workerEmail: String
        let realm = "fixture-time-realm"
        let epoch = String(repeating: "a", count: 64)
        var key: String { "UITestSharedTimeServer-" + company.uuidString }
        init(company: UUID, actor: String, workerEmail: String) { self.company = company; self.actor = actor; self.workerEmail = workerEmail }
        func mapping(revision: Int = 1, providerID: String = "55", kind: String = "Employee", enabled: Bool = true) -> [String: Any] {
            ["companyID": company.uuidString, "realmID": realm, "environment": "sandbox", "workerEmail": workerEmail,
             "revision": revision, "kind": kind, "providerID": providerID, "displayName": "Alex QuickBooks",
             "referenceRevision": String(repeating: "b", count: 64), "enabled": enabled, "usable": enabled,
             "updatedAt": "2026-09-09T00:00:00Z"]
        }
        func request(_ path: String, method: String, body: Data?) throws -> Data {
            guard enabled, let url = URLComponents(string: path) else { throw SharedTimeError.invalid }
            var state = try UserDefaults.standard.data(forKey: key).map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] } ?? [:]
            let input = try body.map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] } ?? [:]
            let worker = state["worker"] as? [String: Any] ??
                (ProcessInfo.processInfo.arguments.contains("-uiTestTimeWorkerMissing") ? nil : mapping())
            var result: [String: Any]
            if url.path == "/api/time-worker-mappings", method == "POST" {
                let request = try JSONDecoder().decode(SharedTimeWorkerRequest.self, from: body!)
                guard request.expectedRevision == (worker?["revision"] as? Int ?? 0) else { throw SharedTimeError.review }
                let saved = mapping(revision: request.expectedRevision + 1, providerID: request.providerID, kind: request.kind, enabled: request.enabled)
                state["worker"] = saved
                result = ["mapping": saved, "operationID": request.operationID.uuidString, "replayed": false]
            } else if url.path.hasPrefix("/api/time-worker-mappings") {
                result = ["companyID": company.uuidString, "realmID": realm, "environment": "sandbox", "workerEmail": workerEmail,
                    "connectionRevision": epoch, "protocolVersion": 1, "mapping": worker ?? NSNull()]
                if url.path.hasSuffix("/candidate") {
                    result["candidate"] = ["kind": url.queryItems!.first { $0.name == "kind" }!.value!,
                        "providerID": url.queryItems!.first { $0.name == "providerID" }!.value!,
                        "displayName": "Alex QuickBooks", "referenceRevision": String(repeating: "b", count: 64)]
                }
            } else if method == "GET" {
                result = ["publications": state["publication"].map { [$0] } ?? []]
            } else if url.path == "/api/time-publications" {
                guard let worker else { throw SharedTimeError.mapping }
                if state["publication"] == nil || (state["publication"] as? [String: Any])?["state"] as? String == "cancelled" {
                    let request = try JSONDecoder().decode(SharedTimeRequest.self, from: body!)
                    let id = UUID(), now = Date()
                    let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
                    formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: request.timeZone); formatter.dateFormat = "yyyy-MM-dd"
                    var document: [String: Any] = ["TxnDate": formatter.string(from: SharedTimeError.date(request.clockIn)!),
                        "NameOf": worker["kind"]!, "\(worker["kind"]!)Ref": ["value": worker["providerID"]!],
                        "Hours": request.payableMinutes / 60, "Minutes": request.payableMinutes % 60,
                        "Description": ["Activity: " + TimeEntryActivity(rawValue: request.activity)!.displayName, request.notes,
                            "Clocked " + request.clockIn + " - " + request.clockOut,
                            "GUNNAIRE-TIME:" + request.localEntryID.uuidString, "GUNNAIRE-TIME-PUBLICATION:" + id.uuidString]
                            .filter { !$0.isEmpty }.joined(separator: "\n")]
                    if request.localCustomerID != nil { document["CustomerRef"] = ["value": "C55"] }
                    if request.localItemID != nil { document["ItemRef"] = ["value": "I55"] }
                    state["publication"] = ["id": id.uuidString, "companyID": company.uuidString, "realmID": realm,
                        "environment": "sandbox", "localEntryID": request.localEntryID.uuidString, "workerEmail": workerEmail,
                        "state": "reserved", "entryRevision": request.entryRevision, "reviewHash": String(repeating: "d", count: 64),
                        "preparedByEmail": actor, "review": input, "worker": worker, "timeActivity": document,
                        "createdAt": SharedTimeError.instant(now), "updatedAt": SharedTimeError.instant(now),
                        "expiresAt": SharedTimeError.instant(now.addingTimeInterval(900))]
                }
                result = ["publication": state["publication"]!]
            } else {
                guard var publication = state["publication"] as? [String: Any],
                      url.path.contains((publication["id"] as! String).lowercased()) else { throw SharedTimeError.invalid }
                if url.path.hasSuffix("/confirm"), publication["state"] as? String == "reserved" {
                    state["dispatches"] = (state["dispatches"] as? Int ?? 0) + 1
                    publication["state"] = "unknown"
                    state["publication"] = publication
                    try save(state)
                    if ProcessInfo.processInfo.arguments.contains("-uiTestTimeLostReply") { throw URLError(.networkConnectionLost) }
                }
                if url.path.hasSuffix("/cancel") {
                    guard publication["state"] as? String == "reserved" else { throw SharedTimeError.review }
                    publication["state"] = "cancelled"
                } else if (url.path.hasSuffix("/recover") || url.path.hasSuffix("/confirm")), publication["state"] as? String == "unknown" {
                    publication["state"] = "confirmed"
                    publication["receipt"] = ["providerID": "fixture-time-55", "syncToken": "0",
                        "confirmedAt": SharedTimeError.instant(Date()), "legacyAdoption": false]
                }
                state["publication"] = publication; result = ["publication": publication]
            }
            try save(state)
            return try JSONSerialization.data(withJSONObject: result)
        }
        func save(_ value: [String: Any]) throws { UserDefaults.standard.set(try JSONSerialization.data(withJSONObject: value), forKey: key) }
    }
    #endif
}
