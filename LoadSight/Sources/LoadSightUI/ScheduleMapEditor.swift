import SwiftUI
import LoadSightKit

struct ScheduleMapEditor: View {
    @Binding var document: LoadSightDocument
    let session: ScheduleMapEditSession
    private var mapID: UUID? { session.mapID }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.loadSightDocumentStorage) private var documentStorage
    @State private var draft: ScheduleMapDraft
    private let original: ScheduleMapDraft
    @State private var regionIndex = 0
    @State private var author = ""
    @State private var reason = ""
    @State private var failure: String?
    @State private var discard = false
    init(document: Binding<LoadSightDocument>, session: ScheduleMapEditSession) {
        _document = document; self.session = session
        let draft = session.draft
        original = draft; _draft = State(initialValue: draft)
    }
    private var dirty: Bool { draft != original || !author.isEmpty || !reason.isEmpty }
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    Section("Map record") {
                        TextField("Map name", text: $draft.name).accessibilityIdentifier("ScheduleMapName")
                        TextField("Recorded by", text: $author).accessibilityIdentifier("ScheduleMapAuthor")
                        TextField("Reason for creating or changing this map", text: $reason, axis: .vertical).accessibilityIdentifier("ScheduleMapReason")
                        Text("Saving keeps the map and its correction history in this project. It reopens QA; it does not accept extracted rows or change quantities.").font(.caption)
                        Text(documentStorage.guidance).font(.caption)
                        if !session.context.matches(document) {
                            Text("The project or drawings changed. These edits are retained here but cannot be applied to the replacement. Reopen the current map.").foregroundStyle(.orange)
                        }
                    }
                    Section("Table regions") {
                        Picker("Selected table", selection: $regionIndex) {
                            ForEach(draft.regions.indices, id: \.self) { Text("Table \($0 + 1)").tag($0) }
                        }
                        HStack {
                            Button("Add table") { draft.regions.append(.init(drawings: session.context.drawings)); regionIndex = draft.regions.count - 1 }.disabled(draft.regions.count >= 100)
                            if draft.regions.count > 1 { Button("Remove this table", role: .destructive) { draft.regions.remove(at: regionIndex); regionIndex = min(regionIndex, draft.regions.count - 1) } }
                        }
                    }
                    if draft.regions.indices.contains(regionIndex) {
                        ScheduleRegionFields(draft: regionBinding(draft.regions[regionIndex]), drawings: session.context.drawings) {
                            withAnimation { proxy.scrollTo("ScheduleMapPreview", anchor: .top) }
                        }.id(draft.regions[regionIndex].id)
                    }
                    if let failure { Section("Unable to save map") { Text(failure).foregroundStyle(.red).accessibilityIdentifier("ScheduleMapError") } }
                    if let mapID {
                        Section("Remove map") {
                            Button("Remove saved map", role: .destructive) { remove() }.disabled(author.isEmpty || reason.isEmpty).accessibilityIdentifier("RemoveScheduleMap")
                            Text("Removal keeps the complete prior map in correction history.").font(.caption)
                        }
                        ScheduleMapHistorySection(project: document.project, mapID: mapID)
                    }
                }
            }
            .navigationTitle(mapID == nil ? "New schedule map" : "Edit schedule map")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if dirty { discard = true } else { dismiss() } } }
                ToolbarItem(placement: .confirmationAction) { Button("Save map") { save() }.disabled(author.isEmpty || reason.isEmpty).accessibilityIdentifier("SaveScheduleMap") }
            }
            .interactiveDismissDisabled(dirty)
            .alert("Unable to save map", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(failure ?? "") }
            .alert("Discard map edits?", isPresented: $discard) {
                Button("Discard edits", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
        }
    }
    private func regionBinding(_ snapshot: ScheduleRegionDraft) -> Binding<ScheduleRegionDraft> {
        Binding(get: { draft.regions.first { $0.id == snapshot.id } ?? snapshot }, set: { value in
            guard let index = draft.regions.firstIndex(where: { $0.id == snapshot.id }) else { return }
            draft.regions[index] = value
        })
    }
    private func save() {
        do {
            try session.save(draft, author: author, reason: reason, in: &document)
            dismiss()
        } catch { failure = error.localizedDescription }
    }
    private func remove() {
        do {
            try session.remove(author: author, reason: reason, in: &document)
            dismiss()
        } catch { failure = error.localizedDescription }
    }
}

private enum ScheduleCaptureTarget: Hashable { case inspect, body, column(UUID) }
private struct ScheduleRegionFields: View {
    @Binding var draft: ScheduleRegionDraft
    let drawings: DrawingArchive
    let scrollToPreview: () -> Void
    @State private var tool = ScheduleCaptureTarget.inspect
    @State private var points: [PagePoint] = []
    private var source: DrawingRecord? { drawings.records.first { $0.id == draft.sourceID } }
    private var page: DrawingPage? { source?.pages.first { $0.id == draft.pageID } }
    var body: some View {
        Section("Drawing and table body") {
            Picker("Source drawing", selection: Binding(get: { draft.sourceID }, set: { id in
                if let record = drawings.records.first(where: { $0.id == id }), id != draft.sourceID { draft.changeSource(record); resetCapture() }
            })) {
                ForEach(drawings.records) { Text($0.filename).tag($0.id) }
            }
            if let source {
                Picker("Source page", selection: Binding(get: { draft.pageID }, set: { id in
                    if id != draft.pageID { draft.changeSource(source, pageID: id); resetCapture() }
                })) { ForEach(source.pages) { Text("Page \($0.number)").tag($0.id) } }
                Picker("Text source", selection: $draft.textMode) {
                    if source.kind == "pdf" { Text("PDF text layer").tag(ScheduleTextMode.nativePDFWords) }
                    Text("Imported text / OCR anchors").tag(ScheduleTextMode.recordedAnchors)
                }
            }
            TextField("Header and drawing evidence for this mapping", text: $draft.basis, axis: .vertical).accessibilityIdentifier("ScheduleMappingBasis")
            Text("Exclude titles, header rows and unrelated notes from the body. Map units from the actual header; leave unknown units blank.").font(.caption)
            DisclosureGroup("Precise body bounds") {
                LabeledContent("Left") { TextField("Left", text: $draft.minX).multilineTextAlignment(.trailing).accessibilityIdentifier("ScheduleBodyLeft") }
                LabeledContent("Bottom") { TextField("Bottom", text: $draft.minY).multilineTextAlignment(.trailing).accessibilityIdentifier("ScheduleBodyBottom") }
                LabeledContent("Right") { TextField("Right", text: $draft.maxX).multilineTextAlignment(.trailing).accessibilityIdentifier("ScheduleBodyRight") }
                LabeledContent("Top") { TextField("Top", text: $draft.maxY).multilineTextAlignment(.trailing).accessibilityIdentifier("ScheduleBodyTop") }
            }
        }
        Section("Select on drawing") {
            Picker("Drawing tool", selection: $tool) {
                Text("Inspect / zoom").tag(ScheduleCaptureTarget.inspect)
                Text("Table body").tag(ScheduleCaptureTarget.body)
                ForEach(draft.columns) { column in Text("Column: " + column.field.title).tag(ScheduleCaptureTarget.column(column.id)) }
            }
            Text(tool == .inspect ? "Inspect the page, then choose a selection tool." : "Tap two opposite body corners, or two column edges. \(points.count) of 2 points selected.").font(.caption)
            if let source, let page, let data = drawings.files[source.id] {
                DrawingNativePreview(data: data, kind: source.kind, pageNumber: page.number, capture: tool != .inspect,
                    overlays: overlays, onPoint: capture)
                    .frame(minHeight: 280, idealHeight: 320, maxHeight: 400)
                    .id("ScheduleMapPreview")
                    .accessibilityIdentifier("ScheduleMapPreview")
                Text("Coordinates: \(source.kind == "pdf" ? "PDF page points" : "oriented image pixels"), bottom-left origin. Selected bounds do not establish physical scale.").font(.caption)
            }
            if !points.isEmpty { Button("Clear pending points") { points = [] } }
        }
        ForEach(Array(draft.columns.enumerated()), id: \.element.id) { index, column in
            Section("Column \(index + 1)") {
                Picker("Column meaning", selection: columnBinding(column, \.field)) {
                    ForEach(EquipmentScheduleField.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                LabeledContent("Exact header text") { TextField("Exact header text", text: columnBinding(column, \.header)).multilineTextAlignment(.trailing).accessibilityIdentifier("ScheduleColumnHeader-\(index)") }
                LabeledContent("Header units, if recorded") { TextField("Header units, if recorded", text: columnBinding(column, \.unit)).multilineTextAlignment(.trailing).accessibilityIdentifier("ScheduleColumnUnit-\(index)") }
                LabeledContent("Left column edge") { TextField("Left column edge", text: columnBinding(column, \.minX)).multilineTextAlignment(.trailing).accessibilityIdentifier("ScheduleColumnLeft-\(index)") }
                LabeledContent("Right column edge") { TextField("Right column edge", text: columnBinding(column, \.maxX)).multilineTextAlignment(.trailing).accessibilityIdentifier("ScheduleColumnRight-\(index)") }
                HStack {
                    Button("Pick column edges") { tool = .column(column.id); points = []; scrollToPreview() }
                    if draft.columns.count > 2 { Button("Remove column", role: .destructive) { draft.columns.removeAll { $0.id == column.id }; resetCapture() } }
                }
            }
        }
        Section {
            Button("Add column") {
                if let field = EquipmentScheduleField.allCases.first(where: { field in !draft.columns.contains { $0.field == field } }) { draft.columns.append(.init(field: field)) }
            }.disabled(draft.columns.count >= EquipmentScheduleField.allCases.count)
        }
        .onChange(of: tool) { _, _ in points = [] }
    }
    private func columnBinding<Value>(_ snapshot: ScheduleColumnDraft, _ keyPath: WritableKeyPath<ScheduleColumnDraft, Value>) -> Binding<Value> {
        Binding(get: { (draft.columns.first { $0.id == snapshot.id } ?? snapshot)[keyPath: keyPath] }, set: { value in
            guard let index = draft.columns.firstIndex(where: { $0.id == snapshot.id }) else { return }
            draft.columns[index][keyPath: keyPath] = value
        })
    }
    private var overlays: [DrawingOverlay] {
        var result: [DrawingOverlay] = []
        if let left = Double(draft.minX), let right = Double(draft.maxX), let bottom = Double(draft.minY), let top = Double(draft.maxY), [left,right,bottom,top].allSatisfy(\.isFinite), right > left, top > bottom {
            result.append(.init(points: [.init(x: left, y: bottom), .init(x: right, y: top)], rectangle: true))
            for column in draft.columns {
                if let x1 = Double(column.minX), let x2 = Double(column.maxX), x1.isFinite, x2.isFinite, x2 > x1 {
                    result.append(.init(points: [.init(x: x1, y: bottom), .init(x: x2, y: top)], rectangle: true))
                }
            }
        }
        if !points.isEmpty { result.append(.init(points: points)) }
        return result
    }
    private func capture(_ point: PagePoint) {
        guard tool != .inspect, point.x.isFinite, point.y.isFinite else { return }
        points.append(point)
        guard points.count == 2 else { return }
        switch tool {
        case .body: draft.setBody(points[0], points[1])
        case .column(let id):
            if let index = draft.columns.firstIndex(where: { $0.id == id }) {
                draft.columns[index].minX = String(min(points[0].x, points[1].x)); draft.columns[index].maxX = String(max(points[0].x, points[1].x))
            }
        case .inspect: break
        }
        resetCapture()
    }
    private func resetCapture() { tool = .inspect; points = [] }
}

struct ScheduleMapHistorySection: View {
    let project: ProjectDocument
    let mapID: UUID?
    var body: some View {
        Section("Map history") {
            if let history = try? project.scheduleMapHistory() {
                ForEach(history.reversed()) { revision in
                    let before = try? ProjectDocument.decodeScheduleMaps(revision.before).filter { mapID == nil || $0.id == mapID }
                    let after = try? ProjectDocument.decodeScheduleMaps(revision.after).filter { mapID == nil || $0.id == mapID }
                    if before != after {
                        DisclosureGroup(revision.author + " · " + revision.recordedAt) {
                            Text(revision.reason)
                            Text("Before").font(.headline)
                            if let before, !before.isEmpty { ForEach(before) { summary($0, label: "") } } else { Text("No saved map") }
                            Text("After").font(.headline)
                            if let after, !after.isEmpty { ForEach(after) { summary($0, label: "") } } else { Text("No saved map") }
                        }
                    }
                }
            }
        }
    }
    @ViewBuilder private func summary(_ map: StoredScheduleMap?, label: String) -> some View {
        if let map, let request = try? map.columnMap() {
            Text(map.name)
            ForEach(Array(request.regions.enumerated()), id: \.offset) { index, region in
                Text("Table \(index + 1): " + region.mappingBasis).font(.caption)
                Text("Body: x \(region.bodyBounds.x), y \(region.bodyBounds.y), width \(region.bodyBounds.width), height \(region.bodyBounds.height)").font(.caption)
                ForEach(region.columns, id: \.field) { column in
                    Text("\(column.field.title): \(column.headerText), \(column.minX) to \(column.maxX), units: \(column.unitText ?? "not recorded")").font(.caption)
                }
            }
        } else { Text("No saved map") }
    }
}
