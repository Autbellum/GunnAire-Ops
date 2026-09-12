import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor struct StaffWorkspaceWorkflowCodecTests {
    typealias C = StaffWorkspaceModelCodecs
    let date = Date(timeIntervalSinceReferenceDate: 810_123_456.123456)

    func copy<M>(_ codec: StaffWorkspaceModelCodec<M>, _ source: M) throws -> M {
        var resolver = StaffWorkspaceModelResolver()
        return try copy(codec, source, resolver: &resolver)
    }

    func copy<M>(_ codec: StaffWorkspaceModelCodec<M>, _ source: M, resolver: inout StaffWorkspaceModelResolver) throws -> M {
        let record = try codec.encode(source)
        let value = try codec.decodeDetached(record, resolver: &resolver)
        #expect(try codec.encode(value) == record)
        return value
    }

    @Test func agreementApprovalRenewalAndOriginalBillingEventDoNotBecomeANewObligation() throws {
        let customer = Customer(name: "Original customer")
        let invoiceID = UUID(), operationID = UUID(), jobID = UUID(), itemID = UUID()
        var lifecycle = MaintenanceAgreementLifecycle(status: .cancelled, billingInterval: .monthly, autoRenews: false, createdAt: date)
        lifecycle.agreementPrice = 123.375; lifecycle.billingCatalogItemID = itemID
        lifecycle.billingEvents = [.init(id: operationID, cycleDueDate: date, serviceCallID: jobID,
            amount: 12.125, invoiceID: invoiceID, generatedAt: date, generatedByEmail: "office@example.invalid")]
        lifecycle.approvedAt = date; lifecycle.approvedByName = "Original signer"
        lifecycle.approvalReference = "Original approval reference"
        lifecycle.approvalSignatureImageBase64 = "c3ludGhldGljLXNpZ25hdHVyZQ=="
        lifecycle.renewalOfContractID = UUID(); lifecycle.supersededByContractID = UUID()
        lifecycle.cancelledAt = date; lifecycle.cancellationReason = "Original cancellation"
        let agreement = RecurringMaintenanceContract(customer: customer, schedulePattern: "every 6 months",
            nextDate: date, active: false, pricePerVisit: 12.125, coveredEquipmentIDs: [UUID()], lifecycle: lifecycle)
        var resolver = StaffWorkspaceModelResolver()
        _ = try copy(C.customer, customer, resolver: &resolver)
        let result = try copy(C.agreement, agreement, resolver: &resolver)
        #expect(result.lifecycle == lifecycle && !result.canScheduleVisit && !result.active)
        #expect(result.billingEvents.count == 1 && result.billingEvents[0].id == operationID)
        #expect(result.billingEvents[0].invoiceID == invoiceID && result.billingEvents[0].amount == 12.125)
        #expect(result.coveredEquipmentIDs == agreement.coveredEquipmentIDs)
        #expect(agreement.lifecycle == lifecycle)
    }

    @Test func purchasingAndFormHistoryKeepTheirSnapshotsAfterCatalogAndTemplateChanges() throws {
        let item = Item(name: "Original valve", unitPrice: 123.375, sku: "OLD-SKU")
        let line = PurchaseOrderLine(id: UUID(), catalogItemID: item.id, itemName: item.name,
            itemSKU: item.sku, vendorPartNumber: "ORIGINAL-PART", quantity: 2.5, unitCost: 12.125)
        let order = PurchaseOrder(number: "ORIGINAL-123", vendorName: "Original supplier", itemName: item.name,
            quantity: 2.5, unitCost: 12.125, notes: "Original purchasing notes", createdAt: date, lineItems: [line])
        order.statusRaw = PurchaseOrderStatus.partiallyReceived.rawValue
        order.orderedAt = date; order.receivedAt = date; order.updatedAt = date
        let movement = InventoryMovement(item: item, type: .adjust, quantity: -0.125, notes: "Original approved adjustment", createdAt: date)
        item.name = "New valve name"; item.sku = "NEW-SKU"; item.unitPrice = 200
        let importedOrder = try copy(C.purchaseOrder, order)
        let importedMovement = try copy(C.movement, movement)
        #expect(importedOrder.purchaseOrderLines == [line] && importedOrder.number == "ORIGINAL-123")
        #expect(importedOrder.orderedAt == date && importedOrder.updatedAt == date && importedOrder.status == .partiallyReceived)
        #expect(importedMovement.itemName == "Original valve" && importedMovement.itemSKU == "OLD-SKU" && importedMovement.quantity == -0.125)
        let question = FieldFormQuestion(label: "Original supply temperature", kind: .text, required: true)
        let template = FieldFormTemplate(title: "Original startup", questions: [question], requiresCompletionForCloseout: true)
        let response = FieldFormResponse(serviceCallID: UUID(), template: template, answers: [question.id: "51.875°F"], completedAt: date)
        template.title = "Revised startup"; template.questionsJSON = "[]"; template.isActive = false
        let importedResponse = try copy(C.formResponse, response)
        #expect(importedResponse.templateTitle == "Original startup" && importedResponse.answers[question.id] == "51.875°F")
        #expect(importedResponse.snapshotAnswerRows == response.snapshotAnswerRows)
        #expect(importedResponse.snapshotAnswerRows.first?.label == question.label && importedResponse.completedAt == date)
    }

    @Test func workforceTaskAndFleetEventsKeepOriginalActorsAndTransitionIdentities() throws {
        let technicianID = UUID(), requestID = UUID(), approvalID = UUID(), cancellationID = UUID()
        let request = TechnicianTimeOffRequest(id: requestID, technicianID: technicianID, technicianNameSnapshot: "Original technician",
            requestedByEmail: "field@example.invalid", startsAt: date, endsAt: date.addingTimeInterval(3_600), privateReason: "Private original reason", createdAt: date)
        request.statusRawValue = TechnicianTimeOffStatus.approved.rawValue
        request.reviewedAt = date; request.reviewedByEmail = "office@example.invalid"
        request.privateReviewNote = "Private original review"; request.reviewOperationID = approvalID
        request.cancelledAt = date; request.cancellationOperationID = cancellationID
        let timeOff = try copy(C.timeOff, request)
        #expect(timeOff.privateReason == request.privateReason && timeOff.privateReviewNote == request.privateReviewNote)
        #expect(timeOff.reviewOperationID == approvalID && timeOff.cancellationOperationID == cancellationID)
        let time = TimeEntry(userEmail: "field@example.invalid", clockIn: date.addingTimeInterval(-3_600), clockOut: date,
            quickBooksTimeActivityID: "original-QBO-time", quickBooksTimeActivitySyncToken: "17", quickBooksTimeActivitySyncedAt: date,
            reviewStatus: .approved, reviewedByEmail: "office@example.invalid", reviewedAt: date)
        let importedTime = try copy(C.timeEntry, time)
        #expect(importedTime.isApprovedForQuickBooksPublication && importedTime.quickBooksTimeActivityID == "original-QBO-time")
        #expect(importedTime.quickBooksTimeActivitySyncToken == "17" && importedTime.quickBooksTimeActivitySyncedAt == date)
        let task = BusinessTask(title: "Current task title", assignedToEmail: "new@example.invalid", dueAt: date, createdByEmail: "office@example.invalid")
        task.completedAt = date; task.completedByEmail = "original@example.invalid"; task.completionOperationID = UUID()
        let event = BusinessTaskEvent(operationID: UUID(), taskID: task.id, kind: .created,
            occurredAt: date, actorEmail: "office@example.invalid", detail: "Original assignment",
            titleSnapshot: "Original task title", assignedToEmailSnapshot: "original@example.invalid", dueAtSnapshot: date, priority: .normal)
        let importedTask = try copy(C.task, task), importedEvent = try copy(C.taskEvent, event)
        #expect(importedTask.completionOperationID == task.completionOperationID && importedTask.status == .completed)
        #expect(importedEvent.titleSnapshot == "Original task title" && importedEvent.assignedToEmailSnapshot == "original@example.invalid")
        let fleet = FleetVehicleEvent(vehicleID: UUID(), vehicleUnitNumber: "Original truck", kind: .created,
            occurredAt: date, actorEmail: "office@example.invalid", detail: "Original inspection", odometer: 123_456.125,
            serviceCost: 123.375, invoiceNumber: "ORIGINAL-SERVICE-123", assignmentTechnicianID: technicianID, resolvesOutOfService: false)
        let importedFleet = try copy(C.vehicleEvent, fleet)
        #expect(importedFleet.odometer == 123_456.125 && importedFleet.serviceCost == 123.375 && importedFleet.resolvesOutOfService == false)
    }

    @Test func consentUncertainDeliveryAndExpenseReimbursementAreNotInferredOrReplayed() throws {
        let customer = Customer(name: "Original customer", allowsTransactionalEmail: false, allowsServiceText: true,
            allowsMarketing: false, communicationConsentUpdatedAt: date)
        let originalConsent = CustomerCommunicationConsentSnapshot(customer: customer)
        let communication = CustomerCommunication(customer: customer, recipient: "customer@example.invalid",
            subject: "Original report", deliveryStatus: "sent", consentSnapshot: originalConsent,
            providerMessageID: "original-provider-message", createdAt: date)
        communication.deliveredAt = nil // Keep incomplete legacy delivery evidence incomplete.
        communication.providerStatusDetail = "Original pending delivery confirmation"
        customer.allowsMarketing = true
        var resolver = StaffWorkspaceModelResolver(); _ = try copy(C.customer, customer, resolver: &resolver)
        let imported = try copy(C.communication, communication, resolver: &resolver)
        #expect(imported.consentSnapshot == originalConsent && imported.consentSnapshot?.allowsMarketing == false)
        #expect(imported.deliveredAt == nil && imported.providerMessageID == "original-provider-message")
        let expense = FieldExpenseClaim(claimantEmail: "field@example.invalid", claimantName: "Original technician",
            claimType: .expense, category: .other, expenseDate: date, merchant: "Original supplier",
            businessPurpose: "Original valve", amount: 12.125, reimbursable: true, createdAt: date)
        expense.amount = 12.125 // An existing persisted amount must not be rounded again.
        expense.statusRaw = FieldExpenseClaimStatus.reimbursed.rawValue
        expense.reimbursedAt = date; expense.reimbursedByEmail = "office@example.invalid"
        expense.reimbursementReference = "ORIGINAL-REIMBURSEMENT-123"
        let priorAudit = expense.auditJSON
        let result = try copy(C.expense, expense)
        #expect(result.amount == 12.125 && result.status == .reimbursed && !result.needsReimbursement)
        #expect(result.reimbursementReference == "ORIGINAL-REIMBURSEMENT-123" && result.auditJSON == priorAudit)
        #expect(expense.auditJSON == priorAudit && communication.deliveredAt == nil)
    }
}
