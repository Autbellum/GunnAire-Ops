import SwiftUI
import SwiftData
import AuthenticationServices

struct LoginView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]
    @Query(sort: \Technician.name, order: .forward) private var technicians: [Technician]

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
            let authorizationUsers = GunnAireBackendService.applyVerifiedUser(
                remoteUser,
                into: modelContext,
                currentUsers: users,
                technicians: technicians
            )
            isAuthenticating = false
            guard AppAccess.isAuthorized(email: remoteUser.email, users: authorizationUsers) else {
                appleAuth.signOut()
                authErrorMessage = "Your GunnAire account has not been added to this app by an administrator."
                return
            }
            ensurePrimaryAdminExists()
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
        var authorizationUsers = users
        var sharedUserError: Error?

        if GunnAireBackendService.isConfigured {
            do {
                if Config.Backend.usesBusinessIdentity {
                    let remoteUser = try await googleAuth.establishBusinessApplicationSession(for: profile)
                    authorizationUsers = GunnAireBackendService.applyVerifiedUser(
                        remoteUser,
                        into: modelContext,
                        currentUsers: users,
                        technicians: technicians
                    )
                } else {
                    authorizationUsers = try await GunnAireBackendService.refreshUsers(
                        into: modelContext,
                        currentUsers: users,
                        technicians: technicians
                    )
                }
            } catch {
                sharedUserError = error
            }
        }

        isAuthenticating = false
        if Config.Backend.usesBusinessIdentity, let sharedUserError {
            googleAuth.signOut()
            authErrorMessage = "Could not establish the verified GunnAire business session: \(sharedUserError.localizedDescription)"
            return
        }
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
