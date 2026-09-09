import Foundation
import SwiftData

/// Complete explicit model-reference preflight, not full domain validity or
/// tenant authorization. Nested billing/approval JSON, financial semantics, role
/// projection, content delivery and an authenticated store lease remain gates.
@MainActor struct StaffWorkspaceRelationshipGraph {
    typealias Key = StaffWorkspaceRecordKey
    private let records: [Key: StaffWorkspaceModelRecord]

    private final class Components {
        private var parents: [String: String] = [:]
        private var anchors: [String: UUID] = [:]
        func root(_ key: String) -> String {
            var current = key
            while let parent = parents[current], parent != current { current = parent }
            var child = key
            while let parent = parents[child], parent != current {
                parents[child] = current; child = parent
            }
            return current
        }
        func anchor(_ key: String, id: UUID) { anchors[key] = id }
        func join(_ lhs: String, _ rhs: String) -> Bool {
            let left = root(lhs), right = root(rhs)
            if left == right { return true }
            if let a = anchors[left], let b = anchors[right], a != b { return false }
            parents[right] = left
            anchors[left] = anchors[left] ?? anchors[right]
            anchors.removeValue(forKey: right)
            return true
        }
    }

    static func validate(_ input: [StaffWorkspaceModelRecord]) throws -> Self {
        guard input.count <= 20_000, try JSONEncoder().encode(input).count <= 32 * 1024 * 1024 else {
            throw StaffWorkspaceModelError.invalid
        }
        try StaffWorkspaceRecordLinks.validateCoverage()
        try StaffWorkspaceDiscriminators.validateCoverage()
        let codecs = Dictionary(uniqueKeysWithValues: StaffWorkspaceModelCatalog.all.map { ($0.kind, $0) })
        let discriminatorRules = StaffWorkspaceDiscriminators.rules
        var records: [Key: StaffWorkspaceModelRecord] = [:]
        for record in input {
            let key = Key(kind: record.kind, id: record.id)
            guard let codec = codecs[record.kind], records[key] == nil else { throw StaffWorkspaceModelError.invalid }
            try codec.validate(record)
            try StaffWorkspaceDiscriminators.validate(record, using: discriminatorRules[record.kind]!)
            records[key] = record
        }
        let graph = Self(records: records)
        let components = Dictionary(uniqueKeysWithValues: StaffWorkspaceLinkScope.allCases.map { ($0, Components()) })
        func node(_ key: Key) -> String { key.kind + ":" + key.id.uuidString }
        for key in records.keys {
            if let scope = StaffWorkspaceLinkScope(rawValue: key.kind) { components[scope]!.anchor(node(key), id: key.id) }
        }
        func join(_ source: Key, field: String, target: Key, scopes: Set<StaffWorkspaceLinkScope>) throws {
            guard records[target] != nil else { throw StaffWorkspaceLinkError.missing(source: source, field: field, target: target) }
            for scope in scopes.sorted(by: { $0.rawValue < $1.rawValue }) {
                guard components[scope]!.join(node(source), node(target)) else {
                    throw StaffWorkspaceLinkError.conflictingScope(source: source, field: field, scope: scope)
                }
            }
        }
        for key in records.keys.sorted() {
            let record = records[key]!
            let dispositions = StaffWorkspaceRecordLinks.scalar[key.kind]!.merging(StaffWorkspaceRecordLinks.owning[key.kind, default: [:]]) { first, _ in first }
            for field in dispositions.keys.sorted() {
                guard let value = record.fields[field] else { throw StaffWorkspaceModelError.incomplete }
                if value == .null { continue }
                let id = try UUID.fromStaffValue(value)
                switch dispositions[field]! {
                case .link(let target, let scopes): try join(key, field: field, target: Key(kind: target, id: id), scopes: scopes)
                case .group(let scope):
                    guard components[scope]!.join(node(key), "group:" + key.kind + ":" + field + ":" + id.uuidString) else {
                        throw StaffWorkspaceLinkError.conflictingScope(source: key, field: field, scope: scope)
                    }
                case .evidence: break
                }
            }
            for list in StaffWorkspaceRecordLinks.lists where list.kind == key.kind {
                let ids = try graph.identifiers(record, field: list.field)
                if key.kind == "job", let lead = try graph.identifier(record, field: "assignedTechnician"), ids.contains(lead) {
                    throw StaffWorkspaceLinkError.inconsistent(source: key, field: list.field)
                }
                for id in ids { try join(key, field: list.field, target: Key(kind: list.target, id: id), scopes: list.scopes) }
            }
        }
        try graph.validateOriginalLinks()
        try graph.rejectCycles(kind: "job", field: "originatingServiceCallID")
        try graph.rejectCycles(kind: "job", field: "scheduledFollowUpServiceCallID")
        try graph.rejectCycles(kind: "estimate", field: "parentEstimateID")
        try graph.rejectCycles(kind: "payment", field: "refundedPaymentID")
        return graph
    }

    var recordCount: Int { records.count }

    /// Useful for a future full-domain import/review only after its independent
    /// tenant, nested-value, role and store-lease checks. No existing context is
    /// accepted and no credential, file content, approval or payment is issued.
    func decodeDetached() throws -> [any PersistentModel] {
        try StaffWorkspaceModelCatalog.decodeDetached(records.keys.sorted().map { records[$0]! })
    }

    static func captureSaved(in context: ModelContext) throws -> Self {
        guard !context.hasChanges else { throw StaffWorkspaceModelError.invalid }
        let records = try StaffWorkspaceModelCatalog.all.flatMap { try $0.readSavedRecords(context) }
        guard !context.hasChanges else { throw StaffWorkspaceModelError.invalid }
        return try validate(records)
    }

    private func identifier(_ record: StaffWorkspaceModelRecord, field: String) throws -> UUID? {
        guard let value = record.fields[field] else { throw StaffWorkspaceModelError.incomplete }
        return value == .null ? nil : try UUID.fromStaffValue(value)
    }

    private func identifiers(_ record: StaffWorkspaceModelRecord, field: String) throws -> [UUID] {
        guard let value = record.fields[field] else { throw StaffWorkspaceModelError.incomplete }
        if value == .null { return [] }
        let text = try String.fromStaffValue(value)
        guard text.utf8.count <= 1_048_576 else { throw StaffWorkspaceLinkError.inconsistent(source: .init(kind: record.kind, id: record.id), field: field) }
        let ids: [UUID]
        do { ids = try JSONDecoder().decode([UUID].self, from: Data(text.utf8)) }
        catch { throw StaffWorkspaceLinkError.inconsistent(source: .init(kind: record.kind, id: record.id), field: field) }
        guard ids.count <= 20_000, Set(ids).count == ids.count else {
            throw StaffWorkspaceLinkError.inconsistent(source: .init(kind: record.kind, id: record.id), field: field)
        }
        return ids
    }

    private func rejectCycles(kind: String, field: String) throws {
        var complete = Set<UUID>()
        for key in records.keys.filter({ $0.kind == kind }).sorted() where !complete.contains(key.id) {
            var path = Set<UUID>(), next: UUID? = key.id
            while let id = next, !complete.contains(id) {
                guard path.insert(id).inserted else { throw StaffWorkspaceLinkError.cycle(kind: kind, field: field) }
                guard let record = records[Key(kind: kind, id: id)] else { throw StaffWorkspaceModelError.relationships }
                next = try identifier(record, field: field)
            }
            complete.formUnion(path)
        }
    }

    private func validateOriginalLinks() throws {
        func requireMatchingBacklink(_ record: StaffWorkspaceModelRecord, _ field: String, kind: String, backlink: String) throws {
            guard let id = try identifier(record, field: field), let target = records[Key(kind: kind, id: id)] else { return }
            if let back = try identifier(target, field: backlink), back != record.id {
                throw StaffWorkspaceLinkError.inconsistent(source: Key(kind: record.kind, id: record.id), field: field)
            }
        }
        for key in records.keys.sorted() {
            let record = records[key]!
            switch key.kind {
            case "job":
                try requireMatchingBacklink(record, "scheduledFollowUpServiceCallID", kind: "job", backlink: "originatingServiceCallID")
                try requireMatchingBacklink(record, "linkedInvoiceID", kind: "invoice", backlink: "serviceCallID")
                if let id = try identifier(record, field: "linkedEstimateID"), let estimate = records[Key(kind: "estimate", id: id)] {
                    guard try EstimateJobLineage.matches(jobID: record.id,
                        diagnosticJobID: identifier(estimate, field: "serviceCallID"),
                        scheduledJobID: identifier(estimate, field: "scheduledServiceCallID")) else {
                        throw StaffWorkspaceLinkError.inconsistent(source: key, field: "linkedEstimateID")
                    }
                }
            case "timeOff": try requireMatchingBacklink(record, "approvedAvailabilityBlockID", kind: "availability", backlink: "sourceTimeOffRequestID")
            case "availability": try requireMatchingBacklink(record, "sourceTimeOffRequestID", kind: "timeOff", backlink: "approvedAvailabilityBlockID")
            case "expense": try requireMatchingBacklink(record, "receiptAttachmentID", kind: "attachment", backlink: "expenseClaimID")
            case "milestone": try requireMatchingBacklink(record, "invoiceID", kind: "invoice", backlink: "projectMilestoneID")
            case "payment":
                if let originalID = try identifier(record, field: "refundedPaymentID"), let original = records[Key(kind: "payment", id: originalID)] {
                    guard record.fields["isRefund"] == .flag(true), original.fields["isRefund"] == .flag(false) else {
                        throw StaffWorkspaceLinkError.inconsistent(source: key, field: "refundedPaymentID")
                    }
                }
            default: break
            }
        }
    }
}
