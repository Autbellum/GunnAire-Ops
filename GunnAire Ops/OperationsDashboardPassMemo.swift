import Foundation

/// Remembers values for the duration of one SwiftUI body pass.
///
/// Command Center's body reads its role-filtered collections and the
/// reductions over them dozens of times per pass: `dashboardPayments` alone is
/// read by every invoice balance, which the open-invoice sort evaluates once
/// per comparison. Each read used to re-run the whole access policy (about
/// thirteen role checks) and walk every payment's relationships again. On the
/// owner's iPad that was the main-thread stack in every watchdog crash of
/// 2026-09-19. Reading through this memo computes each value once per pass.
///
/// The view clears the memo at the top of `body`, so a value never outlives
/// the pass whose inputs produced it; anything read after the pass (a sheet's
/// content, a button action) sees the last pass's value, which is the value
/// currently on screen.
///
/// Not observable on purpose: filling it must never invalidate the view.
@MainActor
final class OperationsDashboardPassMemo {
    private var values: [String: Any] = [:]
    private(set) var passCount = 0
    private(set) var computeCount = 0

    /// Returns the value stored under `key` for this pass, computing and
    /// storing it on the first read. `key` identifies the getter; `T` must be
    /// a non-optional type so a stored value is always distinguishable from
    /// an absent one.
    func value<T>(_ key: String, compute: () -> T) -> T {
        if let cached = values[key] as? T {
            return cached
        }
        computeCount += 1
        let computed = compute()
        values[key] = computed
        return computed
    }

    /// Starts a new pass. Every subsequent read recomputes once.
    func clear() {
        values.removeAll(keepingCapacity: true)
        passCount += 1
    }
}
