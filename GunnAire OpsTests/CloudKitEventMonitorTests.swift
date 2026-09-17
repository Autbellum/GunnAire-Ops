import Combine
import Foundation
import Testing
@testable import GunnAire_Ops

/// The mirroring event monitor is mounted at the app root for the whole
/// session. Every emission re-renders the observers, so routine events that do
/// not change the reduced state must stay silent, and persistence must only
/// happen when the durable snapshot (failures and successes) changes.
@MainActor
struct CloudKitEventMonitorTests {
    private func makeMonitor() throws -> (GunnAireCloudKitEventMonitor, UserDefaults, String) {
        let suite = "CloudKitEventMonitorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let monitor = GunnAireCloudKitEventMonitor(
            notificationCenter: NotificationCenter(),
            userDefaults: defaults,
            isEnabled: true,
            retainsCloudKitContainer: false
        )
        return (monitor, defaults, suite)
    }

    @Test func identicalEventsDoNotRepublishOrPersist() throws {
        let (monitor, defaults, suite) = try makeMonitor()
        defer { defaults.removePersistentDomain(forName: suite) }
        var stateEmissions = 0
        var attentionEmissions = 0
        let stateObservation = monitor.objectWillChange.sink { _ in stateEmissions += 1 }
        let attentionObservation = monitor.attention.objectWillChange.sink { _ in attentionEmissions += 1 }
        let start = Date(timeIntervalSince1970: 1_788_800_000)

        monitor.record(CloudKitMirroringEventSnapshot(operation: .exportRecords, outcome: .running, occurredAt: start))
        monitor.record(CloudKitMirroringEventSnapshot(operation: .exportRecords, outcome: .running, occurredAt: start.addingTimeInterval(1)))
        #expect(stateEmissions == 1)
        #expect(attentionEmissions == 0)
        #expect(monitor.state.runningOperations == [.exportRecords])
        // A running-only transition changes nothing that must survive relaunch.
        #expect(defaults.data(forKey: "GunnAireCloudKitMirroringStateV1") == nil)

        monitor.record(CloudKitMirroringEventSnapshot(operation: .exportRecords, outcome: .failed, occurredAt: start.addingTimeInterval(2)))
        #expect(stateEmissions == 2)
        #expect(attentionEmissions == 1)
        #expect(monitor.attention.operation == .exportRecords)
        let persisted = try #require(defaults.data(forKey: "GunnAireCloudKitMirroringStateV1"))
        #expect(try JSONDecoder().decode(CloudKitMirroringState.self, from: persisted).attentionFailure?.operation == .exportRecords)

        // The same failure reported again with the same timestamp is silent.
        monitor.record(CloudKitMirroringEventSnapshot(operation: .exportRecords, outcome: .failed, occurredAt: start.addingTimeInterval(2)))
        #expect(stateEmissions == 2)
        #expect(attentionEmissions == 1)

        // A later retry of the same failed export updates the detailed state
        // for Settings but does not change which operation needs attention.
        monitor.record(CloudKitMirroringEventSnapshot(operation: .exportRecords, outcome: .running, occurredAt: start.addingTimeInterval(3)))
        monitor.record(CloudKitMirroringEventSnapshot(operation: .exportRecords, outcome: .failed, occurredAt: start.addingTimeInterval(4)))
        #expect(stateEmissions == 4)
        #expect(attentionEmissions == 1)
        #expect(monitor.state.attentionFailure?.occurredAt == start.addingTimeInterval(4))

        // A successful export clears the warning for both observers.
        monitor.record(CloudKitMirroringEventSnapshot(operation: .exportRecords, outcome: .succeeded, occurredAt: start.addingTimeInterval(5)))
        #expect(stateEmissions == 5)
        #expect(attentionEmissions == 2)
        #expect(monitor.attention.operation == nil)
        #expect(!monitor.state.needsAttention)
        withExtendedLifetime((stateObservation, attentionObservation)) {}
    }

    @Test func restoredFailuresSeedTheAttentionOperationAtLaunch() throws {
        let (first, defaults, suite) = try makeMonitor()
        defer { defaults.removePersistentDomain(forName: suite) }
        first.record(CloudKitMirroringEventSnapshot(operation: .importRecords, outcome: .failed))

        let restored = GunnAireCloudKitEventMonitor(
            notificationCenter: NotificationCenter(),
            userDefaults: defaults,
            isEnabled: true,
            retainsCloudKitContainer: false
        )
        #expect(restored.attention.operation == .importRecords)
        #expect(restored.state.attentionFailure?.operation == .importRecords)
        #expect(restored.attention.eventMonitor === restored)
        #expect(
            OperationalDataContinuity.cloudKitNotice(for: .available, attentionOperation: restored.attention.operation)
                == OperationalDataContinuity.cloudKitNotice(for: .available, mirroringState: restored.state)
        )
    }
}
