import SwiftUI

struct SettingsView: View {
    @Binding var isQuickBooksAuthenticated: Bool
    @Binding var isGoogleAuthenticated: Bool
    let authenticateQuickBooks: () -> Void
    let authenticateGoogle: () -> Void
    let dismiss: () -> Void
    
    var body: some View {
        NavigationStack {
            Form {
                Section("QuickBooks") {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(isQuickBooksAuthenticated ? "Connected" : "Not Connected")
                            .foregroundColor(isQuickBooksAuthenticated ? .green : .secondary)
                    }
                    
                    if isQuickBooksAuthenticated {
                        Button("Disconnect QuickBooks", role: .destructive) {
                            isQuickBooksAuthenticated = false
                        }
                    } else {
                        Button("Connect QuickBooks") {
                            authenticateQuickBooks()
                        }
                    }
                }
                
                Section("Google") {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(isGoogleAuthenticated ? "Connected" : "Not Connected")
                            .foregroundColor(isGoogleAuthenticated ? .green : .secondary)
                    }
                    
                    if isGoogleAuthenticated {
                        Button("Disconnect Google", role: .destructive) {
                            isGoogleAuthenticated = false
                        }
                    } else {
                        Button("Connect Google") {
                            authenticateGoogle()
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    SettingsView(
        isQuickBooksAuthenticated: .constant(false),
        isGoogleAuthenticated: .constant(false),
        authenticateQuickBooks: {},
        authenticateGoogle: {},
        dismiss: {}
    )
}
