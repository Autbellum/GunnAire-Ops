import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor
struct BillingPDFLocalQueueTests {
    private func fixture() throws -> (ModelContainer, ModelContext, Customer) {
        let schema = GunnAireModelSchema.schema
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true,
                cloudKitDatabase: .none)
        ])
        let context = ModelContext(container)
        let customer = Customer(name: "Saved PDF Customer")
        context.insert(customer)
        try context.save()
        return (container, context, customer)
    }

    @Test func savedEstimateCreatesOneDurablePDFAndRelaunchAdoptsIt() async throws {
        let (container, context, customer) = try fixture()
        let estimate = Estimate(customer: customer, lineItemSummary: "Labor",
            amount: 125, notes: "Initial scope")
        context.insert(estimate)
        try context.save()
        let companyID = UUID()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("billing-queue-\(UUID().uuidString)", isDirectory: true)
        let generated = root.appendingPathComponent("GunnAire Customer Documents", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = BillingPDFGenerationJournal(directory: root.appendingPathComponent("Journal"),
            generatedRoot: generated)
        let queue = BillingPDFLocalQueue(journal: journal, generatedRoot: generated)
        let initial = await queue.enqueue(companyID: companyID, container: container,
            kind: .estimate, documentID: estimate.id)
        #expect(initial == .queued)
        let pending = try await journal.pending(companyID: companyID)
        #expect(pending.count == 1)
        #expect(pending.first?.stage == .rendered)
        let originalPath = try #require(pending.first?.renderedFilePath)
        #expect(try Data(contentsOf: URL(fileURLWithPath: originalPath))
            .starts(with: Data("%PDF-".utf8)))

        let restartedJournal = BillingPDFGenerationJournal(
            directory: root.appendingPathComponent("Journal"), generatedRoot: generated)
        let restarted = BillingPDFLocalQueue(journal: restartedJournal, generatedRoot: generated)
        let recovered = await restarted.recoverPending(companyID: companyID, container: container)
        #expect(recovered == [.alreadyQueued])
        #expect(try FileManager.default.contentsOfDirectory(at: generated,
            includingPropertiesForKeys: nil).count == 1)
        #expect(try await restartedJournal.pending(companyID: companyID).first?.renderedFilePath
            == originalPath)

        estimate.notes = "Materially revised scope"
        try context.save()
        let revised = await restarted.enqueue(companyID: companyID, container: container,
            kind: .estimate, documentID: estimate.id)
        #expect(revised == .queued)
        let current = try await restartedJournal.pending(companyID: companyID)
        #expect(current.count == 1)
        #expect(current.first?.sourceDigest != pending.first?.sourceDigest)
        #expect(try await restartedJournal.superseded(companyID: companyID).count == 1)
    }

    @Test func unsavedInvoiceCannotCreateDurablePDFIntent() async throws {
        let (container, context, customer) = try fixture()
        let invoice = Invoice(customer: customer, lineItemSummary: "Repair",
            amount: 225, completionNotes: "Not saved")
        context.insert(invoice)
        let companyID = UUID()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("billing-queue-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let generated = root.appendingPathComponent("GunnAire Customer Documents", isDirectory: true)
        let journal = BillingPDFGenerationJournal(directory: root.appendingPathComponent("Journal"),
            generatedRoot: generated)
        let queue = BillingPDFLocalQueue(journal: journal, generatedRoot: generated)
        let outcome = await queue.enqueue(companyID: companyID, container: container,
            kind: .invoice, documentID: invoice.id)
        #expect(outcome == .needsReview)
        #expect(try await journal.pending(companyID: companyID).isEmpty)
    }

    @Test func tamperedRenderedFileCannotBeRecoveredAsQueued() async throws {
        let (container, context, customer) = try fixture()
        let invoice = Invoice(customer: customer, lineItemSummary: "Service",
            amount: 320, completionNotes: "Completed")
        context.insert(invoice)
        try context.save()
        let companyID = UUID()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("billing-queue-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let generated = root.appendingPathComponent("GunnAire Customer Documents", isDirectory: true)
        let journal = BillingPDFGenerationJournal(directory: root.appendingPathComponent("Journal"),
            generatedRoot: generated)
        let queue = BillingPDFLocalQueue(journal: journal, generatedRoot: generated)
        #expect(await queue.enqueue(companyID: companyID, container: container,
            kind: .invoice, documentID: invoice.id) == .queued)
        let path = try #require(await journal.pending(companyID: companyID).first?.renderedFilePath)
        try Data("tampered".utf8).write(to: URL(fileURLWithPath: path))
        let restarted = BillingPDFLocalQueue(journal: BillingPDFGenerationJournal(
            directory: root.appendingPathComponent("Journal"), generatedRoot: generated),
            generatedRoot: generated)
        #expect(await restarted.recoverPending(companyID: companyID, container: container)
            == [.needsReview])
    }

    @Test func revokedWorkspaceCannotCreateAnIntentOrPDF() async throws {
        let (container, context, customer) = try fixture()
        let estimate = Estimate(customer: customer, lineItemSummary: "Review",
            amount: 90)
        context.insert(estimate)
        try context.save()
        let companyID = UUID()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("billing-queue-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let generated = root.appendingPathComponent("GunnAire Customer Documents", isDirectory: true)
        let journal = BillingPDFGenerationJournal(directory: root.appendingPathComponent("Journal"),
            generatedRoot: generated)
        let queue = BillingPDFLocalQueue(journal: journal, generatedRoot: generated)
        let outcome = await queue.enqueue(companyID: companyID, container: container,
            kind: .estimate, documentID: estimate.id,
            check: { throw BillingPDFGenerationError.changed })
        #expect(outcome == .needsReview)
        #expect(try await journal.pending(companyID: companyID).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: generated.path))
    }
}
