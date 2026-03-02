import SwiftUI

struct NewPaymentView: View {
    @Environment(\.dismiss) private var dismiss
    var dismissHandler: (() -> Void)?
    
    @State private var paymentAmount: String = ""
    @State private var paymentMethod: String = ""
    @State private var notes: String = ""
    
    init(dismiss: @escaping () -> Void) {
        self.dismissHandler = dismiss
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Payment Details") {
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
                        // TODO: Implement QuickBooks API call to add new payment
                        dismiss()
                        dismissHandler?()
                    }
                    .disabled(paymentAmount.trimmingCharacters(in: .whitespaces).isEmpty)
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
