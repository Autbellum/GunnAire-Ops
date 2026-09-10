import SwiftUI
import UniformTypeIdentifiers
import LoadSightKit

/// Host apps may supply a previously prepared column map. Mapping import is local and read-only.
public struct EquipmentScheduleWorkspace: View {
    @Binding private var document: LoadSightDocument
    private let initialRequest: EquipmentScheduleRequest?
    @StateObject private var preparation = EquipmentSchedulePreparation()
    @State private var importing = false
    @State private var importSession: DrawingReviewSession?
    @State private var failure: String?
    @State private var selected: DrawingReviewSelection<EquipmentScheduleRow>?
    @State private var request: EquipmentScheduleRequest?
    @State private var editor: ScheduleMapEditSession?
    public init(document: Binding<LoadSightDocument>, initialRequest: EquipmentScheduleRequest? = nil) {
        _document = document; self.initialRequest = initialRequest
    }
    public var body: some View {
        List {
            Section("Mapped equipment schedules") {
                Text(preparation.stage).accessibilityIdentifier("ScheduleStatus")
                Text("Create a map by selecting a table body and matching its columns to the drawing headers. Saved maps remain with this project. Row candidates do not establish equipment counts or approved design values.").font(.caption)
                if let message = failure ?? preparation.failure { Text(message).foregroundStyle(.red) }
                if preparation.isScanning { ProgressView(); Button("Cancel schedule scan") { preparation.cancel() } }
            }
            if let maps = try? document.project.scheduleMaps(), !maps.isEmpty {
                Section("Saved column maps") {
                    ForEach(maps) { map in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(map.name).font(.headline)
                            HStack {
                                Button("Read map") { read(map) }.accessibilityIdentifier("ReadScheduleMap-" + map.id.uuidString)
                                Button("Edit map") { openEditor(map: map) }.accessibilityIdentifier("EditScheduleMap-" + map.id.uuidString)
                            }.buttonStyle(.bordered)
                        }
                    }
                }
            }
            if preparation.matches(drawings: document.drawings, documentSessionID: document.editSessionID), let result = preparation.result {
                Section("\(result.rows.count) unreviewed row candidates") {
                    ForEach(result.rows) { row in
                        Button { selected = .init(document: document, value: row) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(row.tag).font(.headline)
                                Text("\(row.filename) · page \(row.pageNumber)").font(.caption)
                                Text("\(row.matchingTagOccurrences.count) possible tag links · review required").font(.caption)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("ScheduleRow-" + row.id)
                    }
                }
                Section("Additional review") {
                    if !result.unassigned.isEmpty {
                        Label("\(result.unassigned.count) text fragments still need source review", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    DisclosureGroup("Unassigned text (\(result.unassigned.count))") {
                        ForEach(Array(result.unassigned.enumerated()), id: \.offset) { _, item in
                            VStack(alignment: .leading) { Text(item.evidence.text); Text(item.reason).font(.caption) }
                        }
                        if result.unassigned.isEmpty { Text("No recognized text left unassigned inside the mapped bodies. Unread image content may still exist.").font(.caption) }
                    }
                    DisclosureGroup("Unmatched tag text (\(result.unmatchedTagOccurrences.count))") {
                        ForEach(result.unmatchedTagOccurrences) { tag in Text("\(tag.matchedText) · \(tag.filename) · page \(tag.pageNumber)") }
                    }
                    DisclosureGroup("Review notes (\(result.warnings.count + result.limitations.count))") {
                        ForEach(Array((result.warnings + result.limitations).enumerated()), id: \.offset) { _, warning in Text(warning).font(.caption) }
                    }
                }
            }
            ScheduleMapHistorySection(project: document.project, mapID: nil)
        }
        .toolbar {
            Button("New column map") { openEditor() }.disabled(document.drawings.records.isEmpty).accessibilityIdentifier("NewScheduleMap")
            Button("Import column map") { importSession = .init(document: document); importing = true }.disabled(preparation.isScanning || document.drawings.records.isEmpty).accessibilityIdentifier("ImportScheduleMap")
            if let request {
                Menu("Current map") {
                    Button("Read schedule again") { start(request) }.disabled(preparation.isScanning)
                    Button("Save as a map") { openEditor(request: request) }
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            defer { importSession = nil }
            do {
                guard let importSession else { throw LoadSightError.invalid("Choose the column map again for the current project.") }
                try importSession.validate(document)
                let url = try result.get(), scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                try require(size <= 1_000_000, "Column map exceeds the 1 MB limit.")
                start(try EquipmentScheduleRequest.decode(Data(contentsOf: url)))
            } catch { failure = error.localizedDescription }
        }
        .sheet(item: $editor) { session in ScheduleMapEditor(document: $document, session: session) }
        .sheet(item: $selected) { selection in EquipmentScheduleRowReview(document: $document, row: selection.value, session: selection.session) }
        .onChange(of: document.project.root["scheduleMaps"]) { _, _ in reset() }
        .onChange(of: document.drawings) { _, _ in reset() }
        .onChange(of: document.editSessionID) { _, _ in reset() }
        .onDisappear { preparation.cancel() }
        .task { if let initialRequest, request == nil { start(initialRequest) } }
    }
    private func openEditor(map: StoredScheduleMap? = nil, request: EquipmentScheduleRequest? = nil) {
        do { editor = try .init(document: document, mapID: map?.id, request: request) }
        catch { failure = error.localizedDescription }
    }
    private func read(_ map: StoredScheduleMap) {
        do { start(try map.columnMap()) } catch { failure = error.localizedDescription }
    }
    private func start(_ value: EquipmentScheduleRequest) {
        failure = nil; request = value
        preparation.start(drawings: document.drawings, documentSessionID: document.editSessionID, request: value)
    }
    private func reset() { preparation.cancel(); request = nil; selected = nil; failure = nil }
}

private struct EquipmentScheduleRowReview: View {
    @Binding var document: LoadSightDocument
    let row: EquipmentScheduleRow
    let session: DrawingReviewSession
    @Environment(\.dismiss) private var dismiss
    @State private var preview = false
    var body: some View {
        NavigationStack {
            List {
                Section("Unreviewed schedule row") {
                    Text("\(row.filename) · page \(row.pageNumber)")
                    Button("View schedule source") { preview = true }.accessibilityIdentifier("ViewScheduleSource")
                    Text("Column mapping: \(row.region.recordedBy)")
                    Text(row.region.mappingBasis).font(.caption)
                }
                ForEach(row.cells, id: \.field) { cell in
                    Section(cell.field.title) {
                        Text(cell.text ?? "Unknown — no recognized cell text").textSelection(.enabled)
                        if let unit = cell.unitText { Text("Header units: \(unit)").font(.caption) }
                        let numeric = cell.numericInterpretation
                        if numeric.status != .notNumeric {
                            if let value = numeric.value, let unit = numeric.unit {
                                Text("Numeric interpretation: \(value.formatted(.number.precision(.significantDigits(1...8)))) \(unit)")
                                    .accessibilityIdentifier("ScheduleNumeric-" + cell.field.rawValue)
                            } else { Text("Numeric interpretation: " + numeric.status.rawValue).font(.caption) }
                            DisclosureGroup("Interpretation basis") {
                                Text(numeric.explanation).font(.caption)
                                if let factor = numeric.factor, let offset = numeric.offset {
                                    Text("Source × \(factor.formatted(.number.precision(.significantDigits(1...12)))) + \(offset.formatted(.number.precision(.significantDigits(1...12))))").font(.caption)
                                }
                                Link("Unit conversion reference", destination: URL(string: ScheduleNumericInterpreter.reference)!)
                            }
                        }
                        DisclosureGroup("Cell evidence") {
                            ForEach(cell.evidence) { evidence in
                                Text("\(evidence.text) · \(evidence.method) · recognition confidence \(evidence.confidence.formatted())").font(.caption)
                            }
                        }
                    }
                }
                Section("Possible tag links") {
                    ForEach(row.matchingTagOccurrences) { candidate in Text("\(candidate.matchedText) · \(candidate.filename) · page \(candidate.pageNumber)").font(.caption) }
                }
                Section("Review required") { ForEach(Array(row.warnings.enumerated()), id: \.offset) { _, warning in Text(warning).font(.caption) } }
            }.navigationTitle(row.tag)
            .toolbar { Button("Done") { dismiss() } }
            .sheet(isPresented: $preview) {
                NavigationStack {
                    if let source = session.drawings.records.first(where: { $0.id == row.sourceID }), let data = session.drawings.files[row.sourceID] {
                        DrawingNativePreview(data: data, kind: source.kind, pageNumber: row.pageNumber, capture: false,
                            overlays: row.cells.flatMap(\.evidence).map { evidence in
                                .init(points: [.init(x: evidence.bounds.x, y: evidence.bounds.y), .init(x: evidence.bounds.x + evidence.bounds.width, y: evidence.bounds.y + evidence.bounds.height)], rectangle: true)
                            }, onPoint: { _ in })
                        .navigationTitle("Schedule source")
                        .toolbar { Button("Close source") { preview = false } }
                    } else { Text("Source unavailable. Import the drawing and read the schedule again.") }
                }
            }
        }
    }
}

extension EquipmentScheduleField {
    var title: String {
        switch self {
        case .tag: "Equipment tag"
        case .equipmentType: "Equipment type"
        case .manufacturer: "Manufacturer"
        case .model: "Model"
        case .quantity: "Schedule quantity"
        case .coolingTotal: "Total cooling capacity"
        case .coolingSensible: "Sensible cooling capacity"
        case .heatingCapacity: "Heating capacity"
        case .furnaceInput: "Furnace input"
        case .furnaceOutput: "Furnace output"
        case .airflow: "Airflow"
        case .outdoorAir: "Outdoor air"
        case .externalStaticPressure: "External static pressure"
        case .enteringWaterTemperature: "Entering water temperature"
        case .leavingWaterTemperature: "Leaving water temperature"
        case .waterFlow: "Water flow"
        case .voltage: "Voltage (coordination)"
        case .phase: "Phase (coordination)"
        case .minimumCircuitAmpacity: "Minimum circuit ampacity (coordination)"
        case .maximumOvercurrentProtection: "Maximum overcurrent protection (coordination)"
        case .weight: "Weight"
        case .dimensions: "Dimensions"
        case .sound: "Sound"
        case .accessories: "Accessories"
        case .notes: "Notes"
        }
    }
}
