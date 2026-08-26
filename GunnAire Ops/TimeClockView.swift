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
                                    .foregroundColor(Config.QuickBooksTime.isConfiguredForSync ? .secondary : .orange)
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
        guard Config.QuickBooksTime.isConfiguredForSync else {
            return "QBO time sync needs QB_TIME_ACTIVITY_ENTITY_REF set to an Employee or Vendor Id."
        }
        return "QBO sync creates a completed TimeActivity after clock-out."
    }

    private func clockOut(_ entry: TimeEntry) {
        entry.clockOut = Date()
        entry.quickBooksTimeActivitySyncError = nil
        syncMessage = nil

        guard Config.QuickBooksTime.enabled else { return }
        guard Config.QuickBooksTime.isConfiguredForSync else {
            entry.quickBooksTimeActivitySyncError = "Missing QB_TIME_ACTIVITY_ENTITY_REF."
            syncMessage = qboTimeSyncConfigurationMessage
            return
        }
        guard QuickBooksDataAPI.shared.isAuthenticated else {
            entry.quickBooksTimeActivitySyncError = "QuickBooks is not connected."
            syncMessage = "QuickBooks is not connected; time stayed local."
            return
        }
        guard let payload = Self.makeTimeActivityPayload(for: entry) else {
            entry.quickBooksTimeActivitySyncError = "Could not build a valid TimeActivity duration."
            syncMessage = entry.quickBooksTimeActivitySyncError
            return
        }

        syncMessage = "Syncing completed time to QBO..."
        QuickBooksDataAPI.shared.createTimeActivity(payload) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let activity):
                    entry.quickBooksTimeActivityID = activity.Id
                    entry.quickBooksTimeActivitySyncToken = activity.SyncToken
                    entry.quickBooksTimeActivitySyncedAt = Date()
                    entry.quickBooksTimeActivitySyncError = nil
                    syncMessage = "Synced to QBO TimeActivity \(activity.Id)."
                case .failure(let error):
                    entry.quickBooksTimeActivitySyncError = error.localizedDescription
                    syncMessage = "QBO time sync failed; time stayed local."
                }
            }
        }
    }

    private func jobLabel(for call: ServiceCall) -> String {
        "\(call.customer.name) • \(call.type.displayName) • \(call.scheduledDate.formatted(date: .abbreviated, time: .shortened))"
    }

    private static func makeTimeActivityPayload(for entry: TimeEntry) -> QuickBooksTimeActivityCreate? {
        guard let durationMinutes = entry.durationMinutes else { return nil }
        let hours = durationMinutes / 60
        let minutes = durationMinutes % 60
        let nameOf = Config.QuickBooksTime.normalizedNameOf
        let entityRef = QuickBooksReference(value: Config.QuickBooksTime.entityRef, name: nil)
        let customerID = entry.serviceCall?.customer.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let customerRef = customerID.flatMap { $0.isEmpty ? nil : QuickBooksReference(value: $0, name: entry.serviceCall?.customer.name) }
        let projectID = Config.QuickBooksTime.projectRef.trimmingCharacters(in: .whitespacesAndNewlines)
        let itemID = Config.QuickBooksTime.itemRef.trimmingCharacters(in: .whitespacesAndNewlines)
        let payrollItemID = Config.QuickBooksTime.payrollItemRef.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = [
            entry.notes?.trimmingCharacters(in: .whitespacesAndNewlines),
            entry.serviceCall.map { "GunnAire Ops time for \($0.customer.name)" },
            "Clocked \(entry.clockIn.formatted(date: .abbreviated, time: .shortened)) - \(entry.clockOut?.formatted(date: .abbreviated, time: .shortened) ?? "")"
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

    private static func qboDateString(_ date: Date) -> String {
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
