import SwiftUI

/// Native documents, manual export and local recovery have different
/// save contracts. Keep their instructions tied to the actual host workflow.
enum LoadSightDocumentStorage: Equatable, Sendable {
    case nativeDocument, exportedProject, recoverableProject
    var guidance: String {
        switch self {
        case .exportedProject:
            return "Use Project to open or create a project. Choose Export project package or Export portable JSON to save changes before choosing Done."
        case .recoverableProject:
            return "Check the local-save status. For unexported edits, Done offers Keep draft and close. Use Project → Export project package or Export portable JSON to keep a portable copy."
        case .nativeDocument:
            #if os(iOS)
            return "Project files retain drawing evidence. Save or export your project to keep changes before closing the workspace."
            #else
            return "Open an existing workbench project with File → Open. Changes retain its drawing evidence and save through the native document system."
            #endif
        }
    }
    var openingGuidance: String {
        switch self {
        case .recoverableProject:
            return "Open a LoadSight project or create a new one. Check the local-save status for recovery on this device; export a project copy for a portable record. Ops billing and approvals remain separate."
        case .exportedProject:
            return "Open a LoadSight project or create a new one. Local recovery is unavailable; export your changes to retain them. Ops billing and approvals remain separate."
        case .nativeDocument: return guidance
        }
    }
    var linkRetentionGuidance: String {
        switch self {
        case .recoverableProject: return "Check the local-save status for recovery on this device. Export the project for a portable copy of this link."
        case .exportedProject: return "Export the project to retain the link."
        case .nativeDocument: return "Save the project to retain the link with its document."
        }
    }
}

private struct LoadSightDocumentStorageKey: EnvironmentKey {
    static let defaultValue = LoadSightDocumentStorage.nativeDocument
}

extension EnvironmentValues {
    var loadSightDocumentStorage: LoadSightDocumentStorage {
        get { self[LoadSightDocumentStorageKey.self] }
        set { self[LoadSightDocumentStorageKey.self] = newValue }
    }
}
