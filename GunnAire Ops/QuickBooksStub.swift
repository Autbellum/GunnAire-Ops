import Foundation
import Combine

// MARK: - QuickBooks API Abstraction (temporary shim to resolve ambiguity and compile errors)
protocol QBStubAPIProtocol: AnyObject {
    var isLoadingInvoices: Bool { get }
    var invoiceError: Error? { get }
    var invoices: [QBStubInvoice] { get }
    func fetchInvoices()
    func createInvoice(_ invoice: QBStubInvoiceCreate, completion: @escaping (Result<Void, Error>) -> Void)
}

// Lightweight stub models (no Codable conformance to avoid conflicts)
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

struct QBStubInvoiceCreate {
    var CustomerRef: QBStubReference
    var Line: [QBStubLineItem]
    var TotalAmt: Double
    var PrivateNote: String?
}

final class QBStubAPIClient: ObservableObject, QBStubAPIProtocol {
    @Published private(set) var isLoadingInvoices: Bool = false
    @Published private(set) var invoiceError: Error? = nil
    @Published private(set) var invoices: [QBStubInvoice] = []

    func fetchInvoices() {
        isLoadingInvoices = true
        invoiceError = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.isLoadingInvoices = false
            self.invoices = []
        }
    }

    func createInvoice(_ invoice: QBStubInvoiceCreate, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            completion(.success(()))
        }
    }
}
