import Foundation
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

    private func response(account: String, leaseToken: String?, fileID: String? = nil) throws -> Data {
        let reservation: [String: Any] = [
            "key": ["company_id": company.uuidString.lowercased(), "drive_account": account,
                    "document_kind": "invoice", "document_id": document.uuidString.lowercased(),
                    "source_digest": String(repeating: "c", count: 64), "renderer_version": "customer-pdf-v1"],
            "attachment_id": attachment.uuidString.lowercased(),
            "rendered_at": "2026-10-02T12:00:00+00:00",
            "lease_token": leaseToken.map { $0 as Any } ?? NSNull(),
            "lease_until": "2026-10-02T12:05:00+00:00",
            "content_digest": NSNull(),
            "drive_file_id": fileID.map { $0 as Any } ?? NSNull(),
            "confirmed_link": NSNull(),
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
            confirmedLink: nil)
        let metadata = try GoogleDriveUploadMetadata.automaticBillingPDF(
            reservation: reservation, displayName: "Invoice.pdf")
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

}
