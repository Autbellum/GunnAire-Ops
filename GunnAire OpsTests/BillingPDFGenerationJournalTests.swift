import Foundation
import Testing
@testable import GunnAire_Ops

struct BillingPDFGenerationJournalTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("billing-pdf-journal-\(UUID().uuidString)", isDirectory: true)
    }

    private func journal(_ folder: URL) -> BillingPDFGenerationJournal {
        BillingPDFGenerationJournal(directory: folder.appendingPathComponent("Journal", isDirectory: true),
                                    generatedRoot: folder.appendingPathComponent("PDF", isDirectory: true))
    }

    private func pdf(_ folder: URL, name: String, body: String = "%PDF-1.7\nfixture") throws -> URL {
        let root = folder.appendingPathComponent("PDF", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent(name)
        try Data(body.utf8).write(to: file)
        return file
    }

    @Test func intentSurvivesRelaunchAndReconcilesRenderedAttachment() async throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let company = UUID(), document = UUID()
        let source = BillingPDFSourceDigest.make(["Estimate", "one customer", "100.00"])
        let first = journal(folder)
        let pending = try await first.record(companyID: company, documentID: document,
            kind: .estimate, sourceDigest: source)
        let duplicate = try await first.record(companyID: company, documentID: document,
            kind: .estimate, sourceDigest: source)
        #expect(duplicate == pending)

        let reopened = journal(folder)
        #expect(try await reopened.pending(companyID: company) == [pending])
        #expect(try await reopened.pending(companyID: UUID()).isEmpty)
        let output = try pdf(folder, name: "current-estimate.pdf")
        let rendered = try await reopened.rendered(pending, fileURL: output,
                                                  byteCount: Data("%PDF-1.7\nfixture".utf8).count)
        let afterRender = journal(folder)
        #expect(try await afterRender.pending(companyID: company) == [rendered])
        #expect(try await afterRender.current(pending) == rendered)

        try await afterRender.complete(rendered)
        #expect(try await journal(folder).pending(companyID: company).isEmpty)
    }

    @Test func newerSourceSupersedesOldRenderWithoutClobberingItsCheckpoint() async throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = journal(folder)
        let company = UUID(), document = UUID()
        let first = try await journal.record(companyID: company, documentID: document,
            kind: .invoice, sourceDigest: BillingPDFSourceDigest.make(["Invoice", "100.00"]))
        let changed = try await journal.record(companyID: company, documentID: document,
            kind: .invoice, sourceDigest: BillingPDFSourceDigest.make(["Invoice", "120.00"]))
        #expect(changed.generationID != first.generationID)
        await #expect(throws: BillingPDFGenerationError.changed) {
            try await journal.rendered(first, fileURL: URL(fileURLWithPath: "/tmp/stale.pdf"), byteCount: 10)
        }
        await #expect(throws: BillingPDFGenerationError.changed) {
            try await journal.complete(first)
        }
        #expect(try await journal.pending(companyID: company) == [changed])
        #expect(try await journal.superseded(companyID: company) == [first])
    }

    @Test func digestPreservesValueBoundariesAndRejectsInvalidInput() async throws {
        #expect(BillingPDFSourceDigest.make(["a", "bc"]) != BillingPDFSourceDigest.make(["ab", "c"]))
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = journal(folder)
        await #expect(throws: BillingPDFGenerationError.invalidIntent) {
            try await journal.record(companyID: UUID(), documentID: UUID(),
                kind: .estimate, sourceDigest: "invalid")
        }
    }

    @Test func corruptedOrSymbolicLinkJournalFailsClosed() async throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let company = UUID(), document = UUID()
        let journal = journal(folder)
        let intent = try await journal.record(companyID: company, documentID: document,
            kind: .invoice, sourceDigest: BillingPDFSourceDigest.make(["invoice"]))
        let file = folder.appendingPathComponent("Journal", isDirectory: true)
            .appendingPathComponent(intent.key + ".json")
        try Data("not-json".utf8).write(to: file, options: .atomic)
        await #expect(throws: BillingPDFGenerationError.invalidIntent) {
            try await self.journal(folder).pending(companyID: company)
        }
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file,
            withDestinationURL: URL(fileURLWithPath: "/tmp/unrelated-journal"))
        await #expect(throws: BillingPDFGenerationError.invalidIntent) {
            try await self.journal(folder).pending(companyID: company)
        }
    }

    @Test func recoveryRejectsChangedMissingAndOutsideRootPDF() async throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = journal(folder)
        let company = UUID(), document = UUID()
        let pending = try await journal.record(companyID: company, documentID: document,
            kind: .estimate, sourceDigest: BillingPDFSourceDigest.make(["estimate", "revision-1"]))
        let outside = folder.appendingPathComponent("outside.pdf")
        try Data("%PDF-1.7\noutside".utf8).write(to: outside)
        await #expect(throws: BillingPDFGenerationError.changed) {
            try await journal.rendered(pending, fileURL: outside, byteCount: 16)
        }
        let output = try pdf(folder, name: "current.pdf")
        let original = Data("%PDF-1.7\nfixture".utf8)
        let rendered = try await journal.rendered(pending, fileURL: output, byteCount: original.count)
        try Data("%PDF-1.7\nchanged".utf8).write(to: output)
        await #expect(throws: BillingPDFGenerationError.invalidIntent) {
            try await self.journal(folder).current(rendered)
        }
        try original.write(to: output)
        #expect(try await self.journal(folder).current(rendered) == rendered)
        try FileManager.default.removeItem(at: output)
        await #expect(throws: BillingPDFGenerationError.invalidIntent) {
            try await self.journal(folder).current(rendered)
        }
    }
}
