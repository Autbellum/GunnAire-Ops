import SwiftUI
import LoadSightKit

struct RFIWorkspaceView: View {
    @Binding var document: LoadSightDocument
    @State private var selection: RFISelection?
    @State private var search = ""
    @State private var openOnly = false
    @State private var word = WordExportDocument(data: Data())
    @State private var exportingWord = false
    @State private var exportError: String?
    private var rows: [JSONValue] { (document.project.root["rfis"].array ?? []).filter { row in
        (!openOnly || row["status"].string != "Resolved") && (search.isEmpty ||
        ["id", "title", "question", "source", "response"].contains { key in (row[key].string ?? "").localizedCaseInsensitiveContains(search) })
    } }
    var body: some View {
        List {
            Toggle("Show open questions only", isOn: $openOnly)
            ForEach(rows, id: \.selfID) { row in
                Button { selection = .init(id: row["id"].string!) } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(row["title"].string ?? row["id"].string ?? "RFI").font(.headline)
                        Text("\(row["status"].string ?? "Open") · \(row["priority"].string ?? "Normal")").font(.caption.bold())
                        Text(row["question"].string ?? "")
                        Text(row["source"].string ?? "").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                }.buttonStyle(.plain)
                .contextMenu {
                    Button("Export saved RFI to Word") { export(row) }
                }
                Button("Export Word copy") { export(row) }
                    .accessibilityLabel("Export Word copy of " + (row["title"].string ?? "RFI"))
            }
            if rows.isEmpty { Text("No matching questions. Create an RFI to record a drawing conflict or missing information.").foregroundStyle(.secondary) }
        }
        .searchable(text: $search, prompt: "Find a question, answer or source")
        .toolbar { Button { selection = .init(id: nil) } label: { Label("New RFI", systemImage: "plus") } }
        .sheet(item: $selection) { selected in RFIEditor(document: $document, recordID: selected.recordID) }
        .fileExporter(isPresented: $exportingWord, document: word, contentType: WordExportDocument.contentType, defaultFilename: "LoadSight-RFI") { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .alert("Unable to export RFI", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") { exportError = nil }
        } message: { Text(exportError ?? "") }
    }
    private func export(_ row: JSONValue) {
        do {
            word = WordExportDocument(data: try RFIWordDocument.docx(document.project, rfiID: row["id"].string ?? ""))
            exportingWord = true
        } catch { exportError = error.localizedDescription }
    }
}
private extension JSONValue { var selfID: String { self["id"].string ?? "" } }
private struct RFISelection: Identifiable {
    let id = UUID()
    let recordID: String?
    init(id: String?) { recordID = id }
}

private struct RFIEditor: View {
    @Binding var document: LoadSightDocument
    let recordID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var fields: [String: String] = [:]
    @State private var itemIDs: Set<String> = []
    @State private var action = "Save question"
    @State private var error: String?
    private var row: JSONValue { document.project.root["rfis"].array?.first { $0["id"].string == recordID } ?? .null }
    private var resolved: Bool { row["status"].string == "Resolved" }
    private var questionChanged: Bool {
        ["title", "question", "source", "impact", "priority"].contains { fields[$0] != row[$0].string } ||
        RFICommunication.fields.contains { (fields[$0.id] ?? "") != (row[$0.id].string ?? "") } ||
        itemIDs != Set(row["itemIDs"].array?.compactMap(\.string) ?? [])
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Question") {
                    if let recordID { Text(recordID).font(.caption.monospaced()); Text(row["status"].string ?? "Open").bold() }
                    input("title", "Title"); input("question", "Question")
                    input("source", "Drawing / specification source"); input("impact", "Scope, cost or schedule impact")
                    Picker("Priority", selection: binding("priority")) {
                        ForEach(["Normal", "High", "Urgent"], id: \.self) { Text($0) }
                    }
                }.disabled(resolved || action != "Save question")
                Section("Routing and response planning") {
                    ForEach(RFICommunication.fields, id: \.id) { field in input(field.id, field.label) }
                    Text("Leave unknown fields blank. Enter dates as YYYY-MM-DD. Recording a recipient or deadline does not send the RFI or schedule a reminder.").font(.caption).foregroundStyle(.secondary)
                }.disabled(resolved || action != "Save question")
                Section("Affected takeoff items") {
                    ForEach(document.project.items, id: \.itemIdentity) { item in
                        let id = item["id"]!.string!
                        Toggle("\(id) · \(item["description"]?.string ?? "")", isOn: Binding(get: { itemIDs.contains(id) }, set: { if $0 { itemIDs.insert(id) } else { itemIDs.remove(id) } }))
                    }
                    let missing = itemIDs.subtracting(document.project.items.compactMap { $0["id"]?.string })
                    ForEach(missing.sorted(), id: \.self) { id in
                        Text("\(id) — source item removed; historical link retained").foregroundStyle(.orange)
                        if !resolved && action == "Save question" { Button("Remove link to \(id)") { itemIDs.remove(id) } }
                    }
                }.disabled(resolved || action != "Save question")
                if recordID != nil {
                    Section("Action") {
                        if resolved {
                            Text("Previous answer: \(row["response"].string ?? "")")
                            Text("\(row["resolvedBy"].string ?? "") · \(row["resolvedDate"].string ?? "")").font(.caption)
                            Text(row["responseSource"].string ?? "Legacy answer has no separate source reference").font(.caption)
                            input("reason", "Reason for reopening")
                        } else {
                            Picker("Action", selection: $action) { Text("Save question").tag("Save question"); Text("Record resolution").tag("Record resolution") }
                            if action == "Record resolution" {
                                input("response", "Documented answer")
                                input("responseSource", "Answer source / document reference")
                                input("respondent", "Answered by")
                                Text("Save question edits first. Recording a resolution keeps the saved question and item links.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Recordkeeping") {
                    input("author", "Recorded by")
                    Text("Saving reopens QA. Review affected quantities and prices separately; an answer does not approve the estimate.").font(.caption).foregroundStyle(.secondary)
                    if let error { Text(error).foregroundStyle(.red) }
                }
                let history = (document.project.root["rfiHistory"].array ?? []).filter { $0["rfiID"].string == recordID }
                if !history.isEmpty {
                    Section("History") {
                        ForEach(Array(history.reversed()), id: \.selfID) { event in
                            DisclosureGroup("\(event["action"].string ?? "") · \(event["author"].string ?? "") · \(event["at"].string ?? "")") {
                                Text(event["reason"].string ?? "")
                                Text(event["after"]["question"].string ?? "")
                                Text(event["after"]["response"].string ?? "")
                                Text(event["after"]["responseSource"].string ?? "").font(.caption)
                                ForEach(["before", "after"], id: \.self) { snapshot in
                                    if event[snapshot] != .null {
                                        DisclosureGroup(snapshot == "before" ? "Previous routing and plan" : "Saved routing and plan") {
                                            ForEach(RFICommunication.fields, id: \.id) { field in
                                                let value = event[snapshot][field.id].string ?? ""
                                                Text(field.label + ": " + (value.isEmpty ? "Not recorded" : value))
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }.formStyle(.grouped)
            .navigationTitle(recordID == nil ? "New RFI" : "Review RFI")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(resolved ? "Reopen RFI" : action) { save() } }
            }
            .onAppear {
                for key in ["title", "question", "source", "impact", "priority"] { fields[key] = row[key].string ?? (key == "priority" ? "Normal" : "") }
                for field in RFICommunication.fields { fields[field.id] = row[field.id].string ?? "" }
                itemIDs = Set(row["itemIDs"].array?.compactMap(\.string) ?? [])
            }
        }
        #if os(macOS)
        .frame(minWidth: 620, minHeight: 700)
        #endif
    }
    private func binding(_ key: String) -> Binding<String> { .init(get: { fields[key] ?? "" }, set: { fields[key] = $0 }) }
    private func input(_ key: String, _ label: String) -> some View { TextField(label, text: binding(key), axis: .vertical).accessibilityLabel(label) }
    private func save() {
        do {
            let author = fields["author"] ?? ""
            if let recordID, resolved {
                try document.project.reopenRFI(id: recordID, reason: fields["reason"] ?? "", author: author)
            } else if let recordID, action == "Record resolution" {
                guard !questionChanged else {
                    error = "The question has unsaved changes. Choose Save question, save it, then reopen this RFI to record the answer."
                    return
                }
                try document.project.resolveRFI(id: recordID, response: fields["response"] ?? "", responseSource: fields["responseSource"] ?? "", respondent: fields["respondent"] ?? "", author: author)
            } else {
                let communication = RFICommunication(to: fields["to"] ?? "", from: fields["from"] ?? "", date: fields["date"] ?? "", requiredResponseDate: fields["requiredResponseDate"] ?? "", suggestedResolution: fields["suggestedResolution"] ?? "")
                try document.project.saveRFI(id: recordID, draft: .init(title: fields["title"] ?? "", question: fields["question"] ?? "", source: fields["source"] ?? "", impact: fields["impact"] ?? "", priority: fields["priority"] ?? "Normal", itemIDs: itemIDs.sorted(), communication: communication), author: author)
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
private extension Dictionary where Key == String, Value == JSONValue { var itemIdentity: String { self["id"]?.string ?? "" } }
