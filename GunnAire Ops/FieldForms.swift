import Foundation
import SwiftData
import SwiftUI

nonisolated enum FieldFormQuestionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case toggle
    case text
    case choice

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .toggle: "Confirmation"
        case .text: "Text / reading"
        case .choice: "Choice"
        }
    }

    var systemImage: String {
        switch self {
        case .toggle: "checkmark.square"
        case .text: "text.cursor"
        case .choice: "list.bullet"
        }
    }
}

nonisolated struct FieldFormQuestion: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var label: String
    var kind: FieldFormQuestionKind
    var required: Bool = false
    var choices: [String] = []
}

nonisolated struct FieldFormAnswerRow: Codable, Identifiable, Equatable, Sendable {
    let questionID: UUID
    let label: String
    let kind: FieldFormQuestionKind
    let required: Bool
    let answer: String

    var id: UUID { questionID }

    var displayAnswer: String {
        switch kind {
        case .toggle:
            switch answer {
            case "true": return "Yes"
            case "false": return "No"
            case "": return "Not answered"
            default: return "Needs review"
            }
        case .text, .choice:
            let value = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? "Not answered" : value
        }
    }
}

enum FieldFormCompletionPolicy {
    static func validationIssue(
        questions: [FieldFormQuestion],
        answers: [UUID: String]
    ) -> String? {
        guard !questions.isEmpty, Set(questions.map(\.id)).count == questions.count else {
            return "This form needs review before it can be completed. Ask the office to revise it."
        }
        guard Set(answers.keys).isSubset(of: Set(questions.map(\.id))) else {
            return "Some answers do not belong to this form. Reopen the original form before saving."
        }
        for question in questions {
            let answer = answers[question.id] ?? ""
            if question.kind == .toggle, !["", "true", "false"].contains(answer) {
                return "Review the confirmation for “\(question.label)” before saving."
            }
            if question.kind == .choice, !answer.isEmpty, !question.choices.contains(answer) {
                return "Choose a listed answer for “\(question.label)” before saving."
            }
        }
        let missing = questions.compactMap { question -> String? in
            guard question.required else { return nil }
            let answer = answers[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            switch question.kind {
            case .toggle:
                return answer == "true" ? nil : question.label
            case .text, .choice:
                return answer.isEmpty ? question.label : nil
            }
        }
        guard !missing.isEmpty else { return nil }
        if missing.count == 1 {
            return "Complete the required field “\(missing[0])” before saving."
        }
        return "Complete all \(missing.count) required fields before saving."
    }

    static func answerRows(
        questions: [FieldFormQuestion],
        answers: [UUID: String]
    ) -> [FieldFormAnswerRow] {
        questions.map { question in
            FieldFormAnswerRow(
                questionID: question.id,
                label: question.label,
                kind: question.kind,
                required: question.required,
                answer: answers[question.id] ?? ""
            )
        }
    }
}

enum FieldFormTemplatePolicy {
    static func validationIssue(title: String, questions: [FieldFormQuestion]) -> String? {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Enter a form title."
        }
        guard !questions.isEmpty else {
            return "Add at least one field."
        }
        guard Set(questions.map(\.id)).count == questions.count else {
            return "Each field needs its own identity. Remove the duplicate field and add it again."
        }
        guard questions.allSatisfy({ !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return "Every field needs a label."
        }
        for question in questions where question.kind == .choice {
            let choices = normalizedChoices(question.choices)
            guard choices.count >= 2 else {
                return "“\(question.label)” needs at least two distinct choices."
            }
        }
        return nil
    }

    static func normalizedChoices(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let key = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(key).inserted else { return nil }
            return trimmed
        }
    }
}

nonisolated private struct FieldFormAssignmentEnvelope: Codable, Sendable {
    static let currentVersion = 1

    let version: Int
    let serviceTypes: [String]
    let requiredForCloseout: Bool
}

@Model
final class FieldFormTemplate {
    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()
    var title: String = ""
    var questionsJSON: String = "[]"
    var applicableServiceTypesJSON: String?
    var isActive: Bool = true
    var createdAt: Date = Date()

    init(
        id: UUID = UUID(),
        title: String,
        questions: [FieldFormQuestion],
        applicableServiceTypes: Set<ServiceCallType> = [],
        requiresCompletionForCloseout: Bool = false,
        isActive: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.questionsJSON = Self.encode(questions) ?? "[]"
        self.applicableServiceTypesJSON = Self.assignmentJSON(
            serviceTypes: applicableServiceTypes,
            requiredForCloseout: requiresCompletionForCloseout
        )
        self.isActive = isActive
        self.createdAt = createdAt
    }

    var questions: [FieldFormQuestion] {
        (try? FieldFormPayload.questions(questionsJSON)) ?? []
    }

    var applicableServiceTypes: Set<ServiceCallType> {
        (try? FieldFormPayload.assignment(applicableServiceTypesJSON).serviceTypes) ?? []
    }

    var requiresCompletionForCloseout: Bool {
        (try? FieldFormPayload.assignment(applicableServiceTypesJSON).required) ?? false
    }

    var hasVersionedAssignment: Bool {
        (try? FieldFormPayload.assignment(applicableServiceTypesJSON).isLegacy) == false
    }

    var dataReviewIssue: String? {
        guard (try? FieldFormPayload.assignment(applicableServiceTypesJSON)) != nil,
              let decoded = try? FieldFormPayload.questions(questionsJSON),
              FieldFormTemplatePolicy.validationIssue(title: title, questions: decoded) == nil else {
            return "This form needs office review. Its original setup has been kept; revise it before use."
        }
        return nil
    }

    func applies(to type: ServiceCallType) -> Bool {
        guard let assignment = try? FieldFormPayload.assignment(applicableServiceTypesJSON) else { return false }
        let types = assignment.serviceTypes
        return types.isEmpty || types.contains(type)
    }

    func isListed(for type: ServiceCallType) -> Bool {
        // Keep an unreadable assignment reachable for review, not silently
        // hidden behind an empty "no forms" state.
        applies(to: type) || (try? FieldFormPayload.assignment(applicableServiceTypesJSON)) == nil
    }

    func closeoutRequirementApplies(to type: ServiceCallType) -> Bool {
        guard let assignment = try? FieldFormPayload.assignment(applicableServiceTypesJSON) else { return true }
        return assignment.required && (assignment.serviceTypes.isEmpty || assignment.serviceTypes.contains(type))
    }

    var scopeSummary: String {
        guard dataReviewIssue == nil else { return "Setup needs review" }
        let types = applicableServiceTypes
        guard !types.isEmpty else { return "All job types" }
        return ServiceCallType.allCases
            .filter(types.contains)
            .map(\.displayName)
            .joined(separator: ", ")
    }

    func makeRevision(
        title: String,
        questions: [FieldFormQuestion],
        applicableServiceTypes: Set<ServiceCallType>
    ) -> FieldFormTemplate {
        makeRevision(
            title: title,
            questions: questions,
            applicableServiceTypes: applicableServiceTypes,
            requiresCompletionForCloseout: requiresCompletionForCloseout
        )
    }

    func makeRevision(
        title: String,
        questions: [FieldFormQuestion],
        applicableServiceTypes: Set<ServiceCallType>,
        requiresCompletionForCloseout: Bool
    ) -> FieldFormTemplate {
        isActive = false
        return FieldFormTemplate(
            title: title,
            questions: questions,
            applicableServiceTypes: applicableServiceTypes,
            requiresCompletionForCloseout: requiresCompletionForCloseout
        )
    }

    func updateAssignment(
        serviceTypes: Set<ServiceCallType>,
        requiredForCloseout: Bool
    ) {
        applicableServiceTypesJSON = Self.assignmentJSON(
            serviceTypes: serviceTypes,
            requiredForCloseout: requiredForCloseout
        )
    }

    static func ensureStarterTemplates(in modelContext: ModelContext) {
        let existing = (try? modelContext.fetch(FetchDescriptor<FieldFormTemplate>())) ?? []
        let operationalHVACTypes: Set<ServiceCallType> = [.service, .repair, .replacement, .maintenance, .install]
        let starters = [FieldFormTemplate(
            title: "HVAC Safety Check",
            questions: [
                FieldFormQuestion(label: "Electrical disconnect inspected", kind: .toggle, required: true),
                FieldFormQuestion(label: "Combustion or refrigerant concern observed", kind: .choice, required: true, choices: ["No", "Yes — documented in findings"]),
                FieldFormQuestion(label: "Safety notes", kind: .text)
            ],
            applicableServiceTypes: operationalHVACTypes,
            requiresCompletionForCloseout: true
        ), FieldFormTemplate(
            title: "Service Diagnostic",
            questions: [
                FieldFormQuestion(label: "Customer concern verified", kind: .toggle, required: true),
                FieldFormQuestion(label: "Diagnostic findings documented", kind: .toggle, required: true),
                FieldFormQuestion(label: "Recommended repair or next step reviewed", kind: .toggle, required: true),
                FieldFormQuestion(label: "Diagnostic notes", kind: .text)
            ],
            applicableServiceTypes: [.service],
            requiresCompletionForCloseout: true
        ), FieldFormTemplate(
            title: "Repair Completion",
            questions: [
                FieldFormQuestion(label: "Repaired component or assembly", kind: .text, required: true),
                FieldFormQuestion(label: "Repair and installed parts documented", kind: .toggle, required: true),
                FieldFormQuestion(label: "Final system operation verified", kind: .toggle, required: true),
                FieldFormQuestion(label: "Repair classification", kind: .choice, required: true, choices: ["Standard repair", "Warranty — linked in job", "Callback — linked in job"]),
                FieldFormQuestion(label: "Repair notes", kind: .text)
            ],
            applicableServiceTypes: [.repair],
            requiresCompletionForCloseout: true
        ), FieldFormTemplate(
            title: "Replacement Commissioning",
            questions: [
                FieldFormQuestion(label: "Replacement model and serial verified", kind: .toggle, required: true),
                FieldFormQuestion(label: "Removed equipment disposition", kind: .choice, required: true, choices: ["Removed / recycled", "Left with customer", "Not applicable"]),
                FieldFormQuestion(label: "Startup readings and commissioning completed", kind: .toggle, required: true),
                FieldFormQuestion(label: "Safety and permit / inspection status reviewed", kind: .toggle, required: true),
                FieldFormQuestion(label: "Customer orientation and warranty registration reviewed", kind: .toggle, required: true),
                FieldFormQuestion(label: "Replacement notes", kind: .text)
            ],
            applicableServiceTypes: [.replacement],
            requiresCompletionForCloseout: true
        ), FieldFormTemplate(
            title: "Install Start-Up",
            questions: [
                FieldFormQuestion(label: "Model and serial verified", kind: .toggle, required: true),
                FieldFormQuestion(label: "System operation confirmed", kind: .toggle, required: true),
                FieldFormQuestion(label: "Customer orientation completed", kind: .toggle, required: true),
                FieldFormQuestion(label: "Start-up notes", kind: .text)
            ],
            applicableServiceTypes: [.install],
            requiresCompletionForCloseout: true
        )]
        let existingByTitle = Dictionary(grouping: existing, by: { normalizedStarterTitle($0.title) })
        for starter in starters {
            let key = normalizedStarterTitle(starter.title)
            if let installed = existingByTitle[key]?.sorted(by: { $0.createdAt > $1.createdAt }).first {
                // Upgrade only the legacy array payload. Once an administrator
                // saves a versioned assignment, startup never overwrites it.
                if (try? FieldFormPayload.assignment(installed.applicableServiceTypesJSON).isLegacy) == true {
                    installed.updateAssignment(
                        serviceTypes: starter.applicableServiceTypes,
                        requiredForCloseout: true
                    )
                }
            } else {
                modelContext.insert(starter)
            }
        }
    }

    private static func normalizedStarterTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func assignmentJSON(
        serviceTypes: Set<ServiceCallType>,
        requiredForCloseout: Bool
    ) -> String? {
        let orderedTypes = ServiceCallType.allCases
            .filter(serviceTypes.contains)
            .map(\.rawValue)
        return encode(FieldFormAssignmentEnvelope(
            version: FieldFormAssignmentEnvelope.currentVersion,
            serviceTypes: orderedTypes,
            requiredForCloseout: requiredForCloseout
        ))
    }

    private static func encode<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

}

@Model
final class FieldFormResponse {
    @Attribute(.preserveValueOnDeletion) var id: UUID = UUID()
    var serviceCallID: UUID = UUID()
    var templateID: UUID = UUID()
    var templateTitle: String = ""
    var answersJSON: String = "{}"
    var completedByEmail: String?
    var completedAt: Date = Date()

    init(id: UUID = UUID(), serviceCallID: UUID, template: FieldFormTemplate, answers: [UUID: String], completedByEmail: String? = nil, completedAt: Date = Date()) {
        self.id = id
        self.serviceCallID = serviceCallID
        self.templateID = template.id
        self.templateTitle = template.title
        let snapshot = FieldFormPayload.Snapshot(
            version: 2,
            rows: FieldFormCompletionPolicy.answerRows(questions: template.questions, answers: answers),
            questions: template.questions
        )
        let ids = Set(template.questions.map(\.id))
        self.answersJSON = ids.isSuperset(of: answers.keys)
            ? (Self.encode(snapshot) ?? Self.encode(answers) ?? "{}")
            : (Self.encode(answers) ?? "{}")
        self.completedByEmail = completedByEmail
        self.completedAt = completedAt
    }

    var answers: [UUID: String] {
        (try? FieldFormPayload.response(answersJSON).answers) ?? [:]
    }

    var snapshotAnswerRows: [FieldFormAnswerRow] {
        guard case .snapshot(let snapshot)? = try? FieldFormPayload.response(answersJSON) else { return [] }
        return snapshot.rows
    }

    func answerRows(resolving template: FieldFormTemplate?) -> [FieldFormAnswerRow] {
        guard let payload = try? FieldFormPayload.response(answersJSON) else { return [] }
        if case .snapshot(let snapshot) = payload { return snapshot.rows }
        let legacyAnswers = payload.answers
        if let template, template.id == templateID,
           (try? FieldFormPayload.validate(payload, against: template.questions)) != nil {
            return FieldFormCompletionPolicy.answerRows(
                questions: template.questions,
                answers: legacyAnswers
            )
        }
        return legacyAnswers
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .enumerated()
            .map { index, entry in
                FieldFormAnswerRow(
                    questionID: entry.key,
                    label: "Recorded field \(index + 1)",
                    kind: .text,
                    required: false,
                    answer: entry.value
                )
            }
    }

    /// Versioned snapshots are immutable evidence. Legacy answers need their
    /// exact original template, never a same-title revision's questions.
    func completionReviewIssue(resolving template: FieldFormTemplate?) -> String? {
        let review = "This saved form needs review before it can count as complete. The original record has been kept."
        guard !templateTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let payload = try? FieldFormPayload.response(answersJSON) else { return review }
        let original = template.flatMap { $0.id == templateID ? $0 : nil }
        if let original {
            guard original.title == templateTitle,
                  let questions = try? FieldFormPayload.questions(original.questionsJSON),
                  (try? FieldFormPayload.validate(payload, against: questions)) != nil else { return review }
        }
        switch payload {
        case .snapshot(let snapshot):
            // Version 1 omitted choice options. Do not manufacture them from
            // the answer or substitute options from a newer template revision.
            if snapshot.questions == nil, original == nil, snapshot.rows.contains(where: { $0.kind == .choice }) {
                return "The original choice list is needed to verify this saved form. Ask the office to restore its original template."
            }
            let questions = snapshot.questions ?? original?.questions ?? snapshot.rows.map {
                FieldFormQuestion(id: $0.questionID, label: $0.label, kind: $0.kind,
                                  required: $0.required)
            }
            return FieldFormCompletionPolicy.validationIssue(questions: questions, answers: payload.answers)
        case .legacy:
            guard let original, original.dataReviewIssue == nil else { return review }
            return FieldFormCompletionPolicy.validationIssue(questions: original.questions, answers: payload.answers)
        }
    }

    private static func encode<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

}

struct FieldFormCloseoutRequirement: Identifiable, Equatable {
    let templateID: UUID
    let title: String

    var id: UUID { templateID }
    var closeoutItem: String { "Field form: \(title)" }
}

struct FieldFormCloseoutReadiness: Equatable {
    let requirements: [FieldFormCloseoutRequirement]
    let missingRequirements: [FieldFormCloseoutRequirement]

    var completedCount: Int { requirements.count - missingRequirements.count }
    var totalCount: Int { requirements.count }
    var isReady: Bool { missingRequirements.isEmpty }

    var statusLabel: String {
        guard totalCount > 0 else { return "No required forms" }
        return isReady
            ? "\(totalCount) required form\(totalCount == 1 ? "" : "s") complete"
            : "\(completedCount)/\(totalCount) required forms complete"
    }
}

enum FieldFormCloseoutPolicy {
    static func readiness(
        serviceCallID: UUID,
        serviceType: ServiceCallType,
        templates: [FieldFormTemplate],
        responses: [FieldFormResponse]
    ) -> FieldFormCloseoutReadiness {
        let scopedResponses = responses.filter { response in
            response.serviceCallID == serviceCallID && response.completionReviewIssue(
                resolving: templates.first { $0.id == response.templateID }
            ) == nil
        }
        let completedTemplateIDs = Set(scopedResponses.map(\.templateID))
        let completedTitles = Set(scopedResponses.map { normalizedTitle($0.templateTitle) })

        var seenTitles = Set<String>()
        let requirements = templates
            .filter {
                $0.isActive &&
                    $0.closeoutRequirementApplies(to: serviceType)
            }
            .sorted {
                let titleOrder = $0.title.localizedCaseInsensitiveCompare($1.title)
                return titleOrder == .orderedSame ? $0.createdAt > $1.createdAt : titleOrder == .orderedAscending
            }
            .compactMap { template -> FieldFormCloseoutRequirement? in
                let titleKey = normalizedTitle(template.title)
                if template.dataReviewIssue != nil {
                    return FieldFormCloseoutRequirement(templateID: template.id,
                        title: titleKey.isEmpty ? "Unnamed form needs review" : template.title)
                }
                guard seenTitles.insert(titleKey).inserted else { return nil }
                return FieldFormCloseoutRequirement(templateID: template.id, title: template.title)
            }

        let missing = requirements.filter { requirement in
            templates.first(where: { $0.id == requirement.templateID })?.dataReviewIssue != nil ||
                (!completedTemplateIDs.contains(requirement.templateID) &&
                !completedTitles.contains(normalizedTitle(requirement.title)))
        }
        return FieldFormCloseoutReadiness(
            requirements: requirements,
            missingRequirements: missing
        )
    }

    static func responseCompletes(
        _ template: FieldFormTemplate,
        serviceCallID: UUID,
        responses: [FieldFormResponse],
        originalTemplates: [FieldFormTemplate] = []
    ) -> Bool {
        latestResponse(
            completing: template,
            serviceCallID: serviceCallID,
            responses: responses,
            originalTemplates: originalTemplates
        ) != nil
    }

    static func latestResponse(
        completing template: FieldFormTemplate,
        serviceCallID: UUID,
        responses: [FieldFormResponse],
        originalTemplates: [FieldFormTemplate] = []
    ) -> FieldFormResponse? {
        guard template.dataReviewIssue == nil else { return nil }
        let titleKey = normalizedTitle(template.title)
        return responses
            .filter { response in
                response.serviceCallID == serviceCallID &&
                    (response.templateID == template.id || normalizedTitle(response.templateTitle) == titleKey) &&
                    response.completionReviewIssue(resolving:
                        originalTemplates.first { $0.id == response.templateID } ?? template) == nil
            }
            .max(by: { $0.completedAt < $1.completedAt })
    }

    private static func normalizedTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

struct FieldFormResponseDetailView: View {
    let response: FieldFormResponse
    let template: FieldFormTemplate?
    let serviceCall: ServiceCall
    let attachment: ServiceDocumentAttachment?
    @State private var exportURL: URL?
    @State private var exportMessage: String?

    private var rows: [FieldFormAnswerRow] {
        guard response.serviceCallID == serviceCall.id else { return [] }
        return response.answerRows(resolving: template)
    }

    private var reviewIssue: String? {
        guard response.serviceCallID == serviceCall.id else { return "Open this form from its original job." }
        return response.completionReviewIssue(resolving: template)
    }

    var body: some View {
        Form {
            if let reviewIssue {
                Section("Needs review") {
                    Label(reviewIssue, systemImage: "exclamationmark.triangle")
                        .accessibilityIdentifier("FieldFormHistoryNeedsReview")
                }
            }
            Section(reviewIssue == nil ? "Completion" : "Original record") {
                LabeledContent("Form", value: response.templateTitle)
                LabeledContent("Customer", value: serviceCall.customer.name)
                LabeledContent("Job", value: serviceCall.type.displayName)
                LabeledContent(reviewIssue == nil ? "Completed" : "Recorded",
                               value: response.completedAt.formatted(date: .abbreviated, time: .shortened))
                if let completedByEmail = response.completedByEmail?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !completedByEmail.isEmpty {
                    LabeledContent(reviewIssue == nil ? "Completed by" : "Recorded by", value: completedByEmail)
                }
            }
            Section("Responses") {
                if rows.isEmpty {
                    Text("The saved answers cannot be displayed. The original record is still kept; ask the office to review it.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("FieldFormUnreadableAnswers")
                }
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.label)
                            .font(.subheadline.weight(.semibold))
                        Text(row.displayAnswer)
                            .foregroundStyle(row.displayAnswer == "Not answered" ? .secondary : .primary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if let exportMessage {
                Section {
                    Label(exportMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("FieldFormExportIssue")
                }
            }
        }
        .navigationTitle(response.templateTitle)
        .toolbar {
            if let exportURL {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: exportURL) {
                        Label("Share PDF", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("ShareCompletedFieldFormPDF")
                }
            }
        }
        .task(id: response.id) {
            prepareExportURL()
        }
    }

    private func prepareExportURL() {
        exportURL = nil
        exportMessage = nil
        guard response.serviceCallID == serviceCall.id else {
            return
        }
        if let attachment,
           attachment.serviceCallID == serviceCall.id,
           attachment.customer?.id == serviceCall.customer.id,
           attachment.caption?.contains("[FieldFormResponse:\(response.id.uuidString)]") == true,
           FileManager.default.fileExists(atPath: attachment.localFilePath) {
            exportURL = attachment.localFileURL
            exportMessage = nil
            return
        }
        guard reviewIssue == nil else {
            // The review notice already explains why this is not a completion.
            // Keep the PDF action unavailable without a second error banner.
            return
        }
        do {
            exportURL = try CustomerDocumentExporter.exportFieldFormResponse(
                response,
                serviceCall: serviceCall,
                template: template
            )
            exportMessage = nil
        } catch {
            exportMessage = "The PDF could not be prepared: \(error.localizedDescription)"
        }
    }
}

enum FieldFormHistoryPolicy {
    static func responses(_ values: [FieldFormResponse], for serviceCallID: UUID) -> [FieldFormResponse] {
        values.filter { $0.serviceCallID == serviceCallID }.sorted {
            $0.completedAt == $1.completedAt
                ? $0.id.uuidString < $1.id.uuidString
                : $0.completedAt > $1.completedAt
        }
    }
}

struct CompletedFieldFormsView: View {
    let responses: [FieldFormResponse]
    let templates: [FieldFormTemplate]
    let serviceCall: ServiceCall
    let attachments: [ServiceDocumentAttachment]

    var body: some View {
        List(FieldFormHistoryPolicy.responses(responses, for: serviceCall.id)) { response in
            NavigationLink {
                FieldFormResponseDetailView(
                    response: response,
                    template: templates.first { $0.id == response.templateID },
                    serviceCall: serviceCall,
                    attachment: attachment(for: response)
                )
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(response.templateTitle)
                        .font(.headline)
                    Text(response.completedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if response.completionReviewIssue(resolving: templates.first { $0.id == response.templateID }) != nil {
                        Label("Needs review", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                    }
                }
            }
            .accessibilityIdentifier("SavedFieldFormResponse-\(response.id.uuidString)")
        }
        .navigationTitle("Saved Forms")
    }

    private func attachment(for response: FieldFormResponse) -> ServiceDocumentAttachment? {
        let marker = "[FieldFormResponse:\(response.id.uuidString)]"
        return attachments.first {
            $0.serviceCallID == serviceCall.id && ($0.caption?.contains(marker) ?? false)
        }
    }
}

/// Undo only this editor's changes on failure. A context-wide rollback would
/// also discard unrelated field work waiting to be saved.
enum FieldFormTemplatePersistence {
    static func insert(_ template: FieldFormTemplate, retiring source: FieldFormTemplate?,
                       in context: ModelContext, persist: () throws -> Void) throws {
        let wasActive = source?.isActive
        source?.isActive = false
        context.insert(template)
        do {
            try persist()
        } catch {
            context.delete(template)
            if let source, let wasActive { source.isActive = wasActive }
            throw error
        }
    }

    static func setActive(_ value: Bool, for template: FieldFormTemplate,
                          persist: () throws -> Void) throws {
        let wasActive = template.isActive
        template.isActive = value
        do { try persist() }
        catch {
            template.isActive = wasActive
            throw error
        }
    }
}

private enum FieldFormTemplateEditorMode: Identifiable {
    case create
    case revise(FieldFormTemplate)
    case duplicate(FieldFormTemplate)

    var id: String {
        switch self {
        case .create: "create"
        case .revise(let template): "revise-\(template.id.uuidString)"
        case .duplicate(let template): "duplicate-\(template.id.uuidString)"
        }
    }

    var sourceTemplate: FieldFormTemplate? {
        switch self {
        case .create: nil
        case .revise(let template), .duplicate(let template): template
        }
    }
}

struct FieldFormTemplateManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FieldFormTemplate.createdAt, order: .forward) private var templates: [FieldFormTemplate]
    @State private var editorMode: FieldFormTemplateEditorMode?
    @State private var savedTemplateID: UUID?
    @State private var saveError: String?

    private var orderedTemplates: [FieldFormTemplate] {
        templates.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            if lhs.title != rhs.title {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            Form {
                Section("Reusable Forms") {
                    if orderedTemplates.isEmpty {
                        ContentUnavailableView(
                            "No field forms",
                            systemImage: "checklist",
                            description: Text("Create a form for service, repair, installation, maintenance, or another job type.")
                        )
                    }
                    ForEach(orderedTemplates) { template in
                        templateRow(template)
                            .id(template.id)
                    }
                }
                Section("Version Safety") {
                    Text("Revising creates a new active template and retires the prior version. Completed jobs keep their original question labels, answers, technician, timestamp, and PDF.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("FieldFormTemplateList")
            .navigationTitle("Field Form Templates")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editorMode = .create
                    } label: {
                        Label("New Form", systemImage: "plus")
                    }
                    .accessibilityIdentifier("CreateFieldFormTemplate")
                }
            }
            .sheet(item: $editorMode, onDismiss: { revealSavedTemplate(using: proxy) }) { mode in
                FieldFormTemplateEditor(mode: mode) { savedTemplateID = $0 }
            }
            .onChange(of: orderedTemplates.map(\.id)) {
                if editorMode == nil { revealSavedTemplate(using: proxy) }
            }
            .alert("Could not update form", isPresented: Binding(
                get: { saveError != nil }, set: { if !$0 { saveError = nil } }
            )) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "The previous status has been kept. Try again.")
            }
            .onAppear {
                FieldFormTemplate.ensureStarterTemplates(in: modelContext)
                try? modelContext.save()
            }
            }
        }
    }

    private func revealSavedTemplate(using proxy: ScrollViewProxy) {
        guard let savedTemplateID, orderedTemplates.contains(where: { $0.id == savedTemplateID }) else { return }
        proxy.scrollTo(savedTemplateID, anchor: .center)
        self.savedTemplateID = nil
    }

    private func templateRow(_ template: FieldFormTemplate) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(template.title)
                    .font(.headline)
                Text("\(template.questions.count) \(template.questions.count == 1 ? "field" : "fields") • \(template.scopeSummary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("FieldFormTemplateSummary-\(template.id.uuidString)")
                if template.requiresCompletionForCloseout {
                    Text("Required for closeout")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                if !template.isActive {
                    Text("Retired")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Toggle(
                "Active",
                isOn: Binding(
                    get: { template.isActive },
                    set: { newValue in
                        do {
                            try FieldFormTemplatePersistence.setActive(newValue, for: template) {
                                try modelContext.save()
                            }
                        } catch {
                            saveError = "The previous status has been kept. Try again. \(error.localizedDescription)"
                        }
                    }
                )
            )
            .labelsHidden()
            .accessibilityLabel("\(template.title) active")
            Menu {
                Button {
                    editorMode = .revise(template)
                } label: {
                    Label("Revise", systemImage: "square.and.pencil")
                }
                Button {
                    editorMode = .duplicate(template)
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .accessibilityLabel("Actions for \(template.title)")
        }
    }
}

private struct FieldFormTemplateEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let mode: FieldFormTemplateEditorMode
    let onSaved: (UUID) -> Void
    @State private var title: String
    @State private var questions: [FieldFormQuestion]
    @State private var selectedTypes: Set<ServiceCallType>
    @State private var requiresCompletionForCloseout: Bool
    @State private var validationMessage: String?
    @State private var hasReviewedOriginalSetup = false

    init(mode: FieldFormTemplateEditorMode, onSaved: @escaping (UUID) -> Void) {
        self.mode = mode
        self.onSaved = onSaved
        let source = mode.sourceTemplate
        let initialTitle: String
        switch mode {
        case .duplicate:
            initialTitle = source.map { "\($0.title) Copy" } ?? ""
        case .create, .revise:
            initialTitle = source?.title ?? ""
        }
        _title = State(initialValue: initialTitle)
        _questions = State(initialValue: source?.questions ?? [
            FieldFormQuestion(label: "", kind: .toggle, required: true)
        ])
        _selectedTypes = State(initialValue: source?.applicableServiceTypes ?? [])
        switch mode {
        case .revise:
            _requiresCompletionForCloseout = State(initialValue: source?.requiresCompletionForCloseout ?? false)
        case .create, .duplicate:
            _requiresCompletionForCloseout = State(initialValue: false)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if mode.sourceTemplate?.dataReviewIssue != nil {
                    Section("Review original setup") {
                        Text("The original setup could not be fully read. Check the fields, job types, and closeout requirement before saving a new version. The original saved record will be kept.")
                        Toggle("I've reviewed the fields and job requirements", isOn: $hasReviewedOriginalSetup)
                            .accessibilityIdentifier("FieldFormOriginalSetupReviewed")
                    }
                }
                Section("Form") {
                    TextField("Form title", text: $title)
                        .accessibilityIdentifier("FieldFormTemplateTitle")
                    DisclosureGroup("Job types") {
                        Text("Leave every type off to make this form available for all jobs.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(ServiceCallType.allCases, id: \.rawValue) { type in
                            Toggle(type.displayName, isOn: serviceTypeBinding(type))
                        }
                    }
                    Text(selectedTypes.isEmpty ? "Applies to all job types" : selectedTypes.map(\.displayName).sorted().joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Required for job closeout", isOn: $requiresCompletionForCloseout)
                        .accessibilityIdentifier("FieldFormRequiredForCloseout")
                    Text(requiresCompletionForCloseout
                         ? "Every matching job must complete this form before closeout."
                         : "The form stays available when useful but does not block closeout.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Fields") {
                    ForEach($questions) { $question in
                        questionEditor(question: $question)
                    }
                    .onDelete { questions.remove(atOffsets: $0) }
                    .onMove { questions.move(fromOffsets: $0, toOffset: $1) }

                    Menu {
                        ForEach(FieldFormQuestionKind.allCases) { kind in
                            Button {
                                addQuestion(kind)
                            } label: {
                                Label(kind.displayName, systemImage: kind.systemImage)
                            }
                        }
                    } label: {
                        Label("Add Field", systemImage: "plus.circle")
                    }
                    .accessibilityIdentifier("AddFieldFormQuestion")
                }
                if case .revise = mode {
                    Section("Revision") {
                        Text("Saving retires the current template and creates a new active version. Existing completed forms and PDFs are not changed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle(navigationTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .secondaryAction) {
                    EditButton()
                        .disabled(questions.count < 2)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .accessibilityIdentifier("SaveFieldFormTemplate")
                        .disabled(mode.sourceTemplate?.dataReviewIssue != nil && !hasReviewedOriginalSetup)
                }
            }
        }
    }

    private var navigationTitle: String {
        switch mode {
        case .create: "New Field Form"
        case .revise: "Revise Field Form"
        case .duplicate: "Duplicate Field Form"
        }
    }

    private func serviceTypeBinding(_ type: ServiceCallType) -> Binding<Bool> {
        Binding(
            get: { selectedTypes.contains(type) },
            set: { isSelected in
                if isSelected { selectedTypes.insert(type) }
                else { selectedTypes.remove(type) }
            }
        )
    }

    private func questionEditor(question: Binding<FieldFormQuestion>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Field label", text: question.label)
            Picker("Type", selection: question.kind) {
                ForEach(FieldFormQuestionKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            Toggle("Required before completion", isOn: question.required)
            if question.wrappedValue.kind == .choice {
                TextField("Choices — one per line", text: choicesBinding(question), axis: .vertical)
                    .lineLimit(2...6)
                Text("Enter at least two distinct choices.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func choicesBinding(_ question: Binding<FieldFormQuestion>) -> Binding<String> {
        Binding(
            get: { question.wrappedValue.choices.joined(separator: "\n") },
            set: { value in
                question.wrappedValue.choices = value
                    .split(whereSeparator: \.isNewline)
                    .map(String.init)
            }
        )
    }

    private func addQuestion(_ kind: FieldFormQuestionKind) {
        questions.append(FieldFormQuestion(
            label: "",
            kind: kind,
            required: false,
            choices: kind == .choice ? ["Pass", "Flag", "Fail"] : []
        ))
    }

    private func save() {
        guard mode.sourceTemplate?.dataReviewIssue == nil || hasReviewedOriginalSetup else {
            validationMessage = "Review the original setup and confirm the job requirements before saving."
            return
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanQuestions = questions.map { question in
            FieldFormQuestion(
                id: question.id,
                label: question.label.trimmingCharacters(in: .whitespacesAndNewlines),
                kind: question.kind,
                required: question.required,
                choices: question.kind == .choice
                    ? FieldFormTemplatePolicy.normalizedChoices(question.choices)
                    : []
            )
        }
        if let issue = FieldFormTemplatePolicy.validationIssue(title: cleanTitle, questions: cleanQuestions) {
            validationMessage = issue
            return
        }

        let template = FieldFormTemplate(
            title: cleanTitle, questions: cleanQuestions, applicableServiceTypes: selectedTypes,
            requiresCompletionForCloseout: requiresCompletionForCloseout
        )
        let source: FieldFormTemplate?
        if case .revise(let original) = mode { source = original } else { source = nil }
        do {
            try FieldFormTemplatePersistence.insert(template, retiring: source, in: modelContext) {
                try modelContext.save()
            }
            onSaved(template.id)
            dismiss()
        } catch {
            validationMessage = "Could not save this form: \(error.localizedDescription)"
        }
    }
}
