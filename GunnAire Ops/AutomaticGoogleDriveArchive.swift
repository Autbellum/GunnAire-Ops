import Foundation
import SwiftData

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

    func recover(context: ModelContext) {
        guard canArchive(context: context),
              let stamp = CompanyWorkspaceAccessController.shared.operationStamp else { return }
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
                var offset = 0
                while !Task.isCancelled {
                    var fetch = FetchDescriptor<ServiceDocumentAttachment>(
                        sortBy: [SortDescriptor(\.createdAt, order: .forward), SortDescriptor(\.id)])
                    fetch.fetchLimit = 100
                    fetch.fetchOffset = offset
                    let page = try context.fetch(fetch)
                    guard !page.isEmpty else { return }
                    for attachment in page where
                        (attachment.customer != nil || attachment.fleetVehicleID != nil) &&
                            attachment.needsGoogleDriveArchive {
                        guard canArchive(context: context),
                              CompanyWorkspaceAccessController.shared.operationStamp == stamp,
                              !Task.isCancelled else { return }
                        await archive(attachment, context: context, stamp: stamp)
                    }
                    offset += page.count
                    await Task.yield()
                }
            } catch {
                // Records remain pending in SwiftData for the next activation.
            }
        }
    }

    private func canArchive(context: ModelContext) -> Bool {
        guard !GunnAireCloudKit.usesTestDatabase,
              CompanyWorkspaceAccessController.shared.authorizedContainer === context.container,
              CompanyWorkspaceAccessController.shared.verifiedRole == .admin,
              GoogleAuthManager.shared.googleDriveAuthorizationState == .ready,
              let users = try? context.fetch(FetchDescriptor<AppUser>()),
              AppAccess.canArchiveBusinessDocumentsToGoogleDrive(
                email: AppIdentity.currentEmail, users: users) else { return false }
        return true
    }

    private func archive(_ attachment: ServiceDocumentAttachment, context: ModelContext,
                         stamp: CompanyWorkspaceOperationStamp) async {
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
        var operation: WorkspaceProviderOperation?

        func check() throws {
            guard canArchive(context: context),
                  CompanyWorkspaceAccessController.shared.operationStamp == stamp else {
                throw GoogleDriveAPIError.authorizationChanged
            }
            try operation?.check()
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

        do {
            operation = try GoogleAuthManager.shared.captureProviderOperation()
            try check()
            let fileID: String
            if let reserved = attachment.googleDriveFileID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !reserved.isEmpty {
                fileID = reserved
            } else {
                fileID = try await GoogleDriveAPI.shared.generateFileID()
                try check()
                attachment.markGoogleDrivePreparing(fileID: fileID, actorEmail: actorEmail)
                try context.save()
            }
            let data = try await fileData(for: attachment, context: context)
            try check()
            guard !data.isEmpty else { throw GoogleDriveAPIError.emptyFile }
            attachment.markGoogleDriveUploading()
            try context.save()
            let file = try await GoogleDriveAPI.shared.uploadFile(
                fileID: fileID, displayName: originalName, mimeType: originalType,
                attachmentID: originalID, documentKind: originalKind, data: data)
            try check()
            attachment.markGoogleDriveArchived(file, actorEmail: actorEmail)
            try context.save()
        } catch {
            guard (try? check()) != nil else { return }
            attachment.markGoogleDriveArchiveFailed(error.localizedDescription,
                discardReservedID: (error as? GoogleDriveAPIError)?.discardsReservedFileIDBeforeRetry == true)
            try? context.save()
        }
    }

    private func fileData(for attachment: ServiceDocumentAttachment,
                          context: ModelContext) async throws -> Data {
        let localURL = attachment.localFileURL
        if FileManager.default.fileExists(atPath: localURL.path) {
            return try await Task.detached(priority: .utility) {
                try Data(contentsOf: localURL, options: .mappedIfSafe)
            }.value
        }
        if let (_, retained) = try? QBODocumentNativeWorkflow.retainedData(for: attachment, context: context) {
            return retained
        }
        if let backendID = attachment.backendDocumentID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !backendID.isEmpty, GunnAireBackendService.isConfigured {
            return try await GunnAireBackendService.downloadDocument(id: backendID)
        }
        throw GoogleDriveAPIError.emptyFile
    }
}
