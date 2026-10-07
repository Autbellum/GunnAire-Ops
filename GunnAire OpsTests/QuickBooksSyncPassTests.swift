import Foundation
import Testing
@testable import GunnAire_Ops

/// The rules that decide what one QuickBooks sync pass may claim.
///
/// The owner reported sales receipts, deposits and stored cards as "not
/// syncing". Two faults produced that: a pass that stopped early reported
/// resources it had never reached as failed, and the resources that run last
/// were the ones a stop reached first.
///
/// These drive `QuickBooksResourceSyncOrchestrator` itself, the type the view
/// uses, rather than recording outcomes by hand. A test that recorded outcomes
/// directly could not see a wiring fault, which is how the first pair of them
/// went unnoticed.
@MainActor
struct QuickBooksSyncPassTests {
    private let trailing = ["salesReceipts", "deposits"]
    private let ledgerResourceIDs = Set(QuickBooksChangeEntity.allCases.map(\.resourceID))

    /// Records every fetch the orchestrator actually performs and every status
    /// transition it emits, so order and truthfulness are both observable.
    @MainActor
    private final class Harness {
        var fetched: [String] = []
        var changes: [QuickBooksResourceSyncOrchestrator.StatusChange] = []
        var accessFailure: Error?

        func orchestrator(order: [String]) -> QuickBooksResourceSyncOrchestrator {
            QuickBooksResourceSyncOrchestrator(
                order: order,
                checkAccess: { [weak self] in if let failure = self?.accessFailure { throw failure } },
                describe: { error in "described: \(error)" },
                emit: { [weak self] change in self?.changes.append(change) }
            )
        }

        /// A fetch that records that it ran, then succeeds or throws.
        func work(_ id: String, throwing error: Error? = nil, count: Int = 3) -> () async throws -> Int {
            {
                self.fetched.append(id)
                if let error { throw error }
                return count
            }
        }

        func state(of id: String) -> QuickBooksResourceSyncOrchestrator.StatusChange? {
            changes.last { change in
                switch change {
                case let .loading(other): return other == id
                case let .loaded(other, _): return other == id
                case let .failed(other, _): return other == id
                case let .skipped(other, _): return other == id
                case let .notAttempted(other, _): return other == id
                }
            }
        }

        func isNotAttempted(_ id: String) -> Bool {
            if case .notAttempted = state(of: id) { return true }
            return false
        }

        func isFailed(_ id: String) -> Bool {
            if case .failed = state(of: id) { return true }
            return false
        }
    }

    private enum OrdinaryFailure: Error { case providerRejectedTheQuery }

    // MARK: - The declared order

    @Test func theRunOrderKeepsTheTrailingFinancialResourcesLast() {
        let order = QuickBooksManagementView.syncResourceOrder
        #expect(Array(order.suffix(2)) == trailing)
        #expect(Set(order).count == order.count, "A duplicated resource id would double-count an outcome.")
        #expect(ledgerResourceIDs.isSubset(of: Set(order)), "Every change entity must be attempted by the pass.")
        #expect(ledgerResourceIDs.contains("storedCards") == false, "Stored cards are not a change entity.")
    }

    // MARK: - What must no longer stop a pass

    @Test func anOrdinaryFailureDoesNotEndThePass() {
        #expect(QuickBooksSyncPass.haltReason(for: OrdinaryFailure.providerRejectedTheQuery) == nil)
        #expect(QuickBooksSyncPass.haltReason(for: QuickBooksChangeHistoryError.unavailable) == nil)
        #expect(QuickBooksSyncPass.haltReason(for: QuickBooksDataAPI.QBError.network) == nil)
    }

    @Test func salesReceiptsAndDepositsAreStillFetchedAfterAnEarlierFailure() async throws {
        let harness = Harness()
        let order = ["customers", "invoices", "salesReceipts", "deposits"]
        let sync = harness.orchestrator(order: order)

        #expect(try await sync.perform(id: "customers", work: harness.work("customers")))
        #expect(try await sync.perform(id: "invoices",
                                       work: harness.work("invoices", throwing: OrdinaryFailure.providerRejectedTheQuery)))
        #expect(try await sync.perform(id: "salesReceipts", work: harness.work("salesReceipts")))
        #expect(try await sync.perform(id: "deposits", work: harness.work("deposits")))

        #expect(harness.fetched == order, "Every resource must still be fetched, in order.")
        #expect(sync.halt == nil)
        #expect(sync.pass.failed == ["invoices"])
        #expect(sync.pass.notAttempted.isEmpty)
        #expect(harness.isFailed("invoices"))
    }

    // MARK: - What must still stop a pass

    @Test func everyAccessOrConnectionErrorEndsThePass() {
        #expect(QuickBooksSyncPass.haltReason(for: CancellationError()) == .accessEnded)
        #expect(QuickBooksSyncPass.haltReason(for: QuickBooksChangeHistoryError.access) == .accessEnded)
        #expect(QuickBooksSyncPass.haltReason(for: QuickBooksChangeHistoryError.changed) == .connectionChanged)
        #expect(QuickBooksSyncPass.haltReason(for: WorkspaceProviderAccessError.unavailable) == .accessEnded)
        #expect(QuickBooksSyncPass.haltReason(for: WorkspaceProviderAccessError.changed(mayHaveReachedProvider: true))
                == .connectionChanged)
        #expect(QuickBooksSyncPass.haltReason(for: CompanyWorkspaceFailure.differentWorkspace) == .accessEnded)
        #expect(QuickBooksSyncPass.haltReason(for: QuickBooksDataAPI.QBError.unauthorized) == .reconnectRequired)
    }

    /// The backend can refuse this administrator while the device still looks
    /// locally valid, so the local access check alone cannot be trusted to stop
    /// the pass. This is the wiring the first version of this work got wrong.
    @Test func sharedHistoryLosingBackendAuthStopsFurtherReadsEvenWhenLocalAccessStillPasses() async throws {
        let harness = Harness()
        harness.accessFailure = nil // the device still validates locally
        let order = ["customers", "invoices", "salesReceipts", "deposits"]
        let sync = harness.orchestrator(order: order)

        #expect(try await sync.perform(id: "customers", work: harness.work("customers")))
        let mayContinue = try await sync.perform(
            id: "invoices", work: harness.work("invoices", throwing: QuickBooksChangeHistoryError.access))

        #expect(mayContinue == false)
        #expect(sync.halt == .accessEnded)
        #expect(harness.fetched == ["customers", "invoices"], "No provider read may happen after access is lost.")
        #expect(harness.isFailed("invoices"))
        for id in trailing {
            #expect(harness.isNotAttempted(id), "\(id) was never reached and must not read as failed.")
        }
    }

    @Test func aChangedConnectionStopsFurtherReads() async throws {
        let harness = Harness()
        let order = ["customers", "invoices", "deposits"]
        let sync = harness.orchestrator(order: order)

        #expect(try await sync.perform(id: "customers", work: harness.work("customers")))
        let afterChange = try await sync.perform(
            id: "invoices", work: harness.work("invoices", throwing: QuickBooksChangeHistoryError.changed))
        #expect(afterChange == false)
        // A later call must not reach the provider at all.
        #expect(try await sync.perform(id: "deposits", work: harness.work("deposits")) == false)

        #expect(sync.halt == .connectionChanged)
        #expect(harness.fetched == ["customers", "invoices"])
        #expect(harness.isNotAttempted("deposits"))
    }

    @Test func aLocalAccessFailureIsRethrownAndNeverBecomesAResourceFailure() async throws {
        let harness = Harness()
        let sync = harness.orchestrator(order: ["customers", "deposits"])
        harness.accessFailure = CompanyWorkspaceFailure.differentWorkspace

        await #expect(throws: CompanyWorkspaceFailure.self) {
            _ = try await sync.perform(id: "customers", work: harness.work("customers"))
        }
        #expect(harness.fetched.isEmpty, "The fetch must not run once access has gone.")
        #expect(sync.pass.failed.isEmpty, "An access failure is not one resource's error.")
    }

    @Test func aRejectedSessionLeavesLaterResourcesNotAttemptedRatherThanFailed() async throws {
        let harness = Harness()
        let order = ["customers", "invoices", "salesReceipts", "deposits"]
        let sync = harness.orchestrator(order: order)

        #expect(try await sync.perform(id: "customers", work: harness.work("customers")))
        let afterRejection = try await sync.perform(
            id: "invoices", work: harness.work("invoices", throwing: QuickBooksDataAPI.QBError.unauthorized))
        #expect(afterRejection == false)

        #expect(sync.halt == .reconnectRequired)
        #expect(sync.pass.failed == ["invoices"])
        #expect(sync.pass.notAttempted == trailing)
        for id in trailing { #expect(harness.isNotAttempted(id)) }
    }

    @Test func aHaltedPassPerformsNothingFurther() async throws {
        let harness = Harness()
        let sync = harness.orchestrator(order: ["customers", "deposits"])
        sync.stop(.accessEnded)

        #expect(try await sync.perform(id: "customers", work: harness.work("customers")) == false)
        #expect(harness.fetched.isEmpty)
        #expect(sync.pass.outcome(for: "customers") == .notAttempted)
    }

    // MARK: - Status truthfulness through the real transitions

    @Test func aResourceReportsLoadingThenItsOwnResult() async throws {
        let harness = Harness()
        let sync = harness.orchestrator(order: ["customers"])
        #expect(try await sync.perform(id: "customers", work: harness.work("customers", count: 7)))

        #expect(harness.changes.first == .loading("customers"))
        #expect(harness.changes.last == .loaded("customers", count: 7))
    }

    @Test func aSkippedResourceIsNeitherAFailureNorSilence() async throws {
        let harness = Harness()
        let sync = harness.orchestrator(order: ["customers", "storedCards", "deposits"])
        #expect(try await sync.perform(id: "customers", work: harness.work("customers")))
        sync.skip(id: "storedCards", message: "Skipped because this token has no payments scope.")
        #expect(try await sync.perform(id: "deposits", work: harness.work("deposits")))

        #expect(sync.pass.outcome(for: "storedCards") == .skipped)
        #expect(sync.pass.failed.isEmpty)
        #expect(sync.pass.notAttempted.isEmpty)
        #expect(harness.isFailed("storedCards") == false)
        #expect(harness.isNotAttempted("storedCards") == false)
    }

    // MARK: - What a partial pass may claim

    @Test func skippedStoredCardsStillAllowTheAccountingSnapshotImport() async throws {
        let harness = Harness()
        let order = QuickBooksManagementView.syncResourceOrder
        let sync = harness.orchestrator(order: order)
        for id in order where id != "storedCards" {
            #expect(try await sync.perform(id: id, work: harness.work(id)))
        }
        sync.skip(id: "storedCards", message: "Accounting-only login.")

        #expect(sync.pass.isLedgerComplete(ledgerResourceIDs: ledgerResourceIDs))
        #expect(sync.pass.mayImportCompleteSnapshot(ledgerResourceIDs: ledgerResourceIDs),
                "An accounting-only company must still get its accounting snapshot.")
        #expect(sync.pass.isComplete == false, "The pass as a whole still did not read everything.")
    }

    @Test func anIncompleteLedgerNeverImportsOrAcknowledges() async throws {
        let harness = Harness()
        let order = QuickBooksManagementView.syncResourceOrder
        let sync = harness.orchestrator(order: order)
        for id in order where id != "deposits" {
            if id == "storedCards" {
                sync.skip(id: id, message: "Accounting-only login.")
            } else {
                #expect(try await sync.perform(id: id, work: harness.work(id)))
            }
        }
        #expect(try await sync.perform(id: "deposits",
                                       work: harness.work("deposits", throwing: OrdinaryFailure.providerRejectedTheQuery)))

        #expect(sync.pass.isLedgerComplete(ledgerResourceIDs: ledgerResourceIDs) == false)
        #expect(sync.pass.mayImportCompleteSnapshot(ledgerResourceIDs: ledgerResourceIDs) == false)
        #expect(sync.pass.mayAcknowledgeChangeEvents(ledgerResourceIDs: ledgerResourceIDs) == false,
                "Acknowledging would retire a change this pass never read.")
    }

    @Test func onlyAFullyReadPassMayAcknowledgeChangeEvents() async throws {
        let harness = Harness()
        let order = QuickBooksManagementView.syncResourceOrder
        let sync = harness.orchestrator(order: order)
        for id in order { #expect(try await sync.perform(id: id, work: harness.work(id))) }

        #expect(sync.pass.isComplete)
        #expect(sync.pass.mayAcknowledgeChangeEvents(ledgerResourceIDs: ledgerResourceIDs))
        #expect(sync.pass.notAttemptedSummary() == nil)
    }

    // MARK: - What the owner is told

    @Test func theSummaryNamesEveryResourceThatNeverRan() async throws {
        let harness = Harness()
        let sync = harness.orchestrator(order: ["customers", "salesReceipts", "deposits"])
        let afterRejection = try await sync.perform(
            id: "customers", work: harness.work("customers", throwing: QuickBooksDataAPI.QBError.unauthorized))
        #expect(afterRejection == false)

        let text = try #require(sync.pass.notAttemptedSummary(
            names: ["salesReceipts": "Sales Receipts", "deposits": "Deposits"]))
        #expect(text.contains("Sales Receipts"))
        #expect(text.contains("Deposits"))
        #expect(text.contains("customers") == false, "A resource that failed is reported by the failure list.")
    }

    // MARK: - How a finished pass is reported

    /// Reading the change alerts is independent of reading the resources, so
    /// an unreadable alert list must not stop the run. It must also not be
    /// swallowed: before this, an alert read that failed returned an empty list
    /// and the run reported refreshed data and stamped a successful sync date.
    @Test func unreadableChangeAlertsMakeTheRunIncompleteAndRecordNoSuccessDate() {
        let completion = QuickBooksSyncPass.completion(
            failures: [],
            notAttemptedSummary: nil,
            alertsUnavailable: "Change alerts: the shared server could not be reached.",
            hasPendingAlerts: false
        )
        #expect(completion.isComplete == false)
        #expect(completion.recordsSuccessfulSyncDate == false)
        #expect(completion.statusMessage.hasPrefix("QuickBooks sync incomplete."))
        #expect(completion.statusMessage.contains("Change alerts:"))
    }

    @Test func aCleanRunRecordsItsSuccessDateAndSaysSo() {
        let completion = QuickBooksSyncPass.completion(
            failures: [], notAttemptedSummary: nil, alertsUnavailable: nil, hasPendingAlerts: false)
        #expect(completion.isComplete)
        #expect(completion.recordsSuccessfulSyncDate)
        #expect(completion.statusMessage.contains("refreshed"))
        #expect(completion.alertRetentionNote == nil)
    }

    @Test func pendingAlertsKeepTheirRetentionNoteOnAPartialResult() {
        for (failures, notAttempted) in [(["Invoices: rejected"], nil), ([], "Not attempted in this sync: Deposits.")]
            as [([String], String?)] {
            let completion = QuickBooksSyncPass.completion(
                failures: failures,
                notAttemptedSummary: notAttempted,
                alertsUnavailable: nil,
                hasPendingAlerts: true
            )
            #expect(completion.isComplete == false)
            #expect(completion.alertRetentionNote == QuickBooksSyncCompletion.retentionNote,
                    "A run that stopped early is exactly when a pending alert must not look cleared.")
        }
    }

    @Test func pendingAlertsKeepTheirRetentionNoteOnACleanRun() {
        let completion = QuickBooksSyncPass.completion(
            failures: [], notAttemptedSummary: nil, alertsUnavailable: nil, hasPendingAlerts: true)
        #expect(completion.isComplete)
        #expect(completion.alertRetentionNote == QuickBooksSyncCompletion.retentionNote)
    }

    @Test func unreadableAlertsSuppressTheRetentionNoteInFavourOfTheirOwnMessage() {
        let completion = QuickBooksSyncPass.completion(
            failures: [],
            notAttemptedSummary: nil,
            alertsUnavailable: "Change alerts: the shared server could not be reached.",
            hasPendingAlerts: true
        )
        #expect(completion.alertRetentionNote == nil,
                "Claiming alerts are retained would overstate what the run could see.")
    }

    @Test func everyReasonTheRunFellShortIsNamedInOneMessage() {
        let completion = QuickBooksSyncPass.completion(
            failures: ["Invoices: rejected"],
            notAttemptedSummary: "Not attempted in this sync: Deposits.",
            alertsUnavailable: "Change alerts: the shared server could not be reached.",
            hasPendingAlerts: true
        )
        #expect(completion.statusMessage.contains("Invoices: rejected"))
        #expect(completion.statusMessage.contains("Deposits"))
        #expect(completion.statusMessage.contains("Change alerts:"))
        #expect(completion.recordsSuccessfulSyncDate == false)
    }

    /// The shared server answers with a status code rather than a typed
    /// provider error, and those must stop the pass exactly as the provider's
    /// own refusals do.
    @Test func backendRefusalsAndConnectionChangesStopThePass() {
        #expect(QuickBooksSyncPass.haltReason(
            for: GunnAireBackendError.server(statusCode: 401, message: "no")) == .accessEnded)
        #expect(QuickBooksSyncPass.haltReason(
            for: GunnAireBackendError.server(statusCode: 403, message: "no")) == .accessEnded)
        #expect(QuickBooksSyncPass.haltReason(
            for: GunnAireBackendError.server(statusCode: 409, message: "moved")) == .connectionChanged)
        #expect(QuickBooksSyncPass.haltReason(for: GunnAireBackendError.missingBusinessIdentity) == .accessEnded)
        // An ordinary server problem is not a reason to stop reading resources.
        #expect(QuickBooksSyncPass.haltReason(
            for: GunnAireBackendError.server(statusCode: 503, message: "busy")) == nil)
        #expect(QuickBooksSyncPass.haltReason(for: GunnAireBackendError.invalidResponse) == nil)
    }

    @Test func eachHaltExplainsItselfDistinctly() {
        let halts: [QuickBooksSyncHalt] = [.reconnectRequired, .accessEnded, .connectionChanged]
        #expect(Set(halts.map(\.detail)).count == halts.count)
        for halt in halts {
            #expect(halt.detail.hasPrefix("Not attempted."),
                    "The owner must be able to tell an unread resource from a failed one.")
        }
        #expect(QuickBooksSyncHalt.reconnectRequired.detail.contains("Reconnect QuickBooks"))
    }
}
