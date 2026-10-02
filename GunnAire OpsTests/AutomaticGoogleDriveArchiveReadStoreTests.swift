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

    @Test func fleetOnlyArchiveFailureStaysInVisibleRecoveryQueue() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let customer = Customer(name: "Drive queue fixture")
        let customerPending = ServiceDocumentAttachment(customer: customer, serviceCallID: nil,
            kind: .serviceReport, displayName: "customer.pdf", localFilePath: "/tmp/customer.pdf",
            contentType: "application/pdf", fileSizeBytes: 12)
        let fleetPending = ServiceDocumentAttachment(customer: nil, serviceCallID: nil,
            fleetVehicleID: UUID(), kind: .fleetService, displayName: "fleet.pdf",
            localFilePath: "/tmp/fleet.pdf", contentType: "application/pdf", fileSizeBytes: 12)
        fleetPending.markGoogleDriveArchiveFailed("Connection interrupted")
        let unowned = ServiceDocumentAttachment(customer: nil, serviceCallID: nil,
            kind: .other, displayName: "unowned.pdf", localFilePath: "/tmp/unowned.pdf",
            contentType: "application/pdf", fileSizeBytes: 12)
        let archived = ServiceDocumentAttachment(customer: customer, serviceCallID: nil,
            kind: .customerDocument, displayName: "archived.pdf", localFilePath: "/tmp/archived.pdf",
            contentType: "application/pdf", fileSizeBytes: 12,
            googleDriveFileID: "confirmed", googleDriveWebViewLink: "https://drive.google.com/file/d/confirmed/view",
            googleDriveSyncStatus: GoogleDriveDocumentSyncState.archived.rawValue)
        context.insert(customer)
        for attachment in [customerPending, fleetPending, unowned, archived] {
            context.insert(attachment)
        }
        try context.save()

        let pending = GoogleDriveArchiveQueue.pending(from: [customerPending, fleetPending, unowned, archived])
        #expect(Set(pending.map(\.id)) == Set([customerPending.id, fleetPending.id]))
        #expect(pending.filter { $0.googleDriveSyncState == .needsAttention }.map(\.id) == [fleetPending.id])
        #expect(GoogleDriveArchiveQueue.pending(from: [fleetPending]).count == 1)
    }

    @Test func retainedReservationReconcilesOneConfirmedUploadAfterReconnect() async throws {
        let container = try makeContainer()
        let firstContext = ModelContext(container)
        let customer = Customer(name: "Drive reconnect fixture")
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("drive-reconnect-\(UUID().uuidString).txt")
        let bytes = Data("fictional service report".utf8)
        try bytes.write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }
        let attachment = ServiceDocumentAttachment(
            customer: customer, serviceCallID: nil, kind: .serviceReport,
            displayName: "report.txt", localFilePath: localURL.path,
            contentType: "text/plain", fileSizeBytes: bytes.count)
        firstContext.insert(customer)
        firstContext.insert(attachment)
        try firstContext.save()

        let email = "drive-fixture@gunnaire.com"
        let fileID = "reserved-drive-reconnect"
        let metadata = GoogleDriveUploadMetadata.document(
            fileID: fileID, displayName: attachment.displayName,
            mimeType: attachment.contentType, attachmentID: attachment.id,
            documentKind: attachment.kindRaw)
        let file = GoogleDriveFile(
            id: fileID, name: metadata.name, mimeType: metadata.mimeType,
            webViewLink: "https://drive.google.com/file/d/\(fileID)/view",
            trashed: false, appProperties: metadata.appProperties)
        var remoteFile: GoogleDriveFile?
        var acceptedWrites = 0
        var reservations = 0
        var uploadCalls = 0
        var requests: [URLRequest] = []
        let auth = GoogleAuthManager(
            testTokens: GoogleOAuthTokens(
                accessToken: "fixture-bearer", refreshToken: "fixture-refresh", idToken: nil,
                expiration: .distantFuture,
                scopeSignature: Config.Google.scopeSignature(for: [Config.Google.driveFileScope])),
            email: email, businessEmail: { email },
            transport: { _ in throw URLError(.unsupportedURL) })
        let drive = GoogleDriveAPI(authManager: auth, transport: { request in
            requests.append(request)
            guard let url = request.url,
                  let response = HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
                throw GoogleDriveAPIError.invalidResponse
            }
            if url.path == "/drive/v3/files/generateIds" {
                reservations += 1
                return (Data(#"{"ids":["reserved-drive-reconnect"]}"#.utf8), response)
            }
            if request.httpMethod == "GET", url.path == "/drive/v3/files/\(fileID)" {
                if let remoteFile {
                    return (try JSONEncoder().encode(remoteFile), response)
                }
                guard let missing = HTTPURLResponse(
                    url: url, statusCode: 404, httpVersion: nil, headerFields: nil) else {
                    throw GoogleDriveAPIError.invalidResponse
                }
                return (Data(), missing)
            }
            if request.httpMethod == "POST", url.path == "/upload/drive/v3/files" {
                guard let started = HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil,
                    headerFields: ["Location": "https://www.googleapis.com/upload/drive/v3/files?upload_id=fixture"]) else {
                    throw GoogleDriveAPIError.invalidResponse
                }
                return (Data(), started)
            }
            if request.httpMethod == "PUT", request.httpBody == bytes {
                acceptedWrites += 1
                remoteFile = file
                throw URLError(.networkConnectionLost)
            }
            if request.httpMethod == "PUT",
               request.value(forHTTPHeaderField: "Content-Range") == "bytes */\(bytes.count)" {
                throw URLError(.networkConnectionLost)
            }
            Issue.record("Unexpected Drive request during recovery: \(request.httpMethod ?? "unknown") \(url.path)")
            throw GoogleDriveAPIError.invalidResponse
        })

        func publish(_ saved: ServiceDocumentAttachment, in context: ModelContext) async {
            await GoogleDriveArchivePublication.run(
                attachment: saved, context: context, actorEmail: email,
                check: {
                    guard saved.needsGoogleDriveArchive else {
                        throw GoogleDriveAPIError.authorizationChanged
                    }
                },
                reserveFileID: { try await drive.generateFileID() },
                readFile: { try Data(contentsOf: saved.localFileURL) },
                upload: { reservedID, body in
                    uploadCalls += 1
                    return try await drive.uploadFile(
                        fileID: reservedID, displayName: saved.displayName,
                        mimeType: saved.contentType, attachmentID: saved.id,
                        documentKind: saved.kindRaw, data: body)
                })
        }

        await publish(attachment, in: firstContext)
        #expect(attachment.googleDriveFileID == fileID)
        #expect(attachment.googleDriveSyncState == .needsAttention)
        #expect(attachment.needsGoogleDriveArchive)
        #expect(reservations == 1)
        #expect(acceptedWrites == 1)

        let restoredContext = ModelContext(container)
        let attachmentID = attachment.id
        let pendingPage = try await GoogleDriveArchiveReadStore(container: container).attachmentPage(offset: 0)
        #expect(pendingPage.candidateIDs == [attachmentID])
        var fetch = FetchDescriptor<ServiceDocumentAttachment>(predicate: #Predicate { $0.id == attachmentID })
        fetch.fetchLimit = 2
        let restoredMatches = try restoredContext.fetch(fetch)
        #expect(restoredMatches.count == 1)
        let restored = try #require(restoredMatches.first)
        #expect(restored.googleDriveFileID == fileID)
        await publish(restored, in: restoredContext)
        #expect(restored.googleDriveSyncState == .archived)
        #expect(restored.googleDriveFileID == fileID)
        #expect(restored.googleDriveWebURL?.host == "drive.google.com")
        #expect(!restored.needsGoogleDriveArchive)
        #expect(reservations == 1)
        #expect(acceptedWrites == 1)
        #expect(uploadCalls == 2)

        let requestCount = requests.count
        await publish(restored, in: restoredContext)
        #expect(requests.count == requestCount)
    }
}
