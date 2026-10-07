import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor
struct TechnicianCalendarInvitationRecoveryTests {
    @Test func changingTechnicianEmailQueuesOnlyTheirActiveManagedAppointments() throws {
        let schema = GunnAireModelSchema.schema
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let context = ModelContext(container)
        let technician = Technician(name: "Assigned", contactInfo: "old@example.invalid")
        let other = Technician(name: "Other", contactInfo: "other@example.invalid")
        let customer = Customer(name: "Synthetic customer")
        let confirmed = Date(timeIntervalSince1970: 1_800_000_000)
        let scheduled = Date(timeIntervalSince1970: 1_800_100_000)
        let assigned = ServiceCall(googleEventID: "assigned-event", googleEventConfirmedAt: confirmed,
            googleEventManagedByApp: true, type: .service, scheduledDate: scheduled,
            assignedTechnician: technician, customer: customer)
        let crew = ServiceCall(googleEventID: "crew-event", googleEventConfirmedAt: confirmed,
            googleEventManagedByApp: true, type: .service, scheduledDate: scheduled,
            assignedTechnician: other, additionalTechnicianIDs: [technician.id], customer: customer)
        let cancelled = ServiceCall(googleEventID: "cancelled-event", googleEventConfirmedAt: confirmed,
            googleEventManagedByApp: true, type: .service, scheduledDate: scheduled,
            assignedTechnician: technician, customer: customer, status: .cancelled)
        let external = ServiceCall(googleEventID: "external-event", googleEventConfirmedAt: confirmed,
            googleEventManagedByApp: false, type: .service, scheduledDate: scheduled,
            assignedTechnician: technician, customer: customer)
        let unrelated = ServiceCall(googleEventID: "other-event", googleEventConfirmedAt: confirmed,
            googleEventManagedByApp: true, type: .service, scheduledDate: scheduled,
            assignedTechnician: other, customer: customer)
        for model in [technician, other] { context.insert(model) }
        context.insert(customer)
        for call in [assigned, crew, cancelled, external, unrelated] { context.insert(call) }
        try context.save()

        let affected = try TechnicianCalendarInvitationRecovery.save(
            email: "new@example.invalid", for: technician,
            calls: [assigned, crew, cancelled, external, unrelated], context: context)
        #expect(affected == 2)
        #expect(technician.contactInfo == "new@example.invalid")
        #expect(assigned.googleEventConfirmedAt == nil && assigned.googleCalendarPendingAt != nil)
        #expect(crew.googleEventConfirmedAt == nil && crew.googleCalendarPendingAt != nil)
        #expect(cancelled.googleEventConfirmedAt == confirmed && cancelled.googleCalendarPendingAt == nil)
        #expect(external.googleEventConfirmedAt == confirmed && external.googleCalendarPendingAt == nil)
        #expect(unrelated.googleEventConfirmedAt == confirmed && unrelated.googleCalendarPendingAt == nil)

        let reopened = ModelContext(container)
        let savedCalls = try reopened.fetch(FetchDescriptor<ServiceCall>())
        let savedAssigned = try #require(savedCalls.first(where: { $0.id == assigned.id }))
        let savedCrew = try #require(savedCalls.first(where: { $0.id == crew.id }))
        #expect(savedAssigned.googleEventConfirmedAt == nil && savedAssigned.googleCalendarPendingAt != nil)
        #expect(savedCrew.googleEventConfirmedAt == nil && savedCrew.googleCalendarPendingAt != nil)

        let repeated = try TechnicianCalendarInvitationRecovery.save(
            email: " NEW@example.invalid ", for: technician,
            calls: [assigned, crew], context: context)
        #expect(repeated == 0)
        #expect(assigned.googleCalendarPendingAt != nil && crew.googleCalendarPendingAt != nil)
    }
}
