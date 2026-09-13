import Foundation
import XCTest
@testable import GunnAire_Ops

final class StaffWorkspaceDiscriminatorInteropTests: XCTestCase {
    struct Rule: Codable, Equatable {
        let kind: String
        let values: [String]
    }
    struct Contract: Codable, Equatable {
        let schema: String
        let ownerSchemaDigest: String
        let rules: [String: [String: Rule]]
    }
    @MainActor static func text<T: RawRepresentable & CaseIterable>(_ type: T.Type, kind: String = "text") -> Rule where T.RawValue == String {
        .init(kind: kind, values: T.allCases.map(\.rawValue).sorted())
    }
    @MainActor static func contract() -> Contract {
        .init(schema: "staff-workspace-discriminators-v1", ownerSchemaDigest: StaffWorkspacePublicationContract.schemaDigest, rules: [
            "customer": ["preferredContactMethodRaw": text(CustomerContactMethod.self)], "location": [:],
            "equipment": ["equipmentTypeRaw": text(HVACEquipmentType.self)],
            "technician": ["quickBooksTimeEntityKindRawValue": text(TechnicianQuickBooksTimeEntityKind.self)],
            "item": ["itemTypeRawValue": text(CatalogItemType.self), "pricebookReviewStatusRawValue": text(PricebookReviewStatus.self)],
            "job": ["type": text(ServiceCallType.self), "status": text(JobStatus.self), "dispatchUrgencyRaw": text(ServiceRequestUrgency.self),
                "visitDispositionRaw": text(ServiceVisitDisposition.self), "equipmentTypeRaw": text(HVACEquipmentType.self), "correctiveWorkReasonRaw": text(CorrectiveWorkReason.self)],
            "invoice": ["workTypeRaw": text(InvoiceWorkType.self), "taxCalculationStatusRawValue": text(BillingTaxCalculationStatus.self)],
            "estimate": ["proposalOption": text(EstimateProposalOption.self), "customerApprovalMethodRaw": text(EstimateApprovalMethod.self), "taxCalculationStatusRawValue": text(BillingTaxCalculationStatus.self)],
            "payment": [:], "user": ["roleRawValue": text(AppUserRole.self)],
            "availability": ["kindRawValue": text(TechnicianAvailabilityKind.self)],
            "shift": ["weekdayRawValue": .init(kind: "integer", values: TechnicianWeekday.allCases.map { String($0.rawValue) }.sorted()), "kindRawValue": text(TechnicianWorkShiftKind.self)],
            "timeOff": ["statusRawValue": text(TechnicianTimeOffStatus.self)],
            "availabilityEvent": ["kindRawValue": text(TechnicianAvailabilityEventKind.self), "requestStatusRawSnapshot": text(TechnicianTimeOffStatus.self)],
            "timeEntry": ["reviewStatusRawValue": text(TimeEntryReviewStatus.self)], "agreement": [:],
            "request": ["requestedServiceTypeRaw": text(ServiceCallType.self), "urgencyRaw": text(ServiceRequestUrgency.self), "statusRaw": text(ServiceRequestStatus.self)],
            "activity": [:], "milestone": ["billingTriggerRaw": text(ProjectBillingTrigger.self), "statusRaw": text(ProjectMilestoneStatus.self)],
            "alert": ["kindRaw": text(CustomerOperationalAlertKind.self)], "task": ["priorityRaw": text(BusinessTaskPriority.self)],
            "taskEvent": ["kindRaw": text(BusinessTaskEventKind.self), "priorityRawSnapshot": text(BusinessTaskPriority.self)],
            "attachment": ["kindRaw": text(ServiceDocumentAttachmentKind.self), "googleDriveSyncStatus": text(GoogleDriveDocumentSyncState.self),
                "quickBooksAttachedEntityKeysRaw": .init(kind: "receiptLines", values: QuickBooksAttachableEntityType.allCases.map { $0.rawValue.lowercased() }.sorted())],
            "communication": ["workflowRawValue": text(GunnAireMailWorkflow.self)], "formTemplate": [:], "formResponse": [:], "vendor": [:],
            "purchaseOrder": ["statusRaw": text(PurchaseOrderStatus.self)], "movement": ["movementTypeRaw": text(InventoryMovementType.self)],
            "vehicle": ["administrativeStatusRaw": text(FleetVehicleAdministrativeStatus.self)],
            "vehicleEvent": ["kindRaw": text(FleetVehicleEventKind.self), "serviceCategoryRaw": text(FleetServiceCategory.self),
                "priorStatusRaw": text(FleetVehicleAdministrativeStatus.self), "newStatusRaw": text(FleetVehicleAdministrativeStatus.self),
                "failedInspectionItemsRaw": text(FleetInspectionItem.self, kind: "lines")],
            "expense": ["claimTypeRaw": text(FieldExpenseClaimType.self), "categoryRaw": text(FieldExpenseCategory.self), "statusRaw": text(FieldExpenseClaimStatus.self)],
        ])
    }

    @MainActor func testEveryExportedCaseMatchesTheActualNativeDiscriminatorAndFieldCoverage() throws {
        let contract = Self.contract()
        try StaffWorkspaceDiscriminators.validateCoverage()
        XCTAssertEqual(Set(contract.rules.keys), Set(StaffWorkspaceDiscriminators.rules.keys))
        for (kind, fields) in contract.rules {
            let native = try XCTUnwrap(StaffWorkspaceDiscriminators.rules[kind])
            XCTAssertEqual(Set(fields.keys), Set(native.keys))
            for (name, rule) in fields {
                let check = try XCTUnwrap(native[name])
                XCTAssertEqual(rule.values, Array(Set(rule.values)).sorted())
                for value in rule.values {
                    let atom: StaffWorkspaceValue
                    switch rule.kind {
                    case "integer": atom = .integer(try XCTUnwrap(Int(value)))
                    case "receiptLines": atom = .text(value + ":NATIVE:REFERENCE")
                    default: atom = .text(value)
                    }
                    XCTAssertTrue(check.accepts(atom), "\(kind).\(name)")
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        print("GUNNAIRE_NATIVE_DISCRIMINATORS=" + String(decoding: try encoder.encode(contract), as: UTF8.self))
    }

    @MainActor func testCommittedServerContractExactlyMatchesAllCurrentNativeCases() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "StaffWorkspaceDiscriminatorsInterop", withExtension: "json"))
        let saved = try JSONDecoder().decode(Contract.self, from: Data(contentsOf: url))
        XCTAssertEqual(saved, Self.contract())
    }
}
