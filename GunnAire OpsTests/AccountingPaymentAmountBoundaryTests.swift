import Foundation
import XCTest
@testable import GunnAire_Ops

@MainActor final class AccountingPaymentAmountBoundaryTests: XCTestCase {
    func draft(_ amount: Double) -> QuickBooksAccountingPaymentDraft {
        .init(localPaymentID: UUID(), payment: .init(CustomerRef: .init(value: "synthetic-customer", name: nil), TotalAmt: amount,
            PrivateNote: nil, PaymentRefNum: nil,
            Line: [.init(Amount: amount, LinkedTxn: [.init(TxnId: "synthetic-invoice", TxnType: "Invoice")])],
            PaymentMethodRef: nil, CreditCardPayment: nil))
    }
    func testInvalidLocalAmountsFailWithoutIntegerConversionTrapOrRounding() throws {
        for amount in [Double.greatestFiniteMagnitude, Double(Int64.max) / 100, 100_000_000_000,
                       -1e30, -1, 0, .infinity, .nan, 1.004, 1.005, 0.001] {
            XCTAssertThrowsError(try QuickBooksAccountingPaymentCreateOperation.payload(for: draft(amount))) {
                XCTAssertEqual($0 as? QuickBooksAccountingPaymentCreateOperationError, .invalidAmount)
            }
        }
    }
    func testExactCentAmountsRemainUnchangedAtSupportedBoundaries() throws {
        for amount in [0.01, 1.01, 34.68, 125, 99_999_999_999] {
            let payload = try QuickBooksAccountingPaymentCreateOperation.payload(for: draft(amount))
            XCTAssertEqual(payload.TotalAmt, amount)
            XCTAssertEqual(payload.Line?.first?.Amount, amount)
        }
    }
    func testMalformedRemoteAmountCannotMatchOriginalPaymentIdentity() throws {
        let original = draft(1), marker = QuickBooksAccountingPaymentCreateOperation.marker(for: original.localPaymentID)
        for amount in [1e30, -1e30, 1.004] {
            let json: [String: Any] = ["Id": "synthetic-payment", "CustomerRef": ["value": "synthetic-customer"],
                "TotalAmt": amount, "PrivateNote": marker,
                "Line": [["Amount": amount, "LinkedTxn": [["TxnId": "synthetic-invoice", "TxnType": "Invoice"]]]]]
            let remote = try JSONDecoder().decode(QuickBooksPayment.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertThrowsError(try QuickBooksAccountingPaymentCreateOperation.matchingRemotePayment(for: original, in: [remote])) {
                XCTAssertEqual($0 as? QuickBooksAccountingPaymentCreateOperationError, .conflictingRemotePayment)
            }
        }
    }
}
