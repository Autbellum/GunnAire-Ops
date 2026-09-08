import Foundation
import CryptoKit
import SwiftData
import Testing
@testable import GunnAire_Ops

/// Isolated provider simulator; every file and response belongs to this test.
/// The production coordinator, encrypted journal and contract validation run
/// unchanged. There are no credentials or live network requests.
@MainActor final class QuickBooksDocumentWorkflowFixture {
    let root: URL
    let owner = QBODocumentOwner(companyID: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!,
        backendOrigin: "https://files.example.invalid", actorEmail: "office@example.invalid")
    var scope: QBODocumentScope { .init(companyID: owner.companyID, realmID: "billing-realm", environment: Config.QuickBooks.environment) }
    let secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    var store: QBODocumentCaptureStore { .encrypted(directory: root.appendingPathComponent("journal"), key: { _ in self.secret }) }
    var authorized = true
    var requests: [(path: String, method: String, body: Data?)] = []
    var remote: [String: Any]?
    var beforeResponse: ((String) throws -> Void)?
    var sends: Int { requests.filter { $0.path.hasSuffix("/send") }.count }
    var reservations: Int { requests.filter { $0.path == "/api/qbo-document-uploads" && $0.method == "POST" }.count }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeOriginalFileTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func check() throws { guard authorized else { throw QBODocumentError.access } }
    func access() throws -> QBODocumentNativeWorkflow.Access {
        try check()
        return .init(owner: owner, scope: scope, check: check)
    }
    func dependencies(check: @escaping () throws -> Void = {}) -> QBODocumentNativeWorkflow.Dependencies {
        .init(owner: { _ in try check(); try self.check(); return self.owner }, access: { _, _ in
            try check(); try self.check()
            return .init(owner: self.owner, scope: self.scope, check: { try check(); try self.check() })
        }, store: store, transport: request)
    }
    func file(_ name: String = "Service findings.txt", data: Data = Data("Original job findings".utf8)) throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }
    func request(_ path: String, _ method: String, _ body: Data?) async throws -> Data {
        requests.append((path, method, body))
        let route = try #require(URLComponents(string: path)).path
        var value: [String: Any]
        if route == "/api/qbo-document-uploads", method == "GET" {
            value = ["protocolVersion": 1, "maxFileBytes": QBODocumentFileInfo.maximum,
                "companyID": owner.companyID.uuidString, "realmID": scope.realmID, "environment": scope.environment,
                "connectionRevision": String(repeating: "b", count: 64), "uploads": remote.map { [$0] } ?? [], "nextCursor": NSNull()]
        } else if route == "/api/qbo-document-uploads", method == "POST" {
            let bytes = try #require(body)
            let request = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let file = try #require(request["file"] as? [String: Any])
            let encoded = try #require(file["data"] as? String)
            let original = try #require(Data(base64Encoded: encoded))
            let info = try QBODocumentFileInfo(filename: #require(file["filename"] as? String),
                contentType: #require(file["contentType"] as? String), data: original)
            value = ["protocolVersion": 1, "id": UUID().uuidString, "companyID": owner.companyID.uuidString,
                "realmID": scope.realmID, "environment": scope.environment, "operationID": request["operationID"]!,
                "revision": String(repeating: "a", count: 64), "state": "reserved", "providerID": NSNull(),
                "file": try JSONSerialization.jsonObject(with: JSONEncoder().encode(info)), "targets": request["targets"]!,
                "jobDocument": request["jobDocument"] ?? NSNull(), "createdAt": "2026-09-08T12:00:00Z",
                "updatedAt": "2026-09-08T12:00:01Z", "connectionChanged": false]
            remote = value
        } else {
            value = try #require(remote)
            if route.hasSuffix("/send") {
                #expect(value["state"] as? String == "reserved")
                value["state"] = "confirmed"; value["providerID"] = "A1"
            } else if route.hasSuffix("/cancel") { value["state"] = "cancelled" }
            else { #expect(route.hasSuffix("/recover")) }
            remote = value
        }
        try beforeResponse?(path)
        return try JSONSerialization.data(withJSONObject: value)
    }
}
