import SwiftUI

struct NewInvoiceView: View {
    @Environment(\.dismiss) private var dismiss
    var dismissHandler: (() -> Void)?
    
    @EnvironmentObject private var qbAPI: QBStubAPIClient
    
    @State private var customerName: String = ""
    @State private var amount: String = ""
    @State private var notes: String = ""
    
    @State private var isCreating = false
    @State private var creationError: String? = nil
    
    init(dismiss: @escaping () -> Void) {
        self.dismissHandler = dismiss
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Invoice Details") {
                    TextField("Customer Name", text: $customerName)
                    TextField("Amount", text: $amount)
                        .keyboardType(.decimalPad)
                    TextField("Notes", text: $notes)
                    
                    if isCreating {
                        ProgressView("Creating Invoice...")
                            .tint(Color.brandGold)
                    }
                    if let creationError {
                        Text("Error: \(creationError)")
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("New Invoice")
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
                        createInvoice()
                    }
                    .disabled(customerName.trimmingCharacters(in: .whitespaces).isEmpty || amount.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
                    .tint(Color.brandGold)
                }
            }
        }
        .tint(Color.brandGold)
    }
    
    private func createInvoice() {
        guard let amountDouble = Double(amount) else {
            creationError = "Invalid amount entered."
            return
        }
        
        isCreating = true
        creationError = nil
        
        let invoiceCreate = QBStubInvoiceCreate(
            CustomerRef: QBStubReference(value: nil, name: customerName),
            Line: [],
            TotalAmt: amountDouble,
            PrivateNote: notes.isEmpty ? nil : notes
        )
        
        qbAPI.createInvoice(invoiceCreate) { result in
            DispatchQueue.main.async {
                isCreating = false
                switch result {
                case .success:
                    dismiss()
                    dismissHandler?()
                case .failure(let error):
                    creationError = error.localizedDescription
                }
            }
        }
    }
}

#Preview {
    NewInvoiceView(dismiss: {})
        .environmentObject(QBStubAPIClient())
}
