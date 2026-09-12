import XCTest
import LoadSightKit
@testable import LoadSightUI

@MainActor final class EquipmentSchedulePreparationTests: XCTestCase {
    func testSuccessBindsDocumentScopeAndCancelClearsEvidence() async throws {
        let url = Bundle.module.url(forResource: "EquipmentSchedule", withExtension: "pdf", subdirectory: "Fixtures")!
        let map = Bundle.module.url(forResource: "EquipmentScheduleMapping", withExtension: "json", subdirectory: "Fixtures")!
        let archive = try await DrawingIngestor().ingest(url: url, ocr: .disabled)
        let request = try EquipmentScheduleRequest.decode(Data(contentsOf: map)), session = UUID()
        let controller = EquipmentSchedulePreparation()
        controller.start(drawings: archive, documentSessionID: session, request: request)
        let deadline = Date().addingTimeInterval(5)
        while controller.isScanning && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.result?.rows.count, 3)
        XCTAssertTrue(controller.matches(drawings: archive, documentSessionID: session))
        XCTAssertFalse(controller.matches(drawings: archive, documentSessionID: UUID()))
        controller.cancel()
        XCTAssertNil(controller.result); XCTAssertFalse(controller.matches(drawings: archive, documentSessionID: session))
        controller.start(drawings: archive, documentSessionID: session, request: request)
        controller.cancel()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(controller.result); XCTAssertFalse(controller.isScanning)
    }
    func testBadMappingShowsFailureWithoutResult() async throws {
        let controller = EquipmentSchedulePreparation()
        controller.start(drawings: .init(), documentSessionID: UUID(), request: .init(regions: []))
        let deadline = Date().addingTimeInterval(5)
        while controller.isScanning && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(controller.failure); XCTAssertNil(controller.result); XCTAssertFalse(controller.isScanning)
    }
}
