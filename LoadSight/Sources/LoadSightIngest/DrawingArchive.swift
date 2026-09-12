import Foundation
import CryptoKit
import LoadSightCore

public struct DrawingBounds: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(_ rect: CGRect) { x = rect.minX; y = rect.minY; width = rect.width; height = rect.height }
    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    public func validate() throws {
        try require([x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0, "Invalid drawing bounds.")
    }
}

public struct DrawingText: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var text: String
    public var bounds: DrawingBounds
    public var method: String
    /// Recognition confidence, not confidence in engineering interpretation.
    public var confidence: Double
}

public struct DrawingPage: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var number: Int
    public var bounds: DrawingBounds
    public var rotation: Int
    public var text: [DrawingText]
    public var sheetCandidates: [String]
    public var warnings: [String]
}

public struct DrawingRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var filename: String
    public var kind: String
    public var byteCount: Int
    public var pages: [DrawingPage]
}

/// Original files keyed by SHA-256, so aliases/reimports cannot duplicate physical pages.
public struct DrawingArchive: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public private(set) var records: [DrawingRecord] = []
    public private(set) var files: [String: Data] = [:]
    public init() {}
    public static func fingerprint(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public mutating func insert(record: DrawingRecord, data: Data) throws {
        var candidate = self
        if let existing = records.first(where: { $0.id == record.id }) {
            try require(existing.byteCount == data.count && files[record.id] == data, "Conflicting drawing fingerprint.")
            return
        }
        candidate.records.append(record); candidate.files[record.id] = data
        try candidate.validate(); self = candidate
    }
    public func validate() throws {
        try require(schemaVersion == 1, "Unsupported drawing archive version.")
        try require(records.count <= 500 && Set(records.map(\.id)).count == records.count, "Duplicate or excessive drawing sources.")
        try require(Set(records.map(\.id)) == Set(files.keys), "Drawing index and source files disagree.")
        for record in records {
            guard let data = files[record.id] else { throw LoadSightError.invalid("Drawing source is missing.") }
            try require(record.id == Self.fingerprint(data) && record.byteCount == data.count, "Drawing fingerprint mismatch: \(record.filename)")
            try require(["pdf", "image"].contains(record.kind) && !record.filename.isEmpty, "Invalid drawing source type or name.")
            try require(!record.pages.isEmpty && record.pages.count <= 1000, "Invalid drawing page count.")
            for (offset, page) in record.pages.enumerated() {
                try require(page.number == offset + 1 && page.id == "\(record.id):\(page.number)", "Invalid source page identity.")
                try page.bounds.validate()
                try require(Set(page.text.map(\.id)).count == page.text.count, "Duplicate text anchors.")
                for anchor in page.text {
                    try anchor.bounds.validate()
                    try require(anchor.confidence.isFinite && (0...1).contains(anchor.confidence) && !anchor.text.isEmpty, "Invalid text evidence.")
                }
            }
        }
    }
    public func projectJSON() throws -> JSONValue {
        try validate()
        return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(self))
    }
    public init(projectJSON: JSONValue) throws {
        if projectJSON == .null { self.init(); return }
        self = try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(projectJSON))
        try validate()
    }
}
