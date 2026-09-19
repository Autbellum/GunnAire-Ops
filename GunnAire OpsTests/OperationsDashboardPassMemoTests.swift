import Foundation
import Testing
@testable import GunnAire_Ops

/// The memo exists so one body pass computes each dashboard collection once.
/// These pin the two properties that make it safe: repeated reads within a
/// pass never recompute, and a cleared pass always does.
@MainActor
struct OperationsDashboardPassMemoTests {
    @Test func aValueIsComputedOncePerPassNoMatterHowOftenItIsRead() {
        let memo = OperationsDashboardPassMemo()
        var computations = 0
        for _ in 0..<50 {
            let value = memo.value("invoices") { computations += 1; return [1, 2, 3] }
            #expect(value == [1, 2, 3])
        }
        #expect(computations == 1)
        #expect(memo.computeCount == 1)
    }

    @Test func distinctKeysAreIndependent() {
        let memo = OperationsDashboardPassMemo()
        let invoices = memo.value("invoices") { [10] }
        let payments = memo.value("payments") { [20, 30] }
        #expect(invoices == [10])
        #expect(payments == [20, 30])
        #expect(memo.computeCount == 2)
    }

    @Test func clearingStartsANewPassThatRecomputes() {
        let memo = OperationsDashboardPassMemo()
        var generation = 0
        let first = memo.value("balances") { generation += 1; return [UUID(): Double(generation)] }
        memo.clear()
        let second = memo.value("balances") { generation += 1; return [UUID(): Double(generation)] }
        #expect(first.values.first == 1)
        #expect(second.values.first == 2)
        #expect(memo.passCount == 1)
        #expect(memo.computeCount == 2)
    }

    /// A key reused with a different type must not hand back the wrong
    /// value; it recomputes under the requested type instead.
    @Test func aTypeMismatchRecomputesRatherThanReturningTheStoredValue() {
        let memo = OperationsDashboardPassMemo()
        _ = memo.value("count") { 3 }
        let text = memo.value("count") { "three" }
        #expect(text == "three")
    }
}
