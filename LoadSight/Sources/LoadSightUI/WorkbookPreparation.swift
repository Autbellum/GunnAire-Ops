import Foundation
import Combine
import LoadSightKit

/// Owns generation only. The host owns the save panel and never marks a project saved from an XLSX receipt.
@MainActor final class WorkbookPreparation: ObservableObject {
    typealias Generator = @Sendable (ProjectDocument, DrawingArchive, @escaping LoadSightProgressHandler) async throws -> Data
    @Published private(set) var isPreparing = false
    @Published private(set) var stage = ""
    @Published private(set) var readyID: UUID?
    @Published private(set) var failure: String?
    private(set) var data: Data?
    private(set) var documentSessionID: UUID?
    private var generation: UUID?
    private var operation: LoadSightOperation<Data>?
    private var monitor: Task<Void, Never>?
    private let generate: Generator
    init(generate: @escaping Generator = { project, drawings, progress in
        try await LocalLoadSightService().exportTakeoff(project, drawings: drawings, progress: progress)
    }) { self.generate = generate }
    func start(project: ProjectDocument, drawings: DrawingArchive, documentSessionID: UUID) {
        guard !isPreparing && readyID == nil else { return }
        cancel()
        let id = UUID(), generate = generate
        generation = id; self.documentSessionID = documentSessionID
        isPreparing = true; stage = "Preparing workbook"; failure = nil
        let job = LoadSightOperation { progress in try await generate(project, drawings, progress) }
        operation = job
        monitor = Task { [weak self] in
            let observer = Task { [weak self] in
                for await event in job.progress {
                    guard !Task.isCancelled, self?.generation == id, self?.isPreparing == true else { return }
                    self?.stage = event.stage
                }
            }
            defer { observer.cancel() }
            do {
                let bytes = try await job.result
                guard let self, self.generation == id, !Task.isCancelled else { return }
                self.data = bytes; self.isPreparing = false; self.stage = "Workbook ready"
                self.readyID = id; self.operation = nil; self.monitor = nil
            } catch {
                guard let self, self.generation == id else { return }
                self.isPreparing = false; self.operation = nil; self.monitor = nil
                if error is CancellationError { self.stage = "Workbook preparation cancelled" }
                else { self.failure = error.localizedDescription; self.stage = "Workbook preparation failed" }
            }
        }
    }
    @discardableResult func finish(receiptID: UUID?, currentDocumentSessionID: UUID) -> Bool {
        guard let receiptID, receiptID == readyID, documentSessionID == currentDocumentSessionID else { return false }
        cancel(); return true
    }
    func cancel() {
        generation = nil; operation?.cancel(); monitor?.cancel()
        operation = nil; monitor = nil; isPreparing = false
        data = nil; readyID = nil; documentSessionID = nil
        failure = nil; stage = "Workbook preparation cancelled"
    }
    deinit { operation?.cancel(); monitor?.cancel() }
}
