// Config.swift
// Central location for all API keys, tokens, and secrets
// -- FILL OUT WITH YOUR APP'S INFORMATION --
import Foundation

struct Config {
    private static func value(_ key: String, fallback: String) -> String {
        let env = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let env, !env.isEmpty { return env }
        let plist = (Bundle.main.object(forInfoDictionaryKey: key) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let plist, !plist.isEmpty { return plist }
        return fallback
    }

    struct AppSecurity {
        // TODO: Set this to false before publishing to App Store / production.
        #if DEBUG
        static let allowTestingBypass = true
        #else
        static let allowTestingBypass = false
        #endif
    }

    struct QuickBooks {
        // Prefer env overrides for local/dev workflows.
        static let clientID = Config.value("QB_CLIENT_ID", fallback: "YOUR_CLIENT_ID")
        static let clientSecret = Config.value("QB_CLIENT_SECRET", fallback: "YOUR_CLIENT_SECRET")
        static let redirectURI = Config.value("QB_REDIRECT_URI", fallback: "YOUR_REDIRECT_URI")
        // Optional callback scheme for ASWebAuthenticationSession when using an HTTPS redirect bridge.
        static let callbackScheme = Config.value("QB_CALLBACK_SCHEME", fallback: "gunnaireops")
        static let environment = Config.value("QB_ENVIRONMENT", fallback: "sandbox") // sandbox or production
        // Required for invoice line item creation in QBO. Set to a valid Sales Item ID in your company.
        static let defaultSalesItemRef = Config.value("QB_DEFAULT_ITEM_REF", fallback: "1")
        
        // OAuth 2.0 endpoints for QuickBooks Online
        static let authorizationEndpoint = "https://appcenter.intuit.com/connect/oauth2" // Authorization endpoint URL
        static let tokenEndpoint = "https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer" // Token exchange endpoint URL
    }
    struct Google {
        // Prefer env overrides for local/dev workflows.
        static let clientID = Config.value("GOOGLE_CLIENT_ID", fallback: "YOUR_GOOGLE_CLIENT_ID")
        static let clientSecret = Config.value("GOOGLE_CLIENT_SECRET", fallback: "YOUR_GOOGLE_CLIENT_SECRET")
        static let redirectURI = Config.value("GOOGLE_REDIRECT_URI", fallback: "YOUR_GOOGLE_REDIRECT_URI")
        // Optional callback scheme for ASWebAuthenticationSession when using an HTTPS redirect bridge.
        static let callbackScheme = Config.value("GOOGLE_CALLBACK_SCHEME", fallback: "gunnaireops")
        static let allowedHostedDomain = Config.value("GOOGLE_ALLOWED_HOSTED_DOMAIN", fallback: "gunnaire.com")
        
        // Keep scopes minimal for OAuth policy compliance during development/testing.
        // Add broader scopes only after Google app verification if required.
        static let scopes = [
            "openid",
            "profile",
            "email",
            "https://www.googleapis.com/auth/calendar"
        ]
        
        // OAuth 2.0 endpoints for Google
        static let authorizationEndpoint = "https://accounts.google.com/o/oauth2/v2/auth" // Authorization endpoint URL
        static let tokenEndpoint = "https://oauth2.googleapis.com/token"                  // Token exchange endpoint URL
        
        // Note: PKCE (Proof Key for Code Exchange) is recommended for native and mobile apps for enhanced security.
    }
}
