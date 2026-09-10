import Foundation
import SwiftData
import SwiftUI

/// Staff-safe navigation destinations for a hosted staff projection ModelContainer.
///
/// Destinations are derived from projection record kinds already present in the
/// hosted store — never from owner ModelCodec reconstruction, never from forged
/// empty owner models. Overview is always available once a HostedStore is valid.
enum StaffWorkspaceOperationalNavDestination: String, CaseIterable, Identifiable, Hashable {
    case overview
    case customers
    case scheduleAndJobs
    case estimates
    case invoices
    case payments
    case technicians
    case equipment
    case forms
    case attachments
    case vendors
    case fleet
    case expenses
    case communications
    case catalog

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .customers: return "Customers"
        case .scheduleAndJobs: return "Schedule & Jobs"
        case .estimates: return "Estimates"
        case .invoices: return "Invoices"
        case .payments: return "Payments"
        case .technicians: return "Technicians"
        case .equipment: return "Equipment"
        case .forms: return "Forms"
        case .attachments: return "Attachments"
        case .vendors: return "Vendors"
        case .fleet: return "Fleet"
        case .expenses: return "Expenses"
        case .communications: return "Communications"
        case .catalog: return "Catalog"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .customers: return "person.2"
        case .scheduleAndJobs: return "calendar"
        case .estimates: return "doc.text"
        case .invoices: return "doc.richtext"
        case .payments: return "creditcard"
        case .technicians: return "wrench.and.screwdriver"
        case .equipment: return "cpu"
        case .forms: return "list.clipboard"
        case .attachments: return "paperclip"
        case .vendors: return "building.2"
        case .fleet: return "truck.box"
        case .expenses: return "dollarsign.circle"
        case .communications: return "envelope"
        case .catalog: return "shippingbox"
        }
    }

    /// Projection kinds that surface this destination. Empty for overview.
    var kinds: Set<String> {
        switch self {
        case .overview: return []
        case .customers: return ["customer", "location"]
        case .scheduleAndJobs: return ["job", "task", "taskEvent", "activity", "milestone", "alert", "request"]
        case .estimates: return ["estimate"]
        case .invoices: return ["invoice"]
        case .payments: return ["payment"]
        case .technicians: return ["technician", "user", "availability", "availabilityEvent", "shift", "timeOff", "timeEntry"]
        case .equipment: return ["equipment"]
        case .forms: return ["formTemplate", "formResponse"]
        case .attachments: return ["attachment"]
        case .vendors: return ["vendor", "purchaseOrder"]
        case .fleet: return ["vehicle", "vehicleEvent", "movement"]
        case .expenses: return ["expense"]
        case .communications: return ["communication"]
        case .catalog: return ["item", "agreement"]
        }
    }
}

/// Selection recovery for staff projection nav — mirrors SidebarNavigationPolicy
/// so role/kind coverage changes cannot leave the split view on a dead route.
enum StaffWorkspaceOperationalNavPolicy {
    static func resolvedSelection(
        _ current: StaffWorkspaceOperationalNavDestination?,
        visible: [StaffWorkspaceOperationalNavDestination]
    ) -> StaffWorkspaceOperationalNavDestination? {
        guard !visible.isEmpty else { return nil }
        if let current, visible.contains(current) { return current }
        if visible.contains(.overview) { return .overview }
        return visible.first
    }

    static func destinations(kindsPresent: Set<String>) -> [StaffWorkspaceOperationalNavDestination] {
        var result: [StaffWorkspaceOperationalNavDestination] = [.overview]
        for destination in StaffWorkspaceOperationalNavDestination.allCases where destination != .overview {
            if !destination.kinds.isDisjoint(with: kindsPresent) {
                result.append(destination)
            }
        }
        return result
    }
}

/// Fail-closed presentation gate over an already-hosted staff projection store.
/// Requires host-v1 `state=hosted` + `operationalWorkspaceReady` and matching
/// activated digests. Never unlocks the owner ModelContainer and never calls
/// owner `ModelCodec.make`.
enum StaffWorkspaceOperationalPresentation {
    static func requireHosted(_ hosted: StaffWorkspaceOperationalHostedStore) throws {
        guard hosted.journal.schema == StaffWorkspaceOperationalHostJournal.schema,
              hosted.journal.state == "hosted",
              hosted.journal.operationalWorkspaceReady,
              hosted.activated.journal.selectionID == hosted.journal.selectionID,
              hosted.activated.journal.contentSHA256 == hosted.journal.contentSHA256,
              hosted.activated.journal.sourceSequence == hosted.journal.sourceSequence,
              hosted.activated.journal.recordCount == hosted.journal.recordCount,
              hosted.activated.journal.operationalWorkspaceReady == false,
              hosted.activated.plan.operationalWorkspaceReady == false else {
            throw StaffReplicaDeliveryError.storage
        }
    }

    /// Additive fail-closed gate: hosted digests must also match a bound
    /// identity journal for the signed CloudKit participant account + device.
    static func requireBound(hosted: StaffWorkspaceOperationalHostedStore,
                            identity: StaffWorkspaceOperationalIdentityJournal,
                            account: CompanyCloudKitAccount,
                            deviceFingerprint: String) throws {
        try requireHosted(hosted)
        guard JobBillingAssignmentSnapshot.validConnectionRevision(deviceFingerprint),
              identity.schema == StaffWorkspaceOperationalIdentityJournal.schema,
              identity.state == "bound",
              identity.operationalWorkspaceReady == false,
              identity.planID == hosted.journal.planID,
              identity.scope == hosted.journal.scope,
              identity.selectionID == hosted.journal.selectionID,
              identity.contentSHA256 == hosted.journal.contentSHA256,
              identity.sealedSHA256 == hosted.journal.sealedSHA256,
              identity.sourceSequence == hosted.journal.sourceSequence,
              identity.recordCount == hosted.journal.recordCount,
              identity.participantAccountHash == account.accountHash,
              identity.environment == account.environment,
              identity.deviceFingerprint == deviceFingerprint,
              JobBillingAssignmentSnapshot.validConnectionRevision(identity.participantAccountHash),
              JobBillingAssignmentSnapshot.validConnectionRevision(identity.deviceFingerprint) else {
            throw StaffReplicaDeliveryError.storage
        }
    }

    static func kindsPresent(in hosted: StaffWorkspaceOperationalHostedStore) throws -> Set<String> {
        try requireHosted(hosted)
        let records = try hosted.fetch()
        return Set(records.map(\.kind))
    }

    static func destinations(for hosted: StaffWorkspaceOperationalHostedStore) throws
    -> [StaffWorkspaceOperationalNavDestination] {
        StaffWorkspaceOperationalNavPolicy.destinations(kindsPresent: try kindsPresent(in: hosted))
    }

    static func records(
        in hosted: StaffWorkspaceOperationalHostedStore,
        for destination: StaffWorkspaceOperationalNavDestination
    ) throws -> [StaffWorkspaceOperationalImportRecord] {
        try requireHosted(hosted)
        let all = try hosted.fetch()
        if destination == .overview { return all }
        let allowed = destination.kinds
        return all.filter { allowed.contains($0.kind) }
    }
}

/// Staff UI shell that presents the hosted staff projection ModelContainer.
/// Uses NavigationSplitView (iPad-first) and queries projection rows only —
/// never owner `@Model` types.
struct StaffWorkspaceOperationalHostedWorkspaceView: View {
    let hosted: StaffWorkspaceOperationalHostedStore
    var identity: StaffWorkspaceOperationalIdentityJournal? = nil
    var account: CompanyCloudKitAccount? = nil
    var deviceFingerprint: String? = nil
    @State private var selected: StaffWorkspaceOperationalNavDestination? = .overview
    @State private var destinations: [StaffWorkspaceOperationalNavDestination] = [.overview]
    @State private var loadError: String?
    @State private var boundIdentity: StaffWorkspaceOperationalIdentityJournal?
    @State private var showingFieldUpdates = false

    var body: some View {
        Group {
            if let loadError {
                ContentUnavailableView(
                    "Staff workspace unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
                .accessibilityIdentifier("StaffOperationalHostedUnavailable")
            } else {
                NavigationSplitView {
                    List(destinations, selection: $selected) { destination in
                        Label(destination.title, systemImage: destination.systemImage)
                            .tag(destination)
                            .accessibilityIdentifier("StaffOperationalNav.\(destination.rawValue)")
                    }
                    .navigationTitle("Staff Workspace")
                    .accessibilityIdentifier("StaffOperationalHostedSidebar")
                    .toolbar {
                        if [AppUserRole.admin.rawValue, AppUserRole.dispatcher.rawValue, AppUserRole.fieldTechnician.rawValue].contains(hosted.plan.memberRole) {
                            ToolbarItem(placement: .primaryAction) {
                                Button("Submitted Updates", systemImage: "checkmark.message") { showingFieldUpdates = true }
                                    .accessibilityIdentifier("StaffSubmittedUpdatesButton")
                            }
                        }
                    }
                } detail: {
                    NavigationStack {
                        StaffWorkspaceOperationalHostedDetailView(
                            hosted: hosted,
                            destination: StaffWorkspaceOperationalNavPolicy.resolvedSelection(
                                selected, visible: destinations) ?? .overview,
                            identity: boundIdentity
                        )
                        .accessibilityIdentifier("StaffOperationalHostedDetail")
                    }
                }
            }
        }
        .modelContainer(hosted.container)
        .sheet(isPresented: $showingFieldUpdates) { StaffWorkspaceFieldUpdatesView(hosted: hosted) }
        .task(id: taskIdentity) {
            do {
                if let identity, let account, let deviceFingerprint {
                    try StaffWorkspaceOperationalPresentation.requireBound(
                        hosted: hosted, identity: identity, account: account,
                        deviceFingerprint: deviceFingerprint)
                    boundIdentity = identity
                } else if let identity {
                    // Identity journal present but account/device proof missing → fail closed.
                    throw StaffReplicaDeliveryError.storage
                } else {
                    try StaffWorkspaceOperationalPresentation.requireHosted(hosted)
                    boundIdentity = nil
                }
                let next = try StaffWorkspaceOperationalPresentation.destinations(for: hosted)
                destinations = next
                selected = StaffWorkspaceOperationalNavPolicy.resolvedSelection(selected, visible: next)
                loadError = nil
            } catch {
                loadError = StaffReplicaDeliveryPolicy.safe(error).localizedDescription
                destinations = []
                selected = nil
                boundIdentity = nil
            }
        }
    }

    private var taskIdentity: String {
        var parts = [hosted.journal.contentSHA256, "\(hosted.journal.sourceSequence)"]
        if let identity {
            parts.append(identity.participantAccountHash)
            parts.append(identity.deviceFingerprint)
        }
        if let account {
            parts.append(account.accountHash)
            parts.append(account.environment)
        }
        if let deviceFingerprint {
            parts.append(deviceFingerprint)
        }
        return parts.joined(separator: ":")
    }
}

struct StaffWorkspaceOperationalHostedDetailView: View {
    let hosted: StaffWorkspaceOperationalHostedStore
    let destination: StaffWorkspaceOperationalNavDestination
    var identity: StaffWorkspaceOperationalIdentityJournal? = nil
    @Query(sort: \StaffWorkspaceOperationalProjectionRecord.kind, order: .forward)
    private var rows: [StaffWorkspaceOperationalProjectionRecord]

    private var filtered: [StaffWorkspaceOperationalProjectionRecord] {
        if destination == .overview { return rows }
        let allowed = destination.kinds
        return rows.filter { allowed.contains($0.kind) }
    }

    var body: some View {
        List {
            if destination == .overview, let identity {
                Section {
                    LabeledContent("Environment", value: identity.environment)
                    LabeledContent("Account", value: StaffWorkspaceOperationalDetail.shortRecordID(
                        identity.participantAccountHash))
                    LabeledContent("Device", value: "This device")
                } header: {
                    Text("Signed identity")
                }
                .accessibilityIdentifier("StaffOperationalIdentityBound")
            }

            Section {
                LabeledContent(
                    "Selection",
                    value: StaffWorkspaceOperationalDetail.shortRecordID(hosted.journal.selectionID))
                LabeledContent("Records", value: "\(hosted.journal.recordCount)")
                LabeledContent("Sequence", value: "\(hosted.journal.sourceSequence)")
            } header: {
                Text(destination.title)
            }

            Section("Projection") {
                if filtered.isEmpty {
                    Text("No \(destination.title.lowercased()) records in this staff projection.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filtered, id: \.recordID) { row in
                        let summary = StaffWorkspaceOperationalDetail.summary(for: row)
                        NavigationLink {
                            StaffWorkspaceOperationalRecordDetailView(row: row)
                        } label: {
                            StaffWorkspaceOperationalProjectionRowLabel(summary: summary)
                        }
                        .accessibilityIdentifier("StaffOperationalRow.\(row.kind).\(row.recordID)")
                    }
                }
            }
        }
        .navigationTitle(destination.title)
        .accessibilityIdentifier("StaffOperationalHostedList.\(destination.rawValue)")
    }
}

/// List-row label driven by kind-aware detail-v1 summary (title/subtitle/badges).
struct StaffWorkspaceOperationalProjectionRowLabel: View {
    let summary: StaffWorkspaceOperationalDetail.Summary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(summary.title)
                    .font(.headline)
                Text(summary.kindBadge)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }
            if !summary.subtitle.isEmpty {
                Text(summary.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if summary.hasRestrictedFields {
                Text("Restricted fields present")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }
}

/// Per-record staff projection detail — available scalars + restricted placeholders.
/// Does not decode or display `structuredFieldsJSON` owner extras as scalars.
struct StaffWorkspaceOperationalRecordDetailView: View {
    let row: StaffWorkspaceOperationalProjectionRecord

    private var detail: StaffWorkspaceOperationalDetail.RecordDetail {
        StaffWorkspaceOperationalDetail.detail(for: row)
    }

    var body: some View {
        let detail = self.detail
        List {
            Section {
                LabeledContent("Kind", value: detail.summary.kindBadge)
                LabeledContent(
                    "Record ID",
                    value: StaffWorkspaceOperationalDetail.shortRecordID(detail.recordID))
                LabeledContent("Revision", value: "\(detail.revision)")
                LabeledContent("Body", value: detail.bodyKind)
            } header: {
                Text(detail.summary.title)
            }

            Section("Fields") {
                if detail.fields.isEmpty {
                    Text("No displayable fields in this projection row.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(detail.fields) { field in
                        LabeledContent(field.label) {
                            Text(field.displayValue)
                                .foregroundStyle(field.isRestricted ? .orange : .primary)
                                .multilineTextAlignment(.trailing)
                        }
                        .accessibilityIdentifier(
                            "StaffOperationalRecordDetail.field.\(field.key)")
                    }
                }
            }
        }
        .navigationTitle(detail.summary.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier(
            "StaffOperationalRecordDetail.\(detail.kind).\(detail.recordID)")
    }
}
