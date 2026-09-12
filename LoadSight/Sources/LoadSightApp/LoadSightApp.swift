import SwiftUI
import LoadSightUI

@main
struct LoadSightApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: LoadSightDocument()) { file in
            LoadSightWorkspaceView(document: file.$document)
        }
    }
}
