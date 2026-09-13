// Harness injects fixturePDFData and fixtureMappingData for a source-undefined MBH map.
import SwiftUI
import LoadSightUI
import LoadSightKit

@main struct ScheduleUnitConventionApp: App {
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
                                    let url = folder.appendingPathComponent("ScheduleUnitConvention-" + UUID().uuidString + ".loadsight", isDirectory: true)
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
                            let archive = try await DrawingIngestor().ingest(data: fixturePDFData, filename: "UnitConventionSchedule.pdf", ocr: .disabled)
                            try document.addDrawings(archive)
                            let request = try EquipmentScheduleRequest.decode(fixtureMappingData)
                            try document.project.saveScheduleMap(name: "Synthetic MBH schedule", request: request, drawings: archive, expectedFingerprint: document.project.scheduleMapEditFingerprint(), author: "Fixture mapper", reason: "Literal header recorded; convention awaiting source review")
                        } catch { self.error = error.localizedDescription }
                    }
            }
        }
    }
}
