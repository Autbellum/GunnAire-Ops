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

    struct QuickBooks {
        // Prefer env / Info.plist overrides for local and CI workflows.
        // Keep the sandbox as the default so a missing QB_ENVIRONMENT never sends test traffic to production.
        static let clientID = Config.value("QB_CLIENT_ID", fallback: "YOUR_CLIENT_ID")
        static let clientSecret = Config.value("QB_CLIENT_SECRET", fallback: "YOUR_CLIENT_SECRET")
        static let redirectURI = Config.value("QB_REDIRECT_URI", fallback: "YOUR_REDIRECT_URI")
        // ASWebAuthenticationSession callback scheme. For production, use an HTTPS Intuit redirect URI
        // that forwards back into this custom scheme after your backend exchanges / validates the callback.
        static let callbackScheme = Config.value("QB_CALLBACK_SCHEME", fallback: "gunnaireops")
        static let environment = Config.value("QB_ENVIRONMENT", fallback: "sandbox").lowercased() // sandbox or production

        // Required QBO references. These must be IDs from the same connected company / realm.
        static let defaultSalesItemRef = Config.value("QB_DEFAULT_ITEM_REF", fallback: "")
        static let defaultIncomeAccountRef = Config.value("QB_DEFAULT_INCOME_ACCOUNT_REF", fallback: "")
        static let defaultExpenseAccountRef = Config.value("QB_DEFAULT_EXPENSE_ACCOUNT_REF", fallback: "")
        static let hasExplicitDefaultSalesItemRef = Config.optionalValue("QB_DEFAULT_ITEM_REF") != nil
        static let hasExplicitDefaultIncomeAccountRef = Config.optionalValue("QB_DEFAULT_INCOME_ACCOUNT_REF") != nil
        static let hasExplicitDefaultExpenseAccountRef = Config.optionalValue("QB_DEFAULT_EXPENSE_ACCOUNT_REF") != nil

        // Enable only when the app is approved for QuickBooks Payments and users reconnect after scope changes.
        static let enablePaymentsScope = Config.value("QB_ENABLE_PAYMENTS_SCOPE", fallback: "true").lowercased() != "false"
        static let maxConcurrentSyncRequests = max(1, Int(Config.value("QB_MAX_CONCURRENT_SYNC_REQUESTS", fallback: "3")) ?? 3)
        static let maxRetryAttempts = max(0, Int(Config.value("QB_MAX_RETRY_ATTEMPTS", fallback: "3")) ?? 3)
        static let requestTimeoutSeconds = max(15, Double(Config.value("QB_REQUEST_TIMEOUT_SECONDS", fallback: "45")) ?? 45)

        static let accountingScope = "com.intuit.quickbooks.accounting"
        static let paymentsScope = "com.intuit.quickbooks.payment"
        static var oauthScopes: [String] {
            var scopes = [accountingScope, "openid", "profile", "email", "phone", "address"]
            if enablePaymentsScope { scopes.append(paymentsScope) }
            return scopes
        }

        // OAuth 2.0 endpoints for QuickBooks Online.
        static let authorizationEndpoint = "https://appcenter.intuit.com/connect/oauth2"
        static let tokenEndpoint = "https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer"

        static var isSandbox: Bool { environment == "sandbox" }
        static var isProduction: Bool { environment == "production" }
        static var redirectURIIsHTTPS: Bool { URL(string: redirectURI)?.scheme?.lowercased() == "https" }
        static var redirectURIIsPlaceholder: Bool { redirectURI.hasPrefix("YOUR_") || redirectURI.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        static var clientIDIsPlaceholder: Bool { clientID.hasPrefix("YOUR_") || clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        static var clientSecretIsPlaceholder: Bool { clientSecret.hasPrefix("YOUR_") || clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        static var isConfigured: Bool {
            !clientIDIsPlaceholder &&
            !clientSecretIsPlaceholder &&
            !redirectURIIsPlaceholder &&
            (isSandbox || redirectURIIsHTTPS)
        }

        static var configurationWarnings: [String] {
            var warnings: [String] = []
            if isProduction && !redirectURIIsHTTPS {
                warnings.append("Production QuickBooks redirect URIs must be HTTPS and must exactly match the Intuit Developer Portal entry.")
            }
            if !hasExplicitDefaultSalesItemRef {
                warnings.append("Set QB_DEFAULT_ITEM_REF to a valid QBO Service/NonInventory Item.Id before creating estimates, invoices, or refund receipts.")
            }
            if !hasExplicitDefaultIncomeAccountRef {
                warnings.append("Set QB_DEFAULT_INCOME_ACCOUNT_REF to a valid QBO income Account.Id before creating catalog items.")
            }
            if !hasExplicitDefaultExpenseAccountRef {
                warnings.append("Set QB_DEFAULT_EXPENSE_ACCOUNT_REF before creating bills or expense purchases.")
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
