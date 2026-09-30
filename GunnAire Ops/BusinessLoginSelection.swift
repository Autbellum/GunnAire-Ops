import Foundation

enum BusinessLoginProvider: String, Sendable {
    case apple
    case google
}

/// Selects which verified application session owns the business workspace.
/// Google OAuth may also be connected for integrations while Apple remains the
/// business login, so provider availability alone cannot make this decision.
@MainActor
enum BusinessLoginSelection {
    private static let storageKey = "GunnAireBusinessLoginProvider"

    struct AuthorizationHeader: Equatable {
        let name: String
        let value: String
    }

    static var selected: BusinessLoginProvider? { selected(in: .standard) }

    static func selected(in defaults: UserDefaults) -> BusinessLoginProvider? {
        defaults.string(forKey: storageKey).flatMap(BusinessLoginProvider.init(rawValue:))
    }

    static func choose(_ provider: BusinessLoginProvider, in defaults: UserDefaults = .standard) {
        defaults.set(provider.rawValue, forKey: storageKey)
    }

    static func clear(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }

    static func resolvedProvider(
        selected: BusinessLoginProvider?,
        appleBusinessSessionAvailable: Bool,
        googleBusinessSessionAvailable: Bool
    ) -> BusinessLoginProvider? {
        switch selected {
        case .apple:
            return appleBusinessSessionAvailable ? .apple : nil
        case .google:
            return googleBusinessSessionAvailable ? .google : nil
        case nil:
            // Existing installs did not persist a provider choice. Preserve
            // their Apple-first behavior for this one migration decision.
            if appleBusinessSessionAvailable { return .apple }
            if googleBusinessSessionAvailable { return .google }
            return nil
        }
    }

    /// The business bearer must follow the selected login, even when Google
    /// integration OAuth and an older Apple application session coexist.
    static func authorizationHeader(
        selected: BusinessLoginProvider?,
        appleSessionToken: String?,
        googleSessionToken: String?,
        googleIdentityToken: String?
    ) -> AuthorizationHeader? {
        func bearer(_ token: String?) -> AuthorizationHeader? {
            guard let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return AuthorizationHeader(name: "Authorization", value: "Bearer \(token)")
        }
        switch selected {
        case .apple:
            return bearer(appleSessionToken)
        case .google:
            return bearer(googleSessionToken)
        case nil:
            if let apple = bearer(appleSessionToken) { return apple }
            if let google = bearer(googleSessionToken) { return google }
            guard let googleIdentityToken,
                  !googleIdentityToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return AuthorizationHeader(name: "X-GunnAire-Google-ID-Token", value: googleIdentityToken)
        }
    }
}
