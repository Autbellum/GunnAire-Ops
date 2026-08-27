import SwiftUI

struct EstimateApprovalEvidence {
    let customerName: String
    let method: EstimateApprovalMethod
    let reference: String?
    let signatureImageBase64: String?
}

struct EstimateApprovalSheet: View {
    @Environment(\.dismiss) private var dismiss

    let estimate: Estimate
    let onApprove: (EstimateApprovalEvidence) -> Bool

    @State private var customerName: String
    @State private var method: EstimateApprovalMethod = .inPersonSignature
    @State private var reference = ""
    @State private var signatureStrokes: [[CGPoint]] = []
    @State private var confirmedReview = false
    @State private var validationMessage: String?

    init(estimate: Estimate, onApprove: @escaping (EstimateApprovalEvidence) -> Bool) {
        self.estimate = estimate
        self.onApprove = onApprove
        _customerName = State(initialValue: estimate.customer.name)
    }

    private var trimmedName: String {
        customerName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedReference: String {
        reference.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasSignature: Bool {
        signatureStrokes.contains { !$0.isEmpty }
    }

    private var canApprove: Bool {
        guard !trimmedName.isEmpty, confirmedReview else { return false }
        return method.requiresSignature ? hasSignature : !trimmedReference.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(estimate.proposalLabel) {
                    LabeledContent("Customer", value: estimate.customer.name)
                    LabeledContent("Total", value: estimate.amount.formatted(.currency(code: "USD")))
                    if estimate.isChangeOrder {
                        Text("This approval applies only to this revised change order. The original approval stays on the original estimate.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section("Approval Method") {
                    Picker("Method", selection: $method) {
                        ForEach(EstimateApprovalMethod.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .accessibilityIdentifier("EstimateApprovalMethodPicker")
                    TextField("Customer name", text: $customerName)
                        .textContentType(.name)
                }

                if method.requiresSignature {
                    Section("Customer Signature") {
                        SignaturePad(strokes: $signatureStrokes)
                            .frame(height: 180)
                            .accessibilityLabel("Customer signature pad")
                        HStack {
                            Text(hasSignature ? "Signature captured." : "Ask the customer to sign above.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Clear") {
                                signatureStrokes = []
                            }
                            .disabled(!hasSignature)
                        }
                    }
                } else {
                    Section("Authorization Reference") {
                        TextField(method.referencePrompt, text: $reference, axis: .vertical)
                            .lineLimit(2...4)
                        Text("Record enough detail for office staff to locate or verify the customer's authorization.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section("Confirmation") {
                    Toggle("Customer reviewed the scope, total price, and terms", isOn: $confirmedReview)
                    Text("Approval is locked to this estimate revision. Create a change order for later scope or price changes.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let validationMessage {
                    Section {
                        Text(validationMessage)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Customer Approval")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Approve") { saveApproval() }
                        .disabled(!canApprove)
                }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(hasSignature || confirmedReview || !trimmedReference.isEmpty)
    }

    private func saveApproval() {
        let signature = method.requiresSignature
            ? SignatureRenderer.image(from: signatureStrokes)?.pngData()?.base64EncodedString()
            : nil
        let evidence = EstimateApprovalEvidence(
            customerName: trimmedName,
            method: method,
            reference: method.requiresSignature ? nil : trimmedReference,
            signatureImageBase64: signature
        )
        guard onApprove(evidence) else {
            validationMessage = "Approval evidence could not be saved. Check the name and authorization details, then try again."
            return
        }
        dismiss()
    }
}
