import Foundation
import SwiftData

/// Structured interpretation of append-only job activity records used for
/// multi-visit work logging. The existing activity model already has a stable
/// operation ID, job ID, author, timestamp, and CloudKit persistence, so work
/// logs do not need a second mutable notes store or a schema migration.
enum ServiceWorkLogActivityKind: String, Sendable {
    case workPerformed = "Work performed"
    case customerSummaryRevision = "Customer work summary"
}

enum ServiceWorkLogError: LocalizedError, Equatable {
    case missingContent
    case contentTooShort
    case contentTooLong
    case unsupportedControlCharacter

    var errorDescription: String? {
        switch self {
        case .missingContent:
            "Describe the work performed before saving."
        case .contentTooShort:
            "Add enough detail for the next technician and the office to understand the work."
        case .contentTooLong:
            "Keep each entry at 4,000 characters or fewer. Split longer work into separate entries."
        case .unsupportedControlCharacter:
            "Remove unsupported control characters before saving."
        }
    }
}

@MainActor
enum ServiceWorkLogPolicy {
    static let minimumContentLength = 10
    static let maximumContentLength = 4_000

    static func normalizedContent(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func validatedContent(_ value: String) throws -> String {
        let content = normalizedContent(value)
        guard !content.isEmpty else { throw ServiceWorkLogError.missingContent }
        guard content.count >= minimumContentLength else { throw ServiceWorkLogError.contentTooShort }
        guard content.count <= maximumContentLength else { throw ServiceWorkLogError.contentTooLong }

        let permittedControls = CharacterSet(charactersIn: "\n\t")
        let hasUnsupportedControl = content.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar) && !permittedControls.contains(scalar)
        }
        guard !hasUnsupportedControl else { throw ServiceWorkLogError.unsupportedControlCharacter }
        return content
    }

    static func workPerformedEntries(
        for serviceCallID: UUID,
        in activities: [ServiceCallActivity]
    ) -> [ServiceCallActivity] {
        activities
            .filter {
                $0.serviceCallID == serviceCallID &&
                    $0.action == ServiceWorkLogActivityKind.workPerformed.rawValue
            }
            .sorted(by: newestFirst)
    }

    static func customerSummaryRevisions(
        for serviceCallID: UUID,
        in activities: [ServiceCallActivity]
    ) -> [ServiceCallActivity] {
        activities
            .filter {
                $0.serviceCallID == serviceCallID &&
                    $0.action == ServiceWorkLogActivityKind.customerSummaryRevision.rawValue
            }
            .sorted(by: newestFirst)
    }

    static func latestCustomerSummary(
        for call: ServiceCall,
        in activities: [ServiceCallActivity]
    ) -> String? {
        if let revision = customerSummaryRevisions(for: call.id, in: activities).first,
           let content = try? validatedContent(revision.detail) {
            return content
        }
        let persisted = normalizedContent(call.serviceReportSummary ?? "")
        return persisted.isEmpty ? nil : persisted
    }

    /// Produces a deterministic draft only. A technician or office user must
    /// review and save it before it becomes the customer-facing report summary.
    static func suggestedCustomerSummary(from entries: [ServiceCallActivity]) -> String {
        var seen = Set<String>()
        var paragraphs: [String] = []
        let chronologicalEntries = entries.sorted(by: oldestFirst)

        for entry in chronologicalEntries {
            guard let content = try? validatedContent(entry.detail) else { continue }
            let deduplicationKey = content.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard seen.insert(deduplicationKey).inserted else { continue }

            let candidate = (paragraphs + [content]).joined(separator: "\n\n")
            guard candidate.count <= maximumContentLength else { break }
            paragraphs.append(content)
        }
        return paragraphs.joined(separator: "\n\n")
    }

    static func closeoutMissingItem(
        for call: ServiceCall,
        activities: [ServiceCallActivity],
        isRequired: Bool
    ) -> String? {
        guard requiresWorkPerformedLog(for: call.type, whenEnabled: isRequired) else { return nil }
        return workPerformedEntries(for: call.id, in: activities).isEmpty
            ? "Work performed log"
            : nil
    }

    static func operationalCompletionBlockers(
        for call: ServiceCall,
        requireCompletionChecklist: Bool,
        fieldFormTemplates: [FieldFormTemplate],
        fieldFormResponses: [FieldFormResponse],
        activities: [ServiceCallActivity],
        requireWorkPerformedLog: Bool
    ) -> [String] {
        var blockers: [String] = []
        let checklistIsComplete = call.customerNotified &&
            call.arrivalConfirmed &&
            call.workCompletedChecklist &&
            call.documentationChecklist &&
            call.paymentCollectedChecklist
        if requireCompletionChecklist && !checklistIsComplete {
            blockers.append("Completion checklist")
        }

        let fieldForms = FieldFormCloseoutPolicy.readiness(
            serviceCallID: call.id,
            serviceType: call.type,
            templates: fieldFormTemplates,
            responses: fieldFormResponses
        )
        blockers.append(contentsOf: fieldForms.missingRequirements.map(\.closeoutItem))

        if let workLogItem = closeoutMissingItem(
            for: call,
            activities: activities,
            isRequired: requireWorkPerformedLog
        ) {
            blockers.append(workLogItem)
        }
        if !call.canCompleteDocumentation {
            blockers.append("Technical report")
        }

        var seen = Set<String>()
        return blockers.filter { seen.insert($0).inserted }
    }

    static func requiresWorkPerformedLog(
        for serviceType: ServiceCallType,
        whenEnabled isEnabled: Bool
    ) -> Bool {
        guard isEnabled else { return false }
        switch serviceType {
        case .service, .repair, .replacement, .install, .maintenance:
            return true
        case .estimate, .meeting, .reminder, .siteVisit, .other:
            return false
        }
    }

    @discardableResult
    static func recordWorkPerformed(
        _ content: String,
        for call: ServiceCall,
        actorEmail: String?,
        occurredAt: Date = Date(),
        in modelContext: ModelContext
    ) throws -> ServiceCallActivity {
        let validated = try validatedContent(content)
        return ServiceCallActivity.record(
            for: call,
            action: ServiceWorkLogActivityKind.workPerformed.rawValue,
            detail: validated,
            actorEmail: actorEmail,
            occurredAt: occurredAt,
            in: modelContext
        )
    }

    @discardableResult
    static func recordCustomerSummary(
        _ content: String,
        for call: ServiceCall,
        actorEmail: String?,
        occurredAt: Date = Date(),
        in modelContext: ModelContext
    ) throws -> ServiceCallActivity {
        let validated = try validatedContent(content)
        call.serviceReportSummary = validated
        return ServiceCallActivity.record(
            for: call,
            action: ServiceWorkLogActivityKind.customerSummaryRevision.rawValue,
            detail: validated,
            actorEmail: actorEmail,
            occurredAt: occurredAt,
            in: modelContext
        )
    }

    static func actorDisplayName(_ actorEmail: String?) -> String? {
        let normalized = AppAccess.normalizedEmail(actorEmail)
        guard !normalized.isEmpty else { return nil }
        return AppAccess.inferredDisplayName(fromEmail: normalized)
    }

    private static func newestFirst(_ lhs: ServiceCallActivity, _ rhs: ServiceCallActivity) -> Bool {
        if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt > rhs.occurredAt }
        return lhs.id.uuidString > rhs.id.uuidString
    }

    private static func oldestFirst(_ lhs: ServiceCallActivity, _ rhs: ServiceCallActivity) -> Bool {
        if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
