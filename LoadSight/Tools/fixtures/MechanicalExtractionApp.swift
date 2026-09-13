// Acceptance template: the harness injects fixturePDFData from DrawingIntake.pdf before this source.
import SwiftUI
import LoadSightUI
import LoadSightKit

@main struct MechanicalExtractionApp: App {
    @State private var document = LoadSightDocument()
    @State private var loaded = false
    @State private var error: String?
    var body: some Scene {
        WindowGroup {
            LoadSightWorkspaceView(document: $document)
                .overlay(alignment: .bottom) { if let error { Text(error) } }
                .task {
                    guard !loaded else { return }; loaded = true
                    do {
                        let archive = try await DrawingIngestor().ingest(data: fixturePDFData, filename: "DrawingIntake.pdf", ocr: .disabled)
                        try document.addDrawings(archive)
                        try document.project.replace("name", with: .string("Synthetic extraction project"))
                    } catch { self.error = error.localizedDescription }
                }
        }
    }
}
