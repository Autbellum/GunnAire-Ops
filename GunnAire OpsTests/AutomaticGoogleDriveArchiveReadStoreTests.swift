import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor
struct AutomaticGoogleDriveArchiveReadStoreTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = GunnAireModelSchema.schema
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)]
        )
    }

    @Test func localUserProofRejectsInactiveAndAmbiguousMirrors() async throws {
        let container = try makeContainer()
        let seed = ModelContext(container)
        let reader = GoogleDriveArchiveReadStore(container: container)
        let approved = AppUser(email: "owner@gunnaire.com", role: .admin)
        seed.insert(approved)
        try seed.save()
        #expect(try await reader.hasUnambiguousActiveUser(email: "owner@gunnaire.com"))
        #expect(try await reader.hasUnambiguousActiveUser(email: "other@gunnaire.com") == false)

        let conflicting = AppUser(email: "owner@gunnaire.com", role: .fieldTechnician)
        seed.insert(conflicting)
        try seed.save()
        #expect(try await reader.hasUnambiguousActiveUser(email: "owner@gunnaire.com") == false)

        seed.delete(conflicting)
        approved.isActive = false
        try seed.save()
        #expect(try await reader.hasUnambiguousActiveUser(email: "owner@gunnaire.com") == false)
    }

    @Test func backgroundPagesReturnOnlyPendingOwnedAttachmentIDsWithoutTruncation() async throws {
        let container = try makeContainer()
        let seed = ModelContext(container)
        let customer = Customer(name: "Drive recovery fixture")
        seed.insert(customer)
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        var expectedPending: UUID?
        for index in 0..<102 {
            let owned = index != 101
            let pending = index >= 100
            let attachment = ServiceDocumentAttachment(
                customer: owned ? customer : nil,
                serviceCallID: nil,
                kind: .other,
                displayName: "record-\(index).pdf",
                localFilePath: "/tmp/record-\(index).pdf",
                contentType: "application/pdf",
                fileSizeBytes: 12,
                googleDriveFileID: pending ? nil : "file-\(index)",
                googleDriveWebViewLink: pending ? nil : "https://drive.google.com/file/d/file-\(index)/view",
                googleDriveSyncStatus: pending ? nil : GoogleDriveDocumentSyncState.archived.rawValue,
                createdAt: base.addingTimeInterval(TimeInterval(index))
            )
            seed.insert(attachment)
            if index == 100 { expectedPending = attachment.id }
        }
        try seed.save()

        let reader = GoogleDriveArchiveReadStore(container: container)
        let first = try await reader.attachmentPage(offset: 0)
        let second = try await reader.attachmentPage(offset: first.fetchedCount)
        let end = try await reader.attachmentPage(offset: first.fetchedCount + second.fetchedCount)
        #expect(first.fetchedCount == 100)
        #expect(first.candidateIDs.isEmpty)
        #expect(second.fetchedCount == 2)
        #expect(second.candidateIDs == [expectedPending].compactMap { $0 })
        #expect(end.fetchedCount == 0)
    }

    @Test func savedOwnedAttachmentsWakeArchiveWithoutRewakingArchivedOrUnownedFiles() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let customer = Customer(name: "Drive wake fixture")
        context.insert(customer)

        let pending = ServiceDocumentAttachment(customer: customer, serviceCallID: nil,
            kind: .serviceReport, displayName: "report.pdf", localFilePath: "/tmp/report.pdf",
            contentType: "application/pdf", fileSizeBytes: 12)
        let archived = ServiceDocumentAttachment(customer: customer, serviceCallID: nil,
            kind: .customerDocument, displayName: "archived.pdf", localFilePath: "/tmp/archived.pdf",
            contentType: "application/pdf", fileSizeBytes: 12,
            googleDriveFileID: "saved-file", googleDriveWebViewLink: "https://drive.google.com/file/d/saved-file/view",
            googleDriveSyncStatus: GoogleDriveDocumentSyncState.archived.rawValue)
        let unowned = ServiceDocumentAttachment(customer: nil, serviceCallID: nil,
            kind: .other, displayName: "unowned.pdf", localFilePath: "/tmp/unowned.pdf",
            contentType: "application/pdf", fileSizeBytes: 12)
        let fleet = ServiceDocumentAttachment(customer: nil, serviceCallID: nil,
            fleetVehicleID: UUID(), kind: .fleetService, displayName: "fleet.pdf",
            localFilePath: "/tmp/fleet.pdf", contentType: "application/pdf", fileSizeBytes: 12)
        context.insert(pending)
        context.insert(archived)
        context.insert(unowned)
        context.insert(fleet)
        try context.save()

        var wakeCount = 0
        let recovery: @MainActor (ModelContext) -> Void = { recoveredContext in
            #expect(recoveredContext === context)
            wakeCount += 1
        }
        AutomaticGoogleDriveArchive.shared.wakeAfterSave(pending, context: context, recovery: recovery)
        AutomaticGoogleDriveArchive.shared.wakeAfterSave(archived, context: context, recovery: recovery)
        AutomaticGoogleDriveArchive.shared.wakeAfterSave(unowned, context: context, recovery: recovery)
        AutomaticGoogleDriveArchive.shared.wakeAfterSave(fleet, context: context, recovery: recovery)
        #expect(wakeCount == 2)
    }
}
