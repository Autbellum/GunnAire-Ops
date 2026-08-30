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
        note: String?,
        catalogItems: [Item]
    ) async throws -> QuickBooksProcessedPaymentResult {
        let customerQBID = try await prepareInvoiceForQuickBooksPayment(
            invoice,
            catalogItems: catalogItems
        )

        let clientTransactionID = Self.chargeClientTransactionID(for: invoice, amount: amount)
        let token = try await createCardToken(cardInput)
        let authorized = try await createAuthorization(
            amount: amount,
            token: token.value,
            note: note,
            clientTransactionID: clientTransactionID
        )
        try QuickBooksPaymentsResponsePolicy.validateCharge(
            authorized,
            expectedAmount: amount,
            expectedClientTransactionID: clientTransactionID,
            kind: .capturedCard
        )
        let charge = authorized

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

    func createStandaloneCardToken(_ input: QuickBooksPaymentsCardInput) async throws -> QuickBooksPaymentsTokenResponse {
        try await createCardToken(input)
    }

    func processBankPayment(
        invoice: Invoice,
        amount: Double,
        bankInput: QuickBooksPaymentsBankAccountInput,
        note: String?,
        catalogItems: [Item]
    ) async throws -> QuickBooksProcessedPaymentResult {
        let customerQBID = try await prepareInvoiceForQuickBooksPayment(
            invoice,
            catalogItems: catalogItems
        )

        let clientTransactionID = Self.chargeClientTransactionID(for: invoice, amount: amount)
        let token = try await createBankAccountToken(bankInput)
        let charge = try await createBankCharge(
            amount: amount,
            token: token.value,
            note: note,
            clientTransactionID: clientTransactionID,
            checkNumber: bankInput.checkNumber
        )
        try QuickBooksPaymentsResponsePolicy.validateCharge(
            charge,
            expectedAmount: amount,
            expectedClientTransactionID: clientTransactionID,
            kind: .submittedBank
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
        guard let salesItemRef = await resolvedSalesItemRef() else {
            throw QuickBooksPaymentsServiceError.missingSalesItemReference
        }

        let clientTransactionID = Self.refundClientTransactionID(for: payment, amount: amount)
        let refund = try await refundCharge(
            id: chargeID,
            amount: amount,
            note: note,
            clientTransactionID: clientTransactionID
        )
        try QuickBooksPaymentsResponsePolicy.validateRefund(
            refund,
            expectedAmount: amount,
            expectedClientTransactionID: clientTransactionID
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
        guard payment.invoice.quickBooksID.nilIfBlank != nil else {
            throw QuickBooksPaymentsServiceError.invoiceNotSyncedToQuickBooks
        }

        let payload = await quickBooksPaymentPayload(
            invoice: payment.invoice,
            customerQBID: customerQBID,
            amount: payment.amount,
            note: payment.notes,
            paymentRef: payment.quickBooksClientTransID.nilIfBlank ?? payment.quickBooksChargeID.nilIfBlank ?? payment.id.uuidString,
            clientTransactionID: payment.quickBooksClientTransID.nilIfBlank,
            paymentKind: paymentKind(for: payment)
        )

        return try await withCheckedThrowingContinuation { continuation in
            api.createPayment(payload) { result in
                continuation.resume(with: result)
            }
        }
    }

    func syncManualAccountingPayment(for payment: Payment) async throws -> QuickBooksPayment {
        guard !payment.isRefund else {
            throw QuickBooksPaymentsServiceError.invalidRetryTarget
        }
        guard let customerQBID = payment.invoice.customer.quickBooksID, !customerQBID.isEmpty else {
            throw QuickBooksPaymentsServiceError.customerNotSynced
        }
        guard payment.invoice.quickBooksID.nilIfBlank != nil else {
            throw QuickBooksPaymentsServiceError.invoiceNotSyncedToQuickBooks
        }

        let payload = await quickBooksPaymentPayload(
            invoice: payment.invoice,
            customerQBID: customerQBID,
            amount: payment.amount,
            note: payment.notes,
            paymentRef: payment.authorizationReference.nilIfBlank ?? "Payment for invoice #\(payment.invoice.id.uuidString.prefix(8)) from \(payment.invoice.customer.name)",
            paymentKind: .manual(methodName: payment.method)
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
        guard let salesItemRef = await resolvedSalesItemRef() else {
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

    private func resolvedSalesItemRef() async -> String? {
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

        let payload = QuickBooksCustomerCreate(
            DisplayName: customer.name,
            PrimaryPhone: customer.phone.flatMap { Self.nilIfBlank($0).map { QuickBooksPhoneNumber(FreeFormNumber: $0) } },
            PrimaryEmailAddr: customer.email.flatMap { Self.nilIfBlank($0).map { QuickBooksEmailAddress(Address: $0) } },
            BillAddr: customer.address.flatMap { Self.nilIfBlank($0).map { QuickBooksAddress(Line1: $0) } }
        )

        let created = try await withCheckedThrowingContinuation { continuation in
            api.createCustomer(payload) { result in
                continuation.resume(with: result)
            }
        }
        customer.quickBooksID = created.Id
        return created.Id
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
            GlobalTaxCalculation: "TaxExcluded"
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

        await MainActor.run {
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
        clientTransactionID: String
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
        guard invoice.quickBooksID.nilIfBlank != nil else {
            return (nil, QuickBooksPaymentsServiceError.invoiceNotSyncedToQuickBooks.localizedDescription)
        }

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
        guard let invoiceQBID = invoice.quickBooksID.nilIfBlank else {
            preconditionFailure("Invoice QuickBooks ID is required before building a QuickBooks Payment payload.")
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
            CustomerRef: QuickBooksReference(value: customerQBID, name: invoice.customer.name),
            TotalAmt: amount,
            PrivateNote: privateNote,
            PaymentRefNum: Self.quickBooksPaymentRefNum(paymentRef),
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
    case invoiceNotSyncedToQuickBooks
    case quickBooksSessionExpired
    case invalidPaymentInput
    case invalidBankAccountInput
    case authoritativeTaxRequired(String)
    case unconfirmedProcessorResponse(String)

    var errorDescription: String? {
        switch self {
        case .customerNotSynced:
            return "This customer needs a QuickBooks customer ID before QuickBooks Payments can be processed."
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
                "The charge currency was \(currency.uppercased()) instead of USD."
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
            let detail = normalized(response.status)?.uppercased() ?? "MISSING"
            throw QuickBooksPaymentsServiceError.unconfirmedProcessorResponse(
                "The processor reported refund status \(detail)."
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
