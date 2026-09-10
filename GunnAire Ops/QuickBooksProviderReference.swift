import Foundation

/// Opaque provider IDs at document, item, payment and link-review boundaries.
/// One whole-string grammar, including reserved-identity rejection, for every caller.
nonisolated enum QuickBooksProviderReference {
    static func isValid(_ value: String) -> Bool {
        ![".", ".."].contains(value) &&
        value.range(of: #"\A[A-Za-z0-9._:-]{1,128}\z"#, options: .regularExpression) != nil
    }
}
