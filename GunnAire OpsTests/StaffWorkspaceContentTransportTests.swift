import Foundation
import XCTest
@testable import GunnAire_Ops

final class StaffWorkspaceContentTransportTests: XCTestCase {
    struct Vector: Decodable {
        let receipt: StaffWorkspaceContentReceipt
        let payloadUtf8: String
    }
    func vector() throws -> Vector {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "StaffWorkspaceContentTransportInterop", withExtension: "json"))
        return try JSONDecoder().decode(Vector.self, from: Data(contentsOf: url))
    }
    @MainActor func assembly(_ receipt: StaffWorkspaceContentReceipt, changes: [String: Any] = [:]) throws -> StaffWorkspaceContentAssembly {
        let fixture = StaffWorkspaceBillingProjectionTests()
        return try .init(receipt: receipt, plan: fixture.plan(changes: changes), workspace: fixture.fixture.workspace,
                         selection: "a1000000-0000-4000-8000-000000000077", selectionDigest: vector().receipt.selectionSHA256,
                         sequence: 1, now: fixture.fixture.now)
    }
    @MainActor func changed(_ receipt: StaffWorkspaceContentReceipt, _ changes: [String: Any]) throws -> StaffWorkspaceContentReceipt {
        let data = try StaffWorkspacePublicationContract.encode(receipt)
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        value.merge(changes) { _, next in next }
        return try JSONDecoder().decode(StaffWorkspaceContentReceipt.self, from: JSONSerialization.data(withJSONObject: value))
    }
    @MainActor func chunk(_ receipt: StaffWorkspaceContentReceipt, bytes: Data, offset: Int = 0) -> StaffWorkspaceContentChunk {
        let part = bytes.subdata(in: offset..<min(offset + receipt.chunkBytes, bytes.count))
        let end = offset + part.count
        return .init(receipt: receipt, offset: offset, nextOffset: end < bytes.count ? end : nil,
                     chunkSHA256: StaffReplicaManifest.hash(part), payloadBase64: part.base64EncodedString())
    }

    @MainActor func testActualBackendBytesHashAndAssembleExactlyWithoutJSONReencoding() throws {
        let vector = try vector(), bytes = Data(vector.payloadUtf8.utf8)
        XCTAssertEqual(StaffReplicaManifest.hash(bytes), vector.receipt.contentSHA256)
        var receiver = try assembly(vector.receipt)
        XCTAssertThrowsError(try receiver.completedBytes())
        let wire = try StaffWorkspacePublicationContract.encode(chunk(vector.receipt, bytes: bytes))
        try receiver.append(StaffWorkspaceContentChunk.decode(wire))
        XCTAssertEqual(try receiver.completedBytes(), bytes)
        XCTAssertNil(receiver.nextOffset)
        XCTAssertFalse(vector.receipt.operationalWorkspaceReady)
        XCTAssertTrue(vector.receipt.localCloudKitProofRequired)
        XCTAssertEqual(vector.receipt.coverage.count, 32)
        XCTAssertTrue(vector.payloadUtf8.contains("R-410A"))
        XCTAssertFalse(vector.payloadUtf8.contains("PRIVATE-CREDIT-AMOUNT"))
        XCTAssertThrowsError(try receiver.append(chunk(vector.receipt, bytes: bytes)))
    }

    @MainActor func testMultiChunkExactTransportIncludesUnicodeAndNumericSpellingBoundaries() throws {
        let original = try vector().receipt
        // Deliberately different JSON spellings. Transport hashes bytes, not a
        // decoded number's semantic equality. This is not a content model test.
        let bytes = Data((String(repeating: "é🧰", count: 360_000) + "[1.0,1,-0.0,1e-05]").utf8)
        let receipt = try changed(original, ["payloadBytes": bytes.count, "contentSHA256": StaffReplicaManifest.hash(bytes)])
        var receiver = try assembly(receipt)
        while let offset = receiver.nextOffset { try receiver.append(chunk(receipt, bytes: bytes, offset: offset)) }
        XCTAssertEqual(try receiver.completedBytes(), bytes)
    }

    @MainActor func testScopeRolePolicySchemaSequenceAndActivationFlagsAreFenced() throws {
        let receipt = try vector().receipt
        let cases: [[String: Any]] = [
            ["companyID": UUID().uuidString.lowercased()], ["environment": "production"],
            ["replicaID": UUID().uuidString.lowercased()], ["membershipID": UUID().uuidString.lowercased()],
            ["memberRole": "Admin"], ["projectionPolicy": "admin-operations-v1"], ["memberRevision": String(repeating: "b", count: 64)],
            ["shareRevision": 5], ["sourceSequence": 2], ["currentSourceSequence": 2], ["sourceCurrent": false],
            ["selectionID": UUID().uuidString.lowercased()], ["selectionSHA256": String(repeating: "c", count: 64)],
            ["contentSHA256": "invalid"], ["schema": "staff-billing-delivery-v1"], ["contentSchema": "core-field-v1"],
            ["sourceSchemaDigest": String(repeating: "d", count: 64)], ["fieldPolicy": "future"],
            ["discriminatorSchema": "future"], ["structuredSchema": "future"], ["billingSchema": "future"],
            ["coverage": Array(receipt.coverage.dropLast())], ["coverage": receipt.coverage.reversed().map { $0 }],
            ["recordCount": -1], ["recordCount": 20_001], ["payloadBytes": 0], ["payloadBytes": 64 * 1024 * 1024 + 1],
            ["chunkBytes": 1], ["operationalWorkspaceReady": true], ["fieldProjectionRequired": true], ["localCloudKitProofRequired": false]
        ]
        for change in cases { XCTAssertThrowsError(try assembly(changed(receipt, change)), "\(change.keys)") }
        for change in [["state": "revoked"], ["businessAccessEligible": false], ["reviewRequired": true], ["cloudKitRevocationRequired": true]] as [[String: Any]] {
            XCTAssertThrowsError(try assembly(receipt, changes: change))
        }
    }

    @MainActor func testBadChunkDoesNotChangePreviouslyVerifiedProgressAndRetryWorks() throws {
        let bytes = Data(repeating: 97, count: 2 * 1024 * 1024 + 7)
        let receipt = try changed(vector().receipt, ["payloadBytes": bytes.count, "contentSHA256": StaffReplicaManifest.hash(bytes)])
        var receiver = try assembly(receipt)
        let first = chunk(receipt, bytes: bytes)
        try receiver.append(first)
        let saved = receiver.bytes, second = chunk(receipt, bytes: bytes, offset: receipt.chunkBytes)
        let bad = [
            first,
            StaffWorkspaceContentChunk(receipt: receipt, offset: second.offset + 1, nextOffset: second.nextOffset, chunkSHA256: second.chunkSHA256, payloadBase64: second.payloadBase64),
            .init(receipt: receipt, offset: second.offset, nextOffset: nil, chunkSHA256: second.chunkSHA256, payloadBase64: second.payloadBase64),
            .init(receipt: receipt, offset: second.offset, nextOffset: second.nextOffset, chunkSHA256: String(repeating: "0", count: 64), payloadBase64: second.payloadBase64),
            .init(receipt: receipt, offset: second.offset, nextOffset: second.nextOffset, chunkSHA256: second.chunkSHA256, payloadBase64: second.payloadBase64 + "\n"),
            .init(receipt: try changed(receipt, ["memberRevision": String(repeating: "b", count: 64)]), offset: second.offset, nextOffset: second.nextOffset, chunkSHA256: second.chunkSHA256, payloadBase64: second.payloadBase64)
        ]
        for part in bad {
            XCTAssertThrowsError(try receiver.append(part)); XCTAssertEqual(receiver.bytes, saved)
        }
        try receiver.append(second)
        try receiver.append(chunk(receipt, bytes: bytes, offset: 2 * receipt.chunkBytes))
        XCTAssertEqual(try receiver.completedBytes(), bytes)
    }

    @MainActor func testWrongWholeHashRejectsFinalChunkAndRetainsEarlierBytes() throws {
        let bytes = Data(repeating: 98, count: 1024 * 1024 + 3)
        let receipt = try changed(vector().receipt, ["payloadBytes": bytes.count, "contentSHA256": String(repeating: "c", count: 64)])
        var receiver = try assembly(receipt)
        try receiver.append(chunk(receipt, bytes: bytes))
        let saved = receiver.bytes
        XCTAssertThrowsError(try receiver.append(chunk(receipt, bytes: bytes, offset: receipt.chunkBytes)))
        XCTAssertEqual(receiver.bytes, saved)
        XCTAssertThrowsError(try receiver.completedBytes())
    }

    @MainActor func testStrictWireRejectsUnknownDuplicateBoolAndMissingTerminalCursor() throws {
        let vector = try vector()
        let value = chunk(vector.receipt, bytes: Data(vector.payloadUtf8.utf8))
        let bytes = try StaffWorkspacePublicationContract.encode(value)
        let raw = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        XCTAssertThrowsError(try StaffWorkspaceContentChunk.decode(Data(raw.replacingOccurrences(of: "\"offset\":0", with: "\"offset\":true").utf8)))
        XCTAssertThrowsError(try StaffWorkspaceContentChunk.decode(Data(raw.replacingOccurrences(of: "\"offset\":0", with: "\"offset\":0,\"offset\":0").utf8)))
        XCTAssertThrowsError(try StaffWorkspaceContentChunk.decode(Data(raw.replacingOccurrences(of: "\"offset\":0", with: "\"offset\":0,\"unrecognized\":1").utf8)))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object.removeValue(forKey: "nextOffset")
        XCTAssertThrowsError(try StaffWorkspaceContentChunk.decode(JSONSerialization.data(withJSONObject: object)))
    }
}
