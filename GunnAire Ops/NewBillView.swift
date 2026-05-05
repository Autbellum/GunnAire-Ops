import SwiftUI

struct NewBillView: View {
    @Environment(\.dismiss) private var dismiss
    var dismissHandler: (() -> Void)?
    var onCreate: ((QBStubBillCreate) -> Void)?

    @State private var vendorName: String = ""
    @State private var amount: String = ""
    @State private var notes: String = ""

    init(dismiss: @escaping () -> Void, onCreate: ((QBStubBillCreate) -> Void)? = nil) {
        self.dismissHandler = dismiss
        self.onCreate = onCreate
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Bill Details") {
                    TextField("Vendor Name", text: $vendorName)
                    TextField("Amount", text: $amount)
                        .keyboardType(.decimalPad)
                    TextField("Notes", text: $notes)
                }
            }
            .navigationTitle("New Bill")
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
                    Button("Create") {
                        guard let amountValue = Double(amount) else { return }
                        onCreate?(QBStubBillCreate(vendorName: vendorName, totalAmt: amountValue, notes: notes.isEmpty ? nil : notes))
                        dismiss()
                        dismissHandler?()
                    }
                    .disabled(vendorName.trimmingCharacters(in: .whitespaces).isEmpty || Double(amount) == nil)
                    .tint(Color.brandGold)
                }
            }
        }
        .tint(Color.brandGold)
    }
}

#Preview {
    NewBillView(dismiss: {})
}
