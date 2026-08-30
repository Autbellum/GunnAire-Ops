import Foundation
import Combine

enum OnsitePaymentProcessor: String, CaseIterable, Identifiable {
    case none = "none"
    case quickBooksPayments = "quickbooks_payments"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none:
            return "Not Connected"
        case .quickBooksPayments:
            return "QuickBooks Payments"
        }
    }

    var supportsTapToPay: Bool {
        self == .quickBooksPayments
    }

    var requiresQuickBooksSession: Bool {
        self == .quickBooksPayments
    }
}

enum OnsitePaymentReadiness {
    static func processorIsReady(
        bridgeAvailable: Bool,
        processor: OnsitePaymentProcessor,
        deviceMarkedReady: Bool,
        quickBooksPaymentsAuthorized: Bool
    ) -> Bool {
        guard bridgeAvailable,
              processor.supportsTapToPay,
              deviceMarkedReady else { return false }
        return !processor.requiresQuickBooksSession || quickBooksPaymentsAuthorized
    }
}

struct OnsitePaymentCaptureResult: Sendable {
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
    case quickBooksPaymentsScopeRequired
    case quickBooksSDKNotIntegrated

    var errorDescription: String? {
        switch self {
        case .processorUnavailable:
            return "No Tap to Pay on iPhone processor is configured on this device."
        case .invalidAmount:
            return "Enter a valid payment amount before starting Tap to Pay on iPhone."
        case .quickBooksAuthenticationRequired:
            return "QuickBooks Payments requires an active QuickBooks connection before Tap to Pay on iPhone can start."
        case .quickBooksPaymentsScopeRequired:
            return "QuickBooks Payments scope is disabled. Enable the payments scope and reconnect QuickBooks before starting Tap to Pay on iPhone."
        case .quickBooksSDKNotIntegrated:
            return "Tap to Pay on iPhone is available in QuickBooks Mobile or GoPayment. This custom app does not embed that capture flow."
        }
    }
}

@MainActor
final class OnsitePaymentManager: ObservableObject {
    static let shared = OnsitePaymentManager()

    @Published private(set) var isProcessing = false
    private let quickBooksBridge: any QuickBooksTapToPayBridge

    private init() {
        self.quickBooksBridge = QuickBooksTapToPayBridgeRegistry.makeBridge()
    }

    var tapToPayAvailableInCurrentBuild: Bool {
        quickBooksBridge.isAvailableInCurrentBuild
    }

    func availableProcessors() -> [OnsitePaymentProcessor] {
        tapToPayAvailableInCurrentBuild ? [.none, .quickBooksPayments] : [.none]
    }

    func configuredProcessor() -> OnsitePaymentProcessor {
        let storedValue = UserDefaults.standard.string(forKey: "onsitePaymentProcessor") ?? OnsitePaymentProcessor.none.rawValue
        let processor = OnsitePaymentProcessor(rawValue: storedValue) ?? .none
        return availableProcessors().contains(processor) ? processor : .none
    }

    func processorReady() -> Bool {
        let processor = configuredProcessor()
        return OnsitePaymentReadiness.processorIsReady(
            bridgeAvailable: tapToPayAvailableInCurrentBuild,
            processor: processor,
            deviceMarkedReady: UserDefaults.standard.bool(forKey: "onsitePaymentProcessorReady"),
            quickBooksPaymentsAuthorized: QuickBooksDataAPI.shared.canUseQuickBooksPaymentsAPI
        )
    }

    func processorStatusDetail() -> String {
        let processor = configuredProcessor()
        switch processor {
        case .none:
            return tapToPayAvailableInCurrentBuild
                ? "No on-device payment processor is selected."
                : "Use QuickBooks Mobile or GoPayment on the field iPhone for Tap to Pay on iPhone."
        case .quickBooksPayments:
            guard tapToPayAvailableInCurrentBuild else {
                return "Use QuickBooks Mobile or GoPayment on the field iPhone for Tap to Pay on iPhone."
            }
            if !Config.QuickBooks.enablePaymentsScope {
                return "Enable the QuickBooks Payments scope and reconnect QuickBooks before using live Tap to Pay on iPhone capture."
            }
            if !QuickBooksDataAPI.shared.isAuthenticated {
                return "Connect QuickBooks first, then mark this device ready for Tap to Pay on iPhone."
            }
            if let diagnostic = QuickBooksDataAPI.shared.paymentsAuthorizationDiagnostic {
                return diagnostic
            }
            if !UserDefaults.standard.bool(forKey: "onsitePaymentProcessorReady") {
                return "QuickBooks Payments is connected. Use the QuickBooks field app for its supported Tap to Pay on iPhone checkout."
            }
            return "QuickBooks Payments is selected and ready for live Tap to Pay on iPhone capture."
        }
    }

    func startTapToPay(amount: Double, customerName: String) async throws -> OnsitePaymentCaptureResult {
        guard amount > 0 else { throw OnsitePaymentError.invalidAmount }
        guard tapToPayAvailableInCurrentBuild else {
            throw OnsitePaymentError.quickBooksSDKNotIntegrated
        }
        let processor = configuredProcessor()
        guard processor.supportsTapToPay, processorReady() else {
            throw OnsitePaymentError.processorUnavailable
        }

        isProcessing = true
        defer { isProcessing = false }

        if processor.requiresQuickBooksSession {
            guard Config.QuickBooks.enablePaymentsScope else {
                throw OnsitePaymentError.quickBooksPaymentsScopeRequired
            }
            guard QuickBooksDataAPI.shared.isAuthenticated else {
                throw OnsitePaymentError.quickBooksAuthenticationRequired
            }
            return try await quickBooksBridge.startCharge(
                QuickBooksTapToPayChargeRequest(
                    amount: amount,
                    customerName: customerName
                )
            )
        }
        throw OnsitePaymentError.processorUnavailable
    }
}
