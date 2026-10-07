import Foundation
import Testing
@testable import GunnAire_Ops

/// A refused progress invoice used to leave Job Documentation unchanged, with
/// no surface for the message its revalidation had already written. These pin
/// the selection that names the cause - and, more importantly, that it keeps
/// the original short-circuit, because the later checks read records that only
/// the earlier identity checks make safe to touch.
@MainActor
struct ProgressInvoiceChangeAuditTests {
    private typealias Check = ProgressInvoiceChangeAudit.Check

    @Test func everyCheckHoldingReportsNoChange() {
        var evaluated = 0
        let result = ProgressInvoiceChangeAudit.firstChange(in: (0..<5).map { index in
            Check("check \(index)") { evaluated += 1; return true }
        })
        #expect(result == nil)
        #expect(evaluated == 5)
    }

    @Test func theFirstFailingCheckIsTheOneReported() {
        let result = ProgressInvoiceChangeAudit.firstChange(in: [
            Check("the open job") { true },
            Check("the job customer") { false },
            Check("the approved milestone allocation") { false }
        ])
        #expect(result == "the job customer")
    }

    @Test func noCheckAfterTheFailureIsEvaluated() {
        var touchedLaterCheck = false
        var evaluated: [String] = []
        let result = ProgressInvoiceChangeAudit.firstChange(in: [
            Check("the open job") { evaluated.append("job"); return true },
            Check("the job record") { evaluated.append("record"); return false },
            Check("the job customer") {
                // Reading a rejected record is exactly what the order prevents.
                touchedLaterCheck = true
                evaluated.append("customer")
                return true
            }
        ])
        #expect(result == "the job record")
        #expect(!touchedLaterCheck)
        #expect(evaluated == ["job", "record"])
    }

    @Test func anEmptyCheckListReportsNoChange() {
        #expect(ProgressInvoiceChangeAudit.firstChange(in: []) == nil)
    }

    /// A check is only ever asked once, so a caller may use a check whose
    /// evaluation is expensive - the allocation re-derivation is.
    @Test func eachCheckIsAskedOnce() {
        var counts: [String: Int] = [:]
        _ = ProgressInvoiceChangeAudit.firstChange(in: ["a", "b", "c"].map { name in
            Check(name) { counts[name, default: 0] += 1; return true }
        })
        #expect(counts == ["a": 1, "b": 1, "c": 1])
    }
}
