import Foundation

/// A saved catalog snapshot has more than one producer, and they have not
/// always agreed on key order. `BillingTaxAddressContext.attaching` has always
/// re-serialized the whole document with sorted keys; before build 2026100119,
/// `CatalogLineItemSnapshot.encoded` wrote its properties in declaration order.
/// A revalidation that compares raw strings therefore rejected an allocation
/// that had not changed, which is how a progress invoice came to refuse itself
/// after its own first-save await. `encoded` now sorts its keys too, so that
/// particular pair agrees again - but key order is a property of whichever
/// encoder each producer happens to use, and comparing raw bytes makes every
/// such revalidation depend on them never diverging again.
///
/// Canonicalizing re-serializes with sorted keys recursively. That normalizes
/// key order and nothing else: every key survives, including snapshot metadata
/// this build does not interpret, so comparing canonical forms is byte
/// comparison modulo key order rather than a comparison of the fields we happen
/// to decode today. A string that is not valid JSON has no canonical form and
/// compares equal to nothing, so a malformed or missing snapshot still fails
/// closed.
nonisolated enum CatalogSnapshotCanonicalJSON {
    /// `nil` when the text is absent or is not valid JSON.
    static func canonical(_ json: String?) -> Data? {
        guard let json, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let sorted = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return sorted
    }

    /// True only when both texts are valid JSON describing the same document.
    /// Two absent or two malformed snapshots are never "the same": this answers
    /// whether a snapshot was proven unchanged, so absence of proof is a no.
    static func describesSameSnapshot(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = canonical(lhs), let rhs = canonical(rhs) else { return false }
        return lhs == rhs
    }
}
