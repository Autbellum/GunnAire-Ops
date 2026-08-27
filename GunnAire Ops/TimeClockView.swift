import SwiftUI
import SwiftData

struct TimeClockView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var googleAuth = GoogleAuthManager.shared
    @Query(sort: \TimeEntry.clockIn, order: .reverse) private var entries: [TimeEntry]
    @Query(sort: \ServiceCall.scheduledDate, order: .reverse) private var serviceCalls: [ServiceCall]
    @Query(sort: \Technician.name, order: .forward) private var technicians: [Technician]
    @State private var syncMessage: String?
    @State private var selectedServiceCallID: UUID?
    @State private var syncingEntryIDs: Set<UUID> = []

    private var signedInEmail: String {
        googleAuth.signedInEmail ?? UserDefaults.standard.string(forKey: "SignedInGoogleEmail") ?? "testing@gunnaire.com"
    }

    private var isOwnerAccount: Bool {
        AppAccess.isPrimaryAdmin(signedInEmail)
    }

    private var userEntries: [TimeEntry] {
        entries.filter { $0.userEmail.caseInsensitiveCompare(signedInEmail) == .orderedSame }
    }

    private var openEntry: TimeEntry? {
        userEntries.first { $0.isOpen }
    }

    private var trackableServiceCalls: [ServiceCall] {
        serviceCalls
            .filter { call in
                guard call.status != .cancelled && call.status != .completed && call.status != .invoiced else {
                    return false
                }
                let signedInTechnicianIDs = Set(technicians.compactMap { technician in
                    AppAccess.normalizedEmail(technician.contactInfo) == AppAccess.normalizedEmail(signedInEmail) ? technician.id : nil
                })
                let isLead = AppAccess.normalizedEmail(call.assignedTechnician?.contactInfo) == AppAccess.normalizedEmail(signedInEmail)
                return isLead || !signedInTechnicianIDs.isDisjoint(with: call.assignedCrewTechnicianIDs)
            }
            .sorted { lhs, rhs in
                if lhs.status != rhs.status {
                    return lhs.status == .inProgress
                }
                return lhs.scheduledDate < rhs.scheduledDate
            }
    }

    private var selectedServiceCall: ServiceCall? {
        guard let selectedServiceCallID else { return nil }
        return trackableServiceCalls.first { $0.id == selectedServiceCallID }
    }

    private var currentTechnicianTimeMapping: TechnicianQuickBooksTimeMapping? {
        QuickBooksTimeActivitySync.mapping(for: signedInEmail, technicians: technicians)
    }

    private func serviceCall(for id: UUID?) -> ServiceCall? {
        guard let id else { return nil }
        return serviceCalls.first { $0.id == id }
    }

    var body: some View {
        NavigationStack {
            List {
                if isOwnerAccount {
                    Section("Owner Account") {
                        Text("Owner account signed in.")
                            .font(.headline)
                        Text("Clock in/out is not required for Eric Gunn.")
                            .foregroundColor(.secondary)
                    }
                } else {
                    Section("Current Status") {
                        if let openEntry {
                            Text("Clocked in since \(openEntry.clockIn.formatted(date: .abbreviated, time: .shortened))")
                            if let serviceCall = openEntry.serviceCall {
                                Text("Job: \(serviceCall.customer.name)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if !trackableServiceCalls.isEmpty {
                                Picker("Current job", selection: Binding(
                                    get: { openEntry.serviceCall?.id },
                                    set: { openEntry.serviceCall = serviceCall(for: $0) }
                                )) {
                                    Text("No job selected").tag(UUID?.none)
                                    ForEach(trackableServiceCalls) { call in
                                        Text(jobLabel(for: call)).tag(UUID?.some(call.id))
                                    }
                                }
                                Text("Optional. Link time to the job currently being worked so labor and QBO time activity retain the customer context.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Button("Clock Out") {
                                clockOut(openEntry)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)
                            if let syncMessage {
                                Text(syncMessage)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            Text("You are clocked out.")
                                .foregroundColor(.secondary)
                            if !trackableServiceCalls.isEmpty {
                                Picker("Job for this shift", selection: $selectedServiceCallID) {
                                    Text("General time / no job").tag(UUID?.none)
                                    ForEach(trackableServiceCalls) { call in
                                        Text(jobLabel(for: call)).tag(UUID?.some(call.id))
                                    }
                                }
                            }
                            Button("Clock In") {
                                modelContext.insert(TimeEntry(userEmail: signedInEmail, serviceCall: selectedServiceCall))
                                selectedServiceCallID = nil
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)
                            Text("Job link is optional. Use general time for non-job work.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if Config.QuickBooksTime.enabled {
                                Text(qboTimeSyncConfigurationMessage)
                                    .font(.caption)
                                    .foregroundColor(currentTechnicianTimeMapping == nil ? .orange : .secondary)
                            }
                        }
                    }
                }

                if !isOwnerAccount {
                    Section("Recent Time Entries") {
                        if userEntries.isEmpty {
                            Text("No time entries yet.")
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(userEntries.prefix(20)) { entry in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.clockIn.formatted(date: .abbreviated, time: .shortened))
                                        .font(.headline)
                                    Text(entry.clockOut.map { "Out: \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Open shift")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    if let quickBooksID = entry.quickBooksTimeActivityID {
                                        Text("QBO TimeActivity \(quickBooksID)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    } else if let syncError = entry.quickBooksTimeActivitySyncError {
                                        Text("QBO sync issue: \(syncError)")
                                            .font(.caption)
                                            .foregroundColor(.orange)
                                    }
                                    if Config.QuickBooksTime.enabled,
                                       !entry.isOpen,
                                       entry.quickBooksTimeActivityID == nil {
                                        Button(syncingEntryIDs.contains(entry.id) ? "Checking QuickBooks..." : "Retry QBO Sync") {
                                            syncCompletedEntryToQuickBooks(entry)
                                        }
                                        .buttonStyle(.bordered)
                                        .disabled(syncingEntryIDs.contains(entry.id))
                                        .accessibilityIdentifier("RetryQBOTimeSync-\(entry.id.uuidString)")
                                    }
                                    if let serviceCall = entry.serviceCall {
                                        Text("Job: \(serviceCall.customer.name)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Time Clock")
        }
    }

    private var qboTimeSyncConfigurationMessage: String {
        guard Config.QuickBooksTime.enabled else { return "QBO time sync is off." }
        guard let currentTechnicianTimeMapping else {
            return "QBO time sync needs this technician's Employee or Vendor ID in Sync & Integrations."
        }
        return "QBO sync uses \(currentTechnicianTimeMapping.kind.displayName) \(currentTechnicianTimeMapping.referenceID) for this technician after clock-out."
    }

    private func clockOut(_ entry: TimeEntry) {
        entry.clockOut = Date()
        entry.quickBooksTimeActivitySyncError = nil
        syncMessage = nil
        try? modelContext.save()
        syncCompletedEntryToQuickBooks(entry)
    }

    private func syncCompletedEntryToQuickBooks(_ entry: TimeEntry) {
        guard Config.QuickBooksTime.enabled else { return }
        guard entry.quickBooksTimeActivityID == nil else { return }
        guard !entry.isOpen else {
            entry.quickBooksTimeActivitySyncError = "Clock out before syncing time."
            return
        }
        guard let mapping = QuickBooksTimeActivitySync.mapping(
            for: entry.userEmail,
            technicians: technicians
        ) else {
            entry.quickBooksTimeActivitySyncError = "No technician-specific QuickBooks Employee or Vendor ID is configured."
            syncMessage = qboTimeSyncConfigurationMessage
            try? modelContext.save()
            return
        }
        guard QuickBooksDataAPI.shared.isAuthenticated else {
            entry.quickBooksTimeActivitySyncError = "QuickBooks is not connected."
            syncMessage = "QuickBooks is not connected; time stayed local."
            try? modelContext.save()
            return
        }
        guard let payload = QuickBooksTimeActivitySync.makePayload(for: entry, mapping: mapping) else {
            entry.quickBooksTimeActivitySyncError = "Could not build a valid TimeActivity duration."
            syncMessage = entry.quickBooksTimeActivitySyncError
            try? modelContext.save()
            return
        }

        syncingEntryIDs.insert(entry.id)
        entry.quickBooksTimeActivitySyncError = nil
        syncMessage = "Checking QuickBooks before publishing completed time..."
        try? modelContext.save()

        QuickBooksDataAPI.shared.fetchTimeActivities { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    syncingEntryIDs.remove(entry.id)
                    entry.quickBooksTimeActivitySyncError = "Could not reconcile existing QBO time: \(error.localizedDescription)"
                    syncMessage = "QuickBooks reconciliation failed; time stayed local and was not duplicated."
                    try? modelContext.save()
                case .success(let activities):
                    if let existing = QuickBooksTimeActivitySync.matchingActivity(
                        for: entry.id,
                        in: activities
                    ) {
                        finishQuickBooksSync(entry, activity: existing, reconciled: true)
                    } else {
                        createQuickBooksTimeActivity(payload, for: entry)
                    }
                }
            }
        }
    }

    private func createQuickBooksTimeActivity(
        _ payload: QuickBooksTimeActivityCreate,
        for entry: TimeEntry
    ) {
        syncMessage = "Publishing completed time to QuickBooks..."
        QuickBooksDataAPI.shared.createTimeActivity(payload) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let activity):
                    finishQuickBooksSync(entry, activity: activity, reconciled: false)
                case .failure(let error):
                    syncingEntryIDs.remove(entry.id)
                    entry.quickBooksTimeActivitySyncError = error.localizedDescription
                    syncMessage = "QBO time sync failed; time stayed local and can be retried."
                    try? modelContext.save()
                }
            }
        }
    }

    private func finishQuickBooksSync(
        _ entry: TimeEntry,
        activity: QuickBooksTimeActivity,
        reconciled: Bool
    ) {
        syncingEntryIDs.remove(entry.id)
        entry.quickBooksTimeActivityID = activity.Id
        entry.quickBooksTimeActivitySyncToken = activity.SyncToken
        entry.quickBooksTimeActivitySyncedAt = Date()
        entry.quickBooksTimeActivitySyncError = nil
        syncMessage = reconciled
            ? "Recovered existing QBO TimeActivity \(activity.Id); no duplicate was created."
            : "Synced to QBO TimeActivity \(activity.Id)."
        try? modelContext.save()
    }

    private func jobLabel(for call: ServiceCall) -> String {
        "\(call.customer.name) • \(call.type.displayName) • \(call.scheduledDate.formatted(date: .abbreviated, time: .shortened))"
    }

}

enum QuickBooksTimeActivitySync {
    static func mapping(
        for userEmail: String,
        technicians: [Technician]
    ) -> TechnicianQuickBooksTimeMapping? {
        let normalizedEmail = AppAccess.normalizedEmail(userEmail)
        guard !normalizedEmail.isEmpty else { return nil }
        let mappings = technicians
            .filter { AppAccess.normalizedEmail($0.contactInfo) == normalizedEmail }
            .compactMap(\.quickBooksTimeMapping)
        let signatures = Set(mappings.map { "\($0.kind.rawValue):\($0.referenceID)" })
        guard signatures.count == 1 else { return nil }
        return mappings.first
    }

    static func operationMarker(for entryID: UUID) -> String {
        "GUNNAIRE-TIME:\(entryID.uuidString.uppercased())"
    }

    static func matchingActivity(
        for entryID: UUID,
        in activities: [QuickBooksTimeActivity]
    ) -> QuickBooksTimeActivity? {
        let marker = operationMarker(for: entryID)
        return activities.first { activity in
            activity.Description?.localizedCaseInsensitiveContains(marker) == true
        }
    }

    static func makePayload(
        for entry: TimeEntry,
        mapping: TechnicianQuickBooksTimeMapping
    ) -> QuickBooksTimeActivityCreate? {
        guard let durationMinutes = entry.durationMinutes else { return nil }
        let hours = durationMinutes / 60
        let minutes = durationMinutes % 60
        let nameOf = mapping.kind.quickBooksNameOf
        let entityRef = QuickBooksReference(value: mapping.referenceID, name: mapping.technicianName)
        let customerID = entry.serviceCall?.customer.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let customerRef = customerID.flatMap { $0.isEmpty ? nil : QuickBooksReference(value: $0, name: entry.serviceCall?.customer.name) }
        let projectID = Config.QuickBooksTime.projectRef.trimmingCharacters(in: .whitespacesAndNewlines)
        let itemID = Config.QuickBooksTime.itemRef.trimmingCharacters(in: .whitespacesAndNewlines)
        let payrollItemID = Config.QuickBooksTime.payrollItemRef.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = [
            entry.notes?.trimmingCharacters(in: .whitespacesAndNewlines),
            entry.serviceCall.map { "GunnAire Ops time for \($0.customer.name)" },
            "Clocked \(entry.clockIn.formatted(date: .abbreviated, time: .shortened)) - \(entry.clockOut?.formatted(date: .abbreviated, time: .shortened) ?? "")",
            operationMarker(for: entry.id)
        ]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: "\n")

        return QuickBooksTimeActivityCreate(
            TxnDate: qboDateString(entry.clockIn),
            NameOf: nameOf,
            EmployeeRef: nameOf == "Employee" ? entityRef : nil,
            VendorRef: nameOf == "Vendor" ? entityRef : nil,
            CustomerRef: customerRef,
            ProjectRef: projectID.isEmpty ? nil : QuickBooksReference(value: projectID, name: nil),
            ItemRef: itemID.isEmpty ? nil : QuickBooksReference(value: itemID, name: nil),
            PayrollItemRef: payrollItemID.isEmpty ? nil : QuickBooksReference(value: payrollItemID, name: nil),
            Hours: hours,
            Minutes: minutes,
            Description: description.isEmpty ? nil : description
        )
    }

    static func qboDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

#Preview {
    TimeClockView()
}
