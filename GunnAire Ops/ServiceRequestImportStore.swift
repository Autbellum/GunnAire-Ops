import Foundation
import SwiftData

/// Imports server requests using a private context so the UI stays responsive.
/// Only a count crosses the actor boundary; SwiftData models stay in this context.
nonisolated struct ServiceRequestImportStore: Sendable {
    let container: ModelContainer

    func persist(_ remoteRequests: [BackendServiceRequestRecord]) async throws -> Int {
        try await Task.detached(priority: .utility) {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let knownIDs = Set(try context.fetch(FetchDescriptor<ServiceRequest>())
                .compactMap(\.backendRequestID))
            let formatter = ISO8601DateFormatter()
            var imported = 0
            var seenIDs = knownIDs
            for remote in remoteRequests where seenIDs.insert(remote.id).inserted {
                let type = ServiceCallType(rawValue: remote.requestedServiceType) ?? .service
                let urgency = ServiceRequestUrgency(rawValue: remote.urgency) ?? .normal
                let source = remote.source.flatMap(ServiceRequestSource.init(rawValue:)) ?? .website
                context.insert(ServiceRequest(
                    backendRequestID: remote.id,
                    customerName: remote.customerName,
                    phone: remote.phone,
                    email: remote.email,
                    address: remote.address,
                    requestedServiceType: type,
                    urgency: urgency,
                    summary: remote.summary,
                    preferredDate: remote.preferredDate.flatMap(formatter.date(from:)),
                    source: source,
                    createdByEmail: "online-booking",
                    createdAt: formatter.date(from: remote.createdAt) ?? Date()
                ))
                imported += 1
            }
            if imported > 0 {
                try context.save()
            }
            return imported
        }.value
    }
}
