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
}
