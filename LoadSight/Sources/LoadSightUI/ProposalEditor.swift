import SwiftUI
import LoadSightKit

struct ProposalEditor: View {
    @Binding var document: LoadSightDocument
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @State private var author = ""
    @State private var source = ""
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Record the agreed terms and their source. Leave unknown terms blank; state None only when confirmed. Alternate and bond narratives do not add costs to the estimate.").font(.callout).foregroundStyle(.secondary)
                }
                Section("Proposal details") {
                    ForEach(ProposalDetails.fields) { field in
                        TextField(field.label, text: Binding(get: { values[field.id] ?? "" }, set: { values[field.id] = $0 }), axis: .vertical)
                    }
                }
                Section("Evidence") {
                    TextField("Recorded by", text: $author)
                    TextField("Source / reason for changes", text: $source, axis: .vertical)
                    Text("Saving retains prior terms and reopens QA. Attachment references describe supporting documents; this editor does not attach or send files.").font(.caption).foregroundStyle(.secondary)
                    if let failure { Text(failure).foregroundStyle(.red) }
                }
                let history = Array((document.project.root["proposalHistory"].array ?? []).reversed())
                if !history.isEmpty {
                    Section("Earlier terms") {
                        ForEach(history, id: \.proposalEventID) { event in
                            DisclosureGroup("\(event["author"].string ?? "") · \(event["at"].string ?? "")") {
                                Text(event["source"].string ?? "")
                                ForEach(ProposalDetails.fields) { field in
                                    if event["before"][field.id] != event["after"][field.id] {
                                        Text(field.label).bold()
                                        Text("Before: \(event["before"][field.id].string ?? "Unknown")")
                                        Text("After: \(event["after"][field.id].string ?? "Unknown")")
                                    }
                                }
                            }
                        }
                    }
                }
            }.formStyle(.grouped)
            .navigationTitle("Proposal details")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") {
                    do { try document.project.updateProposalDetails(values, author: author, source: source); dismiss() }
                    catch { failure = error.localizedDescription }
                } }
            }
            .onAppear { for field in ProposalDetails.fields { values[field.id] = document.project.root["proposalDetails"][field.id].string ?? "" } }
        }
        #if os(macOS)
        .frame(minWidth: 660, minHeight: 720)
        #endif
    }
}
private extension JSONValue { var proposalEventID: String { self["id"].string ?? "" } }
