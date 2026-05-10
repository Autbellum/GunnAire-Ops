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

    func createCustomer(_ customer: QuickBooksCustomerCreate, completion: @escaping (Result<QuickBooksCustomer, Error>) -> Void) {
        data.createCustomer(customer, completion: completion)
    }

    func fetchItems(completion: @escaping (Result<[QuickBooksItem], Error>) -> Void) {
        data.fetchItems(completion: completion)
    }

    func createItem(_ item: QuickBooksItemCreate, completion: @escaping (Result<QuickBooksItem, Error>) -> Void) {
        data.createItem(item, completion: completion)
    }

    func fetchEstimates(completion: @escaping (Result<[QuickBooksEstimate], Error>) -> Void) {
        data.fetchEstimates(completion: completion)
    }

    func createEstimate(_ estimate: QuickBooksEstimateCreate, completion: @escaping (Result<QuickBooksEstimate, Error>) -> Void) {
        data.createEstimate(estimate, completion: completion)
    }

    func fetchInvoices(completion: @escaping (Result<[QuickBooksInvoice], Error>) -> Void) {
        data.fetchInvoices(completion: completion)
    }
    
    func createInvoice(_ invoice: QuickBooksInvoiceCreate, completion: @escaping (Result<QuickBooksInvoice, Error>) -> Void) {
        data.createInvoice(invoice, completion: completion)
    }
    
    func fetchBills(completion: @escaping (Result<[QuickBooksBill], Error>) -> Void) {
        data.fetchBills(completion: completion)
    }
    
    func createBill(_ bill: QuickBooksBillCreate, completion: @escaping (Result<QuickBooksBill, Error>) -> Void) {
        data.createBill(bill, completion: completion)
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
    
    func createVendor(_ vendor: QuickBooksVendorCreate, completion: @escaping (Result<QuickBooksVendor, Error>) -> Void) {
        data.createVendor(vendor, completion: completion)
    }
    
    func fetchPayments(completion: @escaping (Result<[QuickBooksPayment], Error>) -> Void) {
        data.fetchPayments(completion: completion)
    }
    
    func createPayment(_ payment: QuickBooksPaymentCreate, completion: @escaping (Result<QuickBooksPayment, Error>) -> Void) {
        data.createPayment(payment, completion: completion)
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
