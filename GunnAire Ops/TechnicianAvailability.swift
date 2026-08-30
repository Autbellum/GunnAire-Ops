import Foundation
import SwiftData

enum TechnicianAvailabilityKind: String, Codable, CaseIterable, Identifiable {
    case timeOff = "time_off"
    case breakPeriod = "break"
    case training
    case unavailable

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .timeOff: "Time off"
        case .breakPeriod: "Break"
        case .training: "Training"
        case .unavailable: "Unavailable"
        }
    }
}

/// A dispatcher-managed period when a technician must not be auto-scheduled.
/// This is intentionally separate from a service call so leave, training, and
/// breaks stay visible without becoming billable customer work.
@Model
final class TechnicianAvailabilityBlock {
    var id: UUID = UUID()
    var creationOperationID: UUID = UUID()
    var technicianID: UUID = UUID()
    var startsAt: Date = Date()
    var endsAt: Date = Date()
    var kindRawValue: String = TechnicianAvailabilityKind.unavailable.rawValue
    var reason: String?
    var createdAt: Date = Date()
    var createdByEmail: String = ""
    var sourceTimeOffRequestID: UUID?
    var cancelledAt: Date?
    var cancelledByEmail: String?
    var cancellationReason: String?
    var cancellationOperationID: UUID?

    init(
        id: UUID = UUID(),
        creationOperationID: UUID = UUID(),
        technicianID: UUID,
        startsAt: Date,
        endsAt: Date,
        kind: TechnicianAvailabilityKind = .unavailable,
        reason: String? = nil,
        createdAt: Date = Date(),
        createdByEmail: String = "",
        sourceTimeOffRequestID: UUID? = nil
    ) {
        self.id = id
        self.creationOperationID = creationOperationID
        self.technicianID = technicianID
        self.startsAt = startsAt
        self.endsAt = max(endsAt, startsAt.addingTimeInterval(60))
        self.kindRawValue = kind.rawValue
        self.reason = TechnicianTimeOffPolicy.optionalText(reason, limit: TechnicianTimeOffPolicy.noteLimit)
        self.createdAt = createdAt
        self.createdByEmail = AppAccess.normalizedEmail(createdByEmail)
        self.sourceTimeOffRequestID = sourceTimeOffRequestID
    }

    var kind: TechnicianAvailabilityKind {
        get { TechnicianAvailabilityKind(rawValue: kindRawValue) ?? .unavailable }
        set { kindRawValue = newValue.rawValue }
    }

    var dispatchLabel: String {
        let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        return [kind.displayName, reason].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ": ")
    }

    var isActive: Bool { cancelledAt == nil }

    func overlaps(start: Date, end: Date) -> Bool {
        isActive && start < endsAt && end > startsAt
    }
}

enum TechnicianDispatchAvailability {
    static func nextAvailableStart(
        technicianID: UUID,
        proposedStart: Date,
        duration: TimeInterval,
        serviceCalls: [ServiceCall],
        availabilityBlocks: [TechnicianAvailabilityBlock]
    ) -> Date {
        let minimumDuration = max(duration, 60)
        let callBusyPeriods = serviceCalls.compactMap { call -> (Date, Date)? in
            guard call.includesAssignedTechnician(technicianID),
                  call.status != .cancelled,
                  call.status != .completed else { return nil }
            return (call.scheduledDate, call.scheduledDate.addingTimeInterval(max(call.duration, 60)))
        }
        let availabilityBusyPeriods = availabilityBlocks
            .filter { $0.technicianID == technicianID && $0.isActive }
            .map { ($0.startsAt, $0.endsAt) }
        let busyPeriods = (callBusyPeriods + availabilityBusyPeriods)
            .sorted { $0.0 < $1.0 }

        var candidateStart = proposedStart
        while true {
            let candidateEnd = candidateStart.addingTimeInterval(minimumDuration)
            guard let conflict = busyPeriods.first(where: { candidateStart < $0.1 && candidateEnd > $0.0 }) else {
                return candidateStart
            }
            candidateStart = conflict.1
        }
    }
}

import SwiftUI

struct TechnicianAvailabilityView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Technician.name, order: .forward) private var technicians: [Technician]
    @Query(sort: \TechnicianAvailabilityBlock.startsAt, order: .forward) private var availabilityBlocks: [TechnicianAvailabilityBlock]
    @Query(sort: \TechnicianTimeOffRequest.createdAt, order: .reverse) private var timeOffRequests: [TechnicianTimeOffRequest]
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]

    @State private var selectedTechnicianID: UUID?
    @State private var showingAddBlock = false
    @State private var blockToCancel: TechnicianAvailabilityBlock?

    private var selectedTechnician: Technician? {
        technicians.first { $0.id == selectedTechnicianID } ?? technicians.first
    }

    private var visibleBlocks: [TechnicianAvailabilityBlock] {
        guard let technician = selectedTechnician else { return [] }
        return availabilityBlocks.filter { $0.technicianID == technician.id }
    }

    private var activeBlocks: [TechnicianAvailabilityBlock] { visibleBlocks.filter(\.isActive) }
    private var cancelledBlocks: [TechnicianAvailabilityBlock] { visibleBlocks.filter { !$0.isActive } }
    private var pendingRequestCount: Int { timeOffRequests.filter { $0.status == .pending }.count }

    private var canManageAvailability: Bool {
        AppAccess.canPerformScheduleMutation(
            .manageAvailability,
            email: AppIdentity.currentEmail,
            users: users
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if canManageAvailability {
                    List {
                        Section("Requests") {
                            NavigationLink {
                                TechnicianTimeOffWorkspaceView()
                            } label: {
                                HStack {
                                    Label("Review Time-Off Requests", systemImage: "calendar.badge.clock")
                                    Spacer()
                                    if pendingRequestCount > 0 {
                                        Text("\(pendingRequestCount)")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.orange)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(.orange.opacity(0.12), in: Capsule())
                                    }
                                }
                            }
                            .accessibilityIdentifier("ReviewTimeOffRequests")
                        }

                        Section("Technician") {
                            if technicians.isEmpty {
                                ContentUnavailableView("No technicians", systemImage: "person.badge.plus", description: Text("Add a technician before recording time off, breaks, or training."))
                            } else {
                                Picker("Technician", selection: Binding(
                                    get: { selectedTechnician?.id ?? UUID() },
                                    set: { selectedTechnicianID = $0 }
                                )) {
                                    ForEach(technicians) { technician in
                                        Text(technician.name).tag(technician.id)
                                    }
                                }

                                Button {
                                    selectedTechnicianID = selectedTechnician?.id
                                    showingAddBlock = true
                                } label: {
                                    Label("Add unavailable time", systemImage: "plus.circle")
                                }
                                .disabled(selectedTechnician == nil)
                            }
                        }

                        Section("Unavailable time") {
                            if activeBlocks.isEmpty {
                                Text("No breaks, time off, training, or unavailable time recorded for this technician.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(activeBlocks) { block in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(block.dispatchLabel)
                                            .font(.headline)
                                        Text("\(block.startsAt.formatted(date: .abbreviated, time: .shortened)) – \(block.endsAt.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 2)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button("Cancel", role: .destructive) { blockToCancel = block }
                                    }
                                }
                            }
                        }

                        if !cancelledBlocks.isEmpty {
                            Section("Cancelled History") {
                                ForEach(cancelledBlocks) { block in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(block.dispatchLabel).font(.subheadline.weight(.semibold))
                                        Text("\(block.startsAt.formatted(date: .abbreviated, time: .shortened)) – \(block.endsAt.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        if let cancellationReason = block.cancellationReason {
                                            Text("Cancelled: \(cancellationReason)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }

                        Section {
                            Text("Dispatch moves a proposed assignment past recorded unavailable time. It remains a recommendation: a dispatcher can still review and deliberately change the appointment.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "Dispatch Access Required",
                        systemImage: "person.badge.shield.checkmark",
                        description: Text("Only a dispatcher or administrator can change technician availability.")
                    )
                }
            }
            .navigationTitle("Technician Availability")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingAddBlock) {
                if canManageAvailability, let technician = selectedTechnician {
                    AddTechnicianAvailabilityBlockView(technician: technician)
                        .tint(Color.brandGold)
                }
            }
            .sheet(item: $blockToCancel) { block in
                CancelTechnicianAvailabilityBlockView(block: block)
                    .tint(Color.brandGold)
            }
            .onAppear {
                if selectedTechnicianID == nil {
                    selectedTechnicianID = technicians.first?.id
                }
            }
            .onChange(of: canManageAvailability) { _, isAllowed in
                if !isAllowed { showingAddBlock = false }
            }
        }
    }

}

private struct AddTechnicianAvailabilityBlockView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]

    let technician: Technician
    @State private var kind: TechnicianAvailabilityKind = .timeOff
    @State private var startsAt = Date()
    @State private var endsAt = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
    @State private var reason = ""
    @State private var errorMessage: String?

    private var canManageAvailability: Bool {
        AppAccess.canPerformScheduleMutation(
            .manageAvailability,
            email: AppIdentity.currentEmail,
            users: users
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Availability") {
                    LabeledContent("Technician", value: technician.name)
                    Picker("Type", selection: $kind) {
                        ForEach(TechnicianAvailabilityKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    DatePicker("Starts", selection: $startsAt)
                    DatePicker("Ends", selection: $endsAt, in: startsAt...)
                    TextField("Reason (optional)", text: $reason, axis: .vertical)
                        .lineLimit(2...3)
                }
            }
            .disabled(!canManageAvailability)
            .navigationTitle("Unavailable Time")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard canManageAvailability else {
                            dismiss()
                            return
                        }
                        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                        let block = TechnicianAvailabilityBlock(
                            technicianID: technician.id,
                            startsAt: startsAt,
                            endsAt: endsAt,
                            kind: kind,
                            reason: trimmedReason.isEmpty ? nil : trimmedReason,
                            createdByEmail: AppIdentity.currentEmail ?? ""
                        )
                        modelContext.insert(block)
                        modelContext.insert(TechnicianTimeOffPolicy.makeDirectBlockEvent(
                            block: block,
                            technicianName: technician.name,
                            actorEmail: AppIdentity.currentEmail ?? ""
                        ))
                        do {
                            try modelContext.save()
                            dismiss()
                        } catch {
                            modelContext.rollback()
                            errorMessage = error.localizedDescription
                        }
                    }
                    .disabled(endsAt <= startsAt || !canManageAvailability)
                }
            }
            .onAppear {
                if !canManageAvailability { dismiss() }
            }
            .onChange(of: canManageAvailability) { _, isAllowed in
                if !isAllowed { dismiss() }
            }
            .alert("Unavailable Time Not Saved", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "") }
        }
    }
}

private struct CancelTechnicianAvailabilityBlockView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TechnicianTimeOffRequest.createdAt, order: .reverse) private var requests: [TechnicianTimeOffRequest]
    @Query(sort: \Technician.name, order: .forward) private var technicians: [Technician]
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]

    let block: TechnicianAvailabilityBlock
    @State private var reason = ""
    @State private var errorMessage: String?

    private var currentEmail: String { AppAccess.normalizedEmail(AppIdentity.currentEmail) }
    private var canCancel: Bool { AppAccess.canCancelAvailabilityBlock(email: currentEmail, users: users) }
    private var sourceRequest: TechnicianTimeOffRequest? {
        guard let requestID = block.sourceTimeOffRequestID else { return nil }
        return requests.first { $0.id == requestID }
    }
    private var technicianName: String {
        technicians.first { $0.id == block.technicianID }?.name ?? sourceRequest?.technicianNameSnapshot ?? "Technician"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Cancel Unavailable Time") {
                    LabeledContent("Technician", value: technicianName)
                    LabeledContent("Period", value: "\(block.startsAt.formatted(date: .abbreviated, time: .shortened)) – \(block.endsAt.formatted(date: .abbreviated, time: .shortened))")
                    TextField("Cancellation reason", text: $reason, axis: .vertical)
                        .lineLimit(2...4)
                        .accessibilityIdentifier("AvailabilityCancellationReason")
                }
                Section {
                    Text("Cancellation removes this block from capacity calculations but retains the original record and event history.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!canCancel)
            .navigationTitle("Cancel Availability")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Keep") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Cancel Block", role: .destructive, action: cancel)
                        .disabled(!canCancel || TechnicianTimeOffPolicy.optionalText(reason, limit: TechnicianTimeOffPolicy.noteLimit) == nil)
                        .accessibilityIdentifier("ConfirmAvailabilityCancellation")
                }
            }
            .alert("Availability Not Cancelled", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "") }
            .onChange(of: canCancel) { _, allowed in if !allowed { dismiss() } }
        }
    }

    private func cancel() {
        guard canCancel else { return }
        do {
            let event = try TechnicianTimeOffPolicy.cancel(
                block: block,
                sourceRequest: sourceRequest,
                technicianName: technicianName,
                actorEmail: currentEmail,
                reason: reason
            )
            modelContext.insert(event)
            try modelContext.save()
            dismiss()
        } catch {
            modelContext.rollback()
            errorMessage = error.localizedDescription
        }
    }
}
