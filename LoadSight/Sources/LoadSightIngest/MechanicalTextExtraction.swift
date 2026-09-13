import Foundation
import CryptoKit
import LoadSightCore

public enum MechanicalTextKind: String, Codable, Sendable {
    case equipmentTag, airflow, thermalRating
    public var title: String {
        switch self { case .equipmentTag: "Equipment-tag text"; case .airflow: "Airflow text"; case .thermalRating: "Thermal-rating text" }
    }
}

/// A text occurrence, never a physical equipment count or an assigned schedule value.
public struct MechanicalTextCandidate: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: MechanicalTextKind
    public let sourceID: String
    public let filename: String
    public let pageID: String
    public let pageNumber: Int
    public let coordinateSpace: String
    public let anchor: DrawingText
    public let utf16Location: Int
    public let utf16Length: Int
    public let matchedText: String
    public var needsRecognitionCheck: Bool { anchor.confidence < 0.75 }
    public var sourceDescription: String {
        "\(filename), page \(pageNumber); source SHA-256 \(sourceID); anchor \(anchor.id); \(coordinateSpace), bounds x=\(anchor.bounds.x), y=\(anchor.bounds.y), w=\(anchor.bounds.width), h=\(anchor.bounds.height); UTF-16 range \(utf16Location):\(utf16Length); \(anchor.method), recognition confidence \(anchor.confidence). Candidate text: \(matchedText). Full anchor: \(anchor.text)"
    }
    public func validate(in archive: DrawingArchive) throws {
        try Task.checkCancellation()
        try archive.validate()
        guard let source = archive.records.first(where: { $0.id == sourceID }),
              source.filename == filename,
              let page = source.pages.first(where: { $0.id == pageID && $0.number == pageNumber }),
              let current = page.text.first(where: { $0.id == anchor.id }), current == anchor else {
            throw LoadSightError.invalid("Extraction source changed or is unavailable. Extract and review this text again.")
        }
        try MechanicalTextExtractor.validate(self, source: source, page: page, anchor: current)
    }
}

public struct MechanicalTextExtraction: Codable, Sendable {
    public let method: String
    public let sourceCount: Int
    public let pageCount: Int
    public let candidates: [MechanicalTextCandidate]
    public let limitations: [String]
}

public enum MechanicalTextExtractor {
    public static let method = "Mechanical text occurrences v1"
    public static let limitations = [
        "Every occurrence requires visual/source review. Recognition confidence is not engineering confidence.",
        "Tags may occur in legends, schedules, details and repeated views. Occurrence counts are not physical quantities.",
        "Values are not assigned to equipment, converted to design inputs, or interpreted as supply/outdoor/exhaust airflow or heating/cooling/input/output capacity.",
        "Source bounds cover the whole text anchor, not an independently localized symbol or exact token rectangle.",
        "No linework, symbols, room geometry, scale, lifecycle, complete schedule rows, manufacturers or cross-view reconciliation are extracted by this method."
    ]
    private static let patterns: [(MechanicalTextKind, String)] = [
        (.equipmentTag, #"(?<![A-Za-z0-9_-])(?:RTU|AHU|MAU|DOAS|FCU|VAV|CU|HP|EF|SF|RF|UH)[ -]*\d+[A-Za-z]?(?![A-Za-z0-9_-])"#),
        (.airflow, #"(?<![\w.,+\-])[-+]?\d+(?:,\d{3})*(?:\.\d+)?\s*CFM(?![A-Za-z])"#),
        (.thermalRating, #"(?<![\w.,+\-])[-+]?\d+(?:,\d{3})*(?:\.\d+)?\s*(?:MBH|BTU\s*/\s*(?:HR|H)|BTUH)(?![A-Za-z])"#)
    ]
    public static func extract(_ archive: DrawingArchive, progress: @Sendable (Int, Int) -> Void = { _, _ in }) throws -> MechanicalTextExtraction {
        try Task.checkCancellation(); try archive.validate()
        let total = archive.records.reduce(0) { $0 + $1.pages.count }
        var result: [MechanicalTextCandidate] = [], processed = 0
        for source in archive.records.sorted(by: { $0.id < $1.id }) {
            for page in source.pages {
                try Task.checkCancellation()
                for anchor in page.text.sorted(by: { $0.id < $1.id }) {
                    try Task.checkCancellation()
                    result += try candidates(source: source, page: page, anchor: anchor)
                    try require(result.count <= 100_000, "Text extraction exceeds 100,000 candidates. Review a smaller drawing set.")
                }
                processed += 1; progress(processed, total)
            }
        }
        try Task.checkCancellation()
        return .init(method: method, sourceCount: archive.records.count, pageCount: total, candidates: result, limitations: limitations)
    }
    fileprivate static func candidates(source: DrawingRecord, page: DrawingPage, anchor: DrawingText) throws -> [MechanicalTextCandidate] {
        let text = anchor.text as NSString
        try require(text.length <= 100_000, "Text anchor is too large for candidate extraction.")
        let evidence = try anchorEvidence(anchor)
        var result: [MechanicalTextCandidate] = []
        for (kind, pattern) in patterns {
            try Task.checkCancellation()
            let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            for match in regex.matches(in: anchor.text, range: NSRange(location: 0, length: text.length)) {
                try Task.checkCancellation()
                result.append(try candidate(kind: kind, range: match.range, source: source, page: page, anchor: anchor, evidence: evidence))
            }
        }
        return result.sorted { $0.utf16Location == $1.utf16Location ? $0.kind.rawValue < $1.kind.rawValue : $0.utf16Location < $1.utf16Location }
    }

    fileprivate static func validate(_ value: MechanicalTextCandidate, source: DrawingRecord, page: DrawingPage, anchor: DrawingText) throws {
        try Task.checkCancellation()
        let text = anchor.text as NSString
        try require(text.length <= 100_000, "Text anchor is too large for candidate extraction.")
        guard let (_, pattern) = patterns.first(where: { $0.0 == value.kind }) else {
            throw LoadSightError.invalid("Unsupported extraction candidate kind.")
        }
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        // Match against the full anchor to preserve the v1 lookaround/word-boundary rules.
        // Hash only the selected occurrence, not every sibling in a large text anchor.
        let match = regex.matches(in: anchor.text, range: NSRange(location: 0, length: text.length)).first {
            $0.range.location == value.utf16Location && $0.range.length == value.utf16Length
        }
        try Task.checkCancellation()
        guard let match else { throw LoadSightError.invalid("Extraction candidate differs from its source text or matching rule.") }
        let expected = try candidate(kind: value.kind, range: match.range, source: source, page: page, anchor: anchor, evidence: anchorEvidence(anchor))
        try require(value == expected, "Extraction candidate differs from its source text or matching rule.")
    }

    private static func anchorEvidence(_ anchor: DrawingText) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(anchor))
    }

    private static func candidate(kind: MechanicalTextKind, range: NSRange, source: DrawingRecord, page: DrawingPage, anchor: DrawingText, evidence: JSONValue) throws -> MechanicalTextCandidate {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let coordinateSpace = source.kind == "pdf" ? "PDF page points, bottom-left origin" : "Oriented image pixels, bottom-left origin"
        // Keep the complete v1 identity recipe: existing RFI source references must remain stable.
        let identity: JSONValue = .object(["method": .string(method), "source": .string(source.id), "page": .string(page.id), "anchor": evidence, "coordinates": .string(coordinateSpace), "kind": .string(kind.rawValue), "offset": .number(Double(range.location)), "length": .number(Double(range.length))])
        let id = SHA256.hash(data: try encoder.encode(identity)).map { String(format: "%02x", $0) }.joined()
        return .init(id: id, kind: kind, sourceID: source.id, filename: source.filename, pageID: page.id, pageNumber: page.number, coordinateSpace: coordinateSpace, anchor: anchor, utf16Location: range.location, utf16Length: range.length, matchedText: (anchor.text as NSString).substring(with: range))
    }
}
