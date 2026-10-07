import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor
struct BillingDocumentPreparationTests {
    private enum Failure: Error, Equatable { case sourceChanged, unavailable }

    @MainActor private final class State {
        var current = true
        var source = "original"
        var loaded = false
        var publications = 0
        var requests = 0

        func preparation() throws -> BillingDocumentPreparation {
            try BillingDocumentPreparation(operation: WorkspaceProviderOperation { self.current }, validate: {})
        }

        func sourceCheck() throws {
            guard source == "original" else { throw Failure.sourceChanged }
        }

        func load(changingSource: Bool = false, revoking: Bool = false) -> Data {
            loaded = true
            if changingSource { source = "changed" }
            if revoking { current = false }
            return Data("synthetic PDF bytes".utf8)
        }

        func api() -> QuickBooksDataAPI {
            QuickBooksDataAPI(testTokens: .init(accessToken: "synthetic-preparation", expiration: .distantFuture),
                realmID: "original-preparation-realm", environment: "sandbox") { _ in
                self.requests += 1
                throw Failure.unavailable
            }
        }
    }

    @MainActor private final class IdentityFixture {
        let context: ModelContext
        let customer: Customer
        let original: ServiceDocumentAttachment
        let id: UUID
        var replaced = false

        init() throws {
            let schema = GunnAireModelSchema.schema
            context = ModelContext(try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            ]))
            customer = Customer(name: "Synthetic identity fixture")
            context.insert(customer)
            original = ServiceDocumentAttachment(customer: customer, serviceCallID: nil, kind: .invoiceSupport,
                displayName: "same.pdf", localFilePath: "/synthetic-same.pdf", contentType: "application/pdf", fileSizeBytes: 8)
            id = original.id
            context.insert(original); try context.save()
        }

        func replace() throws {
            context.delete(original); try context.save()
            let replacement = ServiceDocumentAttachment(id: id, customer: customer, serviceCallID: nil, kind: .invoiceSupport,
                displayName: "same.pdf", localFilePath: "/synthetic-same.pdf", contentType: "application/pdf", fileSizeBytes: 8)
            context.insert(replacement); try context.save()
            replaced = true
        }
    }

    @MainActor private final class CustomerIdentityFixture {
        let context: ModelContext
        let original: Customer
        let invoice: Invoice
        let business: GmailBusinessContext
        let originalSource: [String]?
        var replacementSource: [String]?
        var replaced = false

        init() throws {
            let schema = GunnAireModelSchema.schema
            context = ModelContext(try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            ]))
            original = Customer(name: "Synthetic equal customer", email: "fixture@example.invalid", address: "Synthetic address")
            invoice = Invoice(customer: original, lineItemSummary: "Synthetic service", amount: 10)
            context.insert(original); context.insert(invoice); try context.save()
            business = GmailBusinessContext(customerID: original.id, serviceCallID: nil,
                invoiceID: invoice.id, estimateID: nil, workflow: .customerDocument)
            originalSource = try GmailDraftBusinessSnapshot.capture(business, context: context)
        }

        func replaceAndRelink() throws {
            let replacement = Customer(id: original.id, name: original.name, email: original.email, address: original.address)
            context.insert(replacement)
            invoice.customer = replacement
            context.delete(original)
            try context.save()
            replacementSource = try GmailDraftBusinessSnapshot.capture(business, context: context)
            replaced = true
        }
    }

    @Test func unchangedPreparationReadsTheExactFileBeforePublication() async throws {
        let state = State(), preparation = try state.preparation()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let expected = Data("one immutable prepared PDF".utf8)
        try expected.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = try await preparation.perform {
            try await preparation.read(url, validateSource: state.sourceCheck)
        }
        try preparation.check()
        state.publications += 1
        #expect(bytes == expected)
        #expect(state.publications == 1)
    }

    @Test func changedWorkspaceBeforeReadNeverLoadsOrPublishes() async throws {
        let state = State(), preparation = try state.preparation()
        state.current = false
        do {
            _ = try await preparation.read(URL(fileURLWithPath: "/synthetic-unused"), validateSource: state.sourceCheck) { _ in
                await state.load()
            }
            state.publications += 1
            Issue.record("Retired preparation reached publication")
        } catch { #expect(error is WorkspaceProviderAccessError) }
        #expect(!state.loaded)
        #expect(state.publications == 0)
    }

    @Test func sourceChangedDuringByteReadStopsTheProviderContinuation() async throws {
        let state = State(), preparation = try state.preparation()
        do {
            _ = try await preparation.perform {
                let bytes = try await preparation.read(URL(fileURLWithPath: "/synthetic-unused"), validateSource: state.sourceCheck) { _ in
                    await state.load(changingSource: true)
                }
                state.publications += 1
                return bytes
            }
            Issue.record("Changed source reached publication")
        } catch { #expect(error as? Failure == .sourceChanged) }
        #expect(state.loaded)
        #expect(state.publications == 0)
    }

    @Test func workspaceRevokedDuringByteReadCannotReturnDataForMutation() async throws {
        let state = State(), preparation = try state.preparation()
        do {
            _ = try await preparation.read(URL(fileURLWithPath: "/synthetic-unused"), validateSource: state.sourceCheck) { _ in
                await state.load(revoking: true)
            }
            state.publications += 1
            Issue.record("Revoked workspace received prepared bytes")
        } catch { #expect(error is WorkspaceProviderAccessError) }
        #expect(state.loaded)
        #expect(state.publications == 0)
    }

    @Test func ioFailureAfterRevocationIsReportedAsAuthorityLoss() async throws {
        let state = State(), preparation = try state.preparation()
        do {
            _ = try await preparation.read(URL(fileURLWithPath: "/synthetic-unused"), validateSource: state.sourceCheck) { _ in
                _ = await state.load(revoking: true)
                throw Failure.unavailable
            }
            Issue.record("Expected rejection")
        } catch { #expect(error is WorkspaceProviderAccessError) }
        #expect(state.loaded)
    }

    @Test func cancellationAfterReadCannotPublishEvenWhenTheLoaderIgnoresIt() async throws {
        let state = State(), preparation = try state.preparation()
        let task = Task { @MainActor in
            do {
                _ = try await preparation.read(URL(fileURLWithPath: "/synthetic-unused"), validateSource: state.sourceCheck) { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return await state.load()
                }
                state.publications += 1
                Issue.record("Cancelled byte read continued")
            } catch { #expect(error is CancellationError) }
        }
        await task.value
        #expect(state.loaded)
        #expect(state.publications == 0)
    }

    @Test func originalQuickBooksConnectionIsCapturedBeforeTheTaskStarts() async throws {
        let state = State(), api = state.api()
        let preparation = try BillingDocumentPreparation.capture(api: api, isCurrent: { state.current }, validate: {})
        api.storeTokens(.init(accessToken: "synthetic-replacement", expiration: .distantFuture), realmID: "replacement-realm")
        do {
            try await preparation.perform { state.publications += 1 }
            Issue.record("Preparation adopted the replacement QuickBooks account")
        } catch { #expect(error is WorkspaceProviderAccessError) }
        #expect(state.publications == 0)
        #expect(state.requests == 0)
    }

    @Test func disconnectedLocalPreparationDoesNotRequireQuickBooksOrGoogle() async throws {
        let state = State(), api = state.api()
        api.clearTokens()
        let preparation = try BillingDocumentPreparation.capture(api: api, isCurrent: { state.current }, validate: {})
        let bytes = try await preparation.read(URL(fileURLWithPath: "/synthetic-unused"), validateSource: state.sourceCheck) { _ in
            await state.load()
        }
        #expect(!bytes.isEmpty)
        #expect(state.loaded)
        #expect(state.requests == 0)
    }

    @Test func connectionAddedDuringLocalPreparationCannotBeAdopted() async throws {
        let state = State(), api = state.api()
        api.clearTokens()
        let preparation = try BillingDocumentPreparation.capture(api: api, isCurrent: { state.current }, validate: {})
        api.storeTokens(.init(accessToken: "synthetic-new-account", expiration: .distantFuture), realmID: "new-realm")
        do {
            try await preparation.perform { state.publications += 1 }
            Issue.record("Local preparation adopted a newly connected provider")
        } catch { #expect(error is WorkspaceProviderAccessError) }
        #expect(state.publications == 0)
        #expect(state.requests == 0)
    }

    @Test func rejectedUnadoptedExportRemovesOnlyItsNewFile() throws {
        let state = State()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let prior = folder.appendingPathComponent("prior.pdf"), candidate = folder.appendingPathComponent("candidate.pdf")
        try Data("retained prior PDF".utf8).write(to: prior)
        try Data("new PDF".utf8).write(to: candidate)
        let publication = BillingDocumentExportPublication(url: candidate, check: state.sourceCheck)
        state.source = "changed while returning to caller"
        #expect(throws: Failure.sourceChanged) { try publication.validate() }
        #expect(!FileManager.default.fileExists(atPath: candidate.path))
        #expect(try Data(contentsOf: prior) == Data("retained prior PDF".utf8))
    }

    @Test func persistedFirstPDFSurvivesALaterReportSourceFailure() throws {
        let state = State()
        let schema = GunnAireModelSchema.schema
        let context = ModelContext(try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ]))
        let customer = Customer(name: "Synthetic retained export")
        let invoice = Invoice(customer: customer, amount: 10)
        context.insert(customer); context.insert(invoice)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        let bytes = Data("first valid immutable PDF".utf8)
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let publication = BillingDocumentExportPublication(url: url, check: state.sourceCheck)
        let attachment = ServiceDocumentAttachment(customer: customer, serviceCallID: nil, invoiceID: invoice.id, kind: .invoiceSupport,
            displayName: url.lastPathComponent, caption: "Synthetic PDF", localFilePath: url.path,
            contentType: "application/pdf", fileSizeBytes: bytes.count)
        context.insert(attachment)
        try context.save()
        publication.adopt()
        state.source = "later onsite report changed"
        #expect(throws: Failure.sourceChanged) { try publication.validate() }
        #expect(try Data(contentsOf: URL(fileURLWithPath: attachment.localFilePath)) == bytes)
        #expect(try context.fetch(FetchDescriptor<ServiceDocumentAttachment>()).first === attachment)
    }

    @Test func dependentUploadCompletesBeforeItsPreparationOwnerRetires() async throws {
        let state = State(), preparation = try state.preparation()
        var recorded = false
        let upload = Task { @MainActor in
            await Task.yield()
            do { try preparation.check(); recorded = true }
            catch { Issue.record("Upload lost its owner before recording its response") }
        }
        try await preparation.waitForAttachment(upload, validateSource: state.sourceCheck)
        state.current = false
        #expect(recorded)
    }

    @Test func sourceChangeDuringDependentUploadPreventsTheFollowingPublication() async throws {
        let state = State(), preparation = try state.preparation()
        let upload = Task { @MainActor in state.source = "changed during upload" }
        do {
            try await preparation.waitForAttachment(upload, validateSource: state.sourceCheck)
            state.publications += 1
            Issue.record("Changed upload source continued to document publication")
        } catch { #expect(error as? Failure == .sourceChanged) }
        #expect(state.publications == 0)
    }

    @Test func identicalReplacementDuringByteReadCannotInheritRetainedModelIdentity() async throws {
        let fixture = try IdentityFixture()
        let membership = BillingDocumentPreparation.membership([fixture.original], in: fixture.context)
        let preparation = try BillingDocumentPreparation(operation: WorkspaceProviderOperation { true }, validate: membership)
        do {
            _ = try await preparation.read(URL(fileURLWithPath: "/synthetic-unused"), validateSource: {}) { _ in
                try await fixture.replace()
                return Data("same PDF".utf8)
            }
            Issue.record("Equal-valued replacement inherited a retained PDF input")
        } catch { #expect(error as? GmailDraftError == .businessChanged) }
        #expect(fixture.replaced)
        let saved = try #require(fixture.context.fetch(FetchDescriptor<ServiceDocumentAttachment>()).first)
        #expect(saved.id == fixture.id)
        #expect(saved !== fixture.original)
    }

    @Test func equalValuedCustomerReplacementDuringByteReadCannotInheritInvoiceExport() async throws {
        let fixture = try CustomerIdentityFixture()
        let membership = BillingDocumentPreparation.membership([fixture.original], in: fixture.context)
        let preparation = try BillingDocumentPreparation(operation: WorkspaceProviderOperation { true }, validate: membership)
        var publications = 0
        do {
            _ = try await preparation.read(URL(fileURLWithPath: "/synthetic-unused"), validateSource: {}) { _ in
                try await fixture.replaceAndRelink()
                return Data("already rendered invoice PDF".utf8)
            }
            publications += 1
            Issue.record("A replacement Customer inherited the original invoice export")
        } catch { #expect(error as? GmailDraftError == .businessChanged) }
        #expect(fixture.replaced)
        #expect(fixture.originalSource != nil)
        #expect(fixture.originalSource == fixture.replacementSource)
        #expect(fixture.invoice.customer?.id == fixture.business.customerID)
        #expect(fixture.invoice.customer !== fixture.original)
        #expect(publications == 0)
    }
}
