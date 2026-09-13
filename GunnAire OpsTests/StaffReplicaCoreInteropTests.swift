import Foundation
import XCTest
@testable import GunnAire_Ops

final class StaffReplicaCoreInteropTests: XCTestCase {
    @MainActor func testNativeCoreCaptureExportsAnExactBackendContractVector() throws {
        func id(_ value: Int) -> UUID { UUID(uuidString: String(format: "b1000000-0000-4000-8000-%012d", value))! }
        let date = try XCTUnwrap(CompanyWorkspaceClock.parse("2026-09-09T10:00:00Z"))
        let customer = Customer(id: id(1), name: "Contract fixture customer", phone: "555-0100", email: "customer@example.invalid", address: "10 Main",
                                allowsTransactionalEmail: true, allowsServiceText: false)
        let location = CustomerServiceLocation(id: id(2), customer: customer, name: "Assigned property", address: "10 Main",
                                               contactName: "Fixture contact", contactPhone: "555-0101", accessNotes: "Call on arrival", isPrimary: true)
        let equipment = CustomerEquipment(id: id(3), customer: customer, serviceLocationID: location.id, name: "Heat pump",
                                          manufacturer: "Fixture", modelNumber: "MODEL-1", serialNumber: "SERIAL-1", location: "Side yard",
                                          installDate: date, warrantyExpiration: date, filterSize: "Fixture size", notes: "Original equipment notes")
        let technician = Technician(id: id(4), name: "Fixture technician", contactInfo: "field@example.invalid", laborCostPerHour: 50)
        let item = Item(id: id(5), quickBooksID: "17", pricebookReviewStatus: .approved, pricebookCreatedByEmail: "field@example.invalid",
                        name: "Fixture item", unitPrice: 12.34, purchaseCost: 5.67, isTaxable: true, itemDescription: "Original item description", sku: "FIX-1", vendorPartNumber: "PART-1")
        let job = ServiceCall(id: id(6), eventTitle: "Fixture repair", siteAddress: "10 Main", serviceLocationID: location.id,
                              customerEquipmentID: equipment.id, type: .repair, scheduledDate: date, duration: 3600,
                              promisedArrivalWindowStart: date, promisedArrivalWindowEnd: date.addingTimeInterval(3600), assignedTechnician: technician,
                              customer: customer, notes: "Original visit notes", findingsSummary: "Observed condition", recommendedWorkSummary: "Review repair",
                              followUpRequired: true, followUpAction: "Call customer", followUpDueDate: date)
        job.visitDispositionNotes = "Original disposition"; job.cancellationReason = "Retained history"; job.cancelledAt = date
        job.technicianEnRouteAt = date; job.technicianArrivedAt = date
        let source = try StaffReplicaCoreSource.capture(customers: [customer], locations: [location], equipment: [equipment],
                                                       technicians: [technician], jobs: [job], items: [item])
        XCTAssertEqual(source.records.count, 6)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let attachment = XCTAttachment(data: try encoder.encode(source), uniformTypeIdentifier: "public.json")
        attachment.name = "Staff core native-to-backend contract vector"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
