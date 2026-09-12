import Foundation
import LoadSightKit

/// Capture when the user selects evidence, not when a sheet later appears.
/// Drawing snapshots use value semantics; identical bytes reopened in another
/// document session still cannot receive this review's edits.
@MainActor struct DrawingReviewSession {
    let documentSessionID: UUID
    let drawings: DrawingArchive

    init(document: LoadSightDocument) {
        documentSessionID = document.editSessionID
        drawings = document.drawings
    }

    func matches(_ document: LoadSightDocument) -> Bool {
        document.editSessionID == documentSessionID && document.drawings == drawings
    }

    func validate(_ document: LoadSightDocument) throws {
        try require(matches(document), "The project or source drawings changed. Reopen this review for the current project; no edits were applied.")
    }

    func apply(to document: inout LoadSightDocument, _ edit: (inout LoadSightDocument) throws -> Void) throws {
        try validate(document)
        try document.applyEdit(for: documentSessionID, edit)
    }

    func createRFI(from candidate: MechanicalTextCandidate, question: String, impact: String,
                   author: String, in document: inout LoadSightDocument) throws -> String {
        var identifier = ""
        try apply(to: &document) { copy in
            identifier = try copy.project.createRFI(from: candidate, drawings: copy.drawings,
                question: question, impact: impact, author: author)
        }
        return identifier
    }
}

@MainActor struct DrawingReviewSelection<Value>: Identifiable {
    let id = UUID()
    let value: Value
    let session: DrawingReviewSession
    init(document: LoadSightDocument, value: Value) {
        self.value = value
        session = DrawingReviewSession(document: document)
    }
}
