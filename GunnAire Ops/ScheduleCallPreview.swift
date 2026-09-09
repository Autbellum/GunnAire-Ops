import Foundation
import SwiftData

/// A lazy row/dialog must not retain a SwiftData object as its display state.
/// Deletion may invalidate that object before SwiftUI removes the old row.
@MainActor struct ScheduleCallIdentity: Equatable {
    let id: UUID
    let persistentID: PersistentIdentifier

    init?(_ call: ServiceCall, context: ModelContext) {
        guard Self.isLive(call, context: context) else { return nil }
        id = call.id
        persistentID = call.persistentModelID
    }

    static func isLive(_ call: ServiceCall, context: ModelContext) -> Bool {
        call.modelContext === context && !call.isDeleted
    }

    /// The caller supplies its freshly role-filtered list. Identity is not a grant.
    func resolve(in visibleCalls: [ServiceCall], context: ModelContext) -> ServiceCall? {
        let matches = visibleCalls.filter { Self.isLive($0, context: context) && $0.id == id }
        guard matches.count == 1, let call = matches.first,
              call.persistentModelID == persistentID else { return nil }
        return call
    }
}

@MainActor struct ScheduleCallPreview: Identifiable, Equatable {
    let identity: ScheduleCallIdentity
    let title: String
    let subtitle: String
    let scheduledDate: Date
    let isNextStop: Bool
    var id: UUID { identity.id }

    init?(call: ServiceCall, context: ModelContext, isNextStop: Bool,
          title: (ServiceCall) -> String, subtitle: (ServiceCall) -> String) {
        guard let identity = ScheduleCallIdentity(call, context: context) else { return nil }
        self.identity = identity
        self.title = title(call)
        self.subtitle = subtitle(call)
        scheduledDate = call.scheduledDate
        self.isNextStop = isNextStop
    }
}

@MainActor struct ScheduleDeletionConfirmation {
    let identity: ScheduleCallIdentity
    let title: String
    init?(call: ServiceCall, context: ModelContext) {
        guard let identity = ScheduleCallIdentity(call, context: context) else { return nil }
        self.identity = identity
        title = call.eventTitle ?? call.type.displayName
    }
}
