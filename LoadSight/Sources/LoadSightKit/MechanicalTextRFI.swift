import Foundation

public extension ProjectDocument {
    /// Creates a local unanswered RFI from a still-current text occurrence, never a quantity or approved design input.
    mutating func createRFI(from candidate: MechanicalTextCandidate, drawings: DrawingArchive, question: String, impact: String, author: String) throws -> String {
        try candidate.validate(in: drawings)
        try validateDrawingEvidence(in: drawings)
        return try saveRFI(draft: .init(title: "Review drawing text: " + candidate.matchedText,
            question: question, source: "[text-candidate:\(candidate.id)] " + candidate.sourceDescription,
            impact: impact), author: author)
    }
}
