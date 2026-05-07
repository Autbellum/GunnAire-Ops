import Foundation
import Combine

enum OnsitePaymentProcessor: String, CaseIterable, Identifiable {
    case none = "none"
    case simulated = "simulated"
    case quickBooksPayments = "quickbooks_payments"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none:
            return "Not Connected"
        case .simulated:
            return "Tap to Pay Simulator"
        case .quickBooksPayments:
            return "QuickBooks Payments"
        }
    }

    var supportsTapToPay: Bool {
        self != .none
    }

    var usesSimulator: Bool {
        self == .simulated
    }

    var requiresQuickBooksSession: Bool {
        self == .quickBooksPayments
    }
}

struct OnsitePaymentCaptureResult {
    let amount: Double
    let cardLast4: String
    let authorizationCode: String
    let processorReference: String
    let processorName: String
    let paymentSummary: String
}

enum OnsitePaymentError: LocalizedError {
    case processorUnavailable
    case invalidAmount
    case quickBooksAuthenticationRequired
    case quickBooksSDKNotIntegrated

    var errorDescription: String? {
        switch self {
        case .processorUnavailable:
            return "No Tap to Pay processor is configured on this device."
        case .invalidAmount:
            return "Enter a valid payment amount before starting Tap to Pay."
        case .quickBooksAuthenticationRequired:
            return "QuickBooks Payments requires an active QuickBooks connection before Tap to Pay can start."
        case .quickBooksSDKNotIntegrated:
            return "QuickBooks Payments is selected, but the live Intuit Tap to Pay SDK bridge is not integrated in this build yet."
        }
    }
}

@MainActor
final class OnsitePaymentManager: ObservableObject {
    static let shared = OnsitePaymentManager()

    @Published private(set) var isProcessing = false

    private init() {}

    func configuredProcessor() -> OnsitePaymentProcessor {
        let storedValue = UserDefaults.standard.string(forKey: "onsitePaymentProcessor") ?? OnsitePaymentProcessor.none.rawValue
        return OnsitePaymentProcessor(rawValue: storedValue) ?? .none
    }

    func processorReady() -> Bool {
        let processor = configuredProcessor()
        if processor.usesSimulator {
            return true
        }
        guard UserDefaults.standard.bool(forKey: "onsitePaymentProcessorReady") else {
            return false
        }
        if processor.requiresQuickBooksSession {
            return QuickBooksDataAPI.shared.tokens != nil && QuickBooksDataAPI.shared.realmID != nil
        }
        return true
    }

    func processorStatusDetail() -> String {
        let processor = configuredProcessor()
        switch processor {
        case .none:
            return "No on-device payment processor is selected."
        case .simulated:
            return "Simulator mode is enabled for Tap to Pay workflow testing."
        case .quickBooksPayments:
            if QuickBooksDataAPI.shared.tokens == nil || QuickBooksDataAPI.shared.realmID == nil {
                return "Connect QuickBooks first, then mark this device ready for the Intuit Tap to Pay bridge."
            }
            if !UserDefaults.standard.bool(forKey: "onsitePaymentProcessorReady") {
                return "QuickBooks Payments is connected. Mark this device ready after the Intuit Tap to Pay bridge is installed."
            }
            return "QuickBooks Payments is selected. This build still needs the Intuit Tap to Pay SDK bridge before live card-present capture can run."
        }
    }

    func startTapToPay(amount: Double, customerName: String) async throws -> OnsitePaymentCaptureResult {
        guard amount > 0 else { throw OnsitePaymentError.invalidAmount }
        let processor = configuredProcessor()
        guard processor.supportsTapToPay, processorReady() else {
            throw OnsitePaymentError.processorUnavailable
        }

        isProcessing = true
        defer { isProcessing = false }

        if processor.requiresQuickBooksSession {
            guard QuickBooksDataAPI.shared.tokens != nil, QuickBooksDataAPI.shared.realmID != nil else {
                throw OnsitePaymentError.quickBooksAuthenticationRequired
            }
            throw OnsitePaymentError.quickBooksSDKNotIntegrated
        }

        // This app-side layer is ready for a real processor SDK. Until one is added,
        // the simulator provides a deterministic card-present workflow for field testing.
        try await Task.sleep(nanoseconds: 1_500_000_000)

        let auth = String(UUID().uuidString.prefix(8)).uppercased()
        let ref = String(UUID().uuidString.prefix(12)).uppercased()
        let last4 = String(Int.random(in: 1000...9999))

        return OnsitePaymentCaptureResult(
            amount: amount,
            cardLast4: last4,
            authorizationCode: auth,
            processorReference: ref,
            processorName: processor.displayName,
            paymentSummary: "Tap to Pay approved for \(customerName). Ref \(ref)."
        )
    }
}
