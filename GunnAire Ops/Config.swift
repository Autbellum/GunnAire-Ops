// Config.swift
// Central location for all API keys, tokens, and secrets
// -- FILL OUT WITH YOUR APP'S INFORMATION --
import Foundation

struct Config {
    private static func value(_ key: String, fallback: String) -> String {
        let env = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let env, !env.isEmpty, !env.contains("$(") { return env }
        let plist = (Bundle.main.object(forInfoDictionaryKey: key) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let plist, !plist.isEmpty, !plist.contains("$(") { return plist }
        return fallback
    }

    struct AppSecurity {
        static let allowTestingBypass = false
    }

    struct QuickBooks {
        // Prefer env overrides for local/dev workflows.
        static let clientID = Config.value("QB_CLIENT_ID", fallback: "YOUR_CLIENT_ID")
        static let clientSecret = Config.value("QB_CLIENT_SECRET", fallback: "YOUR_CLIENT_SECRET")
        static let redirectURI = Config.value("QB_REDIRECT_URI", fallback: "YOUR_REDIRECT_URI")
        // Optional callback scheme for ASWebAuthenticationSession when using an HTTPS redirect bridge.
        static let callbackScheme = Config.value("QB_CALLBACK_SCHEME", fallback: "gunnaireops")
        static let environment = Config.value("QB_ENVIRONMENT", fallback: "production") // sandbox or production
        // Required for invoice line item creation in QBO. Set to a valid Sales Item ID in your company.
        static let defaultSalesItemRef = Config.value("QB_DEFAULT_ITEM_REF", fallback: "1")
        static let defaultIncomeAccountRef = Config.value("QB_DEFAULT_INCOME_ACCOUNT_REF", fallback: "")
        static let defaultExpenseAccountRef = Config.value("QB_DEFAULT_EXPENSE_ACCOUNT_REF", fallback: "")
        
        // OAuth 2.0 endpoints for QuickBooks Online
        static let authorizationEndpoint = "https://appcenter.intuit.com/connect/oauth2" // Authorization endpoint URL
        static let tokenEndpoint = "https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer" // Token exchange endpoint URL

        static var isConfigured: Bool {
            !clientID.hasPrefix("YOUR_") &&
            !clientSecret.hasPrefix("YOUR_") &&
            !redirectURI.hasPrefix("YOUR_")
        }
    }
    struct Google {
        // Prefer env overrides for local/dev workflows.
        static let clientID = Config.value("GOOGLE_CLIENT_ID", fallback: "YOUR_GOOGLE_CLIENT_ID")
        static let reversedClientID = Config.value("GOOGLE_REVERSED_CLIENT_ID", fallback: "YOUR_GOOGLE_REVERSED_CLIENT_ID")
        static let redirectURI = Config.value("GOOGLE_REDIRECT_URI", fallback: "\(reversedClientID):/oauth2redirect")
        static let callbackScheme = Config.value("GOOGLE_CALLBACK_SCHEME", fallback: reversedClientID)
        static let allowedHostedDomain = Config.value("GOOGLE_ALLOWED_HOSTED_DOMAIN", fallback: "gunnaire.com")
        
        // Request only the scopes tied to user-facing features in this app.
        // Avoid unrelated Cloud / Drive / admin scopes here unless the app implements
        // those APIs, because they substantially raise Google verification burden.
        static let scopes = [
            "openid",
            "profile",
            "email",
            "https://www.googleapis.com/auth/calendar",
            "https://www.googleapis.com/auth/gmail.modify"
        ]
        
        // OAuth 2.0 endpoints for Google
        static let authorizationEndpoint = "https://accounts.google.com/o/oauth2/v2/auth" // Authorization endpoint URL
        static let tokenEndpoint = "https://oauth2.googleapis.com/token"                  // Token exchange endpoint URL
        
        // Note: PKCE (Proof Key for Code Exchange) is recommended for native and mobile apps for enhanced security.
    }

    struct QuickBooksTime {
        static let enabled = value("QB_TIME_ENABLED", fallback: "false").lowercased() == "true"
        static let graphqlEndpoint = "https://qb.api.intuit.com/graphql"
        static let requiredPartnerTier = "Silver or higher"
        static let requiredScope = "payroll.compensation.read"
        static let notes = "QuickBooks Payroll and Time is a separate Intuit integration from QuickBooks Online accounting and requires partner onboarding."
    }
}
