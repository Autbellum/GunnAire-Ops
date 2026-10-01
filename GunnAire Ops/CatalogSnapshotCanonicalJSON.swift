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
/// Comparison normalizes key order and equivalent numeric spellings, and
/// nothing else: every key survives, including snapshot metadata this build
/// does not interpret, so this is byte comparison modulo those two rather than a
/// comparison of the fields we happen to decode today.
nonisolated enum CatalogSnapshotCanonicalJSON {
    /// `nil` unless the text is a snapshot this build will compare: the bounded
    /// strict parser rejects malformed input, input past its 1 MiB bound - the
    /// same bound `CatalogSnapshotPayload.read` already enforces for published
    /// records - and duplicate object keys, including escaped equivalents of a
    /// key already present. Only then is it re-serialized with sorted keys.
    ///
    /// Both steps are load bearing. Re-serializing alone would silently keep one
    /// value of a duplicate key and discard the other, so two documents
    /// differing only in the discarded one would compare equal. Parsing alone
    /// would hold numeric text exact, and the tax-address attachment rewrites
    /// `199.95` as `199.94999999999999` when it re-serializes the document, so a
    /// snapshot that had merely been round-tripped would read as changed.
    static func canonical(_ json: String?) -> Data? {
        guard let json,
              (try? FieldFormJSON.parse(json, maximumNodes: 100_000)) != nil,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let sorted = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return sorted
    }

    /// Whether a re-derived snapshot still describes the document that was
    /// captured. Identical text is unchanged by definition and costs nothing to
    /// establish, which is the normal case; anything else has to survive the
    /// parser and then match byte for byte once key order and equivalent numeric
    /// spellings are normalized. An absent snapshot matches nothing, so absence
    /// of proof is a refusal rather than a pass.
    static func describesSameSnapshot(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        if lhs == rhs { return true }
        guard let left = canonical(lhs), let right = canonical(rhs) else { return false }
        return left == right
    }
}
