import Foundation

struct QuickBooksTapToPayChargeRequest: Sendable {
    let amount: Double
    let customerName: String
}

protocol QuickBooksTapToPayBridge: Sendable {
    var isAvailableInCurrentBuild: Bool { get }
    func startCharge(_ request: QuickBooksTapToPayChargeRequest) async throws -> OnsitePaymentCaptureResult
}

struct UnavailableQuickBooksTapToPayBridge: QuickBooksTapToPayBridge {
    let isAvailableInCurrentBuild = false

    func startCharge(_ request: QuickBooksTapToPayChargeRequest) async throws -> OnsitePaymentCaptureResult {
        throw OnsitePaymentError.quickBooksSDKNotIntegrated
    }
}
