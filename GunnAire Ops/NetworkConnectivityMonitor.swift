import Foundation
import Network

extension Notification.Name {
    /// Posted only on an offline→online transition, never on every path
    /// update, so listeners can safely treat it as "try syncing now" without
    /// needing their own debounce.
    static let gunnaireConnectivityRestored = Notification.Name("GunnAireConnectivityRestored")
}

/// Thin wrapper around `NWPathMonitor` that exists solely to detect the
/// offline→online transition and post a notification, so existing sync paths
/// (e.g. the manual "Sync Saved Document" button) can be triggered
/// automatically instead of requiring a tap. Owns no sync logic itself.
@MainActor
final class NetworkConnectivityMonitor {
    static let shared = NetworkConnectivityMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.gunnaire.businesssuite.connectivity-monitor")
    private let notificationCenter: NotificationCenter
    private var wasSatisfied = true

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        monitor.pathUpdateHandler = { [weak self] path in
            self?.receivePathStatus(isSatisfied: path.status == .satisfied)
        }
    }

    /// Path callbacks arrive on the monitor queue. FIFO main-queue delivery
    /// preserves their order and lets SwiftUI subscribers update recovery UI.
    nonisolated func receivePathStatus(isSatisfied: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let previouslySatisfied = self.wasSatisfied
            self.wasSatisfied = isSatisfied
            guard isSatisfied, !previouslySatisfied else { return }
            self.notificationCenter.post(name: .gunnaireConnectivityRestored, object: nil)
        }
    }

    func start() {
        monitor.start(queue: queue)
    }
}
