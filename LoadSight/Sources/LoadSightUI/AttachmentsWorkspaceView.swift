import SwiftUI
import UniformTypeIdentifiers
import LoadSightKit

struct AttachmentsWorkspaceView: View {
    @Binding var document: LoadSightDocument
    @State private var importing = false
    @State private var busy = false
    @State private var author = ""
    @State private var source = ""
    @State private var rfiID = ""
    @State private var message: String?
    @State private var failure: String?
    @State private var exporting = false
    @State private var exportFile: AttachmentExportFile?
    @State private var exportName = "attachment"
    var body: some View {
        List {
            Section("Add supporting evidence") {
                TextField("Recorded by", text: $author)
                TextField("Source / purpose", text: $source, axis: .vertical)
                Picker("Link to RFI", selection: $rfiID) {
                    Text("Project-wide attachment").tag("")
                    ForEach(document.project.root["rfis"].array ?? [], id: \.attachmentReferenceID) { rfi in Text(rfi["id"].string ?? "").tag(rfi["id"].string ?? "") }
                }
                Button("Choose attachment") { importing = true }.disabled(busy || author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("Original bytes are retained in this project. Attachments are limited to 64 MB each. Importing evidence reopens QA and does not resolve an RFI.").font(.caption).foregroundStyle(.secondary)
                if busy { ProgressView("Reading attachment…") }
                if let message { Text(message).font(.caption) }
                if let failure { Text(failure).foregroundStyle(.red) }
            }
            if let records = try? document.project.attachments() {
                ForEach(records) { record in
                    Section(record.filename) {
                        Text("\(record.data.count.formatted()) bytes").font(.caption)
                        Text("SHA-256: \(record.id)").font(.caption.monospaced()).textSelection(.enabled)
                        ForEach(Array(record.references.enumerated()), id: \.offset) { _, reference in
                            Text("\(reference.filename) | \(reference.author) | \(reference.source)\n\(reference.rfiID ?? "Project-wide") | \(reference.at.formatted())").font(.callout)
                        }
                        Button("Export original") { exportFile = .init(data: record.data); exportName = record.filename; exporting = true }
                    }
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            switch result {
            case .failure(let error): failure = error.localizedDescription
            case .success(let url):
                let recorder = author, purpose = source, linkedRFI = rfiID
                busy = true; failure = nil; message = nil
                Task {
                    do {
                        let bytes = try await Task.detached(priority: .userInitiated) {
                            let granted = url.startAccessingSecurityScopedResource()
                            defer { if granted { url.stopAccessingSecurityScopedResource() } }
                            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                            try require(values.isRegularFile == true, "Select a regular file, not a folder or package.")
                            try require((values.fileSize ?? Int.max) <= ProjectAttachment.maximumBytes, "Attachments are limited to 64 MB each.")
                            return try Data(contentsOf: url)
                        }.value
                        try document.project.addAttachment(data: bytes, filename: url.lastPathComponent, author: recorder, source: purpose, rfiID: linkedRFI.isEmpty ? nil : linkedRFI)
                        message = "Attachment retained: \(url.lastPathComponent)"
                    } catch { failure = error.localizedDescription }
                    busy = false
                }
            }
        }
        .fileExporter(isPresented: $exporting, document: exportFile, contentType: .data, defaultFilename: exportName) { result in
            if case .failure(let error) = result { failure = error.localizedDescription }
        }
    }
}
private extension JSONValue { var attachmentReferenceID: String { self["id"].string ?? "" } }
private struct AttachmentExportFile: FileDocument {
    static let readableContentTypes: [UTType] = [.data]
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
