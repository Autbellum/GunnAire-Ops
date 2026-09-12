import XCTest
import Combine
import PDFKit
import LoadSightKit
@testable import LoadSightUI

private actor ProgressProbe {
    var handler: LoadSightProgressHandler?
    func install(_ handler: @escaping LoadSightProgressHandler) { self.handler = handler }
    func sendLateProgress() { handler?(.init(phase: .failed, stage: "Late callback", completedUnits: 1, totalUnits: 1)) }
}

@MainActor final class AsyncExportBoundaryTests: XCTestCase {
    func testConcurrentAndLateProgressCannotFollowTerminalEvent() async throws {
        let probe = ProgressProbe()
        let operation = LoadSightOperation<Int> { progress in
            await probe.install(progress)
            await withTaskGroup(of: Void.self) { group in
                for index in 0..<32 {
                    group.addTask { progress(.init(stage: "Concurrent \(index)", completedUnits: index, totalUnits: 32)) }
                }
            }
            return 7
        }
        let value = try await operation.result
        XCTAssertEqual(value, 7)
        await probe.sendLateProgress()
        var events: [LoadSightProgress] = []
        for await event in operation.progress { events.append(event) }
        XCTAssertEqual(events.filter { $0.phase != .running }.map(\.phase), [.succeeded])
        XCTAssertEqual(events.last?.phase, .succeeded)
        XCTAssertFalse(events.contains { $0.stage == "Late callback" })
    }

    func testAllDraftExportersRejectNonfiniteGenerationTime() async throws {
        let project = try LoadSightTests().readyProject(), original = project.root
        let service = LocalLoadSightService()
        for value in [Double.infinity, -.infinity, .nan] {
            let date = Date(timeIntervalSince1970: value)
            XCTAssertThrowsError(try DraftProposal.pdf(project, generatedAt: date)) { XCTAssertTrue($0.localizedDescription.contains("finite")) }
            XCTAssertThrowsError(try RFIWordDocument.docx(project, rfiID: "missing", generatedAt: date)) { XCTAssertTrue($0.localizedDescription.contains("finite")) }
            XCTAssertThrowsError(try ChangeOrderWordDocument.docx(project, changeOrderID: "missing", generatedAt: date)) { XCTAssertTrue($0.localizedDescription.contains("finite")) }
            do { _ = try await service.draftProposal(project, generatedAt: date); XCTFail("Expected invalid date") }
            catch { XCTAssertTrue(error.localizedDescription.contains("finite")) }
        }
        XCTAssertEqual(project.root, original)
    }

    func testOnlyOperationCanDeclareTerminalProgress() async throws {
        let operation = LoadSightOperation<Int> { progress in
            for phase in [LoadSightProgress.Phase.succeeded, .cancelled, .failed] {
                progress(.init(phase: phase, stage: "Worker status", completedUnits: 1, totalUnits: 1))
            }
            throw LoadSightError.invalid("Synthetic final failure")
        }
        do { _ = try await operation.result; XCTFail("Expected work failure") }
        catch { XCTAssertEqual(error as? LoadSightError, .invalid("Synthetic final failure")) }
        var terminal: [LoadSightProgress.Phase] = []
        for await event in operation.progress where event.phase != .running { terminal.append(event.phase) }
        XCTAssertEqual(terminal, [.failed])
    }

    func testWorkerProgressUnitsCannotLeaveDisplayRange() async throws {
        let operation = LoadSightOperation<Int> { progress in
            progress(.init(stage: "Negative", completedUnits: -1, totalUnits: -9))
            progress(.init(stage: "Overshoot", completedUnits: Int.max, totalUnits: 10))
            return 1
        }
        _ = try await operation.result
        for await event in operation.progress {
            XCTAssertGreaterThan(event.totalUnits, 0)
            XCTAssertGreaterThanOrEqual(event.completedUnits, 0)
            XCTAssertLessThanOrEqual(event.completedUnits, event.totalUnits)
        }
    }

    func testProposalReviewsQuoteAtItsDeclaredGenerationTime() throws {
        var p = try LoadSightTests().readyProject()
        let quote = SupplierQuoteEvidence(supplier: "Fixture", reference: "Q-1", source: "Synthetic quote", issuedAt: "2026-09-10T12:00:00Z", validUntil: "2026-09-10T13:00:00Z", conditions: "Synthetic test conditions")
        let catalog = OpsMaterialCatalogSnapshot(id: UUID(), source: "Synthetic catalog", name: "Duct", purchaseCost: 50, updatedAt: "2026-09-10T12:00:00Z")
        let mapping = CatalogMaterialMapping(catalog: catalog, currency: "USD", purchaseUnit: "5-foot length", catalogUnitsPerTakeoffUnit: 0.2, takeoffUnit: "LF", itemDescription: "Duct", lifecycle: "", basis: "Synthetic conversion", quote: quote)
        try p.updateCatalogMaterialMapping(itemID: "D1", mapping: mapping, expectedFingerprint: p.catalogMaterialEditFingerprint(itemID: "D1"), author: "Fixture", reason: "Quote timing")
        let original = p.root
        let validAt = ISO8601DateFormatter().date(from: "2026-09-10T12:30:00Z")!
        let expiredAt = ISO8601DateFormatter().date(from: "2026-09-10T13:00:00Z")!
        let validText = try XCTUnwrap(PDFDocument(data: DraftProposal.pdf(p, generatedAt: validAt))?.string)
        let expiredText = try XCTUnwrap(PDFDocument(data: DraftProposal.pdf(p, generatedAt: expiredAt))?.string)
        XCTAssertFalse(validText.contains("Supplier quote for D1"))
        XCTAssertTrue(expiredText.contains("Supplier quote for D1"))
        XCTAssertTrue(expiredText.contains("expired"))
        XCTAssertEqual(p.root, original)
    }
}
