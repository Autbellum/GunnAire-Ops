import Foundation
import SwiftData

/// A private context owns each read. SwiftData models never cross back to the
/// UI actor; recovery receives only stable attachment IDs and a policy result.
nonisolated struct GoogleDriveArchiveReadStore: Sendable {
    let container: ModelContainer

    nonisolated struct AttachmentPage: Sendable {
        let candidateIDs: [UUID]
        let fetchedCount: Int
    }

    func hasUnambiguousActiveUser(email: String) async throws -> Bool {
        let email = AppAccess.normalizedEmail(email)
        return try await Task.detached(priority: .utility) {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let users = try context.fetch(FetchDescriptor<AppUser>())
            let matching = users.filter { AppAccess.normalizedEmail($0.email) == email }
            guard !email.isEmpty, !matching.isEmpty,
                  matching.allSatisfy({ $0.isActive && AppUserRole(rawValue: $0.roleRawValue) != nil }) else {
                return false
            }
            return Set(matching.map(\.roleRawValue)).count == 1
        }.value
    }

    func attachmentPage(offset: Int) async throws -> AttachmentPage {
        try await Task.detached(priority: .utility) {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            var fetch = FetchDescriptor<ServiceDocumentAttachment>(
                sortBy: [SortDescriptor(\.createdAt, order: .forward), SortDescriptor(\.id)])
            fetch.fetchLimit = 100
            fetch.fetchOffset = offset
            let page = try context.fetch(fetch)
            return AttachmentPage(
                candidateIDs: page.compactMap { attachment in
                    guard (attachment.customer != nil || attachment.fleetVehicleID != nil),
                          attachment.needsGoogleDriveArchive else { return nil }
                    return attachment.id
                },
                fetchedCount: page.count
            )
        }.value
    }
}

/// The durable reservation and confirmation step shared by live recovery and
/// local transport tests. The caller supplies authorization and source guards;
/// neither a failed upload nor a dropped response creates a new reservation.
@MainActor
enum GoogleDriveArchivePublication {
    static func run(
        attachment: ServiceDocumentAttachment,
        context: ModelContext,
        actorEmail: String?,
        check: @MainActor () async throws -> Void,
        reserveFileID: @MainActor () async throws -> String,
        readFile: @MainActor () async throws -> Data,
        upload: @MainActor (String, Data) async throws -> GoogleDriveFile
    ) async {
        guard attachment.needsGoogleDriveArchive else { return }
        do {
            try await check()
            let fileID: String
            if let reserved = attachment.googleDriveFileID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !reserved.isEmpty {
                fileID = reserved
            } else {
                fileID = try await reserveFileID()
                try await check()
                attachment.markGoogleDrivePreparing(fileID: fileID, actorEmail: actorEmail)
                try context.save()
            }
            let data = try await readFile()
            try await check()
            guard !data.isEmpty else { throw GoogleDriveAPIError.emptyFile }
            attachment.markGoogleDriveUploading()
            try context.save()
            let file = try await upload(fileID, data)
            try await check()
            attachment.markGoogleDriveArchived(file, actorEmail: actorEmail)
            try context.save()
        } catch {
            guard (try? await check()) != nil else { return }
            attachment.markGoogleDriveArchiveFailed(error.localizedDescription,
                discardReservedID: (error as? GoogleDriveAPIError)?.discardsReservedFileIDBeforeRetry == true)
            try? context.save()
        }
    }
}

/// Archives only app-owned pending attachments while an administrator has a
/// matching Google account with per-file Drive permission. Saved reservations
/// make a later launch/reconnect reconcile the original Drive file ID.
@MainActor
final class AutomaticGoogleDriveArchive {
    static let shared = AutomaticGoogleDriveArchive()

    private var running = false
    private var queued = false
    private var queuedContext: ModelContext?
    private var activeAttachmentIDs: Set<UUID> = []

    private init() {}

    func claim(_ id: UUID) -> Bool {
        activeAttachmentIDs.insert(id).inserted
    }

    func release(_ id: UUID) {
        activeAttachmentIDs.remove(id)
    }

    /// Called only after the attachment has been saved. Recovery keeps the
    /// workspace, administrator, Google account, and Drive scope checks.
    func wakeAfterSave(_ attachment: ServiceDocumentAttachment, context: ModelContext,
                       recovery: @MainActor (ModelContext) -> Void = { AutomaticGoogleDriveArchive.shared.recover(context: $0) }) {
        guard (attachment.customer != nil || attachment.fleetVehicleID != nil),
              attachment.needsGoogleDriveArchive else { return }
        recovery(context)
    }

    func recover(context: ModelContext) {
        guard canArchiveFast(context: context),
              let stamp = CompanyWorkspaceAccessController.shared.operationStamp,
              let providerOperation = try? GoogleAuthManager.shared.captureProviderOperation() else { return }
        if running { queued = true; queuedContext = context; return }
        running = true
        Task { @MainActor in
            defer {
                running = false
                if queued {
                    queued = false
                    let nextContext = queuedContext ?? context
                    queuedContext = nil
                    recover(context: nextContext)
                }
            }
            do {
                let reader = GoogleDriveArchiveReadStore(container: context.container)
                var offset = 0
                while !Task.isCancelled {
                    guard await canArchive(context: context, reader: reader),
                          CompanyWorkspaceAccessController.shared.operationStamp == stamp,
                          (try? providerOperation.check()) != nil else { return }
                    let page = try await reader.attachmentPage(offset: offset)
                    guard page.fetchedCount > 0 else { return }
                    for id in page.candidateIDs {
                        guard canArchiveFast(context: context),
                              CompanyWorkspaceAccessController.shared.operationStamp == stamp,
                              (try? providerOperation.check()) != nil,
                              !Task.isCancelled else { return }
                        var fetch = FetchDescriptor<ServiceDocumentAttachment>(predicate: #Predicate { $0.id == id })
                        fetch.fetchLimit = 2
                        let matches = try context.fetch(fetch)
                        guard matches.count <= 1 else { return }
                        if let attachment = matches.first,
                           (attachment.customer != nil || attachment.fleetVehicleID != nil),
                           attachment.needsGoogleDriveArchive {
                            await archive(attachment, context: context, stamp: stamp,
                                          providerOperation: providerOperation, reader: reader)
                        }
                    }
                    offset += page.fetchedCount
                    await Task.yield()
                }
            } catch {
                // Records remain pending in SwiftData for the next activation.
            }
        }
    }

    private func canArchiveFast(context: ModelContext) -> Bool {
        let access = CompanyWorkspaceAccessController.shared
        let actorEmail = AppAccess.normalizedEmail(AppIdentity.currentEmail)
        let hasUnsavedUserChange = context.insertedModelsArray.contains { $0 is AppUser } ||
            context.changedModelsArray.contains { $0 is AppUser } ||
            context.deletedModelsArray.contains { $0 is AppUser }
        guard !GunnAireCloudKit.usesTestDatabase,
              !hasUnsavedUserChange,
              access.authorizedContainer === context.container,
              let verifiedUser = access.verifiedUser, verifiedUser.isActive,
              AppAccess.normalizedEmail(verifiedUser.email) == actorEmail,
              access.verifiedRole == .admin,
              GoogleAuthManager.shared.googleDriveAuthorizationState == .ready,
              AppAccess.normalizedEmail(GoogleAuthManager.shared.signedInEmail) == actorEmail,
              !actorEmail.isEmpty else { return false }
        return true
    }

    private func canArchive(context: ModelContext, reader: GoogleDriveArchiveReadStore) async -> Bool {
        guard canArchiveFast(context: context),
              let stamp = CompanyWorkspaceAccessController.shared.operationStamp else { return false }
        let actorEmail = AppAccess.normalizedEmail(AppIdentity.currentEmail)
        guard (try? await reader.hasUnambiguousActiveUser(email: actorEmail)) == true else { return false }
        return canArchiveFast(context: context) &&
            CompanyWorkspaceAccessController.shared.operationStamp == stamp &&
            AppAccess.normalizedEmail(AppIdentity.currentEmail) == actorEmail
    }

    private func archive(_ attachment: ServiceDocumentAttachment, context: ModelContext,
                         stamp: CompanyWorkspaceOperationStamp,
                         providerOperation: WorkspaceProviderOperation,
                         reader: GoogleDriveArchiveReadStore) async {
        let originalID = attachment.id
        guard claim(originalID) else { return }
        defer { release(originalID) }
        let originalPath = attachment.localFilePath
        let originalBackendID = attachment.backendDocumentID
        let originalKind = attachment.kindRaw
        let originalName = attachment.displayName
        let originalType = attachment.contentType
        let originalCustomer = attachment.customer?.id
        let originalFleet = attachment.fleetVehicleID
        let actorEmail = AppIdentity.currentEmail
        func check() async throws {
            guard await canArchive(context: context, reader: reader),
                  CompanyWorkspaceAccessController.shared.operationStamp == stamp else {
                throw GoogleDriveAPIError.authorizationChanged
            }
            try providerOperation.check()
            var fetch = FetchDescriptor<ServiceDocumentAttachment>(predicate: #Predicate { $0.id == originalID })
            fetch.fetchLimit = 2
            let matches = try context.fetch(fetch)
            guard matches.count == 1, matches[0] === attachment,
                  attachment.localFilePath == originalPath,
                  attachment.backendDocumentID == originalBackendID,
                  attachment.kindRaw == originalKind,
                  attachment.displayName == originalName,
                  attachment.contentType == originalType,
                  attachment.customer?.id == originalCustomer,
                  attachment.fleetVehicleID == originalFleet else {
                throw GoogleDriveAPIError.authorizationChanged
            }
        }

        await GoogleDriveArchivePublication.run(
            attachment: attachment, context: context, actorEmail: actorEmail,
            check: check,
            reserveFileID: { try await GoogleDriveAPI.shared.generateFileID() },
            readFile: { try await self.fileData(for: attachment, context: context) },
            upload: { fileID, data in
                try await GoogleDriveAPI.shared.uploadFile(
                    fileID: fileID, displayName: originalName, mimeType: originalType,
                    attachmentID: originalID, documentKind: originalKind, data: data)
            }
        )
    }

    private func fileData(for attachment: ServiceDocumentAttachment,
                          context: ModelContext) async throws -> Data {
        let localURL = attachment.localFileURL
        if FileManager.default.fileExists(atPath: localURL.path) {
            return try await Task.detached(priority: .utility) {
                try Data(contentsOf: localURL, options: .mappedIfSafe)
            }.value
        }
        if let retained = try? await QBODocumentNativeWorkflow.retainedDataForArchive(
            for: attachment, context: context) {
            return retained
        }
        if let backendID = attachment.backendDocumentID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !backendID.isEmpty, GunnAireBackendService.isConfigured {
            return try await GunnAireBackendService.downloadDocument(id: backendID)
        }
        throw GoogleDriveAPIError.emptyFile
    }
}
