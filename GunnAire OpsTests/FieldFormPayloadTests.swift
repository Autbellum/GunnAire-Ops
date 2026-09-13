import Foundation
import PDFKit
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor struct FieldFormPayloadTests {
    let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    func question(kind: FieldFormQuestionKind = .toggle, required: Bool = true) -> FieldFormQuestion {
        FieldFormQuestion(id: id, label: "Original check — café", kind: kind, required: required,
                          choices: kind == .choice ? ["Pass", "Fail"] : [])
    }
    func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
    func version1(_ question: FieldFormQuestion, answer: String) throws -> String {
        try encode(FieldFormPayload.Snapshot(version: 1,
            rows: FieldFormCompletionPolicy.answerRows(questions: [question], answers: [question.id: answer]), questions: nil))
    }
    func fixture(kind: FieldFormQuestionKind = .toggle) -> (FieldFormTemplate, FieldFormResponse) {
        let question = question(kind: kind)
        let template = FieldFormTemplate(title: "Repair Completion", questions: [question],
                                        applicableServiceTypes: [.repair], requiresCompletionForCloseout: true)
        return (template, FieldFormResponse(serviceCallID: UUID(), template: template,
                                           answers: [id: kind == .choice ? "Pass" : "true"]))
    }
    func readiness(_ template: FieldFormTemplate, _ response: FieldFormResponse) -> FieldFormCloseoutReadiness {
        FieldFormCloseoutPolicy.readiness(serviceCallID: response.serviceCallID, serviceType: .repair,
                                         templates: [template], responses: [response])
    }

    @Test func savedHistoryUsesOnlyTheOriginalJobWithStableOrderingAndUnchangedBytes() {
        let (template, first) = fixture()
        let second = FieldFormResponse(serviceCallID: first.serviceCallID, template: template, answers: [id: "true"],
                                       completedAt: first.completedAt)
        let newer = FieldFormResponse(serviceCallID: first.serviceCallID, template: template, answers: [:],
                                      completedAt: first.completedAt.addingTimeInterval(60))
        newer.answersJSON = #"{"version":99,"rows":[]}"#
        let other = FieldFormResponse(serviceCallID: UUID(), template: template, answers: [id: "true"])
        let raw = newer.answersJSON
        let values = FieldFormHistoryPolicy.responses([other, second, newer, first], for: first.serviceCallID)
        let tiedIDs = [first.id, second.id].sorted { $0.uuidString < $1.uuidString }
        let expectedIDs: [UUID] = [newer.id] + tiedIDs
        #expect(values.map(\.id) == expectedIDs)
        #expect(newer.answersJSON == raw)
        #expect(newer.completionReviewIssue(resolving: template) != nil)
    }

    private enum SaveFailure: Error { case diskUnavailable }

    private func localContext() throws -> ModelContext {
        let schema = Schema([FieldFormTemplate.self])
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    @Test func failedRevisionRetainsTheOriginalAndUnrelatedDraftBeforeSuccessfulRetry() throws {
        let context = try localContext()
        let (source, response) = fixture()
        let (unrelated, _) = fixture()
        context.insert(source); context.insert(unrelated); try context.save()
        unrelated.title = "Unsaved office edit"
        let rawQuestions = source.questionsJSON
        let rawAssignment = source.applicableServiceTypesJSON
        let rawAnswer = response.answersJSON
        let candidate = FieldFormTemplate(title: source.title, questions: [question(kind: .text)],
                                          applicableServiceTypes: [.repair], requiresCompletionForCloseout: true)
        #expect(throws: SaveFailure.self) {
            try FieldFormTemplatePersistence.insert(candidate, retiring: source, in: context) {
                #expect(!source.isActive)
                throw SaveFailure.diskUnavailable
            }
        }
        #expect(source.isActive)
        #expect(source.questionsJSON == rawQuestions)
        #expect(source.applicableServiceTypesJSON == rawAssignment)
        #expect(response.answersJSON == rawAnswer)
        #expect(unrelated.title == "Unsaved office edit")
        #expect(try context.fetch(FetchDescriptor<FieldFormTemplate>()).allSatisfy { $0.id != candidate.id })
        let retry = FieldFormTemplate(title: source.title, questions: [question(kind: .text)],
                                      applicableServiceTypes: [.repair], requiresCompletionForCloseout: true)
        try FieldFormTemplatePersistence.insert(retry, retiring: source, in: context) { try context.save() }
        #expect(!source.isActive)
        #expect(retry.isActive && retry.requiresCompletionForCloseout)
        #expect(try context.fetch(FetchDescriptor<FieldFormTemplate>()).count == 3)
        #expect(response.completionReviewIssue(resolving: source) == nil)
    }

    @Test func failedCreateLeavesNoPhantomFormAndFailedStatusChangeKeepsPreviousValue() throws {
        let context = try localContext()
        let (candidate, _) = fixture()
        #expect(throws: SaveFailure.self) {
            try FieldFormTemplatePersistence.insert(candidate, retiring: nil, in: context) {
                throw SaveFailure.diskUnavailable
            }
        }
        #expect(try context.fetch(FetchDescriptor<FieldFormTemplate>()).isEmpty)
        let (original, _) = fixture()
        context.insert(original); try context.save()
        for initial in [true, false] {
            original.isActive = initial
            #expect(throws: SaveFailure.self) {
                try FieldFormTemplatePersistence.setActive(!initial, for: original) {
                    throw SaveFailure.diskUnavailable
                }
            }
            #expect(original.isActive == initial)
        }
        try FieldFormTemplatePersistence.setActive(true, for: original) { try context.save() }
        #expect(original.isActive)
    }

    @Test func newResponsesRetainOriginalQuestionsChoicesAndExactText() throws {
        let (template, response) = fixture(kind: .choice)
        let raw = response.answersJSON
        guard case .snapshot(let snapshot) = try FieldFormPayload.response(raw) else { Issue.record("Missing snapshot"); return }
        #expect(snapshot.version == 2)
        #expect(snapshot.questions == template.questions)
        #expect(snapshot.questions?.first?.choices == ["Pass", "Fail"])
        #expect(response.completionReviewIssue(resolving: nil) == nil)
        let revision = template.makeRevision(title: "Repair Completion",
            questions: [FieldFormQuestion(label: "New work", kind: .text, required: true)], applicableServiceTypes: [.repair])
        #expect(response.completionReviewIssue(resolving: revision) == nil)
        #expect(response.answersJSON == raw)
        #expect(response.answerRows(resolving: revision).first?.label == "Original check — café")
    }

    @Test func duplicateUUIDRowsNeverTrapOrCreditCompletion() throws {
        let (template, response) = fixture()
        let row = FieldFormCompletionPolicy.answerRows(questions: [question()], answers: [id: "true"])[0]
        response.answersJSON = try encode(FieldFormPayload.Snapshot(version: 1, rows: [row, row], questions: nil))
        let raw = response.answersJSON
        #expect(response.answers.isEmpty)
        #expect(response.snapshotAnswerRows.isEmpty)
        #expect(response.completionReviewIssue(resolving: template) != nil)
        #expect(!readiness(template, response).isReady)
        #expect(response.answersJSON == raw)
    }

    @Test func duplicateEscapedKeysAndBooleanCoercionAreRejected() throws {
        let row = #"{"questionID":"11111111-1111-1111-1111-111111111111","label":"Original","kind":"toggle","required":true,"answer":"true"}"#
        for text in [
            "{\"version\":1,\"version\":2,\"rows\":[\(row)]}",
            "{\"version\":1,\"vers\\u0069on\":1,\"rows\":[\(row)]}",
            "{\"version\":true,\"rows\":[\(row)]}",
            "{\"version\":1.5,\"rows\":[\(row)]}",
            "{\"version\":1,\"rows\":[\(row.replacingOccurrences(of: "\"required\":true", with: "\"required\":1"))]}",
            "{\"version\":1,\"rows\":[\(row)],\"approved\":true}",
            "{\"version\":99,\"rows\":[\(row)]}",
        ] {
            #expect(throws: (any Error).self) { try FieldFormPayload.response(text) }
        }
    }

    @Test func invalidAndExcessiveJSONHasNoPartialAcceptance() throws {
        for text in ["", "null", "[", "{} trailing", "{\"a\":1,}", "[1,]",
                     "{\"a\":NaN}", "{\"a\":01}", "{\"a\":+1}", "\"\\uD800\"",
                     String(repeating: "[", count: 20) + "0" + String(repeating: "]", count: 20),
                     "[" + Array(repeating: "0", count: 20_001).joined(separator: ",") + "]",
                     String(repeating: " ", count: 1_048_577)] {
            #expect(throws: (any Error).self) { try FieldFormPayload.response(text) }
        }
        let literal = "Reading \"quoted\" \\ valve\n雪 café"
        let q = question(kind: .text)
        let raw = try version1(q, answer: literal)
        #expect(try FieldFormPayload.response(raw).answers[id] == literal)
    }

    @Test func JSONReaderItselfEnforcesSyntaxDuplicateKeysAndResourceBounds() throws {
        for valid in ["null", "true", "false", "-1.25e+10", "[]", "{}",
                      #"{"text":"quoted \"value\" / \u96EA", "nested":[1,false,null]}"#] {
            _ = try FieldFormJSON.parse(valid)
        }
        for invalid in ["", "{} trailing", #"{"key":1,"key":2}"#,
                        #"{"key":1,"k\u0065y":1}"#, "{\"a\":1,}", "[1,]",
                        "{\"a\":NaN}", "{\"a\":01}", "{\"a\":+1}", "\"\\uD800\"",
                        String(repeating: "[", count: 18) + "0" + String(repeating: "]", count: 18),
                        "[" + Array(repeating: "0", count: 20_001).joined(separator: ",") + "]",
                        "\"" + String(repeating: "x", count: 1_048_577) + "\""] {
            #expect(throws: (any Error).self) { try FieldFormJSON.parse(invalid) }
        }
    }

    @Test func questionIdentitiesKindsChoicesAndRequiredFlagsAreStrict() throws {
        let q = question(kind: .choice)
        let raw = try encode([q])
        #expect(try FieldFormPayload.questions(raw) == [q])
        for value in [try encode([q, q]), raw.replacingOccurrences(of: "choice", with: "unknown"),
                      raw.replacingOccurrences(of: "\"required\":true", with: "\"required\":1"),
                      try encode([FieldFormQuestion(label: " ", kind: .text)]),
                      try encode([FieldFormQuestion(label: "Check", kind: .choice, choices: ["Pass", "pass"])]),
                      try encode([FieldFormQuestion(label: "Check", kind: .toggle, choices: ["Stale"])]),
                      raw.replacingOccurrences(of: "\"choices\":", with: "\"future\":true,\"choices\":")] {
            #expect(throws: (any Error).self) { try FieldFormPayload.questions(value) }
        }
    }

    @Test func assignmentsSupportOnlyKnownLegacyAndCurrentShapes() throws {
        #expect(try FieldFormPayload.assignment(nil).isLegacy)
        #expect(try FieldFormPayload.assignment(#"["repair"]"#).serviceTypes == [.repair])
        #expect(try FieldFormPayload.assignment(#"{"version":1,"serviceTypes":[],"requiredForCloseout":true}"#).required)
        for value in [#"["unknown"]"#, #"["repair","repair"]"#, "null", "{}",
                      #"{"version":2,"serviceTypes":["repair"],"requiredForCloseout":true}"#,
                      #"{"version":1,"serviceTypes":["repair"],"requiredForCloseout":1}"#,
                      #"{"version":true,"serviceTypes":[],"requiredForCloseout":true}"#,
                      #"{"version":1,"serviceTypes":[],"requiredForCloseout":false,"extra":true}"#] {
            #expect(throws: (any Error).self) { try FieldFormPayload.assignment(value) }
        }
    }

    @Test func malformedStarterAssignmentIsNotOverwrittenDuringMigration() throws {
        let schema = GunnAireModelSchema.schema
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let context = ModelContext(container)
        let (template, _) = fixture()
        let original = #"{"version":9,"serviceTypes":["repair"],"requiredForCloseout":true}"#
        template.applicableServiceTypesJSON = original
        context.insert(template); try context.save()
        FieldFormTemplate.ensureStarterTemplates(in: context); try context.save()
        #expect(template.applicableServiceTypesJSON == original)
        #expect(template.dataReviewIssue != nil)
        #expect(!template.applies(to: .repair))
        let result = FieldFormCloseoutPolicy.readiness(serviceCallID: UUID(), serviceType: .repair,
                                                      templates: [template], responses: [])
        #expect(!result.isReady)
        #expect(result.totalCount == 1)
    }

    @Test func legacyUUIDArrayPreservesAnswersAndNeedsTheOriginalTemplate() throws {
        let (template, response) = fixture()
        response.answersJSON = try encode([id: "true"])
        #expect(response.answers[id] == "true")
        #expect(response.completionReviewIssue(resolving: template) == nil)
        #expect(response.completionReviewIssue(resolving: nil) != nil)
        let revision = template.makeRevision(title: template.title, questions: [question(kind: .text)], applicableServiceTypes: [.repair])
        #expect(response.completionReviewIssue(resolving: revision) != nil)
        #expect(response.answerRows(resolving: revision).first?.label == "Recorded field 1")
        for raw in ["[\"\(id)\",\"true\",\"\(id)\",\"false\"]", "[\"\(id)\"]",
                    "[\"\(id)\",false]", "[\"bad-id\",\"true\"]"] {
            #expect(throws: (any Error).self) { try FieldFormPayload.response(raw) }
        }
    }

    @Test func oldSnapshotsRetainTheirMeaningWithoutAssumingMissingChoices() throws {
        let (template, response) = fixture()
        response.answersJSON = try version1(question(), answer: "true")
        #expect(response.completionReviewIssue(resolving: nil) == nil)
        #expect(response.completionReviewIssue(resolving: template) == nil)
        let (choiceTemplate, choiceResponse) = fixture(kind: .choice)
        choiceResponse.answersJSON = try version1(question(kind: .choice), answer: "Pass")
        #expect(choiceResponse.completionReviewIssue(resolving: choiceTemplate) == nil)
        #expect(choiceResponse.completionReviewIssue(resolving: nil) != nil)
        choiceResponse.answersJSON = try version1(question(kind: .choice), answer: "Unlisted")
        #expect(choiceResponse.completionReviewIssue(resolving: choiceTemplate) != nil)
    }

    @Test func incompleteAndUnrecognizedAnswersCannotCreditCloseout() throws {
        let (template, response) = fixture()
        for answer in ["false", "", "yes", " true "] {
            response.answersJSON = try version1(question(), answer: answer)
            #expect(!readiness(template, response).isReady)
            #expect(FieldFormCloseoutPolicy.latestResponse(completing: template,
                serviceCallID: response.serviceCallID, responses: [response]) == nil)
        }
        #expect(FieldFormCompletionPolicy.validationIssue(questions: [], answers: [:]) != nil)
        #expect(FieldFormCompletionPolicy.validationIssue(questions: [question(), question()], answers: [id: "true"]) != nil)
        #expect(FieldFormCompletionPolicy.validationIssue(questions: [question()], answers: [id: "true", UUID(): "extra"]) != nil)
        #expect(FieldFormCompletionPolicy.validationIssue(questions: [question(kind: .choice)], answers: [id: "Unlisted"]) != nil)
    }

    @Test func blankOptionalConfirmationIsNotReportedAsNo() {
        let q = question(required: false)
        let row = FieldFormCompletionPolicy.answerRows(questions: [q], answers: [:])[0]
        #expect(row.displayAnswer == "Not answered")
        #expect(FieldFormCompletionPolicy.validationIssue(questions: [q], answers: [:]) == nil)
        #expect(FieldFormAnswerRow(questionID: id, label: q.label, kind: .toggle,
                                  required: false, answer: "unknown").displayAnswer == "Needs review")
    }

    @Test func snapshotTamperingCannotDropRequiredFieldsOrChangeChoiceDomains() throws {
        let (template, response) = fixture(kind: .choice)
        var changed = question(kind: .choice)
        changed.required = false
        let forged = FieldFormPayload.Snapshot(version: 2,
            rows: FieldFormCompletionPolicy.answerRows(questions: [changed], answers: [id: "Pass"]), questions: [changed])
        response.answersJSON = try encode(forged)
        #expect(response.completionReviewIssue(resolving: template) != nil)
        response.answersJSON = try encode(FieldFormPayload.Snapshot(version: 2,
            rows: FieldFormCompletionPolicy.answerRows(questions: [question(kind: .choice)], answers: [id: "Unlisted"]),
            questions: [question(kind: .choice)]))
        #expect(response.completionReviewIssue(resolving: nil) != nil)
        response.answersJSON = try encode(FieldFormPayload.Snapshot(version: 1, rows: [], questions: nil))
        #expect(!readiness(template, response).isReady)
    }

    @Test func fullWorkspaceRejectsMalformedFormsBeforeDetachedReconstruction() throws {
        let records = try StaffWorkspaceFullModelTests().encodedFixtures()
        _ = try StaffWorkspaceRelationshipGraph.validate(records)
        let mutations: [(String, String, StaffWorkspaceValue)] = [
            ("formTemplate", "questionsJSON", .text("[{}]")),
            ("formTemplate", "applicableServiceTypesJSON", .text(#"["future"]"#)),
            ("formResponse", "answersJSON", .text(#"{"version":9,"rows":[]}"#)),
            ("formResponse", "templateTitle", .text("Another form")),
            ("formResponse", "answersJSON", .text("[\"\(id)\",\"extra\"]")),
        ]
        for (kind, field, value) in mutations {
            let changed = records.map { record in
                guard record.kind == kind else { return record }
                var fields = record.fields; fields[field] = value
                return StaffWorkspaceModelRecord(version: record.version, kind: kind, id: record.id, fields: fields)
            }
            #expect(throws: (any Error).self) { try StaffWorkspaceRelationshipGraph.validate(changed) }
            // Transfer primitives must still retain the original bytes for
            // owner review; semantic rejection must not silently repair them.
            let detached = try StaffWorkspaceModelCatalog.decodeDetached(changed)
            #expect(detached.count == records.count)
        }
    }

    @Test func completionExportsRejectWrongJobAndInvalidHistoryBeforeWriting() throws {
        let (template, response) = fixture()
        let customer = Customer(name: "Isolated form fixture")
        let wrongJob = ServiceCall(type: .repair, scheduledDate: Date(), customer: customer)
        #expect(throws: CustomerDocumentExportError.self) {
            try CustomerDocumentExporter.exportFieldFormResponse(response, serviceCall: wrongJob, template: template)
        }
        response.serviceCallID = wrongJob.id
        response.answersJSON = "broken"
        #expect(throws: CustomerDocumentExportError.self) {
            try CustomerDocumentExporter.exportFieldFormResponse(response, serviceCall: wrongJob, template: template)
        }
    }

    @Test func originalTemplateResolutionAgreesAcrossCloseoutAndNavigation() throws {
        let (original, response) = fixture(kind: .choice)
        response.answersJSON = try version1(question(kind: .choice), answer: "Pass")
        let revision = original.makeRevision(title: original.title,
            questions: [FieldFormQuestion(label: "New safety check", kind: .toggle, required: true)],
            applicableServiceTypes: [.repair])
        let templates = [original, revision]
        let readiness = FieldFormCloseoutPolicy.readiness(serviceCallID: response.serviceCallID, serviceType: .repair,
                                                          templates: templates, responses: [response])
        #expect(readiness.isReady)
        #expect(FieldFormCloseoutPolicy.responseCompletes(revision, serviceCallID: response.serviceCallID,
            responses: [response], originalTemplates: templates))
        #expect(FieldFormCloseoutPolicy.latestResponse(completing: revision, serviceCallID: response.serviceCallID,
            responses: [response], originalTemplates: templates)?.id == response.id)
    }

    @Test func invalidOptionalOrOtherWorkTypeFormsDoNotInventCloseoutRequirements() {
        let optional = FieldFormTemplate(title: "Optional", questions: [], applicableServiceTypes: [.repair])
        let otherType = FieldFormTemplate(title: "Replacement", questions: [], applicableServiceTypes: [.replacement],
                                          requiresCompletionForCloseout: true)
        let result = FieldFormCloseoutPolicy.readiness(serviceCallID: UUID(), serviceType: .repair,
                                                      templates: [optional, otherType], responses: [])
        #expect(result.isReady && result.totalCount == 0)
        #expect(optional.dataReviewIssue != nil)
        #expect(optional.isListed(for: .repair))
        #expect(!otherType.isListed(for: .repair))
        otherType.applicableServiceTypesJSON = "unreadable"
        #expect(otherType.isListed(for: .repair))
        #expect(otherType.closeoutRequirementApplies(to: .repair))
    }

    @Test func constructorDoesNotDiscardAnswersWithUnknownQuestionIDs() {
        let (template, _) = fixture()
        let unknown = UUID()
        let response = FieldFormResponse(serviceCallID: UUID(), template: template,
                                          answers: [id: "true", unknown: "Keep my original reading"])
        #expect(response.answers[unknown] == "Keep my original reading")
        #expect(response.completionReviewIssue(resolving: template) != nil)
        #expect(response.answerRows(resolving: template).contains { $0.answer == "Keep my original reading" })
    }

    @Test func exportedReportsDistinguishReviewFromVerifiedCompletion() throws {
        let (template, validResponse) = fixture(kind: .choice)
        let customer = Customer(name: "Field Form QA", address: "100 Fixture Lane")
        let job = ServiceCall(type: .repair, scheduledDate: Date(timeIntervalSinceReferenceDate: 810_123_456), customer: customer)
        validResponse.serviceCallID = job.id
        let completedURL = try CustomerDocumentExporter.exportFieldFormResponse(validResponse, serviceCall: job, template: template)
        let completedBytes = try Data(contentsOf: completedURL)
        let completedText = try #require(PDFDocument(data: completedBytes)?.string)
        #expect(completedText.contains("Pass"))
        #expect(!completedText.contains("Needs review"))
        Attachment.record(Array(completedBytes), named: "Field Form - Verified Completion.pdf")

        let invalid = FieldFormResponse(serviceCallID: job.id, template: template, answers: [:])
        invalid.answersJSON = #"{"version":99,"rows":[]}"#
        let reportURL = try CustomerDocumentExporter.exportOnsiteReport(serviceCall: job, estimate: nil,
            invoice: nil, payments: [], fieldFormResponses: [invalid], includeFinancials: false)
        let bytes = try Data(contentsOf: reportURL)
        let text = try #require(PDFDocument(data: bytes)?.string)
            .split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
        #expect(text.contains("Needs review. Original record retained; completion is not verified."))
        #expect(text.contains("Field Form — Repair Completion"))
        #expect(invalid.answersJSON == #"{"version":99,"rows":[]}"#)
        Attachment.record(Array(bytes), named: "Field Form - Needs Review.pdf")
    }

    @Test func exportedLegacyHistoryUsesOriginalChoicesAndLabelsConsistently() throws {
        for legacyDictionary in [false, true] {
            let (original, response) = fixture(kind: .choice)
            let customer = Customer(name: "Legacy Form QA")
            let job = ServiceCall(type: .repair, scheduledDate: Date(), customer: customer)
            response.serviceCallID = job.id
            response.answersJSON = legacyDictionary ? try encode([id: "Pass"]) : try version1(question(kind: .choice), answer: "Pass")
            let revision = original.makeRevision(title: original.title,
                questions: [FieldFormQuestion(label: "New unrelated check", kind: .text, required: true)],
                applicableServiceTypes: [.repair])
            let url = try CustomerDocumentExporter.exportOnsiteReport(serviceCall: job, estimate: nil, invoice: nil,
                payments: [], fieldFormTemplates: [original, revision], fieldFormResponses: [response], includeFinancials: false)
            let text = try #require(PDFDocument(url: url)?.string)
                .split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
            #expect(text.contains("Original check — café"))
            #expect(text.contains("Pass"))
            #expect(!text.contains("completion is not verified"))
            #expect(!text.contains("Recorded field 1"))
            #expect(!text.contains("New unrelated check"))
        }
    }
}
