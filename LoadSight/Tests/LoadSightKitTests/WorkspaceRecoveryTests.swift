import XCTest
import LoadSightKit
@testable import LoadSightUI

@MainActor
final class WorkspaceRecoveryTests: XCTestCase {
    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LoadSightRecoveryTests-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func failed(_ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected rejection") } catch {}
    }
    func testDurableRoundTripRetainsOriginalDrawingsAndProjectHistory() async throws {
        let url = directory(), store = WorkspaceRecoveryStore(directory: url)
        var document = LoadSightDocument()
        let drawing = Bundle.module.url(forResource: "DrawingIntake", withExtension: "pdf", subdirectory: "Fixtures")!
        let archive = try await DrawingIngestor().ingest(url: drawing)
        try document.addDrawings(archive)
        let context = OpsProjectContext(customer: .init(id: UUID(), name: "Synthetic recovery customer", address: ""))
        try document.project.updateOpsContext(context, expectedFingerprint: document.project.opsContextEditFingerprint(), author: "Recorder", reason: "Recovery fixture")
        let saved = try await store.save(project: document.project, drawings: document.drawings, scope: "account-A", expectedRevision: nil)
        let anotherInstance = WorkspaceRecoveryStore(directory: url)
        let loaded = try await anotherInstance.load(scope: "account-A")
        let restored = try LoadSightDocument(recoveryDraft: XCTUnwrap(loaded))
        XCTAssertEqual(restored.drawings.files, document.drawings.files)
        XCTAssertEqual(restored.project.root["opsContextHistory"], document.project.root["opsContextHistory"])
        XCTAssertEqual(try restored.project.opsContext(), context)
        XCTAssertEqual(loaded?.revision, saved.revision)
        XCTAssertEqual(loaded?.project["nativeDrawings"], .null)
        let file = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).first { $0.pathExtension == "json" }!
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
    func testAccountScopesAreSeparateAndNotVisibleInFilenames() async throws {
        let url = directory(), store = WorkspaceRecoveryStore(directory: url), document = LoadSightDocument()
        _ = try await store.save(project: document.project, drawings: document.drawings, scope: "person@example.invalid/company-A", expectedRevision: nil)
        let absent = try await store.load(scope: "person@example.invalid/company-B")
        XCTAssertNil(absent)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: url.path).joined().contains("person"))
        await failed { _ = try await store.load(scope: " ") }
        let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        let firstFile = files.first { $0.pathExtension == "json" }!
        let secondLock = files.first { $0.pathExtension == "lock" && $0.deletingPathExtension().lastPathComponent != firstFile.deletingPathExtension().lastPathComponent }!
        try Data(contentsOf: firstFile).write(to: secondLock.deletingPathExtension().appendingPathExtension("json"))
        await failed { _ = try await store.load(scope: "person@example.invalid/company-B") }
    }
    func testStaleSaveAndDeleteCannotReplaceAnotherWindow() async throws {
        let url = directory(), first = WorkspaceRecoveryStore(directory: url), second = WorkspaceRecoveryStore(directory: url)
        let document = LoadSightDocument()
        let original = try await first.save(project: document.project, drawings: document.drawings, scope: "A", expectedRevision: nil)
        var changed = document.project; try changed.replace("name", with: .string("Newer project"))
        let current = try await second.save(project: changed, drawings: document.drawings, scope: "A", expectedRevision: original.revision)
        await failed { _ = try await first.save(project: document.project, drawings: document.drawings, scope: "A", expectedRevision: original.revision) }
        await failed { try await first.remove(scope: "A", expectedRevision: original.revision) }
        let retained = try await first.load(scope: "A")
        XCTAssertEqual(retained?.revision, current.revision)
        XCTAssertEqual(retained?.project["name"].string, "Newer project")
    }
    func testCompetingStoreInstancesHaveExactlyOneWinner() async throws {
        let url = directory(), document = LoadSightDocument()
        let first = WorkspaceRecoveryStore(directory: url), second = WorkspaceRecoveryStore(directory: url)
        let project = document.project, drawings = document.drawings
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let outcomes = await withTaskGroup(of: String.self, returning: [String].self) { group in
            for store in [first, second] {
                group.addTask { do { _ = try await store.save(project: project, drawings: drawings, scope: "A", expectedRevision: nil); return "saved" } catch { return error.localizedDescription } }
            }
            var values: [String] = []; for await value in group { values.append(value) }; return values
        }
        XCTAssertEqual(outcomes.filter { $0 == "saved" }.count, 1)
        XCTAssertEqual(outcomes.filter { $0.contains("Another window changed") }.count, 1)
    }
    func testCorruptionAndSymlinkDoNotGetOverwritten() async throws {
        let url = directory(), store = WorkspaceRecoveryStore(directory: url), document = LoadSightDocument()
        let saved = try await store.save(project: document.project, drawings: document.drawings, scope: "A", expectedRevision: nil)
        let file = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).first { $0.pathExtension == "json" }!
        let damaged = Data("invalid recovery".utf8); try damaged.write(to: file)
        await failed { _ = try await store.load(scope: "A") }
        await failed { _ = try await store.save(project: document.project, drawings: document.drawings, scope: "A", expectedRevision: saved.revision) }
        XCTAssertEqual(try Data(contentsOf: file), damaged)
        try FileManager.default.removeItem(at: file)
        let target = url.appendingPathComponent("protected-original"); try damaged.write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        await failed { _ = try await store.save(project: document.project, drawings: document.drawings, scope: "A", expectedRevision: nil) }
        XCTAssertEqual(try Data(contentsOf: target), damaged)
    }
    func testControllerKeepsNewestDraftAfterDelayedExportAndFlush() async throws {
        let store = WorkspaceRecoveryStore(directory: directory()), session = WorkspaceRecoverySession(scope: "A", store: store)
        await session.load()
        let original = LoadSightDocument()
        var newer = original.project; try newer.replace("name", with: .string("Newer edit"))
        session.save(project: original.project, drawings: original.drawings)
        session.save(project: newer, drawings: original.drawings)
        session.exported(projectRoot: original.project.root)
        let flushed = await session.flush(project: newer, drawings: original.drawings)
        XCTAssertTrue(flushed)
        let loaded = try await store.load(scope: "A")
        XCTAssertEqual(loaded?.project["name"].string, "Newer edit")
        let removed = await session.discard(); XCTAssertTrue(removed)
        let empty = try await store.load(scope: "A"); XCTAssertNil(empty)
    }
    func testCleanProjectRemovesQueuedSupersededRecovery() async throws {
        let store = WorkspaceRecoveryStore(directory: directory()), session = WorkspaceRecoverySession(scope: "A", store: store)
        await session.load()
        let document = LoadSightDocument()
        session.save(project: document.project, drawings: document.drawings)
        session.currentProjectIsClean()
        await session.waitForPendingOperations()
        let empty = try await store.load(scope: "A"); XCTAssertNil(empty)
        XCTAssertFalse(session.isSaved(project: document.project, drawings: document.drawings))
    }
    func testFailedStorageNeverReportsSavedAndManualModeKeepsOldBytes() async throws {
        let url = directory(); try Data("not a directory".utf8).write(to: url)
        let store = WorkspaceRecoveryStore(directory: url), session = WorkspaceRecoverySession(scope: "A", store: store)
        await session.load()
        XCTAssertTrue(session.requiresRecoveryDecision)
        let document = LoadSightDocument()
        let result = await session.flush(project: document.project, drawings: document.drawings)
        XCTAssertFalse(result); XCTAssertNotNil(session.issue)
        session.continueWithoutRecovery()
        XCTAssertFalse(session.enabled)
        XCTAssertEqual(try Data(contentsOf: url), Data("not a directory".utf8))
    }
}
