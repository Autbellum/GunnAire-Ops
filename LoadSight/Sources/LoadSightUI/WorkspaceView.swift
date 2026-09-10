import SwiftUI
import LoadSightKit

public struct LoadSightWorkspaceView: View {
    @Environment(\.loadSightDocumentStorage) private var documentStorage
    @Binding var document: LoadSightDocument
    @State private var section: String? = "Overview"
    @State private var search = ""
    @State private var showingOpsContext = false
    private let opsContexts: [OpsProjectContext]
    private let catalogMaterials: [OpsMaterialCatalogSnapshot]
    @State private var mappingMaterial: ItemSelection?
    @State private var exportingWorkbook = false
    @State private var workbook: WorkbookExportDocument?
    @State private var editing: ItemSelection?
    @State private var reviewing: ItemSelection?
    @State private var errorMessage: String?
    private let sections = ["Overview", "Drawings", "Takeoff", "Estimate", "QA", "Requirements", "RFIs", "Change orders", "Attachments", "Sources", "Calculations"]
    public init(document: Binding<LoadSightDocument>, opsContexts: [OpsProjectContext] = [], catalogMaterials: [OpsMaterialCatalogSnapshot] = []) { _document = document; self.opsContexts = opsContexts; self.catalogMaterials = catalogMaterials }
    public var body: some View {
        NavigationSplitView {
            List(sections, id: \.self, selection: $section) { title in
                Label(title, systemImage: symbol(title)).tag(title)
            }
            .navigationTitle("LoadSight")
        } detail: {
            Group {
                switch section {
                case "Drawings": DrawingsWorkspaceView(document: $document)
                case "Takeoff": takeoff
                case "Estimate": CommercialWorkspaceView(document: $document)
                case "QA": QAWorkspaceView(document: $document)
                case "Attachments": AttachmentsWorkspaceView(document: $document)
                case "Requirements": register("requirements", title: "Specifications & obligations", primary: "requirement", secondary: "source")
                case "RFIs": RFIWorkspaceView(document: $document)
                case "Change orders": ChangeOrderWorkspaceView(document: $document)
                case "Sources": register("sheets", title: "Drawing register", primary: "title", secondary: "revision")
                case "Calculations": CalculationWorkspaceView(document: $document)
                default: overview
                }
            }
            .navigationTitle(section ?? "Overview")
        }
        .sheet(isPresented: $showingOpsContext) { OpsContextEditor(document: $document, choices: opsContexts) }
        .sheet(item: $editing) { selected in
            if let row = document.project.items.first(where: { $0["id"]?.string == selected.id }) {
                TakeoffItemEditor(row: row) { fields in
                    do { try document.project.updateItem(id: selected.id, fields: fields); editing = nil }
                    catch { errorMessage = error.localizedDescription }
                }
            }
        }
        .fileExporter(isPresented: $exportingWorkbook, document: workbook, contentType: WorkbookExportDocument.contentType, defaultFilename: "LoadSight-Takeoff") { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
        }
        .sheet(item: $mappingMaterial) { selected in CatalogMaterialEditor(document: $document, itemID: selected.id, choices: catalogMaterials) }
        .sheet(item: $reviewing) { selected in ItemReviewEditor(document: $document, id: selected.id) }
        .alert("Unable to save change", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .tint(Color(red: 0, green: 0.48, blue: 0.45))
    }
    private func symbol(_ title: String) -> String {
        switch title { case "Drawings": "doc.viewfinder"; case "Takeoff": "list.bullet.rectangle"; case "Requirements": "checklist"; case "RFIs": "questionmark.bubble"; case "Sources": "doc.text.magnifyingglass"; case "Calculations": "function"; default: "square.grid.2x2" }
    }
    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(document.project.name).font(.largeTitle.bold())
                GroupBox("Ops project context") {
                    VStack(alignment: .leading, spacing: 8) {
                        OpsContextSummary(context: try? document.project.opsContext())
                        Button("Review Ops link") { showingOpsContext = true }.accessibilityIdentifier("ReviewOpsContext")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(document.project.root["scopePolicy"].string ?? "Mechanical scope • plumbing and electrical trade takeoffs excluded")
                    .foregroundStyle(.secondary)
                if let review = try? EstimatePricing.review(document.project) {
                    Label(review.ready ? "Review gates complete" : "Draft — not for bid release", systemImage: review.ready ? "checkmark.seal" : "exclamationmark.circle")
                        .font(.headline).foregroundStyle(review.ready ? Color.green : Color.orange)
                    HStack(spacing: 24) {
                        metric("Takeoff rows", value: "\(document.project.items.count)")
                        metric("Costed rows", value: "\(review.pricedCount) / \(review.includedCount)")
                        metric("Review issues", value: "\(review.blockers.count)")
                    }
                    GroupBox("Estimate readiness") {
                        VStack(alignment: .leading, spacing: 12) {
                            if let price = review.releasableSellingPrice { Text(price, format: .currency(code: "USD")).font(.title.bold()) }
                            ForEach(review.blockers, id: \.self) { Text("• " + $0).frame(maxWidth: .infinity, alignment: .leading) }
                        }.padding(8)
                    }
                }
                Text(documentStorage.guidance)
                    .font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("LoadSightDocumentStorageGuidance")
            }.padding(28).frame(maxWidth: 1000, alignment: .leading)
        }
    }
    private func metric(_ name: String, value: String) -> some View {
        VStack(alignment: .leading) { Text(value).font(.title.bold()); Text(name).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var takeoff: some View {
        List {
            ForEach(document.project.items.filter { search.isEmpty || String(describing: $0).localizedCaseInsensitiveContains(search) }.map { (id: $0["id"]!.string!, fields: $0) }, id: \.id) { entry in
                let row = entry.fields
                HStack {
                Button { editing = .init(id: row["id"]?.string ?? "") } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(row["id"]?.string ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(row["lifecycle"]?.string ?? "").font(.caption)
                            Spacer()
                            Text(row["scope"]?.string ?? "").font(.caption.bold())
                        }
                        Text(row["description"]?.string ?? "").font(.headline).foregroundStyle(.primary)
                        HStack {
                            Text(row["quantity"]?.number.map { String(format: "%g", $0) } ?? "Unmeasured")
                            Text(row["unit"]?.string ?? "")
                            Text("· " + (row["quantityStatus"]?.string ?? ""))
                        }.foregroundStyle(.secondary)
                        Text(row["source"]?.string ?? "No source reference").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 6)
                }.buttonStyle(.plain)
                VStack {
                    Button("Review") { reviewing = .init(id: entry.id) }.buttonStyle(.bordered)
                    Button("Catalog cost") { mappingMaterial = .init(id: entry.id) }.buttonStyle(.bordered).accessibilityIdentifier("CatalogCost-" + entry.id)
                }
                }
            }
        }.searchable(text: $search, prompt: "Find an item, source, or RFI")
        .toolbar { Button("Export XLSX") {
            do { workbook = WorkbookExportDocument(data: try TakeoffWorkbook.xlsx(document.project, drawings: document.drawings)); exportingWorkbook = true }
            catch { errorMessage = error.localizedDescription }
        } }
        .overlay { if document.project.items.isEmpty { ContentUnavailableView("No takeoff items", systemImage: "list.bullet.rectangle", description: Text("Open a workbench project to review its takeoff.")) } }
    }
    private func register(_ key: String, title: String, primary: String, secondary: String) -> some View {
        let rows = document.project.root[key].array ?? []
        return List(Array(rows.enumerated()), id: \.offset) { _, row in
            VStack(alignment: .leading, spacing: 8) {
                Text(row["id"].string ?? row["sheet"].string ?? title).font(.headline)
                if let status = row["status"].string { Text(status).font(.caption.bold()).foregroundStyle(status == "Resolved" ? Color.green : Color.orange) }
                Text(row[primary].string ?? "")
                Text(row[secondary].string ?? "").font(.callout).foregroundStyle(.secondary)
                if key == "rfis" { Text(row["source"].string ?? "").font(.caption).foregroundStyle(.secondary) }
            }.padding(.vertical, 8)
        }.overlay { if rows.isEmpty { ContentUnavailableView("No records", systemImage: "doc.text", description: Text("This project has no \(title.lowercased()).")) } }
    }
}

private struct ItemSelection: Identifiable { let id: String }

private struct TakeoffItemEditor: View {
    let row: [String: JSONValue]
    let save: ([String: JSONValue]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var fields: [String: String] = [:]
    @State private var validation: String?
    private let numeric = ["quantity", "materialUnit", "laborHoursUnit", "subcontractUnit", "otherUnit", "wastePct"]
    private let labels = ["quantity": "Quantity", "materialUnit": "Material cost per unit", "laborHoursUnit": "Labor hours per unit", "subcontractUnit": "Subcontract cost per unit", "otherUnit": "Other cost per unit", "wastePct": "Material waste (%)", "source": "Drawing source", "priceSource": "Price and labor basis", "notes": "Field notes"]
    var body: some View {
        NavigationStack {
            Form {
                Section { Text(row["description"]?.string ?? "").font(.headline); Text(row["lifecycle"]?.string ?? "") }
                Section("Quantity & costs") {
                    ForEach(numeric, id: \.self) { key in
                        TextField(labels[key]!, text: binding(key)).accessibilityIdentifier("Takeoff_" + key)
                            .disabled(key == "quantity" && row["nativeMarkupID"] != nil)
                    }
                    Text("Leave unknown values blank. Enter zero only when deliberately confirmed. Waste applies to material cost.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Evidence") {
                    ForEach(["source", "priceSource", "notes"], id: \.self) { key in
                        TextField(labels[key]!, text: binding(key), axis: .vertical).disabled(key == "source" && row["nativeMarkupID"] != nil)
                    }
                }
                if let validation { Text(validation).foregroundStyle(.red) }
                Text("Saving changes reopens the estimate review checks.").font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle(row["id"]?.string ?? "Takeoff item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { commit() }.accessibilityIdentifier("SaveTakeoffItem") }
            }
            .onAppear {
                for key in numeric + ["source", "priceSource", "notes"] {
                    fields[key] = row[key]?.string ?? row[key]?.number.map { String($0) } ?? ""
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 640)
        #endif
    }
    private func binding(_ key: String) -> Binding<String> { .init(get: { fields[key] ?? "" }, set: { fields[key] = $0 }) }
    private func commit() {
        var values: [String: JSONValue] = [:]
        for key in numeric {
            if key == "quantity" && row["nativeMarkupID"] != nil { continue }
            let text = (fields[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { values[key] = .null }
            else if let n = Double(text), n.isFinite, n >= 0 { values[key] = .number(n) }
            else { validation = "\(labels[key]!) must be a nonnegative number or blank."; return }
        }
        for key in ["source", "priceSource", "notes"] {
            if key == "source" && row["nativeMarkupID"] != nil { continue }
            values[key] = .string(fields[key] ?? "")
        }
        save(values)
    }
}

struct CalculationWorkbench: View {
    @State private var cfm = "1200"
    @State private var delta = "20"
    @State private var result: CalculationTrace?
    @State private var failure: String?
    var body: some View {
        Form {
            Section("Sensible air load") {
                Text("Engineering worksheet · standard air approximation").foregroundStyle(.secondary)
                TextField("Airflow (CFM)", text: $cfm)
                TextField("Temperature difference (°F)", text: $delta)
                Button("Calculate") {
                    do {
                        guard let air = Double(cfm), let temperature = Double(delta) else { throw LoadSightError.invalid("Enter numeric airflow and temperature difference.") }
                        result = try MechanicalMath.sensibleAir(cfm: air, deltaF: temperature); failure = nil
                    } catch { failure = error.localizedDescription; result = nil }
                }
            }
            if let result {
                Section("Calculation trace") {
                    Text(result.equation); Text(result.substitution).monospaced()
                    Text("\(result.value.formatted()) \(result.unit)").font(.title2.bold())
                    ForEach(result.assumptions, id: \.self) { Text($0).foregroundStyle(.secondary) }
                }
            }
            if let failure { Text(failure).foregroundStyle(.red) }
        }.formStyle(.grouped)
    }
}
