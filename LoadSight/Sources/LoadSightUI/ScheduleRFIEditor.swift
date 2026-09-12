import SwiftUI
import LoadSightKit

struct ScheduleRFIEditor: View {
    @Binding var document: LoadSightDocument
    let row: EquipmentScheduleRow
    let finding: ScheduleConsistencyCheck
    let session: DrawingReviewSession
    @Environment(\.dismiss) private var dismiss
    private enum Input: Hashable { case question, impact, author }
    @FocusState private var focusedInput: Input?
    @State private var draft = SourceRFIDraft()
    @State private var failure: String?
    @State private var discard = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Schedule finding") {
                    Text("\(row.tag) · \(row.filename) · page \(row.pageNumber)")
                    Text(finding.fields.map(\.title).joined(separator: " / "))
                    Text(finding.detail).font(.caption)
                    Text("Saving retains a source summary and a linked JSON evidence snapshot. The RFI remains unanswered.").font(.caption)
                    if !session.matches(document) {
                        Text("The project or drawings changed. Your text is retained here, but cannot be saved into the changed source. Copy any notes you need, then close and review the current drawing.")
                            .foregroundStyle(.orange).accessibilityIdentifier("ScheduleRFISourceChanged")
                    }
                }
                Section("Question and impact") {
                    TextField("Question requiring clarification", text: $draft.question, axis: .vertical).focused($focusedInput, equals: .question).disabled(!draft.canEdit).accessibilityIdentifier("ScheduleRFIQuestion")
                    TextField("Known impact or what remains unknown", text: $draft.impact, axis: .vertical).focused($focusedInput, equals: .impact).disabled(!draft.canEdit).accessibilityIdentifier("ScheduleRFIImpact")
                    TextField("Recorded by", text: $draft.author).focused($focusedInput, equals: .author).disabled(!draft.canEdit).accessibilityIdentifier("ScheduleRFIAuthor")
                    Button("Save RFI draft") { save() }.disabled(!draft.canSave(session: session, in: document)).accessibilityIdentifier("SaveScheduleRFI")
                    if let savedID = draft.savedID { Text("Saved \(savedID). Review it in RFIs; the evidence snapshot is linked in Attachments.").accessibilityIdentifier("ScheduleRFISaved") }
                }
            }.navigationTitle("Schedule RFI draft")
            .toolbar { Button("Done") { if draft.isDirty { discard = true } else { dismiss() } } }
            .interactiveDismissDisabled(draft.isDirty)
            .alert("Discard RFI draft?", isPresented: $discard) {
                Button("Discard edits", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
            .alert("Unable to save RFI", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "") }
        }
    }
    private func save() {
        do {
            try draft.save(session: session, in: &document) { copy, content in
                try copy.project.createRFI(from: row, findingID: finding.id, drawings: copy.drawings,
                                          question: content.question, impact: content.impact, author: content.author)
            }
            focusedInput = nil
        } catch { failure = error.localizedDescription }
    }
}
