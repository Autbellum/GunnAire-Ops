// Config.swift
// Central location for all API keys, tokens, and secrets
// -- FILL OUT WITH YOUR APP'S INFORMATION --
import Foundation

struct Config {
    private static func optionalValue(_ key: String) -> String? {
        let env = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let env, !env.isEmpty, !env.contains("$(") { return env }
        let plist = (Bundle.main.object(forInfoDictionaryKey: key) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let plist, !plist.isEmpty, !plist.contains("$(") { return plist }
        return nil
    }

    private static func value(_ key: String, fallback: String) -> String {
        optionalValue(key) ?? fallback
    }

    struct AppSecurity {
        static let allowTestingBypass = false
    }

    struct Backend {
        static let baseURL = Config.value("GUNNAIRE_BACKEND_BASE_URL", fallback: "")
        static let apiToken = Config.value("GUNNAIRE_BACKEND_API_TOKEN", fallback: "")
        static let authMode = Config.value("GUNNAIRE_BACKEND_AUTH_MODE", fallback: "api-token")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        /// The deployed backend keeps its historical `google-id-token` mode
        /// name for configuration compatibility. In that mode it accepts either
        /// a verified Google ID token or a backend-issued Apple app session.
        static var usesBusinessIdentity: Bool { authMode == "google-id-token" }
        static var hasSupportedAuthMode: Bool { authMode == "api-token" || usesBusinessIdentity }

        static var normalizedBaseURL: String {
            baseURL
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        static var usesHTTPS: Bool {
            URL(string: normalizedBaseURL)?.scheme?.lowercased() == "https"
        }

        static var isConfigured: Bool {
            !normalizedBaseURL.isEmpty &&
            URL(string: normalizedBaseURL) != nil &&
            hasSupportedAuthMode &&
            (usesBusinessIdentity ||
                (!apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !apiToken.contains("$(")))
        }

        /// Production accounting access must not rely on the legacy shared-token
        /// backend mode, which is only appropriate for a controlled development LAN.
        static var isProductionReady: Bool {
            isConfigured && usesBusinessIdentity && usesHTTPS
        }

        static var displayHost: String {
            guard let url = URL(string: normalizedBaseURL), let host = url.host else {
                return "Not configured"
            }
            if let port = url.port {
                return "\(host):\(port)"
            }
            return host
        }
    }

    struct QuickBooks {
        // Prefer env / Info.plist overrides for local and CI workflows. Production is the app default;
        // use QB_ENVIRONMENT=sandbox only for an intentional Intuit sandbox test build.
        static let clientID = Config.value("QB_CLIENT_ID", fallback: "YOUR_CLIENT_ID")
        // The iOS app is a public OAuth client. The QBO client secret is held only by
        // the backend callback bridge, which performs code exchange and token refresh.
        static let redirectURI = Config.value("QB_REDIRECT_URI", fallback: "YOUR_REDIRECT_URI")
        // ASWebAuthenticationSession callback scheme. For production, use an HTTPS Intuit redirect URI
        // that forwards back into this custom scheme after your backend exchanges / validates the callback.
        static let callbackScheme = Config.value("QB_CALLBACK_SCHEME", fallback: "gunnaireops")
        private static let configuredEnvironment = Config.value("QB_ENVIRONMENT", fallback: "production")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        static let environment = configuredEnvironment == "sandbox" ? "sandbox" : "production"

        // Enable only when the app is approved for QuickBooks Payments and users reconnect after scope changes.
        static let enablePaymentsScope = Config.value("QB_ENABLE_PAYMENTS_SCOPE", fallback: "false").lowercased() != "false"
        static let maxConcurrentSyncRequests = max(1, Int(Config.value("QB_MAX_CONCURRENT_SYNC_REQUESTS", fallback: "3")) ?? 3)
        static let maxRetryAttempts = max(0, Int(Config.value("QB_MAX_RETRY_ATTEMPTS", fallback: "3")) ?? 3)
        static let requestTimeoutSeconds = max(15, Double(Config.value("QB_REQUEST_TIMEOUT_SECONDS", fallback: "45")) ?? 45)

        static let accountingScope = "com.intuit.quickbooks.accounting"
        static let paymentsScope = "com.intuit.quickbooks.payment"
        static let accountingOAuthScopes = [accountingScope]
        static let paymentsOAuthScopes = [accountingScope, paymentsScope]
        static var oauthScopes: [String] {
            enablePaymentsScope ? paymentsOAuthScopes : accountingOAuthScopes
        }

        static var oauthScopeSignature: String {
            oauthScopes.joined(separator: "|")
        }

        static var clientIDFingerprint: String {
            let trimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("YOUR_") else { return "unconfigured" }
            if trimmed.count <= 12 { return trimmed }
            return "\(trimmed.prefix(4))…\(trimmed.suffix(6))"
        }

        static var configurationSummary: String {
            "Environment: \(environment.capitalized) • Client: \(clientIDFingerprint) • Payments scope: \(enablePaymentsScope ? "On" : "Off")"
        }

        // OAuth 2.0 endpoints for QuickBooks Online.
        static let authorizationEndpoint = "https://appcenter.intuit.com/connect/oauth2"
        static let tokenEndpoint = "https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer"
        static let revocationEndpoint = "https://developer.api.intuit.com/v2/oauth2/tokens/revoke"

        static var isSandbox: Bool { environment == "sandbox" }
        static var isProduction: Bool { environment == "production" }
        static var redirectURIIsHTTPS: Bool { URL(string: redirectURI)?.scheme?.lowercased() == "https" }
        static var redirectURIIsPlaceholder: Bool { redirectURI.hasPrefix("YOUR_") || redirectURI.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        static var clientIDIsPlaceholder: Bool { clientID.hasPrefix("YOUR_") || clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        static var isConfigured: Bool {
            !clientIDIsPlaceholder &&
            !redirectURIIsPlaceholder &&
            Backend.isConfigured &&
            (isSandbox || (redirectURIIsHTTPS && Backend.isProductionReady))
        }

        static var configurationWarnings: [String] {
            var warnings: [String] = []
            if isProduction && !redirectURIIsHTTPS {
                warnings.append("Production QuickBooks redirect URIs must be HTTPS and must exactly match the Intuit Developer Portal entry.")
            }
            if isProduction && !Backend.isProductionReady {
                warnings.append("Production QuickBooks requires an HTTPS backend using verified GunnAire business identity. The shared API-token backend mode is development-only.")
            }
            if configuredEnvironment != "production" && configuredEnvironment != "sandbox" {
                warnings.append("QB_ENVIRONMENT was '\(configuredEnvironment)'. The app is using production; set it to production or sandbox explicitly.")
            }
            return warnings
        }
    }
    struct Google {
        // Prefer env overrides for local/dev workflows.
        static let clientID = Config.value("GOOGLE_CLIENT_ID", fallback: "YOUR_GOOGLE_CLIENT_ID")
        static let reversedClientID = Config.value("GOOGLE_REVERSED_CLIENT_ID", fallback: "YOUR_GOOGLE_REVERSED_CLIENT_ID")
        static let redirectURI = Config.value("GOOGLE_REDIRECT_URI", fallback: "\(reversedClientID):/oauth2redirect")
        static let callbackScheme = Config.value("GOOGLE_CALLBACK_SCHEME", fallback: reversedClientID)
        static let allowedHostedDomain = Config.value("GOOGLE_ALLOWED_HOSTED_DOMAIN", fallback: "gunnaire.com")
        
        static let calendarScope = "https://www.googleapis.com/auth/calendar"
        static let gmailModifyScope = "https://www.googleapis.com/auth/gmail.modify"
        /// Per-file access is the least-privilege Drive scope. It limits the app
        /// to files it creates or that the user explicitly opens with the app.
        static let driveFileScope = "https://www.googleapis.com/auth/drive.file"

        // Request only the scopes tied to user-facing features in this app.
        // Do not replace drive.file with broad Drive or Workspace admin access.
        static let scopes = [
            "openid",
            "profile",
            "email",
            calendarScope,
            gmailModifyScope,
            driveFileScope
        ]

        static var oauthScopeSignature: String {
            scopeSignature(for: scopes)
        }

        static func scopeSignature(for scopes: [String]) -> String {
            scopes
                .flatMap { $0.split(whereSeparator: \Character.isWhitespace).map(String.init) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { $0.lowercased() }
                .reduce(into: Set<String>()) { $0.insert($1) }
                .sorted()
                .joined(separator: "|")
        }
        
        // OAuth 2.0 endpoints for Google
        static let authorizationEndpoint = "https://accounts.google.com/o/oauth2/v2/auth" // Authorization endpoint URL
        static let tokenEndpoint = "https://oauth2.googleapis.com/token"                  // Token exchange endpoint URL
        
        // Note: PKCE (Proof Key for Code Exchange) is recommended for native and mobile apps for enhanced security.
    }

    struct QuickBooksTime {
        static let enabled = value("QB_TIME_ACTIVITY_SYNC_ENABLED", fallback: "false").lowercased() == "true"
        static let itemRef = value("QB_TIME_ACTIVITY_ITEM_REF", fallback: "")
        static let payrollItemRef = value("QB_TIME_ACTIVITY_PAYROLL_ITEM_REF", fallback: "")
        static let projectRef = value("QB_TIME_ACTIVITY_PROJECT_REF", fallback: "")
        static let graphqlEndpoint = "https://qb.api.intuit.com/graphql"
        static let accountingResource = "TimeActivity"
        static let accountingOperations = "Query, Create, Update, Delete"
        static let requiredAccountingScope = QuickBooks.accountingScope
        static let payrollCompensationScope = "payroll.compensation.read"
        static let notes = "QBO Accounting TimeActivity records completed time only. Each technician requires an explicit Employee or Vendor mapping in the app. Live clock-in/out stays local until clock-out creates a duration-based TimeActivity. PayrollItemRef requires QuickBooks Workforce/Payroll compensation access."
    }
}
