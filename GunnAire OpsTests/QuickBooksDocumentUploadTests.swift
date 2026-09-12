import Foundation
import Testing
@testable import GunnAire_Ops

@MainActor struct QuickBooksDocumentUploadTests {
    let company = UUID(), operation = UUID(), upload = UUID()
    let bytes = Data("Original service findings".utf8)
    var scope: QBODocumentScope { .init(companyID: company, realmID: "realm", environment: "sandbox") }
    var targets: [QBODocumentTarget] { [.init(type: "Invoice", id: "D1")] }
    var file: QBODocumentFileInfo { get throws { try .init(filename: "Service.txt", contentType: "text/plain", data: bytes) } }
    func record(_ state: String = "reserved", changes: [String: Any] = [:]) throws -> [String: Any] {
        let info = try JSONSerialization.jsonObject(with: JSONEncoder().encode(file))
        var value: [String: Any] = ["protocolVersion": 1, "id": upload.uuidString, "companyID": company.uuidString,
            "realmID": "realm", "environment": "sandbox", "operationID": operation.uuidString,
            "revision": String(repeating: "a", count: 64), "state": state, "file": info,
            "targets": [["type": "Invoice", "id": "D1"]], "jobDocument": NSNull(),
            "providerID": state == "confirmed" ? "A1" : NSNull(), "createdAt": "2026-09-08T12:00:00Z",
            "updatedAt": "2026-09-08T12:00:01Z", "connectionChanged": false]
        value.merge(changes) { _, new in new }; return value
    }
    func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    func decoded(_ state: String = "reserved", changes: [String: Any] = [:]) throws -> QBODocumentUploadRecord {
        try JSONDecoder().decode(QBODocumentUploadRecord.self, from: data(record(state, changes: changes)))
    }
    func request() -> QBODocumentUploadRequest {
        .init(companyID: company, realmID: "realm", environment: "sandbox", operationID: operation,
              connectionRevision: String(repeating: "b", count: 64),
              file: .init(filename: "Service.txt", contentType: "text/plain", data: bytes), targets: targets, jobDocument: nil)
    }

    @Test func reservationCarriesOriginalBytesAndNeverRequestsCustomerDelivery() async throws {
        var calls = 0
        let client = QBODocumentUploadClient(transport: { path, method, body in
            calls += 1
            #expect(path == "/api/qbo-document-uploads"); #expect(method == "POST")
            let encoded = try #require(body)
            let value = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            #expect(value["operationID"] as? String == operation.uuidString)
            #expect(Set(value.keys) == Set(["companyID", "realmID", "environment", "operationID", "connectionRevision", "file", "targets"]))
            let file = try #require(value["file"] as? [String: Any])
            #expect(file["data"] as? String == bytes.base64EncodedString())
            return try data(record())
        }, check: {})
        let result = try await client.reserve(request())
        #expect(result.id == upload); #expect(result.state == .reserved); #expect(calls == 1)
    }

    @Test func wrongCompanyFileTargetsAndRevisionCannotBecomeSuccessfulUpload() async throws {
        for change: [String: Any] in [["companyID": UUID().uuidString], ["targets": [["type": "Estimate", "id": "D1"]]],
                                     ["revision": "bad"], ["protocolVersion": 2], ["providerID": "unconfirmed"],
                                     ["updatedAt": "2026-09-08T11:00:00Z"], ["jobDocument": ["kind": "expense_receipt"]]] {
            let client = QBODocumentUploadClient(transport: { _, _, _ in try data(record(changes: change)) }, check: {})
            await #expect(throws: QBODocumentError.invalid) { try await client.reserve(request()) }
        }
    }

    @Test func recoveryCannotDowngradeUnknownOrReplaceOriginalIdentity() async throws {
        let original = try decoded("uncertain")
        for change: [String: Any] in [["id": UUID().uuidString], ["revision": String(repeating: "c", count: 64)],
                                     ["operationID": UUID().uuidString], ["state": "reserved", "providerID": NSNull()]] {
            let client = QBODocumentUploadClient(transport: { _, _, _ in try data(record("confirmed", changes: change)) }, check: {})
            await #expect(throws: QBODocumentError.invalid) { try await client.action(.recover, original: original) }
        }
    }

    @Test func uncertainOrReconnectedUploadNeverDispatchesAnotherSendOrCancel() async throws {
        var calls = 0
        let client = QBODocumentUploadClient(transport: { _, _, _ in calls += 1; return try data(record("confirmed")) }, check: {})
        for value in [try decoded("uncertain"), try decoded("sending"), try decoded("confirmed"),
                      try decoded(changes: ["connectionChanged": true])] {
            await #expect(throws: QBODocumentError.review) { try await client.action(.send, original: value) }
        }
        await #expect(throws: QBODocumentError.review) { try await client.action(.cancel, original: decoded("uncertain")) }
        #expect(calls == 0)
    }

    @Test func timeoutDoesNotAutomaticallyRepeatOrExposeProviderPayload() async throws {
        var calls = 0
        let client = QBODocumentUploadClient(transport: { _, _, _ in calls += 1; throw URLError(.timedOut) }, check: {})
        await #expect(throws: QBODocumentError.unavailable) { try await client.action(.send, original: decoded()) }
        #expect(calls == 1)
        let denied = QBODocumentUploadClient(transport: { _, _, _ in
            throw GunnAireBackendError.server(statusCode: 502, message: "private provider response")
        }, check: {})
        await #expect(throws: QBODocumentError.unavailable) { try await denied.reserve(request()) }
    }

    @Test func changedAccessDuringResponseInvalidatesOtherwiseSuccessfulResult() async throws {
        var active = true
        let client = QBODocumentUploadClient(transport: { _, _, _ in active = false; return try data(record("confirmed")) },
            check: { if !active { throw QBODocumentError.access } })
        await #expect(throws: QBODocumentError.access) { try await client.action(.send, original: decoded()) }
    }

    @Test func explicitOriginalFileDownloadChecksDigestAndAllOriginalMetadata() async throws {
        let original = try decoded("confirmed")
        let client = QBODocumentUploadClient(transport: { path, method, body in
            #expect(path == "/api/qbo-document-uploads/\(upload.uuidString.lowercased())/file")
            #expect(method == "GET"); #expect(body == nil)
            return try data(record("confirmed", changes: ["data": bytes.base64EncodedString()]))
        }, check: {})
        #expect(try await client.file(original) == bytes)
        let changed = QBODocumentUploadClient(transport: { _, _, _ in
            try data(record("confirmed", changes: ["data": Data("Other".utf8).base64EncodedString()]))
        }, check: {})
        await #expect(throws: QBODocumentError.invalid) { try await changed.file(original) }
    }

    @Test func unsafeOrOversizedFileAndDuplicateDestinationsAreRejectedBeforeTransport() throws {
        for name in ["../file.txt", "file\n.txt", "file\".txt", "file.exe", " file.txt"] {
            #expect(throws: QBODocumentError.file) { try QBODocumentFileInfo(filename: name, contentType: "text/plain", data: bytes) }
        }
        #expect(throws: QBODocumentError.file) { try QBODocumentFileInfo(filename: "file.txt", contentType: "text/plain", data: Data()) }
        #expect(throws: QBODocumentError.invalid) { try QBODocumentTarget.normalized(targets + targets) }
        #expect(throws: QBODocumentError.access) { try QBODocumentScope(companyID: company, realmID: "..", environment: "sandbox").validate() }
    }

    @Test func recoveryPageRequiresExactScopeProtocolAndCompletePagination() async throws {
        var value: [String: Any] = ["protocolVersion": 1, "maxFileBytes": QBODocumentFileInfo.maximum,
            "companyID": company.uuidString, "realmID": "realm", "environment": "sandbox",
            "connectionRevision": String(repeating: "b", count: 64), "uploads": [try record()], "nextCursor": NSNull()]
        var client = QBODocumentUploadClient(transport: { _, method, body in
            #expect(method == "GET"); #expect(body == nil); return try data(value)
        }, check: {})
        #expect(try await client.page(scope, operationID: operation).uploads.count == 1)
        value["nextCursor"] = UUID().uuidString
        client = .init(transport: { _, _, _ in try data(value) }, check: {})
        await #expect(throws: QBODocumentError.invalid) { try await client.page(scope) }
    }
}
