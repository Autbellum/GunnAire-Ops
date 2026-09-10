import Foundation

public extension LocalLoadSightService {
    /// Extract literal row candidates from explicit table/column mappings. Never updates takeoff or approves evidence.
    func extractEquipmentSchedules(_ drawings: DrawingArchive, request: EquipmentScheduleRequest,
                                   progress: @escaping LoadSightProgressHandler = { _ in }) async throws -> EquipmentScheduleExtraction {
        try EquipmentScheduleExtractor.extract(drawings, request: request) { done, total in
            progress(.init(stage: "Reading mapped schedule regions", completedUnits: done, totalUnits: total))
        }
    }
}
