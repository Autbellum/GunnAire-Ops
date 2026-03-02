// Config.swift
// Central location for all API keys, tokens, and secrets
// -- FILL OUT WITH YOUR APP'S INFORMATION --
import Foundation

struct Config {
    struct QuickBooks {
        // Prefer env overrides for local/dev workflows.
        static let clientID = ProcessInfo.processInfo.environment["QB_CLIENT_ID"] ?? "YOUR_CLIENT_ID"
        static let clientSecret = ProcessInfo.processInfo.environment["QB_CLIENT_SECRET"] ?? "YOUR_CLIENT_SECRET"
        static let redirectURI = ProcessInfo.processInfo.environment["QB_REDIRECT_URI"] ?? "YOUR_REDIRECT_URI"
        static let environment = ProcessInfo.processInfo.environment["QB_ENVIRONMENT"] ?? "sandbox" // sandbox or production
        
        // OAuth 2.0 endpoints for QuickBooks Online
        static let authorizationEndpoint = "https://appcenter.intuit.com/connect/oauth2" // Authorization endpoint URL
        static let tokenEndpoint = "https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer" // Token exchange endpoint URL
    }
    struct Google {
        // Prefer env overrides for local/dev workflows.
        static let clientID = ProcessInfo.processInfo.environment["GOOGLE_CLIENT_ID"] ?? "YOUR_GOOGLE_CLIENT_ID"
        static let clientSecret = ProcessInfo.processInfo.environment["GOOGLE_CLIENT_SECRET"] ?? "YOUR_GOOGLE_CLIENT_SECRET"
        static let redirectURI = ProcessInfo.processInfo.environment["GOOGLE_REDIRECT_URI"] ?? "YOUR_GOOGLE_REDIRECT_URI"
        
        // Most common and useful Google OAuth scopes for email, profile, calendar, and cloud services.
        // For more scopes, visit: https://developers.google.com/identity/protocols/oauth2/scopes
        static let scopes = [
            "openid",                                   // OpenID Connect scope for user identity
            "profile",                                  // Access to basic profile info
            "email",                                    // Access to user's email address
            "https://www.googleapis.com/auth/userinfo.email",       // Read user's email address
            "https://www.googleapis.com/auth/bigquery",              // Manage BigQuery data
            "https://www.googleapis.com/auth/trace.readonly",       // Read Trace data
            "https://www.googleapis.com/auth/trace.append",         // Append Trace data
            "https://www.googleapis.com/auth/iam.test",              // Test IAM permissions
            "https://www.googleapis.com/auth/logging.admin",         // Administer Logs
            "https://www.googleapis.com/auth/calendar",              // Full access to user's calendar
            "https://www.googleapis.com/auth/calendar.acls",         // Manage calendar ACLs
            "https://www.googleapis.com/auth/calendar.app.created",  // Manage calendars created by the app
            "https://www.googleapis.com/auth/calendar.calendarlist", // Manage calendar list
            "https://www.googleapis.com/auth/calendar.calendars"     // Manage calendars
        ]
        
        // OAuth 2.0 endpoints for Google
        static let authorizationEndpoint = "https://accounts.google.com/o/oauth2/v2/auth" // Authorization endpoint URL
        static let tokenEndpoint = "https://oauth2.googleapis.com/token"                  // Token exchange endpoint URL
        
        // Note: PKCE (Proof Key for Code Exchange) is recommended for native and mobile apps for enhanced security.
    }
}
