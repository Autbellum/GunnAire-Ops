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

struct QuickBooksProcessedPaymentResult {
    let charge: QuickBooksPaymentsChargeResponse
    let accountingPayment: QuickBooksPayment?
    let accountingError: String?
}

struct QuickBooksProcessedRefundResult {
    let refund: QuickBooksPaymentsRefundResponse
    let refundReceipt: QuickBooksRefundReceipt?
    let accountingError: String?
}

final class QuickBooksPaymentsService {
    static let shared = QuickBooksPaymentsService()

    private let api = QuickBooksDataAPI.shared

    private init() {}

    func processCardPayment(
        invoice: Invoice,
        amount: Double,
        cardInput: QuickBooksPaymentsCardInput,
        note: String?
    ) async throws -> QuickBooksProcessedPaymentResult {
        guard let customerQBID = invoice.customer.quickBooksID, !customerQBID.isEmpty else {
            throw QuickBooksPaymentsServiceError.customerNotSynced
        }

        let token = try await createCardToken(cardInput)
        let authorized = try await createAuthorization(amount: amount, token: token.value, note: note)
        let charge = try await captureCharge(id: authorized.id, amount: amount)
        let accountingPayment = await syncAccountingPayment(
            invoice: invoice,
            customerQBID: customerQBID,
            amount: amount,
            note: note,
            charge: charge
        )

        return QuickBooksProcessedPaymentResult(
            charge: charge,
            accountingPayment: accountingPayment.payment,
            accountingError: accountingPayment.error
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

        let refund = try await refundCharge(id: chargeID, amount: amount, note: note)
        let refundReceipt = await syncRefundReceipt(
            payment: payment,
            customerQBID: customerQBID,
            salesItemRef: salesItemRef,
            amount: amount,
            note: note,
            refund: refund
        )

        return QuickBooksProcessedRefundResult(
            refund: refund,
            refundReceipt: refundReceipt.receipt,
            accountingError: refundReceipt.error
        )
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
            )
        )

        return try await withCheckedThrowingContinuation { continuation in
            api.createCardToken(tokenRequest) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func createAuthorization(amount: Double, token: String, note: String?) async throws -> QuickBooksPaymentsChargeResponse {
        let charge = QuickBooksPaymentsChargeCreate(
            amount: Self.currencyString(amount),
            currency: "USD",
            capture: false,
            token: token,
            description: note,
            context: QuickBooksPaymentsChargeContext.defaultForApp
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

    private func refundCharge(id: String, amount: Double, note: String?) async throws -> QuickBooksPaymentsRefundResponse {
        try await withCheckedThrowingContinuation { continuation in
            api.refundCharge(id: id, amount: amount, description: note) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func syncAccountingPayment(
        invoice: Invoice,
        customerQBID: String,
        amount: Double,
        note: String?,
        charge: QuickBooksPaymentsChargeResponse
    ) async -> (payment: QuickBooksPayment?, error: String?) {
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

        let payload = QuickBooksPaymentCreate(
            CustomerRef: QuickBooksReference(value: customerQBID, name: invoice.customer.name),
            TotalAmt: amount,
            PrivateNote: note,
            PaymentRefNum: charge.resolvedClientTransID ?? charge.id,
            Line: lines
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
        refund: QuickBooksPaymentsRefundResponse
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
            PrivateNote: note
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
}

enum QuickBooksPaymentsServiceError: LocalizedError {
    case customerNotSynced
    case chargeNotSynced
    case missingSalesItemReference

    var errorDescription: String? {
        switch self {
        case .customerNotSynced:
            return "This customer needs a QuickBooks customer ID before QuickBooks Payments can be processed."
        case .chargeNotSynced:
            return "This payment does not have a QuickBooks Payments charge ID to refund."
        case .missingSalesItemReference:
            return "Set QB_DEFAULT_ITEM_REF before creating QuickBooks refund receipts."
        }
    }
}
