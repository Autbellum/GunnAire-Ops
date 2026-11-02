import Foundation
import Testing
@testable import GunnAire_Ops

struct ReceiptUploadIntentJournalTests {
    let scope = ReceiptUploadIntentJournal.scope(origin: "https://synthetic.invalid", email: "fixture@example.invalid")
    let fingerprint = String(repeating: "a", count: 64)
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @Test func interruptedReceiptReimportAfterRestartRetainsOriginalOperation() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = ReceiptUploadIntentJournal(directory: root)
        let id = try await first.begin(scope: scope, fingerprint: fingerprint)
        await first.release(scope: scope) // Lost HTTP reply; view is dismissed.
        let relaunched = ReceiptUploadIntentJournal(directory: root)
        #expect(try await relaunched.begin(scope: scope, fingerprint: fingerprint) == id)
        try await relaunched.confirm(scope: scope, operation: id)
        await relaunched.release(scope: scope)
        let again = ReceiptUploadIntentJournal(directory: root)
        #expect(try await again.begin(scope: scope, fingerprint: fingerprint) == id)
    }
    @Test func unresolvedReceiptCannotBeReplacedOrDiscarded() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = ReceiptUploadIntentJournal(directory: root)
        _ = try await journal.begin(scope: scope, fingerprint: fingerprint)
        await journal.release(scope: scope)
        await #expect(throws: ReceiptUploadIntentJournal.Failure.self) {
            try await journal.begin(scope: scope, fingerprint: String(repeating: "b", count: 64))
        }
        await #expect(throws: ReceiptUploadIntentJournal.Failure.self) { try await journal.startNew(scope: scope) }
    }
    @Test func explicitNewIntentAllowsLegitimateIdenticalReceipt() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = ReceiptUploadIntentJournal(directory: root)
        let first = try await journal.begin(scope: scope, fingerprint: fingerprint)
        try await journal.confirm(scope: scope, operation: first)
        await journal.release(scope: scope)
        try await journal.startNew(scope: scope)
        let next = ReceiptUploadIntentJournal(directory: root)
        #expect(try await next.begin(scope: scope, fingerprint: fingerprint) != first)
    }
    @Test func scopesAndCorruptStorageCannotShareOrMintRetryAuthority() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = ReceiptUploadIntentJournal(directory: root)
        let first = try await journal.begin(scope: scope, fingerprint: fingerprint)
        let other = ReceiptUploadIntentJournal.scope(origin: "https://other.invalid", email: "fixture@example.invalid")
        #expect(try await journal.begin(scope: other, fingerprint: fingerprint) != first)
        await journal.release(scope: scope)
        try Data("corrupt".utf8).write(to: root.appendingPathComponent(scope + ".json"))
        let relaunched = ReceiptUploadIntentJournal(directory: root)
        await #expect(throws: (any Error).self) { try await relaunched.begin(scope: scope, fingerprint: fingerprint) }
    }
}
