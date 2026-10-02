import Foundation
import CryptoKit
import Testing
@testable import GunnAire_Ops

actor BillingPDFArchiveTransportFixture {
    let body: Data
    private(set) var calls: [(String, String)] = []

    init(body: Data) { self.body = body }

    func send(path: String, method: String, data: Data?) throws -> Data {
        calls.append((path, method))
        guard path.hasPrefix("/api/google/drive/billing-pdf-intents"),
              (method == "GET" && data == nil) || (method == "POST" && data != nil) else {
            throw BillingPDFArchiveClientError.invalid
        }
        return body
    }
}

actor BillingPDFArchiveCheckFixture {
    private var allowed = true
    func revoke() { allowed = false }
    func check() throws {
        guard allowed else { throw BillingPDFArchiveClientError.access }
    }
}

actor BillingPDFArchiveLostReplyFixture {
    let original: Data
    private(set) var methods: [String] = []
    init(original: Data) { self.original = original }
    func send(path: String, method: String, body: Data?) throws -> Data {
        methods.append(method)
        if method == "POST" { throw BillingPDFArchiveClientError.changed }
        return original
    }
}

actor BillingPDFArtifactTransportFixture {
    let pdf: Data
    let receipt: Data
    private(set) var methods: [String] = []
    private(set) var postedDigest: String?

    init(pdf: Data, receipt: Data) { self.pdf = pdf; self.receipt = receipt }

    func send(path: String, method: String, body: Data?) throws -> Data {
        guard path.contains("/artifact") else { throw BillingPDFArchiveClientError.invalid }
        methods.append(method)
        if method == "GET" {
            guard body == nil else { throw BillingPDFArchiveClientError.invalid }
            return pdf
        }
        guard method == "POST", let body,
              let fields = try JSONSerialization.jsonObject(with: body) as? [String: String],
              let encoded = fields["dataBase64"], Data(base64Encoded: encoded) == pdf else {
            throw BillingPDFArchiveClientError.invalid
        }
        postedDigest = fields["contentDigest"]
        return receipt
    }
}

struct BillingPDFArchiveClientTests {
    private let company = UUID()
    private let replica = UUID()
    private let document = UUID()
    private let grant = UUID()
    private let attachment = UUID()
    private let lease = UUID()
    private let account = "google-subject:" + String(repeating: "a", count: 64)

    private func binding() -> CompanyCloudKitBinding {
        CompanyCloudKitBinding(companyID: company,
            containerID: GunnAireCloudKit.containerIdentifier, environment: "production",
            replicaID: replica, cloudAccountHash: String(repeating: "b", count: 64),
            approvedAt: "2026-10-02T12:00:00Z")
    }

    private func response(account: String, leaseToken: String?, fileID: String? = nil,
                          contentDigest: String? = nil, artifactBytes: Int? = nil) throws -> Data {
        let reservation: [String: Any] = [
            "key": ["company_id": company.uuidString.lowercased(), "drive_account": account,
                    "document_kind": "invoice", "document_id": document.uuidString.lowercased(),
                    "source_digest": String(repeating: "c", count: 64), "renderer_version": "customer-pdf-v1"],
            "attachment_id": attachment.uuidString.lowercased(),
            "rendered_at": "2026-10-02T12:00:00+00:00",
            "lease_token": leaseToken.map { $0 as Any } ?? NSNull(),
            "lease_until": "2026-10-02T12:05:00+00:00",
            "content_digest": contentDigest.map { $0 as Any } ?? NSNull(),
            "drive_file_id": fileID.map { $0 as Any } ?? NSNull(),
            "confirmed_link": NSNull(),
            "artifact_ready": artifactBytes != nil,
            "artifact_bytes": artifactBytes.map { $0 as Any } ?? NSNull(),
        ]
        return try JSONSerialization.data(withJSONObject: ["reservation": reservation])
    }

    @Test func serverGrantSubjectMustMatchNativeGoogleProfileBeforeReservation() throws {
        let nativeSubject = "approved-google-subject"
        let expected = "google-subject:" + CompanyWorkspaceSession.digest(nativeSubject)
        let matching = BillingPDFArchiveIdentity(companyID: company, grantID: grant, driveAccount: expected)
        try matching.validate(companyID: company, grantID: grant,
            nativeGoogleSubject: nativeSubject)
        let replacement = BillingPDFArchiveIdentity(companyID: company, grantID: grant,
            driveAccount: "google-subject:" + String(repeating: "d", count: 64))
        #expect(throws: BillingPDFArchiveClientError.connection) {
            try replacement.validate(companyID: company, grantID: grant,
                nativeGoogleSubject: nativeSubject)
        }
        #expect(throws: BillingPDFArchiveClientError.connection) {
            try matching.validate(companyID: company, grantID: UUID(),
                nativeGoogleSubject: nativeSubject)
        }
    }

    @Test func reserveAndReadRequireExactAccountBoundRevision() async throws {
        let fixture = BillingPDFArchiveTransportFixture(body: try response(
            account: account, leaseToken: lease.uuidString.lowercased()))
        let client = try BillingPDFArchiveClient(binding: binding(), grantID: grant,
            driveAccount: account, check: {}, request: { try await fixture.send(path: $0, method: $1, data: $2) })
        let reservation = try await client.reserve(kind: .invoice, documentID: document,
            sourceDigest: String(repeating: "c", count: 64), rendererVersion: "customer-pdf-v1")
        #expect(reservation.attachmentID == attachment)
        #expect(reservation.leaseToken == lease)
        let calls = await fixture.calls
        #expect(calls.count == 1)
        #expect(calls.first?.0 == "/api/google/drive/billing-pdf-intents/reserve")
        #expect(calls.first?.1 == "POST")
    }

    @Test func anotherGoogleSubjectCannotBeAdopted() async throws {
        let fixture = BillingPDFArchiveTransportFixture(body: try response(
            account: "google-subject:" + String(repeating: "d", count: 64), leaseToken: nil))
        let client = try BillingPDFArchiveClient(binding: binding(), grantID: grant,
            driveAccount: account, check: {}, request: { try await fixture.send(path: $0, method: $1, data: $2) })
        await #expect(throws: BillingPDFArchiveClientError.changed) {
            try await client.status(kind: .invoice, documentID: document,
                sourceDigest: String(repeating: "c", count: 64), rendererVersion: "customer-pdf-v1")
        }
    }

    @Test func workspaceChangeAfterRequestRejectsOtherwiseValidReply() async throws {
        let gate = BillingPDFArchiveCheckFixture()
        let body = try response(account: account, leaseToken: lease.uuidString.lowercased())
        let client = try BillingPDFArchiveClient(binding: binding(), grantID: grant,
            driveAccount: account, check: { try await gate.check() }, request: { _, _, _ in
                await gate.revoke()
                return body
            })
        await #expect(throws: BillingPDFArchiveClientError.access) {
            try await client.reserve(kind: .invoice, documentID: document,
                sourceDigest: String(repeating: "c", count: 64), rendererVersion: "customer-pdf-v1")
        }
    }

    @Test func lostReserveReplyReadsOriginalWithoutAutomaticSecondReserve() async throws {
        let fixture = BillingPDFArchiveLostReplyFixture(original: try response(
            account: account, leaseToken: nil, fileID: "saved-drive-id"))
        let client = try BillingPDFArchiveClient(binding: binding(), grantID: grant,
            driveAccount: account, check: {}, request: { try await fixture.send(path: $0, method: $1, body: $2) })
        await #expect(throws: BillingPDFArchiveClientError.changed) {
            try await client.reserve(kind: .invoice, documentID: document,
                sourceDigest: String(repeating: "c", count: 64), rendererVersion: "customer-pdf-v1")
        }
        let recovered = try await client.status(kind: .invoice, documentID: document,
            sourceDigest: String(repeating: "c", count: 64), rendererVersion: "customer-pdf-v1")
        #expect(recovered?.driveFileID == "saved-drive-id")
        #expect(await fixture.methods == ["POST", "GET"])
    }

    @Test func schemaTwoUploadMetadataPinsRevisionAndContent() throws {
        let decoded = try JSONDecoder().decode(BillingPDFArchiveResponse.self, from: response(
            account: account, leaseToken: lease.uuidString.lowercased(), fileID: "saved-drive-id"))
        guard let original = decoded.reservation else { throw BillingPDFArchiveClientError.invalid }
        let reservation = BillingPDFArchiveReservation(
            key: original.key, attachmentID: original.attachmentID, renderedAt: original.renderedAt,
            leaseToken: original.leaseToken, leaseUntil: original.leaseUntil,
            contentDigest: String(repeating: "e", count: 64), driveFileID: original.driveFileID,
            confirmedLink: nil, artifactReady: true, artifactBytes: 12)
        let metadata = try GoogleDriveUploadMetadata.automaticBillingPDF(
            reservation: reservation, displayName: "Invoice.pdf")
        let unretained = BillingPDFArchiveReservation(
            key: original.key, attachmentID: original.attachmentID, renderedAt: original.renderedAt,
            leaseToken: original.leaseToken, leaseUntil: original.leaseUntil,
            contentDigest: String(repeating: "e", count: 64), driveFileID: original.driveFileID,
            confirmedLink: nil, artifactReady: false, artifactBytes: nil)
        #expect(throws: GoogleDriveAPIError.authorizationChanged) {
            try GoogleDriveUploadMetadata.automaticBillingPDF(
                reservation: unretained, displayName: "Invoice.pdf")
        }
        #expect(metadata.appProperties["gunnaireSchema"] == "2")
        #expect(metadata.appProperties["gunnaireDocumentID"] == document.uuidString.lowercased())
        #expect(metadata.appProperties["gunnaireSourceDigest"] == String(repeating: "c", count: 64))
        #expect(metadata.appProperties["gunnaireContentSHA256"] == String(repeating: "e", count: 64))
        let matching = GoogleDriveFile(id: "saved-drive-id", name: "Invoice.pdf",
            mimeType: "application/pdf", webViewLink: nil, trashed: false,
            appProperties: metadata.appProperties)
        #expect(matching.matchesArchiveIdentity(metadata))
        var changed = metadata.appProperties
        changed["gunnaireSourceDigest"] = String(repeating: "f", count: 64)
        let wrongRevision = GoogleDriveFile(id: "saved-drive-id", name: "Invoice.pdf",
            mimeType: "application/pdf", webViewLink: nil, trashed: false,
            appProperties: changed)
        #expect(!wrongRevision.matchesArchiveIdentity(metadata))
    }

    @Test func serverArtifactTransportProvesExactBytesAndAllowsReadback() async throws {
        let pdf = Data("%PDF-1.7\ncustomer revision\n%%EOF\n".utf8)
        let digest = SHA256.hash(data: pdf).map { String(format: "%02x", $0) }.joined()
        let base = try response(account: account, leaseToken: lease.uuidString.lowercased())
        guard let object = try JSONSerialization.jsonObject(with: base) as? [String: Any],
              var reservationObject = object["reservation"] as? [String: Any] else {
            throw BillingPDFArchiveClientError.invalid
        }
        reservationObject["content_digest"] = digest
        reservationObject["artifact_ready"] = true
        reservationObject["artifact_bytes"] = pdf.count
        let receipt = try JSONSerialization.data(withJSONObject: [
            "reservation": reservationObject,
            "artifact": ["fileSizeBytes": pdf.count, "fileSHA256": digest]
        ])
        let fixture = BillingPDFArtifactTransportFixture(pdf: pdf, receipt: receipt)
        let client = try BillingPDFArchiveClient(binding: binding(), grantID: grant,
            driveAccount: account, check: {}, request: {
                try await fixture.send(path: $0, method: $1, body: $2)
            })
        let reservation = try JSONDecoder().decode(BillingPDFArchiveResponse.self, from: base)
        guard let saved = reservation.reservation else { throw BillingPDFArchiveClientError.invalid }
        let stored = try await client.storeArtifact(pdf, for: saved)
        #expect(stored.contentDigest == digest)
        #expect(await fixture.postedDigest == digest)
        let recovered = try await client.readArtifact(for: stored)
        #expect(recovered == pdf)
        #expect(await fixture.methods == ["POST", "GET"])
    }

    @Test func artifactAccountMismatchAndChangedBytesFailBeforeNetwork() async throws {
        let pdf = Data("%PDF-1.7\ncustomer revision\n%%EOF\n".utf8)
        let fixture = BillingPDFArchiveTransportFixture(body: Data())
        let client = try BillingPDFArchiveClient(binding: binding(), grantID: grant,
            driveAccount: account, check: {}, request: {
                try await fixture.send(path: $0, method: $1, data: $2)
            })
        let base = try response(account: account, leaseToken: lease.uuidString.lowercased(),
            contentDigest: String(repeating: "d", count: 64), artifactBytes: pdf.count)
        guard let saved = try JSONDecoder().decode(BillingPDFArchiveResponse.self, from: base).reservation else {
            throw BillingPDFArchiveClientError.invalid
        }
        await #expect(throws: BillingPDFArchiveClientError.changed) {
            try await client.storeArtifact(pdf, for: saved)
        }
        let wrong = try response(account: "google-subject:" + String(repeating: "e", count: 64),
            leaseToken: lease.uuidString.lowercased())
        guard let otherAccount = try JSONDecoder().decode(BillingPDFArchiveResponse.self,
            from: wrong).reservation else { throw BillingPDFArchiveClientError.invalid }
        await #expect(throws: BillingPDFArchiveClientError.changed) {
            try await client.storeArtifact(pdf, for: otherAccount)
        }
        #expect(await fixture.calls.isEmpty)
    }

    @Test func lostArtifactReplyRecoversByExactReadWithoutSecondWrite() async throws {
        let pdf = Data("%PDF-1.7\ncustomer revision\n%%EOF\n".utf8)
        let digest = SHA256.hash(data: pdf).map { String(format: "%02x", $0) }.joined()
        let fixture = BillingPDFArchiveLostReplyFixture(original: pdf)
        let client = try BillingPDFArchiveClient(binding: binding(), grantID: grant,
            driveAccount: account, check: {}, request: {
                try await fixture.send(path: $0, method: $1, body: $2)
            })
        let base = try response(account: account, leaseToken: lease.uuidString.lowercased(),
            contentDigest: digest, artifactBytes: pdf.count)
        guard let saved = try JSONDecoder().decode(BillingPDFArchiveResponse.self, from: base).reservation else {
            throw BillingPDFArchiveClientError.invalid
        }
        await #expect(throws: BillingPDFArchiveClientError.changed) {
            try await client.storeArtifact(pdf, for: saved)
        }
        let recovered = try await client.readArtifact(for: saved)
        #expect(recovered == pdf)
        #expect(await fixture.methods == ["POST", "GET"])
    }

}
