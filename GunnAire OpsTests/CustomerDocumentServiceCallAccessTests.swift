import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor
struct CustomerDocumentServiceCallAccessTests {
    private struct Fixture {
        let context: ModelContext
        let customer: Customer
        let call: ServiceCall

        init() throws {
            let schema = GunnAireModelSchema.schema
            context = ModelContext(try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            ]))
            customer = Customer(name: "Synthetic PDF customer")
            call = ServiceCall(type: .service, scheduledDate: .now, customer: customer)
            context.insert(customer)
            context.insert(call)
            try context.save()
        }
    }

    @Test func officeAccessResolvesOnlyTheOriginalCustomerJob() throws {
        let fixture = try Fixture()
        let admin = AppUser(email: "office@example.invalid", role: .admin)
        fixture.context.insert(admin)
        let other = ServiceCall(type: .service, scheduledDate: .now, customer: fixture.customer)
        fixture.context.insert(other)
        try fixture.context.save()

        let original = try CustomerDocumentServiceCallAccess.require(callID: fixture.call.id,
            customer: fixture.customer, context: fixture.context, email: admin.email, users: [admin])
        #expect(original === fixture.call)

        let differentCustomer = Customer(name: "Synthetic other customer")
        fixture.context.insert(differentCustomer)
        try fixture.context.save()
        do {
            _ = try CustomerDocumentServiceCallAccess.require(callID: fixture.call.id,
                customer: differentCustomer, context: fixture.context, email: admin.email, users: [admin])
            Issue.record("A PDF job was accepted under a different customer")
        } catch { #expect(error is GmailComposeError) }

        let duplicate = ServiceCall(id: fixture.call.id, type: .service,
            scheduledDate: .now, customer: fixture.customer)
        fixture.context.insert(duplicate)
        try fixture.context.save()
        do {
            _ = try CustomerDocumentServiceCallAccess.require(callID: fixture.call.id,
                customer: fixture.customer, context: fixture.context, email: admin.email, users: [admin])
            Issue.record("Duplicate job identifiers authorized a PDF")
        } catch { #expect(error is GmailComposeError) }
    }

    @Test func crewRevocationIsCheckedAtEachPublicationFence() throws {
        let fixture = try Fixture()
        let user = AppUser(email: "crew@example.invalid", role: .fieldTechnician)
        let technician = Technician(name: "Synthetic crew", contactInfo: " CREW@example.invalid ")
        fixture.context.insert(user)
        fixture.context.insert(technician)
        fixture.call.additionalTechnicianIDs = [technician.id]
        try fixture.context.save()

        try CustomerDocumentServiceCallAccess.require(call: fixture.call, context: fixture.context,
            email: user.email, users: [user])
        fixture.call.additionalTechnicianIDs = []
        try fixture.context.save()
        do {
            try CustomerDocumentServiceCallAccess.require(call: fixture.call, context: fixture.context,
                email: user.email, users: [user])
            Issue.record("Revoked crew access reached a PDF publication fence")
        } catch { #expect(error is GmailComposeError) }

        fixture.call.additionalTechnicianIDs = [technician.id]
        user.isActive = false
        try fixture.context.save()
        do {
            try CustomerDocumentServiceCallAccess.require(call: fixture.call, context: fixture.context,
                email: user.email, users: [user])
            Issue.record("A deactivated user reached a PDF publication fence")
        } catch { #expect(error is GmailComposeError) }
    }

    @Test func conflictingUserRoleStillFailsClosed() throws {
        let fixture = try Fixture()
        let admin = AppUser(email: "office@example.invalid", role: .admin)
        let conflicting = AppUser(email: " OFFICE@example.invalid ", role: .standard)
        fixture.context.insert(admin)
        fixture.context.insert(conflicting)
        try fixture.context.save()

        do {
            try CustomerDocumentServiceCallAccess.require(call: fixture.call, context: fixture.context,
                email: admin.email, users: [admin, conflicting])
            Issue.record("Conflicting user roles authorized a PDF job")
        } catch { #expect(error is GmailComposeError) }
    }
}
