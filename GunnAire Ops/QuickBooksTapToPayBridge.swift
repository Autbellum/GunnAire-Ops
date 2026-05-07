import Foundation

struct QuickBooksTapToPayChargeRequest: Sendable {
    let amount: Double
    let customerName: String
}

protocol QuickBooksTapToPayBridge: Sendable {
    nonisolated var isAvailableInCurrentBuild: Bool { get }
    nonisolated func startCharge(_ request: QuickBooksTapToPayChargeRequest) async throws -> OnsitePaymentCaptureResult
}

enum QuickBooksTapToPayBridgeRegistry {
    private static let queue = DispatchQueue(label: "GunnAireOps.QuickBooksTapToPayBridgeRegistry")
    private static var factory: @Sendable () -> any QuickBooksTapToPayBridge = {
        UnavailableQuickBooksTapToPayBridge()
    }

    static func register(_ factory: @escaping @Sendable () -> any QuickBooksTapToPayBridge) {
        queue.sync {
            self.factory = factory
        }
    }

    static func makeBridge() -> any QuickBooksTapToPayBridge {
        queue.sync {
            factory()
        }
    }
}

struct UnavailableQuickBooksTapToPayBridge: QuickBooksTapToPayBridge {
    nonisolated let isAvailableInCurrentBuild = false
    
    nonisolated init() {}

    nonisolated func startCharge(_ request: QuickBooksTapToPayChargeRequest) async throws -> OnsitePaymentCaptureResult {
        throw OnsitePaymentError.quickBooksSDKNotIntegrated
    }
}
