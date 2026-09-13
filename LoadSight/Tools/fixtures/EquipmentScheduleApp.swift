// Harness injects fixturePDFData and fixtureMappingData from the controlled schedule fixtures.
import SwiftUI
import LoadSightUI
import LoadSightKit

@main struct EquipmentScheduleApp: App {
    @State private var document = LoadSightDocument()
    @State private var request: EquipmentScheduleRequest?
    @State private var error: String?
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                if let request { EquipmentScheduleWorkspace(document: $document, initialRequest: request).navigationTitle("Synthetic schedule review") }
                else { Text(error ?? "Loading controlled fixture").task {
                    do {
                        let archive = try await DrawingIngestor().ingest(data: fixturePDFData, filename: "EquipmentSchedule.pdf", ocr: .disabled)
                        try document.addDrawings(archive)
                        request = try EquipmentScheduleRequest.decode(fixtureMappingData)
                    } catch { self.error = error.localizedDescription }
                } }
            }
        }
    }
}
