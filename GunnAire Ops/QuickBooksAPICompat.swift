// QuickBooksAPICompat.swift
// Provides a unified QuickBooksAPI facade that forwards to the split auth and data APIs.

import Foundation
import AuthenticationServices
import Combine

final class QuickBooksAPI: ObservableObject {
    static let shared = QuickBooksAPI()
    
    private let auth = QuickBooksAuthAPI.shared
    private let data = QuickBooksDataAPI.shared
    
    // MARK: - Auth Forwarding
    func startSignIn(presentationContext: ASWebAuthenticationPresentationContextProviding, completion: @escaping (Result<Void, Error>) -> Void) {
        auth.startSignIn(presentationContext: presentationContext, completion: completion)
    }
    
    // MARK: - Data Forwarding
    func fetchCustomers(completion: @escaping (Result<[QuickBooksCustomer], Error>) -> Void) {
        data.fetchCustomers(completion: completion)
    }

    func createCustomer(
        _ customer: QuickBooksCustomerCreate,
        requestID: String? = nil,
        completion: @escaping (Result<QuickBooksCustomer, Error>) -> Void
    ) {
        data.createCustomer(customer, requestID: requestID, completion: completion)
    }

    func recoverOrCreateCustomer(
        _ draft: QuickBooksCustomerCreateDraft,
        remoteCustomers: [QuickBooksCustomer]? = nil,
        completion: @escaping (Result<QuickBooksCustomer, Error>) -> Void
    ) {
        data.recoverOrCreateCustomer(
            draft,
            remoteCustomers: remoteCustomers,
            completion: completion
        )
    }

    func fetchItems(completion: @escaping (Result<[QuickBooksItem], Error>) -> Void) {
        data.fetchItems(completion: completion)
    }

    func fetchItem(id: String, completion: @escaping (Result<QuickBooksItem, Error>) -> Void) {
        data.fetchItem(id: id, completion: completion)
    }

    func createItem(
        _ item: QuickBooksItemCreate,
        requestID: String? = nil,
        completion: @escaping (Result<QuickBooksItem, Error>) -> Void
    ) {
        data.createItem(item, requestID: requestID, completion: completion)
    }

    func updateItem(_ item: QuickBooksItemUpdate, completion: @escaping (Result<QuickBooksItem, Error>) -> Void) {
        data.updateItem(item, completion: completion)
    }

    func fetchEstimates(completion: @escaping (Result<[QuickBooksEstimate], Error>) -> Void) {
        data.fetchEstimates(completion: completion)
    }

    func createEstimate(_ estimate: QuickBooksEstimateCreate, completion: @escaping (Result<QuickBooksEstimate, Error>) -> Void) {
        data.createEstimate(estimate, completion: completion)
    }

    func sendEstimate(id: String, to emailAddress: String? = nil, completion: @escaping (Result<QuickBooksEstimate, Error>) -> Void) {
        data.sendEstimate(id: id, to: emailAddress, completion: completion)
    }

    func fetchInvoices(completion: @escaping (Result<[QuickBooksInvoice], Error>) -> Void) {
        data.fetchInvoices(completion: completion)
    }
    
    func createInvoice(
        _ invoice: QuickBooksInvoiceCreate,
        requestID: String? = nil,
        completion: @escaping (Result<QuickBooksInvoice, Error>) -> Void
    ) {
        data.createInvoice(invoice, requestID: requestID, completion: completion)
    }

    func sendInvoice(id: String, to emailAddress: String? = nil, completion: @escaping (Result<QuickBooksInvoice, Error>) -> Void) {
        data.sendInvoice(id: id, to: emailAddress, completion: completion)
    }
    
    func fetchBills(completion: @escaping (Result<[QuickBooksBill], Error>) -> Void) {
        data.fetchBills(completion: completion)
    }
    
    func createBill(_ bill: QuickBooksBillCreate, requestID: String? = nil, completion: @escaping (Result<QuickBooksBill, Error>) -> Void) {
        data.createBill(bill, requestID: requestID, completion: completion)
    }

    func fetchVendorCredits(completion: @escaping (Result<[QuickBooksVendorCredit], Error>) -> Void) {
        data.fetchVendorCredits(completion: completion)
    }

    func createVendorCredit(_ vendorCredit: QuickBooksVendorCreditCreate, requestID: String? = nil, completion: @escaping (Result<QuickBooksVendorCredit, Error>) -> Void) {
        data.createVendorCredit(vendorCredit, requestID: requestID, completion: completion)
    }

    func fetchPurchases(completion: @escaping (Result<[QuickBooksPurchase], Error>) -> Void) {
        data.fetchPurchases(completion: completion)
    }

    func createPurchase(_ purchase: QuickBooksPurchaseCreate, completion: @escaping (Result<QuickBooksPurchase, Error>) -> Void) {
        data.createPurchase(purchase, completion: completion)
    }
    
    func fetchVendors(completion: @escaping (Result<[QuickBooksVendor], Error>) -> Void) {
        data.fetchVendors(completion: completion)
    }
    
    func createVendor(
        _ vendor: QuickBooksVendorCreate,
        requestID: String? = nil,
        completion: @escaping (Result<QuickBooksVendor, Error>) -> Void
    ) {
        data.createVendor(vendor, requestID: requestID, completion: completion)
    }

    func recoverOrCreateVendor(
        _ draft: QuickBooksVendorCreateDraft,
        remoteVendors: [QuickBooksVendor]? = nil,
        completion: @escaping (Result<QuickBooksVendor, Error>) -> Void
    ) {
        data.recoverOrCreateVendor(
            draft,
            remoteVendors: remoteVendors,
            completion: completion
        )
    }
    
    func fetchPayments(completion: @escaping (Result<[QuickBooksPayment], Error>) -> Void) {
        data.fetchPayments(completion: completion)
    }
    
    func createPayment(
        _ payment: QuickBooksPaymentCreate,
        requestID: String? = nil,
        completion: @escaping (Result<QuickBooksPayment, Error>) -> Void
    ) {
        data.createPayment(payment, requestID: requestID, completion: completion)
    }

    func recoverOrCreatePayment(
        _ draft: QuickBooksAccountingPaymentDraft,
        remotePayments: [QuickBooksPayment]? = nil,
        completion: @escaping (Result<QuickBooksPayment, Error>) -> Void
    ) {
        data.recoverOrCreatePayment(
            draft,
            remotePayments: remotePayments,
            completion: completion
        )
    }

    func fetchSalesReceipts(completion: @escaping (Result<[QuickBooksSalesReceipt], Error>) -> Void) {
        data.fetchSalesReceipts(completion: completion)
    }

    func createSalesReceipt(_ salesReceipt: QuickBooksSalesReceiptCreate, completion: @escaping (Result<QuickBooksSalesReceipt, Error>) -> Void) {
        data.createSalesReceipt(salesReceipt, completion: completion)
    }

    func fetchPaymentMethods(completion: @escaping (Result<[QuickBooksPaymentMethod], Error>) -> Void) {
        data.fetchPaymentMethods(completion: completion)
    }

    func createPaymentMethod(_ method: QuickBooksPaymentMethodCreate, completion: @escaping (Result<QuickBooksPaymentMethod, Error>) -> Void) {
        data.createPaymentMethod(method, completion: completion)
    }

    func fetchDeposits(completion: @escaping (Result<[QuickBooksDeposit], Error>) -> Void) {
        data.fetchDeposits(completion: completion)
    }

    func createDeposit(_ deposit: QuickBooksDepositCreate, completion: @escaping (Result<QuickBooksDeposit, Error>) -> Void) {
        data.createDeposit(deposit, completion: completion)
    }

    func createCardToken(_ tokenRequest: QuickBooksPaymentsTokenCreateRequest, completion: @escaping (Result<QuickBooksPaymentsTokenResponse, Error>) -> Void) {
        data.createCardToken(tokenRequest, completion: completion)
    }

    func fetchCards(completion: @escaping (Result<[QuickBooksPaymentsCardRecord], Error>) -> Void) {
        data.fetchCards(completion: completion)
    }

    func fetchCards(forCustomerID customerID: String, completion: @escaping (Result<[QuickBooksPaymentsCardRecord], Error>) -> Void) {
        data.fetchCards(forCustomerID: customerID, completion: completion)
    }

    func fetchCards(forCustomerIDs customerIDs: [String], completion: @escaping (Result<[QuickBooksPaymentsCardRecord], Error>) -> Void) {
        data.fetchCards(forCustomerIDs: customerIDs, completion: completion)
    }

    func createStoredCard(_ card: QuickBooksPaymentsStoredCardCreateRequest, completion: @escaping (Result<QuickBooksPaymentsCardRecord, Error>) -> Void) {
        data.createStoredCard(card, completion: completion)
    }

    func createStoredCard(_ card: QuickBooksPaymentsStoredCardCreateRequest, forCustomerID customerID: String, completion: @escaping (Result<QuickBooksPaymentsCardRecord, Error>) -> Void) {
        data.createStoredCard(card, forCustomerID: customerID, completion: completion)
    }

    func fetchPaymentReceipt(id: String, completion: @escaping (Result<QuickBooksPaymentsPaymentReceipt, Error>) -> Void) {
        data.fetchPaymentReceipt(id: id, completion: completion)
    }

    func createCharge(_ charge: QuickBooksPaymentsChargeCreate, completion: @escaping (Result<QuickBooksPaymentsChargeResponse, Error>) -> Void) {
        data.createCharge(charge, completion: completion)
    }

    func captureCharge(id: String, amount: Double, completion: @escaping (Result<QuickBooksPaymentsChargeResponse, Error>) -> Void) {
        data.captureCharge(id: id, amount: amount, completion: completion)
    }

    func refundCharge(
        id: String,
        amount: Double,
        description: String?,
        clientTransactionID: String? = nil,
        completion: @escaping (Result<QuickBooksPaymentsRefundResponse, Error>) -> Void
    ) {
        data.refundCharge(
            id: id,
            amount: amount,
            description: description,
            clientTransactionID: clientTransactionID,
            completion: completion
        )
    }

    func createRefundReceipt(_ receipt: QuickBooksRefundReceiptCreate, completion: @escaping (Result<QuickBooksRefundReceipt, Error>) -> Void) {
        data.createRefundReceipt(receipt, completion: completion)
    }
}
