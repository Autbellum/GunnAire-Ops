import SwiftUI
import Combine

/// A single focused invoice task. No protocol IDs, raw JSON or owner records in the form.
struct StaffInvoiceEditorView: View {
    @ObservedObject var editor: StaffInvoiceEditorController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var discarding = false
    @State private var closing = false
    @State private var reloading = false
    @State private var reviewing = false
    @State private var reviewSource: StaffInvoiceSource?
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(editor.message).font(.callout).foregroundStyle(.secondary)
                    if editor.isRunning { ProgressView("Sending saved request…") }
                }
                if let draft = editor.draft, let source = editor.source {
                    Section("Add a line") {
                        Picker("Item source", selection: binding(\.mode)) {
                            Text("Catalog").tag("catalog"); Text("New item").tag("new")
                        }.pickerStyle(.segmented)
                        if draft.mode == "catalog" {
                            NavigationLink {
                                StaffInvoiceCatalogPicker(editor: editor)
                            } label: { LabeledContent("Item", value: draft.catalog?.name ?? "Choose a part or service") }
                            if let line = draft.catalog {
                                if line.itemType == "Group" { Text("Office review will price the package contents.").font(.footnote) }
                                else { LabeledContent("Catalog unit price", value: QuickBooksSalesLineContract.unitPriceLabel(line.unitPrice)) }
                            }
                        } else {
                            TextField("Item name", text: binding(\.name)).accessibilityIdentifier("StaffInvoiceItemName")
                            Picker("Type", selection: binding(\.itemType)) {
                                Text("Service / labor").tag("Service"); Text("Non-inventory part").tag("NonInventory")
                            }
                            TextField("Unit price (USD), e.g. 125.00", text: binding(\.price)).keyboardType(.decimalPad)
                                .accessibilityIdentifier("StaffInvoiceUnitPrice")
                            Toggle("Taxable", isOn: Binding(get: { editor.draft?.isTaxable ?? false }, set: { value in editor.change { $0.isTaxable = value } }))
                            DisclosureGroup("Description and SKU") {
                                TextField("Description", text: binding(\.detail), axis: .vertical).lineLimit(2...6)
                                TextField("SKU (optional)", text: binding(\.sku)).autocorrectionDisabled()
                            }
                        }
                        TextField("Quantity", text: binding(\.quantity)).keyboardType(.decimalPad)
                            .accessibilityIdentifier("StaffInvoiceQuantity")
                        if !source.equipment.isEmpty {
                            Picker("Serviced system", selection: Binding(get: { editor.draft?.equipmentID ?? "" }, set: { value in
                                editor.change { $0.equipmentID = value.isEmpty ? nil : value }
                            })) {
                                Text("Not specified").tag("")
                                ForEach(source.equipment) { Text($0.name).tag($0.id) }
                            }
                        }
                        TextField("Work performed / reason for this line", text: binding(\.reason), axis: .vertical)
                            .lineLimit(2...6).accessibilityIdentifier("StaffInvoiceReason")
                    }.disabled(!editor.available || editor.isRunning)
                    Section {
                        Text(editor.draftMessage).font(.footnote).foregroundStyle(.secondary)
                        if editor.hasUnprotectedChanges {
                            Button("Retry Draft Save") { editor.persist() }
                            Button("Reload Saved Draft") { reloading = true }
                        }
                        if editor.needsReview {
                            Text("The shared invoice changed. Your original input was kept.").font(.callout)
                            Button("Review Current Invoice") { reviewSource = editor.source; reviewing = true }
                        }
                        if source.editable {
                            Button("Submit for Office Review") { Task { await editor.submit() } }
                                .disabled(!editor.canStage).accessibilityIdentifier("StaffInvoiceSubmit")
                            if !editor.canStage && !editor.needsReview && !editor.hasUnprotectedChanges {
                                Text("Choose an item or enter its name and price, a positive quantity, and a work description. Use a decimal point for numbers.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        } else { Text("This invoice is finalized or paid. Ask the office to review a correction.") }
                        Button("Discard Unsubmitted Draft", role: .destructive) { discarding = true }
                    }.disabled(!editor.available || editor.isRunning)
                }
                if !editor.entries.isEmpty {
                    Section("Saved requests") {
                        ForEach(editor.entries.reversed()) { entry in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(entry.request.line.name).font(.headline)
                                Text("Quantity \(entry.request.line.quantity.formatted(.number.precision(.fractionLength(0...5))))")
                                Text(entry.receipt == nil ? "Saved on device · office receipt not confirmed" : "Received for office review · not applied to invoice")
                                    .font(.caption).foregroundStyle(.secondary)
                                if entry.receipt == nil {
                                    Button("Retry Saved Request") { Task { await editor.retry(id: entry.id) } }
                                        .disabled(!editor.available || editor.isRunning)
                                }
                            }
                        }
                    }
                }
                if editor.draft == nil, editor.source?.editable == true {
                    Button("Add Another Line") { editor.begin() }
                        .disabled(!editor.available || editor.isRunning || editor.entries.count >= 128)
                }
                Section {
                    Text("Office review is required for pricing, packages, tax, customer approval and QuickBooks. A received request is not an invoice change or a payment.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Invoice items")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(editor.draft == nil ? "Close" : "Keep Draft and Close") {
                        if editor.hasUnprotectedChanges { closing = true } else { dismiss() }
                    }
                }
            }
        }
        .interactiveDismissDisabled(editor.hasUnprotectedChanges)
        .alert("Discard this unfinished draft?", isPresented: $discarding) {
            Button("Discard Draft", role: .destructive) { _ = editor.discardDraft() }
            Button("Keep Editing", role: .cancel) {}
        } message: { Text("Already queued and received requests are kept unchanged.") }
        .alert("Latest input is not saved", isPresented: $closing) {
            Button("Keep Editing", role: .cancel) {}
            Button("Close Without Latest Input", role: .destructive) { dismiss() }
        } message: { Text("Previously verified drafts and requests remain on this device. Retry saving before closing to keep your latest changes.") }
        .alert("Reload the last saved draft?", isPresented: $reloading) {
            Button("Reload", role: .destructive) { editor.reloadSaved() }
            Button("Keep Editing", role: .cancel) {}
        } message: { Text("This replaces only the input displayed here with the saved version. Copy any unsaved text you want to keep first.") }
        .alert("Use the current invoice?", isPresented: $reviewing) {
            Button("Use Current Invoice") { if let reviewSource { editor.useCurrentInvoice(reviewed: reviewSource) } }
            Button("Keep Original Draft", role: .cancel) {}
        } message: { Text("Your typed details are kept. Any selected catalog item is cleared so you can choose its current price explicitly. This does not submit anything.") }
        .task { editor.open() }
        .onReceive(timer) { _ in if scenePhase == .active { editor.checkLifetime() } }
        .onChange(of: CloudKitStaffSetupStamp.current) { _, _ in editor.checkLifetime() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { editor.checkLifetime() } else { editor.persist() } }
        .onDisappear { editor.persist(); editor.invalidate() }
        .accessibilityIdentifier("StaffInvoiceEditor")
    }
    private func binding(_ key: WritableKeyPath<StaffInvoiceDraft, String>) -> Binding<String> {
        Binding(get: { editor.draft?[keyPath: key] ?? "" }, set: { value in editor.change { $0[keyPath: key] = value } })
    }
}

private struct StaffInvoiceCatalogPicker: View {
    @ObservedObject var editor: StaffInvoiceEditorController
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    private var choices: [StaffInvoiceLine] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return (editor.source?.catalog ?? []).filter { needle.isEmpty || $0.name.localizedCaseInsensitiveContains(needle) || ($0.sku?.localizedCaseInsensitiveContains(needle) ?? false) }
    }
    var body: some View {
        List {
            if choices.isEmpty { Text("No matching approved catalog items. Return to create a new item request.").foregroundStyle(.secondary) }
            ForEach(choices, id: \.itemID) { line in
                Button {
                    if editor.selectCatalog(line) { dismiss() }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(line.name)
                        Text(line.itemType == "Group" ? "Package · office pricing required" : QuickBooksSalesLineContract.unitPriceLabel(line.unitPrice))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.disabled(!editor.available || editor.isRunning)
            }
        }
        .navigationTitle("Choose item")
        .searchable(text: $search, prompt: "Part, service or SKU")
    }
}
