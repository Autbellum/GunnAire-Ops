import Foundation
import XCTest
@testable import GunnAire_Ops

nonisolated private final class ConnectivityDeliveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []

    func record() {
        lock.lock()
        values.append(Thread.isMainThread)
        lock.unlock()
    }

    var deliveries: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

@MainActor
final class NetworkConnectivityMonitorTests: XCTestCase {
    private func deliverFromBackground(_ statuses: [Bool]) async -> [Bool] {
        let center = NotificationCenter()
        let recorder = ConnectivityDeliveryRecorder()
        let observer = center.addObserver(forName: .gunnaireConnectivityRestored,
                                          object: nil, queue: nil) { _ in
            recorder.record()
        }
        defer { center.removeObserver(observer) }
        let monitor = NetworkConnectivityMonitor(notificationCenter: center)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                for status in statuses { monitor.receivePathStatus(isSatisfied: status) }
                // The main queue drains every preceding status before this
                // completion; assertions need no timer or live network event.
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        return withExtendedLifetime(monitor) { recorder.deliveries }
    }

    func testRestorationFromBackgroundIsDeliveredOnMainThread() async {
        let deliveries = await deliverFromBackground([false, true])
        XCTAssertEqual(deliveries, [true])
    }

    func testRepeatedOnlineUpdatesCoalesceWithoutLosingLaterRestoration() async {
        let deliveries = await deliverFromBackground([true, true, false, false, true, true, false, true, true])
        XCTAssertEqual(deliveries, [true, true])
    }

    func testInitialOnlineAndOfflineUpdatesDoNotWakeRecovery() async {
        let deliveries = await deliverFromBackground([true, true, false, false])
        XCTAssertTrue(deliveries.isEmpty)
    }
}
