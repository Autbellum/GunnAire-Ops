import SwiftUI

struct NewVendorView: View {
    @Environment(\.dismiss) private var dismiss
    var dismissHandler: (() -> Void)?
    
    @State private var vendorName: String = ""
    @State private var email: String = ""
    @State private var phone: String = ""
    
    init(dismiss: @escaping () -> Void) {
        self.dismissHandler = dismiss
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Vendor Information") {
                    TextField("Vendor Name", text: $vendorName)
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                    TextField("Phone", text: $phone)
                        .keyboardType(.phonePad)
                }
            }
            .navigationTitle("New Vendor")
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
                        // TODO: Implement QuickBooks API call to add new vendor
                        dismiss()
                        dismissHandler?()
                    }
                    .disabled(vendorName.trimmingCharacters(in: .whitespaces).isEmpty)
                    .tint(Color.brandGold)
                }
            }
        }
        .tint(Color.brandGold)
    }
}

#Preview {
    NewVendorView(dismiss: {})
}
