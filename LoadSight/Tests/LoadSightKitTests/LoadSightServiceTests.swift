import XCTest
import Combine
import LoadSightKit

@MainActor
final class LoadSightServiceTests: XCTestCase {
    func testAsyncReviewAndWorkbookMatchSharedEngineWithoutMutation() async throws {
        let project = try LoadSightTests().readyProject()
        let original = try project.data()
        let service: any LoadSightServicing = LocalLoadSightService()
        let date = Date(timeIntervalSince1970: 1789056000)
        let operation = LoadSightOperation { progress in try await service.reviewEstimate(project, asOf: date, progress: progress) }
        let result = try await operation.result
        let expected = try EstimatePricing.review(project, asOf: date)
        XCTAssertEqual(result.knownDirectCost, expected.knownDirectCost)
        XCTAssertEqual(result.blockers, expected.blockers)
        var events: [LoadSightProgress] = []
        for await event in operation.progress { events.append(event) }
        XCTAssertEqual(events.last?.phase, .succeeded)
        XCTAssertTrue(events.contains { $0.stage == "Reviewing estimate evidence" })
        let workbook = try await service.exportTakeoff(project, progress: { _ in })
        XCTAssertEqual(workbook, try TakeoffWorkbook.xlsx(project))
        XCTAssertEqual(try project.data(), original)
    }
    func testBatchIngestionRetainsAndDeduplicatesOriginals() async throws {
        let url = Bundle.module.url(forResource: "DrawingIntake", withExtension: "pdf", subdirectory: "Fixtures")!
        let service = LocalLoadSightService()
        let operation = LoadSightOperation { progress in try await service.ingestDrawings([url, url], ocr: .disabled, progress: progress) }
        let archive = try await operation.result
        XCTAssertEqual(archive.records.count, 1)
        XCTAssertEqual(archive.records[0].pages.count, 3)
        XCTAssertEqual(archive.files[archive.records[0].id], try Data(contentsOf: url))
        var pages = 0
        for await event in operation.progress where event.stage.contains("page") { pages += 1 }
        XCTAssertEqual(pages, 6)
    }
    func testFailedBatchReturnsNoPartialArchiveAndTerminalFailure() async throws {
        let url = Bundle.module.url(forResource: "DrawingIntake", withExtension: "pdf", subdirectory: "Fixtures")!
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let operation = LoadSightOperation { progress in try await LocalLoadSightService().ingestDrawings([url, missing], ocr: .disabled, progress: progress) }
        do { _ = try await operation.result; XCTFail("Expected missing input failure") } catch { XCTAssertFalse(error is CancellationError) }
        var last: LoadSightProgress?
        for await event in operation.progress { last = event }
        XCTAssertEqual(last?.phase, .failed)
    }
    func testExplicitCancellationFinishesProgressAndThrows() async throws {
        let started = expectation(description: "Work started")
        let operation = LoadSightOperation<Int> { _ in
            started.fulfill()
            try await Task.sleep(for: .seconds(30)); return 1
        }
        await fulfillment(of: [started], timeout: 3)
        operation.cancel()
        do { _ = try await operation.result; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        var phases: [LoadSightProgress.Phase] = []
        for await event in operation.progress { phases.append(event.phase) }
        XCTAssertEqual(phases.last, .cancelled); XCTAssertFalse(phases.contains(.succeeded))
    }
    func testCancellingResultWaiterPropagatesToWork() async throws {
        let started = expectation(description: "Work started before waiter cancellation")
        let operation = LoadSightOperation<Int> { _ in started.fulfill(); try await Task.sleep(for: .seconds(30)); return 1 }
        let waiter = Task { try await operation.result }
        await fulfillment(of: [started], timeout: 3)
        waiter.cancel()
        do { _ = try await waiter.value; XCTFail("Expected cancelled waiter") } catch { XCTAssertTrue(error is CancellationError) }
        do { _ = try await operation.result; XCTFail("Expected cancelled work") } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testBoundedProgressRetainsTerminalEvent() async throws {
        let operation = LoadSightOperation<Int> { progress in
            for index in 0..<1000 { progress(.init(stage: "Synthetic", completedUnits: index, totalUnits: 1000)) }
            return 1000
        }
        let value = try await operation.result; XCTAssertEqual(value, 1000)
        var events: [LoadSightProgress] = []
        for await event in operation.progress { events.append(event) }
        XCTAssertLessThanOrEqual(events.count, 64); XCTAssertEqual(events.last?.phase, .succeeded)
    }
    func testCombineMulticastsTerminalProgressOnMainActor() async throws {
        let operation = LoadSightOperation<Int> { progress in progress(.init(stage: "Synthetic", completedUnits: 1, totalUnits: 1)); return 1 }
        let bridge = LoadSightProgressPublisher(operation.progress)
        let first = expectation(description: "First subscriber"), second = expectation(description: "Second subscriber")
        var subscriptions = Set<AnyCancellable>()
        bridge.publisher.filter { $0.phase == .succeeded }.prefix(1).sink { _ in XCTAssertTrue(Thread.isMainThread); first.fulfill() }.store(in: &subscriptions)
        bridge.publisher.filter { $0.phase == .succeeded }.prefix(1).sink { _ in second.fulfill() }.store(in: &subscriptions)
        _ = try await operation.result
        await fulfillment(of: [first, second], timeout: 3)
        bridge.stopObserving(); XCTAssertEqual(subscriptions.count, 2)
    }
    func testLocalServiceRejectsRemoteAndEmptyDrawingInputs() async throws {
        let service = LocalLoadSightService()
        for urls in [[], [URL(string: "https://example.invalid/drawing.pdf")!]] {
            do { _ = try await service.ingestDrawings(urls); XCTFail("Expected local input boundary") }
            catch { XCTAssertTrue(error is LoadSightError) }
        }
    }
    func testDraftOutputAndMissingRecordUseSharedValidation() async throws {
        let project = try LoadSightTests().readyProject()
        let service = LocalLoadSightService()
        let pdf = try await service.draftProposal(project, generatedAt: Date(timeIntervalSince1970: 1789056000))
        XCTAssertTrue(pdf.starts(with: Data("%PDF".utf8)))
        do { _ = try await service.draftRFI(project, rfiID: "missing"); XCTFail("Expected missing RFI") } catch {}
        do { _ = try await service.draftCO(project, changeOrderID: "missing"); XCTFail("Expected missing CO") } catch {}
    }
    func testRecordedEngineeringKeepsExplicitPartialScope() async throws {
        let project = try LoadSightTests().readyProject()
        let review = try await LocalLoadSightService().reviewRecordedEngineering(project)
        XCTAssertTrue(review["scope"].string!.contains("not semantic drawing extraction or complete building loads"))
        XCTAssertEqual(review["reviews"]["Air processes"], try project.airProcessReview())
        XCTAssertEqual(review["reviews"]["Room transmission"], try project.roomTransmissionReview())
    }
}
