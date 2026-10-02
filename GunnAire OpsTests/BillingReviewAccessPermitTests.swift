import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@Suite(.serialized)
@MainActor
struct BillingReviewAccessPermitTests {
    private func withIdentity(_ body: (String) async throws -> Void) async throws {
        let defaults = UserDefaults.standard
        let business = defaults.object(forKey: "SignedInBusinessEmail")
        let google = defaults.object(forKey: "SignedInGoogleEmail")
        let email = "billing-review@example.invalid"
        defaults.set(email, forKey: "SignedInBusinessEmail")
        defaults.set(email, forKey: "SignedInGoogleEmail")
        defer {
            if let business { defaults.set(business, forKey: "SignedInBusinessEmail") }
            else { defaults.removeObject(forKey: "SignedInBusinessEmail") }
            if let google { defaults.set(google, forKey: "SignedInGoogleEmail") }
            else { defaults.removeObject(forKey: "SignedInGoogleEmail") }
        }
        #expect(AppAccess.normalizedEmail(AppIdentity.currentEmail) == email)
        try await body(email)
    }

    private func fixture(email: String) throws -> (ModelContext, Invoice) {
        let schema = GunnAireModelSchema.schema
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let context = ModelContext(container)
        let customer = Customer(name: "Review fixture")
        let invoice = Invoice(customer: customer, amount: 100)
        context.insert(AppUser(email: email, role: .admin))
        context.insert(customer); context.insert(invoice)
        try context.save()
        return (context, invoice)
    }

    @Test func offMainPermitStopsDisplayingAChangedOriginalInvoice() async throws {
        try await withIdentity { email in
            let (context, invoice) = try fixture(email: email)
            let permit = try await BillingReviewAccessPermit.acquire(document: .invoice(invoice), context: context)
            #expect(permit.covers(invoice))
            invoice.amount = 101
            #expect(!permit.covers(invoice))
        }
    }

    @Test func normalizedConflictingUserRoleCannotAcquireReviewPermit() async throws {
        try await withIdentity { email in
            let (context, invoice) = try fixture(email: email)
            context.insert(AppUser(email: "  \(email.uppercased())  ", role: .dispatcher))
            try context.save()
            do {
                _ = try await BillingReviewAccessPermit.acquire(document: .invoice(invoice), context: context)
                Issue.record("A conflicting normalized AppUser role must deny billing review")
            } catch QuickBooksBillingWorkflowError.accessDenied {
            }
        }
    }

    @Test func auditReviewerRequiresOneNormalizedActiveUser() async throws {
        try await withIdentity { email in
            let (context, invoice) = try fixture(email: email)
            let reviewer = try await QuickBooksBillingAccessPolicy.soleOfficeReviewerOffMain(
                context: context, document: .invoice(invoice), email: email, stamp: nil)
            #expect(reviewer.role == .admin)
            context.insert(AppUser(email: " \(email.uppercased()) ", role: .admin))
            try context.save()
            do {
                _ = try await QuickBooksBillingAccessPolicy.soleOfficeReviewerOffMain(
                    context: context, document: .invoice(invoice), email: email, stamp: nil)
                Issue.record("A second normalized user cannot become the recorded reviewer")
            } catch QuickBooksBillingWorkflowError.accessDenied {
            }
        }
    }
}
