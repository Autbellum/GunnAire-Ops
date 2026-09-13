import Foundation

public extension LocalLoadSightService {
    func discoverEquipmentSchedules(_ drawings: DrawingArchive, progress: @escaping LoadSightProgressHandler = { _ in }) async throws -> EquipmentScheduleDiscovery {
        try EquipmentScheduleDiscoverer.discover(drawings) { done, total in
            progress(.init(stage: "Finding schedule headers and tag rows", completedUnits: done, totalUnits: total))
        }
    }
    func prepareDiscoveredSchedule(_ candidate: EquipmentScheduleCandidate, drawings: DrawingArchive) async throws -> EquipmentScheduleRequest {
        try candidate.draftRequest(in: drawings)
    }

    /// Extract literal row candidates from explicit table/column mappings. Never updates takeoff or approves evidence.
    func extractEquipmentSchedules(_ drawings: DrawingArchive, request: EquipmentScheduleRequest,
                                   progress: @escaping LoadSightProgressHandler = { _ in }) async throws -> EquipmentScheduleExtraction {
        try EquipmentScheduleExtractor.extract(drawings, request: request) { done, total in
            progress(.init(stage: "Reading mapped schedule regions", completedUnits: done, totalUnits: total))
        }
    }
}
