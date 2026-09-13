// Harness injects only fixturePDFData. No column map is supplied to the editor.
import SwiftUI
import LoadSightUI
import LoadSightKit

@main struct ScheduleMapAuthoringApp: App {
    @State private var document = LoadSightDocument()
    @State private var loaded = false
    @State private var error: String?
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                EquipmentScheduleWorkspace(document: $document).navigationTitle("Synthetic map authoring")
                    .toolbar {
                        ToolbarItem(placement: .bottomBar) {
                            Button("Reopen package") {
                                do {
                                    let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                                    let url = folder.appendingPathComponent("ScheduleMapAuthoring-" + UUID().uuidString + ".loadsight", isDirectory: true)
                                    try document.wrapper(asPackage: true).write(to: url, options: .atomic, originalContentsURL: nil)
                                    document = try LoadSightDocument(wrapper: FileWrapper(url: url, options: .immediate))
                                }
                                catch { self.error = error.localizedDescription }
                            }.accessibilityIdentifier("ReopenMapPackage")
                        }
                    }
                    .overlay(alignment: .bottom) { if let error { Text(error) } }
                    .task {
                        guard !loaded else { return }; loaded = true
                        do {
                            let archive = try await DrawingIngestor().ingest(data: fixturePDFData, filename: "EquipmentSchedule.pdf", ocr: .disabled)
                            try document.addDrawings(archive)
                        } catch { self.error = error.localizedDescription }
                    }
            }
        }
    }
}
