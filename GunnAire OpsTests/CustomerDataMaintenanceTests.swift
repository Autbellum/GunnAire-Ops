import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor
struct CustomerDataMaintenanceTests {
    private func fixture() throws -> ModelContainer {
        let schema = GunnAireModelSchema.schema
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let context = ModelContext(container)
        let customer = Customer(name: "Service Call")
        let invoice = Invoice(customer: customer, amount: 100)
        context.insert(customer)
        context.insert(invoice)
        context.insert(Payment(invoice: invoice, amount: 25))
        try context.save()
        return container
    }

    private func permit(_ epoch: CompanyWorkspaceMutationEpoch) -> CustomerCleanupCommitPermit {
        let now = Date()
        return .init(epoch: epoch, issuedAt: now, expiresAt: now.addingTimeInterval(60))
    }

    private func expectPreserved(_ container: ModelContainer) throws {
        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<Customer>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<Invoice>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<Payment>()) == 1)
    }

    @Test func authorizedCleanupCommitsFinancialRecordsOffMain() async throws {
        let container = try fixture()
        let epoch = CompanyWorkspaceMutationEpoch()
        let summary = try await CustomerCalendarCleanup.run(container: container, authorize: { permit(epoch) }, save: {
            #expect(!Thread.isMainThread)
            #expect(!$0.autosaveEnabled)
            try $0.save()
        })
        #expect(summary.customers == 1)
        #expect(summary.invoices == 1)
        #expect(summary.payments == 1)
        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<Customer>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Invoice>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Payment>()) == 0)
    }

    @Test func deniedPrecommitAuthorizationRollsBackStagedFinancialDeletes() async throws {
        let container = try fixture()
        await #expect(throws: CustomerCalendarCleanupError.self) {
            try await CustomerCalendarCleanup.run(container: container, authorize: {
                throw CustomerCalendarCleanupError.accessChanged
            })
        }
        try expectPreserved(container)
    }

    @Test func accountRevocationAfterPermitRejectsBackgroundCommit() async throws {
        let container = try fixture()
        let epoch = CompanyWorkspaceMutationEpoch()
        await #expect(throws: CustomerCalendarCleanupError.self) {
            try await CustomerCalendarCleanup.run(container: container,
                authorize: { permit(epoch) }, beforeCommit: { epoch.invalidate() })
        }
        try expectPreserved(container)
    }

    @Test func changedCustomerDuringAuthorizationKeepsAllFinancialRecords() async throws {
        let container = try fixture()
        let epoch = CompanyWorkspaceMutationEpoch()
        await #expect(throws: CustomerCalendarCleanupError.self) {
            try await CustomerCalendarCleanup.run(container: container, authorize: {
                let editing = ModelContext(container)
                let customer = try #require(editing.fetch(FetchDescriptor<Customer>()).first)
                customer.name = "Real Customer"
                customer.quickBooksID = "linked-customer"
                try editing.save()
                return permit(epoch)
            })
        }
        try expectPreserved(container)
        #expect(try ModelContext(container).fetch(FetchDescriptor<Customer>()).first?.name == "Real Customer")
    }

    @Test func cancellationAfterAuthorizationPreventsCommit() async throws {
        let container = try fixture()
        let epoch = CompanyWorkspaceMutationEpoch()
        let entered = AsyncStream<Void>.makeStream()
        let resume = AsyncStream<Void>.makeStream()
        let task = Task {
            try await CustomerCalendarCleanup.run(container: container, authorize: {
                entered.continuation.yield(())
                for await _ in resume.stream { break }
                return permit(epoch)
            })
        }
        for await _ in entered.stream { break }
        task.cancel()
        resume.continuation.yield(())
        await #expect(throws: CancellationError.self) { try await task.value }
        try expectPreserved(container)
    }

    @Test func failedSaveRollsBackAndDoesNotReportDeletionSuccess() async throws {
        let container = try fixture()
        let epoch = CompanyWorkspaceMutationEpoch()
        await #expect(throws: CocoaError.self) {
            try await CustomerCalendarCleanup.run(container: container, authorize: { permit(epoch) }, save: { _ in
                throw CocoaError(.fileWriteUnknown)
            })
        }
        try expectPreserved(container)
    }

    @Test func permitExpiresAndCannotAuthorizeASecondCommit() throws {
        let now = Date()
        let permit = CustomerCleanupCommitPermit(epoch: .init(), issuedAt: now, expiresAt: now.addingTimeInterval(5))
        try permit.beginCommit(now: now)
        #expect(throws: CustomerCalendarCleanupError.self) { try permit.beginCommit(now: now) }
        let expired = CustomerCleanupCommitPermit(epoch: .init(), issuedAt: now, expiresAt: now)
        #expect(throws: CustomerCalendarCleanupError.self) { try expired.beginCommit(now: now) }
    }

    @Test func appleBusinessSessionClearRevokesPermitBeforeReturning() throws {
        let epoch = CompanyWorkspaceMutationEpoch()
        let permit = permit(epoch)
        let auth = AppleAuthManager(testMutationInvalidation: { epoch.invalidate() })
        auth.discardBusinessSessionProof()
        // No actor yield or SwiftUI observer is needed to retire the permit.
        #expect(throws: CustomerCalendarCleanupError.self) { try permit.beginCommit() }
    }

    @Test func googleBusinessSessionClearRevokesPermitBeforeReturning() throws {
        let currentEpoch = CompanyWorkspaceMutationEpoch()
        // Install the revocation callback after initialization, then issue the
        // permit that must be retired by the session-clear operation itself.
        var invalidation: (() -> Void)?
        let clearAuth = GoogleAuthManager(testTokens: .init(accessToken: "fixture", refreshToken: nil,
            idToken: nil, expiration: .distantFuture), email: "admin@example.test",
            businessEmail: { "admin@example.test" }, mutationInvalidation: { invalidation?() },
            transport: { _ in throw URLError(.unsupportedURL) })
        invalidation = { currentEpoch.invalidate() }
        let permit = permit(currentEpoch)
        clearAuth.discardBusinessSessionProof()
        #expect(throws: CustomerCalendarCleanupError.self) { try permit.beginCommit() }
    }
}
