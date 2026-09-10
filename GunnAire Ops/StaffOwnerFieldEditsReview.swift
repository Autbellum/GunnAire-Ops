import SwiftUI

/// Secondary owner workflow: business context and two values, never a record dump.
struct StaffOwnerFieldEditsReview: View {
    @ObservedObject var edits: StaffOwnerFieldEditCoordinator
    @ObservedObject var source: StaffReplicaSourceCoordinator
    @State private var selected: StaffOwnerFieldEditReview?
    @State private var keepingOffice: StaffOwnerFieldEditReview?
    var body: some View {
        Section("Field updates") {
            Text(edits.message).foregroundStyle(.secondary)
            ForEach(edits.reviews) { review in
                VStack(alignment: .leading, spacing: 8) {
                    Text(review.title).font(.headline)
                    Text(StaffWorkspacePublicationReview.label(review.edit.request.fieldName)).font(.subheadline)
                    Text(review.message).font(.footnote).foregroundStyle(.secondary)
                    DisclosureGroup("Compare values") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Office: " + StaffWorkspacePublicationReview.value(review.officeValue, field: review.edit.request.fieldName))
                            Text("Field update: " + StaffWorkspacePublicationReview.value(review.edit.request.value, field: review.edit.request.fieldName))
                        }.textSelection(.enabled)
                    }
                    if review.canApplyReviewed {
                        Button("Apply Field Update") { selected = review }
                            .disabled(source.isRunning)
                    }
                    if review.canKeepOffice {
                        Button("Keep Office Value") { keepingOffice = review }
                            .disabled(source.isRunning)
                    }
                }.padding(.vertical, 4)
            }
        }
        .alert("Replace the reviewed office value?", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            if let selected {
                Button("Apply Field Update") {
                    let review = selected; self.selected = nil
                    Task { await source.applyFieldReview(review) }
                }
            }
            Button("Cancel", role: .cancel) { selected = nil }
        } message: {
            Text("Only this field will change. Any newer office edit requires review again. The original technician update stays in the audit history.")
        }
        .alert("Keep the reviewed office value?", isPresented: Binding(get: { keepingOffice != nil }, set: { if !$0 { keepingOffice = nil } })) {
            if let keepingOffice {
                Button("Keep Office Value") {
                    let review = keepingOffice; self.keepingOffice = nil
                    Task { await source.keepOfficeFieldReview(review) }
                }
            }
            Button("Cancel", role: .cancel) { keepingOffice = nil }
        } message: {
            Text("The office record will not change. This field update will stop retrying, and its original author, value, and receipt will stay in the audit history.")
        }
    }
}
