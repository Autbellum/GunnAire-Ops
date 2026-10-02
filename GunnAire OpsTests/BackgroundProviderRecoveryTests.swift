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

    @Test func rotatingEstimatePageReadsOnlyOneBoundedBatchOffMain() async throws {
        let schema = GunnAireModelSchema.schema
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let context = ModelContext(container)
        let customer = Customer(name: "Background billing fixture")
        context.insert(customer)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        for index in 0..<18 {
            context.insert(Estimate(customer: customer,
                createdAt: start.addingTimeInterval(TimeInterval(index))))
        }
        try context.save()
        let first = try await BackgroundProviderRecovery.estimatePage(container: container, offset: 0)
        #expect(first.candidates.count == 16)
        #expect(first.nextOffset == 16)
        let second = try await BackgroundProviderRecovery.estimatePage(container: container, offset: first.nextOffset)
        #expect(second.candidates.count == 2)
        #expect(second.nextOffset == 0)
        #expect(Set(first.candidates.map(\.id)).isDisjoint(with: second.candidates.map(\.id)))
    }

    @Test func unlinkedEstimateLaneSkipsLinkedHistoryButLegacyLaneKeepsWhitespace() async throws {
        let schema = GunnAireModelSchema.schema
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let context = ModelContext(container)
        let customer = Customer(name: "Estimate lane fixture")
        context.insert(customer)
        let start = Date(timeIntervalSince1970: 1_790_100_000)
        for index in 0..<24 {
            context.insert(Estimate(customer: customer, quickBooksID: "QBO-\(index)",
                createdAt: start.addingTimeInterval(TimeInterval(index))))
        }
        let nilID = Estimate(customer: customer, createdAt: start.addingTimeInterval(24))
        let emptyID = Estimate(customer: customer, quickBooksID: "", createdAt: start.addingTimeInterval(25))
        let whitespaceID = Estimate(customer: customer, quickBooksID: " \t ",
            createdAt: start.addingTimeInterval(26))
        context.insert(nilID); context.insert(emptyID); context.insert(whitespaceID)
        try context.save()
        let fast = try await BackgroundProviderRecovery.estimatePage(container: container, offset: 0,
            likelyUnlinkedOnly: true)
        #expect(Set(fast.candidates.map(\.id)) == Set([nilID.id, emptyID.id]))
        #expect(fast.nextOffset == 0)
        let legacyFirst = try await BackgroundProviderRecovery.estimatePage(container: container, offset: 16)
        #expect(legacyFirst.candidates.map(\.id).contains(whitespaceID.id))
        #expect(legacyFirst.nextOffset == 0)
    }

    @Test func verifiedRefreshRunsBothBoundedProvidersInOrder() async {
        var events: [String] = []
        let completed = await BackgroundProviderRecovery.runVerifiedProviders(
            stillAuthorized: { events.append("check"); return true },
            calendar: { events.append("calendar"); return true },
            drive: { events.append("drive"); return true },
            quickBooks: { events.append("quickbooks"); return true }
        )
        #expect(completed)
        #expect(events == ["check", "calendar", "check", "drive", "check", "quickbooks", "check"])
    }

    @Test func changedWorkspaceAfterCalendarPreventsDriveWrite() async {
        var authorized = true
        var driveWrites = 0
        let completed = await BackgroundProviderRecovery.runVerifiedProviders(
            stillAuthorized: { authorized },
            calendar: { authorized = false; return true },
            drive: { driveWrites += 1; return true },
            quickBooks: { Issue.record("QBO must not run after workspace change"); return false }
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
                drive: { driveWrites += 1; return true },
                quickBooks: { Issue.record("QBO must not run after expiration"); return false }
            )
        }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        worker.cancel()
        #expect(await worker.value == false)
        #expect(driveWrites == 0)
    }

    @Test func expiredLeaseAfterDrivePreventsEstimateEnqueue() async {
        var authorized = true
        var queueCalls = 0
        let completed = await BackgroundProviderRecovery.runVerifiedProviders(
            stillAuthorized: { authorized },
            calendar: { true },
            drive: { authorized = false; return true },
            quickBooks: { queueCalls += 1; return true }
        )
        #expect(!completed)
        #expect(queueCalls == 0)
    }

    @Test func driveFailureDoesNotStarveAnAuthorizedEstimateQueue() async {
        var queueCalls = 0
        let completed = await BackgroundProviderRecovery.runVerifiedProviders(
            stillAuthorized: { true },
            calendar: { true },
            drive: { false },
            quickBooks: { queueCalls += 1; return true }
        )
        #expect(!completed)
        #expect(queueCalls == 1)
    }

    @Test func rotatingOrderGivesQBOTheFirstChanceBeforeSlowCalendarAndDrive() async {
        let calendarFirst = BackgroundProviderRecovery.recoveryOrder(start: 0)
        let driveFirst = BackgroundProviderRecovery.recoveryOrder(start: 1)
        let billingFirst = BackgroundProviderRecovery.recoveryOrder(start: 2)
        #expect(calendarFirst == [.calendar, .drive, .quickBooks])
        #expect(driveFirst == [.drive, .quickBooks, .calendar])
        #expect(billingFirst == [.quickBooks, .calendar, .drive])
        var events: [String] = []
        var authorized = true
        let completed = await BackgroundProviderRecovery.runVerifiedProviders(
            stillAuthorized: { authorized }, order: billingFirst,
            calendar: { events.append("calendar"); authorized = false; return false },
            drive: { Issue.record("Drive must not run after the lease expires"); return false },
            quickBooks: { events.append("quickbooks"); return true }
        )
        #expect(!completed)
        #expect(events == ["quickbooks", "calendar"])
    }
}
