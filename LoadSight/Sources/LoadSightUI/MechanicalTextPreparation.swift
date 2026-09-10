import Foundation
import Combine
import LoadSightKit

/// A scan belongs to one document session and an immutable set of drawing sources.
/// Replacing either invalidates progress, results and late completions together.
@MainActor final class MechanicalTextPreparation: ObservableObject {
    typealias Generator = @Sendable (DrawingArchive, @escaping LoadSightProgressHandler) async throws -> MechanicalTextExtraction
    @Published private(set) var isScanning = false
    @Published private(set) var result: MechanicalTextExtraction?
    @Published private(set) var stage = "Scan imported drawing text to find review candidates."
    @Published private(set) var failure: String?
    private var documentSessionID: UUID?
    private var drawings: DrawingArchive?
    private var generation: UUID?
    private var operation: LoadSightOperation<MechanicalTextExtraction>?
    private var monitor: Task<Void, Never>?
    private let generate: Generator

    init(generate: @escaping Generator = { drawings, progress in
        try await LocalLoadSightService().extractMechanicalText(drawings, progress: progress)
    }) { self.generate = generate }

    func matches(drawings: DrawingArchive, documentSessionID: UUID) -> Bool {
        self.documentSessionID == documentSessionID && self.drawings == drawings
    }

    func updateScope(drawings: DrawingArchive, documentSessionID: UUID) {
        guard self.documentSessionID != nil, !matches(drawings: drawings, documentSessionID: documentSessionID) else { return }
        stop()
        self.drawings = nil; self.documentSessionID = nil
        result = nil; failure = nil
        stage = "Drawing sources or document changed. Scan the current sources again."
    }

    func start(drawings: DrawingArchive, documentSessionID: UUID) {
        stop()
        let id = UUID(), generate = generate
        generation = id; self.drawings = drawings; self.documentSessionID = documentSessionID
        result = nil; failure = nil; isScanning = true; stage = "Scanning imported drawing text"
        let job = LoadSightOperation { progress in try await generate(drawings, progress) }
        operation = job
        monitor = Task { [weak self] in
            let observer = Task { [weak self] in
                for await event in job.progress {
                    guard !Task.isCancelled, self?.generation == id, self?.isScanning == true else { return }
                    self?.stage = event.stage
                }
            }
            defer { observer.cancel() }
            do {
                let extracted = try await job.result
                guard let self, self.generation == id, !Task.isCancelled else { return }
                self.isScanning = false; self.operation = nil; self.monitor = nil
                self.stage = "Scan complete. Every candidate still requires source review."
                self.result = extracted
            } catch {
                guard let self, self.generation == id else { return }
                self.isScanning = false; self.operation = nil; self.monitor = nil
                self.stage = error is CancellationError ? "Scan cancelled" : "Unable to scan drawing text"
                self.failure = error is CancellationError ? nil : error.localizedDescription
            }
        }
    }

    func cancel() {
        let wasScanning = isScanning
        stop()
        if wasScanning { result = nil; failure = nil; stage = "Scan cancelled" }
    }

    private func stop() {
        generation = nil
        operation?.cancel(); monitor?.cancel()
        operation = nil; monitor = nil; isScanning = false
    }

    deinit { operation?.cancel(); monitor?.cancel() }
}
