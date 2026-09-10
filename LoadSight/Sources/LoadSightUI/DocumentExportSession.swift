import Foundation
import LoadSightKit

/// Keep one immutable export snapshot until its completion or cancellation.
/// A receipt can update only the document session that initiated the export.
struct DocumentExportSession {
    private(set) var snapshot: LoadSightDocument?
    var isExporting: Bool { snapshot != nil }

    mutating func begin(_ document: LoadSightDocument) throws {
        guard snapshot == nil else { throw LoadSightError.invalid("An export is already in progress.") }
        try document.validateMarkup()
        snapshot = document
    }

    mutating func finish(for documentSessionID: UUID) -> LoadSightDocument? {
        defer { snapshot = nil }
        guard let snapshot, snapshot.editSessionID == documentSessionID else { return nil }
        return snapshot
    }

    mutating func cancel() { snapshot = nil }
}
