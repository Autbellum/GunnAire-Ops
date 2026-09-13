import SwiftUI
import PDFKit
import ImageIO
import LoadSightKit

struct DrawingsWorkspaceView: View {
    @Binding var document: LoadSightDocument
    @State private var selected: String?
    @State private var pageNumber = 1
    @State private var importing = false
    @State private var importDestinationID: UUID?
    @State private var progress: DrawingImportProgress?
    @State private var worker: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var fullOCR = false
    @State private var showText = false
    @State private var mode: MarkupMode = .inspect
    @State private var points: [PagePoint] = []
    @State private var itemName = ""
    @State private var system = "Supply air"
    @State private var size = ""
    @State private var author = ""
    @State private var lifecycle: WorkLifecycle = .new
    @State private var knownFeet = ""
    @State private var dimensionSource = ""
    @State private var viewName = "Main plan"
    @State private var selectedView = ""
    @State private var linkedObject = ""
    private var ledger: MarkupLedger { (try? document.project.markupLedger()) ?? MarkupLedger() }
    private var pageViews: [CalibratedView] { ledger.views.filter { $0.pageID == page?.id } }
    private var activeView: CalibratedView? { pageViews.first { $0.id == selectedView } ?? pageViews.first }
    private var record: DrawingRecord? { document.drawings.records.first { $0.id == selected } ?? document.drawings.records.first }
    private var page: DrawingPage? { record?.pages.first { $0.number == pageNumber } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Import drawings", systemImage: "plus") {
                    importDestinationID = document.editSessionID; importing = true
                }.disabled(worker != nil)
                    .accessibilityIdentifier("ImportDrawings")
                Toggle("OCR every PDF page", isOn: $fullOCR).toggleStyle(.checkboxIfMac).disabled(worker != nil)
                Spacer()
                if let progress {
                    ProgressView().controlSize(.small)
                    Text("\(progress.filename) · \(progress.page)/\(progress.totalPages)").font(.caption)
                    Button("Cancel") { worker?.cancel() }
                }
            }.padding()
            if let record, let data = document.drawings.files[record.id], let page {
                HStack {
                    Picker("Source", selection: Binding(get: { record.id }, set: { selected = $0; pageNumber = 1 })) {
                        ForEach(document.drawings.records) { Text($0.filename).tag($0.id) }
                    }
                    Stepper("Page \(pageNumber) of \(record.pages.count)", value: $pageNumber, in: 1...record.pages.count)
                    Toggle("Text evidence", isOn: $showText).toggleStyle(.button)
                }.padding(.horizontal).padding(.bottom, 8)
                markupControls
                HStack(spacing: 0) {
                    DrawingNativePreview(data: data, kind: record.kind, pageNumber: pageNumber, capture: mode != .inspect, overlays: overlays, onPoint: capturePoint)
                        .id(record.id)
                        .accessibilityLabel("Drawing page \(pageNumber), \(record.filename)")
                    if showText {
                        List {
                            Section("Sheet references found · verify title block") {
                                Text(page.sheetCandidates.isEmpty ? "No sheet reference recognized" : page.sheetCandidates.joined(separator: ", "))
                            }
                            Section("Review notes") { ForEach(page.warnings, id: \.self) { Text($0).font(.caption) } }
                            Section("Text anchors") {
                                ForEach(page.text) { anchor in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(anchor.text).textSelection(.enabled)
                                        Text("\(anchor.method) · \(Int(anchor.confidence * 100))% recognition").font(.caption).foregroundStyle(.secondary)
                                        Text("x \(anchor.bounds.x.formatted())  y \(anchor.bounds.y.formatted())").font(.caption2.monospaced()).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }.frame(minWidth: 220, idealWidth: 300, maxWidth: 360)
                    }
                }
                Text("Source \(record.id.prefix(12)) · original retained · \(page.bounds.width.formatted()) × \(page.bounds.height.formatted()) \(record.kind == "pdf" ? "page points" : "display pixels") · \(pageViews.count) calibrated views")
                    .font(.caption).foregroundStyle(.secondary).padding(8)
            } else {
                ContentUnavailableView("Import your mechanical drawings", systemImage: "doc.viewfinder", description: Text("PDF, PNG, JPEG, HEIC and TIFF stay on this device. Original files and recognized text save with your project."))
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .image], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): startImport(urls)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .alert("Drawing import", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .onDisappear { worker?.cancel() }
        .onChange(of: page?.id) { _, _ in points = []; selectedView = ""; mode = .inspect }
        .onChange(of: mode) { _, _ in points = [] }
    }
    private var markupControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Drawing tool", selection: $mode) { ForEach(MarkupMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                if !points.isEmpty { Button("Undo point") { points.removeLast() } }
                if ledger.lastUndoableAction != nil {
                    Button("Undo last save") {
                        do { var copy = ledger; try copy.undoLast(author: author); try document.applyMarkup(copy) }
                        catch { errorMessage = error.localizedDescription }
                    }.help("Undo the latest saved markup, retaining its evidence in the correction history.")
                }
                if [.calibrate, .check, .route].contains(mode) {
                    Button("Save \(mode == .route ? "route" : "calibration")") { commitPoints() }
                        .disabled(points.count < (mode == .calibrate ? 4 : 2))
                }
            }
            if mode != .inspect {
                ScrollView(.horizontal) {
                    HStack {
                        TextField("Recorded by", text: $author).frame(width: 150)
                        if mode == .count || mode == .route {
                            TextField("Item / operation", text: $itemName).frame(width: 170)
                            Picker("Lifecycle", selection: $lifecycle) { ForEach(WorkLifecycle.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(width: 170)
                            TextField("System", text: $system).frame(width: 130)
                            TextField("Size / material", text: $size).frame(width: 140)
                        }
                        if mode == .calibrate || mode == .check {
                            TextField("View name", text: $viewName).frame(width: 130)
                            TextField("Known feet", text: $knownFeet).frame(width: 90)
                            TextField("Dimension source", text: $dimensionSource).frame(width: 220)
                        }
                    }.textFieldStyle(.roundedBorder)
                }
                if mode == .route || mode == .check {
                    Picker("Calibrated view", selection: Binding(get: { activeView?.id ?? "" }, set: { selectedView = $0; points = [] })) {
                        if pageViews.isEmpty { Text("Create a calibrated view first").tag("") }
                        ForEach(pageViews) { view in Text(view.name + (view.check == nil ? " · needs check" : " · checked")).tag(view.id) }
                    }
                }
                if mode == .count {
                    Picker("Physical item", selection: $linkedObject) {
                        Text("New physical object per tap").tag("")
                        ForEach(ledger.objects) { Text("Link existing: \($0.descriptor.label) · \($0.id.prefix(6))").tag($0.id) }
                    }
                }
                Text(mode.instructions).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Pan and zoom to inspect. Select a tool to record page-coordinate evidence.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.horizontal).padding(.bottom, 8)
    }
    private var overlays: [DrawingOverlay] {
        guard let page else { return [] }
        var marks = ledger.objects.flatMap { $0.anchors.filter { $0.pageID == page.id }.map { DrawingOverlay(points: [$0.point]) } }
        marks += pageViews.map { DrawingOverlay(points: [$0.min, $0.max], rectangle: true) }
        marks += ledger.routes.filter { route in pageViews.contains { $0.id == route.viewID } }.map { DrawingOverlay(points: $0.points) }
        if mode == .calibrate && points.count >= 2 {
            marks.append(.init(points: Array(points.prefix(2)), rectangle: true, pending: true))
            if points.count > 2 { marks.append(.init(points: Array(points.dropFirst(2)), pending: true)) }
        } else { marks.append(.init(points: points, pending: true)) }
        return marks
    }
    private func capturePoint(_ point: PagePoint) {
        guard let page else { return }
        do {
            if mode == .count {
                var copy = ledger
                let existing = copy.objects.first { $0.id == linkedObject }
                let descriptor = existing?.descriptor ?? TakeoffDescriptor(label: itemName, lifecycle: lifecycle, system: system, size: size)
                try copy.count(id: existing?.id ?? UUID().uuidString, descriptor: descriptor, anchor: .init(pageID: page.id, point: point, author: author))
                try document.applyMarkup(copy)
            } else if mode != .inspect {
                let limit = mode == .calibrate ? 4 : mode == .check ? 2 : 1000
                if points.count < limit { points.append(point) }
            }
        } catch { errorMessage = error.localizedDescription }
    }
    private func commitPoints() {
        guard let page else { return }
        do {
            var copy = ledger
            if mode == .calibrate || mode == .check {
                guard let feet = Double(knownFeet), feet.isFinite, feet > 0 else { throw LoadSightError.invalid("Enter a positive known dimension in feet.") }
                if mode == .calibrate {
                    try require(points.count == 4, "Select two view corners, then two ends of the known dimension.")
                    let view = CalibratedView(pageID: page.id, name: viewName,
                        min: .init(x: min(points[0].x,points[1].x), y: min(points[0].y,points[1].y)),
                        max: .init(x: max(points[0].x,points[1].x), y: max(points[0].y,points[1].y)),
                        dimension: .init(points: Array(points.suffix(2)), feet: feet, source: dimensionSource), author: author)
                    try copy.addView(view); try document.applyMarkup(copy); selectedView = view.id
                } else {
                    guard let view = activeView else { throw LoadSightError.invalid("Choose a calibrated view.") }
                    try copy.checkView(id: view.id, dimension: .init(points: points, feet: feet, source: dimensionSource), author: author)
                    try document.applyMarkup(copy)
                    if let checked = copy.views.first(where: { $0.id == view.id }), let error = try checked.scale().validationErrorFraction, error > 0.02 {
                        errorMessage = "Calibration check differs by \((error*100).formatted())%. Create a corrected view before measuring routes."
                    }
                }
            } else if mode == .route {
                guard let view = activeView else { throw LoadSightError.invalid("Calibrate and independently check this view first.") }
                try copy.measure(viewID: view.id, descriptor: .init(label: itemName, lifecycle: lifecycle, system: system, size: size), points: points, author: author)
                try document.applyMarkup(copy)
            }
            points = []
        } catch { errorMessage = error.localizedDescription }
    }
    private func startImport(_ urls: [URL]) {
        guard worker == nil, !urls.isEmpty, let destinationID = importDestinationID,
              destinationID == document.editSessionID else { return }
        let mode: DrawingOCRMode = fullOCR ? .everyPage : .whenNoText
        worker = Task {
            defer { worker = nil; progress = nil }
            do {
                let ingestor = DrawingIngestor()
                var batch = DrawingArchive()
                for url in urls {
                    progress = .init(filename: url.lastPathComponent, page: 0, totalPages: 1)
                    let archive = try await ingestor.ingest(url: url, ocr: mode) { update in
                        await MainActor.run { progress = update }
                    }
                    for source in archive.records { try batch.insert(record: source, data: archive.files[source.id]!) }
                }
                try Task.checkCancellation()
                try document.applyEdit(for: destinationID) { try $0.addDrawings(batch) }
                selected = batch.records.first?.id; pageNumber = 1
            } catch is CancellationError { /* Batch is not committed on cancellation. */ }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

private enum MarkupMode: String, CaseIterable {
    case inspect = "Inspect", count = "Count", calibrate = "Calibrate", check = "Check", route = "Route"
    var instructions: String {
        switch self {
        case .inspect: "Pan and zoom."
        case .count: "Each tap records one physical object and creates a draft takeoff row. Link an existing object for another view of the same item."
        case .calibrate: "Tap two opposite view corners, then the two endpoints of a sourced known dimension. Enter its feet and source, then save. Each detail needs its own view."
        case .check: "Tap a different known dimension, preferably in another direction. Enter its feet and source. A difference above 2% requires recalibration."
        case .route: "Tap centerline vertices, then save. Split routes when size, material, system or lifecycle changes. Verticals, fittings and waste remain separate."
        }
    }
}

private extension ToggleStyle where Self == DefaultToggleStyle {
    // Default platform styling keeps touch targets native on iPad.
    static var checkboxIfMac: DefaultToggleStyle { DefaultToggleStyle() }
}

@MainActor
func previewDocument(data: Data, kind: String) -> PDFDocument? {
    if kind == "pdf" { return PDFDocument(data: data) }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let document = PDFDocument()
    for index in 0..<CGImageSourceGetCount(source) {
        guard let cgImage = DrawingIngestor.orientedImage(source: source, index: index) else { return nil }
        #if os(macOS)
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #else
        let image = UIImage(cgImage: cgImage)
        #endif
        guard let page = PDFPage(image: image) else { return nil }
        document.insert(page, at: document.pageCount)
    }
    return document
}
