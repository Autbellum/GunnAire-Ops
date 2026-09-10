import SwiftUI
import LoadSightKit

private struct CatalogMappingForm: Equatable {
    var selection = -1
    var purchaseUnit = ""
    var factor = ""
    var basis = ""
    var author = ""
    var reason = ""
    var confirmsUSD = false
}
struct CatalogMaterialEditor: View {
    @Binding var document: LoadSightDocument
    let itemID: String
    let choices: [OpsMaterialCatalogSnapshot]
    @Environment(\.dismiss) private var dismiss
    @State private var form = CatalogMappingForm()
    @State private var baseline = CatalogMappingForm()
    @State private var snapshots: [OpsMaterialCatalogSnapshot] = []
    @State private var saved: CatalogMaterialMapping?
    @State private var history: [CatalogMaterialRevision] = []
    @State private var fingerprint = ""
    @State private var loaded = false
    @State private var failure: String?
    @State private var discard = false
    private var dirty: Bool { form != baseline }
    private var row: [String: JSONValue] { document.project.items.first { $0["id"]?.string == itemID } ?? [:] }
    private var selected: OpsMaterialCatalogSnapshot? { snapshots.indices.contains(form.selection) ? snapshots[form.selection] : nil }
    var body: some View {
        NavigationStack {
            Form {
                Section("Takeoff material") {
                    Text(row["description"]?.string ?? itemID).font(.headline)
                    LabeledContent("Takeoff unit", value: row["unit"]?.string ?? "Missing")
                    LabeledContent("Current material cost", value: cost(row["materialUnit"]?.number))
                    if let saved {
                        Text(saved.matches(row) ? "Recorded catalog basis matches this item." : "The recorded catalog basis is stale. Review the changed item or cost.")
                            .foregroundStyle(saved.matches(row) ? Color.secondary : Color.orange)
                        Text("Recorded source: \(saved.catalog.name) · \(saved.catalog.updatedAt)").font(.caption)
                    }
                }
                Section("Catalog source") {
                    Picker("Material", selection: $form.selection) {
                        Text("Choose a catalog material").tag(-1)
                        ForEach(Array(snapshots.enumerated()), id: \.offset) { index, snapshot in
                            Text((saved != nil && index == 0 ? "Saved snapshot: " : "Catalog: ") + snapshot.name + (snapshot.sku.isEmpty ? "" : " · " + snapshot.sku)).tag(index)
                        }
                    }.accessibilityIdentifier("CatalogMaterialChoice")
                    if snapshots.isEmpty { Text("No approved material catalog records are available from this host. Open this project from Ops to select one.").foregroundStyle(.secondary) }
                    if let selected {
                        Text(selected.source).font(.caption)
                        LabeledContent("Catalog ID", value: selected.id.uuidString)
                        LabeledContent("Snapshot updated", value: selected.updatedAt)
                        LabeledContent("Supplier", value: selected.supplier.isEmpty ? "Not recorded" : selected.supplier)
                        LabeledContent("Supplier part", value: selected.supplierPartNumber.isEmpty ? "Not recorded" : selected.supplierPartNumber)
                        LabeledContent("Purchase cost amount", value: selected.purchaseCost.map { String($0) } ?? "Unknown")
                    }
                    Text("This records the selected snapshot. Later catalog changes do not refresh a saved estimate automatically. Selling prices are never used as purchase costs.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Purchasing unit and evidence") {
                    Toggle("I verified this purchase cost is in USD", isOn: $form.confirmsUSD).accessibilityIdentifier("CatalogConfirmUSD")
                    TextField("Catalog purchase unit (each, box, length…)", text: $form.purchaseUnit).accessibilityIdentifier("CatalogPurchaseUnit")
                    TextField("Catalog units per one takeoff unit", text: $form.factor).accessibilityIdentifier("CatalogUnitFactor")
                    Text("Example: a box containing 10 each uses 0.1 boxes per EA. Quantity and material waste remain separate.").font(.caption).foregroundStyle(.secondary)
                    if let selected, let factor = Double(form.factor), factor.isFinite, factor > 0 {
                        LabeledContent("Mapped material cost per takeoff unit", value: cost(selected.purchaseCost.map { $0 * factor }))
                    }
                    TextField("Part compatibility, unit conversion and cost evidence", text: $form.basis, axis: .vertical).accessibilityIdentifier("CatalogMappingBasis")
                    TextField("Recorded by", text: $form.author).accessibilityIdentifier("CatalogMappingAuthor")
                    TextField("Reason for this mapping or removal", text: $form.reason, axis: .vertical).accessibilityIdentifier("CatalogMappingReason")
                    Text("Applying replaces material cost, including replacing it with Unknown when the catalog cost is missing. Labor, quantity, other costs and their existing basis are retained. QA reopens.").font(.caption).foregroundStyle(.secondary)
                    if let failure { Text(failure).foregroundStyle(.red) }
                }
                if saved != nil {
                    Section("Remove recorded mapping") {
                        Button("Remove link and retain entered cost") { save(removing: true) }.accessibilityIdentifier("RemoveCatalogMapping")
                        Text("Removal requires a recorded author and reason. The current cost and all mapping history remain; review its manual price basis before completing QA.").font(.caption)
                    }
                }
                if !history.isEmpty {
                    Section("Mapping history") {
                        ForEach(history.reversed()) { event in
                            DisclosureGroup("\(event.author) · \(event.recordedAt)") {
                                Text(event.reason)
                                Text("Material cost: \(cost(event.beforeMaterialUnit.number)) → \(cost(event.afterMaterialUnit.number))")
                                historySnapshot(event.before, title: "Before")
                                historySnapshot(event.after, title: "After")
                            }
                        }
                    }
                }
            }.formStyle(.grouped)
            .navigationTitle("Catalog material cost")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if dirty { discard = true } else { dismiss() } } }
                ToolbarItem(placement: .confirmationAction) { Button("Apply mapping") { save(removing: false) }.disabled(selected == nil || !form.confirmsUSD || fingerprint.isEmpty).accessibilityIdentifier("ApplyCatalogMapping") }
            }
            .onAppear { load() }
            .interactiveDismissDisabled(dirty)
            .alert("Discard catalog mapping edits?", isPresented: $discard) {
                Button("Discard edits", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
        }
        #if os(macOS)
        .frame(minWidth: 650, minHeight: 750)
        #endif
    }
    private func cost(_ number: Double?) -> String { number.map { $0.formatted(.currency(code: "USD")) } ?? "Unknown" }
    @ViewBuilder private func historySnapshot(_ value: JSONValue, title: String) -> some View {
        if value == .null { Text("\(title): No catalog mapping") }
        else {
            Text("\(title): \(value["catalog"]["name"].string ?? "") · \(value["catalog"]["source"].string ?? "")")
            Text("Catalog ID: \(value["catalog"]["id"].string ?? "") · Updated \(value["catalog"]["updatedAt"].string ?? "")")
            Text("\(value["catalogUnitsPerTakeoffUnit"].number.map { String($0) } ?? "") \(value["purchaseUnit"].string ?? "") per \(value["takeoffUnit"].string ?? "")")
            Text(value["basis"].string ?? "")
        }
    }
    private func load() {
        guard !loaded else { return }; loaded = true
        do {
            saved = try document.project.catalogMaterialMapping(itemID: itemID)
            history = try document.project.catalogMaterialHistory().filter { $0.itemID == itemID }
            fingerprint = try document.project.catalogMaterialEditFingerprint(itemID: itemID)
            snapshots = saved.map { [$0.catalog] } ?? []
            for candidate in choices where !snapshots.contains(candidate) { try candidate.validate(); snapshots.append(candidate) }
            if let saved {
                form.selection = 0; form.purchaseUnit = saved.purchaseUnit; form.factor = String(saved.catalogUnitsPerTakeoffUnit)
                form.basis = saved.basis
            }
            baseline = form
        } catch { failure = error.localizedDescription }
    }
    private func save(removing: Bool) {
        do {
            var mapping: CatalogMaterialMapping?
            if !removing {
                guard let selected, form.confirmsUSD, let factor = Double(form.factor.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw LoadSightError.invalid("Select a material, confirm USD and enter a unit conversion.") }
                mapping = .init(catalog: selected, currency: "USD", purchaseUnit: form.purchaseUnit, catalogUnitsPerTakeoffUnit: factor, takeoffUnit: row["unit"]?.string ?? "", itemDescription: row["description"]?.string ?? "", lifecycle: row["lifecycle"]?.string ?? "", basis: form.basis)
            }
            try document.project.updateCatalogMaterialMapping(itemID: itemID, mapping: mapping, expectedFingerprint: fingerprint, author: form.author, reason: form.reason)
            dismiss()
        } catch { failure = error.localizedDescription }
    }
}
