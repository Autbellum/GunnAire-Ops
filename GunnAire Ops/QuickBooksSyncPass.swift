import Foundation

/// What one resource did during a single QuickBooks sync pass.
///
/// `failed` and `notAttempted` are deliberately distinct. A resource that the
/// pass never reached has produced no evidence about the company's books, and
/// reporting it as failed sent the owner looking for a provider problem that
/// did not exist. Sales receipts and deposits run at the end of the pass, so
/// they were the records most often mislabelled this way.
nonisolated enum QuickBooksSyncResourceOutcome: String, Equatable, Sendable {
    case succeeded
    case failed
    /// Deliberately not run, and the pass knows why: stored cards are skipped
    /// when the saved grant carries no payments scope. A known, reported
    /// absence, which is neither a failure nor silence.
    case skipped
    case notAttempted
}

/// Why a pass stopped before every resource had been attempted.
nonisolated enum QuickBooksSyncHalt: String, Equatable, Sendable {
    /// The saved QuickBooks grant was rejected. Every later call would reuse
    /// the same rejected grant, so the pass stops rather than repeating it.
    case reconnectRequired
    /// Cancellation, a lost role or workspace, or shared history refusing this
    /// administrator. The device may still look locally valid, so this is
    /// decided from the error, not from the local access check alone.
    case accessEnded
    /// The accounting connection or the saved history moved under the pass.
    /// Anything read after that could belong to a different company.
    case connectionChanged

    var detail: String {
        switch self {
        case .reconnectRequired:
            "Not attempted. Reconnect QuickBooks in Settings; the sync stopped when the saved QuickBooks session was rejected."
        case .accessEnded:
            "Not attempted. The sync stopped because the company, account, or access for this device changed."
        case .connectionChanged:
            "Not attempted. The sync stopped because the accounting connection or saved history changed. Refresh again."
        }
    }
}

/// The record of one QuickBooks resource sync pass.
///
/// This type holds no provider, context or view state on purpose: the rules it
/// encodes are the ones that decide whether the owner's books may be imported
/// and whether change events may be acknowledged, so they are kept where they
/// can be tested exactly, without a network or a store.
nonisolated struct QuickBooksSyncPass: Equatable, Sendable {
    /// Every resource the pass intends to attempt, in the order it runs them.
    private(set) var order: [String]
    private(set) var outcomes: [String: QuickBooksSyncResourceOutcome] = [:]
    private(set) var halt: QuickBooksSyncHalt?
    /// Resources whose fetch began. One of these interrupted by a halt was
    /// attempted, so it is reported as failed rather than as never attempted.
    private var started: Set<String> = []

    init(order: [String]) {
        self.order = order
    }

    // MARK: - Recording

    mutating func recordAttemptStarted(_ resourceID: String) {
        guard halt == nil else { return }
        started.insert(resourceID)
    }

    mutating func recordSucceeded(_ resourceID: String) {
        guard halt == nil else { return }
        started.insert(resourceID)
        outcomes[resourceID] = .succeeded
    }

    mutating func recordFailed(_ resourceID: String) {
        guard halt == nil else { return }
        started.insert(resourceID)
        outcomes[resourceID] = .failed
    }

    mutating func recordSkipped(_ resourceID: String) {
        guard halt == nil else { return }
        outcomes[resourceID] = .skipped
    }

    /// Ends the pass. Every resource with no outcome yet is settled now: one
    /// whose fetch had begun is reported as failed, and one the pass never
    /// reached is reported as never attempted. A second halt does not
    /// overwrite the first, so the earliest cause is the one reported.
    mutating func recordHalt(_ halt: QuickBooksSyncHalt) {
        guard self.halt == nil else { return }
        self.halt = halt
        for resourceID in order where outcomes[resourceID] == nil {
            outcomes[resourceID] = started.contains(resourceID) ? .failed : .notAttempted
        }
    }

    // MARK: - Decisions

    /// Whether this error ends the pass, and why.
    ///
    /// An ordinary provider failure does not: resources are fetched
    /// independently, so one failing says nothing about the next, and stopping
    /// cost the owner the resources that run last. A pass ends only when
    /// continuing would be unsafe or futile, which is narrower and must be
    /// judged from the error itself. The local access check can still pass
    /// while the backend has already refused this administrator, so shared
    /// history's own access and changed errors are named here explicitly.
    static func haltReason(for error: Error) -> QuickBooksSyncHalt? {
        if error is CancellationError { return .accessEnded }
        if let history = error as? QuickBooksChangeHistoryError {
            switch history {
            case .access: return .accessEnded
            case .changed: return .connectionChanged
            case .invalid, .incomplete, .lifecycleReview, .unavailable, .limit: return nil
            }
        }
        if let workspace = error as? WorkspaceProviderAccessError {
            switch workspace {
            case .unavailable: return .accessEnded
            case .changed: return .connectionChanged
            }
        }
        if error is CompanyWorkspaceFailure { return .accessEnded }
        // The shared server answers with a status code, not a typed provider
        // error. A refused administrator or a moved connection reads the same
        // here as it does from the provider, and must stop the pass the same
        // way; anything else is an ordinary unavailability.
        if let backend = error as? GunnAireBackendError, case let .server(statusCode, _) = backend {
            switch statusCode {
            case 401, 403: return .accessEnded
            case 409: return .connectionChanged
            default: break
            }
        }
        if let backend = error as? GunnAireBackendError, case .missingBusinessIdentity = backend {
            return .accessEnded
        }
        if let qbError = error as? QuickBooksDataAPI.QBError, qbError.requiresReconnect {
            return .reconnectRequired
        }
        return nil
    }

    func outcome(for resourceID: String) -> QuickBooksSyncResourceOutcome? {
        outcomes[resourceID]
    }

    var succeeded: [String] { order.filter { outcomes[$0] == .succeeded } }
    var failed: [String] { order.filter { outcomes[$0] == .failed } }
    var skipped: [String] { order.filter { outcomes[$0] == .skipped } }
    var notAttempted: [String] { order.filter { outcomes[$0] == .notAttempted } }

    /// Every resource ran and succeeded.
    var isComplete: Bool {
        halt == nil && order.allSatisfy { outcomes[$0] == .succeeded }
    }

    /// Every change-ledger resource succeeded and nothing ended the pass.
    ///
    /// Deliberately not the same as `isComplete`. Stored cards are not a ledger
    /// entity, so an accounting-only company skipping them must still be able
    /// to import its accounting snapshot; blocking that would withhold the
    /// books over a payments scope the company does not have.
    func isLedgerComplete(ledgerResourceIDs: Set<String>) -> Bool {
        halt == nil && ledgerResourceIDs.allSatisfy { outcomes[$0] == .succeeded }
    }

    /// A complete, revalidated census is required before the local store may be
    /// replaced from this pass. The sync run enforces the same rule again over
    /// the ledger it revalidates; this is the cheaper check in front of it.
    func mayImportCompleteSnapshot(ledgerResourceIDs: Set<String>) -> Bool {
        isLedgerComplete(ledgerResourceIDs: ledgerResourceIDs)
    }

    /// A partial pass must never acknowledge shared-history or change events.
    /// Acknowledging them would retire a record of work the pass did not read,
    /// and nothing would fetch it again. A deliberate skip outside the ledger
    /// is allowed; an unread or failed resource anywhere is not.
    func mayAcknowledgeChangeEvents(ledgerResourceIDs: Set<String>) -> Bool {
        guard isLedgerComplete(ledgerResourceIDs: ledgerResourceIDs) else { return false }
        return failed.isEmpty && notAttempted.isEmpty
    }

    /// Resources that produced no evidence, for the owner-facing summary.
    /// Empty when every resource was attempted.
    func notAttemptedSummary(names: [String: String] = [:]) -> String? {
        let missing = notAttempted
        guard !missing.isEmpty else { return nil }
        let listed = missing.map { names[$0] ?? $0 }.joined(separator: ", ")
        return "Not attempted in this sync: \(listed)."
    }
}

/// What one finished pass tells the owner, and whether it may be recorded as
/// a successful sync.
///
/// Kept as a decision rather than a sequence of view writes because the rule
/// that matters is narrow: a run that could not read something does not get to
/// look like a run that read everything.
nonisolated struct QuickBooksSyncCompletion: Equatable, Sendable {
    let isComplete: Bool
    let statusMessage: String
    /// Only a complete run stamps the successful-sync date. A run that could
    /// not read the change alerts has not confirmed the company's books.
    let recordsSuccessfulSyncDate: Bool
    let alertRetentionNote: String?

    static let retentionNote =
        "Change alerts are retained until each record is reconciled. Refreshing data does not clear them."
}

extension QuickBooksSyncPass {
    /// Decides how a finished pass is reported.
    ///
    /// `alertsUnavailable` is a failure like any other: the change alerts could
    /// not be read, so the run is incomplete and records no successful sync
    /// date. It is deliberately not a reason to stop the resource reads, which
    /// are independent of the alerts.
    static func completion(failures: [String],
                           notAttemptedSummary: String?,
                           alertsUnavailable: String?,
                           hasPendingAlerts: Bool) -> QuickBooksSyncCompletion {
        var lines = failures
        if let notAttemptedSummary { lines.append(notAttemptedSummary) }
        if let alertsUnavailable { lines.append(alertsUnavailable) }
        let complete = lines.isEmpty
        // The retention note belongs on a partial result too: a run that
        // stopped early is exactly when a pending alert must not look cleared.
        // It is withheld only when the alerts could not be read at all, because
        // then their own message is the honest one to show.
        let note = (hasPendingAlerts && alertsUnavailable == nil)
            ? QuickBooksSyncCompletion.retentionNote
            : nil
        return QuickBooksSyncCompletion(
            isComplete: complete,
            statusMessage: complete
                ? "QuickBooks data refreshed. Review any accounting or payment warnings below."
                : "QuickBooks sync incomplete.\n" + lines.joined(separator: "\n"),
            recordsSuccessfulSyncDate: complete,
            alertRetentionNote: note
        )
    }
}

/// Drives one resource sync pass: the order, the per-resource status
/// transitions, and the decision to continue or stop after each one.
///
/// The view owns the fetching and the store; this owns the sequencing rules,
/// so those rules can be exercised without a provider, a server or a store.
@MainActor
final class QuickBooksResourceSyncOrchestrator {
    /// Every status transition a resource can be given, in the orchestrator's
    /// own vocabulary. The view maps these onto its display states, which is
    /// where a required resource becomes a failure and an optional one a
    /// warning; that distinction is not weakened here.
    enum StatusChange: Equatable {
        case loading(String)
        case loaded(String, count: Int)
        case failed(String, message: String)
        case skipped(String, message: String)
        case notAttempted(String, message: String)
    }

    private(set) var pass: QuickBooksSyncPass
    private let checkAccess: () throws -> Void
    private let describe: (Error) -> String
    private let emit: (StatusChange) -> Void

    init(order: [String],
         checkAccess: @escaping () throws -> Void,
         describe: @escaping (Error) -> String,
         emit: @escaping (StatusChange) -> Void) {
        self.pass = QuickBooksSyncPass(order: order)
        self.checkAccess = checkAccess
        self.describe = describe
        self.emit = emit
    }

    var halt: QuickBooksSyncHalt? { pass.halt }

    /// Runs one resource and reports whether the caller may continue.
    ///
    /// `work` performs the fetch and applies it, returning how many records it
    /// read. A thrown access failure from the surrounding run is never recorded
    /// as a resource failure: it is rethrown so the whole sync stops.
    @discardableResult
    func perform(id: String, work: () async throws -> Int) async throws -> Bool {
        guard pass.halt == nil else { return false }
        try checkAccess()
        emit(.loading(id))
        pass.recordAttemptStarted(id)
        do {
            let count = try await work()
            try checkAccess()
            pass.recordSucceeded(id)
            emit(.loaded(id, count: count))
            return true
        } catch {
            // A locally visible access failure stops the sync outright rather
            // than becoming one resource's error.
            try checkAccess()
            pass.recordFailed(id)
            emit(.failed(id, message: describe(error)))
            guard let halt = QuickBooksSyncPass.haltReason(for: error) else { return true }
            // The backend can refuse this administrator while the device still
            // looks valid. Stop here: no further provider reads.
            pass.recordHalt(halt)
            settleRemaining()
            return false
        }
    }

    /// Records a resource the pass deliberately did not run.
    func skip(id: String, message: String) {
        guard pass.halt == nil else { return }
        pass.recordSkipped(id)
        emit(.skipped(id, message: message))
    }

    /// Ends the pass without a resource error, for a stop raised elsewhere.
    func stop(_ reason: QuickBooksSyncHalt) {
        guard pass.halt == nil else { return }
        pass.recordHalt(reason)
        settleRemaining()
    }

    /// Tells every resource the pass never reached that it was never reached.
    private func settleRemaining() {
        let detail = pass.halt?.detail ?? QuickBooksSyncHalt.accessEnded.detail
        for id in pass.notAttempted {
            emit(.notAttempted(id, message: detail))
        }
    }
}
