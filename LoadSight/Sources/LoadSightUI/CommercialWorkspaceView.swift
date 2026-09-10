import SwiftUI
import LoadSightKit

struct CommercialWorkspaceView: View {
    @Binding var document: LoadSightDocument
    @State private var editing = false
    @State private var editingProposal = false
    @State private var exporting = false
    @State private var pdf: PDFExportDocument?
    @State private var exportError: String?
    private var reviewResult: Result<BidReview, Error> { Result { try EstimatePricing.review(document.project) } }
    var body: some View {
        List {
            Section("Estimate assumptions") {
                LabeledContent("Customer", value: document.project.root["inputs"]["customer"].string ?? "Not entered")
                LabeledContent("Responsible estimator", value: document.project.root["reviewer"].string ?? "Not entered")
                ForEach(ProjectDocument.commercialNumericKeys, id: \.self) { key in
                    LabeledContent(commercialLabel(key), value: document.project.root["inputs"][key].number.map { String($0) } ?? "Unknown")
                }
                Text(document.project.root["inputs"]["proposalTerms"].string ?? "Commercial terms not entered")
            }
            if case .success(let review) = reviewResult {
                Section("Cost review") {
                    LabeledContent("Known direct cost", value: review.knownDirectCost.formatted(.currency(code: "USD")))
                    Text("Includes only fully costed rows: \(review.pricedCount) of \(review.includedCount). Unknown rows are not valued at zero.").font(.caption)
                    if let cost = review.estimatedCost { LabeledContent("Estimated cost before markup", value: cost.formatted(.currency(code: "USD"))) }
                    if let price = review.releasableSellingPrice { LabeledContent("Reviewed selling price", value: price.formatted(.currency(code: "USD"))) }
                    else { Text("Selling price withheld while review issues remain.").foregroundStyle(.orange) }
                    ForEach(review.blockers, id: \.self) { Text($0).font(.callout) }
                }
            } else if case .failure(let error) = reviewResult {
                Section("Cost review unavailable") { Text(error.localizedDescription).foregroundStyle(.red) }
            }
            let events = Array((document.project.root["commercialHistory"].array ?? []).reversed())
            if !events.isEmpty {
                Section("Assumption history") {
                    ForEach(events, id: \.commercialEventID) { event in
                        DisclosureGroup("\(event["author"].string ?? "") · \(event["at"].string ?? "")") {
                            Text(event["basis"].string ?? "")
                            ForEach(ProjectDocument.commercialNumericKeys, id: \.self) { key in
                                Text("\(commercialLabel(key)): \(event["before"]["inputs"][key].number.map { String($0) } ?? "Unknown") → \(event["after"]["inputs"][key].number.map { String($0) } ?? "Unknown")")
                            }
                            Text("Customer: \(event["after"]["inputs"]["customer"].string ?? "")")
                            Text("Terms: \(event["after"]["inputs"]["proposalTerms"].string ?? "")")
                        }
                    }
                }
            }
        }
        .toolbar {
            Button("Edit assumptions") { editing = true }
            Button("Proposal details") { editingProposal = true }
            Button("Export draft PDF") {
                do { try document.validateMarkup(); pdf = PDFExportDocument(data: try DraftProposal.pdf(document.project)); exporting = true }
                catch { exportError = error.localizedDescription }
            }
        }
        .fileExporter(isPresented: $exporting, document: pdf, contentType: .pdf, defaultFilename: "LoadSight-Draft-Proposal") { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .alert("PDF export failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) { Button("OK") { exportError = nil } } message: { Text(exportError ?? "") }
        .sheet(isPresented: $editing) { CommercialEditor(document: $document) }
        .sheet(isPresented: $editingProposal) { ProposalEditor(document: $document) }
    }
}
private extension JSONValue { var commercialEventID: String { self["id"].string ?? "" } }
private func commercialLabel(_ key: String) -> String {
    ["laborRate": "Loaded labor rate ($/hour)", "markupPct": "Markup on cost (%)", "taxAllowance": "Tax allowance ($)", "jobCosts": "Other job costs ($)", "contingency": "Contingency ($)"][key] ?? key
}
private struct CommercialEditor: View {
    @Binding var document: LoadSightDocument
    @Environment(\.dismiss) private var dismiss
    @State private var fields: [String: String] = [:]
    @State private var name = ""
    @State private var estimator = ""
    @State private var author = ""
    @State private var basis = ""
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Project and proposal") {
                    TextField("Project name", text: $name)
                    TextField("Customer", text: binding("customer"))
                    TextField("Responsible estimator", text: $estimator)
                    TextField("Proposal terms, exclusions and validity", text: binding("proposalTerms"), axis: .vertical)
                }
                Section("Commercial assumptions") {
                    ForEach(ProjectDocument.commercialNumericKeys, id: \.self) { key in TextField(commercialLabel(key), text: binding(key)) }
                    Text("Blank means unknown. Enter zero only when deliberately confirmed. Markup applies to total cost, including the entered dollar allowances; it is not gross margin. These are entered allowances, not automatic tax calculations.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Evidence") {
                    TextField("Source / reason for changes", text: $basis, axis: .vertical)
                    TextField("Recorded by", text: $author)
                    Text("Changes are recorded and reopen QA. Saving assumptions does not approve an estimate.").font(.caption).foregroundStyle(.secondary)
                    if let failure { Text(failure).foregroundStyle(.red) }
                }
            }.formStyle(.grouped)
            .navigationTitle("Estimate assumptions")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
            .onAppear {
                name = document.project.name; estimator = document.project.root["reviewer"].string ?? ""
                for key in ProjectDocument.commercialNumericKeys + ["customer", "proposalTerms"] {
                    let value = document.project.root["inputs"][key]
                    fields[key] = value.string ?? value.number.map { String($0) } ?? ""
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 650)
        #endif
    }
    private func binding(_ key: String) -> Binding<String> { .init(get: { fields[key] ?? "" }, set: { fields[key] = $0 }) }
    private func save() {
        do {
            var values: [String: JSONValue] = [:]
            for key in ProjectDocument.commercialNumericKeys {
                let input = (fields[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if input.isEmpty { values[key] = .null }
                else {
                    guard let value = Double(input), value.isFinite, value >= 0 else { throw LoadSightError.invalid("\(commercialLabel(key)) must be a nonnegative number or blank.") }
                    values[key] = .number(value)
                }
            }
            for key in ["customer", "proposalTerms"] { values[key] = .string(fields[key] ?? "") }
            try document.project.updateCommercialInputs(name: name, estimator: estimator, fields: values, basis: basis, author: author)
            dismiss()
        } catch { failure = error.localizedDescription }
    }
}
