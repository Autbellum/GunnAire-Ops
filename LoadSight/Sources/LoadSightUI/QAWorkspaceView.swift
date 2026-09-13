import SwiftUI
import LoadSightKit

struct QAWorkspaceView: View {
    @Binding var document: LoadSightDocument
    @State private var selected: QAGateSelection?
    var body: some View {
        List {
            Section {
                Text("Record the evidence you reviewed for each check. A completed checklist does not replace quantity, pricing, RFI, or proposal review.").foregroundStyle(.secondary)
            }
            ForEach(document.project.root["qa"].array ?? [], id: \.qaIdentity) { gate in
                Button { selected = .init(id: gate["id"].string!) } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(gate["check"].string ?? QAWorkflow.title(for: gate["id"].string ?? "")).font(.headline)
                        Text(status(gate)).font(.caption.bold()).foregroundStyle((try? document.project.isQACurrent(gate)) == true ? Color.green : Color.orange)
                        Text(gate["note"].string ?? "No review evidence recorded").font(.callout)
                        if let reviewer = gate["reviewer"].string, !reviewer.isEmpty { Text("\(reviewer) · \(gate["date"].string ?? "")").font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                }.buttonStyle(.plain)
            }
        }
        .sheet(item: $selected) { QAEditor(document: $document, id: $0.id) }
    }
    private func status(_ gate: JSONValue) -> String {
        guard gate["status"].string == "Complete" else { return "Open" }
        if (gate["reviewer"].string ?? "").isEmpty || (gate["date"].string ?? "").isEmpty { return "Review identity or date missing" }
        if gate["reviewFingerprint"] == .null { return "Legacy review — project version not recorded" }
        return (try? document.project.isQACurrent(gate)) == true ? "Reviewed against current project" : "Stale — review current project"
    }
}
private struct QAGateSelection: Identifiable { let id: String }
private extension JSONValue { var qaIdentity: String { self["id"].string ?? "" } }
private struct QAEditor: View {
    @Binding var document: LoadSightDocument
    let id: String
    @Environment(\.dismiss) private var dismiss
    @State private var reviewer = ""
    @State private var evidence = ""
    @State private var complete = true
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(QAWorkflow.title(for: id)).font(.headline)
                    Picker("Action", selection: $complete) { Text("Record completed review").tag(true); Text("Reopen check").tag(false) }
                    TextField("Reviewer", text: $reviewer)
                    TextField("Evidence reviewed / reason for reopening", text: $evidence, axis: .vertical)
                    Text("Reference the drawings, quote, calculation, site record, or written decision that supports this review. Record limitations explicitly.").font(.caption).foregroundStyle(.secondary)
                    if id == "QA-12" { Text("The final reviewer must differ from the responsible estimator. All other checks must be current. Names are locally recorded and are not authenticated identities.").font(.caption) }
                    if let failure { Text(failure).foregroundStyle(.red) }
                }
                let history = (document.project.root["qaHistory"].array ?? []).filter { $0["gateID"].string == id }
                if !history.isEmpty {
                    Section("Review history") {
                        ForEach(Array(history.reversed()), id: \.qaIdentity) { event in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(event["action"].string ?? "") · \(event["reviewer"].string ?? "")")
                                Text(event["at"].string ?? "").font(.caption)
                                Text(event["evidence"].string ?? "")
                            }
                        }
                    }
                }
            }.formStyle(.grouped)
            .navigationTitle(id)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save review") {
                    do { try document.project.recordQACheck(id: id, reviewer: reviewer, evidence: evidence, complete: complete); dismiss() }
                    catch { failure = error.localizedDescription }
                } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 580, minHeight: 570)
        #endif
    }
}
