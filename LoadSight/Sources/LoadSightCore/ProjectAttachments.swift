import Foundation
import CryptoKit

public struct AttachmentReference: Codable, Equatable, Sendable {
    public let filename: String
    public let author: String
    public let source: String
    public let rfiID: String?
    public let at: Date
}
public struct ProjectAttachment: Codable, Identifiable, Sendable {
    public let id: String
    public let data: Data
    public var references: [AttachmentReference]
    public var filename: String { references.first?.filename ?? "attachment" }
    public static let maximumBytes = 64 * 1024 * 1024
    public static func fingerprint(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public func validate() throws {
        try require(data.count <= Self.maximumBytes, "Attachments are limited to 64 MB each in this version.")
        try require(id == Self.fingerprint(data), "Attachment bytes do not match the stored fingerprint.")
        try require(!references.isEmpty, "Attachment source information is missing.")
        for reference in references {
            try require(!reference.filename.isEmpty && ![".", ".."].contains(reference.filename) && !reference.filename.contains("/") && !reference.filename.contains("\\"), "Attachment filename must be a single filename.")
            for value in [reference.author, reference.source] { try require(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Attachment author and source are required.") }
        }
    }
}
private struct AttachmentArchive: Codable {
    var schemaVersion = 1
    var records: [ProjectAttachment]
}
public extension ProjectDocument {
    func attachments() throws -> [ProjectAttachment] {
        guard root["projectAttachments"] != .null else { return [] }
        let archive = try JSONDecoder().decode(AttachmentArchive.self, from: JSONEncoder().encode(root["projectAttachments"]))
        try require(archive.schemaVersion == 1, "Unsupported attachment archive version.")
        try require(Set(archive.records.map(\.id)).count == archive.records.count, "Duplicate attachment identities.")
        for record in archive.records { try record.validate() }
        return archive.records
    }
    @discardableResult
    mutating func addAttachment(data: Data, filename: String, author: String, source: String, rfiID: String? = nil) throws -> String {
        if let rfiID { try require(root["rfis"].array!.contains { $0["id"].string == rfiID }, "Attachment RFI link must identify an existing RFI.") }
        let id = ProjectAttachment.fingerprint(data)
        let reference = AttachmentReference(filename: filename, author: author, source: source, rfiID: rfiID, at: Date())
        let record = ProjectAttachment(id: id, data: data, references: [reference]); try record.validate()
        var records = try attachments()
        if let index = records.firstIndex(where: { $0.id == id }) {
            let duplicate = records[index].references.contains { $0.filename == filename && $0.author == author && $0.source == source && $0.rfiID == rfiID }
            if duplicate { return id }
            records[index].references.append(reference)
        } else { records.append(record) }
        var object = root.object!
        object["projectAttachments"] = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(AttachmentArchive(records: records)))
        object["qa"] = .array(root["qa"].array!.map { entry in
            var gate = entry.object!; gate["status"] = .string("Open"); gate["reviewer"] = .string(""); gate["date"] = .string("")
            return .object(gate)
        })
        self = try ProjectDocument(data: JSONEncoder().encode(JSONValue.object(object)))
        return id
    }
}
