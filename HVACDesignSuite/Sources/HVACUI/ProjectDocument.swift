import SwiftUI
import UniformTypeIdentifiers
import HVACCore

public extension UTType {
    /// The suite's own document type. Conforms to JSON, so a saved job stays readable and
    /// diffable rather than becoming an opaque blob — a design file that cannot be
    /// inspected outside the app that wrote it is a liability on a ten-year-old project.
    static let hvacProject = UTType(exportedAs: "com.gunnaire.hvacdesignsuite.project",
                                    conformingTo: .json)
}

/// A saved job.
///
/// `Project` is already `Codable` and is the single source of truth for the whole cascade,
/// so the document is a thin wrapper over it: everything needed to reproduce a design —
/// weather, zones, surfaces, equipment, ducts — round-trips, and nothing derived is
/// stored, because storing a computed load would let a file drift out of agreement with
/// the inputs that produced it.
public struct HVACProjectDocument: FileDocument {
    public var project: Project

    public static var readableContentTypes: [UTType] { [.hvacProject, .json] }
    public static var writableContentTypes: [UTType] { [.hvacProject] }

    public init(project: Project = .sample) {
        self.project = project
    }

    public init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.project = try decoder.decode(Project.self, from: data)
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return FileWrapper(regularFileWithContents: try encoder.encode(project))
    }
}
