import Foundation
import CryptoKit
import Testing
@testable import GunnAire_Ops

@MainActor struct QuickBooksDocumentJournalTests {
    let owner = QBODocumentOwner(companyID: UUID(), backendOrigin: "https://files.example.invalid", actorEmail: "office@example.invalid")
    let data = Data("Keep these original service findings".utf8)
    func capture() throws -> QBODocumentCapture {
        .init(id: UUID(), owner: owner, scope: .init(companyID: owner.companyID, realmID: "realm", environment: "sandbox"),
              file: try .init(filename: "Findings.txt", contentType: "text/plain", data: data),
              targets: [.init(type: "Invoice", id: "D1")], jobDocument: nil, createdAt: Date())
    }
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("QBOFileJournalTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    func key() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }
    func serialized(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    func server(_ row: QBODocumentCapture, id: UUID, state: String = "reserved") throws -> [String: Any] {
        ["protocolVersion": 1, "id": id.uuidString, "companyID": owner.companyID.uuidString, "realmID": "realm", "environment": "sandbox",
         "operationID": row.id.uuidString, "revision": String(repeating: "a", count: 64), "state": state,
         "providerID": state == "confirmed" ? "A1" : NSNull(),
         "file": try JSONSerialization.jsonObject(with: JSONEncoder().encode(row.file)),
         "targets": [["type": "Invoice", "id": "D1"]], "jobDocument": NSNull(), "connectionChanged": false,
         "createdAt": "2026-09-08T12:00:00Z", "updatedAt": "2026-09-08T12:00:01Z"]
    }

    @Test func encryptedFileAndMetadataSurviveNewStoreWithoutPlaintextOrRawPaths() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let secret = key(), row = try capture()
        let store = QBODocumentCaptureStore.encrypted(directory: root, key: { _ in secret })
        try store.write(row, nil, data)
        let reopened = QBODocumentCaptureStore.encrypted(directory: root, key: { _ in secret })
        #expect(try reopened.read(owner, row.id) == row)
        #expect(try reopened.bytes(owner, row.id) == data)
        #expect(try reopened.list(owner) == [row])
        let url = root.appendingPathComponent(owner.storageKey).appendingPathComponent(row.id.uuidString.lowercased() + ".sealed")
        let raw = try Data(contentsOf: url)
        #expect(raw.range(of: data) == nil); #expect(raw.range(of: Data(row.file.filename.utf8)) == nil)
        #expect(raw.range(of: Data(owner.actorEmail.utf8)) == nil)
    }

    @Test func metadataRevisionChangesPreserveOriginalCiphertextAndRejectStaleWindows() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let secret = key(), row = try capture()
        let store = QBODocumentCaptureStore.encrypted(directory: root, key: { _ in secret })
        try store.write(row, nil, data)
        let url = root.appendingPathComponent(owner.storageKey).appendingPathComponent(row.id.uuidString.lowercased() + ".sealed")
        let before = try Data(contentsOf: url).suffix(data.count + 28)
        var next = row; next.revision += 1; next.connectionRevision = String(repeating: "b", count: 64)
        try store.write(next, row.revision, nil)
        #expect(try Data(contentsOf: url).suffix(data.count + 28) == before)
        #expect(throws: QBODocumentError.changed) { try store.write(next, row.revision, nil) }
        #expect(try store.bytes(owner, row.id) == data)
    }

    @Test func anotherOwnerOrRenamedCiphertextCannotAdoptTheSavedFile() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let secret = key(), row = try capture()
        let store = QBODocumentCaptureStore.encrypted(directory: root, key: { _ in secret })
        try store.write(row, nil, data)
        let other = QBODocumentOwner(companyID: owner.companyID, backendOrigin: owner.backendOrigin, actorEmail: "other@example.invalid")
        #expect(try store.list(other).isEmpty); #expect(try store.read(other, row.id) == nil)
        let destination = root.appendingPathComponent(other.storageKey)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let filename = row.id.uuidString.lowercased() + ".sealed"
        try FileManager.default.copyItem(at: root.appendingPathComponent(owner.storageKey).appendingPathComponent(filename), to: destination.appendingPathComponent(filename))
        #expect(throws: QBODocumentError.storage) { try store.read(other, row.id) }
    }

    @Test func lostKeyAndCorruptCiphertextFailWithoutClearingSavedFiles() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let secret = key(), row = try capture()
        let store = QBODocumentCaptureStore.encrypted(directory: root, key: { _ in secret })
        try store.write(row, nil, data)
        let missing = QBODocumentCaptureStore.encrypted(directory: root, key: { create in
            #expect(!create); throw QBODocumentError.storage
        })
        #expect(throws: QBODocumentError.storage) { try missing.list(owner) }
        let url = root.appendingPathComponent(owner.storageKey).appendingPathComponent(row.id.uuidString.lowercased() + ".sealed")
        var raw = try Data(contentsOf: url); raw[raw.count - 1] ^= 1
        try raw.write(to: url, options: .atomic)
        #expect(throws: QBODocumentError.storage) { try store.bytes(owner, row.id) }
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func cancellationRetainsOriginalAndPreventsResurrection() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let secret = key(), row = try capture()
        let store = QBODocumentCaptureStore.encrypted(directory: root, key: { _ in secret })
        try store.write(row, nil, data)
        let session = try QBODocumentCaptureSession(record: row, store: store, check: {})
        let client = QBODocumentUploadClient(transport: { _, _, _ in Issue.record("Local cancellation used network"); throw QBODocumentError.unavailable }, check: {})
        try await session.cancel(client: client)
        #expect(session.record.cancelledLocally); #expect(!session.record.needsAttention)
        #expect(try store.bytes(owner, row.id) == data)
        var restored = session.record; restored.revision += 1; restored.cancelledLocally = false
        #expect(throws: QBODocumentError.changed) { try store.write(restored, session.record.revision, nil) }
    }

    @Test func lossAfterDispatchSurvivesRelaunchAndRecoveryNeverPostsASecondFile() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let secret = key(), row = try capture(), id = UUID()
        let store = QBODocumentCaptureStore.encrypted(directory: root, key: { _ in secret })
        try store.write(row, nil, data)
        var sends = 0, reserves = 0
        let client = QBODocumentUploadClient(transport: { path, method, _ in
            if method == "GET" {
                return try serialized(["protocolVersion": 1, "maxFileBytes": QBODocumentFileInfo.maximum, "companyID": owner.companyID.uuidString,
                    "realmID": "realm", "environment": "sandbox", "connectionRevision": String(repeating: "b", count: 64), "uploads": [], "nextCursor": NSNull()])
            }
            if path.hasSuffix("/send") {
                sends += 1
                #expect(try store.read(owner, row.id)?.dispatchStarted == true)
                throw URLError(.timedOut)
            }
            if path.hasSuffix("/recover") { return try serialized(server(row, id: id, state: "confirmed")) }
            reserves += 1
            #expect(try store.read(owner, row.id)?.connectionRevision != nil)
            return try serialized(server(row, id: id))
        }, check: {})
        let first = try QBODocumentCaptureSession(record: row, store: store, check: {})
        await #expect(throws: QBODocumentError.unavailable) { try await first.send(client: client) }
        let savedValue = try store.read(owner, row.id)
        let saved = try #require(savedValue)
        let reopened = try QBODocumentCaptureSession(record: saved, store: store, check: {})
        await #expect(throws: QBODocumentError.review) { try await reopened.send(client: client) }
        try await reopened.recover(client: client)
        #expect(reopened.record.server?.providerID == "A1"); #expect(sends == 1); #expect(reserves == 1)
        #expect(try store.bytes(owner, row.id) == data)
    }

    @Test func lostReservationReplyKeepsSameOperationAndAdoptsOnlyTheOriginalLookup() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let secret = key(), row = try capture(), id = UUID()
        let store = QBODocumentCaptureStore.encrypted(directory: root, key: { _ in secret })
        try store.write(row, nil, data)
        var reserved = false, writes = 0
        let client = QBODocumentUploadClient(transport: { _, method, body in
            if method == "GET" {
                return try serialized(["protocolVersion": 1, "maxFileBytes": QBODocumentFileInfo.maximum, "companyID": owner.companyID.uuidString,
                    "realmID": "realm", "environment": "sandbox", "connectionRevision": String(repeating: "b", count: 64),
                    "uploads": reserved ? [try server(row, id: id)] : [], "nextCursor": NSNull()])
            }
            writes += 1; reserved = true
            let value = try #require(body)
            let fields = try #require(JSONSerialization.jsonObject(with: value) as? [String: Any])
            #expect(fields["operationID"] as? String == row.id.uuidString)
            throw URLError(.timedOut)
        }, check: {})
        let session = try QBODocumentCaptureSession(record: row, store: store, check: {})
        await #expect(throws: QBODocumentError.unavailable) { try await session.send(client: client) }
        #expect(!session.record.dispatchStarted); #expect(session.record.server == nil)
        let savedValue = try store.read(owner, row.id)
        let saved = try #require(savedValue)
        let reopened = try QBODocumentCaptureSession(record: saved, store: store, check: {})
        try await reopened.recover(client: client)
        #expect(reopened.record.server?.id == id); #expect(writes == 1)
    }

    @Test func statePersistenceFailurePreventsProviderDispatch() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let secret = key(); var row = try capture(); let id = UUID()
        let disk = QBODocumentCaptureStore.encrypted(directory: root, key: { _ in secret })
        try disk.write(row, nil, data)
        row.revision = 1; row.connectionRevision = String(repeating: "b", count: 64)
        row.server = try JSONDecoder().decode(QBODocumentUploadRecord.self, from: serialized(server(row, id: id)))
        try disk.write(row, 0, nil)
        var calls = 0
        let denied = QBODocumentCaptureStore(read: disk.read, list: disk.list, bytes: disk.bytes, write: { _, _, _ in throw QBODocumentError.storage })
        let session = try QBODocumentCaptureSession(record: row, store: denied, check: {})
        let client = QBODocumentUploadClient(transport: { _, _, _ in calls += 1; throw QBODocumentError.unavailable }, check: {})
        await #expect(throws: QBODocumentError.storage) { try await session.send(client: client) }
        #expect(calls == 0)
    }

    @Test func legacyCaptureWithoutSharedSourceRemainsReadable() throws {
        let original = try capture()
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "sharedSource")
        let restored = try JSONDecoder().decode(QBODocumentCapture.self, from: serialized(object))
        try restored.validate()
        #expect(restored == original && restored.sharedSource == nil)
    }

    @Test func sharedSourceCannotChangeOrBypassObservedServerState() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let secret = key(); var row = try capture()
        let remote = try JSONDecoder().decode(QBODocumentUploadRecord.self, from: serialized(server(row, id: UUID(), state: "confirmed")))
        row.server = remote; row.sharedSource = remote; row.dispatchStarted = true
        let store = QBODocumentCaptureStore.encrypted(directory: root, key: { _ in secret })
        try store.write(row, nil, data)
        var stripped = row; stripped.revision += 1; stripped.sharedSource = nil
        #expect(throws: (any Error).self) { try store.write(stripped, row.revision, nil) }
        var rewound = row; rewound.revision += 1
        rewound.server = try JSONDecoder().decode(QBODocumentUploadRecord.self, from: serialized(server(row, id: remote.id, state: "reserved")))
        #expect(throws: (any Error).self) { try store.write(rewound, row.revision, nil) }
        #expect(try store.read(owner, row.id) == row && store.bytes(owner, row.id) == data)
    }
}
