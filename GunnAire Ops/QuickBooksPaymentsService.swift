import Foundation
import SwiftData

struct QuickBooksPaymentsCardInput {
    let cardholderName: String
    let cardNumber: String
    let expMonth: String
    let expYear: String
    let cvc: String
    let postalCode: String?
    let addressLine: String?
    let city: String?
    let region: String?
    let country: String?
}

enum QuickBooksBankAccountType: String, CaseIterable, Identifiable {
    case businessChecking = "BUSINESS_CHECKING"
    case personalChecking = "PERSONAL_CHECKING"
    case businessSavings = "BUSINESS_SAVINGS"
    case personalSavings = "PERSONAL_SAVINGS"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .businessChecking: return "Business Checking"
        case .personalChecking: return "Personal Checking"
        case .businessSavings: return "Business Savings"
        case .personalSavings: return "Personal Savings"
        }
    }
}

struct QuickBooksPaymentsBankAccountInput {
    let accountHolderName: String
    let accountNumber: String
    let routingNumber: String
    let phone: String
    let accountType: QuickBooksBankAccountType
    let checkNumber: String?
}

struct QuickBooksProcessedPaymentResult {
    let charge: QuickBooksPaymentsChargeResponse
    let accountingPayment: QuickBooksPayment?
    let accountingError: String?
    let clientTransactionID: String?
    let operation: WorkspaceProviderOperation

    func validateWorkspace() throws { try operation.check() }
}

struct QuickBooksProcessedRefundResult {
    let localPaymentID: UUID
    let refund: QuickBooksPaymentsRefundResponse
    let refundReceipt: QuickBooksRefundReceipt?
    let accountingError: String?
    let clientTransactionID: String?
    let operation: WorkspaceProviderOperation

    func validateWorkspace() throws { try operation.check() }
}

/// Provider evidence remains tied to its initiating account even after an
/// async method returns and the caller is queued to update its interface.
struct QuickBooksWorkspaceResult<Value> {
    let value: Value
    let operation: WorkspaceProviderOperation
    func validateWorkspace() throws { try operation.check() }
}

final class QuickBooksPaymentsService {
    static let shared = QuickBooksPaymentsService()

    private let api: QuickBooksDataAPI
    private let journal: any PaymentAttemptCoordinating

    private init() {
        api = .shared
        journal = BackendPaymentAttemptCoordinator()
    }

#if DEBUG
    private var testSalesItemReference: String?
    init(api: QuickBooksDataAPI, journal: any PaymentAttemptCoordinating, salesItemReference: String? = nil) {
        precondition(GunnAireCloudKit.usesTestDatabase)
        self.api = api
        self.journal = journal
        testSalesItemReference = salesItemReference
    }
#endif


    private func paymentIntent(id: UUID, invoice: Invoice, customerID: String, amount: Double,
                               rail: String, kind: String = "charge") throws -> PaymentAttemptIntent {
        try api.checkWorkflowOperation()
        guard let realmID = api.realmID, let invoiceID = invoice.quickBooksID.nilIfBlank,
              PaymentAttemptRecord.isReference(realmID), PaymentAttemptRecord.isReference(invoiceID),
              PaymentAttemptRecord.isReference(customerID),
              amount.isFinite, amount > 0, amount <= 1_000_000 else {
            throw QuickBooksPaymentsServiceError.invalidAmount
        }
        return PaymentAttemptIntent(id: id, companyID: try journal.companyID(), realmID: realmID,
            environment: api.currentEnvironment, invoiceID: invoice.id, invoiceQuickBooksID: invoiceID,
            customerQuickBooksID: customerID, amountCents: Int((amount * 100).rounded()), rail: rail, kind: kind)
    }

    private func finishAttempt(_ attempt: PaymentAttemptRecord, accountingID: String?) async -> String? {
        guard let accountingID else { return nil }
        do {
            try api.checkWorkflowOperation()
            let completed = try await journal.action("complete", attemptID: attempt.id, reference: accountingID)
            try api.checkWorkflowOperation()
            try completed.validate(for: attempt.intent, states: [.completed], previous: attempt)
            guard completed.providerID == attempt.providerID, completed.accountingID == accountingID else {
                throw PaymentAttemptError.needsReview
            }
            return nil
        } catch {
            return "The payment is verified, but shared accounting confirmation still needs review. Do not collect it again."
        }
    }

    private enum AccountingPaymentKind {
        case card(chargeID: String)
        case ach(chargeID: String)
        case manual(methodName: String)
    }

    func processCardPayment(
        localPaymentID: UUID,
        invoice: Invoice,
        amount: Double,
        cardInput: QuickBooksPaymentsCardInput,
        note: String?,
        catalogItems: [Item]
    ) async throws -> QuickBooksProcessedPaymentResult {
        return try await api.withWorkspaceOperation { operation in
            try validateInvoiceWorkspace(invoice)
            try validatePaymentAmount(amount)
            let customerQBID = try await prepareInvoiceForQuickBooksPayment(
                invoice,
                catalogItems: catalogItems
            )

            let intent = try paymentIntent(id: localPaymentID, invoice: invoice, customerID: customerQBID,
                                           amount: amount, rail: "card")
            let clientTransactionID = intent.clientTransactionID
            let (authorized, attempt) = try await PaymentAttemptDispatcher(journal: journal, check: operation.check).dispatch(
                intent: intent, prepare: { try await self.createCardToken(cardInput) },
                send: { token, permit in
                    try await self.createAuthorization(amount: amount, token: token.value, note: note,
                        clientTransactionID: permit.clientTransactionID, requestID: permit.requestID)
                }, providerID: { $0.id }
            )
            try QuickBooksPaymentsResponsePolicy.validateCharge(
                authorized,
                expectedAmount: amount,
                expectedClientTransactionID: clientTransactionID,
                kind: .capturedCard
            )
            let charge = authorized

            let accountingPayment = await syncAccountingPayment(
                localPaymentID: localPaymentID,
                invoice: invoice,
                customerQBID: customerQBID,
                amount: amount,
                note: note,
                charge: charge,
                clientTransactionID: clientTransactionID,
                paymentKind: .card(chargeID: charge.id)
            )

            let completionError = await finishAttempt(attempt, accountingID: accountingPayment.payment?.Id)
            return QuickBooksProcessedPaymentResult(
                charge: charge,
                accountingPayment: accountingPayment.payment,
                accountingError: accountingPayment.error ?? completionError,
                clientTransactionID: charge.resolvedClientTransID ?? clientTransactionID,
                operation: operation
            )
        }
    }

    func storeCard(
        _ input: QuickBooksPaymentsCardInput, for customer: QuickBooksCustomer
    ) async throws -> QuickBooksWorkspaceResult<QuickBooksPaymentsCardRecord> {
        try await api.withWorkspaceOperation { operation in
            let token = try await createCardToken(input)
            let card: QuickBooksPaymentsCardRecord = try await withCheckedThrowingContinuation { continuation in
                api.createStoredCard(.init(value: token.value), forCustomerID: customer.Id) {
                    continuation.resume(with: $0)
                }
            }
            return QuickBooksWorkspaceResult(value: card, operation: operation)
        }
    }

    func processBankPayment(
        localPaymentID: UUID,
        invoice: Invoice,
        amount: Double,
        bankInput: QuickBooksPaymentsBankAccountInput,
        note: String?,
        catalogItems: [Item]
    ) async throws -> QuickBooksProcessedPaymentResult {
        return try await api.withWorkspaceOperation { operation in
            try validateInvoiceWorkspace(invoice)
            try validatePaymentAmount(amount)
            let customerQBID = try await prepareInvoiceForQuickBooksPayment(
                invoice,
                catalogItems: catalogItems
            )

            let intent = try paymentIntent(id: localPaymentID, invoice: invoice, customerID: customerQBID,
                                           amount: amount, rail: "ach")
            let clientTransactionID = intent.clientTransactionID
            let (charge, attempt) = try await PaymentAttemptDispatcher(journal: journal, check: operation.check).dispatch(
                intent: intent, prepare: { try await self.createBankAccountToken(bankInput) },
                send: { token, permit in
                    try await self.createBankCharge(amount: amount, token: token.value, note: note,
                        clientTransactionID: permit.clientTransactionID, checkNumber: bankInput.checkNumber,
                        requestID: permit.requestID)
                }, providerID: { $0.id }
            )
            try QuickBooksPaymentsResponsePolicy.validateCharge(
                charge,
                expectedAmount: amount,
                expectedClientTransactionID: clientTransactionID,
                kind: .submittedBank
            )

            let accountingPayment = await syncAccountingPayment(
                localPaymentID: localPaymentID,
                invoice: invoice,
                customerQBID: customerQBID,
                amount: amount,
                note: note,
                charge: charge,
                clientTransactionID: clientTransactionID,
                paymentKind: .ach(chargeID: charge.id)
            )

            let completionError = await finishAttempt(attempt, accountingID: accountingPayment.payment?.Id)
            return QuickBooksProcessedPaymentResult(
                charge: charge,
                accountingPayment: accountingPayment.payment,
                accountingError: accountingPayment.error ?? completionError,
                clientTransactionID: charge.resolvedClientTransID ?? clientTransactionID,
                operation: operation
            )
        }
    }

    func refundPayment(
        payment: Payment,
        amount: Double,
        note: String?
    ) async throws -> QuickBooksProcessedRefundResult {
        return try await api.withWorkspaceOperation { operation in
            guard let chargeID = payment.quickBooksChargeID, !chargeID.isEmpty else {
                throw QuickBooksPaymentsServiceError.chargeNotSynced
            }
            guard let invoice = payment.invoice, let customer = invoice.customer else {
                throw QuickBooksPaymentsServiceError.invoiceRelationshipUnavailable
            }
            try validateInvoiceWorkspace(invoice)
            try validatePaymentAmount(amount)
            guard amount <= abs(payment.amount) else {
                throw QuickBooksPaymentsServiceError.invalidAmount
            }
            guard let rail = QuickBooksPaymentRail.forMethod(payment.method) else {
                throw QuickBooksPaymentsServiceError.invalidRetryTarget
            }
            guard let customerQBID = customer.quickBooksID, !customerQBID.isEmpty else {
                throw QuickBooksPaymentsServiceError.customerNotSynced
            }
            guard let salesItemRef = await resolvedSalesItemRef() else {
                throw QuickBooksPaymentsServiceError.missingSalesItemReference
            }

            guard let originalAccountingID = payment.quickBooksID.nilIfBlank else {
                throw PaymentAttemptError.originalAccountingRequired
            }
            let refundPaymentID = UUID()
            var intent = try paymentIntent(id: refundPaymentID, invoice: invoice, customerID: customerQBID,
                                           amount: amount, rail: rail == .bank ? "ach" : "card", kind: "refund")
            intent.sourcePaymentID = payment.id
            intent.sourceProviderID = chargeID
            intent.sourceAccountingID = originalAccountingID
            let clientTransactionID = intent.clientTransactionID
            let (refund, attempt) = try await PaymentAttemptDispatcher(journal: journal, check: operation.check).dispatch(
                intent: intent, prepare: { () },
                send: { _, permit in
                    try await self.refundCharge(rail: rail, id: chargeID, amount: amount, note: note,
                        clientTransactionID: permit.clientTransactionID, requestID: permit.requestID)
                }, providerID: { $0.id }
            )
            try QuickBooksPaymentsResponsePolicy.validateRefund(
                refund,
                expectedAmount: amount,
                expectedClientTransactionID: clientTransactionID
            )
            let refundReceipt = await syncRefundReceipt(
                localPaymentID: refundPaymentID,
                invoice: invoice,
                customerQBID: customerQBID,
                salesItemRef: salesItemRef,
                amount: amount,
                note: note,
                clientTransactionID: clientTransactionID
            )

            let completionError = await finishAttempt(attempt, accountingID: refundReceipt.receipt?.Id)
            return QuickBooksProcessedRefundResult(
                localPaymentID: refundPaymentID,
                refund: refund,
                refundReceipt: refundReceipt.receipt,
                accountingError: refundReceipt.error ?? completionError,
                clientTransactionID: refund.resolvedClientTransID ?? clientTransactionID,
                operation: operation
            )
        }
    }


    func paymentAttempts(for invoice: Invoice) async throws -> QuickBooksWorkspaceResult<[PaymentAttemptRecord]> {
        try await api.withWorkspaceOperation { operation in
            try validateInvoiceWorkspace(invoice)
            let records = try await journal.list(invoiceID: invoice.id)
            try operation.check()
            return QuickBooksWorkspaceResult(value: records, operation: operation)
        }
    }

    func cancelPaymentReservation(_ id: UUID, for invoice: Invoice) async throws {
        try await api.withWorkspaceOperation { operation in
            try validateInvoiceWorkspace(invoice)
            let record = try await journal.get(id)
            try validateAttempt(record, invoice: invoice)
            let cancelled = try await journal.action("cancel", attemptID: id, reference: nil)
            try operation.check()
            try cancelled.validate(for: record.intent, states: [.cancelled], previous: record)
        }
    }

    private func validateAttempt(_ record: PaymentAttemptRecord, invoice: Invoice) throws {
        try validateInvoiceWorkspace(invoice)
        guard record.intent.companyID == (try journal.companyID()),
              record.intent.realmID == api.realmID, record.intent.environment == api.currentEnvironment,
              record.intent.invoiceID == invoice.id, record.intent.invoiceQuickBooksID == invoice.quickBooksID,
              record.intent.customerQuickBooksID == invoice.customer?.quickBooksID,
              record.intent.amountCents > 0, record.intent.amountCents <= 100_000_000,
              ["card", "ach"].contains(record.intent.rail),
              ["charge", "refund"].contains(record.intent.kind) else { throw PaymentAttemptError.needsReview }
    }

    /// Recovery never resends a charge/refund. Server GET evidence precedes
    /// accounting-only recovery and a local upsert by the original attempt UUID.
    func recoverPaymentAttempt(_ id: UUID, for invoice: Invoice, providerReference: String? = nil)
        async throws -> QuickBooksWorkspaceResult<UUID> {
        try await api.withWorkspaceOperation { operation in
            guard let context = invoice.modelContext else { throw WorkspaceProviderAccessError.unavailable }
            var attempt = try await journal.get(id)
            try validateAttempt(attempt, invoice: invoice)
            guard let providerID = attempt.providerID ?? attempt.candidateProviderID ?? providerReference,
                  PaymentAttemptRecord.isReference(providerID) else { throw PaymentAttemptError.needsReview }
            let verified = try await journal.action("confirm", attemptID: id, reference: providerID)
            try operation.check()
            try verified.validate(for: attempt.intent, states: [.confirmed, .completed], previous: attempt)
            guard verified.providerID == providerID else { throw PaymentAttemptError.needsReview }
            attempt = verified
            let isRefund = attempt.intent.kind == "refund"
            let amount = Double(attempt.intent.amountCents) / 100
            let accountingID: String
            if let existing = attempt.accountingID {
                accountingID = existing
            } else if isRefund {
                guard let salesItem = await resolvedSalesItemRef() else {
                    throw QuickBooksPaymentsServiceError.missingSalesItemReference
                }
                let receipt = await syncRefundReceipt(localPaymentID: id, invoice: invoice,
                    customerQBID: attempt.intent.customerQuickBooksID, salesItemRef: salesItem,
                    amount: amount, note: nil, clientTransactionID: attempt.clientTransactionID)
                guard let receipt = receipt.receipt else { throw PaymentAttemptError.needsReview }
                accountingID = receipt.Id
            } else {
                let payload = try await quickBooksPaymentPayload(invoice: invoice,
                    customerQBID: attempt.intent.customerQuickBooksID, amount: amount, note: nil,
                    paymentRef: providerID, clientTransactionID: attempt.clientTransactionID,
                    paymentKind: attempt.intent.rail == "ach" ? .ach(chargeID: providerID) : .card(chargeID: providerID))
                accountingID = try await recoverOrCreateAccountingPayment(localPaymentID: id, payload: payload).Id
            }
            guard await finishAttempt(attempt, accountingID: accountingID) == nil else {
                throw PaymentAttemptError.needsReview
            }
            try validateInvoiceWorkspace(invoice)
            let existing = try context.fetch(FetchDescriptor<Payment>(predicate: #Predicate { $0.id == id }))
            guard existing.count <= 1 else { throw PaymentAttemptError.needsReview }
            if let payment = existing.first {
                guard payment.invoice?.id == invoice.id, payment.quickBooksChargeID == providerID,
                      payment.quickBooksClientTransID == attempt.clientTransactionID,
                      payment.isRefund == isRefund, abs(abs(payment.amount) - amount) < 0.000_001 else {
                    throw PaymentAttemptError.needsReview
                }
                payment.collectionAttemptID = id
                payment.providerPaymentStatus = attempt.providerStatus
                if isRefund { payment.quickBooksRefundReceiptID = accountingID }
                else { payment.quickBooksID = accountingID }
                payment.quickBooksAccountingSyncStatus = "synced"
                payment.quickBooksAccountingSyncDetail = nil
            } else {
                let payment = Payment(id: id, invoice: invoice,
                    quickBooksID: isRefund ? nil : accountingID, quickBooksChargeID: providerID,
                    quickBooksClientTransID: attempt.clientTransactionID, collectionAttemptID: id,
                    providerPaymentStatus: attempt.providerStatus,
                    quickBooksRefundReceiptID: isRefund ? accountingID : nil,
                    quickBooksAccountingSyncStatus: "synced",
                    processorSyncStatus: attempt.providerStatus?.lowercased(),
                    amount: isRefund ? -amount : amount, method: attempt.intent.rail,
                    authorizationReference: providerID, processor: OnsitePaymentProcessor.quickBooksPayments.rawValue,
                    isRefund: isRefund, refundedPaymentID: attempt.intent.sourcePaymentID)
                context.insert(payment)
                invoice.applyLocalPaymentAmount(amount, isRefund: isRefund)
            }
            try context.save()
            return QuickBooksWorkspaceResult(value: id, operation: operation)
        }
    }

    /// Keep accounting evidence and failure metadata in the original model store.
    /// UI callers never write a retained Payment after awaiting a provider result.
    func syncAndRecordAccountingFollowUp(
        for payment: Payment, manual: Bool = false
    ) async throws -> QuickBooksWorkspaceResult<String> {
        try await api.withWorkspaceOperation { operation in
            guard let invoice = payment.invoice else {
                throw QuickBooksPaymentsServiceError.invoiceRelationshipUnavailable
            }
            try validateInvoiceWorkspace(invoice)
            if !GunnAireCloudKit.usesTestDatabase {
                guard payment.modelContext?.container === invoice.modelContext?.container else {
                    throw WorkspaceProviderAccessError.unavailable
                }
            }
            do {
                var attempt: PaymentAttemptRecord?
                if let attemptID = payment.collectionAttemptID {
                    let stored = try await journal.get(attemptID)
                    try operation.check()
                    let expected = try paymentIntent(id: payment.id, invoice: invoice,
                        customerID: invoice.customer?.quickBooksID ?? "", amount: abs(payment.amount),
                        rail: QuickBooksPaymentRail.forMethod(payment.method) == .bank ? "ach" : "card",
                        kind: payment.isRefund ? "refund" : "charge")
                    guard stored.id == payment.id, stored.intent.companyID == expected.companyID,
                          stored.intent.realmID == expected.realmID, stored.intent.environment == expected.environment,
                          stored.intent.invoiceID == expected.invoiceID,
                          stored.intent.invoiceQuickBooksID == expected.invoiceQuickBooksID,
                          stored.intent.customerQuickBooksID == expected.customerQuickBooksID,
                          stored.intent.amountCents == expected.amountCents, stored.intent.rail == expected.rail,
                          stored.intent.kind == expected.kind, stored.providerID == payment.quickBooksChargeID,
                          stored.clientTransactionID == payment.quickBooksClientTransID else {
                        throw PaymentAttemptError.needsReview
                    }
                    try stored.validate(for: stored.intent, states: [.confirmed, .completed])
                    attempt = stored
                }
                let identifier: String
                if payment.isRefund {
                    guard !manual else { throw QuickBooksPaymentsServiceError.invalidRetryTarget }
                    let receipt = try await retryRefundReceiptSync(for: payment)
                    try validateInvoiceWorkspace(invoice)
                    identifier = receipt.Id
                    payment.quickBooksRefundReceiptID = identifier
                } else {
                    let record = try await (manual
                        ? syncManualAccountingPayment(for: payment)
                        : retryAccountingSync(for: payment))
                    try validateInvoiceWorkspace(invoice)
                    identifier = record.Id
                    payment.quickBooksID = identifier
                }
                if let attempt, await finishAttempt(attempt, accountingID: identifier) != nil {
                    throw PaymentAttemptError.needsReview
                }
                try operation.check()
                payment.quickBooksAccountingSyncStatus = "synced"
                payment.quickBooksAccountingSyncDetail = nil
                try payment.modelContext?.save()
                return QuickBooksWorkspaceResult(value: identifier, operation: operation)
            } catch {
                // A late error must not mutate old models under a new session.
                try validateInvoiceWorkspace(invoice)
                payment.quickBooksAccountingSyncStatus = "needs_attention"
                payment.quickBooksAccountingSyncDetail = error.localizedDescription
                try payment.modelContext?.save()
                throw error
            }
        }
    }

    private func retryAccountingSync(for payment: Payment) async throws -> QuickBooksPayment {
        return try await api.withWorkspaceOperation { operation in
            guard !payment.isRefund else {
                throw QuickBooksPaymentsServiceError.invalidRetryTarget
            }
            guard let invoice = payment.invoice, let customer = invoice.customer else {
                throw QuickBooksPaymentsServiceError.invoiceRelationshipUnavailable
            }
            try validateInvoiceWorkspace(invoice)
            guard let customerQBID = customer.quickBooksID, !customerQBID.isEmpty else {
                throw QuickBooksPaymentsServiceError.customerNotSynced
            }
            guard invoice.quickBooksID.nilIfBlank != nil else {
                throw QuickBooksPaymentsServiceError.invoiceNotSyncedToQuickBooks
            }

            let payload = try await quickBooksPaymentPayload(
                invoice: invoice,
                customerQBID: customerQBID,
                amount: payment.amount,
                note: payment.notes,
                paymentRef: payment.quickBooksClientTransID.nilIfBlank ?? payment.quickBooksChargeID.nilIfBlank ?? payment.id.uuidString,
                clientTransactionID: payment.quickBooksClientTransID.nilIfBlank,
                paymentKind: paymentKind(for: payment)
            )

            return try await recoverOrCreateAccountingPayment(
                localPaymentID: payment.id,
                payload: payload
            )
        }
    }

    private func syncManualAccountingPayment(for payment: Payment) async throws -> QuickBooksPayment {
        return try await api.withWorkspaceOperation { operation in
            guard !payment.isRefund else {
                throw QuickBooksPaymentsServiceError.invalidRetryTarget
            }
            guard let invoice = payment.invoice, let customer = invoice.customer else {
                throw QuickBooksPaymentsServiceError.invoiceRelationshipUnavailable
            }
            try validateInvoiceWorkspace(invoice)
            guard let customerQBID = customer.quickBooksID, !customerQBID.isEmpty else {
                throw QuickBooksPaymentsServiceError.customerNotSynced
            }
            guard invoice.quickBooksID.nilIfBlank != nil else {
                throw QuickBooksPaymentsServiceError.invoiceNotSyncedToQuickBooks
            }

            let payload = try await quickBooksPaymentPayload(
                invoice: invoice,
                customerQBID: customerQBID,
                amount: payment.amount,
                note: payment.notes,
                paymentRef: payment.authorizationReference.nilIfBlank ?? "Payment for invoice #\(invoice.id.uuidString.prefix(8)) from \(customer.name)",
                paymentKind: .manual(methodName: payment.method)
            )

            return try await recoverOrCreateAccountingPayment(
                localPaymentID: payment.id,
                payload: payload
            )
        }
    }

    private func retryRefundReceiptSync(for refundPayment: Payment) async throws -> QuickBooksRefundReceipt {
        return try await api.withWorkspaceOperation { operation in
            guard refundPayment.isRefund else {
                throw QuickBooksPaymentsServiceError.invalidRetryTarget
            }
            guard let invoice = refundPayment.invoice, let customer = invoice.customer else {
                throw QuickBooksPaymentsServiceError.invoiceRelationshipUnavailable
            }
            try validateInvoiceWorkspace(invoice)
            guard let customerQBID = customer.quickBooksID, !customerQBID.isEmpty else {
                throw QuickBooksPaymentsServiceError.customerNotSynced
            }
            guard let refundID = refundPayment.quickBooksChargeID.nilIfBlank else {
                throw QuickBooksPaymentsServiceError.chargeNotSynced
            }
            guard let salesItemRef = await resolvedSalesItemRef() else {
                throw QuickBooksPaymentsServiceError.missingSalesItemReference
            }

            let description = invoice.lineItemSummary.isEmpty ? "Refund" : invoice.lineItemSummary
            let receipt = QuickBooksRefundReceiptCreate(
                Line: [
                    QuickBooksLineItem(
                        Amount: abs(refundPayment.amount),
                        DetailType: "SalesItemLineDetail",
                        Description: description,
                        SalesItemLineDetail: QuickBooksSalesItemLineDetail(
                            ItemRef: QuickBooksReference(value: salesItemRef, name: nil)
                        )
                    )
                ],
                CustomerRef: QuickBooksReference(value: customerQBID, name: customer.name),
                CreditCardPayment: nil,
                TxnSource: nil,
                PrivateNote: accountingNote(
                    baseNote: refundPayment.notes,
                    clientTransactionID: refundPayment.quickBooksClientTransID.nilIfBlank ?? refundID
                )
            )

            return try await withCheckedThrowingContinuation { continuation in
                api.recoverOrCreateRefundReceipt(receipt, localPaymentID: refundPayment.id) { result in
                    continuation.resume(with: result)
                }
            }
        }
    }

    private func resolvedSalesItemRef() async -> String? {
#if DEBUG
        if let testSalesItemReference { return testSalesItemReference }
#endif
        let realmID = api.realmID
        let store = await MainActor.run { QuickBooksAccountingConfigurationStore.shared }
        await store.refresh(
            realmID: realmID,
            environment: Config.QuickBooks.environment
        )
        return await MainActor.run {
            let configuration = store.configuration.flatMap { candidate in
                candidate.matches(realmID: realmID, environment: Config.QuickBooks.environment)
                    ? candidate
                    : nil
            }
            return QuickBooksItemAccountResolver.defaultSalesItemRef(
                configuration: configuration
            )?.value
        }
    }

    private func validatePaymentAmount(_ amount: Double) throws {
        let cents = amount * 100
        guard amount.isFinite, amount > 0, cents.isFinite,
              cents < Double(Int64.max), abs(cents - cents.rounded()) < 0.00001 else {
            throw QuickBooksPaymentsServiceError.invalidAmount
        }
    }

    private func validateInvoiceWorkspace(_ invoice: Invoice) throws {
        try api.checkWorkflowOperation()
        if !GunnAireCloudKit.usesTestDatabase {
            guard let context = invoice.modelContext,
                  context.container === CompanyWorkspaceAccessController.shared.authorizedContainer else {
                throw WorkspaceProviderAccessError.unavailable
            }
        }
    }

    private func prepareInvoiceForQuickBooksPayment(
        _ invoice: Invoice,
        catalogItems: [Item]
    ) async throws -> String {
        if let blockedMessage = invoice.paymentCollectionBlockedMessage {
            throw QuickBooksPaymentsServiceError.authoritativeTaxRequired(blockedMessage)
        }

        guard await api.refreshSessionIfPossible() else {
            throw QuickBooksPaymentsServiceError.quickBooksSessionExpired
        }

        let customerQBID = try await ensureQuickBooksCustomer(for: invoice.customer)
        try await ensureQuickBooksInvoice(
            for: invoice,
            customerQBID: customerQBID,
            catalogItems: catalogItems
        )
        return customerQBID
    }

    private func ensureQuickBooksCustomer(for customer: Customer) async throws -> String {
        if let quickBooksID = customer.quickBooksID.nilIfBlank {
            return quickBooksID
        }

        let reconciled = try await withCheckedThrowingContinuation { continuation in
            api.recoverOrCreateCustomer(
                QuickBooksCustomerCreateOperation.draft(for: customer)
            ) { result in
                continuation.resume(with: result)
            }
        }
        try api.checkWorkflowOperation()
        customer.quickBooksID = reconciled.Id
        try customer.modelContext?.save()
        return reconciled.Id
    }

    private func ensureQuickBooksInvoice(
        for invoice: Invoice,
        customerQBID: String,
        catalogItems: [Item]
    ) async throws {
        if invoice.quickBooksID.nilIfBlank != nil {
            return
        }

        let inputs = try await MainActor.run {
            try QuickBooksInvoicePublicationRecovery.publicationInputs(
                for: invoice,
                catalogItems: catalogItems,
                payments: []
            )
        }
        let payload = QuickBooksInvoiceCreate(
            CustomerRef: QuickBooksReference(value: customerQBID, name: inputs.customerRef.name),
            Line: inputs.lines,
            PrivateNote: inputs.privateNote,
            BillEmail: inputs.billEmail,
            ShipAddr: inputs.shipAddress,
            DueDate: QuickBooksDateOnly.string(from: invoice.effectiveDueDate()),
            GlobalTaxCalculation: "TaxExcluded",
            ApplyTaxAfterDiscount: invoice.documentDiscount == nil ? nil : true
        )

        let remoteInvoices = try await withCheckedThrowingContinuation { continuation in
            api.fetchInvoices { result in
                continuation.resume(with: result)
            }
        }

        let recovered = try await MainActor.run {
            try QuickBooksInvoicePublicationRecovery.matchingRemoteInvoice(
                for: invoice,
                in: remoteInvoices
            )
        }

        let confirmed: QuickBooksInvoice
        if let recovered {
            confirmed = recovered
        } else {
            confirmed = try await withCheckedThrowingContinuation { continuation in
                api.createInvoice(
                    payload,
                    requestID: QuickBooksInvoiceLineage.createRequestID(for: invoice)
                ) { result in
                    continuation.resume(with: result)
                }
            }
        }

        try await MainActor.run {
            try validateInvoiceWorkspace(invoice)
            invoice.quickBooksID = confirmed.Id
            invoice.quickBooksBalanceDue = confirmed.Balance
            if let rawDueDate = confirmed.DueDate,
               let dueDate = QuickBooksDateOnly.date(from: rawDueDate) {
                invoice.dueDate = dueDate
            }
            let taxIssue = invoice.applyQuickBooksTaxResult(
                total: confirmed.TotalAmt,
                reportedTax: confirmed.TxnTaxDetail?.TotalTax
            )
            invoice.quickBooksSyncStatus = taxIssue == nil ? "synced" : "needs_attention"
            invoice.quickBooksSyncDetail = taxIssue
            invoice.quickBooksLastSyncedAt = Date()
        }
    }

    private func createCardToken(_ input: QuickBooksPaymentsCardInput) async throws -> QuickBooksPaymentsTokenResponse {

        let normalizedCardNumber =
            input.cardNumber.filter(\.isNumber)

        let normalizedMonth =
            String(format: "%02d", Int(input.expMonth) ?? 0)

        let normalizedYear: String = {
            let trimmed = input.expYear.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.count == 2 {
                return "20\(trimmed)"
            }

            return trimmed
        }()

        let normalizedCVC =
            input.cvc.filter(\.isNumber)

        guard normalizedCardNumber.count >= 12,
              (1...12).contains(Int(normalizedMonth) ?? 0),
              normalizedYear.count == 4,
              normalizedCVC.count >= 3 else {
            throw QuickBooksPaymentsServiceError.invalidPaymentInput
        }

        let normalizedPostal =
            input.postalCode?
                .trimmingCharacters(in: .whitespacesAndNewlines)

        let normalizedRegion =
            input.region?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()

        let normalizedCountry =
            input.country?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased() ?? "US"

        let tokenRequest = QuickBooksPaymentsTokenCreateRequest(
            card: QuickBooksPaymentsCard(
                expYear: normalizedYear,
                expMonth: normalizedMonth,
                address: QuickBooksPaymentsCardAddress(
                    region: normalizedRegion,
                    postalCode: normalizedPostal,
                    streetAddress: input.addressLine?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    country: normalizedCountry,
                    city: input.city?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                ),
                name: input.cardholderName
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                cvc: normalizedCVC,
                number: normalizedCardNumber
            ),
            bankAccount: nil
        )

        return try await withCheckedThrowingContinuation { continuation in
            api.createCardToken(tokenRequest) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func createBankAccountToken(_ input: QuickBooksPaymentsBankAccountInput) async throws -> QuickBooksPaymentsTokenResponse {
        let normalizedName = input.accountHolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAccountNumber = input.accountNumber.filter(\.isNumber)
        let normalizedRoutingNumber = input.routingNumber.filter(\.isNumber)
        let normalizedPhone = input.phone.filter(\.isNumber)

        guard !normalizedName.isEmpty,
              normalizedName.count <= 64,
              (4...17).contains(normalizedAccountNumber.count),
              normalizedRoutingNumber.count == 9,
              normalizedPhone.count == 10 else {
            throw QuickBooksPaymentsServiceError.invalidBankAccountInput
        }

        let tokenRequest = QuickBooksPaymentsTokenCreateRequest(
            card: nil,
            bankAccount: QuickBooksPaymentsBankAccount(
                name: normalizedName,
                accountNumber: normalizedAccountNumber,
                phone: normalizedPhone,
                routingNumber: normalizedRoutingNumber,
                accountType: input.accountType.rawValue
            )
        )

        return try await withCheckedThrowingContinuation { continuation in
            api.createCardToken(tokenRequest) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func createAuthorization(
        amount: Double,
        token: String,
        note: String?,
        clientTransactionID: String,
        requestID: UUID
    ) async throws -> QuickBooksPaymentsChargeResponse {
        let charge = QuickBooksPaymentsChargeCreate(
            amount: Self.currencyString(amount),
            currency: "USD",
            capture: true,
            token: token,
            description: note,
            context: QuickBooksPaymentsChargeContext.forClientTransactionID(clientTransactionID),
            paymentMode: nil,
            checkNumber: nil
        )

        return try await withCheckedThrowingContinuation { continuation in
            api.createCharge(charge, requestID: requestID) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func captureCharge(id: String, amount: Double) async throws -> QuickBooksPaymentsChargeResponse {
        try await withCheckedThrowingContinuation { continuation in
            api.captureCharge(id: id, amount: amount) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func createBankCharge(
        amount: Double,
        token: String,
        note: String?,
        clientTransactionID: String,
        checkNumber: String?,
        requestID: UUID
    ) async throws -> QuickBooksPaymentsChargeResponse {
        let charge = QuickBooksPaymentsECheckCreate(
            amount: Self.currencyString(amount),
            token: token,
            description: note,
            context: QuickBooksPaymentsChargeContext.forClientTransactionID(clientTransactionID),
            paymentMode: "WEB",
            checkNumber: checkNumber?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? checkNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
        )

        return try await withCheckedThrowingContinuation { continuation in
            api.createECheck(charge, requestID: requestID) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func refundCharge(
        rail: QuickBooksPaymentRail,
        id: String,
        amount: Double,
        note: String?,
        clientTransactionID: String,
        requestID: UUID
    ) async throws -> QuickBooksPaymentsRefundResponse {
        try await withCheckedThrowingContinuation { continuation in
            switch rail {
            case .card:
                api.refundCharge(id: id, amount: amount, description: note, clientTransactionID: clientTransactionID, requestID: requestID) {
                    continuation.resume(with: $0)
                }
            case .bank:
                api.refundECheck(id: id, amount: amount, description: note, clientTransactionID: clientTransactionID, requestID: requestID) {
                    continuation.resume(with: $0)
                }
            }
        }
    }

    private func syncAccountingPayment(
        localPaymentID: UUID,
        invoice: Invoice,
        customerQBID: String,
        amount: Double,
        note: String?,
        charge: QuickBooksPaymentsChargeResponse,
        clientTransactionID: String,
        paymentKind: AccountingPaymentKind
    ) async -> (payment: QuickBooksPayment?, error: String?) {
        guard invoice.quickBooksID.nilIfBlank != nil else {
            return (nil, QuickBooksPaymentsServiceError.invoiceNotSyncedToQuickBooks.localizedDescription)
        }

        do {
            let payload = try await quickBooksPaymentPayload(
                invoice: invoice,
                customerQBID: customerQBID,
                amount: amount,
                note: note,
                paymentRef: charge.resolvedClientTransID ?? charge.id,
                clientTransactionID: clientTransactionID,
                paymentKind: paymentKind
            )
            let payment = try await recoverOrCreateAccountingPayment(
                localPaymentID: localPaymentID,
                payload: payload
            )
            return (payment, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    private func syncRefundReceipt(
        localPaymentID: UUID,
        invoice: Invoice,
        customerQBID: String,
        salesItemRef: String,
        amount: Double,
        note: String?,
        clientTransactionID: String
    ) async -> (receipt: QuickBooksRefundReceipt?, error: String?) {
        guard let customer = invoice.customer else {
            return (nil, QuickBooksPaymentsServiceError.invoiceRelationshipUnavailable.localizedDescription)
        }
        let description = invoice.lineItemSummary.isEmpty ? "Refund" : invoice.lineItemSummary
        let receipt = QuickBooksRefundReceiptCreate(
            Line: [
                QuickBooksLineItem(
                    Amount: amount,
                    DetailType: "SalesItemLineDetail",
                    Description: description,
                    SalesItemLineDetail: QuickBooksSalesItemLineDetail(
                        ItemRef: QuickBooksReference(value: salesItemRef, name: nil)
                    )
                )
            ],
            CustomerRef: QuickBooksReference(value: customerQBID, name: customer.name),
            // The Payments refund has already been issued. This is accounting
            // only, including ACH; never request another card transaction.
            CreditCardPayment: nil,
            TxnSource: nil,
            PrivateNote: accountingNote(baseNote: note, clientTransactionID: clientTransactionID)
        )

        do {
            let response = try await withCheckedThrowingContinuation { continuation in
                api.recoverOrCreateRefundReceipt(receipt, localPaymentID: localPaymentID) { result in
                    continuation.resume(with: result)
                }
            }
            return (response, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    private static func currencyString(_ amount: Double) -> String {
        String(format: "%.2f", amount)
    }

    private static func nilIfBlank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func quickBooksPaymentRefNum(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }

        let compact = trimmed
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "\n", with: "-")
            .replacingOccurrences(of: "\t", with: "-")

        guard !compact.isEmpty else { return nil }
        return String(compact.prefix(21))
    }

    private static func chargeClientTransactionID(for localPaymentID: UUID) -> String {
        "ga-charge-\(localPaymentID.uuidString.lowercased())"
    }

    private func accountingNote(baseNote: String?, clientTransactionID: String) -> String {
        let identifierLine = "Client transaction ID: \(clientTransactionID)"
        if let trimmed = baseNote?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            return "\(trimmed)\n\(identifierLine)"
        }
        return identifierLine
    }

    private func quickBooksPaymentPayload(
        invoice: Invoice,
        customerQBID: String,
        amount: Double,
        note: String?,
        paymentRef: String,
        clientTransactionID: String? = nil,
        paymentKind: AccountingPaymentKind
    ) async throws -> QuickBooksPaymentCreate {
        guard let invoiceQBID = invoice.quickBooksID.nilIfBlank else {
            throw QuickBooksPaymentsServiceError.invoiceNotSyncedToQuickBooks
        }

        let lines: [QuickBooksPaymentLine]? = [
            QuickBooksPaymentLine(
                Amount: amount,
                LinkedTxn: [QuickBooksLinkedTxn(TxnId: invoiceQBID, TxnType: "Invoice")]
            )
        ]

        let paymentMethodRef = await resolvePaymentMethodReference(for: paymentKind)

        // Do not send CreditCardPayment/ProcessPayment here. The card/ACH charge
        // was already handled by QuickBooks Payments. Sending ProcessPayment=true
        // on the QBO Accounting Payment causes QuickBooks to reject the follow-up
        // sync with “Feature not supported error : true”.
        let creditCardPayment: QuickBooksCreditCardPayment? = nil

        let privateNote: String?
        if let clientTransactionID {
            privateNote = accountingNote(baseNote: note, clientTransactionID: clientTransactionID)
        } else {
            privateNote = note
        }

        return QuickBooksPaymentCreate(
            CustomerRef: QuickBooksReference(value: customerQBID, name: invoice.customer?.name),
            TotalAmt: amount,
            PrivateNote: privateNote,
            PaymentRefNum: Self.quickBooksPaymentRefNum(paymentRef),
            Line: lines,
            PaymentMethodRef: paymentMethodRef,
            CreditCardPayment: creditCardPayment
        )
    }

    private func recoverOrCreateAccountingPayment(
        localPaymentID: UUID,
        payload: QuickBooksPaymentCreate
    ) async throws -> QuickBooksPayment {
        let draft = QuickBooksAccountingPaymentDraft(
            localPaymentID: localPaymentID,
            payment: payload
        )
        return try await withCheckedThrowingContinuation { continuation in
            api.recoverOrCreatePayment(draft) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func resolvePaymentMethodReference(for kind: AccountingPaymentKind) async -> QuickBooksReference? {
        let methodName: String
        let methodType: String?
        switch kind {
        case .card:
            methodName = "QuickBooks Card"
            methodType = "CREDIT_CARD"
        case .ach:
            methodName = "QuickBooks ACH"
            methodType = "NON_CREDIT_CARD"
        case .manual(let provided):
            methodName = provided
            methodType = provided.lowercased().contains("card") ? "CREDIT_CARD" : "NON_CREDIT_CARD"
        }

        do {
            let methods = try await withCheckedThrowingContinuation { continuation in
                api.fetchPaymentMethods { result in
                    continuation.resume(with: result)
                }
            }
            if let existing = methods.first(where: { $0.Name.caseInsensitiveCompare(methodName) == .orderedSame }) {
                return existing.reference
            }
            let created = try await withCheckedThrowingContinuation { continuation in
                api.createPaymentMethod(
                    QuickBooksPaymentMethodCreate(Name: methodName, methodType: methodType)
                ) { result in
                    continuation.resume(with: result)
                }
            }
            return created.reference
        } catch {
            return nil
        }
    }

    private func paymentKind(for payment: Payment) -> AccountingPaymentKind {
        if payment.quickBooksChargeID.nilIfBlank != nil {
            if payment.method.lowercased().contains("ach") {
                return .ach(chargeID: payment.quickBooksChargeID.nilIfBlank ?? payment.id.uuidString)
            }
            return .card(chargeID: payment.quickBooksChargeID.nilIfBlank ?? payment.id.uuidString)
        }
        let baseMethod = payment.method.trimmingCharacters(in: .whitespacesAndNewlines)
        return .manual(methodName: baseMethod.isEmpty ? "Manual Payment" : baseMethod.capitalized)
    }
}

enum QuickBooksPaymentsServiceError: LocalizedError, Equatable {
    case customerNotSynced
    case invoiceRelationshipUnavailable
    case chargeNotSynced
    case missingSalesItemReference
    case invalidRetryTarget
    case invoiceNotSyncedToQuickBooks
    case quickBooksSessionExpired
    case invalidPaymentInput
    case invalidBankAccountInput
    case invalidAmount
    case authoritativeTaxRequired(String)
    case unconfirmedProcessorResponse(String)

    var errorDescription: String? {
        switch self {
        case .customerNotSynced:
            return "This customer needs a QuickBooks customer ID before QuickBooks Payments can be processed."
        case .invoiceRelationshipUnavailable:
            return "This payment is still waiting for its CloudKit invoice and customer links. Keep GunnAire Ops open until sync finishes, then retry; no QuickBooks request was sent."
        case .chargeNotSynced:
            return "This payment does not have a QuickBooks Payments charge ID to refund."
        case .missingSalesItemReference:
            return "Ask an administrator to open QuickBooks Management → Overview → Accounting Mappings and choose the default sales item before creating QuickBooks invoices, payments, or refund receipts."
        case .invalidRetryTarget:
            return "This QuickBooks sync retry target is not valid for the requested recovery action."
        case .invoiceNotSyncedToQuickBooks:
            return "Sync this invoice to QuickBooks before syncing or retrying the accounting payment."
        case .quickBooksSessionExpired:
            return "Reconnect QuickBooks before processing this payment. The saved QuickBooks session could not be refreshed."
        case .invalidAmount:
            return "Enter a positive payment amount in dollars and cents. A refund cannot exceed the original payment."
        case .invalidPaymentInput:
            return "Enter a valid card number, expiration date, and CVC before sending payment details to QuickBooks Payments."
        case .invalidBankAccountInput:
            return "Enter valid ACH details before sending bank-account details to QuickBooks Payments: holder name up to 64 characters, account number 4-17 digits, routing number 9 digits, and phone number exactly 10 digits."
        case .authoritativeTaxRequired(let detail):
            return detail
        case .unconfirmedProcessorResponse(let detail):
            return "QuickBooks Payments did not return enough matching evidence to confirm this transaction. \(detail) Do not retry until the transaction is reconciled in QuickBooks."
        }
    }
}

enum QuickBooksPaymentsResponsePolicy {
    enum ChargeKind {
        case capturedCard
        case submittedBank
    }

    private static let failureStatuses: Set<String> = [
        "cancelled", "canceled", "declined", "error", "failed", "failure",
        "rejected", "unknown", "voided"
    ]
    private static let capturedCardStatuses: Set<String> = [
        "captured", "completed", "paid", "settled", "succeeded"
    ]
    private static let submittedBankStatuses: Set<String> = [
        "authorized", "captured", "completed", "paid", "pending", "processing",
        "settled", "submitted", "succeeded"
    ]
    private static let acceptedRefundStatuses: Set<String> = [
        "completed", "pending", "processing", "refunded", "settled", "submitted", "succeeded"
    ]

    static func validateCharge(
        _ response: QuickBooksPaymentsChargeResponse,
        expectedAmount: Double,
        expectedClientTransactionID: String,
        kind: ChargeKind
    ) throws {
        try validateIdentifier(response.id, operation: "charge")
        try validateAmount(response.amount, expected: expectedAmount, operation: "charge")
        try validateClientTransactionID(
            response.resolvedClientTransID,
            expected: expectedClientTransactionID,
            operation: "charge"
        )
        if let currency = normalized(response.currency), currency != "usd" {
            throw QuickBooksPaymentsServiceError.unconfirmedProcessorResponse(
                "The charge currency did not match USD."
            )
        }

        let status = normalized(response.status)
        if let status, failureStatuses.contains(status) {
            throw QuickBooksPaymentsServiceError.unconfirmedProcessorResponse(
                "The processor reported charge status \(status.uppercased())."
            )
        }

        let accepted: Bool
        switch kind {
        case .capturedCard:
            accepted = response.capture == true || status.map(capturedCardStatuses.contains) == true
        case .submittedBank:
            accepted = response.capture == true || status.map(submittedBankStatuses.contains) == true
        }
        guard accepted else {
            throw QuickBooksPaymentsServiceError.unconfirmedProcessorResponse(
                "The response did not confirm a captured card charge or an accepted bank submission."
            )
        }
    }

    static func validateRefund(
        _ response: QuickBooksPaymentsRefundResponse,
        expectedAmount: Double,
        expectedClientTransactionID: String
    ) throws {
        try validateIdentifier(response.id, operation: "refund")
        try validateAmount(response.amount, expected: expectedAmount, operation: "refund")
        try validateClientTransactionID(
            response.resolvedClientTransID,
            expected: expectedClientTransactionID,
            operation: "refund"
        )

        guard let status = normalized(response.status),
              !failureStatuses.contains(status),
              acceptedRefundStatuses.contains(status) else {
            throw QuickBooksPaymentsServiceError.unconfirmedProcessorResponse(
                "The response did not confirm an accepted refund status."
            )
        }
    }

    private static func validateIdentifier(_ raw: String, operation: String) throws {
        guard normalized(raw) != nil else {
            throw QuickBooksPaymentsServiceError.unconfirmedProcessorResponse(
                "The \(operation) response did not include a provider transaction ID."
            )
        }
    }

    private static func validateAmount(_ raw: String?, expected: Double, operation: String) throws {
        guard let raw = normalized(raw),
              let received = Double(raw),
              received.isFinite,
              abs(received - expected) < 0.005 else {
            throw QuickBooksPaymentsServiceError.unconfirmedProcessorResponse(
                "The \(operation) amount was missing or did not match \(String(format: "%.2f", expected))."
            )
        }
    }

    private static func validateClientTransactionID(
        _ returned: String?,
        expected: String,
        operation: String
    ) throws {
        guard let returned = normalized(returned) else { return }
        guard returned == expected else {
            throw QuickBooksPaymentsServiceError.unconfirmedProcessorResponse(
                "The \(operation) response belonged to a different client transaction."
            )
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value.lowercased()
    }
}

private extension Optional<String> {
    var nilIfBlank: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
