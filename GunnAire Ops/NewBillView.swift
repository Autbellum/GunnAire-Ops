import SwiftUI

struct NewBillView: View {
    @Environment(\.dismiss) private var dismiss
    var dismissHandler: (() -> Void)?
    
    @State private var vendorName: String = ""
    @State private var amount: String = ""
    @State private var notes: String = ""
    
    init(dismiss: @escaping () -> Void) {
        self.dismissHandler = dismiss
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
                        // TODO: Implement QuickBooks API call to create bill
                        dismiss()
                        dismissHandler?()
                    }
                    .disabled(vendorName.trimmingCharacters(in: .whitespaces).isEmpty || amount.trimmingCharacters(in: .whitespaces).isEmpty)
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
