import SwiftUI

/// A document-browser host and an embedded export-only host have different
/// save contracts. Keep their instructions tied to the actual host workflow.
enum LoadSightDocumentStorage: Equatable, Sendable {
    case nativeDocument, exportedProject
    var guidance: String {
        switch self {
        case .exportedProject:
            return "Use Project to open or create a project. Choose Export project package or Export portable JSON to save changes before choosing Done."
        case .nativeDocument:
            #if os(iOS)
            return "Project files retain drawing evidence. Save or export your project to keep changes before closing the workspace."
            #else
            return "Open an existing workbench project with File → Open. Changes retain its drawing evidence and save through the native document system."
            #endif
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
