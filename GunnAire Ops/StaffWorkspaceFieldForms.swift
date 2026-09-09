import Foundation

/// Reject unsupported or internally inconsistent field evidence before a
/// detached full-workspace projection. Owner codecs remain lossless; this does
/// not publish records, grant access, complete a job or issue a file URL.
enum StaffWorkspaceFieldForms {
    static func validate(_ records: [StaffWorkspaceModelRecord]) throws {
        var templates: [UUID: (title: String, questions: [FieldFormQuestion])] = [:]
        func text(_ record: StaffWorkspaceModelRecord, _ name: String) throws -> String {
            guard let value = record.fields[name] else { throw StaffWorkspaceModelError.incomplete }
            return try String.fromStaffValue(value)
        }
        for record in records where record.kind == "formTemplate" {
            guard templates[record.id] == nil else { throw StaffWorkspaceModelError.invalid }
            let title = try text(record, "title")
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let assignment = record.fields["applicableServiceTypesJSON"] else { throw StaffWorkspaceModelError.invalid }
            _ = try FieldFormPayload.assignment(assignment == .null ? nil : String.fromStaffValue(assignment))
            templates[record.id] = (title, try FieldFormPayload.questions(text(record, "questionsJSON")))
        }
        for record in records where record.kind == "formResponse" {
            guard let rawID = record.fields["templateID"],
                  let original = templates[try UUID.fromStaffValue(rawID)],
                  original.title == (try text(record, "templateTitle")) else { throw StaffWorkspaceModelError.invalid }
            let payload = try FieldFormPayload.response(text(record, "answersJSON"))
            try FieldFormPayload.validate(payload, against: original.questions)
        }
    }
}
