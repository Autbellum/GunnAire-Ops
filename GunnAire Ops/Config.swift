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
        // Prefer env / Info.plist overrides for local and CI workflows. Production is the app default;
        // use QB_ENVIRONMENT=sandbox only for an intentional Intuit sandbox test build.
        static let clientID = Config.value("QB_CLIENT_ID", fallback: "YOUR_CLIENT_ID")
        static let clientSecret = Config.value("QB_CLIENT_SECRET", fallback: "YOUR_CLIENT_SECRET")
        static let redirectURI = Config.value("QB_REDIRECT_URI", fallback: "YOUR_REDIRECT_URI")
        // ASWebAuthenticationSession callback scheme. For production, use an HTTPS Intuit redirect URI
        // that forwards back into this custom scheme after your backend exchanges / validates the callback.
        static let callbackScheme = Config.value("QB_CALLBACK_SCHEME", fallback: "gunnaireops")
        private static let configuredEnvironment = Config.value("QB_ENVIRONMENT", fallback: "production")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        static let environment = configuredEnvironment == "sandbox" ? "sandbox" : "production"

        // Required QBO references. These must be IDs from the same connected company / realm.
        static let defaultSalesItemRef = Config.value("QB_DEFAULT_ITEM_REF", fallback: "")
        static let defaultIncomeAccountRef = Config.value("QB_DEFAULT_INCOME_ACCOUNT_REF", fallback: "")
        static let defaultExpenseAccountRef = Config.value("QB_DEFAULT_EXPENSE_ACCOUNT_REF", fallback: "")
        private static func looksExplicitQuickBooksValue(_ key: String) -> Bool {
            guard let value = Config.optionalValue(key) else { return false }
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty else { return false }
            guard !normalized.contains("$(") else { return false }
            guard !normalized.hasPrefix("your_") && !normalized.hasPrefix("your-") else { return false }
            guard !normalized.hasPrefix("placeholder") && !normalized.contains("placeholder") else { return false }
            return true
        }

        static let hasExplicitDefaultSalesItemRef = looksExplicitQuickBooksValue("QB_DEFAULT_ITEM_REF")
        static let hasExplicitDefaultIncomeAccountRef = looksExplicitQuickBooksValue("QB_DEFAULT_INCOME_ACCOUNT_REF")
        static let hasExplicitDefaultExpenseAccountRef = looksExplicitQuickBooksValue("QB_DEFAULT_EXPENSE_ACCOUNT_REF")

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
            accountingOAuthScopes
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
            if configuredEnvironment != "production" && configuredEnvironment != "sandbox" {
                warnings.append("QB_ENVIRONMENT was '\(configuredEnvironment)'. The app is using production; set it to production or sandbox explicitly.")
            }
            if !hasExplicitDefaultSalesItemRef {
                warnings.append("Set QB_DEFAULT_ITEM_REF to a valid QBO Service/NonInventory Item.Id for generic fallback items and refund receipts.")
            }
            if !hasExplicitDefaultIncomeAccountRef {
                warnings.append("Set QB_DEFAULT_INCOME_ACCOUNT_REF to a valid QBO income Account.Id, or sync catalog items so the app can reuse the income account from your default QBO item.")
            }
            if !hasExplicitDefaultExpenseAccountRef {
                warnings.append("Set QB_DEFAULT_EXPENSE_ACCOUNT_REF before creating bills or expense purchases.")
            }
            if enablePaymentsScope {
                warnings.append("QuickBooks Payments features are enabled, but Accounting login stays Accounting-only so Payments authorization failures do not break core QBO sync.")
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
        static let enabled = value("QB_TIME_ACTIVITY_SYNC_ENABLED", fallback: "false").lowercased() == "true"
        static let nameOf = value("QB_TIME_ACTIVITY_NAME_OF", fallback: "Employee")
        static let entityRef = value("QB_TIME_ACTIVITY_ENTITY_REF", fallback: "")
        static let itemRef = value("QB_TIME_ACTIVITY_ITEM_REF", fallback: "")
        static let payrollItemRef = value("QB_TIME_ACTIVITY_PAYROLL_ITEM_REF", fallback: "")
        static let projectRef = value("QB_TIME_ACTIVITY_PROJECT_REF", fallback: "")
        static let graphqlEndpoint = "https://qb.api.intuit.com/graphql"
        static let accountingResource = "TimeActivity"
        static let accountingOperations = "Query, Create, Update, Delete"
        static let requiredAccountingScope = QuickBooks.accountingScope
        static let payrollCompensationScope = "payroll.compensation.read"
        static let notes = "QBO Accounting TimeActivity records completed time only. Live clock-in/out stays local until clock-out creates a duration-based TimeActivity. PayrollItemRef requires QuickBooks Workforce/Payroll compensation access."

        static var normalizedNameOf: String {
            nameOf.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "vendor" ? "Vendor" : "Employee"
        }

        static var isConfiguredForSync: Bool {
            enabled && !entityRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
