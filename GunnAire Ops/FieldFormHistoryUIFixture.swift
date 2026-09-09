#if DEBUG
import Foundation
import SwiftData

/// Fixture-only records behind the existing unsigned, isolated test-store gate.
/// Uses normal saved models and normal job navigation; no alternate review view,
/// provider transport, production store or authorization grant is installed.
@MainActor enum FieldFormHistoryUIFixture {
    static let originalID = UUID(uuidString: "F0F00000-0000-4000-8000-000000000001")!
    static let revisionID = UUID(uuidString: "F0F00000-0000-4000-8000-000000000002")!
    static let validID = UUID(uuidString: "F0F00000-0000-4000-8000-000000000003")!
    static let invalidID = UUID(uuidString: "F0F00000-0000-4000-8000-000000000004")!
    static let otherID = UUID(uuidString: "F0F00000-0000-4000-8000-000000000005")!

    static func seedIfRequested(in context: ModelContext) throws {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-uiTestFieldFormHistory"),
              arguments.contains("-uiTestAuthenticatedAdmin"),
              arguments.contains("-uiTestSeedCollectibleJob"),
              GunnAireCloudKit.isolatedUITestStoreName(arguments: arguments) != nil,
              GunnAireCloudKit.usesTestDatabase else { return }
        let jobID = UUID(uuidString: "A1000000-0000-4000-8000-000000000002")!
        let otherJobID = UUID(uuidString: "A1000000-0000-4000-8000-000000000012")!
        let jobs = try context.fetch(FetchDescriptor<ServiceCall>())
        guard jobs.contains(where: { $0.id == jobID }), jobs.contains(where: { $0.id == otherJobID }) else {
            throw StaffWorkspaceModelError.incomplete
        }
        let existing = try context.fetch(FetchDescriptor<FieldFormResponse>())
        guard existing.allSatisfy({ ![validID, invalidID, otherID].contains($0.id) }) else { return }
        let date = Date(timeIntervalSinceReferenceDate: 810_123_456)
        let question = FieldFormQuestion(label: "Original drain condition", kind: .choice, required: true,
                                         choices: ["Pass", "Needs cleaning"])
        let original = FieldFormTemplate(id: originalID, title: "Equipment condition", questions: [question],
                                         applicableServiceTypes: [.service], isActive: false, createdAt: date)
        let revision = FieldFormTemplate(id: revisionID, title: original.title,
            questions: [FieldFormQuestion(label: "New coil inspection", kind: .toggle, required: true)],
            applicableServiceTypes: [.service], createdAt: date.addingTimeInterval(100))
        let valid = FieldFormResponse(id: validID, serviceCallID: jobID, template: original,
            answers: [question.id: "Pass"], completedAt: date)
        let invalid = FieldFormResponse(id: invalidID, serviceCallID: jobID, template: original,
            answers: [:], completedAt: date.addingTimeInterval(200))
        invalid.answersJSON = #"{"version":99,"rows":[]}"#
        let otherTemplate = FieldFormTemplate(title: "Another visit's private form", questions: [question],
                                              applicableServiceTypes: [.maintenance])
        let other = FieldFormResponse(id: otherID, serviceCallID: otherJobID, template: otherTemplate,
            answers: [question.id: "Needs cleaning"], completedAt: date.addingTimeInterval(300))
        context.insert(original); context.insert(revision); context.insert(otherTemplate)
        context.insert(valid); context.insert(invalid); context.insert(other)
        try context.save()
    }
}
#endif
