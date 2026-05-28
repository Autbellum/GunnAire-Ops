import SwiftUI
import SwiftData

struct LoginView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]
    @Query(sort: \Technician.name, order: .forward) private var technicians: [Technician]

    @Binding var hasAuthenticatedUser: Bool

    @ObservedObject private var googleAuth = GoogleAuthManager.shared
    @State private var isAuthenticating = false
    @State private var authErrorMessage: String?

    private let presentationContextProvider = ContentViewPresentationContextProvider()

    private var googleConfigReady: Bool {
        !Config.Google.clientID.hasPrefix("YOUR_") &&
        !Config.Google.reversedClientID.hasPrefix("YOUR_")
    }

    var body: some View {
        ZStack {
            WatermarkBackground()

            VStack(spacing: 20) {
                Image("LoadingEmblem")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 140, height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 18, y: 10)

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
                            switch validation {
                            case .success(let profile):
                                Task { @MainActor in
                                    await completeValidatedSignIn(for: profile)
                                }
                            case .failure(let error):
                                isAuthenticating = false
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

    @MainActor
    private func completeValidatedSignIn(for profile: GoogleUserProfile) async {
        var authorizationUsers = users
        var sharedUserError: Error?

        if GunnAireBackendService.isConfigured {
            do {
                authorizationUsers = try await GunnAireBackendService.refreshUsers(
                    into: modelContext,
                    currentUsers: users,
                    technicians: technicians
                )
            } catch {
                sharedUserError = error
            }
        }

        isAuthenticating = false
        guard AppAccess.isAuthorized(email: profile.email, users: authorizationUsers) else {
            googleAuth.signOut()
            if let sharedUserError, GunnAireBackendService.isConfigured {
                authErrorMessage = "Could not verify shared user access from the Mac Studio backend: \(sharedUserError.localizedDescription)"
            } else {
                authErrorMessage = "Your GunnAire account has not been added to this app by an administrator."
            }
            return
        }

        ensurePrimaryAdminExists()
        hasAuthenticatedUser = true
    }

    private func ensurePrimaryAdminExists() {
        guard !users.contains(where: { $0.email == AppAccess.primaryAdminEmail }) else { return }
        modelContext.insert(AppUser(email: AppAccess.primaryAdminEmail, role: .admin))
    }
}

#Preview {
    LoginView(
        hasAuthenticatedUser: .constant(false)
    )
}
