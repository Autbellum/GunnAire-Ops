import Foundation
import SwiftData

nonisolated struct StaffWorkspaceRecordKey: Hashable, Comparable, Sendable {
    let kind: String
    let id: UUID
    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind ? lhs.id.uuidString < rhs.id.uuidString : lhs.kind < rhs.kind
    }
}

nonisolated enum StaffWorkspaceLinkScope: String, CaseIterable, Hashable, Sendable {
    case customer, technician, vehicle, invoice
}

nonisolated enum StaffWorkspaceLinkError: Error, Equatable {
    case unclassified
    case missing(source: StaffWorkspaceRecordKey, field: String, target: StaffWorkspaceRecordKey)
    case conflictingScope(source: StaffWorkspaceRecordKey, field: String, scope: StaffWorkspaceLinkScope)
    case inconsistent(source: StaffWorkspaceRecordKey, field: String)
    case cycle(kind: String, field: String)
}

/// Every persisted UUID is either a real model reference, a grouping identity,
/// or explicitly retained operation evidence. This is a persistence/lineage
/// contract, not a business-membership grant or safe staff role projection.
@MainActor enum StaffWorkspaceRecordLinks {
    enum Disposition {
        case link(String, Set<StaffWorkspaceLinkScope>)
        case group(StaffWorkspaceLinkScope)
        case evidence(String)
    }

    static func link(_ kind: String, _ scopes: StaffWorkspaceLinkScope...) -> Disposition {
        .link(kind, Set(scopes))
    }

    static var scalar: [String: [String: Disposition]] {
        let operation = Disposition.evidence("Original idempotency/audit operation; not a local model or authorization grant.")
        return [
            "customer": [:], "location": [:], "technician": [:], "item": [:],
            "user": [:], "vendor": [:], "agreement": [:], "timeEntry": [:], "formTemplate": [:],
            "equipment": ["serviceLocationID": link("location", .customer)],
            "job": ["serviceLocationID": link("location", .customer), "customerEquipmentID": link("equipment", .customer),
                "maintenanceAgreementID": link("agreement", .customer), "originatingServiceCallID": link("job", .customer),
                "scheduledFollowUpServiceCallID": link("job", .customer), "linkedEstimateID": link("estimate", .customer),
                "linkedInvoiceID": link("invoice", .customer)],
            "invoice": ["serviceCallID": link("job", .customer), "serviceLocationID": link("location", .customer),
                "projectMilestoneID": link("milestone", .customer)],
            "estimate": ["serviceCallID": link("job", .customer), "serviceLocationID": link("location", .customer),
                "scheduledServiceCallID": link("job", .customer), "parentEstimateID": link("estimate", .customer),
                "proposalGroupID": .group(.customer)],
            "payment": ["collectionAttemptID": .evidence("Original server/payment collection attempt, never a new charge request."),
                "refundedPaymentID": link("payment", .customer, .invoice)],
            "availability": ["creationOperationID": operation, "technicianID": link("technician", .technician),
                "sourceTimeOffRequestID": link("timeOff", .technician), "cancellationOperationID": operation],
            "shift": ["creationOperationID": operation, "technicianID": link("technician", .technician), "retirementOperationID": operation],
            "timeOff": ["creationOperationID": operation, "technicianID": link("technician", .technician),
                "reviewOperationID": operation, "approvedAvailabilityBlockID": link("availability", .technician),
                "withdrawalOperationID": operation, "cancellationOperationID": operation],
            "availabilityEvent": ["operationID": operation, "requestID": link("timeOff", .technician),
                "availabilityBlockID": link("availability", .technician), "technicianID": link("technician", .technician)],
            "attachment": ["serviceCallID": link("job", .customer), "customerEquipmentID": link("equipment", .customer),
                "invoiceID": link("invoice", .customer), "estimateID": link("estimate", .customer),
                "maintenanceContractID": link("agreement", .customer), "fleetVehicleID": link("vehicle", .vehicle),
                "fleetVehicleEventID": link("vehicleEvent", .vehicle), "expenseClaimID": link("expense", .customer)],
            "communication": ["serviceCallID": link("job", .customer), "invoiceID": link("invoice", .customer),
                "estimateID": link("estimate", .customer), "maintenanceContractID": link("agreement", .customer)],
            "purchaseOrder": ["serviceCallID": link("job", .customer)],
            "movement": ["itemID": link("item"), "serviceCallID": link("job", .customer)],
            "request": ["convertedCustomerID": link("customer", .customer), "convertedServiceCallID": link("job", .customer)],
            "activity": ["serviceCallID": link("job", .customer)],
            "milestone": ["projectServiceCallID": link("job", .customer), "estimateID": link("estimate", .customer),
                "scheduledVisitID": link("job", .customer), "invoiceID": link("invoice", .customer)],
            "formResponse": ["serviceCallID": link("job", .customer), "templateID": link("formTemplate")],
            "vehicle": ["assignedTechnicianID": link("technician")],
            "vehicleEvent": ["vehicleID": link("vehicle", .vehicle), "assignmentTechnicianID": link("technician")],
            "expense": ["serviceCallID": link("job", .customer), "customerID": link("customer", .customer),
                "receiptAttachmentID": link("attachment", .customer)],
            "alert": ["creationOperationID": operation, "customerID": link("customer", .customer),
                "serviceLocationID": link("location", .customer), "resolutionOperationID": operation],
            "task": ["creationOperationID": operation, "customerID": link("customer", .customer),
                "serviceLocationID": link("location", .customer), "serviceCallID": link("job", .customer),
                "estimateID": link("estimate", .customer), "completionOperationID": operation, "cancellationOperationID": operation],
            "taskEvent": ["operationID": operation, "taskID": link("task", .customer)],
        ]
    }

    /// Owning SwiftData references remain explicit; no new relationship is
    /// automatically classified by its name or inferred from a display string.
    static var owning: [String: [String: Disposition]] {
        ["location": ["customer": link("customer", .customer)],
         "equipment": ["customer": link("customer", .customer)],
         "job": ["customer": link("customer", .customer), "assignedTechnician": link("technician")],
         "invoice": ["customer": link("customer", .customer)],
         "estimate": ["customer": link("customer", .customer)],
         "payment": ["invoice": link("invoice", .customer, .invoice)],
         "timeEntry": ["serviceCall": link("job", .customer)],
         "agreement": ["customer": link("customer", .customer)],
         "attachment": ["customer": link("customer", .customer)],
         "communication": ["customer": link("customer", .customer)]]
    }

    struct ListLink {
        let kind: String
        let field: String
        let target: String
        let scopes: Set<StaffWorkspaceLinkScope>
    }
    static let lists = [
        ListLink(kind: "job", field: "additionalTechnicianIDsJSON", target: "technician", scopes: []),
        ListLink(kind: "agreement", field: "coveredEquipmentIDsJSON", target: "equipment", scopes: [.customer]),
    ]

    static func validateCoverage() throws {
        let codecs = StaffWorkspaceModelCatalog.all
        let schema = GunnAireModelSchema.schema
        try StaffWorkspaceModelCatalog.validateSchema(schema)
        guard Set(scalar.keys) == Set(codecs.map(\.kind)), Set(owning.keys).isSubset(of: scalar.keys) else {
            throw StaffWorkspaceLinkError.unclassified
        }
        for codec in codecs {
            guard let entity = schema.entities.first(where: { $0.name == codec.modelName }) else { throw StaffWorkspaceLinkError.unclassified }
            let identifiers = Set(entity.attributes.filter {
                $0.valueType == UUID.self || $0.valueType == Optional<UUID>.self
            }.map(\.name)).subtracting(["id"])
            guard identifiers == Set(scalar[codec.kind]!.keys),
                  Set(owning[codec.kind, default: [:]].keys) == Set(codec.references.keys) else { throw StaffWorkspaceLinkError.unclassified }
            for (field, disposition) in owning[codec.kind, default: [:]] {
                guard case .link(let kind, _) = disposition, kind == codec.references[field] else { throw StaffWorkspaceLinkError.unclassified }
            }
            for disposition in scalar[codec.kind]!.values {
                switch disposition {
                case .link(let kind, _): guard scalar[kind] != nil else { throw StaffWorkspaceLinkError.unclassified }
                case .evidence(let reason): guard !reason.isEmpty else { throw StaffWorkspaceLinkError.unclassified }
                case .group: break
                }
            }
        }
        for list in lists {
            guard codecs.first(where: { $0.kind == list.kind })?.fields.contains(list.field) == true,
                  scalar[list.target] != nil else { throw StaffWorkspaceLinkError.unclassified }
        }
    }
}
