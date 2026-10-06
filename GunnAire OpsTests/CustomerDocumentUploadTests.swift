import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor
struct CustomerDocumentUploadTests {
    private enum Failure: Error { case access, upload }
    private enum Origin: CaseIterable { case customerFile, customerAgreement, jobAgreement }

    @MainActor private final class Fixture {
        let context: ModelContext
        let customer: Customer
        let attachment: ServiceDocumentAttachment
        let data = Data("Synthetic saved customer document".utf8)
        var generation = UUID()
        var allowed = true
        var authorizedContainer: ModelContainer?
        var messages: [String] = []

        init(_ origin: Origin = .customerFile) throws {
            let schema = GunnAireModelSchema.schema
            context = ModelContext(try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            ]))
            authorizedContainer = context.container
            customer = Customer(name: "Synthetic original customer")
            attachment = ServiceDocumentAttachment(customer: customer,
                serviceCallID: origin == .jobAgreement ? UUID() : nil,
                customerEquipmentID: origin == .customerFile ? UUID() : nil,
                maintenanceContractID: origin == .customerFile ? nil : UUID(),
                kind: origin == .customerFile ? .customerDocument : .maintenanceAgreement,
                displayName: "original.pdf", caption: "Original captured output",
                localFilePath: "/synthetic/original.pdf", contentType: "application/pdf",
                fileSizeBytes: data.count, sharedCompanySyncStatus: "needs_attention",
                sharedCompanySyncDetail: "Waiting for upload")
            context.insert(customer)
            context.insert(attachment)
            try context.save()
        }

        func capture() throws -> CustomerDocumentUpload {
            let originalGeneration = generation
            let operation = WorkspaceProviderOperation { self.generation == originalGeneration }
            return try CustomerDocumentUpload(attachment: attachment, customer: customer, context: context,
                data: data, equipmentName: "Original equipment", operation: operation) {
                guard self.allowed, self.authorizedContainer === self.context.container else { throw Failure.access }
            }
        }

        func run(_ upload: CustomerDocumentUpload, through provider: PausedUpload) -> Task<Void, Never> {
            Task { @MainActor in
                await upload.perform(upload: provider.send) { self.messages.append($0) }
            }
        }
    }

    @MainActor private final class PausedUpload {
        let fails: Bool
        var payloads: [CustomerDocumentUpload.Payload] = []
        var operation: WorkspaceProviderOperation?
        private var continuation: CheckedContinuation<Void, Never>?
        private var started: CheckedContinuation<Void, Never>?

        init(fails: Bool = false) { self.fails = fails }

        func send(_ payload: CustomerDocumentUpload.Payload, operation: WorkspaceProviderOperation) async throws -> String {
            try operation.check()
            payloads.append(payload)
            self.operation = operation
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                started?.resume()
                started = nil
            }
            // Deliberately ignore cancellation and late authority here so the
            // real caller's continuation fence is what these tests exercise.
            if fails { throw Failure.upload }
            return "synthetic-original-storage-id"
        }

        func waitUntilStarted() async {
            if !payloads.isEmpty { return }
            await withCheckedContinuation { started = $0 }
        }

        func finish() {
            continuation?.resume()
            continuation = nil
        }
    }

    @Test func unchangedThreeOriginPayloadsPreserveMetadataAndStoreSuccess() async throws {
        for origin in Origin.allCases {
            let fixture = try Fixture(origin)
            let upload = try fixture.capture()
            let provider = PausedUpload()
            let task = fixture.run(upload, through: provider)
            await provider.waitUntilStarted()
            let payload = try #require(provider.payloads.first)
            #expect(payload.data == fixture.data)
            #expect(payload.filename == "original.pdf")
            #expect(payload.contentType == "application/pdf")
            #expect(payload.kind == fixture.attachment.kindRaw)
            #expect(payload.serviceCallID == fixture.attachment.serviceCallID)
            #expect(payload.maintenanceContractID == fixture.attachment.maintenanceContractID)
            #expect(payload.customerEquipmentID == fixture.attachment.customerEquipmentID)
            #expect(payload.equipmentName == "Original equipment")
            #expect(payload.customerName == "Synthetic original customer")
            provider.finish()
            await task.value
            #expect(fixture.attachment.backendDocumentID == "synthetic-original-storage-id")
            #expect(fixture.attachment.sharedCompanySyncStatus == "stored")
            #expect(fixture.messages.isEmpty)
        }
    }

    @Test func originalWorkspaceRevokedBeforeDispatchNeverCallsProvider() async throws {
        for origin in Origin.allCases {
            let fixture = try Fixture(origin)
            let upload = try fixture.capture()
            fixture.generation = UUID()
            let provider = PausedUpload()
            await fixture.run(upload, through: provider).value
            #expect(provider.payloads.isEmpty)
            #expect(fixture.attachment.backendDocumentID == nil)
            #expect(fixture.attachment.sharedCompanySyncDetail == "Waiting for upload")
            #expect(fixture.messages.isEmpty)
        }
    }

    @Test func accessOrContainerChangeBeforeDispatchNeverCallsProvider() async throws {
        for changeContainer in [false, true] {
            let fixture = try Fixture()
            let upload = try fixture.capture()
            if changeContainer { fixture.authorizedContainer = nil } else { fixture.allowed = false }
            let provider = PausedUpload()
            await fixture.run(upload, through: provider).value
            #expect(provider.payloads.isEmpty)
            #expect(fixture.messages.isEmpty)
        }
    }

    @Test func revokedWorkspaceRejectsBothLateSuccessAndFailure() async throws {
        for fails in [false, true] {
            let fixture = try Fixture(.jobAgreement)
            let provider = PausedUpload(fails: fails)
            let task = fixture.run(try fixture.capture(), through: provider)
            await provider.waitUntilStarted()
            fixture.generation = UUID()
            let operation = try #require(provider.operation)
            #expect(throws: WorkspaceProviderAccessError.self) { try operation.check() }
            provider.finish()
            await task.value
            #expect(fixture.attachment.backendDocumentID == nil)
            #expect(fixture.attachment.sharedCompanySyncDetail == "Waiting for upload")
            #expect(fixture.messages.isEmpty)
        }
    }

    @Test func changedAccessOrContainerRejectsBothLateOutcomes() async throws {
        for fails in [false, true] {
            for changeContainer in [false, true] {
                let fixture = try Fixture()
                let provider = PausedUpload(fails: fails)
                let task = fixture.run(try fixture.capture(), through: provider)
                await provider.waitUntilStarted()
                if changeContainer { fixture.authorizedContainer = nil } else { fixture.allowed = false }
                provider.finish()
                await task.value
                #expect(fixture.attachment.backendDocumentID == nil)
                #expect(fixture.attachment.sharedCompanySyncDetail == "Waiting for upload")
                #expect(fixture.messages.isEmpty)
            }
        }
    }

    @Test func changedOutputRejectsBothLateOutcomesAndKeepsOriginalPayload() async throws {
        for fails in [false, true] {
            let fixture = try Fixture(.customerAgreement)
            let provider = PausedUpload(fails: fails)
            let task = fixture.run(try fixture.capture(), through: provider)
            await provider.waitUntilStarted()
            fixture.attachment.localFilePath = "/synthetic/replacement.pdf"
            fixture.attachment.caption = "Replacement output"
            fixture.attachment.maintenanceContractID = UUID()
            provider.finish()
            await task.value
            #expect(provider.payloads.first?.filename == "original.pdf")
            #expect(provider.payloads.first?.data == fixture.data)
            #expect(fixture.attachment.localFilePath == "/synthetic/replacement.pdf")
            #expect(fixture.attachment.backendDocumentID == nil)
            #expect(fixture.attachment.sharedCompanySyncDetail == "Waiting for upload")
            #expect(fixture.messages.isEmpty)
        }
    }

    @Test func deletedOrSameDomainReplacementAttachmentRejectsLateOutcomes() async throws {
        for fails in [false, true] {
            for saveDeletion in [false, true] {
                let fixture = try Fixture()
                let provider = PausedUpload(fails: fails)
                let task = fixture.run(try fixture.capture(), through: provider)
                await provider.waitUntilStarted()
                let originalID = fixture.attachment.id
                fixture.context.delete(fixture.attachment)
                if saveDeletion { try fixture.context.save() }
                let replacement = ServiceDocumentAttachment(id: originalID, customer: fixture.customer,
                    serviceCallID: nil, kind: .customerDocument, displayName: "original.pdf",
                    localFilePath: "/synthetic/original.pdf", contentType: "application/pdf",
                    fileSizeBytes: fixture.data.count)
                fixture.context.insert(replacement)
                if saveDeletion { try fixture.context.save() }
                provider.finish()
                await task.value
                #expect(replacement.backendDocumentID == nil)
                #expect(replacement.sharedCompanySyncStatus == nil)
                #expect(fixture.messages.isEmpty)
            }
        }
    }

    @Test func equalValuedCustomerRelinkCannotReplaceOriginalIdentity() async throws {
        for fails in [false, true] {
            let fixture = try Fixture()
            let provider = PausedUpload(fails: fails)
            let task = fixture.run(try fixture.capture(), through: provider)
            await provider.waitUntilStarted()
            let replacement = Customer(id: fixture.customer.id, name: fixture.customer.name)
            fixture.context.insert(replacement)
            fixture.attachment.customer = replacement
            try fixture.context.save()
            provider.finish()
            await task.value
            #expect(fixture.attachment.customer === replacement)
            #expect(fixture.attachment.backendDocumentID == nil)
            #expect(fixture.attachment.sharedCompanySyncDetail == "Waiting for upload")
            #expect(fixture.messages.isEmpty)
        }
    }

    @Test func concurrentStoredResultSurvivesBothOlderUploadOutcomes() async throws {
        for fails in [false, true] {
            let fixture = try Fixture()
            let provider = PausedUpload(fails: fails)
            let task = fixture.run(try fixture.capture(), through: provider)
            await provider.waitUntilStarted()
            fixture.attachment.markSharedCompanyStored(id: "newer-storage-id")
            try fixture.context.save()
            provider.finish()
            await task.value
            #expect(fixture.attachment.backendDocumentID == "newer-storage-id")
            #expect(fixture.attachment.sharedCompanySyncStatus == "stored")
            #expect(fixture.attachment.sharedCompanySyncDetail == "Stored in shared company storage.")
            #expect(fixture.messages.isEmpty)
        }
    }

    @Test func cancellationBeforeDispatchOrDuringUploadDoesNotMutateHistory() async throws {
        let fixture = try Fixture()
        let upload = try fixture.capture()
        let provider = PausedUpload()
        let task = fixture.run(upload, through: provider)
        task.cancel()
        await task.value
        #expect(provider.payloads.isEmpty)
        for fails in [false, true] {
            let active = try Fixture()
            let delayed = PausedUpload(fails: fails)
            let pending = active.run(try active.capture(), through: delayed)
            await delayed.waitUntilStarted()
            pending.cancel()
            delayed.finish()
            await pending.value
            #expect(active.attachment.backendDocumentID == nil)
            #expect(active.attachment.sharedCompanySyncDetail == "Waiting for upload")
            #expect(active.messages.isEmpty)
        }
    }

    @Test func unchangedProviderFailureRetainsDocumentAndShowsRecovery() async throws {
        let fixture = try Fixture()
        let provider = PausedUpload(fails: true)
        let task = fixture.run(try fixture.capture(), through: provider)
        await provider.waitUntilStarted()
        provider.finish()
        await task.value
        #expect(fixture.attachment.backendDocumentID == nil)
        #expect(fixture.attachment.localFilePath == "/synthetic/original.pdf")
        #expect(fixture.attachment.sharedCompanySyncStatus == "needs_attention")
        #expect(fixture.attachment.sharedCompanySyncDetail?.hasPrefix("Shared company storage upload failed:") == true)
        #expect(fixture.messages.count == 1)
    }
}
