import SwiftUI

struct NewPaymentView: View {
    @Environment(\.dismiss) private var dismiss
    var dismissHandler: (() -> Void)?
    var onAdd: ((QBStubPaymentCreate) -> Void)?

    @State private var customerName: String = ""
    @State private var paymentAmount: String = ""
    @State private var paymentMethod: String = ""
    @State private var notes: String = ""

    init(dismiss: @escaping () -> Void, onAdd: ((QBStubPaymentCreate) -> Void)? = nil) {
        self.dismissHandler = dismiss
        self.onAdd = onAdd
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Payment Details") {
                    TextField("Customer Name", text: $customerName)
                    TextField("Amount", text: $paymentAmount)
                        .keyboardType(.decimalPad)
                    TextField("Payment Method", text: $paymentMethod)
                    TextField("Notes", text: $notes)
                }
            }
            .navigationTitle("New Payment")
            .foregroundColor(Color.brandGold)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                        dismissHandler?()
                    }
                    .tint(Color.brandGold)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let amountValue = Double(paymentAmount) else { return }
                        onAdd?(
                            QBStubPaymentCreate(
                                customerName: customerName.isEmpty ? "Unknown Customer" : customerName,
                                amount: amountValue,
                                method: paymentMethod.isEmpty ? "Manual" : paymentMethod,
                                notes: notes.isEmpty ? nil : notes
                            )
                        )
                        dismiss()
                        dismissHandler?()
                    }
                    .disabled(Double(paymentAmount) == nil)
                    .tint(Color.brandGold)
                }
            }
        }
        .tint(Color.brandGold)
    }
}

#Preview {
    NewPaymentView(dismiss: {})
}
