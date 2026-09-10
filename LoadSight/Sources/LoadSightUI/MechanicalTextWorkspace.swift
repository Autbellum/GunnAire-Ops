import SwiftUI
import LoadSightKit

struct MechanicalTextWorkspace: View {
    @Binding var document: LoadSightDocument
    @StateObject private var preparation = MechanicalTextPreparation()
    @State private var selected: DrawingReviewSelection<MechanicalTextCandidate>?
    @State private var search = ""
    var body: some View {
        List {
            Section("Text extraction candidates") {
                Text(preparation.stage).accessibilityIdentifier("MechanicalExtractionStatus")
                Text("Occurrences are not physical counts. Values are not assigned to equipment. Review the whole source page, legend, schedule and repeated views before using them.").font(.caption)
                if let failure = preparation.failure { Text(failure).foregroundStyle(.red) }
                if document.drawings.records.isEmpty { Text("Import drawings in the Drawings workspace first.") }
            }
            if preparation.matches(drawings: document.drawings, documentSessionID: document.editSessionID), let result = preparation.result {
                Section("\(result.candidates.count) text occurrences across \(result.pageCount) pages") {
                    ForEach(result.candidates.filter { search.isEmpty || $0.matchedText.localizedCaseInsensitiveContains(search) || $0.anchor.text.localizedCaseInsensitiveContains(search) }) { candidate in
                        Button { selected = .init(document: document, value: candidate) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(candidate.matchedText).font(.headline)
                                Text("\(candidate.kind.title) · \(candidate.filename) · page \(candidate.pageNumber)").font(.caption)
                                Text(candidate.anchor.text).lineLimit(3)
                                Text(candidate.needsRecognitionCheck ? "Low recognition confidence — human verification needed" : "Unreviewed source text").font(.caption).foregroundStyle(candidate.needsRecognitionCheck ? Color.orange : Color.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain).accessibilityIdentifier("TextCandidate-" + candidate.id)
                    }
                    if result.candidates.isEmpty { Text("No supported text patterns found. This does not establish that equipment or design information is absent.") }
                }
            }
        }
        .searchable(text: $search, prompt: "Find candidate text")
        .toolbar {
            if preparation.isScanning { Button("Cancel scan") { preparation.cancel() } }
            else { Button("Scan drawing text") { preparation.start(drawings: document.drawings, documentSessionID: document.editSessionID) }.disabled(document.drawings.records.isEmpty).accessibilityIdentifier("ScanMechanicalText") }
        }
        .sheet(item: $selected) { selection in MechanicalTextReview(document: $document, candidate: selection.value, session: selection.session) }
        .onChange(of: document.editSessionID) { _, _ in sourcesChanged() }
        .onChange(of: document.drawings) { _, _ in sourcesChanged() }
        .onDisappear { preparation.cancel() }
    }
    private func sourcesChanged() {
        preparation.updateScope(drawings: document.drawings, documentSessionID: document.editSessionID)
        // Keep an open RFI draft until the user discards it; its captured session
        // prevents saving into changed drawings or a replacement document.
    }
}

private struct MechanicalTextReview: View {
    @Binding var document: LoadSightDocument
    let candidate: MechanicalTextCandidate
    let session: DrawingReviewSession
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var impact = ""
    @State private var author = ""
    @State private var failure: String?
    @State private var savedID: String?
    @State private var discard = false
    @State private var preview = false
    private var dirty: Bool { savedID == nil && [question, impact, author].contains { !$0.isEmpty } }
    var body: some View {
        NavigationStack {
            Form {
                Section("Unreviewed text occurrence") {
                    Text(candidate.matchedText).font(.headline)
                    Button("View source page") { preview = true }.accessibilityIdentifier("ViewCandidateSource")
                    Text("\(candidate.filename) · page \(candidate.pageNumber)")
                    Text(candidate.anchor.text).textSelection(.enabled)
                    if !session.matches(document) {
                        Text("The project or drawings changed. Your draft is retained, but cannot be saved here. Reopen the current source text.").foregroundStyle(.orange)
                    }
                    Text("The rectangle identifies the full recognized text anchor, not a symbol count or a verified equipment relationship.").font(.caption)
                    DisclosureGroup("Source details") {
                        Text(candidate.sourceDescription).font(.caption).textSelection(.enabled)
                    }
                }
                Section("Create a local RFI draft") {
                    TextField("Question requiring clarification", text: $question, axis: .vertical).accessibilityIdentifier("CandidateRFIQuestion")
                    TextField("Known impact or what remains unknown", text: $impact, axis: .vertical).accessibilityIdentifier("CandidateRFIImpact")
                    TextField("Recorded by", text: $author).accessibilityIdentifier("CandidateRFIAuthor")
                    Button("Save RFI draft") { save() }.disabled(savedID != nil).accessibilityIdentifier("SaveCandidateRFI")
                    if let savedID { Text("Saved \(savedID). The RFI remains unanswered; no quantity, equipment association or approval was created.").accessibilityIdentifier("CandidateRFISaved") }
                    if let failure { Text(failure).foregroundStyle(.red) }
                }
            }.navigationTitle("Review source text")
            .toolbar { Button("Done") { if dirty { discard = true } else { dismiss() } } }
            .interactiveDismissDisabled(dirty)
            .alert("Discard RFI draft?", isPresented: $discard) {
                Button("Discard edits", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
            .sheet(isPresented: $preview) {
                NavigationStack {
                    if let source = session.drawings.records.first(where: { $0.id == candidate.sourceID }),
                       let bytes = session.drawings.files[candidate.sourceID] {
                        DrawingNativePreview(data: bytes, kind: source.kind, pageNumber: candidate.pageNumber, capture: false,
                            overlays: [.init(points: [.init(x: candidate.anchor.bounds.x, y: candidate.anchor.bounds.y), .init(x: candidate.anchor.bounds.x + candidate.anchor.bounds.width, y: candidate.anchor.bounds.y + candidate.anchor.bounds.height)], rectangle: true)], onPoint: { _ in })
                            .navigationTitle("Source page \(candidate.pageNumber)")
                            .toolbar { Button("Close source") { preview = false } }
                    } else { Text("Source unavailable. Import and scan the current drawing again.") }
                }
            }
        }
    }
    private func save() {
        do {
            savedID = try session.createRFI(from: candidate, question: question, impact: impact, author: author, in: &document)
        } catch { failure = error.localizedDescription }
    }
}
