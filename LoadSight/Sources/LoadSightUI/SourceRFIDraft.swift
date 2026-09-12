import LoadSightKit

/// Shared local composer state for mechanical text and schedule findings.
/// A successful save freezes the fields; errors keep the exact draft for retry.
@MainActor struct SourceRFIDraft: Equatable {
    var question = ""
    var impact = ""
    var author = ""
    private(set) var savedID: String?

    var canEdit: Bool { savedID == nil }
    var isDirty: Bool { canEdit && [question, impact, author].contains { !$0.isEmpty } }
    func canSave(session: DrawingReviewSession, in document: LoadSightDocument) -> Bool {
        canEdit && session.matches(document)
    }

    mutating func save(session: DrawingReviewSession, in document: inout LoadSightDocument,
                       create: (inout LoadSightDocument, SourceRFIDraft) throws -> String) throws {
        try require(canEdit, "This RFI is already saved. Open it in RFIs to make further changes.")
        let content = self
        var identifier: String?
        try session.apply(to: &document) { copy in
            let result = try create(&copy, content)
            try require(!result.isEmpty, "The RFI did not return a saved identity. No changes were applied.")
            identifier = result
        }
        savedID = identifier
    }
}
