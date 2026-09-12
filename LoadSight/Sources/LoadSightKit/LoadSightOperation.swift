import Foundation
import Combine

/// Progress callbacks may arrive concurrently or outlive their worker. All mutable
/// terminal state is locked; yielding is nonblocking and never awaits a consumer.
private final class OperationProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncStream<LoadSightProgress>.Continuation
    private var finished = false
    init(_ continuation: AsyncStream<LoadSightProgress>.Continuation) { self.continuation = continuation }
    func report(_ event: LoadSightProgress) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        let total = max(1, event.totalUnits)
        continuation.yield(.init(phase: .running, stage: event.stage,
            completedUnits: min(total, max(0, event.completedUnits)), totalUnits: total))
    }
    func finish(phase: LoadSightProgress.Phase, stage: String) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        continuation.yield(.init(phase: phase, stage: stage, completedUnits: phase == .succeeded ? 1 : 0, totalUnits: 1))
        continuation.finish()
    }
}

/// An explicitly owned task with one progress stream. Use the Combine adapter to multicast progress.
/// Stopping progress observation does not cancel the task; cancel() or cancellation of result does.
public struct LoadSightOperation<Output: Sendable>: Sendable {
    public let id: UUID
    public let progress: AsyncStream<LoadSightProgress>
    private let task: Task<Output, Error>
    public init(priority: TaskPriority? = nil, work: @escaping @Sendable (@escaping LoadSightProgressHandler) async throws -> Output) {
        id = UUID()
        let stream = AsyncStream<LoadSightProgress>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let gate = OperationProgressGate(stream.continuation)
        progress = stream.stream
        task = Task.detached(priority: priority) {
            do {
                try Task.checkCancellation()
                gate.report(.init(stage: "Starting", completedUnits: 0, totalUnits: 1))
                let result = try await work { event in gate.report(event) }
                try Task.checkCancellation()
                gate.finish(phase: .succeeded, stage: "Completed")
                return result
            } catch {
                let cancelled = error is CancellationError || Task.isCancelled
                gate.finish(phase: cancelled ? .cancelled : .failed, stage: cancelled ? "Cancelled" : "Failed")
                if cancelled { throw CancellationError() }
                throw error
            }
        }
    }
    public func cancel() { task.cancel() }
    public var result: Output {
        get async throws {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let value = try await task.value
                try Task.checkCancellation()
                return value
            } onCancel: { task.cancel() }
        }
    }
}

/// Observe on the main actor. Subscribers receive the latest event, including the terminal phase.
@MainActor public final class LoadSightProgressPublisher {
    private let subject = CurrentValueSubject<LoadSightProgress?, Never>(nil)
    private var observation: Task<Void, Never>?
    public var publisher: AnyPublisher<LoadSightProgress, Never> { subject.compactMap { $0 }.eraseToAnyPublisher() }
    public init(_ stream: AsyncStream<LoadSightProgress>) {
        observation = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { break }
                self?.subject.send(event)
            }
        }
    }
    public func stopObserving() { observation?.cancel(); observation = nil }
    deinit { observation?.cancel() }
}
