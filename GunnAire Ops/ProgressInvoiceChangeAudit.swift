import Foundation

/// A progress invoice revalidates the job, estimate, milestone and allocation
/// after its first-save await, and refuses to continue if any of them moved.
/// That refusal used to be indistinguishable from the invoice silently never
/// appearing, so this names the first check that failed.
///
/// The checks are deferred and evaluated strictly in order, stopping at the
/// first failure, because the later ones read properties that only the earlier
/// identity checks make safe to touch. Evaluating them all to collect every
/// failure would read a record the identity check just rejected.
enum ProgressInvoiceChangeAudit {
    struct Check {
        /// Names what moved, in the words the operator sees.
        let subject: String
        let holds: () -> Bool

        init(_ subject: String, _ holds: @escaping () -> Bool) {
            self.subject = subject
            self.holds = holds
        }
    }

    /// The first check that does not hold, or `nil` when every one holds. A
    /// caller must treat any non-nil answer as a refusal: this reports which
    /// check failed, it never decides whether to proceed.
    static func firstChange(in checks: [Check]) -> String? {
        for check in checks where !check.holds() { return check.subject }
        return nil
    }
}
