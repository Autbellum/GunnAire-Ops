import Foundation
import XCTest
@testable import GunnAire_Ops

@MainActor final class CompanyDocumentContentTests: XCTestCase {
    let identifier = "7ee32599-b8f6-448d-939a-295a90d33577"
    let bytes = Data("original-file".utf8)
    func proof() -> CompanyDocumentContentProof {
        .init(schema: CompanyDocumentContentProof.schema, id: identifier, filename: "Report.pdf", contentType: "application/pdf",
              fileSizeBytes: bytes.count, fileSHA256: QBODocumentFileInfo.hash(bytes), createdAt: "2026-09-10T10:00:00Z")
    }
    func encoded(_ value: CompanyDocumentContentProof) throws -> Data { try StaffWorkspacePublicationContract.encode(value) }
    func altered(_ changes: [String: Any]) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded(proof())) as? [String: Any])
        for (key, value) in changes { object[key] = value }
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testVerifiedDownloadUsesExactProofSizeThenRechecksBinding() async throws {
        var calls: [(String, Int)] = []
        let c = CompanyDocumentContentClient(request: { path, maximum in
            calls.append((path, maximum))
            return path.hasSuffix("/manifest") ? try self.encoded(self.proof()) : self.bytes
        }, check: {})
        let result = try await c.download(id: identifier)
        XCTAssertEqual(result, bytes); XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls.map(\.1), [8192, bytes.count, 8192])
        XCTAssertTrue(calls.allSatisfy { CompanyDocumentContentClient.allows($0.0, maximum: $0.1) })
    }

    func testSameLengthReplacedResponseNeverReturnsOrRequestsFinalManifest() async throws {
        var calls = 0
        let c = CompanyDocumentContentClient(request: { _, _ in
            calls += 1; return calls == 1 ? try self.encoded(self.proof()) : Data("modified-file".utf8)
        }, check: {})
        do { _ = try await c.download(id: identifier); XCTFail() }
        catch { XCTAssertEqual(calls, 2) }
    }

    func testChangedFinalManifestNeverRelabelsVerifiedBytes() async throws {
        for changes in [["filename": "Different.pdf"], ["id": UUID().uuidString.lowercased()], ["fileSHA256": String(repeating: "a", count: 64)]] {
            var calls = 0
            let c = CompanyDocumentContentClient(request: { _, _ in
                calls += 1
                return calls == 1 ? try self.encoded(self.proof()) : calls == 2 ? self.bytes : try self.altered(changes)
            }, check: {})
            do { _ = try await c.download(id: identifier); XCTFail() } catch {}
            XCTAssertEqual(calls, 3)
        }
    }

    func testMissingMalformedOrUnknownProofFailsBeforeAnyBytesRequest() async throws {
        for changes in [["fileSHA256": NSNull()], ["fileSHA256": String(repeating: "A", count: 64)],
                        ["fileSizeBytes": true], ["fileSizeBytes": 0], ["fileSizeBytes": 64 * 1024 * 1024 + 1],
                        ["unknown": NSNull()], ["schema": "company-document-content-v0"],
                        ["filename": "../report.pdf"], ["contentType": "text/plain\r\nX: leaked"]] as [[String: Any]] {
            var calls = 0
            let c = CompanyDocumentContentClient(request: { _, _ in calls += 1; return try self.altered(changes) }, check: {})
            do { _ = try await c.download(id: identifier); XCTFail("Malformed proof accepted") } catch {}
            XCTAssertEqual(calls, 1)
        }
    }

    func testRevocationAfterEveryReplyNeverReleasesDocument() async throws {
        for boundary in 1...3 {
            var calls = 0, allowed = true
            let c = CompanyDocumentContentClient(request: { path, _ in
                calls += 1
                if calls == boundary { allowed = false }
                return path.hasSuffix("/manifest") ? try self.encoded(self.proof()) : self.bytes
            }, check: { if !allowed { throw CompanyDocumentContentError.access } })
            do { _ = try await c.download(id: identifier); XCTFail() } catch {}
            XCTAssertEqual(calls, boundary)
        }
    }

    func testTruncatedOrOversizedBytesDoNotPassHashVerification() async throws {
        for changed in [Data(bytes.dropLast()), bytes + Data([0])] {
            let c = CompanyDocumentContentClient(request: { path, _ in
                path.hasSuffix("/manifest") ? try self.encoded(self.proof()) : changed
            }, check: {})
            do { _ = try await c.download(id: identifier); XCTFail() } catch {}
        }
    }

    func testStrictPathPolicyHasNoProviderURLsTraversalOrQueryBypass() throws {
        let valid = try CompanyDocumentContentClient.path(id: identifier, manifest: true)
        XCTAssertTrue(CompanyDocumentContentClient.allows(valid, maximum: 8192))
        for path in ["https://example.invalid" + valid, valid + "/", valid + "?x=1", valid + "#fragment",
                     valid.replacingOccurrences(of: identifier, with: "%37" + identifier.dropFirst()),
                     valid.replacingOccurrences(of: identifier, with: ".."), valid.replacingOccurrences(of: "manifest", with: "upload")] {
            XCTAssertFalse(CompanyDocumentContentClient.allows(path, maximum: 8192))
        }
        XCTAssertFalse(CompanyDocumentContentClient.allows(valid, maximum: 8193))
        for id in ["", "../file", identifier.uppercased(), "a/b"] {
            XCTAssertThrowsError(try CompanyDocumentContentClient.path(id: id, manifest: false))
        }
    }

    func testWrittenPreviewProofRejectsSameSizeReplacementAndSymbolicLinks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DocumentProof-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Report.pdf")
        try bytes.write(to: url)
        try CompanyDocumentContentProof.verifyFile(url, size: bytes.count, sha256: proof().fileSHA256)
        try Data("modified-file".utf8).write(to: url)
        XCTAssertThrowsError(try CompanyDocumentContentProof.verifyFile(url, size: bytes.count, sha256: proof().fileSHA256))
        let link = directory.appendingPathComponent("Link.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        XCTAssertThrowsError(try CompanyDocumentContentProof.verifyFile(link, size: bytes.count, sha256: proof().fileSHA256))
        XCTAssertEqual(try Data(contentsOf: url), Data("modified-file".utf8))
    }

    func testCancelledOperationDoesNotRequestAFile() async throws {
        var calls = 0
        let c = CompanyDocumentContentClient(request: { _, _ in calls += 1; return self.bytes }, check: {})
        let operation = Task { try await c.download(id: identifier) }
        operation.cancel()
        do { _ = try await operation.value; XCTFail() } catch {}
        XCTAssertEqual(calls, 0)
    }

    func testActualBackendProofAndStaffV2GrantDecodeAndVerifyOriginalBytes() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "CompanyDocumentContentInterop", withExtension: "json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let proof = try StaffWorkspacePublicationContract.decode(CompanyDocumentContentProof.self,
            from: JSONSerialization.data(withJSONObject: XCTUnwrap(object["proof"])))
        try proof.validate(id: proof.id)
        let bytes = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(object["dataBase64"] as? String)))
        try CompanyDocumentContentProof.verify(bytes, size: proof.fileSizeBytes, sha256: proof.fileSHA256)
        let grant = try StaffWorkspacePublicationContract.decode(StaffWorkspaceOperationalMediaHTTPGrant.self,
            from: JSONSerialization.data(withJSONObject: XCTUnwrap(object["staffGrant"])))
        let staffBytes = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(object["staffDataBase64"] as? String)))
        XCTAssertEqual(grant.schema, StaffWorkspaceOperationalMediaGrant.schema)
        try CompanyDocumentContentProof.verify(staffBytes, size: grant.fileSizeBytes, sha256: grant.fileSHA256)
        XCTAssertNotEqual(grant.contentSHA256, grant.fileSHA256, "Workspace selection proof is not a file-content hash")
    }

    func testTransportFailuresShowDocumentMessagesWithoutInternalMailErrorNames() {
        for status in [401, 403, 409, 404, 500, 503] {
            let mapped = CompanyDocumentContentError.transportFailure(GmailServerHTTPError.status(status))
            let expected: CompanyDocumentContentError = [401, 403].contains(status) ? .access : status == 409 ? .unverified : .invalid
            XCTAssertEqual(mapped as? CompanyDocumentContentError, expected)
            XCTAssertFalse(mapped.localizedDescription.contains("Gmail"))
        }
        for error in [GmailServerHTTPError.response, .limit] {
            XCTAssertEqual(CompanyDocumentContentError.transportFailure(error) as? CompanyDocumentContentError, .invalid)
        }
        let offline = URLError(.notConnectedToInternet)
        XCTAssertEqual((CompanyDocumentContentError.transportFailure(offline) as? URLError)?.code, .notConnectedToInternet)
        XCTAssertTrue(CompanyDocumentContentError.transportFailure(CancellationError()) is CancellationError)
    }
}
