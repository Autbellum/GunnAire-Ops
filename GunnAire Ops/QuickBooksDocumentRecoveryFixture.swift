#if DEBUG
import Foundation

/// Synthetic provider only, excluded from Release. The real recovery view,
/// coordinator, validation and encrypted on-disk journal survive app relaunch.
@MainActor enum QBODocumentRecoveryFixture {
    static var enabled: Bool {
        GunnAireCloudKit.usesTestDatabase && ProcessInfo.processInfo.arguments.contains("-uiTestOriginalFiles") &&
        UUID(uuidString: ProcessInfo.processInfo.environment["GUNNAIRE_ORIGINAL_FILE_FIXTURE"] ?? "") != nil
    }
    static let owner = QBODocumentOwner(companyID: UUID(uuidString: "D1000000-0000-4000-8000-000000000001")!,
        backendOrigin: "https://original-files.example.invalid", actorEmail: "office@example.invalid")
    static let scope = QBODocumentScope(companyID: owner.companyID, realmID: "fixture-realm", environment: "sandbox")
    static let localID = UUID(uuidString: "D1000000-0000-4000-8000-000000000002")!
    static let serverID = UUID(uuidString: "D1000000-0000-4000-8000-000000000003")!
    static var key: String { "OriginalFilesFixture-" + (ProcessInfo.processInfo.environment["GUNNAIRE_ORIGINAL_FILE_FIXTURE"] ?? "invalid") }
    static var store: QBODocumentCaptureStore {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return .encrypted(directory: root.appendingPathComponent(key)) { _ in Data(repeating: 71, count: 32) }
    }
    static func check() throws {
        guard enabled, !ProcessInfo.processInfo.arguments.contains("-uiTestOriginalFilesDenied") else { throw QBODocumentError.access }
    }
    static var dependencies: QBODocumentNativeWorkflow.Dependencies {
        precondition(enabled)
        return .init(owner: { _ in try check(); try seed(); return owner }, access: { _, _ in
            try check(); return .init(owner: owner, scope: scope, check: check)
        }, store: store, transport: request)
    }
    static func seed() throws {
        if ProcessInfo.processInfo.arguments.contains("-uiTestSharedOriginalFiles") { return }
        guard try store.read(owner, localID) == nil else { return }
        let data = Data("Original service report. Equipment checked; customer findings retained.".utf8)
        let row = QBODocumentCapture(id: localID, owner: owner, scope: scope,
            file: try .init(filename: "Service report.txt", contentType: "text/plain", data: data),
            targets: [.init(type: "Invoice", id: "original-invoice")], jobDocument: nil, createdAt: Date())
        try store.write(row, nil, data)
    }
    static func request(_ path: String, _ method: String, _ body: Data?) async throws -> Data {
        try check()
        if ProcessInfo.processInfo.arguments.contains("-uiTestSharedOriginalFiles") { return try sharedRequest(path, method) }
        guard let row = try store.read(owner, localID), let route = URLComponents(string: path)?.path else { throw QBODocumentError.invalid }
        let data = UserDefaults.standard.data(forKey: key)
        var remote = try data.map { try JSONDecoder().decode(QBODocumentUploadRecord.self, from: $0) }
        if route == "/api/qbo-document-uploads", method == "GET" {
            let rows = try remote.map { [try JSONSerialization.jsonObject(with: JSONEncoder().encode($0))] } ?? []
            return try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "maxFileBytes": QBODocumentFileInfo.maximum,
                "companyID": owner.companyID.uuidString, "realmID": scope.realmID, "environment": scope.environment,
                "connectionRevision": String(repeating: "b", count: 64), "uploads": rows, "nextCursor": NSNull()])
        }
        if route == "/api/qbo-document-uploads", method == "POST", remote == nil {
            guard let body, let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                  payload["operationID"] as? String == row.id.uuidString,
                  let file = payload["file"] as? [String: Any], let encoded = file["data"] as? String,
                  let bytes = Data(base64Encoded: encoded) else { throw QBODocumentError.invalid }
            try row.file.verify(bytes)
            remote = .init(protocolVersion: 1, id: serverID, companyID: owner.companyID, realmID: scope.realmID,
                environment: scope.environment, operationID: row.id, revision: String(repeating: "a", count: 64),
                state: .reserved, providerID: nil, file: row.file, targets: row.targets, jobDocument: nil,
                createdAt: "2026-09-08T12:00:00Z", updatedAt: "2026-09-08T12:00:01Z", connectionChanged: false)
        } else if route.hasSuffix("/send") || route.hasSuffix("/cancel") {
            guard let old = remote, old.state == .reserved, method == "POST" else { throw QBODocumentError.review }
            let sent = route.hasSuffix("/send")
            remote = .init(protocolVersion: old.protocolVersion, id: old.id, companyID: old.companyID, realmID: old.realmID,
                environment: old.environment, operationID: old.operationID, revision: old.revision,
                state: sent ? .confirmed : .cancelled, providerID: sent ? "original-provider-file" : nil,
                file: old.file, targets: old.targets, jobDocument: old.jobDocument,
                createdAt: old.createdAt, updatedAt: old.updatedAt, connectionChanged: false)
        } else if !route.hasSuffix("/recover") { throw QBODocumentError.invalid }
        guard let remote else { throw QBODocumentError.invalid }
        let result = try JSONEncoder().encode(remote)
        UserDefaults.standard.set(result, forKey: key)
        if route.hasSuffix("/send"), ProcessInfo.processInfo.arguments.contains("-uiTestOriginalFilesLostReply") {
            throw URLError(.networkConnectionLost)
        }
        return result
    }

    private static func sharedRequest(_ path: String, _ method: String) throws -> Data {
        if ProcessInfo.processInfo.arguments.contains("-uiTestSharedOriginalFilesOffline") { throw URLError(.notConnectedToInternet) }
        let route = URLComponents(string: path)?.path
        let original = Data("Shared original from the first device. No replacement upload.".utf8)
        let row = QBODocumentUploadRecord(protocolVersion: 1, id: serverID, companyID: owner.companyID,
            realmID: scope.realmID, environment: scope.environment, operationID: localID,
            revision: String(repeating: "a", count: 64), state: .confirmed, providerID: "shared-original-file",
            file: try .init(filename: "Shared service report.txt", contentType: "text/plain", data: original),
            targets: [.init(type: "Invoice", id: "original-invoice")], jobDocument: nil,
            createdAt: "2026-09-08T12:00:00Z", updatedAt: "2026-09-08T12:00:01Z", connectionChanged: false)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as! [String: Any]
        if route == "/api/qbo-document-uploads", method == "GET" {
            object = ["protocolVersion": 1, "maxFileBytes": QBODocumentFileInfo.maximum,
                "companyID": owner.companyID.uuidString, "realmID": scope.realmID, "environment": scope.environment,
                "connectionRevision": String(repeating: "b", count: 64), "uploads": [object], "nextCursor": NSNull()]
        } else if route == "/api/qbo-document-uploads/" + serverID.uuidString.lowercased() + "/file", method == "GET" {
            object["data"] = original.base64EncodedString()
        } else if route == "/api/qbo-document-uploads/" + serverID.uuidString.lowercased(), method == "GET" {
            // Metadata read retains the first device's original identity.
        } else if route == "/api/qbo-document-uploads/" + serverID.uuidString.lowercased() + "/recover", method == "POST" {
            // Read-only provider recovery; never allow reserve/send in this fixture.
        } else { throw QBODocumentError.invalid }
        return try JSONSerialization.data(withJSONObject: object)
    }
}
#endif
