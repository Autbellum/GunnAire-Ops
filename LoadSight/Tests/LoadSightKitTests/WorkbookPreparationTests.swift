import XCTest
import Combine
import LoadSightKit
@testable import LoadSightUI

@MainActor final class WorkbookPreparationTests: XCTestCase {
    func testNativeGeneratorMatchesOriginalWorkbookAndRetainsSource() async throws {
        let project = try LoadSightTests().readyProject(), drawings = DrawingArchive()
        let original = try project.data(), session = UUID()
        let preparation = WorkbookPreparation()
        let ready = expectation(description: "Ready")
        let subscription = preparation.$readyID.compactMap { $0 }.prefix(1).sink { _ in ready.fulfill() }
        preparation.start(project: project, drawings: drawings, documentSessionID: session)
        await fulfillment(of: [ready], timeout: 5)
        XCTAssertEqual(preparation.data, try TakeoffWorkbook.xlsx(project, drawings: drawings))
        XCTAssertEqual(preparation.documentSessionID, session)
        XCTAssertEqual(try project.data(), original)
        XCTAssertFalse(preparation.isPreparing)
        XCTAssertFalse(preparation.finish(receiptID: preparation.readyID, currentDocumentSessionID: UUID()))
        XCTAssertNotNil(preparation.data)
        XCTAssertTrue(preparation.finish(receiptID: preparation.readyID, currentDocumentSessionID: session))
        XCTAssertNil(preparation.data); withExtendedLifetime(subscription) {}
    }
    func testCancelBeforeCompletionCannotPresentLateOutputOrFailure() async throws {
        let started = expectation(description: "Started"), returned = expectation(description: "Worker ended")
        let preparation = WorkbookPreparation { _, _, _ in
            started.fulfill()
            do { try await Task.sleep(for: .seconds(30)) } catch {}
            returned.fulfill()
            return Data("late".utf8)
        }
        preparation.start(project: try LoadSightTests().readyProject(), drawings: .init(), documentSessionID: UUID())
        await fulfillment(of: [started], timeout: 3)
        preparation.cancel()
        await fulfillment(of: [returned], timeout: 3)
        await Task.yield()
        XCTAssertNil(preparation.readyID); XCTAssertNil(preparation.data); XCTAssertNil(preparation.failure)
        XCTAssertFalse(preparation.isPreparing)
    }
    func testFailureIsVisibleWithoutCreatingExport() async throws {
        let preparation = WorkbookPreparation { _, _, _ in throw LoadSightError.invalid("Synthetic export failure") }
        let failed = expectation(description: "Failed")
        let subscription = preparation.$failure.compactMap { $0 }.prefix(1).sink { _ in failed.fulfill() }
        preparation.start(project: try LoadSightTests().readyProject(), drawings: .init(), documentSessionID: UUID())
        await fulfillment(of: [failed], timeout: 3)
        XCTAssertEqual(preparation.failure, "Synthetic export failure"); XCTAssertNil(preparation.readyID); XCTAssertNil(preparation.data)
        withExtendedLifetime(subscription) {}
    }
    func testOldReceiptCannotClearNewDocumentExport() async throws {
        let preparation = WorkbookPreparation { _, _, _ in Data("workbook".utf8) }
        let first = expectation(description: "First ready"), second = expectation(description: "Second ready")
        var subscriptions = Set<AnyCancellable>()
        preparation.$readyID.compactMap { $0 }.prefix(1).sink { _ in first.fulfill() }.store(in: &subscriptions)
        preparation.start(project: try LoadSightTests().readyProject(), drawings: .init(), documentSessionID: UUID())
        await fulfillment(of: [first], timeout: 3)
        let oldID = preparation.readyID
        preparation.cancel()
        preparation.$readyID.compactMap { $0 }.prefix(1).sink { _ in second.fulfill() }.store(in: &subscriptions)
        let newSession = UUID()
        preparation.start(project: try LoadSightTests().readyProject(), drawings: .init(), documentSessionID: newSession)
        await fulfillment(of: [second], timeout: 3)
        XCTAssertFalse(preparation.finish(receiptID: oldID, currentDocumentSessionID: newSession))
        XCTAssertEqual(preparation.documentSessionID, newSession); XCTAssertNotNil(preparation.data)
        XCTAssertTrue(preparation.finish(receiptID: preparation.readyID, currentDocumentSessionID: newSession))
    }
}
