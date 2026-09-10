import Foundation
import LoadSightKit

/// The draft, map revision, source archive and document identity are one capture.
@MainActor struct ScheduleMapEditSession: Identifiable {
    let id = UUID()
    let mapID: UUID?
    let context: DrawingReviewSession
    let fingerprint: String
    let draft: ScheduleMapDraft

    init(document: LoadSightDocument, mapID: UUID? = nil, request: EquipmentScheduleRequest? = nil) throws {
        context = DrawingReviewSession(document: document)
        fingerprint = try document.project.scheduleMapEditFingerprint()
        self.mapID = mapID
        if let mapID {
            guard request == nil, let map = try document.project.scheduleMaps().first(where: { $0.id == mapID }) else {
                throw LoadSightError.invalid("The saved schedule map changed or is missing. Reopen the current map.")
            }
            draft = ScheduleMapDraft(drawings: context.drawings, name: map.name, request: try map.columnMap())
        } else {
            draft = ScheduleMapDraft(drawings: context.drawings, request: request)
        }
    }

    func save(_ draft: ScheduleMapDraft, author: String, reason: String, in document: inout LoadSightDocument) throws {
        try context.apply(to: &document) { copy in
            try copy.project.saveScheduleMap(id: mapID, name: draft.name, request: draft.request(author: author),
                drawings: copy.drawings, expectedFingerprint: fingerprint, author: author, reason: reason)
        }
    }

    func remove(author: String, reason: String, in document: inout LoadSightDocument) throws {
        guard let mapID else { throw LoadSightError.invalid("This map has not been saved.") }
        try context.apply(to: &document) { copy in
            try copy.project.removeScheduleMap(id: mapID, drawings: copy.drawings,
                expectedFingerprint: fingerprint, author: author, reason: reason)
        }
    }
}
