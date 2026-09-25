import SwiftUI
import HVACCore
import HVACUI

@main
struct HVACDesignSuiteApp: App {
    var body: some Scene {
        // A DocumentGroup rather than a WindowGroup: a load calculation is a job that has
        // to be saved, reopened and handed to someone, and it brings Save, Save As,
        // autosave, versions, Open Recent and the close-without-saving prompt for free.
        DocumentGroup(newDocument: HVACProjectDocument()) { file in
            ContentView(project: file.$document.project)
        }
        .defaultSize(width: 1400, height: 880)
        .commands {
            ReportExportCommands()
            CommandGroup(replacing: .help) {
                Link("ACCA Manual J / S / T / D",
                     destination: URL(string: "https://www.acca.org/standards/technical-manuals")!)
            }
        }
    }
}
