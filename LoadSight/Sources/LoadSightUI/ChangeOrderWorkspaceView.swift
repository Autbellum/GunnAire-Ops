import SwiftUI
import LoadSightKit

struct ChangeOrderWorkspaceView: View {
    @Binding var document: LoadSightDocument
    @State private var creating = false
    @State private var selected: ChangeOrderRecord?
    @State private var revising: ChangeRevisionSelection?
    @State private var word = WordExportDocument(data: Data())
    @State private var exportingWord = false
    @State private var exportError: String?
    var body: some View {
        List {
            Text("Draft changes record proposed scope and cost impact. They do not authorize work or alter the base estimate.").font(.callout).foregroundStyle(.secondary)
            if let records = try? document.project.changeOrders() {
                if records.isEmpty { Text("No change orders yet. Create a draft to compare the original and proposed mechanical work.") }
                ForEach(records) { record in
                    Button { selected = record } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(record.draft.number).font(.headline)
                            Text(record.draft.proposedScope).lineLimit(3)
                            Text("Draft · \(record.author)").font(.caption)
                            if let review = try? record.draft.review() { Text("Cost delta: " + changeMoney(review.totalDelta)).font(.subheadline.bold()) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                    Button("Revise draft") {
                        do { revising = .init(record: record, fingerprint: try document.project.changeOrderEditFingerprint(id: record.id)) }
                        catch { exportError = error.localizedDescription }
                    }.accessibilityLabel("Revise draft " + record.draft.number)
                    Button("Export Word copy") {
                        do { word = WordExportDocument(data: try ChangeOrderWordDocument.docx(document.project, changeOrderID: record.id)); exportingWord = true }
                        catch { exportError = error.localizedDescription }
                    }.accessibilityLabel("Export Word copy of " + record.draft.number)
                }
            } else { Text("Unable to read change-order records.").foregroundStyle(.red) }
        }
        .toolbar { Button { creating = true } label: { Label("New change order", systemImage: "plus") } }
        .sheet(isPresented: $creating) { ChangeOrderEditor(document: $document) }
        .sheet(item: $selected) { record in ChangeOrderDetail(record: record, history: (try? document.project.changeOrderHistory().filter { $0.changeOrderID == record.id }) ?? []) }
        .sheet(item: $revising) { selection in ChangeOrderEditor(document: $document, record: selection.record, fingerprint: selection.fingerprint) }
        .fileExporter(isPresented: $exportingWord, document: word, contentType: WordExportDocument.contentType, defaultFilename: "LoadSight-Change-Order") { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .alert("Unable to export change order", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") { exportError = nil }
        } message: { Text(exportError ?? "") }
    }
}
private func changeMoney(_ value: Double?) -> String { value.map { $0.formatted(.currency(code: "USD")) } ?? "Unknown — total withheld" }

private struct ChangeRevisionSelection: Identifiable {
    var id: String { record.id }
    let record: ChangeOrderRecord
    let fingerprint: String
}
private struct ChangeOrderEditor: View {
    @Binding var document: LoadSightDocument
    @Environment(\.dismiss) private var dismiss
    @State private var state = ChangeOrderFormState()
    @State private var error: String?
    @State private var discarding = false
    @State private var reason = ""
    private let initialState: ChangeOrderFormState
    private let recordID: String?
    private let fingerprint: String?
    init(document: Binding<LoadSightDocument>, record: ChangeOrderRecord? = nil, fingerprint: String? = nil) {
        _document = document
        let initial = record.map { ChangeOrderFormState(draft: $0.draft) } ?? ChangeOrderFormState()
        initialState = initial; _state = State(initialValue: initial); recordID = record?.id; self.fingerprint = fingerprint
    }
    private var dirty: Bool { state != initialState || !reason.isEmpty }
    var body: some View {
        NavigationStack {
            Form {
                Section("Change basis") {
                    text("CO number", $state.draft.number)
                    text("Date YYYY-MM-DD", $state.draft.date)
                    text("Customer / GC", $state.draft.customer)
                    text("Recorded author", $state.author)
                    if recordID != nil { text("Revision reason", $reason) }
                    Picker("Entitlement classification", selection: $state.draft.entitlement) {
                        Text("Unknown").tag(Optional<ChangeEntitlement>.none)
                        ForEach(ChangeEntitlement.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                    }
                    text("Entitlement basis and source", $state.draft.entitlementBasis)
                    text("Original contract scope", $state.draft.originalScope)
                    text("Proposed revised scope", $state.draft.proposedScope)
                    text("Drawing / specification revision", $state.draft.drawingRevision)
                    text("Originating audit reference", $state.draft.auditReference)
                }
                Section("Originating RFIs") {
                    ForEach(document.project.root["rfis"].array ?? [], id: \.changeRFIIdentity) { row in
                        let id = row["id"].string!
                        Toggle(row["title"].string ?? id, isOn: Binding(get: { state.draft.rfiIDs.contains(id) }, set: { enabled in
                            state.draft.rfiIDs.removeAll { $0 == id }; if enabled { state.draft.rfiIDs.append(id) }
                        }))
                    }
                    let currentIDs = Set(document.project.root["rfis"].array?.compactMap { $0["id"].string } ?? [])
                    ForEach(state.draft.rfiIDs.filter { !currentIDs.contains($0) }, id: \.self) { id in
                        Text(id + " · Historical RFI no longer present").font(.caption)
                        Button("Remove historical link " + id) { state.draft.rfiIDs.removeAll { $0 == id } }
                    }
                    if document.project.root["rfis"].array?.isEmpty != false { Text("No saved RFIs. Record any originating audit reference above.").foregroundStyle(.secondary) }
                }
                Section("Original and proposed quantities") {
                    Text("Leave unknown values blank. Quantity deltas are separate from quoted cost deltas.").font(.caption)
                    ForEach($state.quantities) { $quantity in
                        VStack(alignment: .leading, spacing: 10) {
                            text("Quantity description", $quantity.name); text("Quantity unit", $quantity.unit)
                            text("Original quantity", $quantity.original); text("Original quantity source", $quantity.originalSource)
                            text("Proposed quantity", $quantity.proposed); text("Proposed quantity source", $quantity.proposedSource)
                            Button("Remove quantity", role: .destructive) { state.quantities.removeAll { $0.id == quantity.id } }
                        }.padding(.vertical, 6)
                    }
                    Button("Add quantity") { state.quantities.append(.init()) }
                }
                Section("Quoted cost deltas in USD") {
                    Text("Positive values add cost; negative values credit cost. Zero means a sourced zero cost. Blank means unknown. Use numbers without currency symbols or grouping commas.").font(.caption)
                    ForEach(ChangeCostCategory.allCases, id: \.self) { category in amount(category.rawValue, label: category.rawValue.capitalized + " delta USD") }
                }
                Section("Markup tax and bond") {
                    amount("Markup percentage", label: "Markup percentage")
                    Picker("Markup basis", selection: $state.draft.markupBasis) {
                        Text("Unknown").tag(Optional<ChangeMarkupBasis>.none)
                        Text("Signed net costs").tag(Optional(ChangeMarkupBasis.signedNetCosts))
                        Text("Positive category deltas only").tag(Optional(ChangeMarkupBasis.positiveAdditionsOnly))
                    }
                    Text("Signed net costs applies markup to credits too. Positive category deltas excludes negative categories from the markup basis.").font(.caption)
                    amount("Tax delta", label: "Tax delta USD"); amount("Bond delta", label: "Bond delta USD")
                }
                Section("Schedule and terms") {
                    text("Time impact", $state.draft.timeImpact); text("Exclusions", $state.draft.exclusions)
                    text("Required approval language", $state.draft.approvalLanguage)
                }
                Section("Draft review") {
                    switch Result(catching: { try state.resolvedDraft().review() }) {
                    case .success(let review): ChangeReviewRows(review: review)
                    case .failure(let problem): Text(problem.localizedDescription).foregroundStyle(.secondary)
                    }
                    Text("Saving records a draft and reopens QA. Missing fields remain unknown. Each revision retains the earlier record. Recorded authorship is not authenticated approval.").font(.caption)
                }
            }
            .navigationTitle(recordID == nil ? "New change order" : "Revise change order")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if dirty { discarding = true } else { dismiss() } } }
                ToolbarItem(placement: .confirmationAction) { Button("Save draft") {
                    do {
                        let draft = try state.resolvedDraft()
                        if let recordID, let fingerprint { try document.project.reviseChangeOrder(id: recordID, expectedFingerprint: fingerprint, draft: draft, author: state.author, reason: reason) }
                        else { try document.project.createChangeOrder(draft, author: state.author) }
                        dismiss()
                    }
                    catch { self.error = error.localizedDescription }
                } }
            }
            .interactiveDismissDisabled(dirty)
            .alert("Discard this unsaved change order?", isPresented: $discarding) {
                Button("Discard draft", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
            .alert("Unable to save change order", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
    }
    private func text(_ label: String, _ binding: Binding<String>) -> some View {
        TextField(label, text: binding, axis: .vertical).accessibilityLabel(label)
    }
    private func amount(_ key: String, label: String) -> some View {
        VStack(alignment: .leading) {
            text(label, Binding(get: { state.values[key] ?? "" }, set: { state.values[key] = $0 }))
            text(label + " source", Binding(get: { state.sources[key] ?? "" }, set: { state.sources[key] = $0 }))
        }
    }
}
private struct ChangeReviewRows: View {
    let review: ChangeOrderReview
    var body: some View {
        LabeledContent("Known cost entries", value: changeMoney(review.knownCostDelta))
        LabeledContent("Complete cost delta", value: changeMoney(review.costDelta))
        LabeledContent("Markup delta", value: changeMoney(review.markupDelta))
        LabeledContent("Draft total delta", value: changeMoney(review.totalDelta))
        if !review.unknownFields.isEmpty {
            Text("Still unknown: " + review.unknownFields.joined(separator: "; ")).foregroundStyle(.secondary)
        }
        Text(review.limitations).font(.caption).foregroundStyle(.secondary)
    }
}
private extension JSONValue { var changeRFIIdentity: String { self["id"].string ?? "" } }

private struct ChangeOrderDetail: View {
    let record: ChangeOrderRecord
    var history: [ChangeOrderRevision] = []
    @State private var snapshot: ChangeOrderRecord?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                if !history.isEmpty {
                    Section("Revision history") {
                        Text("Creation details remain attached to the original author. Revisions below identify who recorded each correction.").font(.caption)
                        ForEach(Array(history.enumerated()), id: \.element.id) { index, revision in
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Revision \(index + 1) · " + revision.author).font(.headline)
                                Text(revision.recordedAt).font(.caption); Text(revision.reason)
                                Button("Before revision \(index + 1)") { snapshot = try? revision.record(before: true) }.buttonStyle(.borderless)
                                Button("After revision \(index + 1)") { snapshot = try? revision.record(before: false) }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
                Section("Draft record") {
                    detail("Project", record.project); detail("Customer / GC", record.draft.customer)
                    detail("Date", record.draft.date); detail("Recorded author", record.author); detail("Created", record.createdAt)
                    detail("Entitlement classification", record.draft.entitlement?.rawValue ?? "")
                    detail("Entitlement basis", record.draft.entitlementBasis)
                    detail("Original scope", record.draft.originalScope); detail("Proposed scope", record.draft.proposedScope)
                    detail("Drawing / specification revision", record.draft.drawingRevision)
                    detail("RFI identities", record.draft.rfiIDs.joined(separator: ", ")); detail("Audit reference", record.draft.auditReference)
                }
                Section("Quantity ledger") {
                    if record.draft.quantities.isEmpty { Text("Unknown — no quantity ledger recorded") }
                    ForEach(Array(record.draft.quantities.enumerated()), id: \.offset) { _, q in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(q.name + " · " + q.unit).font(.headline)
                            scalar("Original", q.original); scalar("Proposed", q.proposed)
                            detail("Delta", q.delta.map { $0.formatted() } ?? "")
                        }
                    }
                }
                Section("Quoted cost deltas in USD") {
                    ForEach(record.draft.costs, id: \.category) { scalar($0.category.rawValue.capitalized, $0.delta) }
                    scalar("Markup percentage", record.draft.markupPercent)
                    detail("Markup basis", record.draft.markupBasis.map { $0 == .signedNetCosts ? "Signed net costs" : "Positive category deltas only" } ?? "")
                    scalar("Tax delta", record.draft.tax); scalar("Bond delta", record.draft.bond)
                }
                Section("Schedule and terms") {
                    detail("Time impact", record.draft.timeImpact); detail("Exclusions", record.draft.exclusions); detail("Required approval language", record.draft.approvalLanguage)
                }
                if let review = try? record.draft.review() { Section("Draft review") { ChangeReviewRows(review: review) } }
            }
            .sheet(item: $snapshot) { ChangeOrderDetail(record: $0) }
            .navigationTitle(record.draft.number)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
    private func detail(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(label).font(.caption).foregroundStyle(.secondary); Text(value.isEmpty ? "Unknown" : value).textSelection(.enabled) }
    }
    private func scalar(_ label: String, _ value: ChangeAmount) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            detail(label, value.amount.map { $0.formatted() } ?? "")
            detail(label + " source", value.source)
        }
    }
}
