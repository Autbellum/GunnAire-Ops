import SwiftUI
import LoadSightKit

struct ScheduleDiscoveryWorkspace: View {
    @Binding var document: LoadSightDocument
    @Environment(\.dismiss) private var dismiss
    @StateObject private var preparation = ScheduleDiscoveryPreparation()
    @State private var selected: DrawingReviewSelection<EquipmentScheduleCandidate>?
    var body: some View {
        NavigationStack {
            List {
                Section("Find equipment schedules") {
                    Text(preparation.stage).accessibilityIdentifier("ScheduleDiscoveryStatus")
                    Text("Searches imported pages for supported header and tag layouts. Review each proposal on its source before saving a column map. No quantities are created.").font(.caption)
                    if let failure = preparation.failure { Text(failure).foregroundStyle(.red) }
                    if preparation.isScanning { ProgressView(); Button("Cancel discovery") { preparation.cancel() } }
                }
                if preparation.matches(drawings: document.drawings, documentSessionID: document.editSessionID), let result = preparation.result {
                    Section("\(result.candidates.count) possible tables across \(result.pageCount) pages") {
                        ForEach(result.candidates) { candidate in
                            Button { selected = .init(document: document, value: candidate) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("\(candidate.filename) · page \(candidate.pageNumber)").font(.headline)
                                    Text(candidate.headers.map(\.headerText).joined(separator: " · "))
                                    Text("\(candidate.tagEvidence.count) aligned tag rows — unreviewed").font(.caption)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain).accessibilityIdentifier("DiscoveredSchedule-" + candidate.id)
                        }
                    }
                    Section("Discovery notes") {
                        ForEach(Array((result.warnings + result.limitations).enumerated()), id: \.offset) { _, text in Text(text).font(.caption) }
                    }
                }
            }.navigationTitle("Schedule discovery")
                .toolbar {
                    Button("Find again") { find() }.disabled(preparation.isScanning || document.drawings.records.isEmpty)
                    Button("Done") { dismiss() }.accessibilityIdentifier("CloseScheduleDiscovery")
                }
                .sheet(item: $selected) { selection in ScheduleDiscoveryReview(document: $document, selection: selection) }
                .onChange(of: document.drawings) { _, _ in preparation.cancel() }
                .onChange(of: document.editSessionID) { _, _ in preparation.cancel() }
                .onDisappear { preparation.cancel() }
                .task { find() }
        }
    }
    private func find() { preparation.start(drawings: document.drawings, documentSessionID: document.editSessionID) }
}

private struct ScheduleDiscoveryReview: View {
    @Binding var document: LoadSightDocument
    let selection: DrawingReviewSelection<EquipmentScheduleCandidate>
    @Environment(\.dismiss) private var dismiss
    @State private var editor: ScheduleMapEditSession?
    @State private var preparing = false
    @State private var preparationTask: Task<Void, Never>?
    @State private var failure: String?
    private var candidate: EquipmentScheduleCandidate { selection.value }
    var body: some View {
        NavigationStack {
            List {
                Section("Original source and proposed bounds") {
                    Text("\(candidate.filename) · page \(candidate.pageNumber)")
                    if let source = selection.session.drawings.records.first(where: { $0.id == candidate.sourceID }),
                       let data = selection.session.drawings.files[candidate.sourceID] {
                        DrawingNativePreview(data: data, kind: source.kind, pageNumber: candidate.pageNumber, capture: false,
                            overlays: ([candidate.proposedRegion.bodyBounds] + candidate.headers.map(\.bounds)).map { bounds in
                                .init(points: [.init(x: bounds.x, y: bounds.y), .init(x: bounds.x + bounds.width, y: bounds.y + bounds.height)], rectangle: true)
                            }, onPoint: { _ in })
                            .frame(minHeight: 320).accessibilityIdentifier("DiscoveredScheduleSource")
                    }
                    Text("The editor opens with proposed bounds. Check and correct the full body, every column and literal units; supply your name and reason to save.").font(.caption)
                    if let failure { Text(failure).foregroundStyle(.red) }
                    if !selection.session.matches(document) { Text("The project or drawings changed. Reopen discovery for the current source.").foregroundStyle(.orange) }
                    if preparing { ProgressView("Validating current source") }
                }
                Section("Proposed header meanings") {
                    ForEach(Array(candidate.headers.enumerated()), id: \.offset) { _, header in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(header.headerText).font(.headline)
                            Text(header.field?.title ?? "Unrecognized — remains unmapped")
                            Text(header.unitText.map { "Literal unit: " + $0 } ?? "No literal unit recorded").font(.caption)
                        }
                    }
                }
                Section("Review notes") { ForEach(Array(candidate.warnings.enumerated()), id: \.offset) { _, text in Text(text).font(.caption) } }
            }.navigationTitle("Possible equipment table")
                .toolbar {
                    Button("Review map draft") { prepareMap() }.disabled(preparing || !selection.session.matches(document)).accessibilityIdentifier("ReviewDiscoveredMap")
                    Button("Done") { dismiss() }.accessibilityIdentifier("CloseScheduleCandidate")
                }
                .sheet(item: $editor) { session in ScheduleMapEditor(document: $document, session: session) }
                .onDisappear { preparationTask?.cancel() }
        }
    }
    private func prepareMap() {
        preparing = true; failure = nil
        preparationTask = Task { @MainActor in
            defer { preparing = false; preparationTask = nil }
            do {
                try selection.session.validate(document)
                let request = try await LocalLoadSightService().prepareDiscoveredSchedule(candidate, drawings: selection.session.drawings)
                try Task.checkCancellation(); try selection.session.validate(document)
                editor = try .init(document: document, request: request)
            } catch { if !(error is CancellationError) { failure = error.localizedDescription } }
        }
    }
}
