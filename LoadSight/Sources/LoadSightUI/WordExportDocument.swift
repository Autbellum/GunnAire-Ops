import SwiftUI
import UniformTypeIdentifiers

struct WordExportDocument: FileDocument {
    static let contentType = UTType(filenameExtension: "docx") ?? .data
    static let readableContentTypes = [contentType]
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
