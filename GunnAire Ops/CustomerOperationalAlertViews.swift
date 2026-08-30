import SwiftData
import SwiftUI

struct CustomerOperationalAlertCompactRow: View {
    let alert: CustomerOperationalAlert
    var showsScope = true

    private var tint: Color {
        switch alert.severity {
        case .critical: .red
        case .attention: .orange
        case .information: Color.brandGold
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: alert.kind.systemImage)
                .foregroundStyle(tint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(alert.title)
                        .font(.subheadline.weight(.semibold))
                    if alert.blocksNewScheduling {
                        Text("BOOKING BLOCK")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.red, in: Capsule())
                    }
                }
                if let detail = alert.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if showsScope {
                    Text(alert.scopeDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

struct CustomerOperationalAlertInlineSummary: View {
    let alerts: [CustomerOperationalAlert]
    let accessibilityIdentifier: String

    private var orderedAlerts: [CustomerOperationalAlert] {
        CustomerOperationalAlertPolicy.ordered(alerts)
    }

    private var hasBookingBlock: Bool {
        orderedAlerts.contains(where: \CustomerOperationalAlert.blocksNewScheduling)
    }

    var body: some View {
        if !orderedAlerts.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(orderedAlerts.prefix(3)) { alert in
                        CustomerOperationalAlertCompactRow(alert: alert)
                    }
                    if orderedAlerts.count > 3 {
                        Text("+ \(orderedAlerts.count - 3) more active alert\(orderedAlerts.count - 3 == 1 ? "" : "s") in the customer record")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label(
                    hasBookingBlock ? "Service Restricted" : "Customer & Site Alerts",
                    systemImage: hasBookingBlock ? "hand.raised.fill" : "tag.fill"
                )
                .foregroundStyle(hasBookingBlock ? .red : .orange)
            }
            .accessibilityIdentifier(accessibilityIdentifier)
        }
    }
}

struct CustomerOperationalAlertManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CustomerOperationalAlert.createdAt, order: .reverse) private var alerts: [CustomerOperationalAlert]
    @Query(sort: \CustomerServiceLocation.name, order: .forward) private var serviceLocations: [CustomerServiceLocation]
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]

    let customer: Customer

    @State private var selectedKind: CustomerOperationalAlertKind = .access
    @State private var selectedServiceLocationID: UUID?
    @State private var title = ""
    @State private var detail = ""
    @State private var message: String?
    @State private var alertPendingResolution: CustomerOperationalAlert?

    private var currentEmail: String? { AppIdentity.currentEmail }

    private var customerAlerts: [CustomerOperationalAlert] {
        CustomerOperationalAlertPolicy.allAlerts(customerID: customer.id, in: alerts)
    }

    private var activeAlerts: [CustomerOperationalAlert] {
        customerAlerts.filter(\.isActive)
    }

    private var resolvedAlerts: [CustomerOperationalAlert] {
        customerAlerts.filter { !$0.isActive }
    }

    private var customerLocations: [CustomerServiceLocation] {
        CustomerServiceLocationPolicy.locations(
            for: customer.id,
            in: serviceLocations,
            includeInactive: true
        )
    }

    private var canCreateSelectedKind: Bool {
        AppAccess.canPerformCustomerOperationalAlertAction(
            .create,
            kind: selectedKind,
            email: currentEmail,
            users: users
        )
    }

    private var canCreateAnyAlert: Bool {
        CustomerOperationalAlertKind.allCases.contains { kind in
            AppAccess.canPerformCustomerOperationalAlertAction(
                .create,
                kind: kind,
                email: currentEmail,
                users: users
            )
        }
    }

    private var canAddAlert: Bool {
        canCreateSelectedKind &&
            (!selectedKind.requiresDetailedReason || detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Active Alerts") {
                    if activeAlerts.isEmpty {
                        ContentUnavailableView(
                            "No Active Alerts",
                            systemImage: "checkmark.shield",
                            description: Text("Technicians will see new alerts here and on matching jobs after CloudKit sync.")
                        )
                    } else {
                        ForEach(activeAlerts) { alert in
                            VStack(alignment: .leading, spacing: 8) {
                                CustomerOperationalAlertCompactRow(alert: alert)
                                HStack {
                                    Text("Added \(alert.createdAt.formatted(date: .abbreviated, time: .shortened)) by \(alert.createdByEmail)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    if canResolve(alert) {
                                        Button("Resolve") {
                                            alertPendingResolution = alert
                                        }
                                        .buttonStyle(.bordered)
                                        .accessibilityIdentifier("ResolveOperationalAlert-\(alert.id.uuidString)")
                                    }
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }

                if canCreateAnyAlert {
                    Section("Add Alert") {
                        Picker("Type", selection: $selectedKind) {
                            ForEach(CustomerOperationalAlertKind.allCases) { kind in
                                Label(kind.displayName, systemImage: kind.systemImage).tag(kind)
                            }
                        }

                        Picker("Scope", selection: $selectedServiceLocationID) {
                            Text("All service locations").tag(UUID?.none)
                            ForEach(customerLocations) { location in
                                Text(location.isActive ? location.displayName : "\(location.displayName) — inactive")
                                    .tag(UUID?.some(location.id))
                            }
                        }

                        TextField(selectedKind.defaultTitle, text: $title)
                            .accessibilityIdentifier("OperationalAlertTitle")
                        TextField(
                            selectedKind.requiresDetailedReason ? "Required reason and field instruction" : "Details or field instruction (optional)",
                            text: $detail,
                            axis: .vertical
                        )
                        .lineLimit(2...5)
                        .accessibilityIdentifier("OperationalAlertDetail")

                        if selectedKind == .doNotService && !canCreateSelectedKind {
                            Label("Only an administrator can create or resolve a Do Not Service hold.", systemImage: "lock.shield")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .accessibilityIdentifier("OperationalAlertAdminRequired")
                        }

                        Button("Add Alert") { addAlert() }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)
                            .disabled(!canAddAlert)
                            .accessibilityIdentifier("AddOperationalAlert")
                    }
                }

                if !resolvedAlerts.isEmpty {
                    Section("Resolved History") {
                        DisclosureGroup("\(resolvedAlerts.count) resolved alert\(resolvedAlerts.count == 1 ? "" : "s")") {
                            ForEach(resolvedAlerts) { alert in
                                VStack(alignment: .leading, spacing: 4) {
                                    CustomerOperationalAlertCompactRow(alert: alert)
                                    if let resolvedAt = alert.resolvedAt {
                                        Text("Resolved \(resolvedAt.formatted(date: .abbreviated, time: .shortened)) by \(alert.resolvedByEmail ?? "business account")")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    if let note = alert.resolutionNote {
                                        Text("Resolution: \(note)")
                                            .font(.caption)
                                    }
                                }
                                .padding(.vertical, 3)
                            }
                        }
                    }
                }

                if let message {
                    Section {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("OperationalAlertMessage")
                    }
                }
            }
            .navigationTitle("Operational Alerts")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $alertPendingResolution) { alert in
                OperationalAlertResolutionSheet(alert: alert) { note in
                    resolve(alert, note: note)
                }
            }
        }
    }

    private func canResolve(_ alert: CustomerOperationalAlert) -> Bool {
        AppAccess.canPerformCustomerOperationalAlertAction(
            .resolve,
            kind: alert.kind,
            email: currentEmail,
            users: users
        )
    }

    private func addAlert() {
        guard canCreateSelectedKind else {
            message = "This account is not authorized to create that operational alert."
            return
        }
        let location = selectedServiceLocationID.flatMap { selectedID in
            customerLocations.first { $0.id == selectedID }
        }
        var insertedAlert: CustomerOperationalAlert?
        do {
            let alert = try CustomerOperationalAlertPolicy.makeAlert(
                customerID: customer.id,
                customerName: customer.name,
                serviceLocationID: location?.id,
                serviceLocationName: location?.displayName,
                kind: selectedKind,
                title: title,
                detail: detail,
                actorEmail: currentEmail
            )
            insertedAlert = alert
            modelContext.insert(alert)
            try modelContext.save()
            title = ""
            detail = ""
            message = "Alert added. It will follow this customer through CloudKit and matching job workspaces."
        } catch {
            if let insertedAlert {
                modelContext.delete(insertedAlert)
            }
            message = error.localizedDescription
        }
    }

    private func resolve(_ alert: CustomerOperationalAlert, note: String) -> String? {
        guard canResolve(alert) else {
            return "This account is not authorized to resolve that operational alert."
        }
        let priorResolvedAt = alert.resolvedAt
        let priorResolvedByEmail = alert.resolvedByEmail
        let priorResolutionNote = alert.resolutionNote
        let priorResolutionOperationID = alert.resolutionOperationID
        let priorUpdatedAt = alert.updatedAt
        do {
            try CustomerOperationalAlertPolicy.resolve(
                alert,
                actorEmail: currentEmail,
                note: note
            )
            try modelContext.save()
            alertPendingResolution = nil
            message = "Alert resolved. New bookings will use the updated customer status after CloudKit sync."
            return nil
        } catch {
            alert.resolvedAt = priorResolvedAt
            alert.resolvedByEmail = priorResolvedByEmail
            alert.resolutionNote = priorResolutionNote
            alert.resolutionOperationID = priorResolutionOperationID
            alert.updatedAt = priorUpdatedAt
            return error.localizedDescription
        }
    }
}

private struct OperationalAlertResolutionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let alert: CustomerOperationalAlert
    let onResolve: (String) -> String?

    @State private var note = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Alert") {
                    CustomerOperationalAlertCompactRow(alert: alert)
                }
                Section("Resolution") {
                    TextField(
                        alert.kind.requiresDetailedReason ? "Required resolution" : "Resolution note (optional)",
                        text: $note,
                        axis: .vertical
                    )
                    .lineLimit(2...5)
                    .accessibilityIdentifier("OperationalAlertResolutionNote")
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Resolve Alert")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Resolve") {
                        if let error = onResolve(note) {
                            errorMessage = error
                        } else {
                            dismiss()
                        }
                    }
                    .disabled(alert.kind.requiresDetailedReason && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("ConfirmResolveOperationalAlert")
                }
            }
        }
    }
}
