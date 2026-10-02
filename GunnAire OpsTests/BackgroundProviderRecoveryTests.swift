import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor
@Suite(.serialized)
struct BackgroundProviderRecoveryTests {
    @Test func appDeclaresTheRegisteredRefreshIdentifierAndFetchMode() {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        let identifiers = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        #expect(modes.contains("fetch"))
        #expect(identifiers.contains(BackgroundProviderRecovery.identifier))
    }

    @Test func rotatingCalendarPageFindsPendingJobsPastOldManagedRows() throws {
        let schema = GunnAireModelSchema.schema
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let context = ModelContext(container)
        let customer = Customer(name: "Background calendar fixture")
        context.insert(customer)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var pendingIDs: [UUID] = []
        for index in 0..<18 {
            let pending = index >= 9
            let call = ServiceCall(googleCalendarID: "primary",
                googleEventID: pending ? nil : "old-managed-\(index)",
                googleEventConfirmedAt: pending ? nil : now,
                googleEventManagedByApp: true, eventTitle: "Fixture \(index)", type: .repair,
                scheduledDate: now.addingTimeInterval(TimeInterval((index + 1) * 3600)),
                duration: 3600, customer: customer)
            if pending {
                call.googleCalendarPendingAt = now
                pendingIDs.append(call.id)
            }
            context.insert(call)
        }
        try context.save()

        let first = try GoogleCalendarScheduleSync.backgroundCandidatePage(
            context: context, offset: 0, pageSize: 8, now: now)
        #expect(first.calls.map(\.id) == Array(pendingIDs.prefix(8)))
        #expect(first.nextOffset == 8)

        let second = try GoogleCalendarScheduleSync.backgroundCandidatePage(
            context: context, offset: first.nextOffset, pageSize: 8, now: now)
        #expect(second.calls.map(\.id) == [pendingIDs[8]])
        #expect(second.nextOffset == 0)
    }

    @Test func verifiedRefreshRunsBothBoundedProvidersInOrder() async {
        var events: [String] = []
        let completed = await BackgroundProviderRecovery.runVerifiedProviders(
            stillAuthorized: { events.append("check"); return true },
            calendar: { events.append("calendar"); return true },
            drive: { events.append("drive"); return true }
        )
        #expect(completed)
        #expect(events == ["check", "calendar", "check", "drive", "check"])
    }

    @Test func changedWorkspaceAfterCalendarPreventsDriveWrite() async {
        var authorized = true
        var driveWrites = 0
        let completed = await BackgroundProviderRecovery.runVerifiedProviders(
            stillAuthorized: { authorized },
            calendar: { authorized = false; return true },
            drive: { driveWrites += 1; return true }
        )
        #expect(!completed)
        #expect(driveWrites == 0)
    }

    @Test func expirationDuringCalendarPreventsDriveWrite() async {
        var driveWrites = 0
        let (started, signal) = AsyncStream<Void>.makeStream()
        let worker = Task { @MainActor in
            await BackgroundProviderRecovery.runVerifiedProviders(
                stillAuthorized: { !Task.isCancelled },
                calendar: {
                    signal.yield()
                    do { try await Task.sleep(for: .seconds(30)) }
                    catch { return false }
                    return true
                },
                drive: { driveWrites += 1; return true }
            )
        }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        worker.cancel()
        #expect(await worker.value == false)
        #expect(driveWrites == 0)
    }
}
