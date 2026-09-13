import Foundation
import XCTest
@testable import GunnAire_Ops

final class NativeIsolationBoundaryTests: XCTestCase {
    func testReceiptAndChunkRoundTripAcrossConcurrentBackgroundTasks() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "StaffWorkspaceContentTransportInterop", withExtension: "json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let bytes = try JSONSerialization.data(withJSONObject: XCTUnwrap(root["receipt"]), options: [.sortedKeys])
        let copies = try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    let receipt = try JSONDecoder().decode(StaffWorkspaceContentReceipt.self, from: bytes)
                    let chunk = StaffWorkspaceContentChunk(receipt: receipt, offset: 0, nextOffset: nil,
                        chunkSHA256: String(repeating: "a", count: 64), payloadBase64: "Zml4dHVyZQ==")
                    let encoder = JSONEncoder()
                    let chunkBytes = try encoder.encode(chunk)
                    let roundTrip = try JSONDecoder().decode(StaffWorkspaceContentChunk.self, from: chunkBytes)
                    guard roundTrip == chunk else { throw NSError(domain: "Fixture round trip", code: 1) }
                    let encoded = try encoder.encode(receipt)
                    return try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: encoded), options: [.sortedKeys])
                }
            }
            var result: [Data] = []
            for try await value in group { result.append(value) }
            return result
        }
        XCTAssertEqual(copies.count, 32)
        XCTAssertTrue(copies.allSatisfy { $0 == bytes })
        // A successful value decode is still not permission to mount a staff store.
        let receipt = try JSONDecoder().decode(StaffWorkspaceContentReceipt.self, from: bytes)
        XCTAssertFalse(receipt.operationalWorkspaceReady)
        XCTAssertTrue(receipt.localCloudKitProofRequired)
    }

    func testPureReferenceAndTimestampHelpersRunInBackground() async throws {
        let result = await Task.detached {
            let dates = ["2025-01-01T00:00:00Z", "2025-01-01T00:00:00.125Z", "not a date"]
                .map(StaffOwnerFieldEditApplication.instant)
            let references = ["D1", "realm:42", "D1\n", "..", ""].map(QBODocumentScope.reference)
            return (dates, references)
        }.value
        XCTAssertEqual(result.0[0]?.timeIntervalSince1970, 1_735_689_600)
        XCTAssertEqual(result.0[1]?.timeIntervalSince1970, 1_735_689_600.125)
        XCTAssertNil(result.0[2])
        XCTAssertEqual(result.1, [true, true, false, false, false])
    }

    @MainActor func testEveryProviderReferenceBoundaryRejectsPartialMatches() throws {
        let valid = ["D1", "realm:42", "ref_1.2-3", String(repeating: "A", count: 128)]
        let invalid = ["", ".", "..", "D1\n", "D1\r", "D1\r\n", "D1\u{2028}", "D1\u{2029}", " D1", "D1 ", "D1/path", "D1\0", String(repeating: "A", count: 129)]
        for (values, expected) in [(valid, true), (invalid, false)] {
            for value in values {
                XCTAssertEqual(QuickBooksProviderReference.isValid(value), expected, value.debugDescription)
                XCTAssertEqual(QBODocumentScope.reference(value), expected, value.debugDescription)
                XCTAssertEqual(QuickBooksSalesLineContract.validReference(value), expected, value.debugDescription)
                XCTAssertEqual(PaymentAttemptRecord.isReference(value), expected, value.debugDescription)
                XCTAssertEqual(QuickBooksChangeHistoryScope.validReference(value), expected, value.debugDescription)
                let link = QuickBooksExistingLink(kind: .customer, localID: UUID(), providerID: value, localName: "Fixture")
                if expected { XCTAssertNoThrow(try link.validate()) }
                else { XCTAssertThrowsError(try link.validate()) }
            }
        }
    }

}
