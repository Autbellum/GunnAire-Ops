import SwiftUI
import LoadSightKit

struct MixedAirOutputEditor: View {
    @Binding var document: LoadSightDocument
    let process: AirProcessRecord
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var author = ""
    @State private var source = ""
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Reusable mixed-air condition") {
                    Text(process.name).font(.headline)
                    Text("Saves the calculated state and full-stream airflow with a link to this process and its upstream evidence. No values are manually re-entered.").font(.callout).foregroundStyle(.secondary)
                    TextField("Condition name",text:$name)
                    TextField("Recorded by",text:$author)
                    TextField("Source / downstream use basis",text:$source,axis:.vertical)
                    Text("Changing upstream evidence makes this derived record stale. It is a modeled state, not an independently measured condition.").font(.caption).foregroundStyle(.secondary)
                }
                if let failure { Text(failure).foregroundStyle(.red) }
            }.formStyle(.grouped)
            .navigationTitle("Save mixing output")
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement:.confirmationAction) { Button("Save condition") {
                    do {
                        try document.project.saveMixedAirOutput(processID:process.id,name:name,author:author,source:source)
                        onSave()
                    } catch { failure=error.localizedDescription }
                } }
            }
        }.frame(minWidth:360,minHeight:400)
    }
}
