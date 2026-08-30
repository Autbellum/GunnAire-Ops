import Foundation
import SwiftData

enum TechnicianTimeOffStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case approved
    case declined
    case withdrawn
    case cancelled

    var displayName: String {
        switch self {
        case .pending: "Pending review"
        case .approved: "Approved"
        case .declined: "Declined"
        case .withdrawn: "Withdrawn"
        case .cancelled: "Cancelled"
        }
    }
}

enum TechnicianAvailabilityEventKind: String, Codable, CaseIterable, Sendable {
    case requested
    case approved
    case declined
    case withdrawn
    case blockCreated = "block_created"
    case blockCancelled = "block_cancelled"

    var displayName: String {
        switch self {
        case .requested: "Request submitted"
        case .approved: "Request approved"
        case .declined: "Request declined"
        case .withdrawn: "Request withdrawn"
        case .blockCreated: "Availability added"
        case .blockCancelled: "Availability cancelled"
        }
    }
}

enum TechnicianTimeOffValidationError: LocalizedError, Equatable {
    case actorRequired
    case technicianRequired
    case invalidInterval
    case requestNotPending
    case requestNotApproved
    case reviewerNoteRequired
    case withdrawalNotAllowed
    case cancellationReasonRequired
    case blockAlreadyCancelled
    case assignedJobConflict(Int)

    var errorDescription: String? {
        switch self {
        case .actorRequired: "A signed-in business account is required."
        case .technicianRequired: "A technician profile is required."
        case .invalidInterval: "The end of the time-off period must be after its start."
        case .requestNotPending: "Only a pending request can be reviewed."
        case .requestNotApproved: "The approved request could not be matched to this availability block."
        case .reviewerNoteRequired: "Add a private review note before declining the request."
        case .withdrawalNotAllowed: "Only the requester can withdraw their pending request."
        case .cancellationReasonRequired: "Add a reason before cancelling unavailable time."
        case .blockAlreadyCancelled: "This unavailable-time record is already cancelled."
        case .assignedJobConflict(let count):
            "This technician has \(count) active assigned job\(count == 1 ? "" : "s") during the requested time. Resolve the schedule before approval."
        }
    }
}

@Model
final class TechnicianTimeOffRequest {
    var id: UUID = UUID()
    var creationOperationID: UUID = UUID()
    var technicianID: UUID = UUID()
    var technicianNameSnapshot: String = ""
    var requestedByEmail: String = ""
    var startsAt: Date = Date()
    var endsAt: Date = Date()
    /// Kept out of schedule blocks and visible only inside the scoped request workspace.
    var privateReason: String?
    var createdAt: Date = Date()
    var statusRawValue: String = TechnicianTimeOffStatus.pending.rawValue
    var updatedAt: Date = Date()
    var reviewedAt: Date?
    var reviewedByEmail: String?
    var privateReviewNote: String?
    var reviewOperationID: UUID?
    var approvedAvailabilityBlockID: UUID?
    var withdrawnAt: Date?
    var withdrawnByEmail: String?
    var withdrawalOperationID: UUID?
    var cancelledAt: Date?
    var cancelledByEmail: String?
    var cancellationReason: String?
    var cancellationOperationID: UUID?

    init(
        id: UUID = UUID(),
        creationOperationID: UUID = UUID(),
        technicianID: UUID,
        technicianNameSnapshot: String,
        requestedByEmail: String,
        startsAt: Date,
        endsAt: Date,
        privateReason: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.creationOperationID = creationOperationID
        self.technicianID = technicianID
        self.technicianNameSnapshot = TechnicianTimeOffPolicy.boundedText(
            technicianNameSnapshot,
            limit: TechnicianTimeOffPolicy.snapshotLimit
        )
        self.requestedByEmail = AppAccess.normalizedEmail(requestedByEmail)
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.privateReason = TechnicianTimeOffPolicy.optionalText(
            privateReason,
            limit: TechnicianTimeOffPolicy.noteLimit
        )
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    var status: TechnicianTimeOffStatus {
        get { TechnicianTimeOffStatus(rawValue: statusRawValue) ?? .pending }
        set { statusRawValue = newValue.rawValue }
    }
}

@Model
final class TechnicianAvailabilityEvent {
    var id: UUID = UUID()
    var operationID: UUID = UUID()
    var requestID: UUID?
    var availabilityBlockID: UUID?
    var kindRawValue: String = TechnicianAvailabilityEventKind.requested.rawValue
    var technicianID: UUID = UUID()
    var technicianNameSnapshot: String = ""
    var startsAt: Date = Date()
    var endsAt: Date = Date()
    var actorEmail: String = ""
    var occurredAt: Date = Date()
    var privateDetail: String = ""
    var requestStatusRawSnapshot: String?

    init(
        id: UUID = UUID(),
        operationID: UUID = UUID(),
        requestID: UUID?,
        availabilityBlockID: UUID?,
        kind: TechnicianAvailabilityEventKind,
        technicianID: UUID,
        technicianNameSnapshot: String,
        startsAt: Date,
        endsAt: Date,
        actorEmail: String,
        occurredAt: Date = Date(),
        privateDetail: String,
        requestStatus: TechnicianTimeOffStatus?
    ) {
        self.id = id
        self.operationID = operationID
        self.requestID = requestID
        self.availabilityBlockID = availabilityBlockID
        self.kindRawValue = kind.rawValue
        self.technicianID = technicianID
        self.technicianNameSnapshot = TechnicianTimeOffPolicy.boundedText(
            technicianNameSnapshot,
            limit: TechnicianTimeOffPolicy.snapshotLimit
        )
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.actorEmail = AppAccess.normalizedEmail(actorEmail)
        self.occurredAt = occurredAt
        self.privateDetail = TechnicianTimeOffPolicy.boundedText(
            privateDetail,
            limit: TechnicianTimeOffPolicy.eventDetailLimit
        )
        self.requestStatusRawSnapshot = requestStatus?.rawValue
    }

    var kind: TechnicianAvailabilityEventKind {
        TechnicianAvailabilityEventKind(rawValue: kindRawValue) ?? .requested
    }
}

enum TechnicianTimeOffPolicy {
    static let snapshotLimit = 160
    static let noteLimit = 1_000
    static let eventDetailLimit = 1_200

    struct Creation {
        let request: TechnicianTimeOffRequest
        let event: TechnicianAvailabilityEvent
    }

    struct Approval {
        let block: TechnicianAvailabilityBlock
        let event: TechnicianAvailabilityEvent
    }

    static func makeRequest(
        technicianID: UUID,
        technicianName: String,
        actorEmail: String,
        startsAt: Date,
        endsAt: Date,
        privateReason: String?,
        now: Date = Date(),
        operationID: UUID = UUID()
    ) throws -> Creation {
        let actor = AppAccess.normalizedEmail(actorEmail)
        guard !actor.isEmpty else { throw TechnicianTimeOffValidationError.actorRequired }
        let name = boundedText(technicianName, limit: snapshotLimit)
        guard !name.isEmpty else { throw TechnicianTimeOffValidationError.technicianRequired }
        guard endsAt > startsAt else { throw TechnicianTimeOffValidationError.invalidInterval }

        let request = TechnicianTimeOffRequest(
            creationOperationID: operationID,
            technicianID: technicianID,
            technicianNameSnapshot: name,
            requestedByEmail: actor,
            startsAt: startsAt,
            endsAt: endsAt,
            privateReason: privateReason,
            createdAt: now
        )
        let event = makeEvent(
            request: request,
            blockID: nil,
            kind: .requested,
            actorEmail: actor,
            occurredAt: now,
            detail: "Submitted for office review.",
            operationID: operationID
        )
        return Creation(request: request, event: event)
    }

    static func conflicts(
        for request: TechnicianTimeOffRequest,
        serviceCalls: [ServiceCall]
    ) -> [ServiceCall] {
        serviceCalls.filter { call in
            guard call.includesAssignedTechnician(request.technicianID),
                  call.status != .cancelled,
                  call.status != .completed,
                  call.status != .invoiced else { return false }
            let callEnd = call.scheduledDate.addingTimeInterval(max(call.duration, 60))
            return request.startsAt < callEnd && request.endsAt > call.scheduledDate
        }
    }

    static func approve(
        _ request: TechnicianTimeOffRequest,
        actorEmail: String,
        privateReviewNote: String?,
        serviceCalls: [ServiceCall],
        now: Date = Date(),
        operationID: UUID = UUID()
    ) throws -> Approval {
        guard request.status == .pending else { throw TechnicianTimeOffValidationError.requestNotPending }
        let actor = AppAccess.normalizedEmail(actorEmail)
        guard !actor.isEmpty else { throw TechnicianTimeOffValidationError.actorRequired }
        let conflicts = conflicts(for: request, serviceCalls: serviceCalls)
        guard conflicts.isEmpty else { throw TechnicianTimeOffValidationError.assignedJobConflict(conflicts.count) }

        let block = TechnicianAvailabilityBlock(
            creationOperationID: operationID,
            technicianID: request.technicianID,
            startsAt: request.startsAt,
            endsAt: request.endsAt,
            kind: .timeOff,
            reason: nil,
            createdAt: now,
            createdByEmail: actor,
            sourceTimeOffRequestID: request.id
        )
        request.status = .approved
        request.updatedAt = now
        request.reviewedAt = now
        request.reviewedByEmail = actor
        request.privateReviewNote = optionalText(privateReviewNote, limit: noteLimit)
        request.reviewOperationID = operationID
        request.approvedAvailabilityBlockID = block.id

        let event = makeEvent(
            request: request,
            blockID: block.id,
            kind: .approved,
            actorEmail: actor,
            occurredAt: now,
            detail: request.privateReviewNote ?? "Approved and added to technician availability.",
            operationID: operationID
        )
        return Approval(block: block, event: event)
    }

    static func decline(
        _ request: TechnicianTimeOffRequest,
        actorEmail: String,
        privateReviewNote: String,
        now: Date = Date(),
        operationID: UUID = UUID()
    ) throws -> TechnicianAvailabilityEvent {
        guard request.status == .pending else { throw TechnicianTimeOffValidationError.requestNotPending }
        let actor = AppAccess.normalizedEmail(actorEmail)
        guard !actor.isEmpty else { throw TechnicianTimeOffValidationError.actorRequired }
        guard let note = optionalText(privateReviewNote, limit: noteLimit) else {
            throw TechnicianTimeOffValidationError.reviewerNoteRequired
        }
        request.status = .declined
        request.updatedAt = now
        request.reviewedAt = now
        request.reviewedByEmail = actor
        request.privateReviewNote = note
        request.reviewOperationID = operationID
        return makeEvent(
            request: request,
            blockID: nil,
            kind: .declined,
            actorEmail: actor,
            occurredAt: now,
            detail: note,
            operationID: operationID
        )
    }

    static func withdraw(
        _ request: TechnicianTimeOffRequest,
        actorEmail: String,
        now: Date = Date(),
        operationID: UUID = UUID()
    ) throws -> TechnicianAvailabilityEvent {
        let actor = AppAccess.normalizedEmail(actorEmail)
        guard request.status == .pending,
              !actor.isEmpty,
              actor == request.requestedByEmail else {
            throw TechnicianTimeOffValidationError.withdrawalNotAllowed
        }
        request.status = .withdrawn
        request.updatedAt = now
        request.withdrawnAt = now
        request.withdrawnByEmail = actor
        request.withdrawalOperationID = operationID
        return makeEvent(
            request: request,
            blockID: nil,
            kind: .withdrawn,
            actorEmail: actor,
            occurredAt: now,
            detail: "Withdrawn before office review.",
            operationID: operationID
        )
    }

    static func cancel(
        block: TechnicianAvailabilityBlock,
        sourceRequest: TechnicianTimeOffRequest?,
        technicianName: String,
        actorEmail: String,
        reason: String,
        now: Date = Date(),
        operationID: UUID = UUID()
    ) throws -> TechnicianAvailabilityEvent {
        guard block.isActive else { throw TechnicianTimeOffValidationError.blockAlreadyCancelled }
        let actor = AppAccess.normalizedEmail(actorEmail)
        guard !actor.isEmpty else { throw TechnicianTimeOffValidationError.actorRequired }
        guard let reason = optionalText(reason, limit: noteLimit) else {
            throw TechnicianTimeOffValidationError.cancellationReasonRequired
        }
        if block.sourceTimeOffRequestID != nil {
            guard let sourceRequest,
                  sourceRequest.id == block.sourceTimeOffRequestID,
                  sourceRequest.status == .approved else {
                throw TechnicianTimeOffValidationError.requestNotApproved
            }
        }

        block.cancelledAt = now
        block.cancelledByEmail = actor
        block.cancellationReason = reason
        block.cancellationOperationID = operationID

        if let sourceRequest {
            sourceRequest.status = .cancelled
            sourceRequest.updatedAt = now
            sourceRequest.cancelledAt = now
            sourceRequest.cancelledByEmail = actor
            sourceRequest.cancellationReason = reason
            sourceRequest.cancellationOperationID = operationID
        }

        return TechnicianAvailabilityEvent(
            operationID: operationID,
            requestID: sourceRequest?.id,
            availabilityBlockID: block.id,
            kind: .blockCancelled,
            technicianID: block.technicianID,
            technicianNameSnapshot: technicianName,
            startsAt: block.startsAt,
            endsAt: block.endsAt,
            actorEmail: actor,
            occurredAt: now,
            privateDetail: reason,
            requestStatus: sourceRequest?.status
        )
    }

    static func makeDirectBlockEvent(
        block: TechnicianAvailabilityBlock,
        technicianName: String,
        actorEmail: String,
        now: Date = Date()
    ) -> TechnicianAvailabilityEvent {
        TechnicianAvailabilityEvent(
            operationID: block.creationOperationID,
            requestID: nil,
            availabilityBlockID: block.id,
            kind: .blockCreated,
            technicianID: block.technicianID,
            technicianNameSnapshot: technicianName,
            startsAt: block.startsAt,
            endsAt: block.endsAt,
            actorEmail: actorEmail,
            occurredAt: now,
            privateDetail: block.reason ?? block.kind.displayName,
            requestStatus: nil
        )
    }

    static func ordered(_ requests: [TechnicianTimeOffRequest]) -> [TechnicianTimeOffRequest] {
        requests.sorted { lhs, rhs in
            let rank: [TechnicianTimeOffStatus: Int] = [.pending: 0, .approved: 1, .declined: 2, .withdrawn: 3, .cancelled: 4]
            if rank[lhs.status] != rank[rhs.status] {
                return (rank[lhs.status] ?? 99) < (rank[rhs.status] ?? 99)
            }
            if lhs.startsAt != rhs.startsAt { return lhs.startsAt < rhs.startsAt }
            return lhs.createdAt > rhs.createdAt
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

    private static func makeEvent(
        request: TechnicianTimeOffRequest,
        blockID: UUID?,
        kind: TechnicianAvailabilityEventKind,
        actorEmail: String,
        occurredAt: Date,
        detail: String,
        operationID: UUID
    ) -> TechnicianAvailabilityEvent {
        TechnicianAvailabilityEvent(
            operationID: operationID,
            requestID: request.id,
            availabilityBlockID: blockID,
            kind: kind,
            technicianID: request.technicianID,
            technicianNameSnapshot: request.technicianNameSnapshot,
            startsAt: request.startsAt,
            endsAt: request.endsAt,
            actorEmail: actorEmail,
            occurredAt: occurredAt,
            privateDetail: detail,
            requestStatus: request.status
        )
    }
}
