import Foundation
import Testing
@testable import GunnAire_Ops

@MainActor
struct LocalAIWorkspaceGenerationTests {
    @MainActor private final class Session {
        var stamp: CompanyWorkspaceOperationStamp? = .init(generation: UUID(), session: .init(
            backendOrigin: "https://fixture.invalid", email: "staff@example.invalid",
            tokenFingerprint: "synthetic-session", expiresAt: .distantFuture))
    }

    @MainActor private final class DelayedService {
        private(set) var requests: [GunnAireLocalAIAssistRequest] = []
        private var replies: [Int: CheckedContinuation<GunnAireLocalAIAssistResponse, Error>] = [:]
        private var waiting: [(Int, CheckedContinuation<Void, Never>)] = []

        func send(_ request: GunnAireLocalAIAssistRequest) async throws -> GunnAireLocalAIAssistResponse {
            try await withCheckedThrowingContinuation { continuation in
                let index = requests.count
                requests.append(request)
                replies[index] = continuation
                let ready = waiting.filter { $0.0 <= requests.count }
                waiting.removeAll { $0.0 <= requests.count }
                for (_, waiter) in ready { waiter.resume() }
            }
        }

        func waitForRequests(_ count: Int) async {
            guard requests.count < count else { return }
            await withCheckedContinuation { waiting.append((count, $0)) }
        }

        func succeed(_ index: Int, task: String? = nil) throws {
            let pending = replies.removeValue(forKey: index)
            let reply = try #require(pending)
            let result = try JSONDecoder().decode(GunnAireLocalAIResult.self,
                from: Data("{\"body\":\"Synthetic reviewed facts\"}".utf8))
            let responseTask: String
            if let task { responseTask = task } else { responseTask = requests[index].task }
            reply.resume(returning: .init(requestID: "synthetic-\(index)", generatedAt: "2026-09-23T00:00:00Z",
                task: responseTask, provider: "ollama", model: "synthetic-model",
                local: true, cached: false, advisoryOnly: true, hostedFallbackUsed: false,
                hostedCreditsUsed: 0, stableDiffusionUsed: false, needsHumanApproval: true,
                redactions: 0, inputDigest: "synthetic-digest", metrics: .init(elapsedSeconds: nil,
                    promptEvalCount: nil, evalCount: nil), result: result))
        }

        func fail(_ index: Int) throws {
            let pending = replies.removeValue(forKey: index)
            let reply = try #require(pending)
            reply.resume(throwing: URLError(.networkConnectionLost))
        }
    }

    private func controller(_ session: Session, _ service: DelayedService,
                            role: AppUserRole? = .admin) -> GunnAireLocalAIGenerationController {
        let value = GunnAireLocalAIGenerationController(role: role,
            currentSession: { session.stamp }, assist: { try await service.send($0) })
        value.selectedTask = .customerEmailDraft
        value.verifiedInput = "Original verified facts"
        return value
    }

    private func request(_ controller: GunnAireLocalAIGenerationController) -> GunnAireLocalAIAssistRequest {
        .init(task: controller.selectedTask.rawValue, input: controller.requestInput)
    }

    @Test func unchangedRequestPublishesAndClearsBusyState() async throws {
        let session = Session(), service = DelayedService()
        let model = controller(session, service)
        let task = try #require(model.generate(request(model)))
        await service.waitForRequests(1)
        #expect(model.isGenerating)
        #expect(!model.canGenerate)
        try service.succeed(0)
        await task.value
        #expect(model.response?.requestID == "synthetic-0")
        #expect(model.response?.task == GunnAireLocalAITask.customerEmailDraft.rawValue)
        #expect(model.message == nil)
        #expect(!model.isGenerating)
        #expect(model.canGenerate)
    }

    @Test func changingTaskDiscardsOldReplyWithoutClearingNewRequestBusyState() async throws {
        let session = Session(), service = DelayedService()
        let model = controller(session, service)
        let old = try #require(model.generate(request(model)))
        await service.waitForRequests(1)
        model.selectedTask = .customerTextDraft
        #expect(model.verifiedInput.isEmpty)
        #expect(!model.isGenerating)
        model.verifiedInput = "New text facts"
        let current = try #require(model.generate(request(model)))
        await service.waitForRequests(2)
        try service.succeed(0)
        await old.value
        #expect(model.response == nil)
        #expect(model.isGenerating)
        try service.succeed(1)
        await current.value
        #expect(model.response?.requestID == "synthetic-1")
        #expect(model.response?.task == GunnAireLocalAITask.customerTextDraft.rawValue)
        #expect(!model.isGenerating)
    }

    @Test func editedFactsDiscardLateFailureAfterReplacementSucceeded() async throws {
        let session = Session(), service = DelayedService()
        let model = controller(session, service)
        let old = try #require(model.generate(request(model)))
        await service.waitForRequests(1)
        model.verifiedInput = "Corrected verified facts"
        #expect(!model.isGenerating)
        let current = try #require(model.generate(request(model)))
        await service.waitForRequests(2)
        try service.succeed(1)
        await current.value
        try service.fail(0)
        await old.value
        #expect(model.response?.requestID == "synthetic-1")
        #expect(model.message == nil)
        #expect(!model.isGenerating)
        model.verifiedInput = "Further correction"
        #expect(model.response == nil)
    }

    @Test func sessionReplacementIsCheckedAfterAwaitWithoutWaitingForViewNotification() async throws {
        let session = Session(), service = DelayedService()
        let original = try #require(session.stamp)
        let model = controller(session, service)
        let task = try #require(model.generate(request(model)))
        await service.waitForRequests(1)
        session.stamp = .init(generation: UUID(), session: original.session)
        try service.succeed(0)
        await task.value
        #expect(model.response == nil)
        #expect(model.message != nil)
        #expect(!model.isGenerating)
        session.stamp = original
        #expect(model.generate(request(model)) == nil)
        #expect(service.requests.count == 1)
    }

    @Test func signOutImmediatelyClearsBusyAndCannotPublishLateFailure() async throws {
        let session = Session(), service = DelayedService()
        let model = controller(session, service)
        let task = try #require(model.generate(request(model)))
        await service.waitForRequests(1)
        session.stamp = nil
        model.checkSession()
        let accessMessage = model.message
        #expect(!model.isGenerating)
        #expect(!model.canGenerate)
        try service.fail(0)
        await task.value
        #expect(model.response == nil)
        #expect(model.message == accessMessage)
    }

    @Test func sessionChangesBeforeScheduledSendNeverReachService() async throws {
        let session = Session(), service = DelayedService()
        let model = controller(session, service)
        let task = try #require(model.generate(request(model)))
        session.stamp = nil
        await task.value
        #expect(service.requests.isEmpty)
        #expect(model.response == nil)
        #expect(model.message != nil)
        #expect(!model.isGenerating)
    }

    @Test func disappearanceInvalidatesReplyAndAllowsFreshRequestWithoutStuckBusyState() async throws {
        let session = Session(), service = DelayedService()
        let model = controller(session, service)
        let old = try #require(model.generate(request(model)))
        await service.waitForRequests(1)
        model.invalidate()
        #expect(!model.isGenerating)
        try service.succeed(0)
        await old.value
        #expect(model.response == nil)
        let current = try #require(model.generate(request(model)))
        await service.waitForRequests(2)
        try service.succeed(1)
        await current.value
        #expect(model.response?.requestID == "synthetic-1")
    }

    @Test func accessChangesAndUnresolvedRolesCannotDispatch() {
        let session = Session(), service = DelayedService()
        let unresolved = controller(session, service, role: nil)
        #expect(unresolved.generate(request(unresolved)) == nil)
        let changed = controller(session, service)
        changed.invalidateAccess()
        #expect(changed.generate(request(changed)) == nil)
        #expect(service.requests.isEmpty)
    }

    @Test func mismatchedRequestAndResponseTasksAreRejected() async throws {
        let session = Session(), service = DelayedService()
        let model = controller(session, service)
        #expect(model.generate(.init(task: GunnAireLocalAITask.customerTextDraft.rawValue,
            input: model.requestInput)) == nil)
        #expect(model.generate(.init(task: model.selectedTask.rawValue, input: "Obsolete facts")) == nil)
        let task = try #require(model.generate(request(model)))
        await service.waitForRequests(1)
        try service.succeed(0, task: GunnAireLocalAITask.customerTextDraft.rawValue)
        await task.value
        #expect(model.response == nil)
        #expect(model.message != nil)
        #expect(!model.isGenerating)
    }
}
