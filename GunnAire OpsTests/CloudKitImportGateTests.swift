import Combine
import Foundation
import Testing
@testable import GunnAire_Ops

/// Command Center stays unmounted while CloudKit is importing records, so the
/// flag that drives that must follow import start and end exactly, publish only
/// on the transition, and ignore the other operations.
@MainActor
struct CloudKitImportGateTests {
    private func makeMonitor() throws -> (GunnAireCloudKitEventMonitor, UserDefaults, String) {
        let suite = "CloudKitImportGateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let monitor = GunnAireCloudKitEventMonitor(
            notificationCenter: NotificationCenter(),
            userDefaults: defaults,
            isEnabled: true
        )
        return (monitor, defaults, suite)
    }

    @Test func importingIsTrueFromStartUntilFinishAndPublishesOncePerTransition() throws {
        let (monitor, defaults, suite) = try makeMonitor()
        defer { defaults.removePersistentDomain(forName: suite) }
        let start = Date(timeIntervalSince1970: 1_789_757_748)
        var emissions = 0
        let observation = monitor.attention.objectWillChange.sink { _ in emissions += 1 }
        defer { observation.cancel() }

        #expect(monitor.attention.isImportingRecords == false)

        monitor.record(CloudKitMirroringEventSnapshot(operation: .importRecords, outcome: .running, occurredAt: start))
        #expect(monitor.attention.isImportingRecords == true)
        #expect(emissions == 1)

        // Progress events while the same import keeps running must stay silent:
        // a long catch-up import emits many of them.
        monitor.record(CloudKitMirroringEventSnapshot(operation: .importRecords, outcome: .running, occurredAt: start.addingTimeInterval(1)))
        monitor.record(CloudKitMirroringEventSnapshot(operation: .importRecords, outcome: .running, occurredAt: start.addingTimeInterval(2)))
        #expect(monitor.attention.isImportingRecords == true)
        #expect(emissions == 1)

        monitor.record(CloudKitMirroringEventSnapshot(operation: .importRecords, outcome: .succeeded, occurredAt: start.addingTimeInterval(3)))
        #expect(monitor.attention.isImportingRecords == false)
        #expect(emissions == 2)
    }

    /// A failed import is over as far as the dashboard is concerned; the failure
    /// itself is surfaced through `operation`, not by keeping the gate closed.
    @Test func aFailedImportReleasesTheGate() throws {
        let (monitor, defaults, suite) = try makeMonitor()
        defer { defaults.removePersistentDomain(forName: suite) }
        let start = Date(timeIntervalSince1970: 1_789_757_748)

        monitor.record(CloudKitMirroringEventSnapshot(operation: .importRecords, outcome: .running, occurredAt: start))
        #expect(monitor.attention.isImportingRecords == true)
        monitor.record(CloudKitMirroringEventSnapshot(operation: .importRecords, outcome: .failed, occurredAt: start.addingTimeInterval(1)))
        #expect(monitor.attention.isImportingRecords == false)
        #expect(monitor.attention.operation == .importRecords)
    }

    /// Exports and setup run constantly in normal use and must never close the
    /// Command Center gate.
    @Test func exportsAndSetupDoNotCloseTheGate() throws {
        let (monitor, defaults, suite) = try makeMonitor()
        defer { defaults.removePersistentDomain(forName: suite) }
        let start = Date(timeIntervalSince1970: 1_789_757_748)

        monitor.record(CloudKitMirroringEventSnapshot(operation: .exportRecords, outcome: .running, occurredAt: start))
        monitor.record(CloudKitMirroringEventSnapshot(operation: .setup, outcome: .running, occurredAt: start.addingTimeInterval(1)))
        #expect(monitor.attention.isImportingRecords == false)
    }
}
