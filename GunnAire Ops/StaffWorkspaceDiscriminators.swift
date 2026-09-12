import Foundation

nonisolated enum StaffWorkspaceDiscriminatorError: Error, Equatable {
    case unclassified
    // Do not include the saved value, customer details or provider credentials.
    case unrecognized(source: StaffWorkspaceRecordKey, field: String)
}

/// Checks saved discriminators before a full-domain graph is reconstructed.
/// A model getter's fallback is not permission to reinterpret an unknown value.
/// The owner persistence codecs remain lossless so rejected records can be
/// retained and reviewed. This is not nested-envelope/financial validation,
/// role projection, tenant authority, or permission to activate a staff store.
@MainActor enum StaffWorkspaceDiscriminators {
    enum Rule {
        case text((String) -> Bool)
        case integer((Int) -> Bool)
        case lines((String) -> Bool)

        func accepts(_ value: StaffWorkspaceValue) -> Bool {
            // Required-null rejection belongs to the actual model codec.
            if value == .null { return true }
            switch (self, value) {
            case (.text(let check), .text(let text)): return check(text)
            case (.integer(let check), .integer(let number)): return check(number)
            case (.lines(let check), .text(let text)):
                // Empty is a real recorded empty set, not a malformed value to
                // replace with nil. Never trim, deduplicate, or drop bad entries.
                if text.isEmpty { return true }
                let values = text.components(separatedBy: "\n")
                return values.count <= 20_000 && Set(values).count == values.count && values.allSatisfy(check)
            default: return false
            }
        }
    }

    private static func raw<T: RawRepresentable>(_ type: T.Type) -> Rule where T.RawValue == String {
        .text { T(rawValue: $0) != nil }
    }

    /// Explicitly inventories every kind, including kinds with no persisted
    /// raw discriminator. Source-schema coverage catches a new unclassified Raw
    /// field; known discriminator names without Raw are listed explicitly too.
    static let rules: [String: [String: Rule]] = [
            "customer": ["preferredContactMethodRaw": raw(CustomerContactMethod.self)],
            "location": [:],
            "equipment": ["equipmentTypeRaw": raw(HVACEquipmentType.self)],
            "technician": ["quickBooksTimeEntityKindRawValue": raw(TechnicianQuickBooksTimeEntityKind.self)],
            "item": ["itemTypeRawValue": raw(CatalogItemType.self),
                     "pricebookReviewStatusRawValue": raw(PricebookReviewStatus.self)],
            "job": ["type": raw(ServiceCallType.self), "status": raw(JobStatus.self),
                    "dispatchUrgencyRaw": raw(ServiceRequestUrgency.self),
                    "visitDispositionRaw": raw(ServiceVisitDisposition.self),
                    "equipmentTypeRaw": raw(HVACEquipmentType.self),
                    "correctiveWorkReasonRaw": raw(CorrectiveWorkReason.self)],
            "invoice": ["workTypeRaw": raw(InvoiceWorkType.self),
                        "taxCalculationStatusRawValue": raw(BillingTaxCalculationStatus.self)],
            "estimate": ["proposalOption": raw(EstimateProposalOption.self),
                         "customerApprovalMethodRaw": raw(EstimateApprovalMethod.self),
                         "taxCalculationStatusRawValue": raw(BillingTaxCalculationStatus.self)],
            "payment": [:],
            "user": ["roleRawValue": raw(AppUserRole.self)],
            "availability": ["kindRawValue": raw(TechnicianAvailabilityKind.self)],
            "shift": ["weekdayRawValue": .integer { TechnicianWeekday(rawValue: $0) != nil },
                      "kindRawValue": raw(TechnicianWorkShiftKind.self)],
            "timeOff": ["statusRawValue": raw(TechnicianTimeOffStatus.self)],
            "availabilityEvent": ["kindRawValue": raw(TechnicianAvailabilityEventKind.self),
                                  "requestStatusRawSnapshot": raw(TechnicianTimeOffStatus.self)],
            "timeEntry": ["reviewStatusRawValue": raw(TimeEntryReviewStatus.self)],
            "agreement": [:],
            "request": ["requestedServiceTypeRaw": raw(ServiceCallType.self),
                        "urgencyRaw": raw(ServiceRequestUrgency.self), "statusRaw": raw(ServiceRequestStatus.self)],
            "activity": [:],
            "milestone": ["billingTriggerRaw": raw(ProjectBillingTrigger.self), "statusRaw": raw(ProjectMilestoneStatus.self)],
            "alert": ["kindRaw": raw(CustomerOperationalAlertKind.self)],
            "task": ["priorityRaw": raw(BusinessTaskPriority.self)],
            "taskEvent": ["kindRaw": raw(BusinessTaskEventKind.self), "priorityRawSnapshot": raw(BusinessTaskPriority.self)],
            "attachment": ["kindRaw": raw(ServiceDocumentAttachmentKind.self),
                           "googleDriveSyncStatus": raw(GoogleDriveDocumentSyncState.self),
                           "quickBooksAttachedEntityKeysRaw": .lines(validAttachmentReceiptKey)],
            "communication": ["workflowRawValue": raw(GunnAireMailWorkflow.self)],
            "formTemplate": [:], "formResponse": [:], "vendor": [:],
            "purchaseOrder": ["statusRaw": raw(PurchaseOrderStatus.self)],
            "movement": ["movementTypeRaw": raw(InventoryMovementType.self)],
            "vehicle": ["administrativeStatusRaw": raw(FleetVehicleAdministrativeStatus.self)],
            "vehicleEvent": ["kindRaw": raw(FleetVehicleEventKind.self),
                             "serviceCategoryRaw": raw(FleetServiceCategory.self),
                             "priorStatusRaw": raw(FleetVehicleAdministrativeStatus.self),
                             "newStatusRaw": raw(FleetVehicleAdministrativeStatus.self),
                             "failedInspectionItemsRaw": .lines { FleetInspectionItem(rawValue: $0) != nil }],
            "expense": ["claimTypeRaw": raw(FieldExpenseClaimType.self), "categoryRaw": raw(FieldExpenseCategory.self),
                        "statusRaw": raw(FieldExpenseClaimStatus.self)],
        ]

    static func validateCoverage() throws {
        try StaffWorkspaceModelCatalog.validateSchema(GunnAireModelSchema.schema)
        let all = StaffWorkspaceModelCatalog.all, declared = rules
        guard Set(declared.keys) == Set(all.map(\.kind)) else { throw StaffWorkspaceDiscriminatorError.unclassified }
        let additional: [String: Set<String>] = ["job": ["type", "status"], "estimate": ["proposalOption"],
                                               "attachment": ["googleDriveSyncStatus"]]
        for codec in all {
            let expected = Set(codec.fields.filter { $0.contains("Raw") }).union(additional[codec.kind, default: []])
            guard Set(declared[codec.kind]!.keys) == expected else { throw StaffWorkspaceDiscriminatorError.unclassified }
        }
    }

    static func validate(_ record: StaffWorkspaceModelRecord) throws {
        guard let codec = StaffWorkspaceModelCatalog.all.first(where: { $0.kind == record.kind }),
              let fields = rules[record.kind] else { throw StaffWorkspaceDiscriminatorError.unclassified }
        try codec.validate(record)
        try validate(record, using: fields)
    }

    /// The graph has already run the actual codec's full field/type validation.
    /// Reuse its per-kind rules; do not rebuild all 561 mappings for each record.
    static func validate(_ record: StaffWorkspaceModelRecord, using fields: [String: Rule]) throws {
        for field in fields.keys.sorted() {
            guard let value = record.fields[field], fields[field]!.accepts(value) else {
                throw StaffWorkspaceDiscriminatorError.unrecognized(source: .init(kind: record.kind, id: record.id), field: field)
            }
        }
    }

    private static func validAttachmentReceiptKey(_ key: String) -> Bool {
        // The model writes lower-case entity type, colon, then the original ID.
        // IDs can themselves contain a colon. Do not split or rewrite those IDs.
        guard let colon = key.firstIndex(of: ":") else { return false }
        let type = String(key[..<colon]), id = String(key[key.index(after: colon)...])
        return QuickBooksAttachableEntityType.allCases.contains { $0.rawValue.lowercased() == type }
            && QBODocumentScope.reference(id)
    }
}
