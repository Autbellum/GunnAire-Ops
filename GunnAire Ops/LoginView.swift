import SwiftUI
import SwiftData
import AuthenticationServices

struct LoginView: View {
    @Binding var hasAuthenticatedUser: Bool

    @ObservedObject private var googleAuth = GoogleAuthManager.shared
    @ObservedObject private var appleAuth = AppleAuthManager.shared
    @State private var isAuthenticating = false
    @State private var authErrorMessage: String?

    private var googleConfigReady: Bool {
        !Config.Google.clientID.hasPrefix("YOUR_") &&
        !Config.Google.reversedClientID.hasPrefix("YOUR_")
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(.systemBackground), Color.brandGold.opacity(0.10)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "thermometer.medium")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(Color.brandGold)
                    .frame(width: 84, height: 84)
                    .background(Color.brandGold.opacity(0.12), in: Circle())
                    .accessibilityHidden(true)

                Text("GunnAire Ops")
                    .font(.largeTitle)
                    .bold()
                    .foregroundColor(Color.brandGold)

                Text("Sign in with your approved GunnAire business account.")
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

                HStack {
                    Rectangle().frame(height: 1).foregroundStyle(.separator)
                    Text("or").font(.caption).foregroundStyle(.secondary)
                    Rectangle().frame(height: 1).foregroundStyle(.separator)
                }

                SignInWithAppleButton(.signIn) { request in
                    authErrorMessage = nil
                    isAuthenticating = true
                    appleAuth.prepare(request)
                } onCompletion: { result in
                    Task { @MainActor in
                        await completeAppleSignIn(result)
                    }
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 50)
                .disabled(isAuthenticating || !GunnAireBackendService.isConfigured)
                .accessibilityIdentifier("Sign In With Apple")

                if !googleConfigReady {
                    Text("Google OAuth credentials are not configured in Config/environment.")
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                if !GunnAireBackendService.isConfigured {
                    Text("Sign in with Apple requires the secure GunnAire backend configuration.")
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
            .padding(28)
            .frame(maxWidth: 520)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(24)
        }
    }

    @MainActor
    private func completeAppleSignIn(_ result: Result<ASAuthorization, Error>) async {
        do {
            let remoteUser = try await appleAuth.complete(result)
            isAuthenticating = false
            guard remoteUser.isActive, AppUserRole(rawValue: remoteUser.role) != nil else {
                appleAuth.signOut()
                authErrorMessage = "Your GunnAire account has not been added to this app by an administrator."
                return
            }
            hasAuthenticatedUser = true
        } catch {
            isAuthenticating = false
            authErrorMessage = error.localizedDescription
        }
    }

    private func startGoogleSignIn() {
        authErrorMessage = nil
        isAuthenticating = true

        guard let presentationContext = ContentViewPresentationContextProvider.makeIfAvailable() else {
            isAuthenticating = false
            authErrorMessage = ContentViewPresentationContextProvider.unavailableMessage
            return
        }

        googleAuth.startSignIn(presentationContext: presentationContext) { result in
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
        defer { isAuthenticating = false }
        do {
            guard Config.Backend.isProductionReady else { throw GunnAireBackendError.notConfigured }
            let remoteUser = try await googleAuth.establishBusinessApplicationSession(for: profile)
            guard remoteUser.isActive, AppUserRole(rawValue: remoteUser.role) != nil else {
                throw CompanyWorkspaceFailure.signIn
            }
            // Model-backed user and technician writes occur only after the
            // workspace controller proves this device's operational store.
            hasAuthenticatedUser = true
        } catch {
            googleAuth.signOut()
            authErrorMessage = "Could not verify business access: \(error.localizedDescription)"
        }
    }
}

#Preview {
    LoginView(
        hasAuthenticatedUser: .constant(false)
    )
}
