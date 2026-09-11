import Foundation
import Combine

/// Navigation carries original compound IDs, never SwiftData objects or fields.
struct StaffWorkspaceRecordRoute: Hashable {
    let kind: String
    let id: String

    func exists(in hosted: StaffWorkspaceOperationalHostedStore) -> Bool {
        CloudKitStaffSetupPolicy.canonicalID(id) && hosted.plan.record(kind: kind, id: id) != nil
    }

    func canEdit(_ field: String, in hosted: StaffWorkspaceOperationalHostedStore) -> Bool {
        guard [AppUserRole.admin.rawValue, AppUserRole.dispatcher.rawValue, AppUserRole.fieldTechnician.rawValue].contains(hosted.plan.memberRole),
              exists(in: hosted), StaffWorkspaceOperationalCommandPolicy.isOperationsField(kind: kind, field: field),
              let schema = StaffWorkspaceModelCatalog.all.first(where: { $0.kind == kind })?.fieldSchema[field],
              schema.reference == nil, schema.type != .identifier,
              let record = hosted.plan.record(kind: kind, id: id),
              case .operational(let partition) = record.body else { return false }
        return partition.fields[field] != nil && partition.unavailableFields[field] == nil && partition.structuredFields[field] == nil
    }
}

struct StaffWorkspaceNavigationAuthority: Equatable {
    let stamp: CloudKitStaffSetupStamp
    let scope: CloudKitStaffSetupScope
    let plan: CloudKitStaffSharePlan
    let device: String
}

struct StaffWorkspaceNavigationIdentity: Equatable {
    let authority: StaffWorkspaceNavigationAuthority
    let content: String
}

extension StaffReplicaPresentation {
    var navigationIdentity: StaffWorkspaceNavigationIdentity {
        .init(authority: .init(stamp: context.stamp, scope: context.scope, plan: plan, device: deviceFingerprint),
              content: viewIdentity)
    }
}

struct StaffWorkspaceEditorSession: Identifiable {
    let id = UUID()
    let route: StaffWorkspaceRecordRoute
    let field: String
    let title: String
    let controller: StaffWorkspaceFieldEditorController
}

/// Per-window state lives above the snapshot's ModelContainer/view identity.
/// The sheet keeps the same controller; its live dependencies resolve current
/// authorized content, while the controller retains the original draft version.
@MainActor final class StaffWorkspaceNavigationController: ObservableObject {
    @Published var selected: StaffWorkspaceOperationalNavDestination? = .overview {
        didSet { if selected != oldValue { path = []; notice = nil; searchText = "" } }
    }
    @Published var searchText = ""
    @Published var path: [StaffWorkspaceRecordRoute] = []
    @Published var editor: StaffWorkspaceEditorSession?
    @Published private(set) var notice: String?
    private var authority: StaffWorkspaceNavigationAuthority?
    nonisolated deinit {}

    func update(_ presentation: StaffReplicaPresentation?) {
        guard let presentation else { reset(); return }
        let key = presentation.navigationIdentity.authority
        if authority != key { reset(); authority = key }
        let hosted = presentation.workspace.hosted
        let visible = StaffWorkspaceOperationalNavPolicy.destinations(kindsPresent: Set(hosted.plan.records.map(\.kind)))
        selected = StaffWorkspaceOperationalNavPolicy.resolvedSelection(selected, visible: visible)
        let retained = Array(path.prefix { $0.exists(in: hosted) })
        if retained != path {
            path = retained
            notice = "That record is no longer in your shared workspace. Previously saved drafts remain on this device."
        }
        if let editor {
            if editor.route.canEdit(editor.field, in: hosted) { editor.controller.checkLifetime(forceRefresh: true) }
            else {
                editor.controller.invalidate(); self.editor = nil
                notice = "This field is no longer available. Previously saved drafts remain on this device."
            }
        }
    }

    func beginEditing(hosted: StaffWorkspaceOperationalHostedStore, row: StaffWorkspaceOperationalProjectionRecord,
                      field: String, receive: StaffReplicaReceiveController? = nil,
                      coordinator: StaffWorkspaceContentCoordinator? = nil) {
        guard editor == nil else { return } // Never replace another open editor's input.
        let route = StaffWorkspaceRecordRoute(kind: row.kind, id: row.recordID)
        guard route.canEdit(field, in: hosted) else { return }
        let controller = StaffWorkspaceFieldEditorController(dependencies: .live(hosted: hosted,
            kind: row.kind, recordID: row.recordID, revision: row.revision, field: field,
            receive: receive, coordinator: coordinator))
        controller.open()
        guard controller.snapshot != nil else {
            notice = "Refresh the shared workspace before opening this field."; return
        }
        notice = nil
        editor = .init(route: route, field: field, title: StaffWorkspaceOperationalDetail.summary(for: row).title,
                       controller: controller)
    }

    func reset() {
        editor?.controller.invalidate(); editor = nil
        path = []; selected = .overview; searchText = ""; notice = nil; authority = nil
    }
}
