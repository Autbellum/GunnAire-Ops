import SwiftUI
import LoadSightKit

struct ItemReviewEditor: View {
    @Binding var document: LoadSightDocument
    let id: String
    @Environment(\.dismiss) private var dismiss
    @State private var scope = "Hold"
    @State private var status = QuantityReviewStatus.required
    @State private var allowance = ""
    @State private var reviewer = ""
    @State private var evidence = ""
    @State private var failure: String?
    private var item: [String: JSONValue] { document.project.items.first { $0["id"]?.string == id } ?? [:] }
    var body: some View {
        NavigationStack {
            Form {
                Section("Recorded quantity") {
                    Text(item["description"]?.string ?? id).font(.headline)
                    Text("\(item["quantity"]?.number.map { String($0) } ?? "Unknown") \(item["unit"]?.string ?? "")")
                    Text(item["source"]?.string ?? "Source missing").font(.caption)
                    Text(item["basis"]?.string ?? "").font(.caption)
                    if !document.project.isItemReviewCurrent(item) { Text("Earlier quantity review is stale.").foregroundStyle(.orange) }
                }
                Section("Scope and review") {
                    Picker("Scope", selection: $scope) { ForEach(["Base", "Allowance", "Hold", "Excluded"], id: \.self) { Text($0) } }
                    Picker("Quantity status", selection: $status) { ForEach(QuantityReviewStatus.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    TextField("Written allowance basis", text: $allowance, axis: .vertical)
                    TextField("Reviewer", text: $reviewer)
                    TextField("Scope decision / quantity evidence", text: $evidence, axis: .vertical)
                    Text("Review status does not change the quantity or resolve RFIs. Drawing measurements, counts, field verification and procurement checks remain distinct. Saving reopens QA.").font(.caption).foregroundStyle(.secondary)
                    if let failure { Text(failure).foregroundStyle(.red) }
                }
                let history = (document.project.root["itemReviewHistory"].array ?? []).filter { $0["itemID"].string == id }
                if !history.isEmpty {
                    Section("Review history") {
                        ForEach(Array(history.reversed()), id: \.itemReviewIdentity) { event in
                            VStack(alignment: .leading) {
                                Text("\(event["reviewer"].string ?? "") · \(event["at"].string ?? "")").font(.caption)
                                Text("\(event["after"]["scope"].string ?? "") · \(event["after"]["quantityStatus"].string ?? "")")
                                Text(event["evidence"].string ?? "")
                            }
                        }
                    }
                }
            }.formStyle(.grouped)
            .navigationTitle("Review \(id)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save review") {
                    do { try document.project.reviewItem(id: id, scope: scope, status: status, allowanceNote: allowance, reviewer: reviewer, evidence: evidence); dismiss() }
                    catch { failure = error.localizedDescription }
                } }
            }
            .onAppear { scope = item["scope"]?.string ?? "Hold"; status = QuantityReviewStatus(rawValue: item["quantityStatus"]?.string ?? "") ?? .required; allowance = item["allowanceNote"]?.string ?? "" }
        }
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 650)
        #endif
    }
}
private extension JSONValue { var itemReviewIdentity: String { self["id"].string ?? "" } }
