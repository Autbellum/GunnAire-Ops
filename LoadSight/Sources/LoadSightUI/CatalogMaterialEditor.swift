import SwiftUI
import LoadSightKit

struct CatalogMappingForm: Equatable {
    var selection = -1
    var purchaseUnit = ""
    var factor = ""
    var basis = ""
    var author = ""
    var reason = ""
    var confirmsUSD = false
    var recordsQuote = false
    var quoteSupplier = ""
    var quoteReference = ""
    var quoteSource = ""
    var quoteIssuedAt = ""
    var quoteValidUntil = ""
    var quoteConditions = ""
    func quoteEvidence() throws -> SupplierQuoteEvidence? {
        guard recordsQuote else { return nil }
        let quote = SupplierQuoteEvidence(supplier: quoteSupplier, reference: quoteReference, source: quoteSource,
            issuedAt: quoteIssuedAt.trimmingCharacters(in: .whitespacesAndNewlines),
            validUntil: quoteValidUntil.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : quoteValidUntil.trimmingCharacters(in: .whitespacesAndNewlines), conditions: quoteConditions)
        try quote.validate(); return quote
    }
    mutating func select(_ index: Int) {
        guard selection != index else { return }
        selection = index; confirmsUSD = false; purchaseUnit = ""; factor = ""; basis = ""
        recordsQuote = false; quoteSupplier = ""; quoteReference = ""; quoteSource = ""
        quoteIssuedAt = ""; quoteValidUntil = ""; quoteConditions = ""
    }
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
    @State private var comparison: CatalogSnapshotComparison?
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
                if let comparison {
                    Section("Compare supplied Ops record") {
                        Text(comparison.message).accessibilityIdentifier("CatalogComparisonStatus")
                        ForEach(comparison.differences) { difference in
                            LabeledContent(difference.field, value: display(difference.saved) + " → " + display(difference.available))
                        }
                        if let delta = comparison.purchaseCostDelta, comparison.status == .changed {
                            LabeledContent("Purchase cost amount change", value: String(delta))
                        }
                        if comparison.status == .changed, let candidate = comparison.candidate {
                            Button("Use supplied record for review") { selectCandidate(candidate) }.accessibilityIdentifier("ReviewCurrentCatalogRecord")
                        }
                        Text("This compares records supplied when the editor opened. Selection does not save or reprice the project. Confirm currency, purchasing units and compatibility again before Apply mapping.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Catalog source") {
                    Picker("Material", selection: Binding(get: { form.selection }, set: { form.select($0) })) {
                        Text("Choose a catalog material").tag(-1)
                        ForEach(Array(snapshots.enumerated()), id: \.offset) { index, snapshot in
                            Text((saved != nil && index == 0 ? "Saved snapshot: " : "Catalog: ") + snapshot.name + (snapshot.sku.isEmpty ? "" : " · " + snapshot.sku)).tag(index)
                        }
                    }.accessibilityIdentifier("CatalogMaterialChoice")
                    if snapshots.isEmpty { Text("No approved material catalog records are available from this host. Open this project from Ops to select one.").foregroundStyle(.secondary) }
                    if let selected {
                        LabeledContent("Supplier", value: selected.supplier.isEmpty ? "Not recorded" : selected.supplier)
                        LabeledContent("Purchase cost amount", value: selected.purchaseCost.map { String($0) } ?? "Unknown")
                        DisclosureGroup("Source details") {
                            Text(selected.source).font(.caption)
                            LabeledContent("Catalog ID", value: selected.id.uuidString)
                            LabeledContent("Snapshot updated", value: selected.updatedAt)
                            LabeledContent("Supplier part", value: selected.supplierPartNumber.isEmpty ? "Not recorded" : selected.supplierPartNumber)
                        }
                    }
                    Text("Selecting another record clears currency confirmation, purchasing units and compatibility evidence for a fresh review. Later catalog changes do not refresh a saved estimate automatically. Selling prices are never used as purchase costs.").font(.caption).foregroundStyle(.secondary)
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
                quoteSection
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
    private var quoteSection: some View {
        Section("Supplier quote evidence") {
            Toggle("Record a supplier quote for this cost", isOn: $form.recordsQuote).accessibilityIdentifier("CatalogRecordQuote")
            if form.recordsQuote {
                TextField("Quote supplier", text: $form.quoteSupplier).accessibilityIdentifier("QuoteSupplier")
                TextField("Quote reference", text: $form.quoteReference).accessibilityIdentifier("QuoteReference")
                TextField("Source document, page or correspondence reference", text: $form.quoteSource, axis: .vertical).accessibilityIdentifier("QuoteSource")
                TextField("Issued at (2026-09-10T09:00:00-04:00)", text: $form.quoteIssuedAt).accessibilityIdentifier("QuoteIssuedAt")
                TextField("Valid until (blank if unknown)", text: $form.quoteValidUntil).accessibilityIdentifier("QuoteValidUntil")
                Text("Copy the quote's date, time and timezone. Expiry is exclusive: the quote is expired at the entered instant. Record how any date-only terms were interpreted in Conditions.").font(.caption)
                TextField("Conditions: quantities, freight, tax, lead time and exclusions", text: $form.quoteConditions, axis: .vertical).accessibilityIdentifier("QuoteConditions")
                if let quote = try? form.quoteEvidence(), let review = try? quote.review(asOf: Date()) {
                    Text(review.message).accessibilityIdentifier("SupplierQuoteStatus")
                    Text("Reviewed as of \(review.asOf)").font(.caption)
                }
            } else {
                Text("No supplier quote is asserted. The catalog snapshot and other price evidence remain separate from quote validity.").font(.caption)
            }
            Text("Quote evidence applies to this saved cost and purchasing unit. Selecting a different source clears it. Incomplete or expired recorded quotes hold release; draft costs and history are retained.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func display(_ value: JSONValue) -> String {
        value.string ?? value.number.map { String($0) } ?? "Unknown"
    }
    private func selectCandidate(_ candidate: OpsMaterialCatalogSnapshot) {
        guard let index = snapshots.firstIndex(of: candidate) else { return }
        form.select(index)
    }
    private func cost(_ number: Double?) -> String { number.map { $0.formatted(.currency(code: "USD")) } ?? "Unknown" }
    @ViewBuilder private func historySnapshot(_ value: JSONValue, title: String) -> some View {
        if value == .null { Text("\(title): No catalog mapping") }
        else {
            Text("\(title): \(value["catalog"]["name"].string ?? "") · \(value["catalog"]["source"].string ?? "")")
            Text("Catalog ID: \(value["catalog"]["id"].string ?? "") · Updated \(value["catalog"]["updatedAt"].string ?? "")")
            Text("\(value["catalogUnitsPerTakeoffUnit"].number.map { String($0) } ?? "") \(value["purchaseUnit"].string ?? "") per \(value["takeoffUnit"].string ?? "")")
            Text(value["basis"].string ?? "")
            if value["quote"] != .null {
                Text("Quote: \(value["quote"]["supplier"].string ?? "") · \(value["quote"]["reference"].string ?? "")")
                Text("Issued \(value["quote"]["issuedAt"].string ?? "") · Expires \(value["quote"]["validUntil"].string ?? "Unknown")")
                Text(value["quote"]["source"].string ?? "")
                Text(value["quote"]["conditions"].string ?? "")
            }
        }
    }
    private func load() {
        guard !loaded else { return }; loaded = true
        do {
            saved = try document.project.catalogMaterialMapping(itemID: itemID)
            if let saved { comparison = try CatalogSnapshotComparison.compare(saved: saved.catalog, available: choices) }
            history = try document.project.catalogMaterialHistory().filter { $0.itemID == itemID }
            fingerprint = try document.project.catalogMaterialEditFingerprint(itemID: itemID)
            snapshots = saved.map { [$0.catalog] } ?? []
            let counts = Dictionary(grouping: choices, by: { [$0.source, $0.id.uuidString] }).mapValues(\.count)
            for candidate in choices where counts[[candidate.source, candidate.id.uuidString]] == 1 && !snapshots.contains(candidate) { try candidate.validate(); snapshots.append(candidate) }
            if let saved {
                form.selection = 0; form.purchaseUnit = saved.purchaseUnit; form.factor = String(saved.catalogUnitsPerTakeoffUnit)
                form.basis = saved.basis
                if let quote = saved.quote {
                    form.recordsQuote = true; form.quoteSupplier = quote.supplier; form.quoteReference = quote.reference
                    form.quoteSource = quote.source; form.quoteIssuedAt = quote.issuedAt
                    form.quoteValidUntil = quote.validUntil ?? ""; form.quoteConditions = quote.conditions
                }
            }
            baseline = form
        } catch { failure = error.localizedDescription }
    }
    private func save(removing: Bool) {
        do {
            var mapping: CatalogMaterialMapping?
            if !removing {
                guard let selected, form.confirmsUSD, let factor = Double(form.factor.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw LoadSightError.invalid("Select a material, confirm USD and enter a unit conversion.") }
                mapping = try .init(catalog: selected, currency: "USD", purchaseUnit: form.purchaseUnit, catalogUnitsPerTakeoffUnit: factor, takeoffUnit: row["unit"]?.string ?? "", itemDescription: row["description"]?.string ?? "", lifecycle: row["lifecycle"]?.string ?? "", basis: form.basis, quote: form.quoteEvidence())
            }
            try document.project.updateCatalogMaterialMapping(itemID: itemID, mapping: mapping, expectedFingerprint: fingerprint, author: form.author, reason: form.reason)
            dismiss()
        } catch { failure = error.localizedDescription }
    }
}
