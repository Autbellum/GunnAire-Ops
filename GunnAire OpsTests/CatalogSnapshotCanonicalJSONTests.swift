import Foundation
import Testing
@testable import GunnAire_Ops

/// A progress invoice re-derives its milestone allocation after the first-save
/// await and refuses if it changed. Comparing raw strings rejected an unchanged
/// allocation, because its producers had disagreed on key order. These pin that
/// only key order is forgiven - never content, and never a missing or malformed
/// snapshot.
struct CatalogSnapshotCanonicalJSONTests {
    /// The historical failure, kept as the regression example: the same document
    /// in declaration order and in sorted order, as the two producers emitted it
    /// before 2026100119. Raw comparison rejects it; canonical accepts it. The
    /// literals are fixed here so this holds whatever the encoder does later.
    @Test func keyOrderAloneIsNotAChange() throws {
        let declarationOrder = #"{"version":1,"lines":[{"name":"Labor","quantity":2}],"discount":null}"#
        let sortedOrder = #"{"discount":null,"lines":[{"quantity":2,"name":"Labor"}],"version":1}"#
        #expect(declarationOrder != sortedOrder)
        #expect(CatalogSnapshotCanonicalJSON.describesSameSnapshot(declarationOrder, sortedOrder))
    }

    @Test func anyRealDifferenceIsStillAChange() {
        let original = #"{"version":1,"lines":[{"name":"Labor","quantity":2}]}"#
        let quantity = #"{"version":1,"lines":[{"name":"Labor","quantity":3}]}"#
        let name = #"{"version":1,"lines":[{"name":"Parts","quantity":2}]}"#
        let extraLine = #"{"version":1,"lines":[{"name":"Labor","quantity":2},{"name":"Parts","quantity":1}]}"#
        let reorderedLines = #"{"version":1,"lines":[{"name":"Parts","quantity":1},{"name":"Labor","quantity":2}]}"#
        for changed in [quantity, name, extraLine] {
            #expect(!CatalogSnapshotCanonicalJSON.describesSameSnapshot(original, changed))
        }
        // Line order is meaning, not formatting: only object keys are sorted.
        #expect(!CatalogSnapshotCanonicalJSON.describesSameSnapshot(extraLine, reorderedLines))
    }

    /// An unknown key is snapshot metadata a later build may rely on, so it is
    /// compared too - this is what comparing canonical bytes buys over
    /// comparing only the fields this build decodes.
    @Test func metadataThisBuildDoesNotInterpretIsStillCompared() {
        let withMetadata = #"{"version":1,"lines":[],"taxAddresses":{"zip":"30601"}}"#
        let without = #"{"version":1,"lines":[]}"#
        let changedMetadata = #"{"version":1,"lines":[],"taxAddresses":{"zip":"30602"}}"#
        #expect(!CatalogSnapshotCanonicalJSON.describesSameSnapshot(withMetadata, without))
        #expect(!CatalogSnapshotCanonicalJSON.describesSameSnapshot(withMetadata, changedMetadata))
        #expect(CatalogSnapshotCanonicalJSON.describesSameSnapshot(
            withMetadata, #"{"taxAddresses":{"zip":"30601"},"lines":[],"version":1}"#))
    }

    /// Absence of proof is a refusal, not a match. Note the deliberate
    /// exception: identical text is unchanged by definition, so two byte-equal
    /// strings match even when neither is valid JSON. The question here is
    /// whether a snapshot changed, not whether it parses - validity is enforced
    /// by `CatalogSnapshotPayload.read` and by the derivation that produced it.
    @Test func missingSnapshotsNeverMatchAndIdenticalTextAlwaysDoes() {
        let valid = #"{"version":1,"lines":[]}"#
        #expect(!CatalogSnapshotCanonicalJSON.describesSameSnapshot(nil, valid))
        #expect(!CatalogSnapshotCanonicalJSON.describesSameSnapshot(valid, nil))
        #expect(!CatalogSnapshotCanonicalJSON.describesSameSnapshot(nil, nil))
        // Two different malformed strings cannot be proven unchanged.
        #expect(!CatalogSnapshotCanonicalJSON.describesSameSnapshot("{not json", "{also not json"))
        #expect(!CatalogSnapshotCanonicalJSON.describesSameSnapshot("", valid))
        // Byte-equal, so unchanged, parser or no parser.
        #expect(CatalogSnapshotCanonicalJSON.describesSameSnapshot("{not json", "{not json"))
        #expect(CatalogSnapshotCanonicalJSON.describesSameSnapshot("", ""))
        #expect(CatalogSnapshotCanonicalJSON.canonical("{not json") == nil)
        #expect(CatalogSnapshotCanonicalJSON.canonical(nil) == nil)
    }

    /// The tax-address attachment re-serializes the whole document, which
    /// rewrites 199.95 as 199.94999999999999. That is the same price, so it must
    /// not read as a change - this is what keeps a taxed document saveable.
    @Test func numericRespellingIsNotAChangeButADifferentPriceIs() {
        let authored = #"{"version":1,"lines":[{"name":"Labor","unitPrice":199.95}]}"#
        let respelled = #"{"version":1,"lines":[{"name":"Labor","unitPrice":199.94999999999999}]}"#
        #expect(authored != respelled)
        #expect(CatalogSnapshotCanonicalJSON.describesSameSnapshot(authored, respelled))
        for spelling in [#"{"version":1,"lines":[{"name":"Labor","unitPrice":199.950}]}"#,
                         #"{"version":1,"lines":[{"name":"Labor","unitPrice":1.9995e2}]}"#] {
            #expect(CatalogSnapshotCanonicalJSON.describesSameSnapshot(authored, spelling))
        }
        // A cent is a change.
        #expect(!CatalogSnapshotCanonicalJSON.describesSameSnapshot(
            authored, #"{"version":1,"lines":[{"name":"Labor","unitPrice":199.96}]}"#))
    }

    /// Re-serializing alone keeps one value of a duplicate key and discards the
    /// other, so the strict parser has to reject the document first. The escaped
    /// form decodes to a key already present and must be refused the same way.
    @Test func duplicateObjectKeysAreRefusedRatherThanCollapsed() {
        let kept = #"{"version":1,"quantity":2,"quantity":9}"#
        let differsOnlyInTheDiscardedValue = #"{"version":1,"quantity":2,"quantity":8}"#
        #expect(kept != differsOnlyInTheDiscardedValue)
        #expect(!CatalogSnapshotCanonicalJSON.describesSameSnapshot(
            kept, differsOnlyInTheDiscardedValue))
        #expect(CatalogSnapshotCanonicalJSON.canonical(kept) == nil)

        let escaped = #"{"version":1,"quantity":1,"\u0071uantity":2}"#
        #expect(CatalogSnapshotCanonicalJSON.canonical(escaped) == nil)
        #expect(!CatalogSnapshotCanonicalJSON.describesSameSnapshot(
            escaped, #"{"version":1,"quantity":1}"#))
        #expect(!CatalogSnapshotCanonicalJSON.describesSameSnapshot(
            #"{"version":1,"quantity":1}"#, escaped))
    }

    /// A bare line array is the no-discount branch; it must canonicalize too.
    @Test func aTopLevelArrayCanonicalizes() throws {
        let a = #"[{"name":"Labor","quantity":2}]"#
        let b = #"[{"quantity":2,"name":"Labor"}]"#
        #expect(a != b)
        #expect(CatalogSnapshotCanonicalJSON.describesSameSnapshot(a, b))
        #expect(!CatalogSnapshotCanonicalJSON.describesSameSnapshot(a, #"[{"name":"Labor","quantity":2},{}]"#))
    }

    /// The composer's own comparison, now strict. `createDocument` already
    /// requires lines, so an absent snapshot means the encoding or the
    /// tax-address attachment failed, and it refuses before touching a customer
    /// rather than saving a billing document with no line provenance. These pin
    /// that absence is never mistaken for "unchanged" at either end.
    @Test func theComposerComparisonForgivesOnlyKeyOrder() {
        let declarationOrder = #"{"version":1,"lines":[{"name":"Labor","quantity":2}]}"#
        let sortedOrder = #"{"lines":[{"quantity":2,"name":"Labor"}],"version":1}"#
        #expect(declarationOrder != sortedOrder)
        #expect(CatalogSnapshotCanonicalJSON.describesSameSnapshot(declarationOrder, sortedOrder))

        // Absence is a refusal at either end, and absence on both ends too:
        // nothing may stand in for a snapshot that was never built.
        #expect(!CatalogSnapshotCanonicalJSON.describesSameSnapshot(nil, nil))
        #expect(!CatalogSnapshotCanonicalJSON.describesSameSnapshot(nil, declarationOrder))
        #expect(!CatalogSnapshotCanonicalJSON.describesSameSnapshot(declarationOrder, nil))

        // Content and metadata keep their original strictness.
        #expect(!CatalogSnapshotCanonicalJSON.describesSameSnapshot(
            declarationOrder, #"{"version":1,"lines":[{"name":"Labor","quantity":3}]}"#))
        #expect(!CatalogSnapshotCanonicalJSON.describesSameSnapshot(
            declarationOrder, #"{"version":1,"lines":[{"name":"Labor","quantity":2}],"taxAddresses":{}}"#))
        #expect(!CatalogSnapshotCanonicalJSON.describesSameSnapshot("{not json", "{still not json"))
    }

    /// The bounded parser refuses input past 1 MiB, the same bound
    /// `CatalogSnapshotPayload.read` enforces for published records. A snapshot
    /// that large therefore has no canonical form, so two differing ones are
    /// refused rather than compared - fail closed, and no worse than the raw
    /// comparison this replaced. A 750-row document measures about 320 KB, so
    /// this is a documented ceiling rather than a reachable one.
    @Test func snapshotsPastTheParserBoundAreRefusedRatherThanCompared() {
        let filler = String(repeating: "x", count: 1_100_000)
        let oversize = #"{"version":1,"lines":[{"name":""# + filler + #"","unitPrice":1}]}"#
        #expect(oversize.utf8.count > 1_048_576)
        #expect(CatalogSnapshotCanonicalJSON.canonical(oversize) == nil)
        let oversizeChanged = #"{"version":1,"lines":[{"name":""# + filler + #"","unitPrice":2}]}"#
        #expect(!CatalogSnapshotCanonicalJSON.describesSameSnapshot(oversize, oversizeChanged))
        // Identical text is still unchanged without consulting the parser.
        #expect(CatalogSnapshotCanonicalJSON.describesSameSnapshot(oversize, oversize))
    }

    /// The real producer, as the app calls it: whatever key order the current
    /// encoder happens to use, an identical re-encode matches and a changed
    /// quantity does not.
    @Test func theRealProducersAgreeWithThemselves() throws {
        let item = Item(quickBooksID: "42", name: "Original labor", unitPrice: 125)
        let line = CatalogLineItemSnapshot(item: item, quantity: 2)
        let encoded = try #require(CatalogLineItemSnapshot.encoded(snapshots: [line]))
        let again = try #require(CatalogLineItemSnapshot.encoded(snapshots: [line]))
        #expect(CatalogSnapshotCanonicalJSON.describesSameSnapshot(encoded, again))
        let other = try #require(CatalogLineItemSnapshot.encoded(
            snapshots: [CatalogLineItemSnapshot(item: item, quantity: 3)]))
        #expect(!CatalogSnapshotCanonicalJSON.describesSameSnapshot(encoded, other))
    }
}
