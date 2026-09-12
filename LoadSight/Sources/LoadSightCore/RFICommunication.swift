import Foundation

/// Supplied routing and planning facts, never inferred from the editor's identity or today's date.
public struct RFICommunication: Codable, Equatable, Sendable {
    public var to: String
    public var from: String
    public var date: String
    public var requiredResponseDate: String
    public var suggestedResolution: String
    public static let fields: [(id: String, label: String)] = [
        ("to", "To"), ("from", "From"), ("date", "Request date"),
        ("requiredResponseDate", "Required response date"), ("suggestedResolution", "Suggested resolution")
    ]
    public init(to: String = "", from: String = "", date: String = "", requiredResponseDate: String = "", suggestedResolution: String = "") {
        self.to = to; self.from = from; self.date = date
        self.requiredResponseDate = requiredResponseDate; self.suggestedResolution = suggestedResolution
    }
    public var values: [String: String] {
        ["to": to, "from": from, "date": date, "requiredResponseDate": requiredResponseDate, "suggestedResolution": suggestedResolution]
    }
    public func validate() throws {
        for (label, text) in [("Request date", date), ("Required response date", requiredResponseDate)] where !text.isEmpty {
            let parts = text.split(separator: "-", omittingEmptySubsequences: false)
            try require(parts.count == 3 && parts.map(\.count) == [4, 2, 2] && parts.allSatisfy { $0.utf8.allSatisfy { (48...57).contains($0) } }, "\(label) must be blank or YYYY-MM-DD.")
            let year = Int(parts[0])!, month = Int(parts[1])!, day = Int(parts[2])!
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let components = DateComponents(year: year, month: month, day: day)
            guard (1...9999).contains(year), let instant = calendar.date(from: components) else { throw LoadSightError.invalid("\(label) is not a valid calendar date.") }
            let actual = calendar.dateComponents([.year, .month, .day], from: instant)
            try require(actual.year == year && actual.month == month && actual.day == day, "\(label) is not a valid calendar date.")
        }
    }
}
