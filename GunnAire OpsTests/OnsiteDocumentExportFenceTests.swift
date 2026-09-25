import Foundation
import Testing
@testable import GunnAire_Ops

@MainActor
struct OnsiteDocumentExportFenceTests {
    private struct Revoked: Error {}

    @MainActor
    private final class AuthorizationState {
        var allowed = true
    }

    @MainActor
    private final class PausedRenderer {
        private var resumeRender: CheckedContinuation<Void, Never>?
        private var resumeStarted: CheckedContinuation<Void, Never>?
        private var started = false
        let url = URL(fileURLWithPath: "/synthetic/onsite-export.pdf")

        func render(_ validate: @MainActor () throws -> Void) async throws -> URL {
            try validate()
            await withCheckedContinuation { continuation in
                resumeRender = continuation
                started = true
                resumeStarted?.resume()
                resumeStarted = nil
            }
            return url
        }

        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { resumeStarted = $0 }
        }

        func complete() {
            resumeRender?.resume()
            resumeRender = nil
        }
    }

    @Test func unchangedRequestCanPublishAfterPausedRendering() async throws {
        let lifetime = OnsiteDocumentExportLifetime()
        lifetime.appear()
        let request = try #require(lifetime.begin())
        let renderer = PausedRenderer()
        var validations = 0
        let task = Task { @MainActor in
            try await lifetime.export(request: request, validateCurrent: { validations += 1 }, render: renderer.render)
        }
        await renderer.waitUntilStarted()
        #expect(validations == 2)
        renderer.complete()
        let result = try await task.value
        try result.validateCurrent()
        #expect(result.url == renderer.url)
        #expect(validations == 4)
        lifetime.finish(request)
        #expect(lifetime.begin() != nil)
    }

    @Test func revokedAccessDuringRenderCannotReachCallerPublication() async throws {
        let lifetime = OnsiteDocumentExportLifetime()
        lifetime.appear()
        let request = try #require(lifetime.begin())
        let renderer = PausedRenderer()
        let authorization = AuthorizationState()
        var publications = 0
        let task = Task { @MainActor in
            let result = try await lifetime.export(request: request, validateCurrent: {
                guard authorization.allowed else { throw Revoked() }
            }, render: renderer.render)
            try result.validateCurrent()
            publications += 1
        }
        await renderer.waitUntilStarted()
        authorization.allowed = false
        renderer.complete()
        do {
            try await task.value
            Issue.record("A revoked export reached the caller")
        } catch { #expect(error is Revoked) }
        #expect(publications == 0)
    }

    @Test func disappearedRequestDoesNotReviveWhenViewReappears() async throws {
        let lifetime = OnsiteDocumentExportLifetime()
        lifetime.appear()
        let old = try #require(lifetime.begin())
        let renderer = PausedRenderer()
        let task = Task { @MainActor in
            try await lifetime.export(request: old, validateCurrent: {}, render: renderer.render)
        }
        await renderer.waitUntilStarted()
        lifetime.disappear()
        lifetime.appear()
        let current = try #require(lifetime.begin())
        #expect(current != old)
        renderer.complete()
        do {
            _ = try await task.value
            Issue.record("The disappeared request was revived")
        } catch { #expect(error is CancellationError) }
        lifetime.finish(old)
        try lifetime.check(current)
        #expect(lifetime.begin() == nil)
    }

    @Test func selectionChangeRejectsFinishedResultAtFinalCallerFence() async throws {
        let lifetime = OnsiteDocumentExportLifetime()
        lifetime.appear()
        let request = try #require(lifetime.begin())
        let result = try await lifetime.export(request: request, validateCurrent: {}, render: { validate in
            try validate()
            return URL(fileURLWithPath: "/synthetic/finished.pdf")
        })
        lifetime.invalidateRequest()
        do {
            try result.validateCurrent()
            Issue.record("A navigation change was accepted by the final caller fence")
        } catch { #expect(error is CancellationError) }
    }

    @Test func authorizationChangeAfterHandoffIsRejectedBeforeCallerReadsModels() async throws {
        let lifetime = OnsiteDocumentExportLifetime()
        lifetime.appear()
        let request = try #require(lifetime.begin())
        let authorization = AuthorizationState()
        let result = try await lifetime.export(request: request, validateCurrent: {
            guard authorization.allowed else { throw Revoked() }
        }, render: { validate in
            try validate()
            return URL(fileURLWithPath: "/synthetic/finished.pdf")
        })
        authorization.allowed = false
        do {
            try result.validateCurrent()
            Issue.record("Late authorization change reached the caller")
        } catch { #expect(error is Revoked) }
    }

    @Test func rejectedFinalHandoffRemovesOnlyItsNewOutput() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let prior = folder.appendingPathComponent("prior.pdf")
        let output = folder.appendingPathComponent("new.pdf")
        let priorBytes = Data("prior customer document".utf8)
        try priorBytes.write(to: prior)
        let lifetime = OnsiteDocumentExportLifetime()
        lifetime.appear()
        let request = try #require(lifetime.begin())
        let result = try await lifetime.export(request: request, validateCurrent: {}, render: { validate in
            try validate()
            try Data("new customer document".utf8).write(to: output)
            return output
        })
        #expect(FileManager.default.fileExists(atPath: output.path))
        lifetime.invalidateRequest()
        do {
            try result.validateCurrent()
            Issue.record("A rejected output remained eligible for publication")
        } catch { #expect(error is CancellationError) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try Data(contentsOf: prior) == priorBytes)
    }


    @Test func detachedByteReadPreservesExactOutputAndRevalidatesCaller() async throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        let bytes = Data("complete synthetic PDF bytes".utf8)
        try bytes.write(to: output)
        let lifetime = OnsiteDocumentExportLifetime()
        lifetime.appear()
        let request = try #require(lifetime.begin())
        let result = try await lifetime.export(request: request, validateCurrent: {}, render: { _ in output })
        let read = try await result.readData()
        try result.validateCurrent()
        #expect(read == bytes)
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    @Test func revocationDuringByteReadRejectsDataAndRemovesOnlyNewOutput() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("new.pdf")
        let prior = folder.appendingPathComponent("prior.pdf")
        let bytes = Data("new synthetic PDF".utf8)
        let priorBytes = Data("retained original PDF".utf8)
        try bytes.write(to: output)
        try priorBytes.write(to: prior)
        let lifetime = OnsiteDocumentExportLifetime()
        lifetime.appear()
        let request = try #require(lifetime.begin())
        let authorization = AuthorizationState()
        let result = try await lifetime.export(request: request, validateCurrent: {
            guard authorization.allowed else { throw Revoked() }
        }, render: { _ in output })
        let paused = PausedRenderer()
        let task = Task { @MainActor in
            try await result.readData(load: { _ in
                _ = try await paused.render({})
                return bytes
            })
        }
        await paused.waitUntilStarted()
        authorization.allowed = false
        paused.complete()
        do {
            _ = try await task.value
            Issue.record("Revoked PDF bytes reached the persistence caller")
        } catch { #expect(error is Revoked) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try Data(contentsOf: prior) == priorBytes)
    }

    @Test func byteReadFailureStillChecksRevocationBeforeReturningError() async throws {
        struct ReadFailure: Error {}
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        try Data("synthetic PDF".utf8).write(to: output)
        let lifetime = OnsiteDocumentExportLifetime()
        lifetime.appear()
        let request = try #require(lifetime.begin())
        let authorization = AuthorizationState()
        let result = try await lifetime.export(request: request, validateCurrent: {
            guard authorization.allowed else { throw Revoked() }
        }, render: { _ in output })
        let paused = PausedRenderer()
        let task = Task { @MainActor in
            try await result.readData(load: { _ in
                _ = try await paused.render({})
                throw ReadFailure()
            })
        }
        await paused.waitUntilStarted()
        authorization.allowed = false
        paused.complete()
        do {
            _ = try await task.value
            Issue.record("A stale read failure bypassed the authorization fence")
        } catch { #expect(error is Revoked) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

}
