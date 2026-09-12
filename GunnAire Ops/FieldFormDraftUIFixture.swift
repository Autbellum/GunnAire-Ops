#if DEBUG
import Foundation
import SwiftData

@MainActor enum FieldFormDraftUIFixture {
    static let templateID = UUID(uuidString: "F0F00000-0000-4000-8000-000000000201")!
    static let readingID = UUID(uuidString: "F0F00000-0000-4000-8000-000000000202")!
    static let checkID = UUID(uuidString: "F0F00000-0000-4000-8000-000000000203")!

    static func seedIfRequested(in context: ModelContext) throws {
        guard FieldFormDraftWorkflow.fixtureStoreName != nil else { return }
        let existing = try context.fetch(FetchDescriptor<FieldFormTemplate>()).filter { $0.id == templateID }
        if let original = existing.first {
            if ProcessInfo.processInfo.arguments.contains("-uiTestRetireDraftForm") {
                original.isActive = false; try context.save()
            }
            return
        }
        context.insert(FieldFormTemplate(id: templateID, title: "Equipment readings", questions: [
            FieldFormQuestion(id: readingID, label: "Supply temperature °F", kind: .text, required: true),
            FieldFormQuestion(id: checkID, label: "Safety checked", kind: .toggle, required: true)
        ], applicableServiceTypes: [.service], requiresCompletionForCloseout: true))
        try context.save()
    }
}
#endif
