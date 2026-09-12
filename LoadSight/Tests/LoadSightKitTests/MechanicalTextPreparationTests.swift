import XCTest
import Combine
import LoadSightKit
@testable import LoadSightUI

private actor ExtractionGate {
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<MechanicalTextExtraction, Error>] = [:]
    private let started: [XCTestExpectation]
    init(_ started: [XCTestExpectation]) { self.started = started }
    func hold() async throws -> MechanicalTextExtraction {
        let id = nextID; nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation; started[id].fulfill()
        }
    }
    func complete(_ id: Int, _ result: Result<MechanicalTextExtraction, Error>) {
        pending.removeValue(forKey: id)?.resume(with: result)
    }
}

@MainActor final class MechanicalTextPreparationTests: XCTestCase {
    func testNativeScanRetainsSourcesAndShowsTerminalState() async throws {
        let archive = try await MechanicalTextExtractionTests().synthetic("AHU-1 1200 CFM"), original = archive
        let preparation = MechanicalTextPreparation(), session = UUID()
        let ready = expectation(description: "Scan ready")
        let subscription = preparation.$result.compactMap { $0 }.prefix(1).sink { _ in ready.fulfill() }
        preparation.start(drawings: archive, documentSessionID: session)
        await fulfillment(of: [ready], timeout: 5)
        XCTAssertEqual(preparation.result?.candidates, try MechanicalTextExtractor.extract(archive).candidates)
        XCTAssertFalse(preparation.isScanning)
        XCTAssertTrue(preparation.stage.hasPrefix("Scan complete"))
        XCTAssertTrue(preparation.matches(drawings: archive, documentSessionID: session))
        XCTAssertFalse(preparation.matches(drawings: archive, documentSessionID: UUID()))
        XCTAssertEqual(archive, original)
        preparation.updateScope(drawings: archive, documentSessionID: session)
        XCTAssertNotNil(preparation.result)
        preparation.updateScope(drawings: .init(), documentSessionID: session)
        XCTAssertNil(preparation.result)
        XCTAssertTrue(preparation.stage.contains("changed"))
        withExtendedLifetime(subscription) {}
    }

    func testCancellationClearsBusyStateAndRejectsLateSuccess() async throws {
        let started = expectation(description: "Started"), returned = expectation(description: "Worker returned")
        let gate = ExtractionGate([started]), output = try MechanicalTextExtractor.extract(.init())
        let preparation = MechanicalTextPreparation { _, progress in
            let value = try await gate.hold()
            progress(.init(stage: "Late progress", completedUnits: 1, totalUnits: 1))
            returned.fulfill(); return value
        }
        preparation.start(drawings: .init(), documentSessionID: UUID())
        await fulfillment(of: [started], timeout: 3)
        preparation.cancel()
        XCTAssertFalse(preparation.isScanning); XCTAssertEqual(preparation.stage, "Scan cancelled")
        await gate.complete(0, .success(output))
        await fulfillment(of: [returned], timeout: 3)
        await Task.yield()
        XCTAssertNil(preparation.result); XCTAssertNil(preparation.failure)
        XCTAssertEqual(preparation.stage, "Scan cancelled")
    }

    func testSourceAndSessionReplacementInvalidateInFlightScans() async throws {
        let archive = try await MechanicalTextExtractionTests().synthetic("RTU-1")
        for replaceSession in [false, true] {
            let started = expectation(description: "Started"), ended = expectation(description: "Ended")
            let gate = ExtractionGate([started]), output = try MechanicalTextExtractor.extract(archive)
            let preparation = MechanicalTextPreparation { _, _ in
                defer { ended.fulfill() }
                return try await gate.hold()
            }
            let session = UUID()
            preparation.start(drawings: archive, documentSessionID: session)
            await fulfillment(of: [started], timeout: 3)
            preparation.updateScope(drawings: replaceSession ? archive : .init(), documentSessionID: replaceSession ? UUID() : session)
            XCTAssertFalse(preparation.isScanning); XCTAssertNil(preparation.result)
            await gate.complete(0, .success(output))
            await fulfillment(of: [ended], timeout: 3)
            await Task.yield()
            XCTAssertNil(preparation.result); XCTAssertNil(preparation.failure)
            XCTAssertTrue(preparation.stage.contains("changed"))
        }
    }

    func testSupersededFailureCannotReplaceNewSuccessfulScan() async throws {
        let first = expectation(description: "First started"), second = expectation(description: "Second started")
        let oldEnded = expectation(description: "Old worker ended"), ready = expectation(description: "New scan ready")
        let gate = ExtractionGate([first, second]), output = try MechanicalTextExtractor.extract(.init())
        let preparation = MechanicalTextPreparation { _, _ in
            do { return try await gate.hold() }
            catch { oldEnded.fulfill(); throw error }
        }
        preparation.start(drawings: .init(), documentSessionID: UUID())
        await fulfillment(of: [first], timeout: 3)
        let session = UUID()
        preparation.start(drawings: .init(), documentSessionID: session)
        await fulfillment(of: [second], timeout: 3)
        let subscription = preparation.$result.compactMap { $0 }.prefix(1).sink { _ in ready.fulfill() }
        await gate.complete(1, .success(output))
        await fulfillment(of: [ready], timeout: 3)
        await gate.complete(0, .failure(LoadSightError.invalid("Superseded failure")))
        await fulfillment(of: [oldEnded], timeout: 3)
        await Task.yield()
        XCTAssertNotNil(preparation.result); XCTAssertNil(preparation.failure)
        XCTAssertFalse(preparation.isScanning); XCTAssertTrue(preparation.stage.hasPrefix("Scan complete"))
        XCTAssertTrue(preparation.matches(drawings: .init(), documentSessionID: session))
        preparation.updateScope(drawings: .init(), documentSessionID: UUID())
        XCTAssertNil(preparation.result)
        withExtendedLifetime(subscription) {}
    }

    func testFailureLeavesRetryAvailableWithoutStaleResults() async throws {
        let preparation = MechanicalTextPreparation { _, _ in throw LoadSightError.invalid("Synthetic scan failure") }
        let failed = expectation(description: "Failed")
        let subscription = preparation.$failure.compactMap { $0 }.prefix(1).sink { _ in failed.fulfill() }
        preparation.start(drawings: .init(), documentSessionID: UUID())
        await fulfillment(of: [failed], timeout: 3)
        XCTAssertEqual(preparation.failure, "Synthetic scan failure")
        XCTAssertEqual(preparation.stage, "Unable to scan drawing text")
        XCTAssertFalse(preparation.isScanning); XCTAssertNil(preparation.result)
        withExtendedLifetime(subscription) {}
    }
}
