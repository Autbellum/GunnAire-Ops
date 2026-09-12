import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor struct StaffReplicaCoreSourceTests {
    let id = UUID(uuidString: "b1000000-0000-4000-8000-000000000001")!

    @Test func customerExportKeepsOperationalConsentWithoutStoredPaymentData() throws {
        let customer = Customer(id: id, quickBooksID: "provider-private", name: "Original", phone: "555-0100", allowsServiceText: false)
        customer.storedPaymentMethodsJSON = "must-not-export"
        let source = try StaffReplicaCoreSource.capture(customers: [customer], locations: [], equipment: [], technicians: [], jobs: [], items: [])
        let encoded = try JSONEncoder().encode(source)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(source.records[0].id == id.uuidString.lowercased())
        #expect(source.records[0].fields["allowsServiceText"] == .flag(false))
        #expect(!text.contains("must-not-export")); #expect(!text.contains("provider-private"))
        #expect(source.coverage == ["customer", "equipment", "item", "job", "location", "technician"])
    }

    @Test func preservesPropertyEquipmentAndLeadCrewIdentityWithoutPrivateWorkerCost() throws {
        let customer = Customer(name: "Original")
        let location = CustomerServiceLocation(customer: customer, name: "Property", address: "10 Main")
        let equipment = CustomerEquipment(customer: customer, serviceLocationID: location.id, name: "Heat pump", serialNumber: "SERIAL-1")
        let lead = Technician(name: "Lead", contactInfo: "lead@example.invalid", laborCostPerHour: 73, quickBooksTimeEntityRef: "private-worker")
        let crew = Technician(name: "Crew", contactInfo: "555-0101")
        let job = ServiceCall(serviceLocationID: location.id, customerEquipmentID: equipment.id, type: .repair, scheduledDate: Date(),
                              assignedTechnician: lead, additionalTechnicianIDs: [crew.id], customer: customer)
        let source = try StaffReplicaCoreSource.capture(customers: [customer], locations: [location], equipment: [equipment], technicians: [lead, crew], jobs: [job], items: [])
        let work = try #require(source.records.first { $0.kind == "job" })
        #expect(work.fields["assignedTechnicianIDs"] == .identifiers([lead.id, crew.id].map { $0.uuidString.lowercased() }.sorted()))
        #expect(work.fields["serviceLocationID"] == .text(location.id.uuidString.lowercased()))
        #expect(work.fields["customerEquipmentID"] == .text(equipment.id.uuidString.lowercased()))
        let phoneProfile = try #require(source.records.first { $0.id == crew.id.uuidString.lowercased() })
        #expect(phoneProfile.fields["email"] == nil)
        let text = String(decoding: try JSONEncoder().encode(source), as: UTF8.self)
        #expect(!text.contains("private-worker")); #expect(!text.contains("laborCostPerHour"))
    }

    @Test func corruptCrewEncodingCannotBecomeAnUnassignedJob() throws {
        let customer = Customer(name: "Original")
        let job = ServiceCall(type: .service, scheduledDate: Date(), customer: customer)
        for raw in ["{broken}", "[\"invalid-id\"]", "[\"\(id.uuidString)\",\"\(id.uuidString)\"]"] {
            job.additionalTechnicianIDsJSON = raw
            #expect(throws: StaffReplicaSourceError.self) {
                try StaffReplicaCoreSource.capture(customers: [customer], locations: [], equipment: [], technicians: [], jobs: [job], items: [])
            }
        }
        #expect(job.additionalTechnicianIDsJSON != nil)
    }

    @Test func orphanedHydrationIsNotAnEmptySuccessfulCapture() throws {
        let location = CustomerServiceLocation(name: "Pending property", address: "10 Main")
        #expect(throws: StaffReplicaSourceError.self) {
            try StaffReplicaCoreSource.capture(customers: [], locations: [location], equipment: [], technicians: [], jobs: [], items: [])
        }
        let equipment = CustomerEquipment(name: "Pending system")
        #expect(throws: StaffReplicaSourceError.self) {
            try StaffReplicaCoreSource.capture(customers: [], locations: [], equipment: [equipment], technicians: [], jobs: [], items: [])
        }
    }

    @Test func duplicateOriginalIDsAndInvalidMoneyAreNotPublished() throws {
        let a = Customer(id: id, name: "Original"), b = Customer(id: id, name: "Conflict")
        #expect(throws: StaffReplicaSourceError.self) {
            try StaffReplicaCoreSource.capture(customers: [a, b], locations: [], equipment: [], technicians: [], jobs: [], items: [])
        }
        for amount in [Double.nan, Double.infinity, -1] {
            let item = Item(name: "Review", unitPrice: amount)
            #expect(throws: StaffReplicaSourceError.self) {
                try StaffReplicaCoreSource.capture(customers: [], locations: [], equipment: [], technicians: [], jobs: [], items: [item])
            }
        }
    }

    @Test func pricebookIdentityAndReviewStateSurviveWithoutRawProviderPayloads() throws {
        let item = Item(id: id, quickBooksID: "17", pricebookReviewStatus: .needsReview, pricebookCreatedByEmail: "field@example.invalid",
                        name: "Original item", unitPrice: 12.34, purchaseCost: 5, isTaxable: true)
        item.quickBooksCatalogDetailsJSON = "private-provider-body"; item.quickBooksInventorySetupJSON = "private-setup"
        let source = try StaffReplicaCoreSource.capture(customers: [], locations: [], equipment: [], technicians: [], jobs: [], items: [item])
        #expect(source.records[0].fields["reviewStatus"] == .text("needs_review"))
        #expect(source.records[0].fields["createdByEmail"] == .text("field@example.invalid"))
        #expect(source.records[0].fields["quickBooksID"] == .text("17"))
        #expect(source.records[0].fields["unitPrice"] == .number(12.34))
        let text = String(decoding: try JSONEncoder().encode(source), as: UTF8.self)
        #expect(!text.contains("private-provider-body")); #expect(!text.contains("private-setup"))
        // Owner source may retain cost; the server must remove it before field/dispatch export.
        #expect(source.records[0].fields["purchaseCost"] == .number(5))
    }

    @Test func scalarCodecCannotHideNestedProviderObjectsOrNonfiniteNumbers() throws {
        for raw in ["{\"secret\":\"value\"}", "[1,2]", "null"] {
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(StaffReplicaScalar.self, from: Data(raw.utf8)) }
        }
        for value: StaffReplicaScalar in [.flag(true), .text("Original"), .number(12.34), .identifiers([id.uuidString.lowercased()])] {
            #expect(try JSONDecoder().decode(StaffReplicaScalar.self, from: JSONEncoder().encode(value)) == value)
        }
    }
}
