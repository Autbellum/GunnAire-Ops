import Foundation

/// Historical snapshot; decoding this record does not validate it against current source drawings.
public struct ScheduleRFIEvidence: Codable, Sendable {
    public let schemaVersion: Int
    public let row: EquipmentScheduleRow
    public let finding: ScheduleConsistencyCheck
    public let screeningMethod: String
    public let limitations: String
}

public extension ProjectDocument {
    /// Atomically records an unanswered question and linked evidence after re-extracting the source row.
    mutating func createRFI(from row: EquipmentScheduleRow, findingID: String, drawings: DrawingArchive,
                            question: String, impact: String, author: String) throws -> String {
        try row.validate(in: drawings)
        try validateDrawingEvidence(in: drawings)
        let review = row.consistencyReview
        guard let finding = review.checks.first(where: { $0.id == findingID }) else {
            throw LoadSightError.invalid("Schedule finding is missing or changed. Read and review the current row again.")
        }
        let snapshot = ScheduleRFIEvidence(schemaVersion: 1, row: row, finding: finding,
                                           screeningMethod: review.method, limitations: review.limitations)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(snapshot), fingerprint = ProjectAttachment.fingerprint(data)
        let bounds = row.rowBounds
        let literal = row.cells.filter { finding.fields.contains($0.field) }.map {
            "\($0.field.rawValue): \($0.text ?? "Unknown — no recognized value"); header units: \($0.unitText ?? "Not recorded")"
        }.joined(separator: "\n")
        let source = """
        [schedule-row:\(row.id)] [schedule-check:\(finding.id)]
        \(row.filename), page \(row.pageNumber), tag \(row.tag)
        Original SHA-256: \(row.sourceID); page identity: \(row.pageID)
        Row bounds: x=\(bounds.x), y=\(bounds.y), width=\(bounds.width), height=\(bounds.height)
        Mapping recorded by: \(row.region.recordedBy). Basis: \(row.region.mappingBasis)
        \(literal.isEmpty ? "Affected columns are not mapped; source applicability requires review." : literal)
        Finding (\(finding.status.rawValue)): \(finding.detail)
        Evidence attachment SHA-256: \(fingerprint)
        \(review.limitations)
        """
        var copy = self
        let id = try copy.saveRFI(draft: .init(title: "Schedule clarification: " + row.tag, question: question,
                                             source: source, impact: impact), author: author)
        try copy.addAttachment(data: data, filename: "schedule-evidence-\(row.id).json", author: author,
                               source: "Historical schedule row/finding snapshot; original SHA-256 \(row.sourceID)", rfiID: id)
        try copy.validateDrawingEvidence(in: drawings)
        self = copy
        return id
    }
}
