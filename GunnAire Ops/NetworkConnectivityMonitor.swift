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
final class NetworkConnectivityMonitor {
    static let shared = NetworkConnectivityMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.gunnaire.businesssuite.connectivity-monitor")
    private var wasSatisfied = true

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let isSatisfied = path.status == .satisfied
            let previouslySatisfied = self.wasSatisfied
            self.wasSatisfied = isSatisfied
            guard isSatisfied, !previouslySatisfied else { return }
            NotificationCenter.default.post(name: .gunnaireConnectivityRestored, object: nil)
        }
    }

    func start() {
        monitor.start(queue: queue)
    }
}
