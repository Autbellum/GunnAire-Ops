import SwiftUI
import UniformTypeIdentifiers
import LoadSightKit

public struct LoadSightDocument: FileDocument {
    public static let projectType = UTType(exportedAs: "com.gunnaire.loadsight.project", conformingTo: .package)
    public static let readableContentTypes: [UTType] = [projectType, .json]
    public var project: ProjectDocument
    public private(set) var drawings = DrawingArchive()
    public init(project: ProjectDocument) throws {
        self.project = project
        drawings = try DrawingArchive(projectJSON: project.root["nativeDrawings"])
        try validateMarkup()
    }
    public init() {
        // A fixed, valid blank schema contains no pilot facts or assumed prices.
        let gates = (1...12).map { JSONValue.object(["id": .string(String(format: "QA-%02d", $0)), "status": .string("Open"), "reviewer": .string(""), "date": .string("")]) }
        var root: [String: JSONValue] = ["schemaVersion": .number(1), "name": .string("Untitled mechanical project"), "inputs": .object([:]), "reviewer": .string("")]
        for key in ["items", "devices", "rfis", "qa", "requirements", "sheets", "zones", "measurements", "markers"] { root[key] = .array([]) }
        root["qa"] = .array(gates)
        project = try! ProjectDocument(data: JSONEncoder().encode(JSONValue.object(root)))
    }
    public init(configuration: ReadConfiguration) throws {
        try self.init(wrapper: configuration.file)
    }
    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try wrapper(contentType:configuration.contentType)
    }
    /// iOS may resolve a new .loadsight URL as a dynamic data type before the package exists.
    public func wrapper(contentType: UTType) throws -> FileWrapper {
        if contentType == Self.projectType || (contentType.isDynamic && contentType.preferredFilenameExtension?.lowercased() == "loadsight") {
            return try wrapper(asPackage:true)
        }
        if contentType.conforms(to:.json) { return try wrapper(asPackage:false) }
        throw LoadSightError.invalid("Unsupported project output type: \(contentType.identifier).")
    }
    public init(wrapper: FileWrapper) throws {
        if wrapper.isRegularFile, let data = wrapper.regularFileContents {
            project = try ProjectDocument(data: data)
            drawings = try DrawingArchive(projectJSON: project.root["nativeDrawings"])
            try validateMarkup()
            return
        }
        guard wrapper.isDirectory, let children = wrapper.fileWrappers,
              let data = children["project.json"]?.regularFileContents,
              let indexData = children["drawings.json"]?.regularFileContents,
              let sources = children["drawings"]?.fileWrappers else { throw LoadSightError.invalid("The LoadSight package is missing its project or drawing index.") }
        project = try ProjectDocument(data: data)
        let records = try JSONDecoder().decode([DrawingRecord].self, from: indexData)
        try require(Set(records.map(\.id)).count == records.count, "Duplicate source IDs in package index.")
        for record in records {
            guard let source = sources[record.id], source.isRegularFile, let original = source.regularFileContents else {
                throw LoadSightError.invalid("Original drawing missing: \(record.filename)")
            }
            try drawings.insert(record: record, data: original)
        }
        try require(Set(sources.keys) == Set(records.map(\.id)), "Package contains unindexed drawing files.")
        try validateMarkup()
    }
    public func wrapper(asPackage: Bool) throws -> FileWrapper {
        try drawings.validate()
        try validateMarkup()
        var copy = project
        if !asPackage {
            // JSON exports stay self-contained; never silently discard drawings on Save As.
            try copy.replace("nativeDrawings", with: drawings.projectJSON())
            return FileWrapper(regularFileWithContents: try copy.data())
        }
        try copy.replace("nativeDrawings", with: .null)
        var files: [String: FileWrapper] = [:]
        for (id, data) in drawings.files { files[id] = FileWrapper(regularFileWithContents: data) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(directoryWithFileWrappers: [
            "project.json": FileWrapper(regularFileWithContents: try copy.data()),
            "drawings.json": FileWrapper(regularFileWithContents: try encoder.encode(drawings.records)),
            "drawings": FileWrapper(directoryWithFileWrappers: files)
        ])
    }
    public mutating func addDrawings(_ incoming: DrawingArchive) throws {
        try incoming.validate()
        var candidate = self
        let added = incoming.records.filter { record in !drawings.records.contains { $0.id == record.id } }
        if added.isEmpty { return }
        for record in added { try candidate.drawings.insert(record: record, data: incoming.files[record.id]!) }
        var sheets = project.root["sheets"].array ?? []
        for record in added {
            for page in record.pages {
                // Link recovered sheet registers only when the original file hash and page agree.
                // Never merge by a repeated sheet tag or filename alone.
                if project.root["sourceSha256"].string == record.id,
                   let index = sheets.firstIndex(where: { $0["page"].number == Double(page.number) && $0["nativePageID"] == .null }),
                   var existing = sheets[index].object {
                    existing["sourceID"] = .string(record.id); existing["nativePageID"] = .string(page.id)
                    sheets[index] = .object(existing)
                    continue
                }
                sheets.append(.object(["sheet": .string("Imported page \(page.number)"), "title": .string(record.filename),
                    "page": .number(Double(page.number)), "sourceID": .string(record.id), "nativePageID": .string(page.id),
                    "review": .string("Unreviewed extraction"), "revision": .string("Not established"),
                    "width": .number(page.bounds.width), "height": .number(page.bounds.height)]))
            }
        }
        try candidate.project.replace("sheets", with: .array(sheets))
        let gates = (project.root["qa"].array ?? []).map { value -> JSONValue in
            var gate = value.object!; gate["status"] = .string("Open"); gate["reviewer"] = .string(""); gate["date"] = .string("")
            return .object(gate)
        }
        try candidate.project.replace("qa", with: .array(gates))
        self = candidate
    }
    public func validateMarkup() throws {
        try project.validateDrawingEvidence(in: drawings)
    }

    public mutating func applyMarkup(_ ledger: MarkupLedger) throws {
        var copy = self; try copy.project.applyMarkup(ledger); try copy.validateMarkup(); self = copy
    }
}
