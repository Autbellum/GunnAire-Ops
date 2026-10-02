import Foundation
import CryptoKit
import SwiftData

/// Read-only counterpart of the encrypted QBO journal. The owner key is
/// captured from the current workspace before dispatch and checked again by
/// the caller before any returned bytes can leave the device.
nonisolated struct QBODocumentRetainedMediaReader: Sendable {
    nonisolated struct Result: Sendable {
        let metadata: Data
        let bytes: Data
        let sha256: String
    }

    let container: ModelContainer
    let directory: URL
    let loadKey: @Sendable () throws -> Data
    let afterSnapshot: @Sendable () async -> Void

    init(container: ModelContainer, directory: URL,
         loadKey: @escaping @Sendable () throws -> Data = {
             guard let key = try KeychainStore.loadCodable(Data.self,
                                                           account: "QBOOriginalFileEncryption-v1") else {
                 throw QBODocumentError.storage
             }
             return key
         },
         afterSnapshot: @escaping @Sendable () async -> Void = {}) {
        self.container = container
        self.directory = directory
        self.loadKey = loadKey
        self.afterSnapshot = afterSnapshot
    }

    func read(ownerStorageKey: String, actorEmail: String, attachmentID: UUID) async throws -> Result {
        try await Task.detached(priority: .utility) {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let email = AppAccess.normalizedEmail(actorEmail)
            let users = try context.fetch(FetchDescriptor<AppUser>())
            let matching = users.filter { AppAccess.normalizedEmail($0.email) == email }
            guard !email.isEmpty, !matching.isEmpty,
                  matching.allSatisfy({ $0.isActive && $0.roleRawValue == AppUserRole.admin.rawValue }) else {
                throw QBODocumentError.access
            }
            let media = try Self.readJournal(directory: directory, ownerStorageKey: ownerStorageKey,
                                             attachmentID: attachmentID, loadKey: loadKey)
            try Self.validateOriginal(metadata: media.metadata, attachmentID: attachmentID, context: context)
            await afterSnapshot()
            let fresh = ModelContext(container)
            fresh.autosaveEnabled = false
            let currentUsers = try fresh.fetch(FetchDescriptor<AppUser>())
                .filter { AppAccess.normalizedEmail($0.email) == email }
            guard !currentUsers.isEmpty,
                  currentUsers.allSatisfy({ $0.isActive && $0.roleRawValue == AppUserRole.admin.rawValue }) else {
                throw QBODocumentError.access
            }
            try Self.validateOriginal(metadata: media.metadata, attachmentID: attachmentID, context: fresh)
            return media
        }.value
    }

    private static func readJournal(directory: URL, ownerStorageKey: String,
                                    attachmentID: UUID,
                                    loadKey: @Sendable () throws -> Data) throws -> Result {
        guard ownerStorageKey.count == 64,
              ownerStorageKey.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let key = try? loadKey(), key.count == 32 else { throw QBODocumentError.storage }
        let folder = directory.appendingPathComponent(ownerStorageKey, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { throw QBODocumentError.review }
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "sealed" }
        guard urls.count <= 512 else { throw QBODocumentError.limit }
        let symmetricKey = SymmetricKey(data: key)
        var match: Result?
        for url in urls {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  url.lastPathComponent == id.uuidString.lowercased() + ".sealed" else {
                throw QBODocumentError.storage
            }
            let properties = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard properties.isRegularFile == true, properties.isSymbolicLink != true,
                  let size = properties.fileSize, size <= QBODocumentFileInfo.maximum + 65_536,
                  size >= 68 else { throw QBODocumentError.storage }
            let handle = try FileHandle(forReadingFrom: url)
            let file: Data
            do {
                defer { try? handle.close() }
                guard let loaded = try handle.read(upToCount: QBODocumentFileInfo.maximum + 65_537),
                      loaded.count == size else { throw QBODocumentError.storage }
                file = loaded
            }
            guard file.count >= 12, file.prefix(8) == Data("GAFILE1\n".utf8) else { throw QBODocumentError.storage }
            let headerSize = file[8..<12].reduce(0) { ($0 << 8) | Int($1) }
            guard (28...32_768).contains(headerSize), file.count >= 12 + headerSize + 28 else {
                throw QBODocumentError.storage
            }
            let metadataAAD = Data((ownerStorageKey + "/" + id.uuidString.lowercased() + "/metadata").utf8)
            let encryptedMetadata = Data(file[12..<(12 + headerSize)])
            let metadata: Data
            do {
                metadata = try AES.GCM.open(AES.GCM.SealedBox(combined: encryptedMetadata),
                                            using: symmetricKey, authenticating: metadataAAD)
            } catch { throw QBODocumentError.storage }
            guard let json = try JSONSerialization.jsonObject(with: metadata) as? [String: Any],
                  uuid(json["id"]) == id,
                  let fileInfo = json["file"] as? [String: Any],
                  let recordedSize = fileInfo["size"] as? Int,
                  (1...QBODocumentFileInfo.maximum).contains(recordedSize),
                  file.count == 12 + headerSize + recordedSize + 28 else {
                throw QBODocumentError.storage
            }
            let local = json["localAttachment"] as? [String: Any]
            let job = json["jobDocument"] as? [String: Any]
            guard let rawID = (local ?? job)?["attachmentID"] as? String,
                  let recordedID = UUID(uuidString: rawID) else { continue }
            guard recordedID == attachmentID else { continue }
            guard match == nil else { throw QBODocumentError.changed }
            let fileAAD = Data((ownerStorageKey + "/" + id.uuidString.lowercased() + "/file").utf8)
            let encryptedBytes = Data(file[(12 + headerSize)...])
            let bytes: Data
            do {
                bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: encryptedBytes),
                                         using: symmetricKey, authenticating: fileAAD)
            } catch { throw QBODocumentError.storage }
            guard bytes.count == recordedSize else { throw QBODocumentError.storage }
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            guard digest == fileInfo["sha256"] as? String else { throw QBODocumentError.storage }
            match = Result(metadata: metadata, bytes: bytes, sha256: digest)
        }
        guard let match else { throw QBODocumentError.review }
        return match
    }

    private static func validateOriginal(metadata: Data, attachmentID: UUID,
                                         context: ModelContext) throws {
        guard let row = try JSONSerialization.jsonObject(with: metadata) as? [String: Any],
              let file = row["file"] as? [String: Any],
              let targets = row["targets"] as? [[String: Any]] else { throw QBODocumentError.storage }
        let files = try context.fetch(FetchDescriptor<ServiceDocumentAttachment>())
            .filter { $0.id == attachmentID }
        guard files.count == 1, let attachment = files.first, !attachment.isDeleted,
              !FileManager.default.fileExists(atPath: attachment.localFilePath),
              let customer = attachment.customer else { throw QBODocumentError.changed }
        let customers = try context.fetch(FetchDescriptor<Customer>())
        guard customers.filter({ $0.id == customer.id }).count == 1,
              customers.contains(where: { $0 === customer }),
              allowedQuickBooksKind(attachment.kindRaw),
              let customerReference = normalizedReference(customer.quickBooksID),
              file["size"] as? Int == attachment.fileSizeBytes,
              file["contentType"] as? String == attachment.contentType,
              file["filename"] as? String == retainedFilename(attachment) else {
            throw QBODocumentError.changed
        }
        if let local = row["localAttachment"] as? [String: Any] {
            guard uuid(local["attachmentID"]) == attachmentID,
                  uuid(local["customerID"]) == customer.id,
                  local["customerQuickBooksID"] as? String == customerReference,
                  uuid(local["serviceCallID"]) == attachment.serviceCallID,
                  uuid(local["invoiceID"]) == attachment.invoiceID,
                  uuid(local["estimateID"]) == attachment.estimateID,
                  local["kind"] as? String == attachment.kindRaw else {
                throw QBODocumentError.changed
            }
        }
        let invoices = try context.fetch(FetchDescriptor<Invoice>())
        let estimates = try context.fetch(FetchDescriptor<Estimate>())
        var expectedDocuments: [(type: String, localID: UUID, id: String)] = []
        for target in targets {
            guard let type = target["type"] as? String,
                  let providerID = target["id"] as? String else { throw QBODocumentError.changed }
            switch type {
            case "Invoice":
                guard let id = attachment.invoiceID,
                      let invoice = uniqueInvoice(id: id, invoices: invoices),
                      invoice.customer === customer,
                      invoice.quickBooksIdentityReviewMessage == nil,
                      normalizedReference(invoice.quickBooksID) == providerID,
                      attachment.serviceCallID == nil || invoice.serviceCallID == nil ||
                        attachment.serviceCallID == invoice.serviceCallID else {
                    throw QBODocumentError.changed
                }
                expectedDocuments.append((type, id, providerID))
            case "Estimate":
                guard let id = attachment.estimateID,
                      let estimate = uniqueEstimate(id: id, estimates: estimates),
                      estimate.customer === customer,
                      normalizedReference(estimate.quickBooksID) == providerID,
                      attachment.serviceCallID == nil || estimate.serviceCallID == nil ||
                        attachment.serviceCallID == estimate.serviceCallID ||
                        attachment.serviceCallID == estimate.scheduledServiceCallID else {
                    throw QBODocumentError.changed
                }
                expectedDocuments.append((type, id, providerID))
            default:
                throw QBODocumentError.changed
            }
        }
        guard !expectedDocuments.isEmpty else { throw QBODocumentError.changed }
        if let callID = attachment.serviceCallID {
            let calls = try context.fetch(FetchDescriptor<ServiceCall>()).filter { $0.id == callID }
            guard calls.count == 1, calls[0].customer === customer,
                  let job = row["jobDocument"] as? [String: Any],
                  uuid(job["attachmentID"]) == attachmentID,
                  uuid(job["serviceCallID"]) == callID,
                  uuid(job["localCustomerID"]) == customer.id,
                  job["customerQuickBooksID"] as? String == customerReference,
                  job["kind"] as? String == attachment.kindRaw,
                  job["stage"] as? String == stage(attachment.kindRaw),
                  let documents = job["documents"] as? [[String: Any]],
                  documents.count == expectedDocuments.count else {
                throw QBODocumentError.changed
            }
            for (saved, expected) in zip(documents, expectedDocuments) {
                guard saved["type"] as? String == expected.type,
                      uuid(saved["localID"]) == expected.localID,
                      saved["id"] as? String == expected.id else { throw QBODocumentError.changed }
            }
        } else if row["jobDocument"] is [String: Any] {
            throw QBODocumentError.changed
        }
    }

    private static func uuid(_ value: Any?) -> UUID? {
        (value as? String).flatMap(UUID.init(uuidString:))
    }

    private static func normalizedReference(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func retainedFilename(_ attachment: ServiceDocumentAttachment) -> String {
        let name = attachment.displayName
        let path = URL(fileURLWithPath: attachment.localFilePath)
        if (name as NSString).pathExtension.isEmpty, !path.pathExtension.isEmpty {
            return name + "." + path.pathExtension
        }
        return name
    }

    private static func allowedQuickBooksKind(_ kind: String) -> Bool {
        ["service_report", "before_photo", "after_photo", "diagnostic_photo",
         "equipment_data_plate_photo", "warranty_evidence", "customer_document",
         "invoice_support", "estimate_support", "other", "receipt"].contains(kind)
    }

    private static func stage(_ kind: String) -> String {
        kind == "before_photo" ? "before" : kind == "after_photo" ? "after" : "supporting"
    }

    private static func uniqueInvoice(id: UUID, invoices: [Invoice]) -> Invoice? {
        let matches = invoices.filter { $0.id == id }
        guard matches.count == 1, let invoice = matches.first else { return nil }
        if let providerID = normalizedReference(invoice.quickBooksID),
           invoices.filter({ normalizedReference($0.quickBooksID) == providerID }).count != 1 {
            return nil
        }
        return invoice
    }

    private static func uniqueEstimate(id: UUID, estimates: [Estimate]) -> Estimate? {
        let matches = estimates.filter { $0.id == id }
        guard matches.count == 1, let estimate = matches.first else { return nil }
        if let providerID = normalizedReference(estimate.quickBooksID),
           estimates.filter({ normalizedReference($0.quickBooksID) == providerID }).count != 1 {
            return nil
        }
        return estimate
    }
}
