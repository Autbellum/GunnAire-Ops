import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor
struct ServiceRequestPushRouteTests {
    @Test func pushRouteRequiresVersionedRequestIdentity() {
        let requestID = UUID()
        let valid: [AnyHashable: Any] = ["gunnaire": [
            "version": NSNumber(value: 1),
            "eventID": "customer-service-request:\(requestID.uuidString)",
            "route": "serviceRequestsQueue",
            "recordID": requestID.uuidString
        ]]
        #expect(StaffPushNotificationRouteParser.serviceRequestID(from: valid) == requestID)
        let missingRecord: [AnyHashable: Any] = ["gunnaire": [
            "version": NSNumber(value: 1),
            "eventID": "customer-service-request:\(requestID.uuidString)",
            "route": "serviceRequestsQueue"
        ]]
        #expect(StaffPushNotificationRouteParser.serviceRequestID(from: missingRecord) == nil)
        let mismatchedEvent: [AnyHashable: Any] = ["gunnaire": [
            "version": NSNumber(value: 1),
            "eventID": "customer-service-request:\(UUID().uuidString)",
            "route": "serviceRequestsQueue",
            "recordID": requestID.uuidString
        ]]
        #expect(StaffPushNotificationRouteParser.serviceRequestID(from: mismatchedEvent) == nil)
    }

    @Test func importPersistsOnceAcrossFreshContexts() async throws {
        let container = try ModelContainer(
            for: ServiceRequest.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let requestID = UUID().uuidString
        let remote = BackendServiceRequestRecord(
            id: requestID,
            customerName: "Notification Customer",
            phone: "555-0100",
            email: "customer@example.invalid",
            address: "123 Test Lane",
            requestedServiceType: ServiceCallType.service.rawValue,
            urgency: ServiceRequestUrgency.normal.rawValue,
            summary: "Unit does not cool",
            source: ServiceRequestSource.customerPortal.rawValue,
            preferredDate: nil,
            createdAt: "2026-10-01T12:00:00Z",
            customerAccountID: UUID().uuidString
        )
        let store = ServiceRequestImportStore(container: container)
        #expect(try await store.persist([remote, remote]) == 1)
        let persisted = try ModelContext(container).fetch(FetchDescriptor<ServiceRequest>())
        #expect(persisted.count == 1)
        #expect(persisted.first?.backendRequestID == requestID)
        #expect(persisted.first?.leadSource == .customerPortal)
        #expect(try await store.persist([remote]) == 0)
    }
}
