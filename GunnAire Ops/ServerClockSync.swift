import Foundation

/// Tracks how far this device's clock has drifted from the backend's clock,
/// using the standard HTTP `Date` response header already present on every
/// backend response — no dedicated endpoint or extra network traffic needed.
/// Fed from the single request choke point in `GunnAireBackendService`, so it
/// stays fresh as a side effect of normal app usage.
@MainActor
final class ServerClockSync {
    static let shared = ServerClockSync()

    private init() {}

    /// Positive means the device clock is ahead of the server; negative means
    /// it's behind. Nil until at least one backend response has been observed.
    private(set) var lastKnownOffsetSeconds: Double?

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    func record(from response: HTTPURLResponse, deviceNow: Date = Date()) {
        guard let rawDate = (response.allHeaderFields["Date"] as? String)
            ?? (response.allHeaderFields["date"] as? String),
            let serverDate = Self.dateFormatter.date(from: rawDate) else { return }
        lastKnownOffsetSeconds = deviceNow.timeIntervalSince(serverDate)
    }

    #if DEBUG
    func resetForTesting() {
        lastKnownOffsetSeconds = nil
    }
    #endif
}
