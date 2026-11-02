import Foundation
import Testing
@testable import GunnAire_Ops

struct ReceiptUploadIntentJournalTests {
    let scope = ReceiptUploadIntentJournal.scope(origin: "https://synthetic.invalid", email: "fixture@example.invalid")
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func payload(filename: String = "receipt.jpg", data: Data = Data("synthetic-receipt".utf8)) -> ReceiptUploadIntentJournal.Payload {
        .init(request: .init(filename: filename, contentType: "image/jpeg", serviceCallID: nil,
            equipmentID: nil, equipmentName: nil, customerName: nil), data: data)
    }
    @Test func interruptedReceiptReimportAfterRestartRetainsOriginalOperation() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = ReceiptUploadIntentJournal(directory: root)
        let id = try await first.prepare(scope: scope, payload: payload()).operation
        await first.release(scope: scope)
        let relaunched = ReceiptUploadIntentJournal(directory: root)
        #expect(try await relaunched.prepare(scope: scope, payload: payload()).operation == id)
        try await relaunched.confirm(scope: scope, operation: id)
        await relaunched.release(scope: scope)
        let again = ReceiptUploadIntentJournal(directory: root)
        #expect(try await again.prepare(scope: scope, payload: payload()).operation == id)
    }
    @Test func unresolvedReceiptCannotBeReplacedOrDiscarded() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = ReceiptUploadIntentJournal(directory: root)
        _ = try await journal.prepare(scope: scope, payload: payload())
        await journal.release(scope: scope)
        await #expect(throws: ReceiptUploadIntentJournal.Failure.self) {
            try await journal.prepare(scope: scope, payload: payload(filename: "new-camera.jpg"))
        }
        await #expect(throws: ReceiptUploadIntentJournal.Failure.self) { try await journal.startNew(scope: scope) }
    }
    @Test func explicitNewIntentAllowsLegitimateIdenticalReceipt() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = ReceiptUploadIntentJournal(directory: root)
        let first = try await journal.prepare(scope: scope, payload: payload()).operation
        try await journal.confirm(scope: scope, operation: first)
        await journal.release(scope: scope)
        try await journal.startNew(scope: scope)
        let next = ReceiptUploadIntentJournal(directory: root)
        #expect(try await next.prepare(scope: scope, payload: payload()).operation != first)
    }
    @Test func scopesAndCorruptStorageCannotShareOrMintRetryAuthority() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = ReceiptUploadIntentJournal(directory: root)
        let first = try await journal.prepare(scope: scope, payload: payload()).operation
        let other = ReceiptUploadIntentJournal.scope(origin: "https://other.invalid", email: "fixture@example.invalid")
        #expect(try await journal.prepare(scope: other, payload: payload()).operation != first)
        await journal.release(scope: scope)
        try Data("corrupt".utf8).write(to: root.appendingPathComponent(scope + ".json"))
        let relaunched = ReceiptUploadIntentJournal(directory: root)
        await #expect(throws: (any Error).self) { try await relaunched.recover(scope: scope) }
    }
    @Test func cameraTemporaryFileLossRetainsRecoverableOriginalBytes() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let camera = FileManager.default.temporaryDirectory.appendingPathComponent("receipt-camera-" + UUID().uuidString + ".jpg")
        let bytes = Data("synthetic-camera-original".utf8)
        try bytes.write(to: camera)
        let request = ReceiptUploadIntentJournal.Request(filename: camera.lastPathComponent, contentType: "image/jpeg",
            serviceCallID: UUID(), equipmentID: UUID(), equipmentName: "Synthetic unit", customerName: "Synthetic customer")
        let journal = ReceiptUploadIntentJournal(directory: root)
        let pending = try await journal.prepare(scope: scope, payload: .capture(url: camera, request: request))
        let committedID = UUID()
        let serverRecords = [pending.operation: committedID] // Server committed, reply lost.
        await journal.release(scope: scope)
        try FileManager.default.removeItem(at: camera)
        let relaunched = ReceiptUploadIntentJournal(directory: root)
        await #expect(throws: ReceiptUploadIntentJournal.Failure.self) {
            try await relaunched.prepare(scope: scope, payload: payload(filename: "receipt-camera-" + UUID().uuidString + ".jpg", data: bytes))
        }
        let recovered = try await relaunched.recover(scope: scope)
        #expect(recovered.operation == pending.operation && serverRecords[recovered.operation] == committedID)
        #expect(recovered.payload.data == bytes && recovered.payload.request == request)
        #expect(serverRecords.count == 1)
        try await relaunched.confirm(scope: scope, operation: recovered.operation)
        await relaunched.release(scope: scope)
        await #expect(throws: ReceiptUploadIntentJournal.Failure.self) { try await relaunched.recover(scope: scope) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { $0.hasSuffix(".json") || $0.hasSuffix(".lock") })
        try await relaunched.startNew(scope: scope)
        #expect(try await relaunched.prepare(scope: scope, payload: payload()).operation != recovered.operation)
    }
    @Test func corruptedPayloadIsRetainedAndNeverConfirmsOrMintsAnotherIntent() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = ReceiptUploadIntentJournal(directory: root)
        let pending = try await journal.prepare(scope: scope, payload: payload())
        await journal.release(scope: scope)
        let folder = root.appendingPathComponent(scope + "-" + pending.operation.uuidString + "-payload")
        let file = folder.appendingPathComponent("receipt.bin")
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try Data("tampered".utf8).write(to: file)
        let relaunched = ReceiptUploadIntentJournal(directory: root)
        await #expect(throws: (any Error).self) { try await relaunched.recover(scope: scope) }
        await #expect(throws: (any Error).self) { try await relaunched.startNew(scope: scope) }
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
    @Test func oversizedOrEmptyPayloadCannotCreatePendingRecord() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = ReceiptUploadIntentJournal(directory: root)
        for data in [Data(), Data(count: ReceiptUploadIntentJournal.maximumBytes + 1)] {
            await #expect(throws: (any Error).self) { try await journal.prepare(scope: scope, payload: payload(data: data)) }
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(scope + ".json").path))
    }
    @Test func anotherJournalCannotReplaceOrRecoverAnActiveTransport() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = ReceiptUploadIntentJournal(directory: root), other = ReceiptUploadIntentJournal(directory: root)
        let pending = try await first.prepare(scope: scope, payload: payload())
        await #expect(throws: ReceiptUploadIntentJournal.Failure.self) { try await other.prepare(scope: scope, payload: payload()) }
        await #expect(throws: ReceiptUploadIntentJournal.Failure.self) { try await other.recover(scope: scope) }
        await first.release(scope: scope)
        #expect(try await other.recover(scope: scope).operation == pending.operation)
        await other.release(scope: scope)
    }
    @Test func incompleteUnarmedPersistenceCanBeReplacedButArmedUncertaintyCannot() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let record = ReceiptUploadIntentJournal.Record(scope: scope, operation: UUID(),
            fingerprint: try payload().fingerprint(), confirmed: false, payloadReady: false)
        try JSONEncoder().encode(record).write(to: root.appendingPathComponent(scope + ".json"))
        let journal = ReceiptUploadIntentJournal(directory: root)
        await #expect(throws: (any Error).self) { try await journal.recover(scope: scope) }
        try await journal.startNew(scope: scope) // Proven never armed, no possible committed write.
        let pending = try await journal.prepare(scope: scope, payload: payload())
        #expect(pending.operation != record.operation)
        await journal.release(scope: scope)
        await #expect(throws: ReceiptUploadIntentJournal.Failure.self) { try await journal.startNew(scope: scope) }
    }

    @Test func cleanupNeverDeletesUnknownFilesOrLosesConfirmedOutcome() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = ReceiptUploadIntentJournal(directory: root)
        let pending = try await journal.prepare(scope: scope, payload: payload())
        let folder = root.appendingPathComponent(scope + "-" + pending.operation.uuidString + "-payload")
        let unknown = folder.appendingPathComponent("unrelated.txt")
        try Data("retain".utf8).write(to: unknown)
        #expect(try await journal.confirm(scope: scope, operation: pending.operation) == false)
        await journal.release(scope: scope)
        #expect(try Data(contentsOf: unknown) == Data("retain".utf8))
        #expect(try await journal.prepare(scope: scope, payload: payload()).operation == pending.operation)
        await journal.release(scope: scope)
    }

}
