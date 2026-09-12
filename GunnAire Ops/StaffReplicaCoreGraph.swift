import Foundation

/// Typed, relationship-complete import boundary for core-field-v1. This schema
/// is not the full operational store. Never infer absent business domains empty.
struct StaffReplicaCoreGraph {
    struct Record: Equatable {
        let kind: String
        let id: String
        let revision: Int
        let fields: [String: StaffReplicaScalar]
        func text(_ name: String) -> String? { if case .text(let value) = fields[name] { return value }; return nil }
        func flag(_ name: String) -> Bool? { if case .flag(let value) = fields[name] { return value }; return nil }
        func ids(_ name: String) -> [String] { if case .identifiers(let value) = fields[name] { return value }; return [] }
    }
    let records: [Record]
    // Explicit counterpart of Backend/staff_replica_contract.py. No model dumps,
    // unknown properties, purchasing-margin leak or generic nested JSON fallback.
    static let specs: [String: (String, String)] = [
        "customer": ("name:s", "phone:s email:s address:s allowsTransactionalEmail:b allowsServiceText:b preferredContactMethod:s"),
        "location": ("customerID:id name:s address:s isActive:b", "contactName:s contactPhone:s accessNotes:note isPrimary:b"),
        "equipment": ("customerID:id name:s isActive:b", "serviceLocationID:id equipmentType:s manufacturer:s modelNumber:s serialNumber:s location:s installDate:date warrantyExpiration:date filterSize:s notes:note"),
        "technician": ("name:s isActive:b", "email:email phone:s"),
        "job": ("customerID:id type:s scheduledDate:date duration:number status:s assignedTechnicianIDs:ids", "eventTitle:s siteAddress:s serviceLocationID:id customerEquipmentID:id notes:note findingsSummary:note recommendedWorkSummary:note dispatchUrgency:s promisedArrivalWindowStart:date promisedArrivalWindowEnd:date followUpRequired:b followUpAction:note followUpDueDate:date visitDisposition:s visitDispositionNotes:note originatingServiceCallID:id scheduledFollowUpServiceCallID:id cancellationReason:note cancelledAt:date technicianEnRouteAt:date technicianArrivedAt:date"),
        "item": ("name:s itemType:s unitPrice:money isTaxable:b reviewStatus:s", "description:note sku:s createdByEmail:email purchaseCost:money vendorPartNumber:s quickBooksID:s")
    ]
    private static func spec(_ text: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: text.split(separator: " ").map { value in
            let pair = value.split(separator: ":"); return (String(pair[0]), String(pair[1]))
        })
    }
    private static func scalar(_ value: Any, type: String) throws -> StaffReplicaScalar {
        switch type {
        case "b":
            guard let number = value as? NSNumber, String(cString: number.objCType) == "c" else { throw StaffReplicaDeliveryError.invalid }
            return .flag(number.boolValue)
        case "number", "money":
            guard let number = value as? NSNumber, String(cString: number.objCType) != "c", number.doubleValue.isFinite,
                  (0...1_000_000_000).contains(number.doubleValue) else { throw StaffReplicaDeliveryError.invalid }
            return .number(number.doubleValue)
        case "ids":
            guard let ids = value as? [String], ids.count <= 100, ids == Array(Set(ids)).sorted(),
                  ids.allSatisfy(CloudKitStaffSetupPolicy.canonicalID) else { throw StaffReplicaDeliveryError.invalid }
            return .identifiers(ids)
        default:
            guard let text = value as? String, text.utf8.count <= (type == "note" ? 16_384 : 2048),
                  !text.unicodeScalars.contains(where: { ($0.value < 32 && ![9, 10, 13].contains($0.value)) || $0.value == 127 }) else {
                throw StaffReplicaDeliveryError.invalid
            }
            if type == "id", !CloudKitStaffSetupPolicy.canonicalID(text) { throw StaffReplicaDeliveryError.invalid }
            if type == "email", !SharedTimeError.validEmail(text) { throw StaffReplicaDeliveryError.invalid }
            if type == "date", CompanyWorkspaceClock.parse(text) == nil { throw StaffReplicaDeliveryError.invalid }
            return .text(text)
        }
    }
    init(payload: StaffReplicaVerifiedPayload, plan: CloudKitStaffSharePlan, workspace: CompanyWorkspaceIdentity, now: Date = Date()) throws {
        try payload.manifest.validate(plan: plan, workspace: workspace, now: now)
        guard payload.manifest.membershipID == plan.id, payload.manifest.memberRevision == plan.memberRevision,
              payload.manifest.projectionPolicy == plan.projectionPolicy,
              let root = try JSONSerialization.jsonObject(with: payload.bytes) as? [String: Any],
              let raw = root["records"] as? [[String: Any]], let role = AppUserRole(rawValue: plan.memberRole) else {
            throw StaffReplicaDeliveryError.invalid
        }
        records = try raw.map { object in
            guard let kind = object["kind"] as? String, let id = object["id"] as? String,
                  let revision = object["revision"] as? Int, let fields = object["fields"] as? [String: Any],
                  let specification = Self.specs[kind] else { throw StaffReplicaDeliveryError.invalid }
            let required = Self.spec(specification.0), allowed = required.merging(Self.spec(specification.1)) { a, _ in a }
            guard Set(required.keys).isSubset(of: Set(fields.keys)), Set(fields.keys).isSubset(of: Set(allowed.keys)),
                  try JSONSerialization.data(withJSONObject: fields).count <= 64 * 1024 else { throw StaffReplicaDeliveryError.invalid }
            var parsed: [String: StaffReplicaScalar] = [:]
            for (name, value) in fields {
                if value is NSNull, required[name] == nil { continue }
                parsed[name] = try Self.scalar(value, type: allowed[name]!)
            }
            let result = Record(kind: kind, id: id, revision: revision, fields: parsed)
            if required["name"] != nil, result.text("name")?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                throw StaffReplicaDeliveryError.invalid
            }
            if kind == "item" {
                guard ["approved", "needs_review", "archived"].contains(result.text("reviewStatus") ?? ""),
                      role == .admin || fields["purchaseCost"] == nil else { throw StaffReplicaDeliveryError.access }
            }
            return result
        }
        guard records.count == payload.manifest.recordCount else { throw StaffReplicaDeliveryError.invalid }
        try validateRelationshipsAndRole(plan, role: role)
    }
    private func validateRelationshipsAndRole(_ plan: CloudKitStaffSharePlan, role: AppUserRole) throws {
        if role == .standard || role == .accounting {
            guard records.isEmpty else { throw StaffReplicaDeliveryError.access }; return
        }
        let lookup = Dictionary(uniqueKeysWithValues: records.map { ($0.kind + ":" + $0.id, $0) })
        let jobs = records.filter { $0.kind == "job" }
        for record in records {
            for (name, target) in [("customerID", "customer"), ("serviceLocationID", "location"), ("customerEquipmentID", "equipment")] {
                guard let id = record.text(name) else { continue }
                guard let parent = lookup[target + ":" + id], target == "customer" || parent.text("customerID") == record.text("customerID") else {
                    throw StaffReplicaDeliveryError.invalid
                }
            }
            if record.kind == "job" {
                guard record.ids("assignedTechnicianIDs").allSatisfy({ lookup["technician:" + $0] != nil }) else { throw StaffReplicaDeliveryError.invalid }
                for name in ["originatingServiceCallID", "scheduledFollowUpServiceCallID"] {
                    if let id = record.text(name), lookup["job:" + id] == nil { throw StaffReplicaDeliveryError.invalid }
                }
                if let id = record.text("customerEquipmentID"), let equipment = lookup["equipment:" + id],
                   let property = equipment.text("serviceLocationID"), let jobProperty = record.text("serviceLocationID"), property != jobProperty {
                    throw StaffReplicaDeliveryError.invalid
                }
            }
        }
        guard role == .fieldTechnician else { return }
        let own = records.filter { $0.kind == "technician" && $0.text("email") == plan.memberEmail && $0.flag("isActive") == true }
        guard own.count == 1, jobs.allSatisfy({ $0.ids("assignedTechnicianIDs").contains(own[0].id) }) else { throw StaffReplicaDeliveryError.access }
        let customers = Set(jobs.compactMap { $0.text("customerID") })
        let directEquipment = Set(jobs.compactMap { $0.text("customerEquipmentID") })
        let properties = Set(jobs.compactMap { $0.text("serviceLocationID") }).union(
            records.filter { $0.kind == "equipment" && directEquipment.contains($0.id) }.compactMap { $0.text("serviceLocationID") })
        let crew = Set(jobs.flatMap { $0.ids("assignedTechnicianIDs") }).union(own.map(\.id))
        for record in records {
            let allowed: Bool
            switch record.kind {
            case "customer": allowed = customers.contains(record.id)
            case "location": allowed = properties.contains(record.id)
            case "equipment": allowed = directEquipment.contains(record.id) || (customers.contains(record.text("customerID") ?? "") && properties.contains(record.text("serviceLocationID") ?? ""))
            case "technician": allowed = crew.contains(record.id)
            case "item": allowed = ["approved", "archived"].contains(record.text("reviewStatus") ?? "") || record.text("createdByEmail") == plan.memberEmail
            case "job": allowed = true
            default: allowed = false
            }
            guard allowed else { throw StaffReplicaDeliveryError.access }
        }
    }
}
