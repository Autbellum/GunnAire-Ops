import Foundation
import SwiftData

enum BusinessTaskPriority: String, Codable, CaseIterable, Identifiable, Sendable {
    case low
    case normal
    case high
    case urgent

    var id: String { rawValue }

    var displayName: String { rawValue.capitalized }

    var systemImage: String {
        switch self {
        case .low: "arrow.down.circle"
        case .normal: "circle"
        case .high: "arrow.up.circle.fill"
        case .urgent: "exclamationmark.circle.fill"
        }
    }

    fileprivate var sortRank: Int {
        switch self {
        case .urgent: 0
        case .high: 1
        case .normal: 2
        case .low: 3
        }
    }
}

enum BusinessTaskStatus: String, Codable, CaseIterable, Sendable {
    case open
    case completed
    case cancelled
}

enum BusinessTaskEventKind: String, Codable, CaseIterable, Sendable {
    case created
    case updated
    case completed
    case reopened
    case cancelled

    var displayName: String { rawValue.capitalized }
}

enum BusinessTaskValidationError: LocalizedError, Equatable {
    case actorRequired
    case titleRequired
    case assigneeRequired
    case customerSnapshotRequired
    case jobRequiresCustomer
    case closedTask
    case completedTaskRequired
    case completionNoteRequired
    case cancellationReasonRequired

    var errorDescription: String? {
        switch self {
        case .actorRequired:
            "A signed-in business account is required to change a team task."
        case .titleRequired:
            "Enter a task title."
        case .assigneeRequired:
            "Assign the task to one active business account."
        case .customerSnapshotRequired:
            "A linked customer must retain its customer name."
        case .jobRequiresCustomer:
            "A linked job must also retain its customer context."
        case .closedTask:
            "Reopen this task before changing it."
        case .completedTaskRequired:
            "Only a completed task can be reopened."
        case .completionNoteRequired:
            "Enter a short completion result so the next person knows what happened."
        case .cancellationReasonRequired:
            "Enter why this task is no longer required."
        }
    }
}

@Model
final class BusinessTask {
    var id: UUID = UUID()
    var creationOperationID: UUID = UUID()
    var title: String = ""
    var taskDescription: String?
    var priorityRaw: String = BusinessTaskPriority.normal.rawValue
    var assignedToEmail: String = ""
    var dueAt: Date = Date()

    var customerID: UUID?
    var customerName: String?
    var serviceLocationID: UUID?
    var serviceLocationName: String?
    var serviceCallID: UUID?
    var serviceCallSummary: String?
    var estimateID: UUID?
    var estimateSummary: String?

    var createdAt: Date = Date()
    var createdByEmail: String = ""
    var updatedAt: Date = Date()
    var completedAt: Date?
    var completedByEmail: String?
    var completionNote: String?
    var completionOperationID: UUID?
    var cancelledAt: Date?
    var cancelledByEmail: String?
    var cancellationReason: String?
    var cancellationOperationID: UUID?

    init(
        id: UUID = UUID(),
        creationOperationID: UUID = UUID(),
        title: String,
        taskDescription: String? = nil,
        priority: BusinessTaskPriority = .normal,
        assignedToEmail: String,
        dueAt: Date,
        customerID: UUID? = nil,
        customerName: String? = nil,
        serviceLocationID: UUID? = nil,
        serviceLocationName: String? = nil,
        serviceCallID: UUID? = nil,
        serviceCallSummary: String? = nil,
        estimateID: UUID? = nil,
        estimateSummary: String? = nil,
        createdAt: Date = Date(),
        createdByEmail: String
    ) {
        self.id = id
        self.creationOperationID = creationOperationID
        self.title = BusinessTaskPolicy.boundedText(title, limit: BusinessTaskPolicy.titleLimit)
        self.taskDescription = BusinessTaskPolicy.optionalText(taskDescription, limit: BusinessTaskPolicy.descriptionLimit)
        self.priorityRaw = priority.rawValue
        self.assignedToEmail = AppAccess.normalizedEmail(assignedToEmail)
        self.dueAt = dueAt
        self.customerID = customerID
        self.customerName = BusinessTaskPolicy.optionalText(customerName, limit: BusinessTaskPolicy.snapshotLimit)
        self.serviceLocationID = serviceLocationID
        self.serviceLocationName = BusinessTaskPolicy.optionalText(serviceLocationName, limit: BusinessTaskPolicy.snapshotLimit)
        self.serviceCallID = serviceCallID
        self.serviceCallSummary = BusinessTaskPolicy.optionalText(serviceCallSummary, limit: BusinessTaskPolicy.snapshotLimit)
        self.estimateID = estimateID
        self.estimateSummary = BusinessTaskPolicy.optionalText(estimateSummary, limit: BusinessTaskPolicy.snapshotLimit)
        self.createdAt = createdAt
        self.createdByEmail = AppAccess.normalizedEmail(createdByEmail)
        self.updatedAt = createdAt
    }

    var priority: BusinessTaskPriority {
        get { BusinessTaskPriority(rawValue: priorityRaw) ?? .normal }
        set { priorityRaw = newValue.rawValue }
    }

    var status: BusinessTaskStatus {
        if cancelledAt != nil { return .cancelled }
        if completedAt != nil { return .completed }
        return .open
    }

    var isOpen: Bool { status == .open }

    func isOverdue(now: Date = Date()) -> Bool {
        isOpen && dueAt < now
    }

    var linkedRecordSummary: String? {
        serviceCallSummary ?? estimateSummary ?? serviceLocationName ?? customerName
    }
}

@Model
final class BusinessTaskEvent {
    var id: UUID = UUID()
    var operationID: UUID = UUID()
    var taskID: UUID = UUID()
    var kindRaw: String = BusinessTaskEventKind.created.rawValue
    var occurredAt: Date = Date()
    var actorEmail: String = ""
    var detail: String = ""
    var titleSnapshot: String = ""
    var assignedToEmailSnapshot: String = ""
    var dueAtSnapshot: Date = Date()
    var priorityRawSnapshot: String = BusinessTaskPriority.normal.rawValue

    init(
        id: UUID = UUID(),
        operationID: UUID = UUID(),
        taskID: UUID,
        kind: BusinessTaskEventKind,
        occurredAt: Date = Date(),
        actorEmail: String,
        detail: String,
        titleSnapshot: String,
        assignedToEmailSnapshot: String,
        dueAtSnapshot: Date,
        priority: BusinessTaskPriority
    ) {
        self.id = id
        self.operationID = operationID
        self.taskID = taskID
        self.kindRaw = kind.rawValue
        self.occurredAt = occurredAt
        self.actorEmail = AppAccess.normalizedEmail(actorEmail)
        self.detail = BusinessTaskPolicy.boundedText(detail, limit: BusinessTaskPolicy.eventDetailLimit)
        self.titleSnapshot = BusinessTaskPolicy.boundedText(titleSnapshot, limit: BusinessTaskPolicy.titleLimit)
        self.assignedToEmailSnapshot = AppAccess.normalizedEmail(assignedToEmailSnapshot)
        self.dueAtSnapshot = dueAtSnapshot
        self.priorityRawSnapshot = priority.rawValue
    }

    var kind: BusinessTaskEventKind {
        get { BusinessTaskEventKind(rawValue: kindRaw) ?? .updated }
        set { kindRaw = newValue.rawValue }
    }

    var prioritySnapshot: BusinessTaskPriority {
        BusinessTaskPriority(rawValue: priorityRawSnapshot) ?? .normal
    }
}

enum BusinessTaskPolicy {
    static let titleLimit = 100
    static let descriptionLimit = 1_000
    static let snapshotLimit = 200
    static let completionNoteLimit = 600
    static let cancellationReasonLimit = 600
    static let eventDetailLimit = 800

    struct CreatedTask {
        let task: BusinessTask
        let event: BusinessTaskEvent
    }

    static func makeTask(
        title: String,
        taskDescription: String? = nil,
        priority: BusinessTaskPriority = .normal,
        assignedToEmail: String,
        dueAt: Date,
        customerID: UUID? = nil,
        customerName: String? = nil,
        serviceLocationID: UUID? = nil,
        serviceLocationName: String? = nil,
        serviceCallID: UUID? = nil,
        serviceCallSummary: String? = nil,
        estimateID: UUID? = nil,
        estimateSummary: String? = nil,
        actorEmail: String?,
        now: Date = Date(),
        creationOperationID: UUID = UUID()
    ) throws -> CreatedTask {
        let actor = AppAccess.normalizedEmail(actorEmail)
        guard !actor.isEmpty else { throw BusinessTaskValidationError.actorRequired }
        let normalizedTitle = boundedText(title, limit: titleLimit)
        guard !normalizedTitle.isEmpty else { throw BusinessTaskValidationError.titleRequired }
        let assignee = AppAccess.normalizedEmail(assignedToEmail)
        guard !assignee.isEmpty else { throw BusinessTaskValidationError.assigneeRequired }
        let normalizedCustomerName = optionalText(customerName, limit: snapshotLimit)
        if customerID != nil, normalizedCustomerName == nil {
            throw BusinessTaskValidationError.customerSnapshotRequired
        }
        if serviceCallID != nil, customerID == nil {
            throw BusinessTaskValidationError.jobRequiresCustomer
        }

        let task = BusinessTask(
            creationOperationID: creationOperationID,
            title: normalizedTitle,
            taskDescription: taskDescription,
            priority: priority,
            assignedToEmail: assignee,
            dueAt: dueAt,
            customerID: customerID,
            customerName: normalizedCustomerName,
            serviceLocationID: serviceLocationID,
            serviceLocationName: serviceLocationName,
            serviceCallID: serviceCallID,
            serviceCallSummary: serviceCallSummary,
            estimateID: estimateID,
            estimateSummary: estimateSummary,
            createdAt: now,
            createdByEmail: actor
        )
        let event = event(
            for: task,
            kind: .created,
            actorEmail: actor,
            detail: "Task created and assigned.",
            now: now,
            operationID: creationOperationID
        )
        return CreatedTask(task: task, event: event)
    }

    static func update(
        _ task: BusinessTask,
        title: String,
        taskDescription: String?,
        priority: BusinessTaskPriority,
        assignedToEmail: String,
        dueAt: Date,
        actorEmail: String?,
        now: Date = Date(),
        operationID: UUID = UUID()
    ) throws -> BusinessTaskEvent {
        guard task.isOpen else { throw BusinessTaskValidationError.closedTask }
        let actor = AppAccess.normalizedEmail(actorEmail)
        guard !actor.isEmpty else { throw BusinessTaskValidationError.actorRequired }
        let normalizedTitle = boundedText(title, limit: titleLimit)
        guard !normalizedTitle.isEmpty else { throw BusinessTaskValidationError.titleRequired }
        let assignee = AppAccess.normalizedEmail(assignedToEmail)
        guard !assignee.isEmpty else { throw BusinessTaskValidationError.assigneeRequired }

        let previousAssignee = task.assignedToEmail
        let previousDueAt = task.dueAt
        task.title = normalizedTitle
        task.taskDescription = optionalText(taskDescription, limit: descriptionLimit)
        task.priority = priority
        task.assignedToEmail = assignee
        task.dueAt = dueAt
        task.updatedAt = now

        var changes: [String] = ["Task details updated"]
        if previousAssignee != assignee { changes.append("reassigned to another approved business account") }
        if previousDueAt != dueAt { changes.append("due date changed") }
        return event(
            for: task,
            kind: .updated,
            actorEmail: actor,
            detail: changes.joined(separator: "; ") + ".",
            now: now,
            operationID: operationID
        )
    }

    static func complete(
        _ task: BusinessTask,
        actorEmail: String?,
        note: String?,
        now: Date = Date(),
        operationID: UUID = UUID()
    ) throws -> BusinessTaskEvent {
        guard task.isOpen else { throw BusinessTaskValidationError.closedTask }
        let actor = AppAccess.normalizedEmail(actorEmail)
        guard !actor.isEmpty else { throw BusinessTaskValidationError.actorRequired }
        let normalizedNote = optionalText(note, limit: completionNoteLimit)
        guard normalizedNote != nil else { throw BusinessTaskValidationError.completionNoteRequired }
        task.completedAt = now
        task.completedByEmail = actor
        task.completionNote = normalizedNote
        task.completionOperationID = operationID
        task.updatedAt = now
        return event(
            for: task,
            kind: .completed,
            actorEmail: actor,
            detail: normalizedNote ?? "Task completed.",
            now: now,
            operationID: operationID
        )
    }

    static func reopen(
        _ task: BusinessTask,
        actorEmail: String?,
        reason: String?,
        now: Date = Date(),
        operationID: UUID = UUID()
    ) throws -> BusinessTaskEvent {
        guard task.status == .completed else { throw BusinessTaskValidationError.completedTaskRequired }
        let actor = AppAccess.normalizedEmail(actorEmail)
        guard !actor.isEmpty else { throw BusinessTaskValidationError.actorRequired }
        let detail = optionalText(reason, limit: completionNoteLimit) ?? "Task reopened for additional work."
        task.completedAt = nil
        task.completedByEmail = nil
        task.completionNote = nil
        task.completionOperationID = nil
        task.updatedAt = now
        return event(
            for: task,
            kind: .reopened,
            actorEmail: actor,
            detail: detail,
            now: now,
            operationID: operationID
        )
    }

    static func cancel(
        _ task: BusinessTask,
        actorEmail: String?,
        reason: String?,
        now: Date = Date(),
        operationID: UUID = UUID()
    ) throws -> BusinessTaskEvent {
        guard task.isOpen else { throw BusinessTaskValidationError.closedTask }
        let actor = AppAccess.normalizedEmail(actorEmail)
        guard !actor.isEmpty else { throw BusinessTaskValidationError.actorRequired }
        let normalizedReason = optionalText(reason, limit: cancellationReasonLimit)
        guard normalizedReason != nil else { throw BusinessTaskValidationError.cancellationReasonRequired }
        task.cancelledAt = now
        task.cancelledByEmail = actor
        task.cancellationReason = normalizedReason
        task.cancellationOperationID = operationID
        task.updatedAt = now
        return event(
            for: task,
            kind: .cancelled,
            actorEmail: actor,
            detail: normalizedReason ?? "Task cancelled.",
            now: now,
            operationID: operationID
        )
    }

    static func visibleTasks(
        from tasks: [BusinessTask],
        email: String?,
        users: [AppUser],
        visibleServiceCallIDs: Set<UUID> = []
    ) -> [BusinessTask] {
        guard let role = AppAccess.activeRole(email: email, users: users) else { return [] }
        let normalized = AppAccess.normalizedEmail(email)
        let visible = tasks.filter { task in
            switch role {
            case .admin, .dispatcher:
                return true
            case .accounting, .standard:
                return task.assignedToEmail == normalized
            case .fieldTechnician:
                return task.assignedToEmail == normalized ||
                    task.serviceCallID.map(visibleServiceCallIDs.contains) == true
            }
        }
        return ordered(visible)
    }

    static func ordered(_ tasks: [BusinessTask], now: Date = Date()) -> [BusinessTask] {
        tasks.sorted { lhs, rhs in
            if lhs.status != rhs.status {
                let order: [BusinessTaskStatus: Int] = [.open: 0, .completed: 1, .cancelled: 2]
                return (order[lhs.status] ?? 3) < (order[rhs.status] ?? 3)
            }
            if lhs.isOverdue(now: now) != rhs.isOverdue(now: now) {
                return lhs.isOverdue(now: now)
            }
            if lhs.priority.sortRank != rhs.priority.sortRank {
                return lhs.priority.sortRank < rhs.priority.sortRank
            }
            if lhs.dueAt != rhs.dueAt { return lhs.dueAt < rhs.dueAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    static func events(for taskID: UUID, in events: [BusinessTaskEvent]) -> [BusinessTaskEvent] {
        events
            .filter { $0.taskID == taskID }
            .sorted {
                if $0.occurredAt != $1.occurredAt { return $0.occurredAt > $1.occurredAt }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    static func boundedText(_ value: String, limit: Int) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }

    static func optionalText(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let normalized = boundedText(value, limit: limit)
        return normalized.isEmpty ? nil : normalized
    }

    private static func event(
        for task: BusinessTask,
        kind: BusinessTaskEventKind,
        actorEmail: String,
        detail: String,
        now: Date,
        operationID: UUID
    ) -> BusinessTaskEvent {
        BusinessTaskEvent(
            operationID: operationID,
            taskID: task.id,
            kind: kind,
            occurredAt: now,
            actorEmail: actorEmail,
            detail: detail,
            titleSnapshot: task.title,
            assignedToEmailSnapshot: task.assignedToEmail,
            dueAtSnapshot: task.dueAt,
            priority: task.priority
        )
    }
}
