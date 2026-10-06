// QuickBooks authorization and device-session lifecycle.
import Foundation
import AuthenticationServices
import Combine

@MainActor
final class QuickBooksAuthAPI: ObservableObject {
    static let shared = QuickBooksAuthAPI()

    private let clientID = Config.QuickBooks.clientID
    private let redirectURI = Config.QuickBooks.redirectURI
    private let callbackScheme: String
    private let dataAPI: QuickBooksDataAPI
    private let stateStore: QuickBooksOAuthStateStore
    private let currentBinding: () -> String?
    private let exchangeCode: (String, String) async throws -> QuickBooksOAuthTokens
    private let restoreBusinessSession: () async -> Void
    private let allowsSessionResume: () -> Bool
    private let now: () -> Date
    private var activeAuthSession: ASWebAuthenticationSession?
    private var activePresentationContext: ASWebAuthenticationPresentationContextProviding?
    private var pendingOAuthState: String?
    private var pendingCancellation: Task<Void, Never>?
    private var authorizationGeneration = UUID()
    private var authorizationSuspended = false
    private var suspendedBinding: String?
    private var preparingAuthorization = false
    private var handlingCallback = false
    private var resumingAuthorization = false

    @Published private(set) var isAuthenticated = false
    @Published private(set) var callbackErrorMessage: String?
    @Published private var accessToken: String?
    @Published private var realmID: String?
    @Published private var tokenExpiry: Date?

    private init() {
        dataAPI = .shared
        stateStore = .shared
        callbackScheme = Self.resolvedCallbackScheme
        currentBinding = Self.liveBinding
        exchangeCode = { try await GunnAireBackendService.exchangeQuickBooksAuthorizationCode($0, realmID: $1) }
        restoreBusinessSession = {
            async let apple: Void = AppleAuthManager.shared.restoreStoredSession()
            async let google: Void = GoogleAuthManager.shared.restoreStoredSession()
            _ = await (apple, google)
            guard CompanyWorkspaceSession.current != nil else { return }
            await CompanyWorkspaceAccessController.shared.refreshIfStale(
                maxAge: CompanyWorkspaceAccessController.verificationInterval)
        }
        allowsSessionResume = { UserDefaults.standard.bool(forKey: "hasAuthenticatedUser") }
        now = Date.init
    }

    #if DEBUG
    init(testDataAPI: QuickBooksDataAPI, stateStore: QuickBooksOAuthStateStore = .shared,
         callbackScheme: String = "gunnaireops", currentBinding: @escaping () -> String? = { nil },
         exchangeCode: @escaping (String, String) async throws -> QuickBooksOAuthTokens = { _, _ in throw QBOError.tokenExchangeUnavailable },
         restoreBusinessSession: @escaping () async -> Void = {},
         allowsSessionResume: @escaping () -> Bool = { true }, now: @escaping () -> Date = Date.init) {
        dataAPI = testDataAPI
        self.stateStore = stateStore
        self.callbackScheme = callbackScheme
        self.currentBinding = currentBinding
        self.exchangeCode = exchangeCode
        self.restoreBusinessSession = restoreBusinessSession
        self.allowsSessionResume = allowsSessionResume
        self.now = now
    }

    func finishPendingCancellationForTesting() async {
        if let pendingCancellation { await pendingCancellation.value }
    }
    #endif

    func reloadStoredSession() async {
        guard let binding = currentBinding() else { return }
        if authorizationSuspended {
            guard binding != suspendedBinding else { return }
            authorizationSuspended = false
            suspendedBinding = nil
        }
        let generation = authorizationGeneration
        await dataAPI.restoreStoredSession()
        guard generation == authorizationGeneration, !authorizationSuspended,
              currentBinding() == binding else { return }
        accessToken = dataAPI.tokens?.accessToken
        tokenExpiry = dataAPI.tokens?.expiration
        realmID = dataAPI.realmID
        isAuthenticated = dataAPI.isAuthenticated
    }

    func startSignIn(presentationContext: ASWebAuthenticationPresentationContextProviding,
                     completion: @escaping (Result<Void, Error>) -> Void) {
        guard !preparingAuthorization, activeAuthSession == nil, !handlingCallback else {
            completion(.failure(QBOError.authorizationInProgress)); return
        }
        guard Config.QuickBooks.isConfigured else {
            completion(.failure(QBOError.missingConfiguration)); return
        }
        guard !Config.QuickBooks.isProduction || Config.QuickBooks.redirectURIIsHTTPS else {
            completion(.failure(QBOError.invalidRedirectURI(redirectURI))); return
        }
        guard !callbackScheme.isEmpty, isCallbackSchemeRegistered(callbackScheme) else {
            completion(.failure(QBOError.callbackSchemeNotRegistered(callbackScheme))); return
        }
        guard let binding = currentBinding() else {
            completion(.failure(QBOError.businessSessionRequired)); return
        }
        let record = QuickBooksOAuthStateRecord(binding: binding, createdAt: now())
        guard let authURL = makeAuthURL(state: record.state) else {
            completion(.failure(QBOError.invalidAuthURL)); return
        }
        authorizationGeneration = UUID()
        let generation = authorizationGeneration
        authorizationSuspended = false
        suspendedBinding = nil
        preparingAuthorization = true
        pendingOAuthState = record.state
        Task {
            if let pendingCancellation { await pendingCancellation.value }
            do {
                try requireCurrent(generation: generation, binding: binding)
                try await stateStore.save(record)
                try requireCurrent(generation: generation, binding: binding)
                preparingAuthorization = false
                openBrowser(url: authURL, record: record, generation: generation,
                            presentationContext: presentationContext, completion: completion)
            } catch {
                _ = try? await stateStore.cancel(state: record.state)
                if authorizationGeneration == generation {
                    preparingAuthorization = false
                    pendingOAuthState = nil
                }
                completion(.failure(Self.safeError(error)))
            }
        }
    }

    private func openBrowser(url: URL, record: QuickBooksOAuthStateRecord, generation: UUID,
                             presentationContext: ASWebAuthenticationPresentationContextProviding,
                             completion: @escaping (Result<Void, Error>) -> Void) {
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] url, _ in
            Task { @MainActor in
                guard let self else { completion(.failure(QBOError.cancelled)); return }
                guard self.authorizationGeneration == generation else {
                    completion(.failure(QBOError.sessionChanged)); return
                }
                self.activeAuthSession = nil
                self.activePresentationContext = nil
                guard let url else {
                    _ = try? await self.stateStore.cancel(state: record.state)
                    if self.authorizationGeneration == generation { self.pendingOAuthState = nil }
                    completion(.failure(QBOError.cancelled)); return
                }
                do {
                    try self.requireCurrent(generation: generation, binding: record.binding)
                    try await self.completeAuthCallback(url: url)
                    completion(.success(()))
                } catch {
                    // A malformed callback cannot cancel another flow stored after this one.
                    _ = try? await self.stateStore.cancel(state: record.state)
                    if self.authorizationGeneration == generation { self.pendingOAuthState = nil }
                    completion(.failure(Self.safeError(error)))
                }
            }
        }
        session.presentationContextProvider = presentationContext
        session.prefersEphemeralWebBrowserSession = false
        activePresentationContext = presentationContext
        activeAuthSession = session
        if !session.start() {
            activeAuthSession = nil
            activePresentationContext = nil
            pendingOAuthState = nil
            pendingCancellation = Task { _ = try? await stateStore.cancel(state: record.state) }
            completion(.failure(QBOError.browserUnavailable))
        }
    }

    /// Shared by the live browser and a callback that relaunches the app.
    func completeAuthCallback(url: URL) async throws {
        guard !handlingCallback else { throw QBOError.authorizationInProgress }
        guard !authorizationSuspended, let binding = currentBinding() else {
            throw QBOError.businessSessionRequired
        }
        let callback = try QuickBooksOAuthCallback.parse(url, expectedScheme: callbackScheme)
        let generation = authorizationGeneration
        handlingCallback = true
        defer { handlingCallback = false }
        do {
            _ = try await stateStore.consume(state: callback.state, binding: binding, now: now())
        } catch { throw Self.safeError(error) }
        if pendingOAuthState == callback.state { pendingOAuthState = nil }
        try requireCurrent(generation: generation, binding: binding)
        let tokens: QuickBooksOAuthTokens
        do { tokens = try await exchangeCode(callback.code, callback.realmID) }
        catch {
            try requireCurrent(generation: generation, binding: binding)
            throw QBOError.tokenExchangeUnavailable
        }
        try requireCurrent(generation: generation, binding: binding)
        guard !tokens.accessToken.isEmpty, tokens.expiration > now() else {
            throw QBOError.tokenExchangeUnavailable
        }
        dataAPI.storeTokens(tokens, realmID: callback.realmID)
        accessToken = tokens.accessToken
        tokenExpiry = tokens.expiration
        realmID = callback.realmID
        isAuthenticated = true
    }

    func resumeAuthorization(from url: URL) async {
        guard QuickBooksOAuthCallback.isCandidate(url, expectedScheme: callbackScheme),
              activeAuthSession == nil, !preparingAuthorization, !handlingCallback, !resumingAuthorization else { return }
        resumingAuthorization = true
        defer { resumingAuthorization = false }
        let generation = authorizationGeneration
        do {
            guard !authorizationSuspended, allowsSessionResume() else { throw QBOError.businessSessionRequired }
            // Reject malformed URLs before doing any restore or workspace work.
            _ = try QuickBooksOAuthCallback.parse(url, expectedScheme: callbackScheme)
            await restoreBusinessSession()
            guard generation == authorizationGeneration, !authorizationSuspended, allowsSessionResume() else {
                throw QBOError.sessionChanged
            }
            try await completeAuthCallback(url: url)
            callbackErrorMessage = nil
        } catch {
            if generation == authorizationGeneration {
                callbackErrorMessage = Self.safeError(error).localizedDescription
            }
        }
    }

    func clearCallbackError() { callbackErrorMessage = nil }

    func signOut() {
        let state = pendingOAuthState
        let binding = currentBinding()
        isAuthenticated = false
        accessToken = nil
        realmID = nil
        tokenExpiry = nil
        authorizationGeneration = UUID()
        authorizationSuspended = true
        suspendedBinding = binding
        preparingAuthorization = false
        pendingOAuthState = nil
        activeAuthSession?.cancel()
        activeAuthSession = nil
        activePresentationContext = nil
        callbackErrorMessage = nil
        dataAPI.suspendLocalSession()
        // Include the persisted flow after a restart; never remove a different session's flow.
        if state != nil || binding != nil {
            let previousCancellation = pendingCancellation
            pendingCancellation = Task {
                if let previousCancellation { await previousCancellation.value }
                if let state { _ = try? await stateStore.cancel(state: state) }
                else if let binding { _ = try? await stateStore.cancel(binding: binding) }
            }
        }
    }

    /// Only the explicit, confirmed Disconnect action revokes company access.
    func disconnect(completion: @escaping (Bool) -> Void = { _ in }) {
        dataAPI.resetConnectionForReconnect { [weak self] succeeded in
            if succeeded { self?.signOut() }
            completion(succeeded)
        }
    }

    private func requireCurrent(generation: UUID, binding: String) throws {
        try Task.checkCancellation()
        guard !authorizationSuspended, authorizationGeneration == generation,
              currentBinding() == binding else { throw QBOError.sessionChanged }
    }

    private static var resolvedCallbackScheme: String {
        Config.QuickBooks.callbackScheme.isEmpty
            ? (URL(string: Config.QuickBooks.redirectURI)?.scheme ?? "") : Config.QuickBooks.callbackScheme
    }

    private static func liveBinding() -> String? {
        guard let session = CompanyWorkspaceSession.current,
              let companyID = CompanyWorkspaceAccessController.shared.verifiedCompanyID else { return nil }
        let components = ["quickbooks-oauth-binding-v1", session.backendOrigin, session.email,
                          session.tokenFingerprint, companyID.uuidString, Config.QuickBooks.environment,
                          Config.QuickBooks.clientID, Config.QuickBooks.redirectURI, resolvedCallbackScheme,
                          Config.QuickBooks.authorizationEndpoint] + Config.QuickBooks.oauthScopes.sorted()
        guard let data = try? JSONEncoder().encode(components) else { return nil }
        return CompanyWorkspaceSession.digest(data.base64EncodedString())
    }

    private func isCallbackSchemeRegistered(_ scheme: String) -> Bool {
        guard let urlTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] else { return false }
        return urlTypes.compactMap { $0["CFBundleURLSchemes"] as? [String] }.flatMap { $0 }
            .contains { $0.caseInsensitiveCompare(scheme) == .orderedSame }
    }

    private func makeAuthURL(state: String) -> URL? {
        var components = URLComponents(string: Config.QuickBooks.authorizationEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Config.QuickBooks.oauthScopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state)
        ]
        return components?.url
    }

    private static func safeError(_ error: Error) -> QBOError {
        if let error = error as? QBOError { return error }
        if error is CancellationError { return .cancelled }
        if let error = error as? QuickBooksOAuthStateError {
            switch error {
            case .expired, .clockRollback: return .expiredState
            case .changedBinding: return .sessionChanged
            case .missing, .invalidRecord, .mismatchedState: return .invalidState
            case .removalNotConfirmed: return .stateStorageUnavailable
            }
        }
        return .stateStorageUnavailable
    }
}

nonisolated enum QBOError: Error, LocalizedError, Equatable {
    case invalidAuthURL, missingAuthCode, missingRealmID, invalidState, notAuthenticated
    case invalidRedirectURI(String), callbackSchemeNotRegistered(String), missingConfiguration
    case providerError(String, String?), tokenExchangeFailed(Int, String?), unknown
    case invalidCallback, authorizationDeclined, authorizationInProgress, businessSessionRequired
    case sessionChanged, expiredState, stateStorageUnavailable, tokenExchangeUnavailable, browserUnavailable, cancelled

    var errorDescription: String? {
        switch self {
        case .invalidAuthURL: return "QuickBooks authorization could not be opened. Check the app configuration."
        case .missingAuthCode, .missingRealmID, .invalidCallback: return "QuickBooks returned an incomplete or ambiguous callback. Start Connect QuickBooks again."
        case .invalidState: return "This QuickBooks connection attempt could not be verified or was already used. Start Connect QuickBooks again."
        case .notAuthenticated: return "You are not signed in to QuickBooks."
        case .invalidRedirectURI, .callbackSchemeNotRegistered, .missingConfiguration: return "QuickBooks authorization is not configured correctly for this build. Contact your administrator."
        case .providerError, .authorizationDeclined: return "QuickBooks authorization was declined or cancelled. Your existing connection was kept."
        case .tokenExchangeFailed, .tokenExchangeUnavailable: return "QuickBooks could not finish the connection. Check connection status before starting Connect QuickBooks again."
        case .authorizationInProgress: return "A QuickBooks connection attempt is already in progress."
        case .businessSessionRequired: return "Sign in to your GunnAire business workspace before connecting QuickBooks."
        case .sessionChanged: return "Your business session changed during QuickBooks authorization. Start Connect QuickBooks again."
        case .expiredState: return "This QuickBooks connection attempt expired. Start Connect QuickBooks again."
        case .stateStorageUnavailable: return "QuickBooks could not securely verify the saved connection attempt. Unlock this device and start Connect QuickBooks again."
        case .browserUnavailable: return "The QuickBooks sign-in browser could not open. Try Connect QuickBooks again."
        case .cancelled: return "QuickBooks authorization was cancelled."
        case .unknown: return "QuickBooks authorization could not finish. Try Connect QuickBooks again."
        }
    }
}
