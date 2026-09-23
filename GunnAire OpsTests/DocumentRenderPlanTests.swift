import Foundation
import PDFKit
import SwiftData
import Testing
import UIKit
@testable import GunnAire_Ops

/// Covers the boundary between projecting a customer document from SwiftData
/// and rendering it. Projection carries the business fences and must happen on
/// the main actor; rendering must see nothing but immutable values; and the
/// finished bytes must never be published against records that moved while the
/// renderer was running.
///
/// Every assertion here is scoped to the file names this attempt produces, so
/// the suite stays correct when run in parallel with other document tests.
@MainActor struct DocumentRenderPlanTests {
    private struct AuthorizationLost: Error {}

    private func fixture(
        customerName: String,
        summary: String = "Blower motor replacement",
        taxableWithoutQuickBooks: Bool = false
    ) -> (customer: Customer, invoice: Invoice) {
        let customer = Customer(name: customerName, address: "100 Fixture Lane")
        let snapshot = taxableWithoutQuickBooks
            ? CatalogLineItemSnapshot.encoded(from: [Item(name: "Capacitor", unitPrice: 190, isTaxable: true)])
            : nil
        let invoice = Invoice(
            customer: customer,
            lineItemSummary: summary,
            catalogSnapshotJSON: snapshot,
            amount: 189
        )
        return (customer, invoice)
    }

    /// A name unique to one test run, so the file names derived from it cannot
    /// collide with another test's documents.
    private func uniqueName(_ label: String) -> String {
        "\(label) \(UUID().uuidString.prefix(8))"
    }

    private func exportFolder() throws -> URL {
        let documents = try #require(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        return documents.appendingPathComponent("GunnAire Customer Documents", isDirectory: true)
    }

    /// Only the files this attempt could have created: the destination itself,
    /// and any staging file, which always carries the same destination name.
    private func filesProducedFor(fileName: String) throws -> [String] {
        let folder = try exportFolder()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0 == fileName || $0.hasSuffix("-" + fileName) }.sorted()
    }

    private func filesProducedForFixture(_ customerName: String) throws -> [String] {
        let marker = customerName.replacingOccurrences(of: " ", with: "-")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: try exportFolder().path)) ?? []
        return names.filter { $0.contains(marker) }.sorted()
    }

    private func pageText(_ data: Data) throws -> [String] {
        let document = try #require(PDFDocument(data: data))
        return try (0..<document.pageCount).map { index in
            try #require(document.page(at: index)).string ?? ""
        }
    }

    private func pageText(contentsOf url: URL) throws -> [String] {
        try pageText(try Data(contentsOf: url))
    }

    private func expectImmutablePDFName(_ url: URL) {
        #expect(url.pathExtension == "pdf")
        let stem = url.deletingPathExtension().lastPathComponent
        #expect(!stem.hasSuffix(".pdf"))
        // Each retained path needs its own identity even across a minute rollover.
        #expect(UUID(uuidString: String(stem.suffix(36))) != nil)
    }

    // MARK: - Projection is a detached copy

    /// The plan is the whole contract: if it still referenced its models, a
    /// later edit would leak into a document the user already asked for.
    @Test func renderPlanIsDetachedSoLaterEditsCannotChangeTheDocument() throws {
        let name = uniqueName("Detached Plan QA")
        let records = fixture(customerName: name)
        let prepared = try CustomerDocumentExporter.preparedInvoice(
            records.invoice, serviceCall: nil, payments: [])

        let before = try CustomerDocumentExporter.renderDocumentData(prepared.plan)
        records.customer.name = "Replaced Customer"
        records.invoice.lineItemSummary = "Replaced work"
        let after = try CustomerDocumentExporter.renderDocumentData(prepared.plan)

        let beforeText = try pageText(before).joined(separator: "\n")
        #expect(beforeText == (try pageText(after).joined(separator: "\n")))
        #expect(beforeText.contains(name))
        #expect(!beforeText.contains("Replaced Customer"))
    }

    /// Byte equality is not asserted: a PDF carries its own creation metadata.
    /// What must match is every word the customer will read.
    @Test func offMainActorRenderProducesTheSameDocumentAsTheMainActorPath() async throws {
        let records = fixture(customerName: uniqueName("Off Main QA"), summary: "Condenser coil clean")
        let prepared = try CustomerDocumentExporter.preparedInvoice(
            records.invoice, serviceCall: nil, payments: [])

        let onMain = try CustomerDocumentExporter.renderDocumentData(prepared.plan)
        let staged = try await CustomerDocumentExporter.renderDetached(prepared)
        defer { try? FileManager.default.removeItem(at: staged) }

        #expect(try pageText(onMain) == (try pageText(contentsOf: staged)))
        #expect(try pageText(contentsOf: staged).joined().contains("Condenser coil clean"))
        #expect(staged.lastPathComponent.hasPrefix(CustomerDocumentExporter.stagingPrefix))
    }

    // MARK: - Nothing is published against records that moved

    /// The realistic shape of the failure: the edit lands while the renderer is
    /// actually running, not in the authorization callback.
    @Test func recordsEditedWhileRenderingAreRejectedAndNothingIsPublished() async throws {
        let records = fixture(customerName: uniqueName("Render Fence QA"))
        let fixtureName = records.customer.name
        let original = try CustomerDocumentExporter.preparedInvoice(
            records.invoice, serviceCall: nil, payments: []).sourceValues
        let existing = try filesProducedForFixture(fixtureName)

        var thrown: Error?
        do {
            _ = try await CustomerDocumentExporter.exportInvoiceOffMainActor(
                records.invoice, serviceCall: nil, payments: [],
                beforePublication: {
                    #expect((try? filesProducedForFixture(fixtureName))?.isEmpty == false)
                    records.invoice.lineItemSummary = "Compressor replacement"
                }) {}
        } catch { thrown = error }

        let error = try #require(thrown as? CustomerDocumentExportError)
        if case .sourceChangedDuringRender = error {} else {
            Issue.record("Expected sourceChangedDuringRender, got \(error)")
        }
        // Without this the fence could have passed for the wrong reason.
        #expect(try CustomerDocumentExporter.preparedInvoice(
            records.invoice, serviceCall: nil, payments: []).sourceValues != original)
        #expect(try filesProducedForFixture(fixtureName) == existing)
    }

    /// The header comes from the customer record but is not part of the mail
    /// source values, so it needs its own comparison.
    @Test func customerHeaderEditedWhileRenderingIsRejected() async throws {
        let records = fixture(customerName: uniqueName("Header Fence QA"))
        let fixtureName = records.customer.name
        let existing = try filesProducedForFixture(fixtureName)

        var thrown: Error?
        do {
            _ = try await CustomerDocumentExporter.exportInvoiceOffMainActor(
                records.invoice, serviceCall: nil, payments: [],
                beforePublication: { records.customer.address = "999 Somewhere Else" }) {}
        } catch { thrown = error }

        let error = try #require(thrown as? CustomerDocumentExportError)
        if case .sourceChangedDuringRender = error {} else {
            Issue.record("Expected sourceChangedDuringRender, got \(error)")
        }
        #expect(try filesProducedForFixture(fixtureName) == existing)
    }

    /// Losing access while the renderer runs must stop the handoff, and must do
    /// so before any retained record is read again.
    @Test func authorizationLostWhileRenderingStopsTheHandoff() async throws {
        let records = fixture(customerName: uniqueName("Access Fence QA"))
        let fixtureName = records.customer.name
        let existing = try filesProducedForFixture(fixtureName)
        var thrown: Error?

        do {
            _ = try await CustomerDocumentExporter.exportInvoiceOffMainActor(
                records.invoice, serviceCall: nil, payments: []
            ) { throw AuthorizationLost() }
        } catch { thrown = error }

        #expect(thrown is AuthorizationLost)
        #expect(try filesProducedForFixture(fixtureName) == existing)
    }

    @Test func cancellationWhileRenderingStopsTheHandoff() async throws {
        let records = fixture(customerName: uniqueName("Cancel Fence QA"))
        let fixtureName = records.customer.name
        let existing = try filesProducedForFixture(fixtureName)

        let task = Task { @MainActor in
            try await CustomerDocumentExporter.exportInvoiceOffMainActor(
                records.invoice, serviceCall: nil, payments: []) { try Task.checkCancellation() }
        }
        task.cancel()

        var thrown: Error?
        do { _ = try await task.value } catch { thrown = error }
        #expect(thrown is CancellationError)
        #expect(try filesProducedForFixture(fixtureName) == existing)
    }

    // MARK: - Success and the projection-time fences

    @Test func unchangedRecordsRenderOffMainActorAndProduceTheCustomerDocument() async throws {
        let name = uniqueName("Happy Path QA")
        let records = fixture(customerName: name, summary: "Heat exchanger inspection")

        let url = try await CustomerDocumentExporter.exportInvoiceOffMainActor(
            records.invoice, serviceCall: nil, payments: []) {}
        defer { try? FileManager.default.removeItem(at: url) }

        let text = try pageText(contentsOf: url).joined(separator: "\n")
        #expect(text.contains(name))
        #expect(text.contains("Heat exchanger inspection"))
        // The staging file must not survive a successful publication.
        #expect(try filesProducedFor(fileName: url.lastPathComponent) == [url.lastPathComponent])
    }

    @Test func regeneratingDocumentPreservesTheEarlierExportURLAndBytes() async throws {
        let records = fixture(customerName: uniqueName("Immutable Export QA"), summary: "Original approved work")
        let first = try await CustomerDocumentExporter.exportInvoiceOffMainActor(
            records.invoice, serviceCall: nil, payments: []) {}
        defer { try? FileManager.default.removeItem(at: first) }
        let originalBytes = try Data(contentsOf: first)
        records.invoice.lineItemSummary = "Revised approved work"
        let second = try await CustomerDocumentExporter.exportInvoiceOffMainActor(
            records.invoice, serviceCall: nil, payments: []) {}
        defer { try? FileManager.default.removeItem(at: second) }

        #expect(first != second)
        #expect(try Data(contentsOf: first) == originalBytes)
        #expect(try pageText(contentsOf: first).joined().contains("Original approved work"))
        #expect(try pageText(contentsOf: second).joined().contains("Revised approved work"))
        #expect(try filesProducedForFixture(records.customer.name).count == 2)
    }

    @Test func rapidAgreementLifecycleExportsPreserveEveryEarlierPDF() throws {
        let customer = Customer(name: uniqueName("Agreement History QA"))
        let agreement = RecurringMaintenanceContract(
            customer: customer, planName: "Comfort Plan", schedulePattern: "Annual",
            nextDate: Date(timeIntervalSinceReferenceDate: 810_123_456), active: false)
        agreement.configureDraft(
            agreementPrice: 299, billingInterval: .annual, memberDiscountPercent: nil,
            autoRenews: false, termsSummary: "Original agreement terms",
            createdByEmail: "dispatch@example.com", sourceServiceCallID: nil)

        let draft = try CustomerDocumentExporter.exportMaintenanceAgreement(agreement)
        defer { try? FileManager.default.removeItem(at: draft) }
        let draftBytes = try Data(contentsOf: draft)
        agreement.markPendingApproval(offeredByEmail: "dispatch@example.com")
        let offered = try CustomerDocumentExporter.exportMaintenanceAgreement(agreement)
        defer { try? FileManager.default.removeItem(at: offered) }
        let offeredBytes = try Data(contentsOf: offered)
        try agreement.recordCustomerApproval(
            customerName: customer.name, method: .email, reference: "History-Approval-Confirmed",
            signatureImageBase64: nil, recordedByEmail: "dispatch@example.com")
        let approved = try CustomerDocumentExporter.exportMaintenanceAgreement(agreement)
        defer { try? FileManager.default.removeItem(at: approved) }
        #expect(agreement.lifecycleStatus == .active)
        let approvedBytes = try Data(contentsOf: approved)
        agreement.cancel(byEmail: "dispatch@example.com", reason: "Customer requested cancellation")
        let cancelled = try CustomerDocumentExporter.exportMaintenanceAgreement(agreement)
        defer { try? FileManager.default.removeItem(at: cancelled) }

        #expect(agreement.lifecycleStatus == .cancelled)
        #expect(Set([draft, offered, approved, cancelled]).count == 4)
        #expect(try Data(contentsOf: draft) == draftBytes)
        #expect(try Data(contentsOf: offered) == offeredBytes)
        #expect(try Data(contentsOf: approved) == approvedBytes)
        let draftText = try pageText(contentsOf: draft).joined(separator: "\n")
        let offeredText = try pageText(contentsOf: offered).joined(separator: "\n")
        let approvedText = try pageText(contentsOf: approved).joined(separator: "\n")
        let cancelledText = try pageText(contentsOf: cancelled).joined(separator: "\n")
        #expect(draftText.contains("Draft"))
        #expect(offeredText.contains("Pending Approval"))
        #expect(approvedText.contains("Active"))
        #expect(approvedText.contains("History-Approval-Confirmed"))
        #expect(!draftText.contains("History-Approval-Confirmed"))
        #expect(!offeredText.contains("History-Approval-Confirmed"))
        #expect(cancelledText.contains("Cancelled"))
        #expect(!approvedText.contains("Cancelled"))
        for url in [draft, offered, approved, cancelled] { expectImmutablePDFName(url) }
        #expect(try filesProducedForFixture(customer.name).count == 4)
    }

    @Test func repeatedFieldFormExportsPreserveTheOriginalJobDocument() throws {
        let customer = Customer(name: uniqueName("Field Form History QA"))
        let job = ServiceCall(type: .repair, scheduledDate: Date(), customer: customer)
        job.siteAddress = "101 Original Service Road"
        let question = FieldFormQuestion(label: "Drain test", kind: .text, required: true)
        let template = FieldFormTemplate(title: "Completion v1.2.pdf", questions: [question])
        let response = FieldFormResponse(
            serviceCallID: job.id, template: template,
            answers: [question.id: "Drain-Test-Confirmed"])
        let originalAnswers = response.answersJSON
        #expect(response.completionReviewIssue(resolving: template) == nil)

        let first = try CustomerDocumentExporter.exportFieldFormResponse(
            response, serviceCall: job, template: template)
        defer { try? FileManager.default.removeItem(at: first) }
        let firstBytes = try Data(contentsOf: first)
        job.siteAddress = "202 Revised Service Road"
        let revised = try CustomerDocumentExporter.exportFieldFormResponse(
            response, serviceCall: job, template: template)
        defer { try? FileManager.default.removeItem(at: revised) }
        let revisedBytes = try Data(contentsOf: revised)
        let repeated = try CustomerDocumentExporter.exportFieldFormResponse(
            response, serviceCall: job, template: template)
        defer { try? FileManager.default.removeItem(at: repeated) }

        #expect(Set([first, revised, repeated]).count == 3)
        #expect(try Data(contentsOf: first) == firstBytes)
        #expect(try Data(contentsOf: revised) == revisedBytes)
        #expect(try pageText(contentsOf: first).joined().contains("101 Original Service Road"))
        #expect(try pageText(contentsOf: revised).joined().contains("202 Revised Service Road"))
        #expect(response.answersJSON == originalAnswers)
        for url in [first, revised, repeated] {
            expectImmutablePDFName(url)
            #expect(try pageText(contentsOf: url).joined().contains("Drain-Test-Confirmed"))
        }
        #expect(try filesProducedForFixture(customer.name).count == 3)
    }

    @Test func repeatedAccountStatementsPreservePriorBalanceEvidence() throws {
        let customer = Customer(name: uniqueName("Statement History QA"))
        let now = Date(timeIntervalSinceReferenceDate: 810_123_456)
        let invoice = Invoice(
            customer: customer, amount: 500,
            dueDate: now.addingTimeInterval(-86_400), createdAt: now.addingTimeInterval(-172_800))
        let first = try CustomerDocumentExporter.exportAccountStatement(
            customer: customer, invoices: [invoice], payments: [], now: now)
        defer { try? FileManager.default.removeItem(at: first) }
        let firstBytes = try Data(contentsOf: first)
        let payment = Payment(invoice: invoice, amount: 150,
            date: now.addingTimeInterval(-60), method: "check")
        let revised = try CustomerDocumentExporter.exportAccountStatement(
            customer: customer, invoices: [invoice], payments: [payment], now: now)
        defer { try? FileManager.default.removeItem(at: revised) }

        #expect(first != revised)
        #expect(try Data(contentsOf: first) == firstBytes)
        let firstText = try pageText(contentsOf: first).joined(separator: "\n")
        let revisedText = try pageText(contentsOf: revised).joined(separator: "\n")
        #expect(firstText.contains("$500.00"))
        #expect(!firstText.contains("$350.00"))
        #expect(revisedText.contains("$350.00"))
        #expect(revisedText.contains("$150.00 via Check"))
        for url in [first, revised] { expectImmutablePDFName(url) }
        #expect(try filesProducedForFixture(customer.name).count == 2)
    }

    /// The tax fence belongs to projection, so it must stop an off-main-actor
    /// export before any rendering or authorization work happens at all.
    @Test func uncomputedTaxStillBlocksTheOffMainActorExportBeforeRendering() async throws {
        let records = fixture(customerName: uniqueName("Tax Fence QA"), taxableWithoutQuickBooks: true)
        // A fixture that is not actually blocked would make this test vacuous.
        #expect(records.invoice.paymentCollectionBlockedMessage != nil)
        var authorizeCalled = false
        var thrown: Error?

        do {
            _ = try await CustomerDocumentExporter.exportInvoiceOffMainActor(
                records.invoice, serviceCall: nil, payments: []) { authorizeCalled = true }
        } catch { thrown = error }

        let error = try #require(thrown as? CustomerDocumentExportError)
        if case .authoritativeTaxRequired = error {} else {
            Issue.record("Expected authoritativeTaxRequired, got \(error)")
        }
        #expect(!authorizeCalled)
    }

    @Test func deletedRetainedPaymentsCannotBeReadOrPublishedAfterRendering() async throws {
        for saveDeletion in [false, true] {
            let name = uniqueName("Deleted Payment QA")
            let records = fixture(customerName: name)
            let schema = GunnAireModelSchema.schema
            let context = ModelContext(try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            ]))
            context.insert(records.customer)
            context.insert(records.invoice)
            let payment = Payment(invoice: records.invoice, amount: 12)
            context.insert(payment)
            try context.save()
            let existing = try filesProducedForFixture(name)
            var thrown: Error?
            do {
                _ = try await CustomerDocumentExporter.exportInvoiceOffMainActor(
                    records.invoice, serviceCall: nil, payments: [payment],
                    beforePublication: {
                        #expect((try? filesProducedForFixture(name))?.isEmpty == false)
                        context.delete(payment)
                        if saveDeletion {
                            do { try context.save() } catch { Issue.record(error) }
                        }
                    }) {}
            } catch { thrown = error }
            let error = try #require(thrown as? CustomerDocumentExportError)
            if case .sourceChangedDuringRender = error {} else {
                Issue.record("Expected sourceChangedDuringRender, got \(error)")
            }
            #expect(try filesProducedForFixture(name) == existing)
        }
    }

    @Test func originalWholeSourceFenceRejectsPaymentInsertedWhileRendering() async throws {
        let name = uniqueName("Inserted Payment QA")
        let records = fixture(customerName: name)
        let schema = GunnAireModelSchema.schema
        let context = ModelContext(try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ]))
        context.insert(records.customer)
        context.insert(records.invoice)
        try context.save()
        let business = GmailBusinessContext(customerID: records.customer.id,
            invoiceID: records.invoice.id, workflow: .customerDocument)
        let original = try GmailDraftBusinessSnapshot.capture(business, context: context)
        let existing = try filesProducedForFixture(name)
        var thrown: Error?
        do {
            _ = try await CustomerDocumentExporter.exportInvoiceOffMainActor(
                records.invoice, serviceCall: nil, payments: [],
                beforePublication: {
                    #expect((try? filesProducedForFixture(name))?.isEmpty == false)
                    context.insert(Payment(invoice: records.invoice, amount: 8))
                }, authorize: {
                    try GmailDraftBusinessSnapshot.validate(original, business: business, context: context)
                })
        } catch { thrown = error }
        #expect(thrown as? GmailDraftError == .businessChanged)
        #expect(try filesProducedForFixture(name) == existing)
    }

    @Test func stagingWriteFailureCannotPublishOrReplaceThePreviousDocument() async throws {
        let name = uniqueName("Write Failure QA")
        let records = fixture(customerName: name)
        let previous = try await CustomerDocumentExporter.exportInvoiceOffMainActor(
            records.invoice, serviceCall: nil, payments: []) {}
        defer { try? FileManager.default.removeItem(at: previous) }
        let previousBytes = try Data(contentsOf: previous)
        let prepared = try CustomerDocumentExporter.preparedInvoice(
            records.invoice, serviceCall: nil, payments: [])
        // A nonexistent parent causes a real atomic filesystem write failure
        // without changing shared permissions or filling the device's disk.
        let unwritable = PreparedCustomerDocument(plan: prepared.plan,
            fileName: prepared.fileName + "/missing-parent.pdf",
            sourceValues: prepared.sourceValues, customerHeader: prepared.customerHeader,
            customerID: prepared.customerID, documentID: prepared.documentID)
        var thrown: Error?
        do { _ = try await CustomerDocumentExporter.renderDetached(unwritable) }
        catch { thrown = error }
        #expect(thrown is CocoaError)
        #expect(try Data(contentsOf: previous) == previousBytes)
        #expect(try filesProducedForFixture(name) == [previous.lastPathComponent])
    }

    // MARK: - Evidence photos

    /// A report that quietly loses its photos is worse than one that fails:
    /// whoever sends it cannot see what is missing.
    @Test func evidencePhotoReplacedAfterProjectionFailsInsteadOfRenderingStaleEvidence() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photoURL = folder.appendingPathComponent("before.png")

        let red = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
        try #require(red.pngData()).write(to: photoURL)

        let customer = Customer(name: uniqueName("Photo Fence QA"), address: "5 Evidence Road")
        let job = ServiceCall(type: .repair, scheduledDate: Date(timeIntervalSinceReferenceDate: 810_123_456),
                              customer: customer)
        let attachment = ServiceDocumentAttachment(
            customer: customer, serviceCallID: job.id, kind: .beforePhoto,
            displayName: "Before", localFilePath: photoURL.path,
            contentType: "image/png", fileSizeBytes: 0)

        let prepared = try CustomerDocumentExporter.preparedOnsiteReport(
            serviceCall: job, estimate: nil, invoice: nil, payments: [], attachments: [attachment])
        #expect(prepared.plan.photos.count == 1)
        _ = try CustomerDocumentExporter.renderDocumentData(prepared.plan)

        // The path is unchanged; the bytes behind it are not.
        let blue = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 48)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
        }
        try #require(blue.pngData()).write(to: photoURL)

        #expect(throws: CustomerDocumentExportError.self) {
            _ = try CustomerDocumentExporter.renderDocumentData(prepared.plan)
        }
    }

    @Test func missingEvidencePhotoFailsInsteadOfProducingAnIncompleteReport() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photoURL = folder.appendingPathComponent("after.png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
        try #require(image.pngData()).write(to: photoURL)

        let customer = Customer(name: uniqueName("Missing Photo QA"), address: "7 Evidence Road")
        let job = ServiceCall(type: .repair, scheduledDate: Date(timeIntervalSinceReferenceDate: 810_123_456),
                              customer: customer)
        let attachment = ServiceDocumentAttachment(
            customer: customer, serviceCallID: job.id, kind: .afterPhoto,
            displayName: "After", localFilePath: photoURL.path,
            contentType: "image/png", fileSizeBytes: 0)

        let prepared = try CustomerDocumentExporter.preparedOnsiteReport(
            serviceCall: job, estimate: nil, invoice: nil, payments: [], attachments: [attachment])
        try FileManager.default.removeItem(at: photoURL)

        #expect(throws: CustomerDocumentExportError.self) {
            _ = try CustomerDocumentExporter.renderDocumentData(prepared.plan)
        }
    }
}
