import SwiftUI
import UniformTypeIdentifiers

struct WorkbookExportDocument: FileDocument {
    static let contentType = UTType(filenameExtension: "xlsx") ?? .data
    static let readableContentTypes = [contentType]
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
