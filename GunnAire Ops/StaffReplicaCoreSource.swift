import Foundation
import SwiftData

/// Deliberately no generic object/dictionary case: a model or provider payload
/// cannot be accidentally serialized through a scalar operational field.
enum StaffReplicaScalar: Codable, Equatable {
    case text(String), number(Double), flag(Bool), identifiers([String])

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let result = try? value.decode(Bool.self) { self = .flag(result) }
        else if let result = try? value.decode(String.self) { self = .text(result) }
        else if let result = try? value.decode(Double.self), result.isFinite { self = .number(result) }
        else { self = .identifiers(try value.decode([String].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .text(let result): try value.encode(result)
        case .number(let result): try value.encode(result)
        case .flag(let result): try value.encode(result)
        case .identifiers(let result): try value.encode(result)
        }
    }
}

struct StaffReplicaCoreRecord: Codable, Equatable {
    let kind: String
    let id: String
    let fields: [String: StaffReplicaScalar]
}

enum StaffReplicaSourceError: Error, LocalizedError {
    case access, unsaved, relationships, invalid
    var errorDescription: String? {
        switch self {
        case .access: "Verify the approved owner workspace before preparing staff data."
        case .unsaved: "Finish saving the current work before preparing a staff snapshot."
        case .relationships: "Related customer, property or crew records are still incomplete. No partial snapshot was prepared."
        case .invalid: "An operational record needs review before it can be shared. Its original data was retained."
        }
    }
}

/// Coverage is not the full business schema. This captures saved core-field
/// facts for the server's role-filtered ledger; it neither publishes a snapshot
/// nor mounts a staff store. Billing, forms, media, agreements, time, tasks and
/// financial workflows require their own explicit serializers before activation.
struct StaffReplicaCoreSource: Encodable, Equatable {
    static let schemaVersion = "core-field-v1"
    static let recordKinds = ["customer", "equipment", "item", "job", "location", "technician"]
    let schema: String
    let coverage: [String]
    let records: [StaffReplicaCoreRecord]

    static func captureSavedOwner() async throws -> (CompanyCloudKitBinding, Self) {
        let access = CompanyWorkspaceAccessController.shared
        guard !GunnAireCloudKit.usesTestDatabase, let stamp = access.operationStamp,
              access.verifiedRole == .admin, let container = access.authorizedContainer else { throw StaffReplicaSourceError.access }
        let response = try await GunnAireBackendService.fetchCompanyWorkspace()
        guard access.operationStamp == stamp, access.verifiedRole == .admin else { throw StaffReplicaSourceError.access }
        let account = try await CompanyCloudKitRuntimeAccount.current()
        guard access.operationStamp == stamp, access.verifiedRole == .admin, response.user.isActive,
              response.user.email == stamp.session.email, response.user.role == AppUserRole.admin.rawValue,
              let binding = response.workspace.binding(for: account.environment),
              binding.cloudAccountHash == account.accountHash, binding.companyID == access.verifiedCompanyID else {
            throw StaffReplicaSourceError.access
        }
        guard !container.mainContext.hasChanges else { throw StaffReplicaSourceError.unsaved }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let value = try capture(customers: context.fetch(FetchDescriptor<Customer>()), locations: context.fetch(FetchDescriptor<CustomerServiceLocation>()),
                                equipment: context.fetch(FetchDescriptor<CustomerEquipment>()), technicians: context.fetch(FetchDescriptor<Technician>()),
                                jobs: context.fetch(FetchDescriptor<ServiceCall>()), items: context.fetch(FetchDescriptor<Item>()))
        guard access.operationStamp == stamp, access.verifiedRole == .admin, !container.mainContext.hasChanges else { throw StaffReplicaSourceError.access }
        return (binding, value)
    }

    static func capture(customers: [Customer], locations: [CustomerServiceLocation], equipment: [CustomerEquipment],
                        technicians: [Technician], jobs: [ServiceCall], items: [Item]) throws -> Self {
        var records: [StaffReplicaCoreRecord] = []
        func append(_ kind: String, _ id: UUID, _ fields: [String: StaffReplicaScalar]) throws {
            guard case .text(let name) = fields["name"] ?? .text(kind), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StaffReplicaSourceError.invalid }
            for value in fields.values {
                switch value {
                case .number(let number): guard number.isFinite, (0...1_000_000_000).contains(number) else { throw StaffReplicaSourceError.invalid }
                case .text(let text):
                    guard text.utf8.count <= 16_384, !text.unicodeScalars.contains(where: { ($0.value < 32 && ![9, 10, 13].contains($0.value)) || $0.value == 127 }) else { throw StaffReplicaSourceError.invalid }
                case .identifiers(let ids):
                    guard ids.count <= 100, ids == Array(Set(ids)).sorted(), ids.allSatisfy(CloudKitStaffSetupPolicy.canonicalID) else { throw StaffReplicaSourceError.invalid }
                case .flag: break
                }
            }
            let record = StaffReplicaCoreRecord(kind: kind, id: id.uuidString.lowercased(), fields: fields)
            guard try JSONEncoder().encode(record).count <= 64 * 1024 else { throw StaffReplicaSourceError.invalid }
            records.append(record)
        }
        func text(_ fields: inout [String: StaffReplicaScalar], _ name: String, _ value: String?) { if let value { fields[name] = .text(value) } }
        func identifier(_ fields: inout [String: StaffReplicaScalar], _ name: String, _ value: UUID?) { text(&fields, name, value?.uuidString.lowercased()) }
        func date(_ fields: inout [String: StaffReplicaScalar], _ name: String, _ value: Date?) throws {
            if let value {
                guard value.timeIntervalSince1970.isFinite else { throw StaffReplicaSourceError.invalid }
                let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let string = formatter.string(from: value)
                guard CompanyWorkspaceClock.parse(string) != nil else { throw StaffReplicaSourceError.invalid }
                fields[name] = .text(string)
            }
        }
        for customer in customers {
            var fields: [String: StaffReplicaScalar] = ["name": .text(customer.name), "allowsTransactionalEmail": .flag(customer.allowsTransactionalEmail),
                "allowsServiceText": .flag(customer.allowsServiceText), "preferredContactMethod": .text(customer.preferredContactMethod.rawValue)]
            text(&fields, "phone", customer.phone); text(&fields, "email", customer.email); text(&fields, "address", customer.address)
            try append("customer", customer.id, fields)
        }
        for location in locations {
            guard let customer = location.customer else { throw StaffReplicaSourceError.relationships }
            var fields: [String: StaffReplicaScalar] = ["customerID": .text(customer.id.uuidString.lowercased()), "name": .text(location.name),
                "address": .text(location.address), "isActive": .flag(location.isActive), "isPrimary": .flag(location.isPrimary)]
            text(&fields, "contactName", location.contactName); text(&fields, "contactPhone", location.contactPhone); text(&fields, "accessNotes", location.accessNotes)
            try append("location", location.id, fields)
        }
        for value in equipment {
            guard let customer = value.customer else { throw StaffReplicaSourceError.relationships }
            var fields: [String: StaffReplicaScalar] = ["customerID": .text(customer.id.uuidString.lowercased()), "name": .text(value.name), "isActive": .flag(value.isActive)]
            identifier(&fields, "serviceLocationID", value.serviceLocationID); text(&fields, "equipmentType", value.equipmentTypeRaw)
            text(&fields, "manufacturer", value.manufacturer); text(&fields, "modelNumber", value.modelNumber); text(&fields, "serialNumber", value.serialNumber)
            text(&fields, "location", value.location); text(&fields, "filterSize", value.filterSize); text(&fields, "notes", value.notes)
            try date(&fields, "installDate", value.installDate); try date(&fields, "warrantyExpiration", value.warrantyExpiration)
            try append("equipment", value.id, fields)
        }
        for technician in technicians {
            // Profiles have no persisted active flag. Business membership stays
            // authoritative on the server; a phone-only legacy profile grants no account access.
            var fields: [String: StaffReplicaScalar] = ["name": .text(technician.name), "isActive": .flag(true)]
            let email = AppAccess.normalizedEmail(technician.contactInfo)
            if SharedTimeError.validEmail(email) { fields["email"] = .text(email) }
            else { text(&fields, "phone", technician.contactInfo) }
            try append("technician", technician.id, fields)
        }
        for job in jobs {
            guard let customer = job.customer else { throw StaffReplicaSourceError.relationships }
            var crew = Set<UUID>()
            if let raw = job.additionalTechnicianIDsJSON {
                guard let data = raw.data(using: .utf8), let strings = try? JSONDecoder().decode([String].self, from: data),
                      strings.allSatisfy({ UUID(uuidString: $0) != nil }), Set(strings.compactMap(UUID.init(uuidString:))).count == strings.count else { throw StaffReplicaSourceError.relationships }
                crew = Set(strings.compactMap(UUID.init(uuidString:)))
            }
            if let lead = job.assignedTechnician { crew.insert(lead.id) }
            var fields: [String: StaffReplicaScalar] = ["customerID": .text(customer.id.uuidString.lowercased()), "type": .text(job.type.rawValue),
                "duration": .number(job.duration), "status": .text(job.status.rawValue), "assignedTechnicianIDs": .identifiers(crew.map { $0.uuidString.lowercased() }.sorted()),
                "dispatchUrgency": .text(job.dispatchUrgencyRaw), "followUpRequired": .flag(job.followUpRequired), "visitDisposition": .text(job.visitDispositionRaw)]
            identifier(&fields, "serviceLocationID", job.serviceLocationID); identifier(&fields, "customerEquipmentID", job.customerEquipmentID)
            identifier(&fields, "originatingServiceCallID", job.originatingServiceCallID); identifier(&fields, "scheduledFollowUpServiceCallID", job.scheduledFollowUpServiceCallID)
            text(&fields, "eventTitle", job.eventTitle); text(&fields, "siteAddress", job.siteAddress); text(&fields, "notes", job.notes)
            text(&fields, "findingsSummary", job.findingsSummary); text(&fields, "recommendedWorkSummary", job.recommendedWorkSummary)
            text(&fields, "followUpAction", job.followUpAction); text(&fields, "visitDispositionNotes", job.visitDispositionNotes); text(&fields, "cancellationReason", job.cancellationReason)
            try date(&fields, "scheduledDate", job.scheduledDate); try date(&fields, "promisedArrivalWindowStart", job.promisedArrivalWindowStart)
            try date(&fields, "promisedArrivalWindowEnd", job.promisedArrivalWindowEnd); try date(&fields, "followUpDueDate", job.followUpDueDate)
            try date(&fields, "cancelledAt", job.cancelledAt); try date(&fields, "technicianEnRouteAt", job.technicianEnRouteAt); try date(&fields, "technicianArrivedAt", job.technicianArrivedAt)
            try append("job", job.id, fields)
        }
        for item in items {
            var fields: [String: StaffReplicaScalar] = ["name": .text(item.name), "itemType": .text(item.itemType.rawValue), "unitPrice": .number(item.unitPrice),
                "isTaxable": .flag(item.isTaxable), "reviewStatus": .text(item.pricebookReviewStatus.rawValue)]
            if let cost = item.purchaseCost { fields["purchaseCost"] = .number(cost) }
            text(&fields, "description", item.itemDescription); text(&fields, "sku", item.sku); text(&fields, "vendorPartNumber", item.vendorPartNumber)
            text(&fields, "quickBooksID", item.quickBooksID); text(&fields, "createdByEmail", item.pricebookCreatedByEmail)
            try append("item", item.id, fields)
        }
        guard Set(records.map { $0.kind + ":" + $0.id }).count == records.count else { throw StaffReplicaSourceError.invalid }
        return .init(schema: schemaVersion, coverage: recordKinds, records: records.sorted { ($0.kind, $0.id) < ($1.kind, $1.id) })
    }
}
