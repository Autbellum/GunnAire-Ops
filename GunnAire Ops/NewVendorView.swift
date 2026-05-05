import SwiftUI

struct NewVendorView: View {
    @Environment(\.dismiss) private var dismiss
    var dismissHandler: (() -> Void)?
    var onAdd: ((QBStubVendorCreate) -> Void)?

    @State private var vendorName: String = ""
    @State private var email: String = ""
    @State private var phone: String = ""

    init(dismiss: @escaping () -> Void, onAdd: ((QBStubVendorCreate) -> Void)? = nil) {
        self.dismissHandler = dismiss
        self.onAdd = onAdd
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
                        onAdd?(
                            QBStubVendorCreate(
                                displayName: vendorName,
                                email: email.isEmpty ? nil : email,
                                phone: phone.isEmpty ? nil : phone
                            )
                        )
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
