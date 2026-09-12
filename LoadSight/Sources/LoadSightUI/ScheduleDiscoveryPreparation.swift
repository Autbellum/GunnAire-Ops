import Foundation
import Combine
import LoadSightKit

@MainActor final class ScheduleDiscoveryPreparation: ObservableObject {
    @Published private(set) var result: EquipmentScheduleDiscovery?
    @Published private(set) var stage = "Find possible tables in the imported drawing text."
    @Published private(set) var failure: String?
    @Published private(set) var isScanning = false
    private var operation: LoadSightOperation<EquipmentScheduleDiscovery>?
    private var monitor: Task<Void, Never>?
    private var generation: UUID?
    private var archive: DrawingArchive?
    private var documentSessionID: UUID?
    func start(drawings: DrawingArchive, documentSessionID: UUID) {
        cancel(); self.archive = drawings; self.documentSessionID = documentSessionID
        let token = UUID(); generation = token; isScanning = true; failure = nil; stage = "Finding schedule headers and tag rows"
        let job = LoadSightOperation { progress in
            try await LocalLoadSightService().discoverEquipmentSchedules(drawings, progress: progress)
        }
        operation = job
        monitor = Task { [weak self] in
            let observer = Task { [weak self] in
                for await event in job.progress {
                    guard self?.generation == token else { return }
                    self?.stage = event.stage
                }
            }
            defer { observer.cancel() }
            do {
                let result = try await job.result; await observer.value
                guard let self, self.generation == token else { return }
                self.result = result; self.isScanning = false; self.operation = nil; self.monitor = nil
                self.stage = "Possible tables ready. Review headers and inferred bounds on the source."
            } catch {
                guard let self, self.generation == token else { return }
                self.isScanning = false; self.operation = nil; self.monitor = nil
                self.failure = error is CancellationError ? nil : error.localizedDescription
                self.stage = error is CancellationError ? "Schedule scan cancelled" : "Unable to discover schedules"
            }
        }
    }
    func matches(drawings: DrawingArchive, documentSessionID: UUID) -> Bool { archive == drawings && self.documentSessionID == documentSessionID }
    func cancel() {
        let wasScanning = isScanning
        generation = nil; operation?.cancel(); operation = nil; monitor?.cancel(); monitor = nil
        isScanning = false; result = nil; failure = nil; archive = nil; documentSessionID = nil
        if wasScanning { stage = "Schedule scan cancelled" }
    }
}
