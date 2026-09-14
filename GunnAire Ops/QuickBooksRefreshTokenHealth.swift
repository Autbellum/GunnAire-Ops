import Foundation

/// The QuickBooks refresh token and its actual expiry live entirely on the
/// backend (Intuit's ~100-day rotating refresh token never reaches this
/// device — see `GunnAireBackendService.exchangeQuickBooksAuthorizationCode`).
/// This tracks the best client-only proxy available: the date of the most
/// recent successful token exchange/refresh. A successful refresh proves the
/// refresh token was valid at that moment, so a long gap since the last one
/// is a reasonable signal to prompt reconnection before a failure forces it.
enum QuickBooksRefreshTokenHealth {
    private static let lastSuccessKey = "GunnAireQuickBooksLastSuccessfulTokenRefreshAt"
    /// Buffer before Intuit's ~100-day refresh-token window so staff see a
    /// warning while there's still time to reconnect calmly.
    static let staleWarningThreshold: TimeInterval = 85 * 24 * 60 * 60

    static func recordSuccess(at date: Date = Date(), defaults: UserDefaults = .standard) {
        defaults.set(date, forKey: lastSuccessKey)
    }

    static func lastSuccessfulRefresh(defaults: UserDefaults = .standard) -> Date? {
        defaults.object(forKey: lastSuccessKey) as? Date
    }

    static func isStale(now: Date = Date(), defaults: UserDefaults = .standard) -> Bool {
        guard let last = lastSuccessfulRefresh(defaults: defaults) else { return false }
        return now.timeIntervalSince(last) > staleWarningThreshold
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: lastSuccessKey)
    }
}
