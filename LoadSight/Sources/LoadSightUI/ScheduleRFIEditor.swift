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
    @State private var question = ""
    @State private var impact = ""
    @State private var author = ""
    @State private var failure: String?
    @State private var savedID: String?
    @State private var discard = false
    private var dirty: Bool { savedID == nil && [question, impact, author].contains { !$0.isEmpty } }
    var body: some View {
        NavigationStack {
            Form {
                Section("Schedule finding") {
                    Text("\(row.tag) · \(row.filename) · page \(row.pageNumber)")
                    Text(finding.fields.map(\.title).joined(separator: " / "))
                    Text(finding.detail).font(.caption)
                    Text("Saving retains a source summary and a linked JSON evidence snapshot. The RFI remains unanswered.").font(.caption)
                }
                Section("Question and impact") {
                    TextField("Question requiring clarification", text: $question, axis: .vertical).focused($focusedInput, equals: .question).disabled(savedID != nil).accessibilityIdentifier("ScheduleRFIQuestion")
                    TextField("Known impact or what remains unknown", text: $impact, axis: .vertical).focused($focusedInput, equals: .impact).disabled(savedID != nil).accessibilityIdentifier("ScheduleRFIImpact")
                    TextField("Recorded by", text: $author).focused($focusedInput, equals: .author).disabled(savedID != nil).accessibilityIdentifier("ScheduleRFIAuthor")
                    Button("Save RFI draft") { save() }.disabled(savedID != nil).accessibilityIdentifier("SaveScheduleRFI")
                    if let savedID { Text("Saved \(savedID). Review it in RFIs; the evidence snapshot is linked in Attachments.").accessibilityIdentifier("ScheduleRFISaved") }
                }
            }.navigationTitle("Schedule RFI draft")
            .toolbar { Button("Done") { if dirty { discard = true } else { dismiss() } } }
            .interactiveDismissDisabled(dirty)
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
            var identity: String?
            try session.apply(to: &document) { copy in
                identity = try copy.project.createRFI(from: row, findingID: finding.id, drawings: copy.drawings,
                                                      question: question, impact: impact, author: author)
            }
            savedID = identity
            focusedInput = nil
        } catch { failure = error.localizedDescription }
    }
}
