import Foundation
import Combine

// MARK: - QuickBooks Sandbox API
protocol QBStubAPIProtocol: AnyObject {
    var isLoadingInvoices: Bool { get }
    var invoiceError: Error? { get }
    var invoices: [QBStubInvoice] { get }
    func fetchInvoices()
    func createInvoice(_ invoice: QBStubInvoiceCreate, completion: @escaping (Result<Void, Error>) -> Void)
}

struct QBStubReference {
    var value: String?
    var name: String?
}

struct QBStubLineItem: Identifiable {
    var id: UUID = UUID()
    var amount: Double
    var description: String?
}

struct QBStubInvoice: Identifiable {
    var id: UUID = UUID()
    var Id: String { id.uuidString }
    var DocNumber: String?
    var CustomerRef: QBStubReference?
    var TotalAmt: Double?
    var TxnDate: String?
}

struct QBStubBill: Identifiable {
    var id: UUID = UUID()
    var vendorName: String
    var totalAmt: Double
    var dueDate: String
    var status: String
}

struct QBStubVendor: Identifiable {
    var id: UUID = UUID()
    var displayName: String
    var email: String?
    var phone: String?
}

struct QBStubPayment: Identifiable {
    var id: UUID = UUID()
    var customerName: String
    var amount: Double
    var method: String
    var paidDate: String
}

struct QBStubInvoiceCreate {
    var CustomerRef: QBStubReference
    var Line: [QBStubLineItem]
    var TotalAmt: Double
    var PrivateNote: String?
}

struct QBStubBillCreate {
    var vendorName: String
    var totalAmt: Double
    var notes: String?
}

struct QBStubVendorCreate {
    var displayName: String
    var email: String?
    var phone: String?
}

struct QBStubPaymentCreate {
    var customerName: String
    var amount: Double
    var method: String
    var notes: String?
}

final class QBStubAPIClient: ObservableObject, QBStubAPIProtocol {
    static let shared = QBStubAPIClient()

    @Published private(set) var isLoadingInvoices: Bool = false
    @Published private(set) var invoiceError: Error? = nil
    @Published private(set) var invoices: [QBStubInvoice] = []

    @Published private(set) var bills: [QBStubBill] = []
    @Published private(set) var vendors: [QBStubVendor] = []
    @Published private(set) var payments: [QBStubPayment] = []

    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter
    }()

    init() {
        seedIfNeeded()
    }

    func fetchInvoices() {
        isLoadingInvoices = true
        invoiceError = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.isLoadingInvoices = false
            self.seedIfNeeded()
        }
    }

    func createInvoice(_ invoice: QBStubInvoiceCreate, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            let number = "INV-\(1000 + self.invoices.count + 1)"
            let record = QBStubInvoice(
                DocNumber: number,
                CustomerRef: invoice.CustomerRef,
                TotalAmt: invoice.TotalAmt,
                TxnDate: self.formatter.string(from: Date())
            )
            self.invoices.insert(record, at: 0)
            completion(.success(()))
        }
    }

    func fetchBills() {
        seedIfNeeded()
    }

    func createBill(_ bill: QBStubBillCreate, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            let dueDate = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
            let record = QBStubBill(
                vendorName: bill.vendorName,
                totalAmt: bill.totalAmt,
                dueDate: self.formatter.string(from: dueDate),
                status: "open"
            )
            self.bills.insert(record, at: 0)
            completion(.success(()))
        }
    }

    func fetchVendors() {
        seedIfNeeded()
    }

    func createVendor(_ vendor: QBStubVendorCreate, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            let record = QBStubVendor(
                displayName: vendor.displayName,
                email: vendor.email,
                phone: vendor.phone
            )
            self.vendors.insert(record, at: 0)
            completion(.success(()))
        }
    }

    func fetchPayments() {
        seedIfNeeded()
    }

    func createPayment(_ payment: QBStubPaymentCreate, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            let record = QBStubPayment(
                customerName: payment.customerName,
                amount: payment.amount,
                method: payment.method,
                paidDate: self.formatter.string(from: Date())
            )
            self.payments.insert(record, at: 0)
            completion(.success(()))
        }
    }

    func simulateFullSync(completion: @escaping (_ summary: String) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            completion("Synced \(self.invoices.count) invoices, \(self.bills.count) bills, \(self.vendors.count) vendors, \(self.payments.count) payments.")
        }
    }

    private func seedIfNeeded() {
        if invoices.isEmpty {
            invoices = [
                QBStubInvoice(DocNumber: "INV-1001", CustomerRef: QBStubReference(value: "CUST-1", name: "Maple Residence"), TotalAmt: 1249.00, TxnDate: formatter.string(from: Date())),
                QBStubInvoice(DocNumber: "INV-1002", CustomerRef: QBStubReference(value: "CUST-2", name: "Acme Office"), TotalAmt: 699.50, TxnDate: formatter.string(from: Date()))
            ]
        }
        if bills.isEmpty {
            bills = [
                QBStubBill(vendorName: "Parts Warehouse", totalAmt: 285.40, dueDate: formatter.string(from: Date().addingTimeInterval(60 * 60 * 24 * 20)), status: "open")
            ]
        }
        if vendors.isEmpty {
            vendors = [
                QBStubVendor(displayName: "HVAC Supply Co", email: "orders@hvacsupply.test", phone: "555-222-1000")
            ]
        }
        if payments.isEmpty {
            payments = [
                QBStubPayment(customerName: "Maple Residence", amount: 350.00, method: "Credit Card", paidDate: formatter.string(from: Date()))
            ]
        }
    }
}
