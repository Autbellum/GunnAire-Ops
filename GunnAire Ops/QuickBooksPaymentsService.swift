import Foundation

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
}

struct QuickBooksProcessedRefundResult {
    let refund: QuickBooksPaymentsRefundResponse
    let refundReceipt: QuickBooksRefundReceipt?
    let accountingError: String?
    let clientTransactionID: String?
}

final class QuickBooksPaymentsService {
    static let shared = QuickBooksPaymentsService()

    private let api = QuickBooksDataAPI.shared

    private init() {}

    private enum AccountingPaymentKind {
        case card(chargeID: String)
        case ach(chargeID: String)
        case manual(methodName: String)
    }

    func processCardPayment(
        invoice: Invoice,
        amount: Double,
        cardInput: QuickBooksPaymentsCardInput,
        note: String?
    ) async throws -> QuickBooksProcessedPaymentResult {
        guard let customerQBID = invoice.customer.quickBooksID, !customerQBID.isEmpty else {
            throw QuickBooksPaymentsServiceError.customerNotSynced
        }

        let clientTransactionID = Self.chargeClientTransactionID(for: invoice, amount: amount)
        let token = try await createCardToken(cardInput)
        let authorized = try await createAuthorization(
            amount: amount,
            token: token.value,
            note: note,
            clientTransactionID: clientTransactionID
        )
        let charge = try await captureCharge(id: authorized.id, amount: amount)
        let accountingPayment = await syncAccountingPayment(
            invoice: invoice,
            customerQBID: customerQBID,
            amount: amount,
            note: note,
            charge: charge,
            clientTransactionID: clientTransactionID,
            paymentKind: .card(chargeID: charge.id)
        )

        return QuickBooksProcessedPaymentResult(
            charge: charge,
            accountingPayment: accountingPayment.payment,
            accountingError: accountingPayment.error,
            clientTransactionID: charge.resolvedClientTransID ?? clientTransactionID
        )
    }

    func processBankPayment(
        invoice: Invoice,
        amount: Double,
        bankInput: QuickBooksPaymentsBankAccountInput,
        note: String?
    ) async throws -> QuickBooksProcessedPaymentResult {
        guard let customerQBID = invoice.customer.quickBooksID, !customerQBID.isEmpty else {
            throw QuickBooksPaymentsServiceError.customerNotSynced
        }

        let clientTransactionID = Self.chargeClientTransactionID(for: invoice, amount: amount)
        let token = try await createBankAccountToken(bankInput)
        let charge = try await createBankCharge(
            amount: amount,
            token: token.value,
            note: note,
            clientTransactionID: clientTransactionID,
            checkNumber: bankInput.checkNumber
        )
        let accountingPayment = await syncAccountingPayment(
            invoice: invoice,
            customerQBID: customerQBID,
            amount: amount,
            note: note,
            charge: charge,
            clientTransactionID: clientTransactionID,
            paymentKind: .ach(chargeID: charge.id)
        )

        return QuickBooksProcessedPaymentResult(
            charge: charge,
            accountingPayment: accountingPayment.payment,
            accountingError: accountingPayment.error,
            clientTransactionID: charge.resolvedClientTransID ?? clientTransactionID
        )
    }

    func refundPayment(
        payment: Payment,
        amount: Double,
        note: String?
    ) async throws -> QuickBooksProcessedRefundResult {
        guard let chargeID = payment.quickBooksChargeID, !chargeID.isEmpty else {
            throw QuickBooksPaymentsServiceError.chargeNotSynced
        }
        guard let customerQBID = payment.invoice.customer.quickBooksID, !customerQBID.isEmpty else {
            throw QuickBooksPaymentsServiceError.customerNotSynced
        }
        guard let salesItemRef = resolvedSalesItemRef else {
            throw QuickBooksPaymentsServiceError.missingSalesItemReference
        }

        let clientTransactionID = Self.refundClientTransactionID(for: payment, amount: amount)
        let refund = try await refundCharge(
            id: chargeID,
            amount: amount,
            note: note,
            clientTransactionID: clientTransactionID
        )
        let refundReceipt = await syncRefundReceipt(
            payment: payment,
            customerQBID: customerQBID,
            salesItemRef: salesItemRef,
            amount: amount,
            note: note,
            refund: refund,
            clientTransactionID: clientTransactionID
        )

        return QuickBooksProcessedRefundResult(
            refund: refund,
            refundReceipt: refundReceipt.receipt,
            accountingError: refundReceipt.error,
            clientTransactionID: refund.resolvedClientTransID ?? clientTransactionID
        )
    }

    func retryAccountingSync(for payment: Payment) async throws -> QuickBooksPayment {
        guard !payment.isRefund else {
            throw QuickBooksPaymentsServiceError.invalidRetryTarget
        }
        guard let customerQBID = payment.invoice.customer.quickBooksID, !customerQBID.isEmpty else {
            throw QuickBooksPaymentsServiceError.customerNotSynced
        }

        let payload = await quickBooksPaymentPayload(
            invoice: payment.invoice,
            customerQBID: customerQBID,
            amount: payment.amount,
            note: payment.notes,
            paymentRef: payment.quickBooksClientTransID.nilIfBlank ?? payment.quickBooksChargeID.nilIfBlank ?? payment.id.uuidString,
            paymentKind: paymentKind(for: payment)
        )

        return try await withCheckedThrowingContinuation { continuation in
            api.createPayment(payload) { result in
                continuation.resume(with: result)
            }
        }
    }

    func retryRefundReceiptSync(for refundPayment: Payment) async throws -> QuickBooksRefundReceipt {
        guard refundPayment.isRefund else {
            throw QuickBooksPaymentsServiceError.invalidRetryTarget
        }
        guard let customerQBID = refundPayment.invoice.customer.quickBooksID, !customerQBID.isEmpty else {
            throw QuickBooksPaymentsServiceError.customerNotSynced
        }
        guard let refundID = refundPayment.quickBooksChargeID.nilIfBlank else {
            throw QuickBooksPaymentsServiceError.chargeNotSynced
        }
        guard let salesItemRef = resolvedSalesItemRef else {
            throw QuickBooksPaymentsServiceError.missingSalesItemReference
        }

        let description = refundPayment.invoice.lineItemSummary.isEmpty ? "Refund" : refundPayment.invoice.lineItemSummary
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
            CustomerRef: QuickBooksReference(value: customerQBID, name: refundPayment.invoice.customer.name),
            CreditCardPayment: QuickBooksCreditCardPayment(
                CreditChargeInfo: QuickBooksCreditChargeInfo(ProcessPayment: "true"),
                CreditChargeResponse: QuickBooksCreditChargeResponse(CCTransId: refundID)
            ),
            TxnSource: "IntuitPayment",
            PrivateNote: accountingNote(
                baseNote: refundPayment.notes,
                clientTransactionID: refundPayment.quickBooksClientTransID.nilIfBlank ?? refundID
            )
        )

        return try await withCheckedThrowingContinuation { continuation in
            api.createRefundReceipt(receipt) { result in
                continuation.resume(with: result)
            }
        }
    }

    private var resolvedSalesItemRef: String? {
        guard Config.QuickBooks.hasExplicitDefaultSalesItemRef else { return nil }
        let trimmed = Config.QuickBooks.defaultSalesItemRef.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func createCardToken(_ input: QuickBooksPaymentsCardInput) async throws -> QuickBooksPaymentsTokenResponse {
        let tokenRequest = QuickBooksPaymentsTokenCreateRequest(
            card: QuickBooksPaymentsCard(
                expYear: input.expYear,
                expMonth: input.expMonth,
                address: QuickBooksPaymentsCardAddress(
                    region: input.region,
                    postalCode: input.postalCode,
                    streetAddress: input.addressLine,
                    country: input.country ?? "US",
                    city: input.city
                ),
                name: input.cardholderName,
                cvc: input.cvc,
                number: input.cardNumber
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
        let tokenRequest = QuickBooksPaymentsTokenCreateRequest(
            card: nil,
            bankAccount: QuickBooksPaymentsBankAccount(
                name: input.accountHolderName,
                accountNumber: input.accountNumber,
                phone: input.phone,
                routingNumber: input.routingNumber,
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
        clientTransactionID: String
    ) async throws -> QuickBooksPaymentsChargeResponse {
        let charge = QuickBooksPaymentsChargeCreate(
            amount: Self.currencyString(amount),
            currency: "USD",
            capture: false,
            token: token,
            description: note,
            context: QuickBooksPaymentsChargeContext.forClientTransactionID(clientTransactionID),
            paymentMode: nil,
            checkNumber: nil
        )

        return try await withCheckedThrowingContinuation { continuation in
            api.createCharge(charge) { result in
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
        checkNumber: String?
    ) async throws -> QuickBooksPaymentsChargeResponse {
        let charge = QuickBooksPaymentsChargeCreate(
            amount: Self.currencyString(amount),
            currency: nil,
            capture: nil,
            token: token,
            description: note,
            context: QuickBooksPaymentsChargeContext.forClientTransactionID(clientTransactionID),
            paymentMode: "WEB",
            checkNumber: checkNumber?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? checkNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
        )

        return try await withCheckedThrowingContinuation { continuation in
            api.createCharge(charge) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func refundCharge(
        id: String,
        amount: Double,
        note: String?,
        clientTransactionID: String
    ) async throws -> QuickBooksPaymentsRefundResponse {
        try await withCheckedThrowingContinuation { continuation in
            api.refundCharge(
                id: id,
                amount: amount,
                description: note,
                clientTransactionID: clientTransactionID
            ) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func syncAccountingPayment(
        invoice: Invoice,
        customerQBID: String,
        amount: Double,
        note: String?,
        charge: QuickBooksPaymentsChargeResponse,
        clientTransactionID: String,
        paymentKind: AccountingPaymentKind
    ) async -> (payment: QuickBooksPayment?, error: String?) {
        let payload = await quickBooksPaymentPayload(
            invoice: invoice,
            customerQBID: customerQBID,
            amount: amount,
            note: note,
            paymentRef: charge.resolvedClientTransID ?? charge.id,
            clientTransactionID: clientTransactionID,
            paymentKind: paymentKind
        )

        do {
            let payment = try await withCheckedThrowingContinuation { continuation in
                api.createPayment(payload) { result in
                    continuation.resume(with: result)
                }
            }
            return (payment, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    private func syncRefundReceipt(
        payment: Payment,
        customerQBID: String,
        salesItemRef: String,
        amount: Double,
        note: String?,
        refund: QuickBooksPaymentsRefundResponse,
        clientTransactionID: String
    ) async -> (receipt: QuickBooksRefundReceipt?, error: String?) {
        let description = payment.invoice.lineItemSummary.isEmpty ? "Refund" : payment.invoice.lineItemSummary
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
            CustomerRef: QuickBooksReference(value: customerQBID, name: payment.invoice.customer.name),
            CreditCardPayment: QuickBooksCreditCardPayment(
                CreditChargeInfo: QuickBooksCreditChargeInfo(ProcessPayment: "true"),
                CreditChargeResponse: QuickBooksCreditChargeResponse(CCTransId: refund.id)
            ),
            TxnSource: "IntuitPayment",
            PrivateNote: accountingNote(baseNote: note, clientTransactionID: clientTransactionID)
        )

        do {
            let response = try await withCheckedThrowingContinuation { continuation in
                api.createRefundReceipt(receipt) { result in
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

    private static func chargeClientTransactionID(for invoice: Invoice, amount: Double) -> String {
        let cents = Int((amount * 100).rounded())
        return "ga-charge-\(invoice.id.uuidString.lowercased())-\(cents)-\(UUID().uuidString.lowercased())"
    }

    private static func refundClientTransactionID(for payment: Payment, amount: Double) -> String {
        let cents = Int((amount * 100).rounded())
        return "ga-refund-\(payment.id.uuidString.lowercased())-\(cents)-\(UUID().uuidString.lowercased())"
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
    ) async -> QuickBooksPaymentCreate {
        let lines: [QuickBooksPaymentLine]?
        if let invoiceQBID = invoice.quickBooksID, !invoiceQBID.isEmpty {
            lines = [
                QuickBooksPaymentLine(
                    Amount: amount,
                    LinkedTxn: [QuickBooksLinkedTxn(TxnId: invoiceQBID, TxnType: "Invoice")]
                )
            ]
        } else {
            lines = nil
        }

        let paymentMethodRef = await resolvePaymentMethodReference(for: paymentKind)
        let creditCardPayment: QuickBooksCreditCardPayment?
        switch paymentKind {
        case .card(let chargeID), .ach(let chargeID):
            creditCardPayment = QuickBooksCreditCardPayment(
                CreditChargeInfo: QuickBooksCreditChargeInfo(ProcessPayment: "true"),
                CreditChargeResponse: QuickBooksCreditChargeResponse(CCTransId: chargeID)
            )
        case .manual:
            creditCardPayment = nil
        }

        return QuickBooksPaymentCreate(
            CustomerRef: QuickBooksReference(value: customerQBID, name: invoice.customer.name),
            TotalAmt: amount,
            PrivateNote: clientTransactionID == nil ? note : accountingNote(baseNote: note, clientTransactionID: clientTransactionID!),
            PaymentRefNum: paymentRef,
            Line: lines,
            PaymentMethodRef: paymentMethodRef,
            CreditCardPayment: creditCardPayment
        )
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

enum QuickBooksPaymentsServiceError: LocalizedError {
    case customerNotSynced
    case chargeNotSynced
    case missingSalesItemReference
    case invalidRetryTarget

    var errorDescription: String? {
        switch self {
        case .customerNotSynced:
            return "This customer needs a QuickBooks customer ID before QuickBooks Payments can be processed."
        case .chargeNotSynced:
            return "This payment does not have a QuickBooks Payments charge ID to refund."
        case .missingSalesItemReference:
            return "Set QB_DEFAULT_ITEM_REF before creating QuickBooks refund receipts."
        case .invalidRetryTarget:
            return "This QuickBooks sync retry target is not valid for the requested recovery action."
        }
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
