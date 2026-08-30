import Foundation
import SwiftData

/// A concise, durable operational timeline for a job. This intentionally records
/// the handoff, not customer message contents or other sensitive payloads.
@Model
final class ServiceCallActivity {
    var id: UUID = UUID()
    var serviceCallID: UUID = UUID()
    var action: String = ""
    var detail: String = ""
    var actorEmail: String?
    var occurredAt: Date = Date()

    init(
        id: UUID = UUID(),
        serviceCallID: UUID,
        action: String,
        detail: String,
        actorEmail: String? = nil,
        occurredAt: Date = Date()
    ) {
        self.id = id
        self.serviceCallID = serviceCallID
        self.action = action
        self.detail = detail
        self.actorEmail = actorEmail
        self.occurredAt = occurredAt
    }

    @discardableResult
    static func record(
        for call: ServiceCall,
        action: String,
        detail: String,
        actorEmail: String? = nil,
        in modelContext: ModelContext
    ) -> ServiceCallActivity {
        let normalizedActor = actorEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let activity = ServiceCallActivity(
            serviceCallID: call.id,
            action: action,
            detail: detail,
            actorEmail: normalizedActor?.isEmpty == false ? normalizedActor : nil
        )
        modelContext.insert(activity)
        return activity
    }
}
