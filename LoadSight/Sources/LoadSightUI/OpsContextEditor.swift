import SwiftUI
import LoadSightKit

struct OpsContextEditor: View {
    @Binding var document: LoadSightDocument
    let choices: [OpsProjectContext]
    @Environment(\.dismiss) private var dismiss
    @State private var selection = ""
    @State private var author = ""
    @State private var reason = ""
    @State private var fingerprint = ""
    @State private var error: String?
    @State private var confirmingDiscard = false
    private var dirty: Bool { !selection.isEmpty || !author.isEmpty || !reason.isEmpty }
    private var selected: OpsProjectContext? { choices.first { $0.id == selection } }
    private var hasEvidence: Bool { !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var body: some View {
        NavigationStack {
            Form {
                Section("Recorded Ops context") {
                    OpsContextSummary(context: try? document.project.opsContext())
                    Text("This is a saved local snapshot. It does not establish current access, approve an estimate or publish billing. Proposal customer and address fields are reviewed separately.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Choose customer and job") {
                    if choices.isEmpty {
                        Text("Open this project from GunnAire Ops to select an available customer or job.")
                    } else {
                        Picker("Ops customer / job", selection: $selection) {
                            Text("Choose a record").tag("")
                            ForEach(choices) { context in
                                Text(choiceLabel(context)).tag(context.id)
                            }
                        }
                        .accessibilityIdentifier("OpsContextSelection")
                        if let selected { OpsContextSummary(context: selected) }
                    }
                    Text("Changing or removing the link preserves its history and reopens project QA. Export the project to retain the link.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Link evidence") {
                    TextField("Recorded by", text: $author).accessibilityIdentifier("OpsContextAuthor")
                    TextField("Reason for linking or correction", text: $reason, axis: .vertical).accessibilityIdentifier("OpsContextReason")
                    if let error { Text(error).foregroundStyle(.red) }
                    Button("Save Ops link") { save(selected) }
                        .disabled(selected == nil || !hasEvidence || fingerprint.isEmpty)
                        .accessibilityIdentifier("SaveOpsContext")
                    if (try? document.project.opsContext()) != nil {
                        Button("Remove recorded link", role: .destructive) { save(nil) }
                            .disabled(!hasEvidence || fingerprint.isEmpty)
                            .accessibilityIdentifier("RemoveOpsContext")
                    }
                }
                if let history = try? document.project.opsContextHistory(), !history.isEmpty {
                    Section("Link history") {
                        ForEach(history.reversed()) { revision in
                            DisclosureGroup(revision.author + " · " + revision.recordedAt) {
                                Text(revision.reason)
                                Text("Before").font(.headline)
                                OpsContextSummary(context: try? revision.context(before: true))
                                Text("After").font(.headline)
                                OpsContextSummary(context: try? revision.context(before: false))
                            }
                        }
                    }
                }
            }
            .navigationTitle("Ops project link")
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("Done") { if dirty { confirmingDiscard = true } else { dismiss() } }
            } }
            .onAppear {
                guard fingerprint.isEmpty else { return }
                do { fingerprint = try document.project.opsContextEditFingerprint() }
                catch { self.error = error.localizedDescription }
            }
            .interactiveDismissDisabled(dirty)
            .alert("Discard link edits?", isPresented: $confirmingDiscard) {
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
        }
    }
    private func choiceLabel(_ context: OpsProjectContext) -> String {
        let customer = context.customer.name + " · " + String(context.customer.id.uuidString.prefix(8))
        guard let job = context.job else { return customer + " · Customer only" }
        let title = job.title.isEmpty ? "Job" : job.title
        return customer + " · " + title + " · " + String(job.id.uuidString.prefix(8))
    }
    private func save(_ context: OpsProjectContext?) {
        do {
            try document.project.updateOpsContext(context, expectedFingerprint: fingerprint, author: author, reason: reason)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
struct OpsContextSummary: View {
    let context: OpsProjectContext?
    var body: some View {
        if let context {
            LabeledContent("Customer", value: context.customer.name)
            Text("Customer ID: " + context.customer.id.uuidString).font(.caption).textSelection(.enabled)
            LabeledContent("Customer address", value: context.customer.address.isEmpty ? "Not recorded" : context.customer.address)
            if let job = context.job {
                LabeledContent("Job", value: job.title.isEmpty ? "Untitled job" : job.title)
                Text("Job ID: " + job.id.uuidString).font(.caption).textSelection(.enabled)
                LabeledContent("Job site", value: job.siteAddress.isEmpty ? "Not recorded" : job.siteAddress)
                if let id = job.serviceLocationID { Text("Service location ID: " + id.uuidString).font(.caption) }
            } else { Text("Customer only — no job linked") }
        } else { Text("No Ops customer or job linked") }
    }
}
