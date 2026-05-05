import SwiftUI
import SwiftData

struct LoginView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]

    @Binding var hasAuthenticatedUser: Bool
    @Binding var testingBypassActive: Bool

    @ObservedObject private var googleAuth = GoogleAuthManager.shared
    @State private var isAuthenticating = false
    @State private var authErrorMessage: String?

    private let presentationContextProvider = ContentViewPresentationContextProvider()

    private var googleConfigReady: Bool {
        !Config.Google.clientID.hasPrefix("YOUR_") &&
        !Config.Google.clientSecret.hasPrefix("YOUR_") &&
        !Config.Google.redirectURI.hasPrefix("YOUR_")
    }

    var body: some View {
        ZStack {
            WatermarkBackground()

            VStack(spacing: 20) {
                Text("GunnAire Ops")
                    .font(.largeTitle)
                    .bold()
                    .foregroundColor(Color.brandGold)

                Text("Sign in with your GunnAire Google account.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)

                Button {
                    startGoogleSignIn()
                } label: {
                    HStack {
                        if isAuthenticating {
                            ProgressView()
                        }
                        Text(isAuthenticating ? "Signing In..." : "Sign In With Google")
                            .bold()
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.brandGold)
                .foregroundStyle(Color.primaryBlack)
                .disabled(isAuthenticating || !googleConfigReady)

                if Config.AppSecurity.allowTestingBypass {
                    Button("Continue in Testing Mode (Bypass Login)") {
                        testingBypassActive = true
                    }
                    .buttonStyle(.bordered)

                    Text("Testing bypass is enabled. Disable it before publishing.")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                if !googleConfigReady {
                    Text("Google OAuth credentials are not configured in Config/environment.")
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                if let authErrorMessage {
                    Text(authErrorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
            .padding()
            .frame(maxWidth: 520)
        }
    }

    private func startGoogleSignIn() {
        authErrorMessage = nil
        isAuthenticating = true

        googleAuth.startSignIn(presentationContext: presentationContextProvider) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    googleAuth.validateSignedInDomain { validation in
                        DispatchQueue.main.async {
                            isAuthenticating = false
                            switch validation {
                            case .success(let profile):
                                guard AppAccess.isAuthorized(email: profile.email, users: users) else {
                                    googleAuth.signOut()
                                    authErrorMessage = "Your GunnAire account has not been added to this app by an administrator."
                                    return
                                }
                                ensurePrimaryAdminExists()
                                hasAuthenticatedUser = true
                            case .failure(let error):
                                authErrorMessage = error.localizedDescription
                            }
                        }
                    }
                case .failure(let error):
                    isAuthenticating = false
                    authErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func ensurePrimaryAdminExists() {
        guard !users.contains(where: { $0.email == AppAccess.primaryAdminEmail }) else { return }
        modelContext.insert(AppUser(email: AppAccess.primaryAdminEmail, role: .admin))
    }
}

#Preview {
    LoginView(
        hasAuthenticatedUser: .constant(false),
        testingBypassActive: .constant(false)
    )
}
