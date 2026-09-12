import SwiftUI
import UniformTypeIdentifiers

struct PDFExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.pdf]
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
