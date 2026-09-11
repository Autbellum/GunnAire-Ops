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
    let identity: StaffWorkspaceOperationalIdentityJournal
    let account: CompanyCloudKitAccount
    let deviceFingerprint: String
    @ObservedObject var navigation: StaffWorkspaceNavigationController
    @State private var showingFieldUpdates = false
    private var destinations: [StaffWorkspaceOperationalNavDestination] {
        StaffWorkspaceOperationalNavPolicy.destinations(kindsPresent: Set(hosted.plan.records.map(\.kind)))
    }

    var body: some View {
        Group {
            if let loadError = validationError {
                ContentUnavailableView(
                    "Staff workspace unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
                .accessibilityIdentifier("StaffOperationalHostedUnavailable")
            } else {
                NavigationSplitView {
                    List(destinations, selection: $navigation.selected) { destination in
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
                    NavigationStack(path: $navigation.path) {
                        StaffWorkspaceOperationalHostedDetailView(
                            hosted: hosted,
                            destination: StaffWorkspaceOperationalNavPolicy.resolvedSelection(
                                navigation.selected, visible: destinations) ?? .overview,
                            identity: identity,
                            navigation: navigation
                        )
                        .id(contentIdentity)
                        .accessibilityIdentifier("StaffOperationalHostedDetail")
                        .navigationDestination(for: StaffWorkspaceRecordRoute.self) { route in
                            StaffWorkspaceResolvedRecordView(route: route, hosted: hosted, navigation: navigation)
                                .id(contentIdentity + ":" + route.kind + ":" + route.id)
                        }
                    }
                }
            }
        }
        .modelContainer(hosted.container)
        .sheet(isPresented: $showingFieldUpdates) { StaffWorkspaceFieldUpdatesView(hosted: hosted) }
    }

    private var contentIdentity: String { hosted.journal.selectionID + ":" + hosted.journal.contentSHA256 }

    private var validationError: String? {
        do {
            try StaffWorkspaceOperationalPresentation.requireBound(hosted: hosted, identity: identity,
                account: account, deviceFingerprint: deviceFingerprint)
            return nil
        } catch { return StaffReplicaDeliveryPolicy.safe(error).localizedDescription }
    }
}

struct StaffWorkspaceOperationalHostedDetailView: View {
    let hosted: StaffWorkspaceOperationalHostedStore
    let destination: StaffWorkspaceOperationalNavDestination
    var identity: StaffWorkspaceOperationalIdentityJournal? = nil
    @ObservedObject var navigation: StaffWorkspaceNavigationController
    @Query(sort: \StaffWorkspaceOperationalProjectionRecord.kind, order: .forward)
    private var rows: [StaffWorkspaceOperationalProjectionRecord]
    private var searchText: String { navigation.searchText }

    private var filtered: [StaffWorkspaceOperationalProjectionRecord] {
        if destination == .overview { return rows }
        let allowed = destination.kinds
        return rows.filter { allowed.contains($0.kind) }
    }

    var body: some View {
        let billing = StaffWorkspaceBillingQueue.summaries(hosted.plan.records)
        let visible = filtered.filter { row in
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return true }
            if let summary = billing[row.navigationRoute] { return summary.searchText.localizedStandardContains(query) }
            let summary = StaffWorkspaceOperationalDetail.summary(for: row)
            return (summary.title + " " + summary.subtitle).localizedStandardContains(query)
        }
        List {
            if let notice = navigation.notice {
                Section { Text(notice).font(.callout).foregroundStyle(.secondary) }
            }
            if destination == .overview, let identity {
                Section {
                    LabeledContent("Workspace", value: identity.environment == "production" ? "Live business" : "Test workspace")
                    Label("Company account verified", systemImage: "person.crop.circle.badge.checkmark")
                } header: {
                    Text("Company access")
                }
                .accessibilityIdentifier("StaffOperationalIdentityBound")
            }

            Section {
                Text("\(visible.count) shared records available")
            } header: {
                Text(destination.title)
            }

            Section("Records") {
                if visible.isEmpty {
                    Text(searchText.isEmpty ? "No \(destination.title.lowercased()) records in this shared workspace." : "No matching records. Try another search.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(visible, id: \.navigationRoute) { row in
                        let summary = StaffWorkspaceOperationalDetail.summary(for: row)
                        NavigationLink(value: row.navigationRoute) {
                            if let document = billing[row.navigationRoute] {
                                StaffWorkspaceBillingQueueRow(summary: document)
                            } else { StaffWorkspaceOperationalProjectionRowLabel(summary: summary) }
                        }
                        .accessibilityIdentifier("StaffOperationalRow.\(row.kind).\(row.recordID)")
                    }
                }
            }
        }
        .navigationTitle(destination.title)
        .searchable(text: $navigation.searchText, prompt: "Search " + destination.title.lowercased())
        .accessibilityIdentifier("StaffOperationalHostedList.\(destination.rawValue)")
    }
}

extension StaffWorkspaceOperationalProjectionRecord {
    var navigationRoute: StaffWorkspaceRecordRoute { .init(kind: kind, id: recordID) }
}

/// Resolve an ID inside the current verified container, never retain a row from
/// an older snapshot. A missing or ambiguous route cannot open an editor.
struct StaffWorkspaceResolvedRecordView: View {
    let hosted: StaffWorkspaceOperationalHostedStore
    @ObservedObject var navigation: StaffWorkspaceNavigationController
    @Query private var matches: [StaffWorkspaceOperationalProjectionRecord]

    init(route: StaffWorkspaceRecordRoute, hosted: StaffWorkspaceOperationalHostedStore,
         navigation: StaffWorkspaceNavigationController) {
        self.hosted = hosted; self.navigation = navigation
        let kind = route.kind, recordID = route.id
        _matches = Query(filter: #Predicate<StaffWorkspaceOperationalProjectionRecord> {
            $0.kind == kind && $0.recordID == recordID
        })
    }

    var body: some View {
        if matches.count == 1, let row = matches.first {
            if ["invoice", "estimate"].contains(row.kind) {
                StaffWorkspaceBillingDetailView(hosted: hosted, route: row.navigationRoute)
            } else {
                StaffWorkspaceOperationalRecordDetailView(row: row, hosted: hosted, onEdit: { row, field in
                    navigation.beginEditing(hosted: hosted, row: row, field: field)
                })
            }
        } else {
            ContentUnavailableView("Record unavailable", systemImage: "doc.questionmark",
                description: Text("Return to the list to choose a record from this shared workspace."))
        }
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
    var hosted: StaffWorkspaceOperationalHostedStore? = nil
    var onEdit: ((StaffWorkspaceOperationalProjectionRecord, String) -> Void)? = nil

    private var detail: StaffWorkspaceOperationalDetail.RecordDetail {
        StaffWorkspaceOperationalDetail.detail(for: row)
    }

    var body: some View {
        let detail = self.detail
        List {
            Section {
                LabeledContent("Kind", value: detail.summary.kindBadge)
            } header: {
                Text(detail.summary.title)
            }

            Section("Fields") {
                if detail.fields.isEmpty {
                    Text("No displayable fields in this projection row.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(detail.fields) { field in
                        if canEdit(field) {
                            Button { onEdit?(row, field.key) } label: {
                                LabeledContent(field.label) {
                                    HStack {
                                        Text(field.displayValue).multilineTextAlignment(.trailing)
                                        Image(systemName: "pencil").accessibilityHidden(true)
                                    }
                                }
                            }
                            .accessibilityLabel("Edit " + field.label)
                            .accessibilityIdentifier("StaffOperationalEdit." + field.key)
                        } else {
                            LabeledContent(field.label) {
                                Text(field.displayValue)
                                    .foregroundStyle(field.isRestricted ? .orange : .primary)
                                    .multilineTextAlignment(.trailing)
                            }
                            .accessibilityIdentifier("StaffOperationalRecordDetail.field.\(field.key)")
                        }
                    }
                }
            }
        }
        .navigationTitle(detail.summary.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier(
            "StaffOperationalRecordDetail.\(detail.kind).\(detail.recordID)")
    }
    private func canEdit(_ field: StaffWorkspaceOperationalDetail.FieldRow) -> Bool {
        guard onEdit != nil, let hosted, !field.isRestricted,
              [AppUserRole.admin.rawValue, AppUserRole.dispatcher.rawValue, AppUserRole.fieldTechnician.rawValue].contains(hosted.plan.memberRole),
              StaffWorkspaceOperationalCommandPolicy.isOperationsField(kind: row.kind, field: field.key),
              let schema = StaffWorkspaceModelCatalog.all.first(where: { $0.kind == row.kind })?.fieldSchema[field.key] else { return false }
        return schema.reference == nil && schema.type != .identifier
    }
}
