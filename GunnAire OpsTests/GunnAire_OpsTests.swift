//
//  GunnAire_OpsTests.swift
//  GunnAire OpsTests
//
//  Created by Eric Gunn on 2/23/26.
//

import Testing
@testable import GunnAire_Ops
import Foundation
import SwiftData

@MainActor
struct GunnAire_OpsTests {

    @Test func crossDeviceContinuityDisclosureDoesNotOverstateWhatIsShared() {
        #expect(OperationalDataContinuity.sharedCompanyRecordTypes.contains("uploaded customer files"))
        #expect(OperationalDataContinuity.deviceLocalRecordTypes.contains("jobs, dispatch assignments, and field forms"))
        #expect(OperationalDataContinuity.currentStatusDetail.localizedCaseInsensitiveContains("same approved business iCloud account"))
        #expect(OperationalDataContinuity.offlineRecoveryDetail.localizedCaseInsensitiveContains("CloudKit merges"))
        #expect(GunnAireCloudKit.containerIdentifier == "iCloud.com.gunnaire.businesssuite")
    }

    @Test func cloudKitConfigurationUsesTheNamedPrivateBusinessContainer() {
        let configuration = GunnAireCloudKit.productionModelConfiguration(for: GunnAireModelSchema.schema)
        #expect(configuration.cloudKitContainerIdentifier == GunnAireCloudKit.containerIdentifier)
        #expect(configuration.isStoredInMemoryOnly == false)
    }

    @Test func cloudKitReadinessExplainsEveryUnavailableDeviceState() {
        #expect(GunnAireCloudKit.AccountReadiness.available.isReady)
        #expect(GunnAireCloudKit.AccountReadiness.available.statusTitle == "Ready")
        #expect(GunnAireCloudKit.AccountReadiness.unavailable.userFacingDetail.localizedCaseInsensitiveContains("sign in"))
        #expect(GunnAireCloudKit.AccountReadiness.restricted.userFacingDetail.localizedCaseInsensitiveContains("restricted"))
        #expect(GunnAireCloudKit.AccountReadiness.couldNotDetermine.userFacingDetail.localizedCaseInsensitiveContains("could not verify"))
    }

    @Test func dispatchWeekBoardUsesMondayThroughSunday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let wednesday = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 26, hour: 10)))
        let days = DispatchBoardScheduling.daysInWeek(containing: wednesday, calendar: calendar)

        #expect(days.count == 7)
        #expect(calendar.component(.weekday, from: try #require(days.first)) == 2)
        #expect(calendar.component(.weekday, from: try #require(days.last)) == 1)
    }

    @Test func dispatchWeekBoardMovePreservesLocalAppointmentTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let original = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 6, hour: 14, minute: 45)))
        let targetDay = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 8)))
        let proposed = DispatchBoardScheduling.proposedStart(
            preservingTimeOf: original,
            on: targetDay,
            calendar: calendar
        )

        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: proposed)
        #expect(components.year == 2026)
        #expect(components.month == 3)
        #expect(components.day == 9)
        #expect(components.hour == 14)
        #expect(components.minute == 45)
    }

    @Test func dispatchWeekBoardRejectsTechnicianAndAvailabilityConflicts() throws {
        let customer = Customer(name: "Dispatch Customer")
        let otherCustomer = Customer(name: "Existing Customer")
        let technician = Technician(name: "Taylor Tech")
        let proposed = Date(timeIntervalSinceReferenceDate: 900_000)
        let moving = ServiceCall(
            type: .service,
            scheduledDate: proposed.addingTimeInterval(-86_400),
            duration: 3_600,
            assignedTechnician: technician,
            customer: customer
        )
        let existing = ServiceCall(
            type: .maintenance,
            scheduledDate: proposed.addingTimeInterval(1_800),
            duration: 3_600,
            assignedTechnician: technician,
            customer: otherCustomer
        )

        let jobConflict = DispatchBoardScheduling.conflictSummary(
            for: moving,
            proposedStart: proposed,
            serviceCalls: [moving, existing],
            availabilityBlocks: [],
            technicians: [technician]
        )
        #expect(jobConflict?.contains("Taylor Tech") == true)
        #expect(jobConflict?.contains("Existing Customer") == true)

        let unavailable = TechnicianAvailabilityBlock(
            technicianID: technician.id,
            startsAt: proposed,
            endsAt: proposed.addingTimeInterval(7_200),
            kind: .training,
            reason: "Safety class"
        )
        let availabilityConflict = DispatchBoardScheduling.conflictSummary(
            for: moving,
            proposedStart: proposed,
            serviceCalls: [moving],
            availabilityBlocks: [unavailable],
            technicians: [technician]
        )
        #expect(availabilityConflict?.contains("Taylor Tech") == true)
        #expect(availabilityConflict?.localizedCaseInsensitiveContains("training") == true)
    }

    @Test func dispatchWeekBoardProtectsFinishedAndGoogleOwnedEvents() {
        let customer = Customer(name: "Protected Schedule Customer")
        let completed = ServiceCall(type: .service, scheduledDate: Date(), customer: customer, status: .completed)
        let externalGoogleEvent = ServiceCall(
            googleEventID: "external-event",
            googleEventManagedByApp: false,
            type: .meeting,
            scheduledDate: Date(),
            customer: customer
        )
        let managedGoogleEvent = ServiceCall(
            googleEventID: "managed-event",
            googleEventManagedByApp: true,
            type: .service,
            scheduledDate: Date(),
            customer: customer
        )

        #expect(!DispatchBoardScheduling.canMove(completed))
        #expect(!DispatchBoardScheduling.canMove(externalGoogleEvent))
        #expect(DispatchBoardScheduling.canMove(managedGoogleEvent))
    }

    @MainActor
    @Test func cloudKitCompatibleRelationshipsCanPersistWhileTemporarilyUnresolved() throws {
        let container = try ModelContainer(
            for: GunnAireModelSchema.schema,
            configurations: [ModelConfiguration(schema: GunnAireModelSchema.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)]
        )
        let context = ModelContext(container)
        let customer = Customer(name: "CloudKit Relationship Customer")
        let estimate = Estimate(customer: customer, amount: 450)
        let invoice = Invoice(customer: customer, amount: 450)
        let payment = Payment(invoice: invoice, amount: 100)

        context.insert(customer)
        context.insert(estimate)
        context.insert(invoice)
        context.insert(payment)
        estimate.customer = nil
        payment.invoice = nil
        try context.save()

        let savedEstimate = try #require(context.fetch(FetchDescriptor<Estimate>()).first)
        let savedPayment = try #require(context.fetch(FetchDescriptor<Payment>()).first)
        #expect(savedEstimate.customer == nil)
        #expect(savedPayment.invoice == nil)
    }

    @Test func catalogQuickBooksSyncMetadataPersistsInSharedModelSchema() throws {
        let container = try ModelContainer(
            for: GunnAireModelSchema.schema,
            configurations: [ModelConfiguration(schema: GunnAireModelSchema.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)]
        )
        let context = ModelContext(container)
        let attemptedAt = Date(timeIntervalSinceReferenceDate: 123_456)
        let item = Item(
            quickBooksSyncStatus: "needs_attention",
            quickBooksSyncDetail: "Configure a QuickBooks income account.",
            quickBooksLastSyncedAt: attemptedAt,
            name: "Two-Stage Thermostat",
            unitPrice: 315
        )
        context.insert(item)
        try context.save()

        let saved = try #require(context.fetch(FetchDescriptor<Item>()).first)
        #expect(saved.quickBooksCatalogSyncState == "needs_attention")
        #expect(saved.quickBooksSyncDetail == "Configure a QuickBooks income account.")
        #expect(saved.quickBooksLastSyncedAt == attemptedAt)
    }

    @Test func fieldPaymentHandoffOnlyAcceptsItsOwnActivityAndValidInvoiceID() {
        let activity = NSUserActivity(activityType: FieldPaymentHandoff.activityType)
        let invoiceID = UUID()
        activity.userInfo = ["invoiceID": invoiceID.uuidString, "amount": 125.0]
        #expect(FieldPaymentHandoff.invoiceID(from: activity) == invoiceID)
        #expect(FieldPaymentHandoff.requirementsDetail.localizedCaseInsensitiveContains("same approved business Apple Account"))
        #expect(FieldPaymentHandoff.quickBooksTapToPayDetail.localizedCaseInsensitiveContains("QuickBooks Mobile"))
        #expect(FieldPaymentHandoff.quickBooksTapToPayDetail.localizedCaseInsensitiveContains("GoPayment"))

        activity.userInfo = ["invoiceID": "not-an-invoice"]
        #expect(FieldPaymentHandoff.invoiceID(from: activity) == nil)
    }

    @Test func billingCloseoutLaunchPolicyKeepsOrdinaryDocumentationClosed() {
        let decision = BillingInitialCloseoutPolicy.resolve(
            openCloseout: false,
            autoStartTapToPay: true,
            canCollectPayment: true,
            invoiceID: UUID(),
            hasBalanceDue: true
        )

        #expect(decision == .none)
    }

    @Test func billingCloseoutLaunchPolicyPreservesTapToPayIntent() {
        let invoiceID = UUID()
        let decision = BillingInitialCloseoutPolicy.resolve(
            openCloseout: true,
            autoStartTapToPay: true,
            canCollectPayment: true,
            invoiceID: invoiceID,
            hasBalanceDue: true
        )

        #expect(decision == .present(invoiceID: invoiceID, autoStartTapToPay: true))
    }

    @Test func billingCloseoutLaunchPolicyRejectsUnsafeCollectionRoutes() {
        let invoiceID = UUID()
        let unauthorized = BillingInitialCloseoutPolicy.resolve(
            openCloseout: true,
            autoStartTapToPay: false,
            canCollectPayment: false,
            invoiceID: invoiceID,
            hasBalanceDue: true
        )
        let missingInvoice = BillingInitialCloseoutPolicy.resolve(
            openCloseout: true,
            autoStartTapToPay: false,
            canCollectPayment: true,
            invoiceID: nil,
            hasBalanceDue: false
        )
        let paidInvoice = BillingInitialCloseoutPolicy.resolve(
            openCloseout: true,
            autoStartTapToPay: false,
            canCollectPayment: true,
            invoiceID: invoiceID,
            hasBalanceDue: false
        )

        #expect(unauthorized == .rejected("Your business account cannot collect invoice payments."))
        #expect(missingInvoice == .rejected("This job does not have an invoice to collect yet."))
        #expect(paidInvoice == .rejected("This invoice is already paid. No collection is needed."))
    }

    @Test func jobDocumentationStagesKeepTheHVACWorkflowFocused() {
        #expect(JobDocumentationStage.allCases.map(\.label) == ["Work", "Files", "Billing", "Closeout"])
        #expect(Set(JobDocumentationStage.allCases.map(\.guidance)).count == 4)
        #expect(JobDocumentationStage.work.guidance.localizedCaseInsensitiveContains("HVAC"))
    }

    @Test func jobDocumentationStageRecommendationFollowsJobAndInvoiceState() {
        #expect(JobDocumentationStage.recommended(for: .scheduled, hasInvoice: false, invoiceIsPaid: false) == .work)
        #expect(JobDocumentationStage.recommended(for: .inProgress, hasInvoice: false, invoiceIsPaid: false) == .work)
        #expect(JobDocumentationStage.recommended(for: .invoiced, hasInvoice: true, invoiceIsPaid: false) == .billing)
        #expect(JobDocumentationStage.recommended(for: .completed, hasInvoice: true, invoiceIsPaid: true) == .closeout)
        #expect(JobDocumentationStage.recommended(for: .completed, hasInvoice: false, invoiceIsPaid: false) == .closeout)
    }

    @Test func quickBooksManagementWorkspacesSeparateAccountingLanes() {
        #expect(QuickBooksManagementWorkspace.allCases.map(\.label) == ["Overview", "Sales", "Expenses", "Payments"])
        #expect(Set(QuickBooksManagementWorkspace.allCases.map(\.guidance)).count == 4)
        #expect(QuickBooksManagementWorkspace.overview.guidance.localizedCaseInsensitiveContains("realm"))
        #expect(QuickBooksManagementWorkspace.expenses.guidance.localizedCaseInsensitiveContains("vendors"))
        #expect(QuickBooksManagementWorkspace.payments.guidance.localizedCaseInsensitiveContains("refunds"))
    }

    @Test func paymentWorkspacesKeepCollectionAndReconciliationFocused() {
        #expect(PaymentsWorkspace.allCases.map(\.label) == ["Overview", "Collect", "History"])
        #expect(Set(PaymentsWorkspace.allCases.map(\.guidance)).count == 3)
        #expect(PaymentsWorkspace.overview.guidance.localizedCaseInsensitiveContains("readiness"))
        #expect(PaymentsWorkspace.collect.guidance.localizedCaseInsensitiveContains("assigned"))
        #expect(PaymentsWorkspace.history.guidance.localizedCaseInsensitiveContains("QuickBooks"))
    }

    @Test func receiptsBillsWorkspacesSeparateDocumentsProcurementStockAndRecovery() {
        #expect(ReceiptsBillsWorkspace.allCases.map(\.label) == ["Documents", "Purchasing", "Inventory", "Recovery"])
        #expect(ReceiptsBillsWorkspace.available(isAdminUser: false) == [.documents])
        #expect(ReceiptsBillsWorkspace.available(isAdminUser: true) == ReceiptsBillsWorkspace.allCases)
        #expect(ReceiptsBillsWorkspace.purchasing.guidance.localizedCaseInsensitiveContains("supplier"))
        #expect(ReceiptsBillsWorkspace.inventory.guidance.localizedCaseInsensitiveContains("traceable"))
        #expect(ReceiptsBillsWorkspace.recovery.guidance.localizedCaseInsensitiveContains("unsynced"))
    }

    @Test func serviceCallDetailWorkspacesFollowJobStateAndFinancialAccess() {
        #expect(ServiceCallDetailWorkspace.allCases.map(\.label) == ["Overview", "Work", "Billing", "History"])
        #expect(ServiceCallDetailWorkspace.available(canViewFinancials: false) == [.overview, .work, .history])
        #expect(ServiceCallDetailWorkspace.available(canViewFinancials: true) == ServiceCallDetailWorkspace.allCases)
        #expect(ServiceCallDetailWorkspace.recommended(for: .scheduled, hasOpenInvoiceBalance: false, canViewFinancials: true) == .work)
        #expect(ServiceCallDetailWorkspace.recommended(for: .inProgress, hasOpenInvoiceBalance: false, canViewFinancials: false) == .work)
        #expect(ServiceCallDetailWorkspace.recommended(for: .invoiced, hasOpenInvoiceBalance: true, canViewFinancials: true) == .billing)
        #expect(ServiceCallDetailWorkspace.recommended(for: .completed, hasOpenInvoiceBalance: false, canViewFinancials: true) == .history)
        #expect(ServiceCallDetailWorkspace.recommended(for: .cancelled, hasOpenInvoiceBalance: false, canViewFinancials: false) == .history)
        #expect(ServiceCallDetailWorkspace.billing.guidance.localizedCaseInsensitiveContains("payment"))
    }

    @Test func customerProfileWorkspacesSeparateAccountSystemsFilesAndHistory() {
        #expect(CustomerProfileWorkspace.allCases.map(\.label) == ["Overview", "Systems", "Files", "History"])
        #expect(CustomerProfileWorkspace.overview.guidance.localizedCaseInsensitiveContains("consent"))
        #expect(CustomerProfileWorkspace.systems.guidance.localizedCaseInsensitiveContains("equipment"))
        #expect(CustomerProfileWorkspace.files.guidance.localizedCaseInsensitiveContains("receipt"))
        #expect(CustomerProfileWorkspace.history.guidance.localizedCaseInsensitiveContains("jobs"))
    }

    @Test func fieldPaymentPromptQueueAnnouncesEveryPendingTaskOnce() {
        let first = BackendFieldPaymentAssignmentRecord(
            id: "assignment-1",
            invoiceID: UUID().uuidString,
            customerName: "First Customer",
            amount: 125,
            assignedTo: "tech@gunnaire.com",
            assignedBy: "dispatch@gunnaire.com",
            status: "pending",
            createdAt: "2026-08-26T15:00:00Z",
            acceptedAt: nil,
            cancelledAt: nil
        )
        let second = BackendFieldPaymentAssignmentRecord(
            id: "assignment-2",
            invoiceID: UUID().uuidString,
            customerName: "Second Customer",
            amount: 275,
            assignedTo: "tech@gunnaire.com",
            assignedBy: "dispatch@gunnaire.com",
            status: "pending",
            createdAt: "2026-08-26T15:01:00Z",
            acceptedAt: nil,
            cancelledAt: nil
        )

        let initial: Set<String> = []
        #expect(FieldPaymentAssignmentPromptQueue.nextUnannouncedPendingAssignment(from: [first, second], announcedIDs: initial)?.id == first.id)
        let afterFirst = Set(FieldPaymentAssignmentPromptQueue.recordingAnnouncement(for: first.id, previouslyAnnouncedIDs: initial))
        #expect(FieldPaymentAssignmentPromptQueue.nextUnannouncedPendingAssignment(from: [first, second], announcedIDs: afterFirst)?.id == second.id)
        let afterSecond = Set(FieldPaymentAssignmentPromptQueue.recordingAnnouncement(for: second.id, previouslyAnnouncedIDs: afterFirst))
        #expect(FieldPaymentAssignmentPromptQueue.nextUnannouncedPendingAssignment(from: [first, second], announcedIDs: afterSecond) == nil)
    }

    @Test func paymentCollectionGuardRejectsPaidAndOverpaymentRequests() {
        let customer = Customer(name: "Collection Guard Customer")
        let invoice = Invoice(customer: customer, amount: 300)
        let priorPayment = Payment(invoice: invoice, amount: 100)

        #expect(PaymentCollectionGuard.validationMessage(invoice: invoice, amount: 201, payments: [priorPayment])?.contains("exceeds") == true)
        #expect(PaymentCollectionGuard.validationMessage(invoice: invoice, amount: 200, payments: [priorPayment]) == nil)
        #expect(PaymentCollectionGuard.validationMessage(invoice: invoice, amount: 0, payments: [priorPayment])?.contains("greater than zero") == true)

        let paidPayment = Payment(invoice: invoice, amount: 300)
        #expect(PaymentCollectionGuard.validationMessage(invoice: invoice, amount: 1, payments: [paidPayment])?.contains("no open balance") == true)
    }

    @Test func technicianServiceAreaMatchingIsVisibleAndNeverBlocksDispatch() {
        let technician = Technician(name: "Territory Tech", serviceAreas: ["Charlotte", "28202"])

        #expect(technician.serviceAreaMatch(for: "120 Trade St, Charlotte, NC 28202") == .covered)
        #expect(technician.serviceAreaMatch(for: "Concord, NC 28025") == .outsideConfiguredAreas)
        #expect(Technician.serviceAreas(from: " Charlotte, 28202, Charlotte ") == ["28202", "Charlotte"])

        let unconfigured = Technician(name: "New Tech")
        #expect(unconfigured.serviceAreaMatch(for: "Concord, NC") == .unconfigured)
    }

    @Test func technicianAvailabilityBlocksMoveAssignmentsPastNonJobCommitments() {
        let technician = Technician(name: "Availability Tech")
        let start = Date(timeIntervalSinceReferenceDate: 7_000_000)
        let blockEnd = start.addingTimeInterval(60 * 60)
        let breakBlock = TechnicianAvailabilityBlock(
            technicianID: technician.id,
            startsAt: start,
            endsAt: blockEnd,
            kind: .breakPeriod,
            reason: "Lunch"
        )

        let movedStart = TechnicianDispatchAvailability.nextAvailableStart(
            technicianID: technician.id,
            proposedStart: start.addingTimeInterval(15 * 60),
            duration: 30 * 60,
            serviceCalls: [],
            availabilityBlocks: [breakBlock]
        )
        #expect(movedStart == blockEnd)

        let customer = Customer(name: "Scheduling Customer")
        let job = ServiceCall(
            type: .service,
            scheduledDate: blockEnd,
            duration: 45 * 60,
            assignedTechnician: technician,
            customer: customer
        )
        let afterJob = TechnicianDispatchAvailability.nextAvailableStart(
            technicianID: technician.id,
            proposedStart: start,
            duration: 30 * 60,
            serviceCalls: [job],
            availabilityBlocks: [breakBlock]
        )
        #expect(afterJob == blockEnd.addingTimeInterval(45 * 60))
    }

    @MainActor
    @Test func cloudKitDuplicateUsersFailClosedThenConvergeToOneRecord() throws {
        let container = try ModelContainer(
            for: GunnAireModelSchema.schema,
            configurations: [ModelConfiguration(schema: GunnAireModelSchema.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)]
        )
        let context = ModelContext(container)
        let first = AppUser(email: "duplicate@gunnaire.com", role: .dispatcher, createdAt: Date(timeIntervalSinceReferenceDate: 10))
        let second = AppUser(email: "duplicate@gunnaire.com", role: .accounting, createdAt: Date(timeIntervalSinceReferenceDate: 20))
        context.insert(first)
        context.insert(second)
        try context.save()

        #expect(AppAccess.activeRole(email: first.email, users: [first, second]) == .standard)
        #expect(AppAccess.canManageDispatch(email: first.email, users: [first, second]) == false)
        #expect(AppAccess.canViewFinancialManagement(email: first.email, users: [first, second]) == false)

        #expect(AppUserDataMaintenance.collapseCloudKitDuplicates([first, second], modelContext: context) == 1)
        let saved = try context.fetch(FetchDescriptor<AppUser>())
        #expect(saved.count == 1)
        #expect(saved.first?.role == .standard)
        #expect(saved.first?.isActive == true)
    }

    private func completeRequiredTechnicalReadings(for call: ServiceCall) {
        for definition in call.requiredTechnicalReadingDefinitions {
            call.setTechnicalReading(HVACTechnicalReadingDefinition.unableToTestValue, for: definition.key)
        }
    }

    private func completeRequiredMaintenanceActions(for call: ServiceCall) {
        for definition in call.requiredServiceActionDefinitions {
            call.setServiceActionStatus(.completed, for: definition.key)
        }
    }

    @Test func inventoryLedgerKeepsStockAndReservationsTraceableByLocation() async throws {
        let item = Item(name: "45/5 Dual Run Capacitor", itemType: .nonInventory, unitPrice: 85, tracksInventory: true)
        let jobID = UUID()
        let movements = [
            InventoryMovement(item: item, type: .receive, quantity: 10, destinationLocation: "Warehouse"),
            InventoryMovement(item: item, type: .reserve, quantity: 2, sourceLocation: "Warehouse", serviceCallID: jobID),
            InventoryMovement(item: item, type: .consume, quantity: 2, sourceLocation: "Warehouse", serviceCallID: jobID),
            InventoryMovement(item: item, type: .transfer, quantity: 3, sourceLocation: "Warehouse", destinationLocation: "Truck 1"),
            InventoryMovement(item: item, type: .adjust, quantity: -1, destinationLocation: "Warehouse", notes: "Cycle count")
        ]

        #expect(InventoryLedger.onHandQuantity(for: item.id, at: "Warehouse", movements: movements) == 4)
        #expect(InventoryLedger.onHandQuantity(for: item.id, at: "Truck 1", movements: movements) == 3)
        #expect(InventoryLedger.onHandQuantity(for: item.id, movements: movements) == 7)
        #expect(InventoryLedger.reservedQuantity(for: item.id, at: "Warehouse", movements: movements) == 0)
        #expect(InventoryLedger.availableQuantity(for: item.id, at: "Warehouse", movements: movements) == 4)
        #expect(InventoryLedger.locations(for: item.id, movements: movements) == ["Truck 1", "Warehouse"])
    }

    @Test func jobMaterialLedgerFulfillsOnlyTheMatchingReservationAndTracksReturns() async throws {
        let item = Item(name: "45/5 Dual Run Capacitor", itemType: .nonInventory, unitPrice: 85, tracksInventory: true)
        let firstJobID = UUID()
        let secondJobID = UUID()
        let movements = [
            InventoryMovement(item: item, type: .receive, quantity: 10, destinationLocation: "Truck 1"),
            InventoryMovement(item: item, type: .reserve, quantity: 2, sourceLocation: "Truck 1", serviceCallID: firstJobID),
            InventoryMovement(item: item, type: .reserve, quantity: 1, sourceLocation: "Truck 1", serviceCallID: secondJobID),
            InventoryMovement(item: item, type: .consume, quantity: 1.5, sourceLocation: "Truck 1", serviceCallID: firstJobID),
            InventoryMovement(item: item, type: .returnToStock, quantity: 0.5, destinationLocation: "Truck 1", serviceCallID: firstJobID)
        ]

        let firstJob = InventoryLedger.jobMaterialStatus(
            for: item.id,
            serviceCallID: firstJobID,
            requiredQuantity: 2,
            movements: movements
        )
        #expect(firstJob.openReservedQuantity == 0.5)
        #expect(firstJob.consumedQuantity == 1.5)
        #expect(firstJob.returnedQuantity == 0.5)
        #expect(firstJob.netUsedQuantity == 1)
        #expect(firstJob.remainingToRecord == 1)
        #expect(firstJob.isComplete == false)

        #expect(InventoryLedger.reservedQuantity(for: item.id, at: "Truck 1", movements: movements) == 1.5)
        #expect(InventoryLedger.availableQuantity(for: item.id, at: "Truck 1", movements: movements) == 7.5)
    }

    @Test func receivingTrackedPurchaseOrderIncludesSupplierAndOrderReferenceInStockLedger() async throws {
        let item = Item(
            name: "45/5 Dual Run Capacitor",
            itemType: .nonInventory,
            unitPrice: 85
        )
        item.sku = "CAP-45-5"
        item.tracksInventory = true
        item.defaultInventoryLocation = "Warehouse"
        let order = PurchaseOrder(
            number: "PO-20260826-0001",
            vendorName: "Johnstone Supply",
            itemName: item.name,
            itemSKU: item.sku,
            quantity: 2,
            unitCost: 18.50,
            status: .ordered
        )

        let movement = try #require(PurchaseOrderReceiving.receive(order, catalogItems: [item], actorEmail: "owner@gunnaire.com"))

        #expect(order.status == .received)
        #expect(movement.notes == "Received from Johnstone Supply on PO-20260826-0001.")
        #expect(movement.destinationLocation == "Warehouse")
    }

    @Test func purchaseOrderSupplierSummaryKeepsTheManualOrderingTrailTraceable() {
        let order = PurchaseOrder(
            number: "PO-20260826-TEST",
            vendorName: "Johnstone Supply",
            itemName: "45/5 Dual Run Capacitor",
            itemSKU: "CAP-45",
            vendorPartNumber: "27W84",
            quantity: 2,
            unitCost: 18.5,
            shippingCost: 4,
            notes: "Call before substitution."
        )

        let summary = order.supplierOrderSummary
        #expect(summary.contains("PO-20260826-TEST"))
        #expect(summary.contains("Johnstone Supply"))
        #expect(summary.contains("Supplier part #: 27W84"))
        #expect(summary.contains("Expected total: $41.00"))
        #expect(summary.contains("Call before substitution."))
    }

    @Test func technicianEquipmentQualificationsRemainOverridableButExposeMismatch() async throws {
        let technician = Technician(
            name: "Riley Tech",
            supportedEquipmentTypes: [.gasFurnace, .heatPump]
        )

        #expect(technician.qualification(for: .gasFurnace) == .qualified)
        #expect(technician.qualification(for: .miniSplit) == .reviewRequired)
        #expect(technician.qualification(for: nil) == .notRequired)

        let unprofiledTechnician = Technician(name: "New Technician")
        #expect(unprofiledTechnician.qualification(for: .heatPump) == .unverified)
    }

    @Test func timeEntryRetainsTheServiceCallNeededForLaborAndQuickBooksContext() async throws {
        let customer = Customer(name: "Labor Context Customer")
        let call = ServiceCall(type: .service, scheduledDate: Date(), customer: customer)
        let clockIn = Date(timeIntervalSinceReferenceDate: 50_000)
        let clockOut = clockIn.addingTimeInterval(95 * 60)
        let entry = TimeEntry(
            userEmail: "tech@gunnaire.com",
            clockIn: clockIn,
            clockOut: clockOut,
            serviceCall: call
        )

        #expect(entry.serviceCall?.id == call.id)
        #expect(entry.durationMinutes == 95)
    }

    @Test func promisedArrivalWindowStaysSeparateFromTechnicianScheduleAndRejectsInvalidRanges() async throws {
        let customer = Customer(name: "Arrival Window Customer")
        let scheduled = Date(timeIntervalSinceReferenceDate: 70_000)
        let arrivalStart = scheduled.addingTimeInterval(30 * 60)
        let arrivalEnd = arrivalStart.addingTimeInterval(2 * 3600)
        let call = ServiceCall(
            type: .service,
            scheduledDate: scheduled,
            duration: 90 * 60,
            promisedArrivalWindowStart: arrivalStart,
            promisedArrivalWindowEnd: arrivalEnd,
            customer: customer
        )

        #expect(call.scheduledDate == scheduled)
        #expect(call.duration == 90 * 60)
        #expect(call.promisedArrivalWindow?.lowerBound == arrivalStart)
        #expect(call.promisedArrivalWindow?.upperBound == arrivalEnd)
        #expect(call.hasPromisedArrivalWindow)
        #expect(call.customerAppointmentSummary.contains("arrival"))

        call.promisedArrivalWindowEnd = arrivalStart
        #expect(call.promisedArrivalWindow == nil)
        #expect(!call.hasPromisedArrivalWindow)
    }

    @Test func technicianTravelAndArrivalHandoffsAreTimestampedAndKeepTheJobInProgress() async throws {
        let customer = Customer(name: "Travel Handoff Customer")
        let call = ServiceCall(type: .service, scheduledDate: Date(), customer: customer)
        let enRouteAt = Date(timeIntervalSinceReferenceDate: 72_000)
        let arrivedAt = enRouteAt.addingTimeInterval(25 * 60)

        call.markTechnicianEnRoute(at: enRouteAt)
        #expect(call.status == .inProgress)
        #expect(call.technicianEnRouteAt == enRouteAt)
        #expect(call.technicianJobPresence == .enRoute)

        call.markTechnicianArrived(at: arrivedAt)
        #expect(call.technicianEnRouteAt == enRouteAt)
        #expect(call.technicianArrivedAt == arrivedAt)
        #expect(call.arrivalConfirmed)
        #expect(call.technicianJobPresence == .onSite)
    }

    @Test func additionalCrewIsDistinctFromLeadAndParticipatesInAssignmentMembership() async throws {
        let customer = Customer(name: "Crew Assignment Customer")
        let lead = Technician(name: "Lead Installer")
        let helper = Technician(name: "Install Helper")
        let call = ServiceCall(
            type: .install,
            scheduledDate: Date(),
            assignedTechnician: lead,
            additionalTechnicianIDs: [lead.id, helper.id],
            customer: customer
        )

        #expect(call.additionalTechnicianIDs == [helper.id])
        #expect(call.includesAssignedTechnician(lead.id))
        #expect(call.includesAssignedTechnician(helper.id))
        #expect(call.assignedCrewTechnicianIDs.count == 2)
    }

    @Test func dispatchUrgencyPersistsIndependentlyFromAppointmentTiming() async throws {
        let customer = Customer(name: "Priority Dispatch Customer")
        let emergency = ServiceCall(
            type: .service,
            dispatchUrgency: .emergency,
            scheduledDate: Date(),
            customer: customer
        )

        #expect(emergency.dispatchUrgency == .emergency)
        #expect(emergency.dispatchUrgency.dispatchSortRank < ServiceRequestUrgency.normal.dispatchSortRank)

        emergency.dispatchUrgencyRaw = "unexpected_value"
        #expect(emergency.dispatchUrgency == .normal)
    }

    @Test func customerCommunicationKeepsProviderMessageReferenceForReconciliation() async throws {
        let customer = Customer(name: "Communication Audit Customer")
        let communication = CustomerCommunication(
            customer: customer,
            recipient: "customer@example.com",
            subject: "Appointment confirmation",
            deliveryStatus: "sent",
            providerMessageID: "gmail-message-123"
        )

        #expect(communication.providerMessageID == "gmail-message-123")
        #expect(communication.deliveryStatus == "sent")
    }

    @Test func generatedWorkOrderInheritsDurableEquipmentProfileWithoutReusingFieldEvidence() async throws {
        let customer = Customer(name: "Equipment Continuity Customer")
        let equipmentID = UUID()
        let source = ServiceCall(
            equipmentName: "Upstairs Heat Pump",
            equipmentManufacturer: "Lennox",
            equipmentModel: "XP21",
            equipmentSerialNumber: "HP-123",
            equipmentLocation: "Attic",
            customerEquipmentID: equipmentID,
            equipmentTypeRaw: HVACEquipmentType.heatPump.rawValue,
            equipmentNotes: "20 x 25 x 4 media filter",
            filterSize: "20 x 25 x 4",
            type: .service,
            scheduledDate: Date(),
            customer: customer
        )
        source.setTechnicalReading("115", for: "line_voltage")
        source.setServiceActionStatus(.needsService, for: "reversing_valve_tested")
        let generated = ServiceCall(type: .install, scheduledDate: Date(), customer: customer)

        generated.inheritEquipmentProfile(from: source)

        #expect(generated.customerEquipmentID == equipmentID)
        #expect(generated.equipmentType == .heatPump)
        #expect(generated.equipmentModel == "XP21")
        #expect(generated.filterSize == "20 x 25 x 4")
        #expect(generated.equipmentNotes == "20 x 25 x 4 media filter")
        #expect(generated.technicalReadings.isEmpty)
        #expect(generated.serviceActionStatuses.isEmpty)
    }

    @Test func fieldTechnicianCanAccessAJobWhenAssignedAsAdditionalCrew() async throws {
        let customer = Customer(name: "Crew Access Customer")
        let lead = Technician(name: "Lead", contactInfo: "lead@gunnaire.com")
        let helper = Technician(name: "Helper", contactInfo: "helper@gunnaire.com")
        let call = ServiceCall(
            type: .install,
            scheduledDate: Date(),
            assignedTechnician: lead,
            additionalTechnicianIDs: [helper.id],
            customer: customer
        )
        let helperUser = AppUser(email: "helper@gunnaire.com", role: .fieldTechnician)

        let visibleIDs = AppAccess.visibleServiceCallIDs(
            email: helperUser.email,
            users: [helperUser],
            serviceCalls: [call],
            technicians: [lead, helper]
        )

        #expect(visibleIDs == [call.id])
        #expect(AppAccess.canAccessServiceCall(
            call,
            email: helperUser.email,
            users: [helperUser],
            serviceCalls: [call],
            technicians: [lead, helper]
        ))
    }

    @Test func estimateCustomerApprovalRecordsAnAttributableStableApprovalEvent() async throws {
        let customer = Customer(name: "Approval Customer")
        let estimate = Estimate(customer: customer, amount: 3_500)
        let approvedAt = Date(timeIntervalSinceReferenceDate: 60_000)

        estimate.recordCustomerApproval(by: "Morgan Approval", at: approvedAt)
        estimate.recordCustomerApproval(by: "Changed Name", at: approvedAt.addingTimeInterval(60))

        #expect(estimate.status == "accepted")
        #expect(estimate.customerApprovedByName == "Morgan Approval")
        #expect(estimate.customerApprovedAt == approvedAt)
        #expect(estimate.hasRecordedCustomerApproval)
    }

    @Test func serviceRequestRequiresQualificationBeforeCreatingAJob() async throws {
        let request = ServiceRequest(
            customerName: "Avery Customer",
            requestedServiceType: .maintenance,
            urgency: .emergency,
            summary: "No cooling"
        )

        #expect(request.status == .new)
        #expect(request.canSchedule == false)
        #expect(request.requestedServiceType == .maintenance)
        #expect(request.urgency == .emergency)

        request.status = .qualified
        #expect(request.canSchedule == true)

        let customerID = UUID()
        let callID = UUID()
        request.markScheduled(customerID: customerID, serviceCallID: callID)

        #expect(request.status == .scheduled)
        #expect(request.canSchedule == false)
        #expect(request.convertedCustomerID == customerID)
        #expect(request.convertedServiceCallID == callID)
        #expect(request.qualifiedAt != nil)
    }

    @Test func noAccessVisitCannotCreateBillingButKeepsRescheduleContext() async throws {
        let customer = Customer(name: "Access Test Customer")
        let call = ServiceCall(
            type: .service,
            scheduledDate: Date(),
            customer: customer,
            visitDisposition: .noAccess,
            visitDispositionNotes: "Customer was unavailable",
            followUpRequired: true,
            followUpAction: "Confirm access window"
        )

        #expect(call.visitDisposition == .noAccess)
        #expect(call.visitDisposition.preventsBilling == true)
        #expect(call.canCreateInvoiceDocument == false)
        #expect(call.isReadyToCreateBillingDocument == false)
        #expect(call.invoiceCreationBlockedMessage?.contains("No-access") == true)
        #expect(call.followUpRequired == true)
        #expect(call.followUpAction == "Confirm access window")
    }

    @Test func callbackFollowUpRetainsCorrectiveLineageWithoutReusingFieldEvidence() async throws {
        let customer = Customer(name: "Corrective Work Customer", address: "44 Recall Way")
        let equipmentID = UUID()
        let dueDate = Date(timeIntervalSince1970: 1_800_086_400)
        let source = ServiceCall(
            equipmentName: "Main Heat Pump",
            equipmentModel: "XP21",
            equipmentSerialNumber: "CALLBACK-21",
            customerEquipmentID: equipmentID,
            equipmentTypeRaw: HVACEquipmentType.heatPump.rawValue,
            type: .service,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            customer: customer,
            status: .completed,
            notes: "Customer reports intermittent shutdown.",
            findingsSummary: "Control board stopped responding.",
            visitDisposition: .callback,
            visitDispositionNotes: "The original concern returned overnight.",
            followUpRequired: true,
            followUpAction: "Return with a replacement control board",
            followUpDueDate: dueDate,
            correctiveWorkReason: .partFailure
        )
        source.setTechnicalReading("114", for: "line_voltage")
        source.setServiceActionStatus(.needsService, for: "reversing_valve_tested")

        let followUp = source.makeFollowUpVisit()

        #expect(source.scheduledFollowUpServiceCallID == followUp.id)
        #expect(source.followUpRequired == false)
        #expect(source.followUpAction == nil)
        #expect(source.followUpDueDate == nil)
        #expect(followUp.originatingServiceCallID == source.id)
        #expect(followUp.visitDisposition == .callback)
        #expect(followUp.correctiveWorkReason == .partFailure)
        #expect(followUp.scheduledDate == dueDate)
        #expect(followUp.customerEquipmentID == equipmentID)
        #expect(followUp.equipmentSerialNumber == "CALLBACK-21")
        #expect(followUp.notes?.contains("Return with a replacement control board") == true)
        #expect(followUp.notes?.contains("Original visit outcome") == true)
        #expect(followUp.technicalReadings.isEmpty)
        #expect(followUp.serviceActionStatuses.isEmpty)
    }

    @MainActor
    @Test func correctiveLineagePersistsAcrossTheSharedModelSchema() throws {
        let schema = GunnAireModelSchema.schema
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)]
        )
        let context = ModelContext(container)
        let customer = Customer(name: "Persistent Corrective Customer")
        let source = ServiceCall(
            type: .install,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            customer: customer,
            status: .completed,
            visitDisposition: .warranty,
            followUpRequired: true,
            correctiveWorkReason: .manufacturerWarranty
        )
        let followUp = source.makeFollowUpVisit(scheduledDate: Date(timeIntervalSince1970: 1_800_172_800))
        context.insert(customer)
        context.insert(source)
        context.insert(followUp)
        try context.save()

        let stored = try context.fetch(FetchDescriptor<ServiceCall>())
        let storedSource = try #require(stored.first { $0.id == source.id })
        let storedFollowUp = try #require(stored.first { $0.id == followUp.id })

        #expect(storedSource.scheduledFollowUpServiceCallID == storedFollowUp.id)
        #expect(storedFollowUp.originatingServiceCallID == storedSource.id)
        #expect(storedFollowUp.visitDisposition == .warranty)
        #expect(storedFollowUp.correctiveWorkReason == .manufacturerWarranty)
    }

    @Test func ordinaryFollowUpPreservesLineageWithoutCorrectiveClassification() async throws {
        let customer = Customer(name: "Routine Follow-Up Customer")
        let source = ServiceCall(
            type: .maintenance,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            customer: customer,
            status: .completed,
            visitDisposition: .standard,
            followUpRequired: true,
            followUpAction: "Return to replace the customer-provided filter"
        )

        let followUp = source.makeFollowUpVisit()

        #expect(followUp.originatingServiceCallID == source.id)
        #expect(followUp.visitDisposition == .standard)
        #expect(followUp.correctiveWorkReason == nil)
        #expect(followUp.isCorrectiveWorkClassification == false)
        #expect(followUp.isCorrectiveVisit == true)
    }

    @Test func onlyCompletedAccessibleVisitsCanOfferReviewFollowUp() async throws {
        let customer = Customer(name: "Review Customer")
        let completed = ServiceCall(type: .service, scheduledDate: Date(), customer: customer, status: .completed)
        let active = ServiceCall(type: .service, scheduledDate: Date(), customer: customer, status: .inProgress)
        let noAccess = ServiceCall(type: .service, scheduledDate: Date(), customer: customer, status: .completed, visitDisposition: .noAccess)

        #expect(completed.isEligibleForReviewRequest == true)
        #expect(active.isEligibleForReviewRequest == false)
        #expect(noAccess.isEligibleForReviewRequest == false)
    }

    @Test func serviceCallIsUpcomingThisWeekForFutureDate() async throws {
        let customer = Customer(name: "Test Customer")
        let call = ServiceCall(
            type: .service,
            scheduledDate: Date().addingTimeInterval(60 * 60 * 24),
            customer: customer
        )

        #expect(call.isUpcomingThisWeek == true)
    }

    @Test func serviceCallIsNotUpcomingThisWeekForPastDate() async throws {
        let customer = Customer(name: "Test Customer")
        let call = ServiceCall(
            type: .service,
            scheduledDate: Date().addingTimeInterval(-60 * 60 * 24),
            customer: customer
        )

        #expect(call.isUpcomingThisWeek == false)
    }

    @Test func serviceCallIsNotUpcomingThisWeekForFarFutureDate() async throws {
        let customer = Customer(name: "Test Customer")
        let call = ServiceCall(
            type: .service,
            scheduledDate: Date().addingTimeInterval(60 * 60 * 24 * 14),
            customer: customer
        )

        #expect(call.isUpcomingThisWeek == false)
    }

    @Test func completedTechnicianTimeProducesInternalLaborCost() async throws {
        let entry = TimeEntry(
            userEmail: "tech@gunnaire.com",
            clockIn: Date(timeIntervalSince1970: 0),
            clockOut: Date(timeIntervalSince1970: 90 * 60)
        )

        #expect(JobLaborCosting.cost(entries: [entry], hourlyCost: 80) == 120)
        #expect(JobLaborCosting.cost(entries: [entry], hourlyCost: nil) == nil)
        #expect(JobLaborCosting.cost(entries: [], hourlyCost: 80) == nil)
    }

    @Test func jobLaborCostingUsesEachCrewMemberRateAndFlagsUncostedTime() async throws {
        let lead = Technician(name: "Lead", contactInfo: "lead@gunnaire.com", laborCostPerHour: 80)
        let helper = Technician(name: "Helper", contactInfo: "helper@gunnaire.com", laborCostPerHour: 50)
        let unratedEntry = TimeEntry(
            userEmail: "unrated@gunnaire.com",
            clockIn: Date(timeIntervalSince1970: 0),
            clockOut: Date(timeIntervalSince1970: 30 * 60)
        )
        let leadEntry = TimeEntry(
            userEmail: lead.contactInfo ?? "",
            clockIn: Date(timeIntervalSince1970: 0),
            clockOut: Date(timeIntervalSince1970: 60 * 60)
        )
        let helperEntry = TimeEntry(
            userEmail: helper.contactInfo ?? "",
            clockIn: Date(timeIntervalSince1970: 0),
            clockOut: Date(timeIntervalSince1970: 90 * 60)
        )

        let summary = JobLaborCosting.summary(entries: [leadEntry, helperEntry, unratedEntry], technicians: [lead, helper])

        #expect(summary.totalCost == 155)
        #expect(summary.costedMinutes == 150)
        #expect(summary.uncostedMinutes == 30)
    }

    @Test func receivingTrackedPurchaseOrderCreatesOneTraceableStockReceipt() async throws {
        let item = Item(name: "Capacitor", unitPrice: 75, sku: "CAP-45", tracksInventory: true, defaultInventoryLocation: "Truck 4")
        let order = PurchaseOrder(vendorName: "Supply House", itemName: "Capacitor", itemSKU: "CAP-45", quantity: 2, unitCost: 18)

        let receipt = PurchaseOrderReceiving.receive(order, catalogItems: [item], actorEmail: "dispatch@gunnaire.com")

        #expect(order.status == .received)
        #expect(order.receivedToLocation == "Truck 4")
        #expect(receipt?.type == .receive)
        #expect(receipt?.quantity == 2)
        #expect(receipt?.destinationLocation == "Truck 4")
        #expect(receipt?.createdByEmail == "dispatch@gunnaire.com")
        #expect(PurchaseOrderReceiving.receive(order, catalogItems: [item], actorEmail: "dispatch@gunnaire.com") == nil)
    }

    @Test func sharedDocumentUploadFailureRetainsAnActionableRetryState() async throws {
        let attachment = ServiceDocumentAttachment(
            customer: Customer(name: "Offline Attachment Customer"),
            serviceCallID: nil,
            kind: .customerDocument,
            displayName: "field-note.pdf",
            localFilePath: "/tmp/field-note.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 42
        )

        attachment.markSharedCompanyUploadFailed("offline")
        #expect(attachment.needsSharedCompanyStorageUpload)
        #expect(attachment.sharedCompanySyncDetail?.contains("offline") == true)

        attachment.markSharedCompanyStored(id: "company-file-1")
        #expect(attachment.needsSharedCompanyStorageUpload == false)
        #expect(attachment.backendDocumentID == "company-file-1")
    }

    @Test func userRolesSeparateStandardFieldAndAdminAccess() async throws {
        let standard = AppUser(email: "standard@gunnaire.com", role: .standard)
        let technician = AppUser(email: "tech@gunnaire.com", role: .fieldTechnician)
        let dispatcher = AppUser(email: "dispatch@gunnaire.com", role: .dispatcher)
        let accounting = AppUser(email: "accounting@gunnaire.com", role: .accounting)
        let admin = AppUser(email: "admin@gunnaire.com", role: .admin)
        let users = [standard, technician, dispatcher, accounting, admin]

        #expect(AppAccess.canAccessSidebarItem(.scheduleAndJobs, email: standard.email, users: users) == true)
        #expect(AppAccess.canAccessSidebarItem(.onsiteDocumentation, email: standard.email, users: users) == true)
        #expect(AppAccess.canAccessSidebarItem(.invoices, email: standard.email, users: users) == false)
        #expect(AppAccess.canAccessSidebarItem(.payments, email: standard.email, users: users) == false)
        #expect(AppAccess.canAccessSidebarItem(.reports, email: standard.email, users: users) == false)
        #expect(AppAccess.canAccessSidebarItem(.receiptsBills, email: standard.email, users: users) == false)
        #expect(AppAccess.canAccessSidebarItem(.quickBooksManagement, email: standard.email, users: users) == false)
        #expect(AppAccess.canAccessSidebarItem(.syncIntegrations, email: standard.email, users: users) == false)
        #expect(AppAccess.canAccessSidebarItem(.estimates, email: standard.email, users: users) == false)
        #expect(AppAccess.canAccessSidebarItem(.mail, email: standard.email, users: users) == false)
        #expect(AppAccess.canAccessSidebarItem(.customers, email: standard.email, users: users) == true)
        #expect(AppAccess.canViewFinancialManagement(email: standard.email, users: users) == false)
        #expect(AppAccess.canViewBillingFinancialDetails(email: standard.email, users: users) == false)
        #expect(AppAccess.canCollectFieldPayments(email: standard.email, users: users) == false)
        #expect(AppAccess.canRecordJobMaterials(email: standard.email, users: users) == false)
        #expect(AppAccess.canManageDispatch(email: standard.email, users: users) == false)
        #expect(AppAccess.canManageCustomerRecords(email: standard.email, users: users) == false)
        #expect(AppAccess.canDeleteCustomerRecords(email: standard.email, users: users) == false)
        #expect(AppAccess.canSyncCustomerRecordsWithAccounting(email: standard.email, users: users) == false)

        #expect(AppAccess.canAccessSidebarItem(.customers, email: technician.email, users: users) == false)
        #expect(AppAccess.canAccessSidebarItem(.scheduleAndJobs, email: technician.email, users: users) == true)
        #expect(AppAccess.canAccessSidebarItem(.onsiteDocumentation, email: technician.email, users: users) == true)
        #expect(AppAccess.canAccessSidebarItem(.invoices, email: technician.email, users: users) == true)
        #expect(AppAccess.canAccessSidebarItem(.payments, email: technician.email, users: users) == true)
        #expect(AppAccess.canAccessSidebarItem(.receiptsBills, email: technician.email, users: users) == true)
        #expect(AppAccess.canAccessSidebarItem(.reports, email: technician.email, users: users) == false)
        #expect(AppAccess.canAccessSidebarItem(.quickBooksManagement, email: technician.email, users: users) == false)
        #expect(AppAccess.canViewFinancialManagement(email: technician.email, users: users) == false)
        #expect(AppAccess.canViewBillingFinancialDetails(email: technician.email, users: users) == false)
        #expect(AppAccess.canCollectFieldPayments(email: technician.email, users: users) == true)
        #expect(AppAccess.canRecordJobMaterials(email: technician.email, users: users) == true)
        #expect(AppAccess.canManageDispatch(email: technician.email, users: users) == false)
        #expect(AppAccess.canManageCustomerRecords(email: technician.email, users: users) == false)
        #expect(AppAccess.canDeleteCustomerRecords(email: technician.email, users: users) == false)
        #expect(AppAccess.canSyncCustomerRecordsWithAccounting(email: technician.email, users: users) == false)

        #expect(AppAccess.canManageDispatch(email: dispatcher.email, users: users) == true)
        #expect(AppAccess.canRecordJobMaterials(email: dispatcher.email, users: users) == false)
        #expect(AppAccess.canAccessSidebarItem(.customers, email: dispatcher.email, users: users) == true)
        #expect(AppAccess.canManageCustomerRecords(email: dispatcher.email, users: users) == true)
        #expect(AppAccess.canDeleteCustomerRecords(email: dispatcher.email, users: users) == false)
        #expect(AppAccess.canSyncCustomerRecordsWithAccounting(email: dispatcher.email, users: users) == false)

        #expect(AppAccess.canAccessSidebarItem(.customers, email: accounting.email, users: users) == true)
        #expect(AppAccess.canAccessSidebarItem(.scheduleAndJobs, email: accounting.email, users: users) == false)
        #expect(AppAccess.canAccessSidebarItem(.invoices, email: accounting.email, users: users) == true)
        #expect(AppAccess.canAccessSidebarItem(.reports, email: accounting.email, users: users) == true)
        #expect(AppAccess.canViewFinancialManagement(email: accounting.email, users: users) == true)
        #expect(AppAccess.canViewBillingFinancialDetails(email: accounting.email, users: users) == true)
        #expect(AppAccess.canCollectFieldPayments(email: accounting.email, users: users) == false)
        #expect(AppAccess.canRecordJobMaterials(email: accounting.email, users: users) == false)
        #expect(AppAccess.canManageDispatch(email: accounting.email, users: users) == false)
        #expect(AppAccess.canManageCustomerRecords(email: accounting.email, users: users) == false)
        #expect(AppAccess.canDeleteCustomerRecords(email: accounting.email, users: users) == false)
        #expect(AppAccess.canSyncCustomerRecordsWithAccounting(email: accounting.email, users: users) == false)

        #expect(AppAccess.canAccessSidebarItem(.customers, email: admin.email, users: users) == true)
        #expect(AppAccess.canAccessSidebarItem(.quickBooksManagement, email: admin.email, users: users) == true)
        #expect(AppAccess.canAccessSidebarItem(.reports, email: admin.email, users: users) == true)
        #expect(AppAccess.canAccessSidebarItem(.syncIntegrations, email: admin.email, users: users) == true)
        #expect(AppAccess.canViewFinancialManagement(email: admin.email, users: users) == true)
        #expect(AppAccess.canViewBillingFinancialDetails(email: admin.email, users: users) == true)
        #expect(AppAccess.canRecordJobMaterials(email: admin.email, users: users) == true)
        #expect(AppAccess.canManageDispatch(email: admin.email, users: users) == true)
        #expect(AppAccess.canManageCustomerRecords(email: admin.email, users: users) == true)
        #expect(AppAccess.canDeleteCustomerRecords(email: admin.email, users: users) == true)
        #expect(AppAccess.canSyncCustomerRecordsWithAccounting(email: admin.email, users: users) == true)
    }

    @Test func invoiceBuilderRoutePreservesServiceCallContext() async throws {
        _ = GunnAireAppIntentRouter.consumePendingRoute()
        _ = GunnAireAppIntentRouter.consumePendingServiceCallID()
        let serviceCallID = UUID()

        GunnAireAppIntentRouter.storeInvoiceBuilderRoute(serviceCallID)

        #expect(GunnAireAppIntentRouter.consumePendingRoute() == .invoices)
        #expect(GunnAireAppIntentRouter.consumePendingServiceCallID() == serviceCallID)
    }

    @Test func discardedRestrictedRouteDoesNotLeaveSensitiveHandoffContext() async throws {
        let serviceCallID = UUID()
        GunnAireAppIntentRouter.storeInvoiceBuilderRoute(serviceCallID)
        _ = GunnAireAppIntentRouter.consumePendingRoute()

        GunnAireAppIntentRouter.discardPendingPayload(for: .invoices)

        #expect(GunnAireAppIntentRouter.consumePendingServiceCallID() == nil)
    }

    @Test func signOutHandoffCleanupRemovesEveryQueuedSensitiveContext() async throws {
        let customerID = UUID()
        let serviceCallID = UUID()
        let invoiceID = UUID()

        GunnAireAppIntentRouter.storeCustomerRoute(customerID)
        GunnAireAppIntentRouter.storeDocumentationRoute(serviceCallID)
        GunnAireAppIntentRouter.storePaymentCollectionRoute(invoiceID)
        GunnAireAppIntentRouter.storeMailDraftRoute(
            to: "customer@example.com",
            subject: "Private job update",
            body: "Private service details",
            customerID: customerID,
            serviceCallID: serviceCallID,
            invoiceID: invoiceID
        )

        GunnAireAppIntentRouter.discardAllPendingPayloads()

        #expect(GunnAireAppIntentRouter.consumePendingRoute() == nil)
        #expect(GunnAireAppIntentRouter.consumePendingCustomerID() == nil)
        #expect(GunnAireAppIntentRouter.consumePendingServiceCallID() == nil)
        #expect(GunnAireAppIntentRouter.consumePendingInvoiceCollectionID() == nil)
        #expect(GunnAireAppIntentRouter.consumePendingMailDraft() == nil)
    }

    @Test func fieldJobVisibilityNeverExpandsForAnUnassignedDeepLink() async throws {
        let customer = Customer(name: "Billing Access Customer")
        let technician = Technician(name: "Field Tech", contactInfo: "tech@gunnaire.com")
        let otherTechnician = Technician(name: "Other Tech", contactInfo: "other@gunnaire.com")
        let assignedCall = ServiceCall(type: .service, scheduledDate: Date(), assignedTechnician: technician, customer: customer)
        let activeRoutedCall = ServiceCall(type: .maintenance, scheduledDate: Date(), assignedTechnician: otherTechnician, customer: customer)
        let unrelatedCall = ServiceCall(type: .install, scheduledDate: Date(), assignedTechnician: otherTechnician, customer: customer)
        let standard = AppUser(email: "standard@gunnaire.com", role: .standard)
        let fieldUser = AppUser(email: "tech@gunnaire.com", role: .fieldTechnician)
        let admin = AppUser(email: "admin@gunnaire.com", role: .admin)
        let users = [standard, fieldUser, admin]
        let calls = [assignedCall, activeRoutedCall, unrelatedCall]

        let fieldVisible = AppAccess.visibleBillingServiceCallIDs(
            email: fieldUser.email,
            users: users,
            serviceCalls: calls,
            activeServiceCall: activeRoutedCall
        )
        let standardVisible = AppAccess.visibleBillingServiceCallIDs(
            email: standard.email,
            users: users,
            serviceCalls: calls,
            activeServiceCall: activeRoutedCall
        )
        let adminVisible = AppAccess.visibleBillingServiceCallIDs(
            email: admin.email,
            users: users,
            serviceCalls: calls,
            activeServiceCall: nil
        )

        let fieldJobIDs = AppAccess.visibleServiceCallIDs(
            email: fieldUser.email,
            users: users,
            serviceCalls: calls
        )
        let dispatcher = AppUser(email: "dispatch@gunnaire.com", role: .dispatcher)
        let dispatcherJobIDs = AppAccess.visibleServiceCallIDs(
            email: dispatcher.email,
            users: users + [dispatcher],
            serviceCalls: calls
        )

        #expect(fieldVisible == Set([assignedCall.id]))
        #expect(standardVisible.isEmpty)
        #expect(adminVisible == Set(calls.map(\.id)))
        #expect(fieldJobIDs == Set([assignedCall.id]))
        #expect(dispatcherJobIDs == Set(calls.map(\.id)))
        #expect(AppAccess.canAccessServiceCall(assignedCall, email: fieldUser.email, users: users, serviceCalls: calls))
        #expect(!AppAccess.canAccessServiceCall(activeRoutedCall, email: fieldUser.email, users: users, serviceCalls: calls))
    }

    @Test func serviceCallEquipmentSummaryIncludesManufacturer() async throws {
        let customer = Customer(name: "Equipment Customer")
        let call = ServiceCall(
            equipmentName: "Upstairs System",
            equipmentManufacturer: "Carrier",
            equipmentModel: "25VNA4",
            equipmentSerialNumber: "ABC123",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )

        #expect(call.equipmentSummary?.contains("Carrier") == true)
        #expect(call.equipmentSummary?.contains("S/N ABC123") == true)
    }

    @Test func splitSystemServiceReportRequiresHeadPressureAndCompressorRLA() async throws {
        let requiredKeys = Set(HVACEquipmentType.splitSystemAC.requiredReadingKeysForCompleteServiceReport)
        let definitionKeys = Set(HVACEquipmentType.splitSystemAC.readingDefinitions.map(\.key))

        #expect(definitionKeys.contains("head_pressure"))
        #expect(definitionKeys.contains("compressor_rla"))
        #expect(definitionKeys.contains("outdoor_fan_fla"))
        #expect(requiredKeys.contains("head_pressure"))
        #expect(requiredKeys.contains("compressor_rla"))
    }

    @Test func equipmentSpecificTechnicalReadingsExposeDropdownOptions() async throws {
        let splitDefinitions = Dictionary(uniqueKeysWithValues: HVACEquipmentType.splitSystemAC.readingDefinitions.map { ($0.key, $0) })
        let furnaceDefinitions = Dictionary(uniqueKeysWithValues: HVACEquipmentType.gasFurnace.readingDefinitions.map { ($0.key, $0) })
        let miniSplitDefinitions = Dictionary(uniqueKeysWithValues: HVACEquipmentType.miniSplit.readingDefinitions.map { ($0.key, $0) })

        #expect(splitDefinitions["refrigerant_type"]?.options.contains("R-410A") == true)
        #expect(splitDefinitions["metering_device"]?.options.contains("TXV") == true)
        #expect(splitDefinitions["contactor_condition"]?.options.isEmpty == false)
        #expect(furnaceDefinitions["fuel_type"]?.options.contains("Natural Gas") == true)
        #expect(furnaceDefinitions["ignition_type"]?.options.contains("Hot Surface Ignition") == true)
        #expect(miniSplitDefinitions["mode_tested"]?.options.contains("Dry") == true)
    }

    @Test func technicalServiceReportFlagsCompressorAmpDrawAboveRLA() async throws {
        let customer = Customer(name: "Amp Customer")
        let call = ServiceCall(
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .service,
            scheduledDate: Date(),
            customer: customer
        )

        call.setTechnicalReading("10", for: "compressor_rla")
        call.setTechnicalReading("12", for: "compressor_amps")
        call.setTechnicalReading("1.0", for: "outdoor_fan_fla")
        call.setTechnicalReading("1.2", for: "outdoor_fan_amps")

        #expect(call.serviceReportCrossReadingValidationIssueLabels.contains { $0.contains("Compressor Amps exceeds Compressor RLA") })
        #expect(call.serviceReportCrossReadingValidationIssueLabels.contains { $0.contains("Outdoor Fan Amps exceeds Outdoor Fan FLA") })
        #expect(call.serviceReportReadingValidationIssueLabels.contains { $0.contains("Compressor Amps exceeds Compressor RLA") })
        let compressorDefinition = try #require(call.technicalReadingDefinitions.first { $0.key == "compressor_amps" })
        let outdoorFanDefinition = try #require(call.technicalReadingDefinitions.first { $0.key == "outdoor_fan_amps" })
        #expect(call.technicalReadingValidationIssue(for: compressorDefinition)?.contains("Compressor RLA") == true)
        #expect(call.technicalReadingValidationIssue(for: outdoorFanDefinition)?.contains("Outdoor Fan FLA") == true)
    }

    @Test func technicalReportExporterIncludesHeadPressureAndAmpValidation() async throws {
        let customer = Customer(name: "Report Customer")
        let call = ServiceCall(
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .service,
            scheduledDate: Date(),
            customer: customer
        )

        call.setTechnicalReading("325", for: "head_pressure")
        call.setTechnicalReading("10", for: "compressor_rla")
        call.setTechnicalReading("12", for: "compressor_amps")

        let sections = CustomerDocumentExporter.technicalReportSectionSummaries(for: call)
        let rows = sections.flatMap(\.rows)

        #expect(rows.contains { $0.label == "Head Pressure (psig)" && $0.value == "325" })
        #expect(rows.contains { $0.value.contains("Compressor Amps exceeds Compressor RLA") })
    }

    @Test func customerEquipmentProfileAppliesToServiceCall() async throws {
        let customer = Customer(name: "Equipment Customer")
        let equipment = CustomerEquipment(
            customer: customer,
            equipmentType: .heatPump,
            name: "Downstairs Heat Pump",
            manufacturer: "Trane",
            modelNumber: "XV20i",
            serialNumber: "HP123",
            location: "Downstairs closet",
            installDate: Date(timeIntervalSince1970: 1_700_000_000),
            warrantyExpiration: Date(timeIntervalSince1970: 1_900_000_000),
            filterSize: "20x25x1",
            notes: "Variable speed"
        )
        let call = ServiceCall(type: .maintenance, scheduledDate: Date(), customer: customer)

        equipment.apply(to: call)

        #expect(call.customerEquipmentID == equipment.id)
        #expect(call.equipmentType == .heatPump)
        #expect(call.equipmentName == "Downstairs Heat Pump")
        #expect(call.equipmentManufacturer == "Trane")
        #expect(call.equipmentModel == "XV20i")
        #expect(call.equipmentSerialNumber == "HP123")
        #expect(call.equipmentLocation == "Downstairs closet")
        #expect(call.equipmentInstallDate == equipment.installDate)
        #expect(call.equipmentWarrantyExpiration == equipment.warrantyExpiration)
        #expect(call.filterSize == "20x25x1")
        #expect(call.equipmentNotes == "Variable speed")
    }

    @Test func customerEquipmentBaselineReadingsPrefillBlankServiceReportFields() async throws {
        let customer = Customer(name: "Equipment Customer")
        let baselineJSON = try #require(String(
            data: JSONEncoder().encode([
                "refrigerant_type": "R-410A",
                "metering_device": "TXV",
                "compressor_rla": "14.2",
                "suction_pressure": "118"
            ]),
            encoding: .utf8
        ))
        let equipment = CustomerEquipment(
            customer: customer,
            equipmentType: .splitSystemAC,
            name: "Downstairs AC",
            technicalBaselineReadingsJSON: baselineJSON
        )
        let call = ServiceCall(
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        call.setTechnicalReading("Existing", for: "metering_device")

        let appliedCount = equipment.applyTechnicalBaselines(to: call)

        #expect(appliedCount == 2)
        #expect(call.technicalReading(for: "refrigerant_type") == "R-410A")
        #expect(call.technicalReading(for: "compressor_rla") == "14.2")
        #expect(call.technicalReading(for: "metering_device") == "Existing")
        #expect(call.technicalReading(for: "suction_pressure").isEmpty)
    }

    @Test func customerEquipmentBaselineReadingsCaptureOnlyProfileSafeValues() async throws {
        let customer = Customer(name: "Equipment Customer")
        let equipment = CustomerEquipment(
            customer: customer,
            equipmentType: .splitSystemAC,
            name: "Downstairs AC"
        )
        let call = ServiceCall(
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        call.setTechnicalReading("R-454B", for: "refrigerant_type")
        call.setTechnicalReading("TXV", for: "metering_device")
        call.setTechnicalReading("17.5", for: "compressor_rla")
        call.setTechnicalReading("118", for: "suction_pressure")
        call.setTechnicalReading("10", for: "superheat")

        let capturedCount = equipment.updateTechnicalBaselines(from: call)

        #expect(capturedCount == 3)
        #expect(equipment.technicalBaselineReadings["refrigerant_type"] == "R-454B")
        #expect(equipment.technicalBaselineReadings["metering_device"] == "TXV")
        #expect(equipment.technicalBaselineReadings["compressor_rla"] == "17.5")
        #expect(equipment.technicalBaselineReadings["suction_pressure"] == nil)
        #expect(equipment.technicalBaselineReadings["superheat"] == nil)
    }

    @Test func applyingEquipmentProfilePrefillsTechnicalBaselinesWithoutOverwritingEnteredReadings() async throws {
        let customer = Customer(name: "Equipment Baseline Customer")
        let baselineJSON = try #require(String(
            data: JSONEncoder().encode([
                "refrigerant_type": "R-410A",
                "metering_device": "TXV",
                "compressor_rla": "16.4"
            ]),
            encoding: .utf8
        ))
        let equipment = CustomerEquipment(
            customer: customer,
            equipmentType: .splitSystemAC,
            name: "Downstairs AC",
            technicalBaselineReadingsJSON: baselineJSON
        )
        let call = ServiceCall(
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        call.setTechnicalReading("Existing piston", for: "metering_device")

        equipment.apply(to: call)

        #expect(call.customerEquipmentID == equipment.id)
        #expect(call.equipmentType == .splitSystemAC)
        #expect(call.technicalReading(for: "refrigerant_type") == "R-410A")
        #expect(call.technicalReading(for: "compressor_rla") == "16.4")
        #expect(call.technicalReading(for: "metering_device") == "Existing piston")
    }

    @Test func customerEquipmentBaselinesDoNotDefaultBeforeEquipmentTypeSelection() async throws {
        let customer = Customer(name: "Untyped Equipment Customer")
        let baselineJSON = try #require(String(
            data: JSONEncoder().encode([
                "refrigerant_type": "R-410A",
                "metering_device": "TXV"
            ]),
            encoding: .utf8
        ))
        let equipment = CustomerEquipment(
            customer: customer,
            name: "Unclassified System",
            technicalBaselineReadingsJSON: baselineJSON
        )
        let call = ServiceCall(
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )

        let appliedCount = equipment.applyTechnicalBaselines(to: call)
        call.setTechnicalReading("R-454B", for: "refrigerant_type")
        let capturedCount = equipment.updateTechnicalBaselines(from: call)

        #expect(appliedCount == 0)
        #expect(capturedCount == 0)
        #expect(call.technicalReading(for: "metering_device").isEmpty)
        #expect(equipment.technicalBaselineReadings["refrigerant_type"] == "R-410A")
    }

    @Test func serviceCallAttachmentProgressRecalculatesPhotoCounts() async throws {
        let customer = Customer(name: "Attachment Customer")
        let call = ServiceCall(type: .maintenance, scheduledDate: Date(), customer: customer)
        let beforePhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            kind: .beforePhoto,
            displayName: "before.jpg",
            localFilePath: "/tmp/before.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 100
        )
        let afterPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            kind: .afterPhoto,
            displayName: "after.jpg",
            localFilePath: "/tmp/after.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 100
        )
        let document = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            kind: .customerDocument,
            displayName: "notes.pdf",
            localFilePath: "/tmp/notes.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 100
        )

        call.refreshAttachmentProgress(from: [beforePhoto, afterPhoto, document])

        #expect(call.beforePhotoCount == 1)
        #expect(call.afterPhotoCount == 1)
        #expect(call.documentationStartedAt != nil)

        call.refreshAttachmentProgress(from: [afterPhoto, document])

        #expect(call.beforePhotoCount == 0)
        #expect(call.afterPhotoCount == 1)
    }

    @Test func googleCalendarPatchDoesNotOverwriteEventDetails() async throws {
        let customer = Customer(name: "Calendar Customer", address: "123 Main St")
        let call = ServiceCall(
            googleCalendarID: "primary",
            googleEventID: "google-event-1",
            googleEventManagedByApp: true,
            eventTitle: "Do not overwrite this title",
            siteAddress: "456 Field Rd",
            type: .service,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            duration: 3_600,
            customer: customer,
            notes: "Do not overwrite this body."
        )

        let patch = GoogleCalendarScheduleSync.makeScheduleOnlyPatch(for: call)
        let data = try JSONEncoder().encode(patch)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["start"] != nil)
        #expect(object["end"] != nil)
        #expect(object["summary"] == nil)
        #expect(object["description"] == nil)
        #expect(object["location"] == nil)
        #expect(object["attendees"] == nil)
        #expect(GoogleCalendarEventPatch.unsafeDetailKeys(in: data).isEmpty)
    }

    @Test func googleCalendarManagedPatchOmitsExistingGoogleDetails() async throws {
        let customer = Customer(name: "Calendar Customer", address: "123 Main St")
        let call = ServiceCall(
            googleCalendarID: "primary",
            googleEventID: "google-event-1",
            googleEventManagedByApp: true,
            eventTitle: "Customer Follow-up",
            siteAddress: "",
            type: .service,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            duration: 3_600,
            customer: customer,
            notes: "Bring replacement capacitor."
        )

        let remoteEvent = GoogleCalendarEvent(
            id: "google-event-1",
            summary: "Google title stays",
            description: "Google body stays",
            location: "Google location stays",
            htmlLink: nil,
            attendees: nil,
            extendedProperties: GoogleCalendarExtendedProperties(privateProperties: [
                "gunnaireManaged": "true",
                "gunnaireManagedVersion": "4",
                "gunnaireOrigin": "ios-app"
            ]),
            start: GoogleCalendarEventDate(date: nil, dateTime: "2027-01-15T13:00:00Z", timeZone: nil),
            end: GoogleCalendarEventDate(date: nil, dateTime: "2027-01-15T14:00:00Z", timeZone: nil)
        )

        let patch = GoogleCalendarScheduleSync.makeManagedEventPatch(for: call, remoteEvent: remoteEvent)
        let data = try JSONEncoder().encode(patch)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["start"] != nil)
        #expect(object["end"] != nil)
        #expect(object["summary"] == nil)
        #expect(object["description"] == nil)
        #expect(object["location"] == nil)
        #expect(object["extendedProperties"] == nil)
        #expect(Set(object.keys) == ["start", "end"])
        #expect(GoogleCalendarEventPatch.unsafeDetailKeys(in: data).isEmpty)
    }

    @Test func googleCalendarPatchGuardDetectsDetailScrubbingFields() async throws {
        let unsafePayload = Data("""
        {
          "start": { "dateTime": "2027-01-15T13:00:00Z", "timeZone": "America/New_York" },
          "end": { "dateTime": "2027-01-15T14:00:00Z", "timeZone": "America/New_York" },
          "summary": "",
          "description": "",
          "location": ""
        }
        """.utf8)

        #expect(GoogleCalendarEventPatch.unsafeDetailKeys(in: unsafePayload) == ["description", "location", "summary"])
        #expect(GoogleAuthError.unsafeCalendarPatch("description, location, summary").errorDescription?.contains("Blocked unsafe Google Calendar update") == true)
    }

    @Test func googleCalendarManagedPatchNeverWritesLocalDetailsOverGoogleFields() async throws {
        let customer = Customer(name: "Calendar Customer", address: "123 Main St")
        let call = ServiceCall(
            googleCalendarID: "primary",
            googleEventID: "google-event-1",
            googleEventManagedByApp: true,
            eventTitle: "Repair title",
            siteAddress: "456 Field Rd",
            type: .service,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            duration: 3_600,
            customer: customer,
            notes: "Repair body"
        )
        let remoteEvent = GoogleCalendarEvent(
            id: "google-event-1",
            summary: nil,
            description: "",
            location: "Google location stays",
            htmlLink: nil,
            attendees: nil,
            extendedProperties: GoogleCalendarExtendedProperties(privateProperties: [
                "gunnaireManaged": "true",
                "gunnaireManagedVersion": "4",
                "gunnaireOrigin": "ios-app"
            ]),
            start: GoogleCalendarEventDate(date: nil, dateTime: "2027-01-15T13:00:00Z", timeZone: nil),
            end: GoogleCalendarEventDate(date: nil, dateTime: "2027-01-15T14:00:00Z", timeZone: nil)
        )

        let patch = GoogleCalendarScheduleSync.makeManagedEventPatch(for: call, remoteEvent: remoteEvent)
        let data = try JSONEncoder().encode(patch)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["summary"] == nil)
        #expect(object["description"] == nil)
        #expect(object["location"] == nil)
        #expect(object["start"] != nil)
        #expect(object["end"] != nil)
        #expect(object["extendedProperties"] == nil)
        #expect(Set(object.keys) == ["start", "end"])
    }

    @Test func googleCalendarCreatePayloadDoesNotGenerateBodyWhenNotesAreBlank() async throws {
        let customer = Customer(name: "Calendar Customer", address: "")
        let call = ServiceCall(
            eventTitle: "Site reminder",
            siteAddress: "",
            type: .reminder,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            duration: 3_600,
            customer: customer,
            notes: "   "
        )

        let event = GoogleCalendarScheduleSync.makeCalendarCreateEvent(for: call)
        let data = try JSONEncoder().encode(event)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["summary"] as? String == "Site reminder")
        #expect(object["description"] == nil)
        #expect(object["location"] == nil)
        #expect(object["start"] != nil)
        #expect(object["end"] != nil)
        let properties = try #require(object["extendedProperties"] as? [String: Any])
        let privateProperties = try #require(properties["private"] as? [String: String])
        #expect(privateProperties["gunnaireManaged"] == "true")
    }

    @Test func googleCalendarCreatePayloadKeepsUserEnteredLocationAndDetailsVisible() async throws {
        let customer = Customer(name: "Calendar Customer", address: "")
        let call = ServiceCall(
            eventTitle: "Bid due reminder",
            siteAddress: "789 Customer Site Rd",
            type: .reminder,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            duration: 3_600,
            customer: customer,
            notes: "Submit bid package before noon."
        )

        let event = GoogleCalendarScheduleSync.makeCalendarCreateEvent(for: call)
        let data = try JSONEncoder().encode(event)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let description = try #require(object["description"] as? String)

        #expect(object["summary"] as? String == "Bid due reminder")
        #expect(object["location"] as? String == "789 Customer Site Rd")
        #expect(description == "Submit bid package before noon.")
        #expect(!description.contains("Service Address:"))
        #expect(!description.contains("Call Type:"))
    }

    @Test func olderGoogleCalendarManagedMarkersAreTreatedAsExternal() async throws {
        let oldManagedEvent = GoogleCalendarEvent(
            id: "old-managed-event",
            summary: "Existing Google Event",
            description: "Keep this body",
            location: "Keep this location",
            htmlLink: nil,
            attendees: nil,
            extendedProperties: GoogleCalendarExtendedProperties(privateProperties: ["gunnaireManaged": "true"]),
            start: GoogleCalendarEventDate(date: nil, dateTime: "2026-06-01T14:00:00Z", timeZone: nil),
            end: GoogleCalendarEventDate(date: nil, dateTime: "2026-06-01T15:00:00Z", timeZone: nil)
        )

        #expect(GoogleCalendarScheduleSync.isImportedEventManagedByApp(oldManagedEvent) == false)
    }

    @Test func importedGoogleCalendarEventsRemainReadOnlyAfterLocalEdits() async throws {
        let customer = Customer(name: "Calendar Customer", address: "123 Main St")
        let call = ServiceCall(
            googleCalendarID: "primary",
            googleEventID: "google-owned-event",
            googleEventManagedByApp: false,
            eventTitle: "Locally edited title",
            siteAddress: "Locally edited location",
            type: .service,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            duration: 3_600,
            customer: customer,
            notes: "Locally edited details"
        )

        #expect(GoogleCalendarScheduleSync.isExternalGoogleCalendarEvent(call) == true)
        #expect(GoogleCalendarScheduleSync.shouldPreserveExternalGoogleCalendarDetails(for: call) == true)
        #expect(GoogleCalendarScheduleSync.shouldAllowGoogleCalendarWrite(for: call) == false)
        #expect(GoogleCalendarScheduleSync.shouldPublishAfterLocalSave(for: call) == false)
        #expect(GoogleCalendarScheduleSync.shouldSelectGoogleCalendarBeforeCreate(for: call) == false)
        #expect(GoogleCalendarScheduleSync.shouldPatchExistingGoogleCalendarEvent(for: call, remoteEvent: nil) == false)
    }

    @Test func appManagedGoogleCalendarEventsPublishScheduleOnlyAfterLocalSave() async throws {
        let customer = Customer(name: "Calendar Customer", address: "123 Main St")
        let call = ServiceCall(
            googleCalendarID: "primary",
            googleEventID: "app-owned-event",
            googleEventManagedByApp: true,
            eventTitle: "Keep this Google title",
            siteAddress: "Keep this Google location",
            type: .service,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            duration: 3_600,
            customer: customer,
            notes: "Keep this Google body"
        )
        let remoteEvent = GoogleCalendarEvent(
            id: "app-owned-event",
            summary: "Existing Google title",
            description: "Existing Google body",
            location: "Existing Google location",
            htmlLink: nil,
            attendees: nil,
            extendedProperties: GoogleCalendarExtendedProperties(privateProperties: [
                "gunnaireManaged": "true",
                "gunnaireManagedVersion": "4",
                "gunnaireOrigin": "ios-app"
            ]),
            start: GoogleCalendarEventDate(date: nil, dateTime: "2027-01-15T13:00:00Z", timeZone: nil),
            end: GoogleCalendarEventDate(date: nil, dateTime: "2027-01-15T14:00:00Z", timeZone: nil)
        )

        #expect(GoogleCalendarScheduleSync.shouldPublishAfterLocalSave(for: call) == true)
        #expect(GoogleCalendarScheduleSync.shouldCreateGoogleCalendarEvent(for: call) == false)
        #expect(GoogleCalendarScheduleSync.shouldPatchExistingGoogleCalendarEvent(for: call, remoteEvent: remoteEvent) == true)

        let patch = GoogleCalendarScheduleSync.makeManagedEventPatch(for: call, remoteEvent: remoteEvent)
        let data = try JSONEncoder().encode(patch)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(object.keys) == ["start", "end"])
        #expect(GoogleCalendarEventPatch.unsafeDetailKeys(in: data).isEmpty)
    }

    @Test func externalGoogleCalendarImportDoesNotReplaceLocalDetailsWithBlankRemoteFields() async throws {
        #expect(GoogleCalendarScheduleSync.mergedImportedCalendarText(
            remoteValue: " ",
            existingValue: "Customer supplied title",
            isManagedByApp: false
        ) == "Customer supplied title")
        #expect(GoogleCalendarScheduleSync.mergedImportedCalendarText(
            remoteValue: nil,
            existingValue: "123 Existing Location",
            isManagedByApp: false
        ) == "123 Existing Location")
        #expect(GoogleCalendarScheduleSync.mergedImportedCalendarText(
            remoteValue: "\n",
            existingValue: "Existing calendar body",
            isManagedByApp: false
        ) == "Existing calendar body")
    }

    @Test func externalGoogleCalendarImportDoesNotReplaceCorrectedTitleWithGeneratedCallType() async throws {
        #expect(GoogleCalendarScheduleSync.mergedImportedCalendarTitle(
            remoteValue: "Service",
            existingValue: "Bid package due for Oak Street",
            isManagedByApp: false
        ) == "Bid package due for Oak Street")
        #expect(GoogleCalendarScheduleSync.mergedImportedCalendarTitle(
            remoteValue: "Holidays",
            existingValue: "Bid package due for Oak Street",
            isManagedByApp: false
        ) == "Holidays")
    }

    @Test func externalGoogleCalendarImportDoesNotReplaceCorrectedBodyWithGeneratedGunnAireText() async throws {
        let generatedBody = """
        Customer: GunnAire Calendar Import
        Service Address: 123 Main St
        Call Type: Service
        """
        #expect(GoogleCalendarScheduleSync.mergedImportedCalendarBody(
            remoteValue: generatedBody,
            existingValue: "Original Google notes with the real job context.",
            isManagedByApp: false
        ) == "Original Google notes with the real job context.")
        #expect(GoogleCalendarScheduleSync.mergedImportedCalendarBody(
            remoteValue: "Customer asked to move this to the afternoon.",
            existingValue: "Original Google notes with the real job context.",
            isManagedByApp: false
        ) == "Customer asked to move this to the afternoon.")
    }

    @Test func appManagedGoogleCalendarImportDoesNotScrubLocalMirrorWithBlankRemoteFields() async throws {
        #expect(GoogleCalendarScheduleSync.mergedImportedCalendarText(
            remoteValue: nil,
            existingValue: "Old local location",
            isManagedByApp: true
        ) == "Old local location")
        #expect(GoogleCalendarScheduleSync.mergedImportedCalendarBody(
            remoteValue: " ",
            existingValue: "Existing local body",
            isManagedByApp: true
        ) == "Existing local body")
        #expect(GoogleCalendarScheduleSync.mergedImportedCalendarText(
            remoteValue: " Updated remote body ",
            existingValue: "Old local body",
            isManagedByApp: true
        ) == "Updated remote body")
    }

    @Test func customerEquipmentProfileCanBeUpdatedInPlace() async throws {
        let equipment = CustomerEquipment(
            equipmentType: .splitSystemAC,
            name: "Old System",
            manufacturer: "Old Brand",
            isActive: false
        )

        equipment.updateFrom(
            equipmentType: .gasFurnace,
            name: "Main Furnace",
            manufacturer: "Carrier",
            modelNumber: "59TN6",
            serialNumber: "FURN123",
            location: "Attic",
            installDate: Date(timeIntervalSince1970: 1_600_000_000),
            warrantyExpiration: nil,
            filterSize: "16x25x1",
            notes: "Updated during maintenance",
            isActive: true
        )

        #expect(equipment.equipmentType == .gasFurnace)
        #expect(equipment.name == "Main Furnace")
        #expect(equipment.manufacturer == "Carrier")
        #expect(equipment.modelNumber == "59TN6")
        #expect(equipment.serialNumber == "FURN123")
        #expect(equipment.location == "Attic")
        #expect(equipment.warrantyExpiration == nil)
        #expect(equipment.filterSize == "16x25x1")
        #expect(equipment.notes == "Updated during maintenance")
        #expect(equipment.isActive == true)
    }

    @Test func serviceReportCanAppendEquipmentProfileHistoryWithoutDuplicates() async throws {
        let customer = Customer(name: "Equipment Customer")
        let estimateID = UUID()
        let invoiceID = UUID()
        let call = ServiceCall(
            equipmentName: "Main Furnace",
            equipmentTypeRaw: HVACEquipmentType.gasFurnace.rawValue,
            filterCondition: "Replaced",
            indoorCoilCondition: "Clean",
            serviceReportSummary: "Heating maintenance completed.",
            type: .maintenance,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            customer: customer,
            findingsSummary: "No faults found.",
            recommendedWorkSummary: "Return in six months.",
            linkedEstimateID: estimateID,
            linkedInvoiceID: invoiceID
        )
        call.setServiceActionStatus(.completed, for: "burner_assembly_checked")
        call.setServiceActionStatus(.needsService, for: "heat_exchanger_checked")
        let note = try #require(call.equipmentProfileServiceHistoryNote)
        let merged = try #require(CustomerEquipment.mergedNotes(existing: "Existing equipment note.", currentProfileNote: "Updated equipment note.", serviceHistoryNote: note))
        let mergedAgain = CustomerEquipment.mergedNotes(existing: merged, serviceHistoryNote: note)

        #expect(merged.contains("Updated equipment note."))
        #expect(merged.contains("Existing equipment note.") == false)
        #expect(note.contains("Maintenance"))
        #expect(note.contains("Heating maintenance completed."))
        #expect(note.contains("Actions:"))
        #expect(note.contains("Heat exchanger inspected: Needs Service"))
        #expect(note.contains("Filter: Replaced"))
        #expect(note.contains("Estimate: \(String(estimateID.uuidString.prefix(8)).uppercased())"))
        #expect(note.contains("Invoice: \(String(invoiceID.uuidString.prefix(8)).uppercased())"))
        #expect(merged.contains("Return in six months.") == true)
        #expect(mergedAgain == merged)
    }

    @Test func equipmentServiceHistoryIncludesCapturedTechnicalReadings() async throws {
        let customer = Customer(name: "Technical History Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "Cooling maintenance completed.",
            type: .maintenance,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            customer: customer
        )
        call.setTechnicalReading("72", for: "return_air_temp")
        call.setTechnicalReading("54", for: "supply_air_temp")
        call.setTechnicalReading("10", for: "superheat")
        call.setTechnicalReading("8", for: "subcooling")
        call.setTechnicalReading("238", for: "line_voltage")
        call.setTechnicalReading("7.4", for: "compressor_amps")

        let summary = try #require(call.technicalReadingServiceHistorySummary)
        let note = try #require(call.equipmentProfileServiceHistoryNote)

        #expect(summary.contains("Return Air Temp"))
        #expect(summary.contains("Temperature Split"))
        #expect(summary.contains("Superheat"))
        #expect(summary.contains("Line Voltage"))
        #expect(note.contains("Readings:"))
        #expect(note.contains("Compressor Amps"))
    }

    @Test func equipmentUnresolvedServiceConcernsCarryForwardUntilCleared() async throws {
        let customer = Customer(name: "Concern Customer")
        let equipment = CustomerEquipment(
            customer: customer,
            equipmentType: .gasFurnace,
            name: "Main Furnace",
            serialNumber: "FURN-1"
        )
        let olderCall = ServiceCall(
            customerEquipmentID: equipment.id,
            equipmentTypeRaw: HVACEquipmentType.gasFurnace.rawValue,
            type: .maintenance,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            customer: customer,
            status: .completed
        )
        olderCall.setServiceActionStatus(.needsService, for: "heat_exchanger_checked")
        olderCall.setServiceActionStatus(.monitor, for: "burner_assembly_checked")

        let newerCall = ServiceCall(
            customerEquipmentID: equipment.id,
            equipmentTypeRaw: HVACEquipmentType.gasFurnace.rawValue,
            type: .maintenance,
            scheduledDate: Date(timeIntervalSince1970: 1_800_086_400),
            customer: customer,
            status: .completed
        )
        newerCall.setServiceActionStatus(.completed, for: "heat_exchanger_checked")

        let summary = try #require(equipment.unresolvedServiceConcernSummary(
            in: [olderCall, newerCall],
            now: Date(timeIntervalSince1970: 1_800_172_800)
        ))

        #expect(summary.contains("Burner assembly inspected: Monitor"))
        #expect(summary.contains("Heat exchanger inspected") == false)
    }

    @Test func equipmentUnresolvedServiceConcernsIgnoreCancelledFutureAndOtherEquipment() async throws {
        let customer = Customer(name: "Concern Customer")
        let equipment = CustomerEquipment(customer: customer, name: "Downstairs AC", serialNumber: "AC-1")
        let otherEquipment = CustomerEquipment(customer: customer, name: "Upstairs AC", serialNumber: "AC-2")
        let currentCall = ServiceCall(
            customerEquipmentID: equipment.id,
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            customer: customer,
            status: .completed
        )
        currentCall.setServiceActionStatus(.needsService, for: "condenser_coil_serviced")
        let cancelledCall = ServiceCall(
            customerEquipmentID: equipment.id,
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: Date(timeIntervalSince1970: 1_800_086_400),
            customer: customer,
            status: .cancelled
        )
        cancelledCall.setServiceActionStatus(.needsService, for: "electrical_connections_checked")
        let futureCall = ServiceCall(
            customerEquipmentID: equipment.id,
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: Date(timeIntervalSince1970: 1_800_172_800),
            customer: customer,
            status: .scheduled
        )
        futureCall.setServiceActionStatus(.needsService, for: "evaporator_coil_checked")
        let otherCall = ServiceCall(
            customerEquipmentID: otherEquipment.id,
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            customer: customer,
            status: .completed
        )
        otherCall.setServiceActionStatus(.needsService, for: "electrical_connections_checked")

        let summary = try #require(equipment.unresolvedServiceConcernSummary(
            in: [currentCall, cancelledCall, futureCall, otherCall],
            now: Date(timeIntervalSince1970: 1_800_100_000)
        ))

        #expect(summary.contains("Condenser coil inspected/washed: Needs Service"))
        #expect(summary.contains("Electrical connections checked") == false)
        #expect(summary.contains("Evaporator coil inspected") == false)
    }

    @Test func customerEquipmentProfileMatchesLinkedAndSerializedServiceCalls() async throws {
        let customer = Customer(name: "Equipment Customer")
        let otherCustomer = Customer(name: "Other Customer")
        let equipment = CustomerEquipment(
            customer: customer,
            equipmentType: .gasFurnace,
            name: "Main Furnace",
            manufacturer: "Carrier",
            modelNumber: "59TN6",
            serialNumber: "FURN123"
        )
        let linkedCall = ServiceCall(
            customerEquipmentID: equipment.id,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        let serialMatchedCall = ServiceCall(
            equipmentName: "Different label",
            equipmentSerialNumber: " furn123 ",
            type: .service,
            scheduledDate: Date(),
            customer: customer
        )
        let nameModelMatchedCall = ServiceCall(
            equipmentName: "Main Furnace",
            equipmentModel: "59tn6",
            type: .service,
            scheduledDate: Date(),
            customer: customer
        )
        let otherCustomerCall = ServiceCall(
            equipmentSerialNumber: "FURN123",
            type: .service,
            scheduledDate: Date(),
            customer: otherCustomer
        )

        #expect(equipment.matches(linkedCall))
        #expect(equipment.matches(serialMatchedCall))
        #expect(equipment.matches(nameModelMatchedCall))
        #expect(equipment.matches(otherCustomerCall) == false)
    }

    @Test func customerEquipmentServiceHistorySummarizesLastAndNextJobs() async throws {
        let customer = Customer(name: "Equipment Customer")
        let equipment = CustomerEquipment(
            customer: customer,
            equipmentType: .heatPump,
            name: "Downstairs Heat Pump",
            serialNumber: "HP123"
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let pastCall = ServiceCall(
            equipmentSerialNumber: "HP123",
            type: .maintenance,
            scheduledDate: now.addingTimeInterval(-86_400 * 30),
            customer: customer,
            status: .completed
        )
        let futureCall = ServiceCall(
            equipmentSerialNumber: "HP123",
            type: .maintenance,
            scheduledDate: now.addingTimeInterval(86_400 * 30),
            customer: customer,
            status: .scheduled
        )

        let summary = try #require(equipment.serviceHistorySummary(in: [pastCall, futureCall], now: now))

        #expect(summary.contains("Last:"))
        #expect(summary.contains("Next:"))
        #expect(summary.contains("2 jobs"))
    }

    @Test func customerEquipmentLatestTechnicalReadingsUseMostRecentCompletedMatchingJob() async throws {
        let customer = Customer(name: "Equipment Customer")
        let equipment = CustomerEquipment(
            customer: customer,
            equipmentType: .splitSystemAC,
            name: "Downstairs AC",
            serialNumber: "AC123"
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let olderCall = ServiceCall(
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: now.addingTimeInterval(-86_400 * 60),
            customer: customer,
            status: .completed
        )
        olderCall.setTechnicalReading("14", for: "superheat")
        let latestCall = ServiceCall(
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: now.addingTimeInterval(-86_400 * 3),
            customer: customer,
            status: .completed
        )
        latestCall.setTechnicalReading("9", for: "superheat")
        latestCall.setTechnicalReading("240", for: "line_voltage")
        let futureCall = ServiceCall(
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: now.addingTimeInterval(86_400 * 3),
            customer: customer,
            status: .scheduled
        )
        futureCall.setTechnicalReading("999", for: "line_voltage")

        let summary = try #require(equipment.latestTechnicalReadingsSummary(in: [olderCall, latestCall, futureCall], now: now))

        #expect(summary.contains("Superheat"))
        #expect(summary.contains("9"))
        #expect(summary.contains("Line Voltage"))
        #expect(summary.contains("240"))
        #expect(summary.contains("999") == false)
        #expect(summary.contains("14") == false)
    }

    @Test func customerEquipmentRecentTechnicalTrendSummarizesChangedReadings() async throws {
        let customer = Customer(name: "Trend Customer")
        let equipment = CustomerEquipment(
            customer: customer,
            equipmentType: .splitSystemAC,
            name: "Downstairs AC",
            serialNumber: "AC-TREND"
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let olderCall = ServiceCall(
            equipmentSerialNumber: "AC-TREND",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: now.addingTimeInterval(-86_400 * 90),
            customer: customer,
            status: .completed
        )
        olderCall.setTechnicalReading("9", for: "superheat")
        olderCall.setTechnicalReading("8", for: "subcooling")
        olderCall.setTechnicalReading("7.2", for: "compressor_amps")
        olderCall.setTechnicalReading("Normal", for: "condenser_condition")
        let latestCall = ServiceCall(
            customerEquipmentID: equipment.id,
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: now.addingTimeInterval(-86_400),
            customer: customer,
            status: .completed
        )
        latestCall.setTechnicalReading("14", for: "superheat")
        latestCall.setTechnicalReading("8.0", for: "subcooling")
        latestCall.setTechnicalReading("8.4", for: "compressor_amps")
        latestCall.setTechnicalReading("Needs Cleaning", for: "condenser_condition")
        let cancelledCall = ServiceCall(
            customerEquipmentID: equipment.id,
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: now,
            customer: customer,
            status: .cancelled
        )
        cancelledCall.setTechnicalReading("99", for: "superheat")

        let trend = try #require(equipment.recentTechnicalTrendSummary(
            in: [olderCall, latestCall, cancelledCall],
            now: now
        ))
        let context = try #require(equipment.latestServiceContextSummary(
            in: [olderCall, latestCall, cancelledCall],
            now: now
        ))

        #expect(trend.contains("Superheat: 14"))
        #expect(trend.contains("was 9"))
        #expect(trend.contains("Compressor Amps: 8.4"))
        #expect(trend.contains("Condenser Condition: Needs Cleaning"))
        #expect(trend.contains("Subcooling") == false)
        #expect(trend.contains("99") == false)
        #expect(context.contains("Trends:"))
    }

    @Test func customerEquipmentRecentTechnicalTrendRequiresPriorChangedReading() async throws {
        let customer = Customer(name: "Stable Trend Customer")
        let equipment = CustomerEquipment(
            customer: customer,
            equipmentType: .gasFurnace,
            name: "Main Furnace",
            serialNumber: "FURN-STABLE"
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let olderCall = ServiceCall(
            equipmentSerialNumber: "FURN-STABLE",
            equipmentTypeRaw: HVACEquipmentType.gasFurnace.rawValue,
            type: .maintenance,
            scheduledDate: now.addingTimeInterval(-86_400 * 180),
            customer: customer,
            status: .completed
        )
        olderCall.setTechnicalReading("52", for: "temperature_rise")
        let latestCall = ServiceCall(
            customerEquipmentID: equipment.id,
            equipmentTypeRaw: HVACEquipmentType.gasFurnace.rawValue,
            type: .maintenance,
            scheduledDate: now.addingTimeInterval(-86_400),
            customer: customer,
            status: .completed
        )
        latestCall.setTechnicalReading("52.0", for: "temperature_rise")

        #expect(equipment.recentTechnicalTrendSummary(in: [olderCall, latestCall], now: now) == nil)
        #expect(equipment.recentTechnicalTrendSummary(in: [latestCall], now: now) == nil)
    }

    @Test func customerEquipmentLatestConcernSummaryShowsOnlyOpenServiceActions() async throws {
        let customer = Customer(name: "Equipment Concern Customer")
        let equipment = CustomerEquipment(
            customer: customer,
            equipmentType: .splitSystemAC,
            name: "Downstairs AC",
            serialNumber: "AC123"
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let olderCall = ServiceCall(
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: now.addingTimeInterval(-86_400 * 30),
            customer: customer,
            status: .completed
        )
        olderCall.setServiceActionStatus(.needsService, for: "condenser_coil_serviced")
        let latestCall = ServiceCall(
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: now.addingTimeInterval(-86_400 * 2),
            customer: customer,
            status: .completed
        )
        latestCall.setServiceActionStatus(.monitor, for: "condensate_drain_checked")
        latestCall.setServiceActionStatus(.needsService, for: "electrical_connections_checked")
        latestCall.setServiceActionStatus(.completed, for: "filter_checked")
        latestCall.setServiceActionStatus(.notApplicable, for: "thermostat_verified")

        let summary = try #require(equipment.latestServiceConcernSummary(in: [olderCall, latestCall], now: now))

        #expect(summary.contains("Electrical connections inspected: Needs Service"))
        #expect(summary.contains("Condensate drain checked/treated: Monitor"))
        #expect(summary.contains("Filter checked/replaced") == false)
        #expect(summary.contains("Thermostat operation verified") == false)
        #expect(summary.contains("Condenser coil inspected/washed") == false)
    }

    @Test func serviceCallOpenConcernRowsExposeNeedsServiceAndMonitorActions() async throws {
        let customer = Customer(name: "Current Concern Customer")
        let call = ServiceCall(
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        call.setServiceActionStatus(.monitor, for: "condensate_drain_checked")
        call.setServiceActionStatus(.needsService, for: "condenser_coil_serviced")
        call.setServiceActionStatus(.completed, for: "electrical_connections_checked")
        call.setServiceActionStatus(.notApplicable, for: "thermostat_verified")

        let rows = call.openServiceConcernRows

        #expect(rows.first?.label == "Condenser coil inspected/washed")
        #expect(rows.first?.value == "Needs Service")
        #expect(rows.contains { $0.label == "Condensate drain checked/treated" && $0.value == "Monitor" })
        #expect(rows.contains { $0.label == "Electrical connections checked" } == false)
        #expect(rows.contains { $0.label == "Thermostat operation verified" } == false)
    }

    @Test func serviceCallOperationalSearchMatchesDocumentationEquipmentAndConcernContext() async throws {
        let customer = Customer(
            name: "Schedule Search Customer",
            phone: "555-1122",
            email: "schedule@example.com",
            address: "123 Schedule Way"
        )
        let technician = Technician(name: "Alex Tech", contactInfo: "alex@example.com")
        let call = ServiceCall(
            eventTitle: "Cooling diagnostic",
            siteAddress: "456 Roof Access",
            equipmentName: "Roof RTU",
            equipmentManufacturer: "Carrier",
            equipmentModel: "48TC",
            equipmentSerialNumber: "RTU123",
            equipmentLocation: "Roof curb 2",
            equipmentTypeRaw: HVACEquipmentType.packageUnit.rawValue,
            serviceReportSummary: "Economizer operation needs follow-up.",
            type: .maintenance,
            scheduledDate: Date(),
            assignedTechnician: technician,
            customer: customer,
            notes: "Access through north ladder.",
            followUpRequired: true,
            followUpAction: "Return with economizer sensor."
        )
        call.setTechnicalReading("325", for: "flue_temp")
        call.setServiceActionStatus(HVACServiceActionStatus.needsService, for: "economizer_checked")

        #expect(call.matchesOperationalSearch("roof curb"))
        #expect(call.matchesOperationalSearch("economizer sensor"))
        #expect(call.matchesOperationalSearch("flue temp"))
        #expect(call.matchesOperationalSearch("alex tech"))
        #expect(call.matchesOperationalSearch("north ladder"))
        #expect(call.matchesOperationalSearch("unrelated boiler") == false)
    }

    @Test func customerEquipmentLatestServiceContextSummarizesReportAndReadings() async throws {
        let customer = Customer(name: "Equipment Context Customer")
        let equipment = CustomerEquipment(
            customer: customer,
            equipmentType: .splitSystemAC,
            name: "Downstairs AC",
            serialNumber: "AC123"
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let previousCall = ServiceCall(
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "Cleaned condenser and verified charge.",
            type: .maintenance,
            scheduledDate: now.addingTimeInterval(-86_400 * 12),
            customer: customer,
            status: .completed
        )
        previousCall.setTechnicalReading("10", for: "superheat")
        previousCall.setTechnicalReading("8", for: "subcooling")
        previousCall.setServiceActionStatus(.completed, for: "condenser_coil_serviced")
        previousCall.setServiceActionStatus(.monitor, for: "condensate_drain_checked")
        let currentCall = ServiceCall(
            equipmentSerialNumber: "AC123",
            customerEquipmentID: equipment.id,
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "Current report should not be used.",
            type: .maintenance,
            scheduledDate: now,
            customer: customer,
            status: .completed
        )
        currentCall.setTechnicalReading("999", for: "superheat")

        let summary = try #require(equipment.latestServiceContextSummary(
            in: [previousCall],
            now: now
        ))
        let excludingCurrentSummary = try #require(equipment.latestServiceContextSummary(
            in: [previousCall, currentCall].filter { $0.id != currentCall.id },
            now: now
        ))

        #expect(summary.contains("Last service:"))
        #expect(summary.contains("Cleaned condenser"))
        #expect(summary.contains("Superheat"))
        #expect(summary.contains("10"))
        #expect(summary.contains("Subcooling"))
        #expect(summary.contains("8"))
        #expect(summary.contains("Actions:"))
        #expect(summary.contains("Condensate drain checked/treated: Monitor"))
        #expect(summary.contains("Open Concerns:"))
        #expect(summary.contains("Condensate drain checked/treated: Monitor"))
        #expect(excludingCurrentSummary.contains("999") == false)
    }

    @Test func customerEquipmentLatestServiceContextCarriesOpenConcernsUntilResolved() async throws {
        let customer = Customer(name: "Open Concern Customer")
        let equipment = CustomerEquipment(
            customer: customer,
            equipmentType: .splitSystemAC,
            name: "Downstairs AC",
            serialNumber: "AC123"
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let olderCall = ServiceCall(
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: now.addingTimeInterval(-86_400 * 45),
            customer: customer,
            status: .completed
        )
        olderCall.setServiceActionStatus(.needsService, for: "condenser_coil_serviced")
        olderCall.setServiceActionStatus(.monitor, for: "condensate_drain_checked")
        let latestCall = ServiceCall(
            customerEquipmentID: equipment.id,
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "Returned for follow-up.",
            type: .maintenance,
            scheduledDate: now.addingTimeInterval(-86_400 * 3),
            customer: customer,
            status: .completed
        )
        latestCall.setServiceActionStatus(.completed, for: "condenser_coil_serviced")

        let summary = try #require(equipment.latestServiceContextSummary(
            in: [olderCall, latestCall],
            now: now
        ))

        #expect(summary.contains("Open Concerns:"))
        #expect(summary.contains("Condensate drain checked/treated: Monitor"))
        #expect(summary.contains("Condenser coil inspected/washed: Needs Service") == false)
    }

    @Test func customerEquipmentOpenFollowUpSummaryPrioritizesDueActions() async throws {
        let customer = Customer(name: "Equipment Follow Up Customer")
        let equipment = CustomerEquipment(
            customer: customer,
            equipmentType: .splitSystemAC,
            name: "Downstairs AC",
            serialNumber: "AC123"
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let overdueCall = ServiceCall(
            customerEquipmentID: equipment.id,
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: now.addingTimeInterval(-86_400 * 10),
            customer: customer,
            followUpRequired: true,
            followUpAction: "Return to replace weak capacitor.",
            followUpDueDate: now.addingTimeInterval(-86_400)
        )
        let upcomingCall = ServiceCall(
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .service,
            scheduledDate: now.addingTimeInterval(-86_400 * 2),
            customer: customer,
            followUpRequired: true,
            followUpAction: "Verify condensate drain after cleaning.",
            followUpDueDate: now.addingTimeInterval(86_400 * 3)
        )
        let cancelledCall = ServiceCall(
            customerEquipmentID: equipment.id,
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .service,
            scheduledDate: now,
            customer: customer,
            status: .cancelled,
            followUpRequired: true,
            followUpAction: "Do not show cancelled action.",
            followUpDueDate: now.addingTimeInterval(-86_400 * 2)
        )
        let blankActionCall = ServiceCall(
            customerEquipmentID: equipment.id,
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .service,
            scheduledDate: now,
            customer: customer,
            followUpRequired: true,
            followUpAction: " ",
            followUpDueDate: now.addingTimeInterval(-86_400 * 3)
        )

        let summary = try #require(equipment.openFollowUpSummary(
            in: [upcomingCall, cancelledCall, overdueCall, blankActionCall],
            now: now
        ))

        #expect(summary.contains("Overdue"))
        #expect(summary.contains("Return to replace weak capacitor."))
        #expect(summary.contains("Due"))
        #expect(summary.contains("Verify condensate drain after cleaning."))
        #expect(summary.contains("Do not show cancelled action") == false)
    }

    @Test func serviceCallCopiesCompatiblePreviousTechnicalReadingsWithoutOverwritingCurrentValues() async throws {
        let customer = Customer(name: "Reading Copy Customer")
        let previousCall = ServiceCall(
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: Date(timeIntervalSince1970: 1_700_000_000),
            customer: customer
        )
        previousCall.setTechnicalReading("11", for: "superheat")
        previousCall.setTechnicalReading("242", for: "line_voltage")
        previousCall.setTechnicalReading("3.5", for: "gas_pressure_inlet")
        let currentCall = ServiceCall(
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            customer: customer
        )
        currentCall.setTechnicalReading("238", for: "line_voltage")

        let copied = currentCall.copyTechnicalReadings(from: previousCall)

        #expect(copied == 1)
        #expect(currentCall.technicalReading(for: "superheat") == "11")
        #expect(currentCall.technicalReading(for: "line_voltage") == "238")
        #expect(currentCall.technicalReading(for: "gas_pressure_inlet").isEmpty)
    }

    @Test func coolingEquipmentReadingDefinitionsIncludeStructuredRefrigerantOptions() async throws {
        let refrigerantDefinition = HVACEquipmentType.splitSystemAC.readingDefinitions.first {
            $0.key == "refrigerant_type"
        }
        let meteringDeviceDefinition = HVACEquipmentType.splitSystemAC.readingDefinitions.first {
            $0.key == "metering_device"
        }
        let superheatDefinition = HVACEquipmentType.splitSystemAC.readingDefinitions.first {
            $0.key == "superheat"
        }
        let suctionSaturationDefinition = HVACEquipmentType.splitSystemAC.readingDefinitions.first {
            $0.key == "suction_saturation_temp"
        }
        let liquidSaturationDefinition = HVACEquipmentType.splitSystemAC.readingDefinitions.first {
            $0.key == "liquid_saturation_temp"
        }

        #expect(refrigerantDefinition?.options.contains("R-410A") == true)
        #expect(refrigerantDefinition?.options.contains("R-454B") == true)
        #expect(meteringDeviceDefinition?.options.contains("TXV") == true)
        #expect(superheatDefinition?.options.isEmpty == true)
        #expect(suctionSaturationDefinition?.displayLabel == "Suction Saturation Temp (F)")
        #expect(liquidSaturationDefinition?.displayLabel == "Liquid Saturation Temp (F)")
    }

    @Test func technicalReadingDefinitionsIncludeFieldInputHints() async throws {
        let suctionPressure = try #require(HVACEquipmentType.splitSystemAC.readingDefinitions.first { $0.key == "suction_pressure" })
        let superheat = try #require(HVACEquipmentType.splitSystemAC.readingDefinitions.first { $0.key == "superheat" })
        let gasPressure = try #require(HVACEquipmentType.gasFurnace.readingDefinitions.first { $0.key == "gas_pressure_manifold" })
        let coReading = try #require(HVACEquipmentType.gasFurnace.readingDefinitions.first { $0.key == "co_ppm" })

        #expect(suctionPressure.inputHint?.contains("service ports") == true)
        #expect(superheat.inputHint?.contains("Calculate") == true)
        #expect(gasPressure.inputHint?.contains("manometer") == true)
        #expect(coReading.inputHint?.contains("carbon monoxide") == true)
    }

    @Test func calculatedTechnicalReadingDefinitionsExposeSourceGuidance() async throws {
        let split = try #require(HVACEquipmentType.splitSystemAC.readingDefinitions.first { $0.key == "temperature_split" })
        let superheat = try #require(HVACEquipmentType.splitSystemAC.readingDefinitions.first { $0.key == "superheat" })
        let subcooling = try #require(HVACEquipmentType.splitSystemAC.readingDefinitions.first { $0.key == "subcooling" })
        let totalStatic = try #require(HVACEquipmentType.airHandler.readingDefinitions.first { $0.key == "total_external_static" })
        let lineVoltage = try #require(HVACEquipmentType.splitSystemAC.readingDefinitions.first { $0.key == "line_voltage" })

        #expect(split.isCalculated)
        #expect(superheat.isCalculated)
        #expect(subcooling.isCalculated)
        #expect(totalStatic.isCalculated)
        #expect(lineVoltage.isCalculated == false)
        #expect(superheat.calculationSourceHint?.contains("Suction Line Temp") == true)
        #expect(subcooling.calculationSourceHint?.contains("Liquid Line Temp") == true)
        #expect(totalStatic.calculationSourceHint?.contains("Return Static") == true)
    }

    @Test func equipmentSpecificReportDefinitionsIncludeFieldServiceControls() async throws {
        let heatPumpKeys = Set(HVACEquipmentType.heatPump.readingDefinitions.map(\.key))
        let furnaceDefinitions = HVACEquipmentType.gasFurnace.readingDefinitions
        let waterHeaterDefinitions = HVACEquipmentType.waterHeater.readingDefinitions
        let airHandlerDefinitions = HVACEquipmentType.airHandler.readingDefinitions
        let packageUnitDefinitions = HVACEquipmentType.packageUnit.readingDefinitions
        let miniSplitDefinitions = HVACEquipmentType.miniSplit.readingDefinitions
        let iaqDefinitions = HVACEquipmentType.iaqAccessory.readingDefinitions

        #expect(heatPumpKeys.contains("reversing_valve_operation"))
        #expect(heatPumpKeys.contains("defrost_control_status"))
        #expect(furnaceDefinitions.first { $0.key == "ignition_type" }?.options.contains("Hot Surface Ignition") == true)
        #expect(furnaceDefinitions.first { $0.key == "heat_exchanger_condition" }?.options.contains("Needs Repair") == true)
        #expect(waterHeaterDefinitions.first { $0.key == "tank_condition" }?.options.contains("Replacement Recommended") == true)
        #expect(airHandlerDefinitions.first { $0.key == "blower_type" }?.options.contains("ECM Variable Speed") == true)
        #expect(packageUnitDefinitions.first { $0.key == "package_heat_type" }?.options.contains("Dual Fuel") == true)
        #expect(packageUnitDefinitions.contains { $0.key == "economizer_operation" })
        #expect(packageUnitDefinitions.contains { $0.key == "mixed_air_temp" })
        #expect(packageUnitDefinitions.contains { $0.key == "outdoor_air_damper_position" })
        #expect(packageUnitDefinitions.first { $0.key == "economizer_sensor_status" }?.options.contains("Needs Repair") == true)
        #expect(packageUnitDefinitions.contains { $0.key == "flue_temp" })
        #expect(packageUnitDefinitions.contains { $0.key == "co_ppm" })
        #expect(miniSplitDefinitions.first { $0.key == "mode_tested" }?.options.contains("Dry") == true)
        #expect(miniSplitDefinitions.contains { $0.key == "communication_voltage" })
        #expect(miniSplitDefinitions.contains { $0.key == "indoor_filter_condition" })
        #expect(miniSplitDefinitions.first { $0.key == "outdoor_coil_condition" }?.options.contains("Needs Cleaning") == true)
        #expect(miniSplitDefinitions.first { $0.key == "outdoor_fan_operation" }?.options.contains("Needs Repair") == true)
        #expect(iaqDefinitions.first { $0.key == "accessory_type" }?.options.contains("Humidifier") == true)
        #expect(iaqDefinitions.first { $0.key == "accessory_type" }?.options.contains("ERV") == true)
        #expect(iaqDefinitions.contains { $0.key == "uv_lamp_status" })
        #expect(iaqDefinitions.contains { $0.key == "return_humidity" })
    }

    @Test func miniSplitReportsRequireModeAndOutdoorUnitCondition() async throws {
        let requiredKeys = Set(HVACEquipmentType.miniSplit.requiredReadingKeysForCompleteServiceReport)
        let definitionKeys = Set(HVACEquipmentType.miniSplit.readingDefinitions.map(\.key))

        #expect(requiredKeys.contains("mode_tested"))
        #expect(requiredKeys.contains("outdoor_coil_condition"))
        #expect(requiredKeys.contains("outdoor_fan_operation"))
        #expect(requiredKeys.isSubset(of: definitionKeys))

        let mode = try #require(HVACEquipmentType.miniSplit.readingDefinitions.first { $0.key == "mode_tested" })
        let outdoorCoil = try #require(HVACEquipmentType.miniSplit.readingDefinitions.first { $0.key == "outdoor_coil_condition" })
        let outdoorFan = try #require(HVACEquipmentType.miniSplit.readingDefinitions.first { $0.key == "outdoor_fan_operation" })

        #expect(mode.inputHint?.contains("operating mode") == true)
        #expect(outdoorCoil.inputHint?.contains("outdoor coil") == true)
        #expect(outdoorFan.inputHint?.contains("outdoor fan") == true)
    }

    @Test func packageUnitReportsRequireCombustionSafetyReading() async throws {
        let requiredKeys = Set(HVACEquipmentType.packageUnit.requiredReadingKeysForCompleteServiceReport)
        let definitionKeys = Set(HVACEquipmentType.packageUnit.readingDefinitions.map(\.key))

        #expect(definitionKeys.contains("co_ppm"))
        #expect(definitionKeys.contains("flue_temp"))
        #expect(requiredKeys.contains("co_ppm"))
        #expect(requiredKeys.isSubset(of: definitionKeys))
    }

    @Test func packageUnitEconomizerDiagnosticsAreGroupedAndValidated() async throws {
        let packageDefinitions = HVACEquipmentType.packageUnit.readingDefinitions
        let mixedAir = try #require(packageDefinitions.first { $0.key == "mixed_air_temp" })
        let damperPosition = try #require(packageDefinitions.first { $0.key == "outdoor_air_damper_position" })
        let groupedDefinitions = ServiceCall.groupedTechnicalReadingDefinitions(for: packageDefinitions)

        #expect(groupedDefinitions.first { $0.title == "Air Temperatures" }?.definitions.contains(mixedAir) == true)
        #expect(groupedDefinitions.first { $0.title == "Airflow & Static" }?.definitions.contains(damperPosition) == true)
        #expect(mixedAir.validationIssue(for: "72") == nil)
        #expect(mixedAir.validationIssue(for: "165")?.contains("outside expected range") == true)
        #expect(damperPosition.validationIssue(for: "35") == nil)
        #expect(damperPosition.validationIssue(for: "135")?.contains("0-100") == true)
    }

    @Test func packageUnitCoolingOnlyReportsDoNotRequireCombustionReadings() async throws {
        let customer = Customer(name: "Cooling Only RTU Customer")
        let call = ServiceCall(
            equipmentTypeRaw: HVACEquipmentType.packageUnit.rawValue,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )

        #expect(call.effectiveRequiredReadingKeysForCompleteServiceReport.contains("co_ppm"))

        call.setTechnicalReading("Cooling Only", for: "package_heat_type")

        #expect(call.effectiveRequiredReadingKeysForCompleteServiceReport.contains("package_heat_type"))
        #expect(call.effectiveRequiredReadingKeysForCompleteServiceReport.contains("co_ppm") == false)
        #expect(call.effectiveRequiredReadingKeysForCompleteServiceReport.contains("gas_pressure_inlet") == false)
        #expect(call.effectiveRequiredReadingKeysForCompleteServiceReport.contains("gas_pressure_manifold") == false)
        #expect(call.effectiveRequiredReadingKeysForCompleteServiceReport.contains("flue_temp") == false)
        #expect(call.effectiveRequiredReadingKeysForCompleteServiceReport.contains("heat_strip_amps") == false)
        #expect(call.effectiveRequiredReadingKeysForCompleteServiceReport.contains("heat_exchanger_condition") == false)
        #expect(call.requiredTechnicalReadingDefinitions.contains { $0.key == "co_ppm" } == false)
    }

    @Test func packageUnitHeatTypeDrivesHeatingSpecificRequiredReadings() async throws {
        let customer = Customer(name: "Dynamic RTU Customer")
        let call = ServiceCall(
            equipmentTypeRaw: HVACEquipmentType.packageUnit.rawValue,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )

        call.setTechnicalReading("Gas Heat", for: "package_heat_type")

        #expect(call.effectiveRequiredReadingKeysForCompleteServiceReport.contains("gas_pressure_inlet"))
        #expect(call.effectiveRequiredReadingKeysForCompleteServiceReport.contains("gas_pressure_manifold"))
        #expect(call.effectiveRequiredReadingKeysForCompleteServiceReport.contains("flue_temp"))
        #expect(call.effectiveRequiredReadingKeysForCompleteServiceReport.contains("o2_percent"))
        #expect(call.effectiveRequiredReadingKeysForCompleteServiceReport.contains("co2_percent"))
        #expect(call.effectiveRequiredReadingKeysForCompleteServiceReport.contains("co_ppm"))
        #expect(call.effectiveRequiredReadingKeysForCompleteServiceReport.contains("heat_exchanger_condition"))
        #expect(call.effectiveRequiredReadingKeysForCompleteServiceReport.contains("heat_strip_amps") == false)

        call.setTechnicalReading("Electric Heat", for: "package_heat_type")

        #expect(call.effectiveRequiredReadingKeysForCompleteServiceReport.contains("heat_strip_amps"))
        #expect(call.effectiveRequiredReadingKeysForCompleteServiceReport.contains("gas_pressure_inlet") == false)
        #expect(call.effectiveRequiredReadingKeysForCompleteServiceReport.contains("gas_pressure_manifold") == false)
        #expect(call.effectiveRequiredReadingKeysForCompleteServiceReport.contains("flue_temp") == false)
        #expect(call.effectiveRequiredReadingKeysForCompleteServiceReport.contains("co_ppm") == false)
        #expect(call.effectiveRequiredReadingKeysForCompleteServiceReport.contains("heat_exchanger_condition") == false)

        call.setTechnicalReading("Dual Fuel", for: "package_heat_type")

        #expect(call.effectiveRequiredReadingKeysForCompleteServiceReport.contains("gas_pressure_inlet"))
        #expect(call.effectiveRequiredReadingKeysForCompleteServiceReport.contains("gas_pressure_manifold"))
        #expect(call.effectiveRequiredReadingKeysForCompleteServiceReport.contains("flue_temp"))
        #expect(call.effectiveRequiredReadingKeysForCompleteServiceReport.contains("co_ppm"))
        #expect(call.effectiveRequiredReadingKeysForCompleteServiceReport.contains("heat_exchanger_condition"))
        #expect(call.effectiveRequiredReadingKeysForCompleteServiceReport.contains("heat_strip_amps"))
    }

    @Test func packageUnitEconomizerReportsRequireEconomizerDiagnosticsWhenPresent() async throws {
        let customer = Customer(name: "Economizer RTU Customer")
        let call = ServiceCall(
            equipmentTypeRaw: HVACEquipmentType.packageUnit.rawValue,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )

        #expect(call.effectiveRequiredReadingKeysForCompleteServiceReport.contains("mixed_air_temp") == false)

        call.setTechnicalReading("Normal", for: "economizer_operation")

        #expect(call.effectiveRequiredReadingKeysForCompleteServiceReport.contains("mixed_air_temp"))
        #expect(call.effectiveRequiredReadingKeysForCompleteServiceReport.contains("outdoor_air_damper_position"))
        #expect(call.effectiveRequiredReadingKeysForCompleteServiceReport.contains("economizer_sensor_status"))
        #expect(call.requiredTechnicalReadingDefinitions.contains { $0.key == "mixed_air_temp" })

        call.setTechnicalReading("Not Applicable", for: "economizer_operation")

        #expect(call.effectiveRequiredReadingKeysForCompleteServiceReport.contains("mixed_air_temp") == false)
        #expect(call.requiredTechnicalReadingDefinitions.contains { $0.key == "mixed_air_temp" } == false)
    }

    @Test func equipmentSpecificServiceActionsDriveMaintenanceCloseout() async throws {
        let splitActions = HVACEquipmentType.splitSystemAC.serviceActionDefinitions
        let furnaceActions = HVACEquipmentType.gasFurnace.serviceActionDefinitions
        let iaqActions = HVACEquipmentType.iaqAccessory.serviceActionDefinitions

        #expect(splitActions.contains { $0.key == "condenser_coil_serviced" && $0.required })
        #expect(splitActions.contains { $0.key == "condensate_drain_checked" && $0.group == "Drainage" })
        #expect(furnaceActions.contains { $0.key == "heat_exchanger_checked" && $0.group == "Safety" && $0.required })
        #expect(furnaceActions.contains { $0.key == "flame_sensor_serviced" })
        #expect(iaqActions.contains { $0.key == "filter_or_media_serviced" && $0.required })
        #expect(iaqActions.contains { $0.key == "uv_lamp_checked" && !$0.required })
    }

    @Test func serviceCallStoresEquipmentServiceActionStatuses() async throws {
        let customer = Customer(name: "Action Customer")
        let call = ServiceCall(
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )

        call.setServiceActionStatus(.completed, for: "condenser_coil_serviced")
        call.setServiceActionStatus(.needsService, for: "condensate_drain_checked")

        #expect(call.serviceActionStatus(for: "condenser_coil_serviced") == .completed)
        #expect(call.serviceActionStatus(for: "condensate_drain_checked") == .needsService)
        #expect(call.populatedServiceActionRows.contains { $0.label == "Condenser coil inspected/washed" && $0.value == "Completed" })
        #expect(call.populatedServiceActionRows.contains { $0.label == "Condensate drain checked/treated" && $0.value == "Needs Service" })

        call.setServiceActionStatus(.notChecked, for: "condenser_coil_serviced")

        #expect(call.serviceActionStatus(for: "condenser_coil_serviced") == .notChecked)
        #expect(call.serviceActionStatus(for: "condensate_drain_checked") == .needsService)
    }

    @Test func serviceActionStatusesRequireSupportedEquipmentType() async throws {
        let customer = Customer(name: "Unsupported Action Customer")
        let call = ServiceCall(
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )

        call.setServiceActionStatus(.completed, for: "condenser_coil_serviced")
        #expect(call.serviceActionStatus(for: "condenser_coil_serviced") == .notChecked)
        #expect(call.serviceActionChecklistJSON == nil)

        call.equipmentType = .gasFurnace
        call.setServiceActionStatus(.completed, for: "condenser_coil_serviced")
        call.setServiceActionStatus(.needsService, for: "heat_exchanger_checked")

        #expect(call.serviceActionStatus(for: "condenser_coil_serviced") == .notChecked)
        #expect(call.serviceActionStatus(for: "heat_exchanger_checked") == .needsService)
        #expect(call.populatedServiceActionRows.contains { $0.label == "Heat exchanger inspected" && $0.value == "Needs Service" })
    }

    @Test func changingEquipmentTypePrunesIncompatibleServiceActions() async throws {
        let customer = Customer(name: "Equipment Change Customer")
        let call = ServiceCall(
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        call.setServiceActionStatus(.completed, for: "condenser_coil_serviced")
        call.setServiceActionStatus(.needsService, for: "heat_exchanger_checked")

        call.equipmentType = .gasFurnace

        #expect(call.serviceActionStatus(for: "condenser_coil_serviced") == .notChecked)
        #expect(call.serviceActionStatus(for: "heat_exchanger_checked") == .needsService)
        #expect(call.populatedServiceActionRows.contains { $0.label == "Condenser coil inspected/washed" } == false)
        #expect(call.populatedServiceActionRows.contains { $0.label == "Heat exchanger inspected" && $0.value == "Needs Service" })
    }

    @Test func serviceActionGroupBulkStatusOnlyUpdatesUncheckedItems() async throws {
        let customer = Customer(name: "Bulk Action Customer")
        let call = ServiceCall(
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        let coolingGroup = try #require(call.groupedServiceActionDefinitions.first { $0.title == "Cooling" })
        call.setServiceActionStatus(.needsService, for: "condenser_coil_serviced")

        let markedCount = call.markUncheckedServiceActions(.completed, in: coolingGroup)

        #expect(markedCount == coolingGroup.definitions.count - 1)
        #expect(call.serviceActionStatus(for: "condenser_coil_serviced") == .needsService)
        for definition in coolingGroup.definitions where definition.key != "condenser_coil_serviced" {
            #expect(call.serviceActionStatus(for: definition.key) == .completed)
        }
        #expect(call.diagnosticsCaptured)
    }

    @Test func maintenanceReportRequiresEquipmentServiceActions() async throws {
        let customer = Customer(name: "Maintenance Action Customer")
        let call = ServiceCall(
            equipmentName: "Main AC",
            equipmentModel: "24ABC",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "Cooling maintenance completed.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        for definition in call.requiredTechnicalReadingDefinitions {
            call.setTechnicalReading(definition.options.first ?? "1", for: definition.key)
        }

        #expect(call.serviceReportMissingRequiredItemLabels.contains("Condenser coil inspected/washed"))

        for definition in call.requiredServiceActionDefinitions {
            call.setServiceActionStatus(.completed, for: definition.key)
        }

        #expect(call.serviceReportMissingRequiredItemLabels.contains("Condenser coil inspected/washed") == false)
    }

    @Test func hvacEquipmentReadingDefinitionKeysAreUniquePerEquipmentType() async throws {
        for equipmentType in HVACEquipmentType.allCases {
            let keys = equipmentType.readingDefinitions.map(\.key)
            #expect(Set(keys).count == keys.count, "\(equipmentType.displayName) has duplicate technical reading keys")
        }
    }

    @Test func groupedTechnicalReadingsPreserveAllEquipmentFields() async throws {
        for equipmentType in HVACEquipmentType.allCases {
            let definitions = equipmentType.readingDefinitions
            let groupedDefinitions = ServiceCall.groupedTechnicalReadingDefinitions(for: definitions)
                .flatMap(\.definitions)

            #expect(groupedDefinitions.count == definitions.count, "\(equipmentType.displayName) reading grouping dropped or duplicated fields")
            #expect(Set(groupedDefinitions.map(\.key)) == Set(definitions.map(\.key)), "\(equipmentType.displayName) reading grouping changed field coverage")
        }
    }

    @Test func groupedTechnicalReadingsUseFieldServiceCategories() async throws {
        let splitGroups = ServiceCall.groupedTechnicalReadingDefinitions(for: HVACEquipmentType.splitSystemAC.readingDefinitions)
        let furnaceGroups = ServiceCall.groupedTechnicalReadingDefinitions(for: HVACEquipmentType.gasFurnace.readingDefinitions)
        let boilerGroups = ServiceCall.groupedTechnicalReadingDefinitions(for: HVACEquipmentType.boiler.readingDefinitions)
        let iaqGroups = ServiceCall.groupedTechnicalReadingDefinitions(for: HVACEquipmentType.iaqAccessory.readingDefinitions)

        #expect(splitGroups.first { $0.title == "Refrigerant Circuit" }?.definitions.contains { $0.key == "superheat" } == true)
        #expect(splitGroups.first { $0.title == "Electrical" }?.definitions.contains { $0.key == "compressor_amps" } == true)
        #expect(furnaceGroups.first { $0.title == "Combustion" }?.definitions.contains { $0.key == "flue_temp" } == true)
        #expect(boilerGroups.first { $0.title == "Hydronics" }?.definitions.contains { $0.key == "water_temp_supply" } == true)
        #expect(iaqGroups.first { $0.title == "IAQ & Accessories" }?.definitions.contains { $0.key == "accessory_type" } == true)
        #expect(iaqGroups.first { $0.title == "IAQ & Accessories" }?.definitions.contains { $0.key == "uv_lamp_status" } == true)
    }

    @Test func technicalReadingGroupProgressSummarizesCapturedRequiredAndInvalidFields() async throws {
        let customer = Customer(name: "Progress Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "System checked.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        let electricalGroup = try #require(call.groupedTechnicalReadingDefinitions.first { $0.title == "Electrical" })

        call.setTechnicalReading("12", for: "line_voltage")
        call.setTechnicalReading("18", for: "compressor_rla")

        let progress = call.technicalReadingProgress(in: electricalGroup)

        #expect(progress.totalCount >= 4)
        #expect(progress.capturedCount == 2)
        #expect(progress.requiredCount == 3)
        #expect(progress.missingRequiredCount == 1)
        #expect(progress.validationIssueCount == 1)
        #expect(progress.needsAttention)
        #expect(progress.summary.contains("2/"))
        #expect(progress.summary.contains("invalid"))
    }

    @Test func prioritizedTechnicalReadingsPutMissingRequiredFieldsFirst() async throws {
        let customer = Customer(name: "Priority Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "System checked.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        call.setTechnicalReading("12", for: "line_voltage")
        call.setTechnicalReading("18", for: "compressor_rla")
        let electricalGroup = try #require(call.groupedTechnicalReadingDefinitions.first { $0.title == "Electrical" })

        let prioritizedKeys = call.prioritizedTechnicalReadingDefinitions(in: electricalGroup).map(\.key)

        #expect(prioritizedKeys.first == "compressor_amps")
        #expect(prioritizedKeys.firstIndex(of: "compressor_amps")! < prioritizedKeys.firstIndex(of: "line_voltage")!)
        #expect(prioritizedKeys.firstIndex(of: "compressor_rla")! < prioritizedKeys.firstIndex(of: "control_voltage")!)
    }

    @Test func technicalReadingAttentionListIncludesMissingRequiredAndInvalidFields() async throws {
        let customer = Customer(name: "Attention Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "System checked.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        call.setTechnicalReading("12", for: "line_voltage")
        call.setTechnicalReading("18", for: "compressor_rla")

        let attentionKeys = call.attentionTechnicalReadingDefinitions.map(\.key)

        #expect(attentionKeys.first == "compressor_amps")
        #expect(attentionKeys.contains("compressor_amps"))
        #expect(attentionKeys.contains("line_voltage"))
        #expect(attentionKeys.filter { $0 == "line_voltage" }.count == 1)
        #expect(attentionKeys.firstIndex(of: "compressor_amps")! < attentionKeys.firstIndex(of: "line_voltage")!)
        #expect(attentionKeys.contains("control_voltage") == false)
    }

    @Test func serviceReportNextActionPrioritizesMissingRequiredItem() async throws {
        let customer = Customer(name: "Next Action Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "System checked.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        call.setTechnicalReading("12", for: "line_voltage")

        #expect(call.nextServiceReportActionLabel == "Complete Return Air Temp (F)")
    }

    @Test func serviceReportActionSummaryShowsTopMissingAndInvalidItems() async throws {
        let customer = Customer(name: "Action Summary Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        call.setTechnicalReading("12", for: "line_voltage")

        let summary = try #require(call.serviceReportActionSummary)

        #expect(summary.contains("Refrigerant Type"))
        #expect(summary.contains("Supply Air Temp (F)"))
        #expect(summary.contains("Temperature Split (F)"))
        #expect(summary.contains("Refrigerant Type"))
        #expect(summary.contains("+ "))
        #expect(summary.contains("Line Voltage") == false)
    }

    @Test func serviceReportNextActionFallsBackToValidationIssueWhenRequiredItemsAreComplete() async throws {
        let customer = Customer(name: "Validation Action Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "System checked.",
            type: .service,
            scheduledDate: Date(),
            customer: customer
        )
        completeRequiredTechnicalReadings(for: call)
        call.setTechnicalReading("12", for: "line_voltage")

        #expect(call.serviceReportMissingRequiredItemLabels.isEmpty)
        #expect(call.nextServiceReportActionLabel?.hasPrefix("Review Line Voltage (V) outside expected range") == true)
    }

    @Test func technicalReadingGroupCanMarkBlankFieldsUnableToTestWithoutOverwritingMeasurements() async throws {
        let customer = Customer(name: "Unable To Test Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "System checked.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        let electricalGroup = try #require(call.groupedTechnicalReadingDefinitions.first { $0.title == "Electrical" })
        call.setTechnicalReading("238", for: "line_voltage")

        let markedCount = call.markBlankTechnicalReadingsUnableToTest(in: electricalGroup)

        #expect(markedCount == electricalGroup.definitions.count - 1)
        #expect(call.technicalReading(for: "line_voltage") == "238")
        for definition in electricalGroup.definitions where definition.key != "line_voltage" {
            #expect(call.technicalReading(for: definition.key) == HVACTechnicalReadingDefinition.unableToTestValue)
        }
        #expect(call.diagnosticsCaptured)
    }

    @Test func targetSuperheatAndSubcoolingDeviationBlocksReportCompletion() async throws {
        let customer = Customer(name: "Target Deviation Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "System checked.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        completeRequiredTechnicalReadings(for: call)
        completeRequiredMaintenanceActions(for: call)
        call.setTechnicalReading("10", for: "target_superheat")
        call.setTechnicalReading("18", for: "superheat")
        call.setTechnicalReading("9", for: "target_subcooling")
        call.setTechnicalReading("14", for: "subcooling")

        #expect(call.serviceReportMissingRequiredItemLabels.isEmpty)
        #expect(call.serviceReportReadingValidationIssueLabels.contains { $0.contains("Superheat differs from Target Superheat") })
        #expect(call.serviceReportReadingValidationIssueLabels.contains { $0.contains("Subcooling differs from Target Subcooling") })
        #expect(call.canCompleteDocumentation == false)

        let superheatDefinition = try #require(call.technicalReadingDefinitions.first { $0.key == "superheat" })
        let subcoolingDefinition = try #require(call.technicalReadingDefinitions.first { $0.key == "subcooling" })
        #expect(call.technicalReadingValidationIssue(for: superheatDefinition)?.contains("more than 5.0 F") == true)
        #expect(call.technicalReadingValidationIssue(for: subcoolingDefinition)?.contains("more than 3.0 F") == true)
    }

    @Test func clearingDerivedReadingSourceRemovesStaleCalculatedValues() async throws {
        let customer = Customer(name: "Derived Reading Customer")
        let call = ServiceCall(
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )

        call.setTechnicalReading("75", for: "return_air_temp")
        call.setTechnicalReading("55", for: "supply_air_temp")
        call.setTechnicalReading("52", for: "suction_saturation_temp")
        call.setTechnicalReading("62", for: "suction_line_temp")
        call.setTechnicalReading("95", for: "liquid_saturation_temp")
        call.setTechnicalReading("85", for: "liquid_line_temp")

        #expect(call.technicalReading(for: "temperature_split") == "20.0")
        #expect(call.technicalReading(for: "temperature_rise") == "-20.0")
        #expect(call.technicalReading(for: "superheat") == "10.0")
        #expect(call.technicalReading(for: "subcooling") == "10.0")

        call.setTechnicalReading("", for: "supply_air_temp")
        call.setTechnicalReading("", for: "suction_line_temp")
        call.setTechnicalReading("", for: "liquid_line_temp")

        #expect(call.technicalReading(for: "temperature_split").isEmpty)
        #expect(call.technicalReading(for: "temperature_rise").isEmpty)
        #expect(call.technicalReading(for: "superheat").isEmpty)
        #expect(call.technicalReading(for: "subcooling").isEmpty)
    }

    @Test func clearingStaticPressureSourceRemovesStaleTotalExternalStatic() async throws {
        let customer = Customer(name: "Static Reading Customer")
        let call = ServiceCall(
            equipmentTypeRaw: HVACEquipmentType.airHandler.rawValue,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )

        call.setTechnicalReading("-0.35", for: "static_pressure_return")
        call.setTechnicalReading("0.42", for: "static_pressure_supply")

        #expect(call.technicalReading(for: "total_external_static") == "0.8")

        call.setTechnicalReading("", for: "static_pressure_supply")

        #expect(call.technicalReading(for: "total_external_static").isEmpty)
    }

    @Test func equipmentSpecificReportReadinessTracksMissingRequiredItems() async throws {
        let customer = Customer(name: "Readiness Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "System checked and operating.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )

        #expect(call.serviceReportMissingRequirementLabels.contains("Refrigerant Type"))
        #expect(call.serviceReportMissingRequirementLabels.contains("Compressor Amps (A)"))
        #expect(call.serviceReportMissingRequirementLabels.contains("Equipment Name") == false)

        completeRequiredTechnicalReadings(for: call)
        completeRequiredMaintenanceActions(for: call)

        #expect(call.serviceReportMissingRequirementLabels.isEmpty)
        #expect(call.serviceReportReadinessSummary == "\(call.serviceReportRequiredItemCount)/\(call.serviceReportRequiredItemCount) required items")
    }

    @Test func technicalReportRequiresEquipmentTypeBeforeInvoiceCreation() async throws {
        let customer = Customer(name: "Equipment Type Required Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs System",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            serviceReportSummary: "System checked and operating.",
            type: .service,
            scheduledDate: Date(),
            customer: customer
        )
        completeRequiredTechnicalReadings(for: call)

        #expect(call.serviceReportMissingRequiredItemLabels.contains("Equipment Type"))
        #expect(call.canCreateInvoiceDocument == false)
        #expect(call.invoiceCreationBlockedMessage?.contains("Equipment Type") == true)

        call.equipmentType = .splitSystemAC
        completeRequiredTechnicalReadings(for: call)

        #expect(call.serviceReportMissingRequiredItemLabels.contains("Equipment Type") == false)
        #expect(call.canCreateInvoiceDocument)
    }

    @Test func technicalReportDoesNotDefaultReadingsBeforeEquipmentTypeSelection() async throws {
        let customer = Customer(name: "No Default Equipment Customer")
        let call = ServiceCall(
            equipmentName: "Unselected System",
            type: .service,
            scheduledDate: Date(),
            customer: customer
        )

        #expect(call.equipmentType == nil)
        #expect(call.technicalReadingDefinitions.isEmpty)
        #expect(call.requiredTechnicalReadingDefinitions.isEmpty)
        #expect(call.groupedTechnicalReadingDefinitions.isEmpty)
        #expect(call.serviceActionDefinitions.isEmpty)
        #expect(call.groupedServiceActionDefinitions.isEmpty)
        #expect(call.serviceReportMissingRequiredItemLabels.contains("Equipment Type"))
        call.setTechnicalReading("R-410A", for: "refrigerant_type")
        #expect(call.technicalReading(for: "refrigerant_type").isEmpty)

        call.equipmentType = .heatPump

        #expect(call.technicalReadingDefinitions.isEmpty == false)
        #expect(call.requiredTechnicalReadingDefinitions.isEmpty == false)
        #expect(call.groupedTechnicalReadingDefinitions.isEmpty == false)
        #expect(call.technicalReadingDefinitions.contains { $0.key == "reversing_valve_operation" })
        #expect(call.technicalReadingDefinitions.contains { $0.key == "flame_sensor_microamps" } == false)
        call.setTechnicalReading("1.5", for: "flame_sensor_microamps")
        #expect(call.technicalReading(for: "flame_sensor_microamps").isEmpty)
    }

    @Test func changingEquipmentTypePrunesIncompatibleTechnicalReadings() async throws {
        let customer = Customer(name: "Equipment Type Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "System checked.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        call.setTechnicalReading("R-410A", for: "refrigerant_type")
        call.setTechnicalReading("12", for: "superheat")
        call.setTechnicalReading("240", for: "line_voltage")

        call.equipmentType = .gasFurnace

        #expect(call.technicalReading(for: "refrigerant_type").isEmpty)
        #expect(call.technicalReading(for: "superheat").isEmpty)
        #expect(call.technicalReading(for: "line_voltage") == "240")
        #expect(call.technicalReadings.keys.contains("refrigerant_type") == false)
    }

    @Test func applyingEquipmentProfilePrunesPriorEquipmentTypeReadings() async throws {
        let customer = Customer(name: "Equipment Profile Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "System checked.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        call.setTechnicalReading("R-410A", for: "refrigerant_type")
        call.setTechnicalReading("10", for: "subcooling")
        call.setTechnicalReading("240", for: "line_voltage")
        let furnace = CustomerEquipment(
            customer: customer,
            equipmentType: .gasFurnace,
            name: "Gas Furnace",
            modelNumber: "GM9C",
            serialNumber: "FURN123"
        )

        furnace.apply(to: call)

        #expect(call.equipmentType == .gasFurnace)
        #expect(call.technicalReading(for: "refrigerant_type").isEmpty)
        #expect(call.technicalReading(for: "subcooling").isEmpty)
        #expect(call.technicalReading(for: "line_voltage") == "240")
    }

    @Test func technicalReadingDefinitionsValidateExpectedFieldRanges() async throws {
        let voltage = HVACTechnicalReadingDefinition(key: "line_voltage", label: "Line Voltage", unit: "V")
        let superheat = HVACTechnicalReadingDefinition(key: "superheat", label: "Superheat", unit: "F")
        let condition = HVACTechnicalReadingDefinition(key: "condenser_condition", label: "Condenser Condition")

        #expect(voltage.expectedRangeLabel == "90-600 V")
        #expect(voltage.validationIssue(for: "240") == nil)
        #expect(voltage.validationIssue(for: "12")?.contains("outside expected range") == true)
        #expect(superheat.validationIssue(for: "not a number") == "Superheat (F) must be numeric")
        #expect(superheat.validationIssue(for: HVACTechnicalReadingDefinition.unableToTestValue) == nil)
        #expect(HVACTechnicalReadingDefinition.isNonNumericStatus("Not Applicable"))
        #expect(condition.validationIssue(for: "Needs Cleaning") == nil)
    }

    @Test func unableToTestReadingsCanSatisfyRequiredFieldCompletion() async throws {
        let customer = Customer(name: "Unable To Test Customer")
        let call = ServiceCall(
            equipmentName: "Main AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "Unable to run cooling cycle during service.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        completeRequiredTechnicalReadings(for: call)
        completeRequiredMaintenanceActions(for: call)

        #expect(call.serviceReportMissingRequiredItemLabels.isEmpty)
        #expect(call.serviceReportReadingValidationIssueLabels.isEmpty)
        #expect(call.markDocumentationCompleteIfReady())
    }

    @Test func unableToTestCalculatedReadingMarksBlankSourceReadings() async throws {
        let customer = Customer(name: "Calculated Unable Customer")
        let call = ServiceCall(
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )

        call.setTechnicalReading(HVACTechnicalReadingDefinition.unableToTestValue, for: "superheat")
        call.setTechnicalReading(HVACTechnicalReadingDefinition.unableToTestValue, for: "subcooling")

        #expect(call.technicalReading(for: "superheat") == HVACTechnicalReadingDefinition.unableToTestValue)
        #expect(call.technicalReading(for: "suction_line_temp") == HVACTechnicalReadingDefinition.unableToTestValue)
        #expect(call.technicalReading(for: "suction_saturation_temp") == HVACTechnicalReadingDefinition.unableToTestValue)
        #expect(call.technicalReading(for: "subcooling") == HVACTechnicalReadingDefinition.unableToTestValue)
        #expect(call.technicalReading(for: "liquid_line_temp") == HVACTechnicalReadingDefinition.unableToTestValue)
        #expect(call.technicalReading(for: "liquid_saturation_temp") == HVACTechnicalReadingDefinition.unableToTestValue)
    }

    @Test func unableToTestCalculatedReadingDoesNotOverwriteMeasuredSourceReadings() async throws {
        let customer = Customer(name: "Measured Source Customer")
        let call = ServiceCall(
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        call.setTechnicalReading("48", for: "suction_line_temp")

        call.setTechnicalReading(HVACTechnicalReadingDefinition.unableToTestValue, for: "superheat")

        #expect(call.technicalReading(for: "superheat") == HVACTechnicalReadingDefinition.unableToTestValue)
        #expect(call.technicalReading(for: "suction_line_temp") == "48")
        #expect(call.technicalReading(for: "suction_saturation_temp") == HVACTechnicalReadingDefinition.unableToTestValue)
    }

    @Test func invalidTechnicalReadingsBlockReportCompletion() async throws {
        let customer = Customer(name: "Validation Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "System checked.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        completeRequiredTechnicalReadings(for: call)
        completeRequiredMaintenanceActions(for: call)
        call.setTechnicalReading("12", for: "line_voltage")

        #expect(call.serviceReportMissingRequiredItemLabels.isEmpty)
        #expect(call.serviceReportReadingValidationIssueLabels.contains { $0.contains("Line Voltage") })
        #expect(call.serviceReportReadinessSummary == "\(call.serviceReportRequiredItemCount)/\(call.serviceReportRequiredItemCount) required items • 1 invalid")
        #expect(call.canCompleteDocumentation == false)
        #expect(call.markDocumentationCompleteIfReady() == false)
        #expect(call.documentationCompletionBlockedMessage?.contains("Missing or invalid") == true)
        #expect(call.documentationCompletionBlockedMessage?.contains("Line Voltage") == true)
    }

    @Test func unsafeCarbonMonoxideReadingBlocksCombustionReportCompletion() async throws {
        let customer = Customer(name: "Combustion Safety Customer")
        let call = ServiceCall(
            equipmentName: "Gas Furnace",
            equipmentModel: "GM9C",
            equipmentSerialNumber: "FURN123",
            equipmentTypeRaw: HVACEquipmentType.gasFurnace.rawValue,
            serviceReportSummary: "Heating maintenance completed.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        completeRequiredTechnicalReadings(for: call)
        completeRequiredMaintenanceActions(for: call)
        call.setTechnicalReading("125", for: "co_ppm")

        #expect(call.serviceReportMissingRequiredItemLabels.isEmpty)
        #expect(call.serviceReportReadingValidationIssueLabels.contains { $0.contains("CO Reading") })
        #expect(call.serviceReportReadingValidationIssueLabels.contains { $0.contains("100 ppm") })
        let coDefinition = try #require(call.technicalReadingDefinitions.first { $0.key == "co_ppm" })
        #expect(call.technicalReadingValidationIssue(for: coDefinition)?.contains("100 ppm") == true)
        #expect(call.canCompleteDocumentation == false)
        #expect(call.markDocumentationCompleteIfReady() == false)
    }

    @Test func incompleteTechnicalServiceReportDoesNotMarkDocumentationComplete() async throws {
        let customer = Customer(name: "Incomplete Report Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "System checked.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        call.setTechnicalReading("72", for: "return_air_temp")

        let markedComplete = call.markDocumentationCompleteIfReady(at: Date(timeIntervalSince1970: 1_800_000_000))

        #expect(markedComplete == false)
        #expect(call.documentationCompletedAt == nil)
        #expect(call.documentationCompletionBlockedMessage?.contains("Supply Air Temp (F)") == true)
    }

    @Test func completeTechnicalServiceReportMarksDocumentationComplete() async throws {
        let customer = Customer(name: "Complete Report Customer")
        let completionDate = Date(timeIntervalSince1970: 1_800_000_000)
        let call = ServiceCall(
            equipmentName: "Main Furnace",
            equipmentModel: "59TN6",
            equipmentSerialNumber: "FURN123",
            equipmentTypeRaw: HVACEquipmentType.gasFurnace.rawValue,
            serviceReportSummary: "Heating maintenance completed.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        completeRequiredTechnicalReadings(for: call)
        completeRequiredMaintenanceActions(for: call)

        let markedComplete = call.markDocumentationCompleteIfReady(at: completionDate)

        #expect(markedComplete == true)
        #expect(call.documentationChecklist == true)
        #expect(call.documentationCompletedAt == completionDate)
        #expect(call.documentationCompletionBlockedMessage == nil)
    }

    @Test func incompleteTechnicalReportBlocksReadyToBillEvenWhenWorkIsComplete() async throws {
        let customer = Customer(name: "Incomplete Bill Ready Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "System checked.",
            type: .service,
            scheduledDate: Date(),
            customer: customer,
            status: .completed,
            workCompletedChecklist: true
        )
        call.setTechnicalReading("72", for: "return_air_temp")

        #expect(call.canCompleteDocumentation == false)
        #expect(call.isReadyToCreateBillingDocument == false)
    }

    @Test func completeTechnicalReportAllowsReadyToBillBeforeInvoiceExists() async throws {
        let customer = Customer(name: "Bill Ready Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "Cooling service completed.",
            type: .service,
            scheduledDate: Date(),
            customer: customer,
            status: .completed,
            workCompletedChecklist: true
        )
        for definition in call.requiredTechnicalReadingDefinitions {
            call.setTechnicalReading(HVACTechnicalReadingDefinition.unableToTestValue, for: definition.key)
        }

        #expect(call.canCompleteDocumentation)
        #expect(call.isReadyToCreateBillingDocument)

        call.linkedInvoiceID = UUID()
        #expect(call.isReadyToCreateBillingDocument == false)
    }

    @Test func incompleteTechnicalReportBlocksInvoiceCreation() async throws {
        let customer = Customer(name: "Blocked Invoice Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "System checked.",
            type: .service,
            scheduledDate: Date(),
            customer: customer,
            status: .completed,
            workCompletedChecklist: true
        )
        call.setTechnicalReading("72", for: "return_air_temp")

        #expect(call.canCreateInvoiceDocument == false)
        #expect(call.invoiceCreationBlockedMessage?.contains("Missing or invalid") == true)
        #expect(call.invoiceCreationBlockedMessage?.contains("Supply Air Temp") == true)
    }

    @Test func estimateAppointmentCanCreateInvoiceWithoutTechnicalReport() async throws {
        let customer = Customer(name: "Accepted Estimate Customer")
        let call = ServiceCall(
            type: .estimate,
            scheduledDate: Date(),
            customer: customer,
            status: .completed
        )

        #expect(call.requiresTechnicalServiceReportCompletion == false)
        #expect(call.canCreateInvoiceDocument)
    }

    @Test func generalAppointmentCanBeReadyToBillWithoutTechnicalReport() async throws {
        let customer = Customer(name: "General Appointment Customer")
        let call = ServiceCall(
            type: .other,
            scheduledDate: Date(),
            customer: customer,
            status: .completed,
            workCompletedChecklist: true
        )

        #expect(call.requiresTechnicalServiceReportCompletion == false)
        #expect(call.isReadyToCreateBillingDocument)
    }

    @Test func jobCloseoutReadinessShowsMissingOperationalEvidence() async throws {
        let customer = Customer(name: "Closeout Customer")
        let call = ServiceCall(
            equipmentName: "Main Furnace",
            equipmentModel: "59TN6",
            equipmentSerialNumber: "FURN123",
            equipmentTypeRaw: HVACEquipmentType.gasFurnace.rawValue,
            serviceReportSummary: "Heating maintenance completed.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )

        let readiness = call.closeoutReadiness(invoice: nil, payments: [], attachments: [])

        #expect(readiness.isReady == false)
        #expect(readiness.missingItems.contains("Work completed"))
        #expect(readiness.missingItems.contains("Technical report complete"))
        #expect(readiness.missingItems.contains("Onsite report generated"))
        #expect(readiness.missingItems.contains("Before photo captured"))
        #expect(readiness.missingItems.contains("After photo captured"))
        #expect(readiness.missingItems.contains("Invoice created"))
    }

    @Test func jobCloseoutReadinessSummarizesPrimaryBlockersWithRemainderCount() async throws {
        let readiness = JobCloseoutReadiness(
            requiredItems: [
                "Work completed",
                "Technical report complete",
                "Onsite report generated",
                "Invoice created"
            ],
            missingItems: [
                "Work completed",
                "Technical report complete",
                "Onsite report generated",
                "Invoice created"
            ]
        )

        #expect(readiness.primaryMissingItem == "Work completed")
        #expect(readiness.missingSummary(limit: 2) == "Work completed, Technical report complete +2 more")
        #expect(readiness.missingSummary(limit: 10) == "Work completed, Technical report complete, Onsite report generated, Invoice created")
    }

    @Test func jobCloseoutReadinessMarksCompletedSyncedJobsReady() async throws {
        let customer = Customer(name: "Closeout Customer")
        let call = ServiceCall(
            equipmentName: "Main Furnace",
            equipmentModel: "59TN6",
            equipmentSerialNumber: "FURN123",
            equipmentTypeRaw: HVACEquipmentType.gasFurnace.rawValue,
            serviceReportSummary: "Heating maintenance completed.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer,
            status: .invoiced,
            workCompletedChecklist: true,
            documentationChecklist: true,
            paymentCollectedChecklist: true
        )
        completeRequiredTechnicalReadings(for: call)
        completeRequiredMaintenanceActions(for: call)
        let invoice = Invoice(
            serviceCallID: call.id,
            customer: customer,
            quickBooksID: "QB-100",
            amount: 500,
            status: "paid",
            customerSignatureName: "Customer",
            customerSignedAt: Date(),
            finalizedAt: Date()
        )
        call.linkedInvoiceID = invoice.id
        let report = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoice.id,
            kind: .serviceReport,
            displayName: "report.pdf",
            localFilePath: "/tmp/report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            quickBooksAttachableID: "ATTACH-1"
        )
        let beforePhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoice.id,
            kind: .beforePhoto,
            displayName: "before.jpg",
            localFilePath: "/tmp/before.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 512,
            quickBooksAttachableID: "ATTACH-2"
        )
        let afterPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoice.id,
            kind: .afterPhoto,
            displayName: "after.jpg",
            localFilePath: "/tmp/after.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 512,
            quickBooksAttachableID: "ATTACH-3"
        )
        let invoicePDF = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoice.id,
            kind: .invoiceSupport,
            displayName: "invoice.pdf",
            localFilePath: "/tmp/invoice.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            quickBooksAttachableID: "ATTACH-4"
        )

        let readiness = call.closeoutReadiness(invoice: invoice, payments: [], attachments: [report, beforePhoto, afterPhoto, invoicePDF])

        #expect(readiness.isReady == true)
        #expect(readiness.statusLabel == "Ready for closeout")
        #expect(readiness.summary == "\(readiness.totalCount)/\(readiness.totalCount) complete")
    }

    @Test func jobCloseoutReadinessRequiresSettledInvoiceDespitePaymentChecklist() async throws {
        let customer = Customer(name: "Unsettled Closeout Customer")
        let call = ServiceCall(
            equipmentName: "Main Furnace",
            equipmentModel: "59TN6",
            equipmentSerialNumber: "FURN123",
            equipmentTypeRaw: HVACEquipmentType.gasFurnace.rawValue,
            serviceReportSummary: "Heating maintenance completed.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer,
            status: .invoiced,
            workCompletedChecklist: true,
            documentationChecklist: true,
            paymentCollectedChecklist: true
        )
        for definition in call.requiredTechnicalReadingDefinitions {
            call.setTechnicalReading(definition.options.first ?? "1", for: definition.key)
        }
        let invoice = Invoice(
            serviceCallID: call.id,
            customer: customer,
            quickBooksID: "QB-101",
            amount: 500,
            status: "unpaid",
            customerSignatureName: "Customer",
            customerSignedAt: Date(),
            finalizedAt: Date()
        )
        call.linkedInvoiceID = invoice.id
        let report = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoice.id,
            kind: .serviceReport,
            displayName: "report.pdf",
            localFilePath: "/tmp/report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            quickBooksAttachableID: "ATTACH-1"
        )
        let beforePhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoice.id,
            kind: .beforePhoto,
            displayName: "before.jpg",
            localFilePath: "/tmp/before.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 512,
            quickBooksAttachableID: "ATTACH-2"
        )
        let afterPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoice.id,
            kind: .afterPhoto,
            displayName: "after.jpg",
            localFilePath: "/tmp/after.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 512,
            quickBooksAttachableID: "ATTACH-3"
        )

        let readiness = call.closeoutReadiness(invoice: invoice, payments: [], attachments: [report, beforePhoto, afterPhoto])

        #expect(readiness.isReady == false)
        #expect(readiness.missingItems.contains("Payment resolved"))
    }

    @Test func serviceCloseoutRequiresBeforeAndAfterPhotoEvidence() async throws {
        let customer = Customer(name: "Photo Evidence Customer")
        let call = ServiceCall(
            equipmentName: "Main AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "Cooling maintenance completed.",
            type: .service,
            scheduledDate: Date(),
            customer: customer,
            status: .completed,
            workCompletedChecklist: true
        )
        for definition in call.requiredTechnicalReadingDefinitions {
            call.setTechnicalReading(definition.options.first ?? "1", for: definition.key)
        }
        let report = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            kind: .serviceReport,
            displayName: "report.pdf",
            localFilePath: "/tmp/report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )

        let readiness = call.closeoutReadiness(invoice: nil, payments: [], attachments: [report])

        #expect(readiness.requiredItems.contains("Before photo captured"))
        #expect(readiness.requiredItems.contains("After photo captured"))
        #expect(readiness.missingItems.contains("Before photo captured"))
        #expect(readiness.missingItems.contains("After photo captured"))
        let photoStatus = call.photoEvidenceStatus(from: [report])
        #expect(photoStatus.isReady == false)
        #expect(photoStatus.statusLabel == "Before and after photos missing")
        #expect(photoStatus.summary == "0 before - 0 after")
    }

    @Test func serviceCloseoutAcceptsAttachedBeforeAndAfterPhotos() async throws {
        let customer = Customer(name: "Photo Evidence Customer")
        let call = ServiceCall(
            equipmentName: "Main AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "Cooling maintenance completed.",
            type: .service,
            scheduledDate: Date(),
            customer: customer,
            status: .completed,
            workCompletedChecklist: true
        )
        for definition in call.requiredTechnicalReadingDefinitions {
            call.setTechnicalReading(definition.options.first ?? "1", for: definition.key)
        }
        let report = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            kind: .serviceReport,
            displayName: "report.pdf",
            localFilePath: "/tmp/report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let beforePhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            kind: .beforePhoto,
            displayName: "before.jpg",
            localFilePath: "/tmp/before.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 512
        )
        let afterPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            kind: .afterPhoto,
            displayName: "after.jpg",
            localFilePath: "/tmp/after.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 512
        )

        let readiness = call.closeoutReadiness(invoice: nil, payments: [], attachments: [report, beforePhoto, afterPhoto])

        #expect(readiness.missingItems.contains("Before photo captured") == false)
        #expect(readiness.missingItems.contains("After photo captured") == false)
        let photoStatus = call.photoEvidenceStatus(from: [beforePhoto, afterPhoto])
        #expect(photoStatus.isReady)
        #expect(photoStatus.statusLabel == "Photo evidence complete")
        #expect(photoStatus.summary == "1 before - 1 after")
    }

    @Test func meetingCloseoutDoesNotRequireFieldPhotos() async throws {
        let customer = Customer(name: "Meeting Customer")
        let call = ServiceCall(
            type: .meeting,
            scheduledDate: Date(),
            customer: customer,
            status: .completed,
            workCompletedChecklist: true
        )
        let report = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            kind: .serviceReport,
            displayName: "meeting-notes.pdf",
            localFilePath: "/tmp/meeting-notes.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )

        let readiness = call.closeoutReadiness(invoice: nil, payments: [], attachments: [report])

        #expect(readiness.requiredItems.contains("Before photo captured") == false)
        #expect(readiness.requiredItems.contains("After photo captured") == false)
        #expect(readiness.missingItems.contains("Before photo captured") == false)
        #expect(readiness.missingItems.contains("After photo captured") == false)
    }

    @Test func jobCloseoutReadinessRequiresGeneratedReportLinkedToInvoice() async throws {
        let customer = Customer(name: "Closeout Customer")
        let call = ServiceCall(
            equipmentName: "Main Furnace",
            equipmentModel: "59TN6",
            equipmentSerialNumber: "FURN123",
            equipmentTypeRaw: HVACEquipmentType.gasFurnace.rawValue,
            serviceReportSummary: "Heating maintenance completed.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer,
            status: .invoiced,
            workCompletedChecklist: true,
            documentationChecklist: true,
            paymentCollectedChecklist: true
        )
        for definition in call.requiredTechnicalReadingDefinitions {
            call.setTechnicalReading(definition.options.first ?? "1", for: definition.key)
        }
        let invoice = Invoice(
            serviceCallID: call.id,
            customer: customer,
            quickBooksID: "QB-100",
            amount: 500,
            status: "paid",
            customerSignatureName: "Customer",
            customerSignedAt: Date(),
            finalizedAt: Date()
        )
        let unlinkedReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            kind: .serviceReport,
            displayName: "stale-report.pdf",
            localFilePath: "/tmp/stale-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            quickBooksAttachableID: "ATTACH-1"
        )

        let readiness = call.closeoutReadiness(invoice: invoice, payments: [], attachments: [unlinkedReport])

        #expect(readiness.isReady == false)
        #expect(readiness.missingItems.contains("Onsite report generated"))
    }

    @Test func closeoutReadinessAcceptsEstimateReportAfterInvoiceConversion() async throws {
        let customer = Customer(name: "Converted Estimate Customer")
        let estimate = Estimate(customer: customer, amount: 500)
        let invoice = Invoice(
            serviceCallID: UUID(),
            customer: customer,
            amount: 500,
            status: "paid",
            customerSignatureName: "Customer",
            customerSignedAt: Date(),
            finalizedAt: Date()
        )
        let call = ServiceCall(
            equipmentName: "Main Furnace",
            equipmentModel: "59TN6",
            equipmentSerialNumber: "FURN123",
            equipmentTypeRaw: HVACEquipmentType.gasFurnace.rawValue,
            serviceReportSummary: "Heating maintenance completed.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer,
            status: .invoiced,
            workCompletedChecklist: true,
            documentationChecklist: true,
            paymentCollectedChecklist: true,
            linkedEstimateID: estimate.id,
            linkedInvoiceID: invoice.id
        )
        invoice.serviceCallID = call.id
        for definition in call.requiredTechnicalReadingDefinitions {
            call.setTechnicalReading(definition.options.first ?? "1", for: definition.key)
        }
        let estimateLinkedReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            estimateID: estimate.id,
            kind: .serviceReport,
            displayName: "estimate-onsite-report.pdf",
            localFilePath: "/tmp/estimate-onsite-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )

        let readiness = call.closeoutReadiness(invoice: invoice, payments: [], attachments: [estimateLinkedReport])

        #expect(readiness.missingItems.contains("Onsite report generated") == false)
    }

    @Test func jobCloseoutReadinessDetectsPendingQuickBooksAttachments() async throws {
        let customer = Customer(name: "Closeout Customer")
        let call = ServiceCall(
            equipmentName: "Main Furnace",
            equipmentModel: "59TN6",
            equipmentSerialNumber: "FURN123",
            equipmentTypeRaw: HVACEquipmentType.gasFurnace.rawValue,
            serviceReportSummary: "Heating maintenance completed.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer,
            status: .invoiced,
            workCompletedChecklist: true,
            documentationChecklist: true,
            paymentCollectedChecklist: true
        )
        for definition in call.requiredTechnicalReadingDefinitions {
            call.setTechnicalReading(definition.options.first ?? "1", for: definition.key)
        }
        let invoice = Invoice(
            serviceCallID: call.id,
            customer: customer,
            quickBooksID: "QB-100",
            amount: 500,
            status: "paid",
            customerSignatureName: "Customer",
            customerSignedAt: Date(),
            finalizedAt: Date()
        )
        let report = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoice.id,
            kind: .serviceReport,
            displayName: "report.pdf",
            localFilePath: "/tmp/report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let invoicePDF = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoice.id,
            kind: .invoiceSupport,
            displayName: "invoice.pdf",
            localFilePath: "/tmp/invoice.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )

        let readiness = call.closeoutReadiness(invoice: invoice, payments: [], attachments: [report, invoicePDF])

        #expect(readiness.isReady == false)
        #expect(readiness.missingItems.contains("QuickBooks attachments synced"))

        report.quickBooksSyncError = "Upload rejected"
        let failedReadiness = call.closeoutReadiness(invoice: invoice, payments: [], attachments: [report, invoicePDF])

        #expect(failedReadiness.isReady == false)
        #expect(failedReadiness.missingItems.contains("QuickBooks attachment sync failed"))
        #expect(failedReadiness.missingItems.contains("QuickBooks attachments synced") == false)
    }

    @Test func invoiceDocumentationStatusTracksMissingPendingAndSyncedReports() async throws {
        let customer = Customer(name: "Invoice Documentation Customer")
        let call = ServiceCall(
            equipmentName: "Main AC",
            equipmentModel: "24ABC",
            equipmentSerialNumber: "AC123",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        let invoice = Invoice(
            serviceCallID: call.id,
            customer: customer,
            quickBooksID: "QB-INV-1",
            amount: 500
        )

        let missing = call.invoiceDocumentationStatus(invoice: invoice, attachments: [])
        #expect(missing.isReady == false)
        #expect(missing.statusLabel == "Onsite report missing")
        #expect(missing.sendReadinessLabel == "Generate onsite report before sending")
        #expect(missing.actionSummary == "Create or attach the onsite service report for this invoice.")

        let pendingReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoice.id,
            kind: .serviceReport,
            displayName: "onsite-report.pdf",
            localFilePath: "/tmp/onsite-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let linkedPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoice.id,
            kind: .afterPhoto,
            displayName: "after-repair.jpg",
            localFilePath: "/tmp/after-repair.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048
        )
        let linkedInvoicePDF = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoice.id,
            kind: .invoiceSupport,
            displayName: "invoice.pdf",
            localFilePath: "/tmp/invoice.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 2048
        )
        let missingInvoicePDF = call.invoiceDocumentationStatus(invoice: invoice, attachments: [pendingReport, linkedPhoto])
        #expect(missingInvoicePDF.isReady == false)
        #expect(missingInvoicePDF.statusLabel == "Invoice PDF missing")
        #expect(missingInvoicePDF.sendReadinessLabel == "Generate invoice PDF before sending")
        #expect(missingInvoicePDF.actionSummary == "Generate and save the customer-facing invoice PDF before emailing.")

        let pending = call.invoiceDocumentationStatus(invoice: invoice, attachments: [pendingReport, linkedPhoto, linkedInvoicePDF])
        #expect(pending.isReady == false)
        #expect(pending.statusLabel == "QuickBooks attachments pending")
        #expect(pending.sendReadinessLabel == "Sync QuickBooks attachments before sending")
        #expect(pending.actionSummary == "Upload 3 invoice attachments to QuickBooks before emailing.")
        #expect(pending.linkedPhotoEvidenceCount == 1)
        #expect(pending.linkedBillingDocumentCount == 1)
        #expect(pending.pendingQuickBooksAttachmentCount == 3)
        #expect(pending.failedQuickBooksAttachmentCount == 0)
        #expect(pending.summary.contains("1 photo"))
        #expect(pending.summary.contains("1 billing PDF"))

        pendingReport.quickBooksSyncError = "Upload rejected"
        let failed = call.invoiceDocumentationStatus(invoice: invoice, attachments: [pendingReport, linkedPhoto, linkedInvoicePDF])
        #expect(failed.isReady == false)
        #expect(failed.statusLabel == "QuickBooks attachment sync failed")
        #expect(failed.sendReadinessLabel == "Retry QuickBooks attachment sync before sending")
        #expect(failed.actionSummary == "Retry 1 failed QuickBooks attachment upload before emailing.")
        #expect(failed.pendingQuickBooksAttachmentCount == 3)
        #expect(failed.failedQuickBooksAttachmentCount == 1)
        #expect(failed.summary.contains("1 failed"))

        pendingReport.quickBooksSyncError = nil
        pendingReport.quickBooksAttachableID = "ATTACH-1"
        linkedPhoto.quickBooksAttachableID = "ATTACH-2"
        linkedInvoicePDF.quickBooksAttachableID = "ATTACH-3"
        let synced = call.invoiceDocumentationStatus(invoice: invoice, attachments: [pendingReport, linkedPhoto, linkedInvoicePDF])
        #expect(synced.isReady)
        #expect(synced.statusLabel == "Invoice documentation ready")
        #expect(synced.sendReadinessLabel == "Ready to send with documentation")
        #expect(synced.actionSummary == "Ready to email with onsite report and linked job photos.")
        #expect(synced.failedQuickBooksAttachmentCount == 0)
        #expect(synced.syncedQuickBooksAttachmentCount == 3)
    }

    @Test func invoiceDocumentationStatusCountsConvertedEstimatePackage() async throws {
        let customer = Customer(name: "Converted Documentation Customer")
        let estimate = Estimate(customer: customer, amount: 500)
        let invoice = Invoice(customer: customer, amount: 500)
        let call = ServiceCall(
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer,
            linkedEstimateID: estimate.id,
            linkedInvoiceID: invoice.id
        )
        invoice.serviceCallID = call.id
        let estimateReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            estimateID: estimate.id,
            kind: .serviceReport,
            displayName: "estimate-report.pdf",
            localFilePath: "/tmp/estimate-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let estimatePhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            estimateID: estimate.id,
            kind: .diagnosticPhoto,
            displayName: "diagnostic.jpg",
            localFilePath: "/tmp/diagnostic.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 1024
        )
        let invoicePDF = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoice.id,
            kind: .invoiceSupport,
            displayName: "invoice.pdf",
            localFilePath: "/tmp/invoice.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )

        let withoutInvoicePDF = call.invoiceDocumentationStatus(invoice: invoice, attachments: [estimateReport, estimatePhoto])
        #expect(withoutInvoicePDF.isReady == false)
        #expect(withoutInvoicePDF.statusLabel == "Invoice PDF missing")

        let status = call.invoiceDocumentationStatus(invoice: invoice, attachments: [estimateReport, estimatePhoto, invoicePDF])

        #expect(status.isReady)
        #expect(status.statusLabel == "Invoice documentation ready")
        #expect(status.linkedReportCount == 1)
        #expect(status.linkedPhotoEvidenceCount == 1)
        #expect(status.linkedBillingDocumentCount == 1)
    }

    @Test func estimateDocumentationStatusTracksMissingPendingAndSyncedReports() async throws {
        let customer = Customer(name: "Estimate Documentation Customer")
        let call = ServiceCall(
            equipmentName: "Main AC",
            equipmentModel: "24ABC",
            equipmentSerialNumber: "AC123",
            type: .estimate,
            scheduledDate: Date(),
            customer: customer
        )
        let estimate = Estimate(
            serviceCallID: call.id,
            customer: customer,
            quickBooksID: "QB-EST-1",
            amount: 500
        )

        let missing = call.estimateDocumentationStatus(estimate: estimate, attachments: [])
        #expect(missing.isReady == false)
        #expect(missing.statusLabel == "Onsite report missing")
        #expect(missing.sendReadinessLabel == "Generate onsite report before sending")
        #expect(missing.actionSummary == "Create or attach the onsite service report for this estimate.")

        let pendingReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            estimateID: estimate.id,
            kind: .serviceReport,
            displayName: "onsite-report.pdf",
            localFilePath: "/tmp/onsite-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let linkedPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            estimateID: estimate.id,
            kind: .diagnosticPhoto,
            displayName: "diagnostic.jpg",
            localFilePath: "/tmp/diagnostic.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048
        )
        let linkedEstimatePDF = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            estimateID: estimate.id,
            kind: .estimateSupport,
            displayName: "estimate.pdf",
            localFilePath: "/tmp/estimate.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 2048
        )
        let missingEstimatePDF = call.estimateDocumentationStatus(estimate: estimate, attachments: [pendingReport, linkedPhoto])
        #expect(missingEstimatePDF.isReady == false)
        #expect(missingEstimatePDF.statusLabel == "Estimate PDF missing")
        #expect(missingEstimatePDF.sendReadinessLabel == "Generate estimate PDF before sending")
        #expect(missingEstimatePDF.actionSummary == "Generate and save the customer-facing estimate PDF before emailing.")

        let pending = call.estimateDocumentationStatus(estimate: estimate, attachments: [pendingReport, linkedPhoto, linkedEstimatePDF])
        #expect(pending.isReady == false)
        #expect(pending.statusLabel == "QuickBooks attachments pending")
        #expect(pending.sendReadinessLabel == "Sync QuickBooks attachments before sending")
        #expect(pending.actionSummary == "Upload 3 estimate attachments to QuickBooks before emailing.")
        #expect(pending.linkedPhotoEvidenceCount == 1)
        #expect(pending.linkedBillingDocumentCount == 1)
        #expect(pending.pendingQuickBooksAttachmentCount == 3)
        #expect(pending.failedQuickBooksAttachmentCount == 0)
        #expect(pending.summary.contains("1 photo"))
        #expect(pending.summary.contains("1 billing PDF"))

        linkedEstimatePDF.quickBooksSyncError = "Upload rejected"
        let failed = call.estimateDocumentationStatus(estimate: estimate, attachments: [pendingReport, linkedPhoto, linkedEstimatePDF])
        #expect(failed.isReady == false)
        #expect(failed.statusLabel == "QuickBooks attachment sync failed")
        #expect(failed.sendReadinessLabel == "Retry QuickBooks attachment sync before sending")
        #expect(failed.actionSummary == "Retry 1 failed QuickBooks attachment upload before emailing.")
        #expect(failed.pendingQuickBooksAttachmentCount == 3)
        #expect(failed.failedQuickBooksAttachmentCount == 1)
        #expect(failed.summary.contains("1 failed"))

        linkedEstimatePDF.quickBooksSyncError = nil
        pendingReport.quickBooksAttachableID = "ATTACH-EST-1"
        linkedPhoto.quickBooksAttachableID = "ATTACH-EST-2"
        linkedEstimatePDF.quickBooksAttachableID = "ATTACH-EST-3"
        let synced = call.estimateDocumentationStatus(estimate: estimate, attachments: [pendingReport, linkedPhoto, linkedEstimatePDF])
        #expect(synced.isReady)
        #expect(synced.statusLabel == "Estimate documentation ready")
        #expect(synced.sendReadinessLabel == "Ready to send with documentation")
        #expect(synced.actionSummary == "Ready to email with onsite report and linked job photos.")
        #expect(synced.failedQuickBooksAttachmentCount == 0)
        #expect(synced.syncedQuickBooksAttachmentCount == 3)
    }

    @Test func billingDocumentationPackageSummaryPrioritizesInvoicePackage() async throws {
        let customer = Customer(name: "Package Summary Customer")
        let call = ServiceCall(type: .maintenance, scheduledDate: Date(), customer: customer)
        let estimate = Estimate(serviceCallID: call.id, customer: customer, quickBooksID: "QB-EST", amount: 400)
        let invoice = Invoice(serviceCallID: call.id, customer: customer, quickBooksID: "QB-INV", amount: 400)
        let report = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoice.id,
            estimateID: estimate.id,
            kind: .serviceReport,
            displayName: "report.pdf",
            localFilePath: "/tmp/report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            quickBooksAttachableID: "ATTACH-1"
        )
        let photo = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoice.id,
            estimateID: estimate.id,
            kind: .afterPhoto,
            displayName: "after.jpg",
            localFilePath: "/tmp/after.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 1024,
            quickBooksAttachableID: "ATTACH-2"
        )
        let invoicePDF = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoice.id,
            kind: .invoiceSupport,
            displayName: "invoice.pdf",
            localFilePath: "/tmp/invoice.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            quickBooksAttachableID: "ATTACH-3"
        )

        let summary = try #require(call.billingDocumentationPackageSummary(
            invoice: invoice,
            estimate: estimate,
            attachments: [report, photo, invoicePDF]
        ))

        #expect(summary.contains("Invoice documentation ready"))
        #expect(summary.contains("1 onsite report"))
        #expect(summary.contains("1 photo"))
        #expect(summary.contains("1 billing PDF"))
        #expect(summary.contains("3 synced"))
    }

    @Test func billingDocumentationPackageSummaryFallsBackToEstimatePackage() async throws {
        let customer = Customer(name: "Estimate Package Summary Customer")
        let call = ServiceCall(type: .estimate, scheduledDate: Date(), customer: customer)
        let estimate = Estimate(serviceCallID: call.id, customer: customer, quickBooksID: "QB-EST", amount: 400)
        let report = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            estimateID: estimate.id,
            kind: .serviceReport,
            displayName: "report.pdf",
            localFilePath: "/tmp/report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let estimatePDF = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            estimateID: estimate.id,
            kind: .estimateSupport,
            displayName: "estimate.pdf",
            localFilePath: "/tmp/estimate.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )

        let summary = try #require(call.billingDocumentationPackageSummary(
            invoice: nil,
            estimate: estimate,
            attachments: [report, estimatePDF]
        ))

        #expect(summary.contains("QuickBooks attachments pending"))
        #expect(summary.contains("1 onsite report"))
        #expect(summary.contains("1 billing PDF"))
        #expect(summary.contains("2 pending"))
    }

    @Test func jobCloseoutReadinessRequiresQuickBooksInvoiceSync() async throws {
        let customer = Customer(name: "Closeout Customer")
        let call = ServiceCall(
            equipmentName: "Main Furnace",
            equipmentModel: "59TN6",
            equipmentSerialNumber: "FURN123",
            equipmentTypeRaw: HVACEquipmentType.gasFurnace.rawValue,
            serviceReportSummary: "Heating maintenance completed.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer,
            status: .invoiced,
            workCompletedChecklist: true,
            documentationChecklist: true,
            paymentCollectedChecklist: true
        )
        for definition in call.requiredTechnicalReadingDefinitions {
            call.setTechnicalReading(definition.options.first ?? "1", for: definition.key)
        }
        let invoice = Invoice(
            serviceCallID: call.id,
            customer: customer,
            amount: 500,
            status: "paid",
            customerSignatureName: "Customer",
            customerSignedAt: Date(),
            finalizedAt: Date()
        )
        let report = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoice.id,
            kind: .serviceReport,
            displayName: "report.pdf",
            localFilePath: "/tmp/report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )

        let readiness = call.closeoutReadiness(invoice: invoice, payments: [], attachments: [report])

        #expect(readiness.isReady == false)
        #expect(readiness.requiredItems.contains("QuickBooks invoice synced"))
        #expect(readiness.missingItems.contains("QuickBooks invoice synced"))
        #expect(readiness.missingItems.contains("QuickBooks attachments synced") == false)
    }

    @Test func jobCloseoutReadinessRequiresGeneratedCustomerInvoicePDF() async throws {
        let customer = Customer(name: "Closeout PDF Customer")
        let call = ServiceCall(
            equipmentName: "Main Furnace",
            equipmentModel: "59TN6",
            equipmentSerialNumber: "FURN123",
            equipmentTypeRaw: HVACEquipmentType.gasFurnace.rawValue,
            serviceReportSummary: "Heating maintenance completed.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer,
            status: .invoiced,
            workCompletedChecklist: true,
            documentationChecklist: true,
            paymentCollectedChecklist: true
        )
        for definition in call.requiredTechnicalReadingDefinitions {
            call.setTechnicalReading(definition.options.first ?? "1", for: definition.key)
        }
        let invoice = Invoice(
            serviceCallID: call.id,
            customer: customer,
            quickBooksID: "QB-INV-200",
            amount: 500,
            status: "paid",
            customerSignatureName: "Customer",
            customerSignedAt: Date(),
            finalizedAt: Date()
        )
        let report = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoice.id,
            kind: .serviceReport,
            displayName: "report.pdf",
            localFilePath: "/tmp/report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            quickBooksAttachableID: "ATTACH-REPORT"
        )

        let readiness = call.closeoutReadiness(invoice: invoice, payments: [], attachments: [report])

        #expect(readiness.isReady == false)
        #expect(readiness.requiredItems.contains("Customer invoice PDF generated"))
        #expect(readiness.missingItems.contains("Customer invoice PDF generated"))
    }

    @Test func generalCalendarAppointmentsDoNotRequireTechnicalServiceReportForCompletion() async throws {
        let customer = Customer(name: "Calendar Customer")
        let completionDate = Date(timeIntervalSince1970: 1_800_000_000)
        let call = ServiceCall(
            type: .meeting,
            scheduledDate: Date(),
            customer: customer
        )

        let markedComplete = call.markDocumentationCompleteIfReady(at: completionDate)

        #expect(markedComplete == true)
        #expect(call.documentationCompletedAt == completionDate)
    }

    @Test func furnaceReportReadinessUsesCombustionSpecificRequirements() async throws {
        let customer = Customer(name: "Furnace Customer")
        let call = ServiceCall(
            equipmentName: "Main Furnace",
            equipmentModel: "59TN6",
            equipmentSerialNumber: "FURN123",
            equipmentTypeRaw: HVACEquipmentType.gasFurnace.rawValue,
            serviceReportSummary: "Heating maintenance completed.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )

        let requiredKeys = Set(call.requiredTechnicalReadingDefinitions.map { $0.key })

        #expect(requiredKeys.contains("gas_pressure_manifold"))
        #expect(requiredKeys.contains("heat_exchanger_condition"))
        #expect(requiredKeys.contains("co_ppm"))
        #expect(requiredKeys.contains("suction_pressure") == false)
    }

    @Test func packageUnitAndMiniSplitReadinessUseEquipmentSpecificRequirements() async throws {
        let customer = Customer(name: "Technical Customer")
        let packageCall = ServiceCall(
            equipmentName: "Roof Package Unit",
            equipmentModel: "48TC",
            equipmentSerialNumber: "RTU123",
            equipmentTypeRaw: HVACEquipmentType.packageUnit.rawValue,
            serviceReportSummary: "RTU maintenance completed.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        let miniSplitCall = ServiceCall(
            equipmentName: "Office Mini Split",
            equipmentModel: "MSZ",
            equipmentSerialNumber: "MS123",
            equipmentTypeRaw: HVACEquipmentType.miniSplit.rawValue,
            serviceReportSummary: "Mini split maintenance completed.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )

        let packageRequiredKeys = Set(packageCall.requiredTechnicalReadingDefinitions.map(\.key))
        let miniSplitRequiredKeys = Set(miniSplitCall.requiredTechnicalReadingDefinitions.map(\.key))

        #expect(packageRequiredKeys.contains("package_heat_type"))
        #expect(packageRequiredKeys.contains("blower_amps"))
        #expect(packageRequiredKeys.contains("co_ppm"))
        #expect(packageRequiredKeys.contains("condenser_condition"))
        #expect(miniSplitRequiredKeys.contains("mode_tested"))
        #expect(miniSplitRequiredKeys.contains("indoor_head_delta_t"))
        #expect(miniSplitRequiredKeys.contains("indoor_filter_condition"))
        #expect(miniSplitRequiredKeys.contains("outdoor_coil_condition"))
        #expect(miniSplitRequiredKeys.contains("outdoor_fan_operation"))
        #expect(miniSplitRequiredKeys.contains("remote_operation"))
    }

    @Test func coolingEquipmentRequiresSourceReadingsForSuperheatAndSubcooling() async throws {
        let requiredSourceKeys: Set<String> = [
            "suction_saturation_temp",
            "liquid_saturation_temp",
            "suction_line_temp",
            "liquid_line_temp",
            "superheat",
            "subcooling"
        ]

        for equipmentType in [HVACEquipmentType.splitSystemAC, .heatPump, .packageUnit, .miniSplit] {
            let requiredKeys = Set(equipmentType.requiredReadingKeysForCompleteServiceReport)
            #expect(requiredSourceKeys.isSubset(of: requiredKeys), "\(equipmentType.displayName) must require calculated refrigerant source readings")
        }
    }

    @Test func equipmentSpecificTechnicalDropdownsIncludeOtherOption() async throws {
        let coolingDefinitions = HVACEquipmentType.splitSystemAC.readingDefinitions
        let heatPumpDefinitions = HVACEquipmentType.heatPump.readingDefinitions
        let furnaceDefinitions = HVACEquipmentType.gasFurnace.readingDefinitions

        #expect(coolingDefinitions.first { $0.key == "refrigerant_type" }?.options.contains("Other") == true)
        #expect(coolingDefinitions.first { $0.key == "metering_device" }?.options.contains("Other") == true)
        #expect(coolingDefinitions.first { $0.key == "condenser_condition" }?.options.contains("Other") == true)
        #expect(heatPumpDefinitions.first { $0.key == "mode_tested" }?.options.contains("Other") == true)
        #expect(HVACEquipmentType.airHandler.readingDefinitions.first { $0.key == "blower_type" }?.options.contains("Other") == true)
        #expect(furnaceDefinitions.first { $0.key == "venting_type" }?.options.contains("Other") == true)
    }

    @Test func onsiteReportTechnicalSectionsUseGroupedCapturedReadings() async throws {
        let customer = Customer(name: "Report Customer")
        let call = ServiceCall(
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        call.setTechnicalReading("12", for: "superheat")
        call.setTechnicalReading("6.2", for: "compressor_amps")
        call.setTechnicalReading("72", for: "return_air_temp")

        let sections = CustomerDocumentExporter.technicalReportSectionSummaries(for: call)

        #expect(sections.contains { section in
            section.title == "Technical Readings - Refrigerant Circuit" &&
                section.rows.contains { $0.label == "Superheat (F)" && $0.value == "12" }
        })
        #expect(sections.contains { section in
            section.title == "Technical Readings - Electrical" &&
                section.rows.contains { $0.label == "Compressor Amps (A)" && $0.value == "6.2" }
        })
        #expect(sections.contains { section in
            section.title == "Technical Readings - Air Temperatures" &&
                section.rows.contains { $0.label == "Return Air Temp (F)" && $0.value == "72" }
        })
        #expect(sections.flatMap(\.rows).contains {
            $0.label == "Subcooling (F)" && $0.value == "Missing Required Reading"
        })
    }

    @Test func onsiteReportTechnicalSectionsIncludePackageUnitCombustionReadings() async throws {
        let customer = Customer(name: "Package Report Customer")
        let call = ServiceCall(
            equipmentTypeRaw: HVACEquipmentType.packageUnit.rawValue,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        call.setTechnicalReading("325", for: "flue_temp")
        call.setTechnicalReading("18", for: "co_ppm")

        let rows = CustomerDocumentExporter.technicalReportSectionSummaries(for: call)
            .flatMap(\.rows)

        #expect(rows.contains { $0.label == "Flue Temp (F)" && $0.value == "325" })
        #expect(rows.contains { $0.label == "CO Reading (ppm)" && $0.value == "18" })
        #expect(rows.contains { $0.label == "CO Reading (ppm) Requirement" && $0.value == "Required" })
    }

    @Test func onsiteReportReadinessUsesDynamicPackageUnitRequirements() async throws {
        let customer = Customer(name: "Dynamic Package Report Customer")
        let call = ServiceCall(
            equipmentName: "Cooling Only RTU",
            equipmentTypeRaw: HVACEquipmentType.packageUnit.rawValue,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        call.setTechnicalReading("Cooling Only", for: "package_heat_type")
        call.setTechnicalReading("Normal", for: "economizer_operation")

        let rows = CustomerDocumentExporter.serviceReportReadinessRows(for: call)
        let missing = rows.first { $0.label == "Missing Required Items" }?.value ?? ""

        #expect(missing.contains("CO Reading") == false)
        #expect(missing.contains("Gas Pressure Manifold") == false)
        #expect(missing.contains("Mixed Air Temp"))
        #expect(missing.contains("Outdoor Air Damper Position"))
        #expect(missing.contains("Economizer Sensor"))
    }

    @Test func onsiteReportTechnicalSectionsMarkRequiredAndInvalidReadings() async throws {
        let customer = Customer(name: "Validation Report Customer")
        let call = ServiceCall(
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        call.setTechnicalReading("12", for: "superheat")
        call.setTechnicalReading("12", for: "line_voltage")

        let rows = CustomerDocumentExporter.technicalReportSectionSummaries(for: call)
            .flatMap(\.rows)

        #expect(rows.contains { $0.label == "Superheat (F)" && $0.value == "12" })
        #expect(rows.contains { $0.label == "Superheat (F) Requirement" && $0.value == "Required" })
        #expect(rows.contains { $0.label == "Line Voltage (V)" && $0.value == "12" })
        #expect(rows.contains { $0.label == "Line Voltage (V) Requirement" && $0.value == "Required" })
        #expect(rows.contains { $0.label == "Line Voltage (V) Validation" && $0.value.contains("outside expected range") })
        #expect(rows.contains { $0.label == "Line Voltage (V) Validation" && $0.value.contains("90-600 V") })
    }

    @Test func onsiteReportReadinessRowsExposeMissingRequiredTechnicalItems() async throws {
        let customer = Customer(name: "Readiness Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "System checked and operating.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        call.setTechnicalReading("72", for: "return_air_temp")

        let rows = CustomerDocumentExporter.serviceReportReadinessRows(for: call)

        #expect(rows.contains { $0.label == "Completion" && $0.value == "Needs details" })
        #expect(rows.contains { $0.label == "Required Items" && $0.value == call.serviceReportReadinessSummary })
        #expect(rows.contains { $0.label == "Next Required Action" && $0.value == "Complete Supply Air Temp (F)" })
        #expect(rows.contains { $0.label == "Action Summary" && $0.value.contains("Supply Air Temp (F)") })
        #expect(rows.contains { $0.label == "Action Summary" && $0.value.contains("+ ") })
        #expect(rows.contains { $0.label == "Missing Required Items" && $0.value.contains("Supply Air Temp (F)") })
        #expect(rows.contains { $0.label == "Missing Required Items" && $0.value.contains("Compressor Amps (A)") })
    }

    @Test func onsiteReportReadinessRowsExposeInvalidTechnicalReadings() async throws {
        let customer = Customer(name: "Validation Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "System checked.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        completeRequiredTechnicalReadings(for: call)
        completeRequiredMaintenanceActions(for: call)
        call.setTechnicalReading("12", for: "line_voltage")

        let rows = CustomerDocumentExporter.serviceReportReadinessRows(for: call)

        #expect(rows.contains { $0.label == "Completion" && $0.value == "Needs details" })
        #expect(rows.contains { $0.label == "Required Items" && $0.value == call.serviceReportReadinessSummary })
        #expect(rows.contains { $0.label == "Required Items" && $0.value.contains("1 invalid") })
        #expect(rows.contains { $0.label == "Next Required Action" && $0.value.hasPrefix("Review Line Voltage (V) outside expected range") })
        #expect(rows.contains { $0.label == "Missing Required Items" } == false)
        #expect(rows.contains { $0.label == "Reading Validation" && $0.value.contains("Line Voltage") })
        #expect(rows.contains { $0.label == "Reading Validation" && $0.value.contains("90-600 V") })
    }

    @Test func onsiteReportReadinessRowsExposeUnsafeCarbonMonoxideReadings() async throws {
        let customer = Customer(name: "CO Report Customer")
        let call = ServiceCall(
            equipmentName: "Gas Furnace",
            equipmentModel: "GM9C",
            equipmentSerialNumber: "FURN123",
            equipmentTypeRaw: HVACEquipmentType.gasFurnace.rawValue,
            serviceReportSummary: "Heating maintenance completed.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        for definition in call.requiredTechnicalReadingDefinitions {
            call.setTechnicalReading(definition.options.first ?? "1", for: definition.key)
        }
        call.setTechnicalReading("125", for: "co_ppm")

        let rows = CustomerDocumentExporter.serviceReportReadinessRows(for: call)

        #expect(rows.contains { $0.label == "Completion" && $0.value == "Needs details" })
        #expect(rows.contains { $0.label == "Safety Alerts" && $0.value.contains("CO Reading") })
        #expect(rows.contains { $0.label == "Safety Alerts" && $0.value.contains("100 ppm") })
        #expect(rows.contains { $0.label == "Reading Validation" && $0.value.contains("CO Reading") })
        #expect(rows.contains { $0.label == "Reading Validation" && $0.value.contains("100 ppm") })
    }

    @Test func onsiteReportTechnicalRowsExposeCrossReadingValidation() async throws {
        let customer = Customer(name: "Technical Export Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "System checked.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        call.setTechnicalReading("10", for: "target_superheat")
        call.setTechnicalReading("18", for: "superheat")

        let summaries = CustomerDocumentExporter.technicalReportSectionSummaries(for: call)
        let refrigerantRows = try #require(summaries.first { $0.title == "Technical Readings - Refrigerant Circuit" }?.rows)

        #expect(refrigerantRows.contains { $0.label == "Superheat (F) Validation" && $0.value.contains("Target Superheat") })
    }

    @Test func onsiteReportCloseoutRowsExposeIntegratedJobReadiness() async throws {
        let customer = Customer(name: "Closeout Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "System checked.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )

        let rows = CustomerDocumentExporter.closeoutReadinessRows(
            for: call,
            invoice: nil,
            payments: [],
            attachments: []
        )

        #expect(rows.contains { $0.label == "Status" && $0.value == "Needs closeout details" })
        #expect(rows.contains { $0.label == "Progress" && $0.value.contains("complete") })
        #expect(rows.contains { $0.label == "Missing Closeout Items" && $0.value.contains("Invoice created") })
        #expect(rows.contains { $0.label == "Missing Closeout Items" && $0.value.contains("Onsite report generated") })
    }

    @Test func closeoutReadinessFlagsUnlinkedSameJobQuickBooksAttachments() async throws {
        let customer = Customer(name: "Closeout Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "System checked.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer,
            workCompletedChecklist: true
        )
        for definition in call.requiredTechnicalReadingDefinitions {
            call.setTechnicalReading(definition.options.first ?? "1", for: definition.key)
        }
        let invoice = Invoice(
            serviceCallID: call.id,
            customer: customer,
            quickBooksID: "INV-123",
            amount: 400,
            status: "paid",
            customerSignedAt: Date(),
            finalizedAt: Date()
        )
        let generatedReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoice.id,
            kind: .serviceReport,
            displayName: "onsite-report.pdf",
            localFilePath: "/tmp/onsite-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 2048,
            quickBooksAttachableID: "attach-report"
        )
        let unlinkedJobPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: nil,
            kind: .diagnosticPhoto,
            displayName: "diagnostic.jpg",
            localFilePath: "/tmp/diagnostic.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 1024
        )

        let readiness = call.closeoutReadiness(
            invoice: invoice,
            payments: [],
            attachments: [generatedReport, unlinkedJobPhoto]
        )

        #expect(readiness.missingItems.contains("QuickBooks attachments synced"))
    }

    @Test func onsiteReportReadinessRowsMarkCompleteReportsReady() async throws {
        let customer = Customer(name: "Ready Customer")
        let call = ServiceCall(
            equipmentName: "Main Furnace",
            equipmentModel: "59TN6",
            equipmentSerialNumber: "FURN123",
            equipmentTypeRaw: HVACEquipmentType.gasFurnace.rawValue,
            serviceReportSummary: "Heating maintenance completed.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        completeRequiredTechnicalReadings(for: call)
        completeRequiredMaintenanceActions(for: call)

        let rows = CustomerDocumentExporter.serviceReportReadinessRows(for: call)

        #expect(rows.contains { $0.label == "Completion" && $0.value == "Ready" })
        #expect(rows.contains { $0.label == "Required Items" && $0.value == call.serviceReportReadinessSummary })
        #expect(rows.contains { $0.label == "Missing Required Items" } == false)
    }

    @Test func billingDocumentJobContextIncludesEquipmentDetails() async throws {
        let customer = Customer(
            name: "Billing Customer",
            phone: "555-0200",
            email: "billing@example.com",
            address: "123 Service Rd"
        )
        let technician = Technician(name: "Lead Tech")
        let callID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let call = ServiceCall(
            id: callID,
            equipmentName: "Main Furnace",
            equipmentManufacturer: "Carrier",
            equipmentModel: "59TN6",
            equipmentSerialNumber: "FURN123",
            equipmentLocation: "Attic",
            equipmentTypeRaw: HVACEquipmentType.gasFurnace.rawValue,
            equipmentNotes: "Requires low-profile filter access panel.",
            type: .maintenance,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            assignedTechnician: technician,
            customer: customer
        )

        let rows = CustomerDocumentExporter.billingJobContextSummaries(for: call)

        #expect(rows.contains { $0.label == "Job ID" && $0.value == "AAAAAAAA" })
        #expect(rows.contains { $0.label == "Customer" && $0.value == "Billing Customer" })
        #expect(rows.contains { $0.label == "Customer Phone" && $0.value == "555-0200" })
        #expect(rows.contains { $0.label == "Customer Email" && $0.value == "billing@example.com" })
        #expect(rows.contains { $0.label == "Equipment" && $0.value.contains("Gas Furnace") })
        #expect(rows.contains { $0.label == "Equipment" && $0.value.contains("Carrier") })
        #expect(rows.contains { $0.label == "Equipment" && $0.value.contains("S/N FURN123") })
        #expect(rows.contains { $0.label == "Equipment Location" && $0.value == "Attic" })
        #expect(rows.contains { $0.label == "Equipment Notes" && $0.value == "Requires low-profile filter access panel." })
    }

    @Test func serviceCallCalculatesTechnicalReadingsFromFieldInputs() async throws {
        let customer = Customer(name: "Diagnostic Customer")
        let call = ServiceCall(
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        call.setTechnicalReading("75", for: "return_air_temp")
        call.setTechnicalReading("56", for: "supply_air_temp")
        call.setTechnicalReading("52", for: "suction_line_temp")
        call.setTechnicalReading("40", for: "suction_saturation_temp")
        call.setTechnicalReading("90", for: "liquid_line_temp")
        call.setTechnicalReading("100", for: "liquid_saturation_temp")

        #expect(call.calculateTemperatureSplitReading() == 19)
        #expect(call.calculateTemperatureRiseReading() == -19)
        #expect(call.calculateSuperheatReading() == 12)
        #expect(call.calculateSubcoolingReading() == 10)
        #expect(call.technicalReading(for: "temperature_split") == "19.0")
        #expect(call.technicalReading(for: "temperature_rise") == "-19.0")
        #expect(call.technicalReading(for: "superheat") == "12.0")
        #expect(call.technicalReading(for: "subcooling") == "10.0")
    }

    @Test func serviceCallAutomaticallyCalculatesDerivedTechnicalReadingsFromSourceInputs() async throws {
        let customer = Customer(name: "Auto Diagnostic Customer")
        let call = ServiceCall(
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )

        call.setTechnicalReading("75", for: "return_air_temp")
        #expect(call.technicalReading(for: "temperature_split").isEmpty)
        #expect(call.technicalReading(for: "temperature_rise").isEmpty)
        call.setTechnicalReading("56", for: "supply_air_temp")
        #expect(call.technicalReading(for: "temperature_split") == "19.0")
        #expect(call.technicalReading(for: "temperature_rise") == "-19.0")

        call.setTechnicalReading("52", for: "suction_line_temp")
        call.setTechnicalReading("40", for: "suction_saturation_temp")
        #expect(call.technicalReading(for: "superheat") == "12.0")

        call.setTechnicalReading("90", for: "liquid_line_temp")
        call.setTechnicalReading("100", for: "liquid_saturation_temp")
        #expect(call.technicalReading(for: "subcooling") == "10.0")

        call.setTechnicalReading("-0.32", for: "static_pressure_return")
        call.setTechnicalReading("0.28", for: "static_pressure_supply")
        #expect(call.technicalReading(for: "total_external_static") == "0.6")
    }

    @Test func airHandlerCalculatesTotalExternalStaticFromReturnAndSupplyReadings() async throws {
        let customer = Customer(name: "Static Customer")
        let call = ServiceCall(
            equipmentTypeRaw: HVACEquipmentType.airHandler.rawValue,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        call.setTechnicalReading("-0.32", for: "static_pressure_return")
        call.setTechnicalReading("0.28", for: "static_pressure_supply")

        let totalStatic = try #require(call.calculateTotalExternalStaticReading())
        #expect(abs(totalStatic - 0.6) < 0.001)
        #expect(call.technicalReading(for: "total_external_static") == "0.6")
    }

    @Test func gasFurnaceCalculatesTemperatureRiseFromSupplyAndReturnReadings() async throws {
        let customer = Customer(name: "Furnace Diagnostic Customer")
        let call = ServiceCall(
            equipmentTypeRaw: HVACEquipmentType.gasFurnace.rawValue,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        call.setTechnicalReading("68", for: "return_air_temp")
        call.setTechnicalReading("122", for: "supply_air_temp")

        let rise = try #require(call.calculateTemperatureRiseReading())
        #expect(rise == 54)
        #expect(call.technicalReading(for: "temperature_rise") == "54.0")
        #expect(call.requiredTechnicalReadingDefinitions.contains { $0.key == "temperature_rise" })
    }

    @Test func quickBooksMimeTypeDetection() async throws {
        #expect(QuickBooksDataAPI.mimeType(for: URL(fileURLWithPath: "/tmp/file.jpg")) == "image/jpeg")
        #expect(QuickBooksDataAPI.mimeType(for: URL(fileURLWithPath: "/tmp/file.pdf")) == "application/pdf")
        #expect(QuickBooksDataAPI.mimeType(for: URL(fileURLWithPath: "/tmp/file.unknown")) == "application/octet-stream")
    }

    @Test func quickBooksUploadBodyContainsExpectedParts() async throws {
        let boundary = "Boundary-Test"
        let filename = "receipt.jpg"
        let contentType = "image/jpeg"
        let fileData = Data([0x01, 0x02, 0x03])
        let metadataJSON = #"{"FileName":"receipt.jpg","ContentType":"image/jpeg","Note":"Uploaded from test"}"#

        let body = QuickBooksDataAPI.buildUploadBody(
            boundary: boundary,
            filename: filename,
            contentType: contentType,
            fileData: fileData,
            metadataJSON: metadataJSON
        )
        let bodyString = String(data: body, encoding: .utf8) ?? ""

        #expect(bodyString.contains("name=\"file_metadata_01\""))
        #expect(bodyString.contains(metadataJSON))
        #expect(bodyString.contains("name=\"file_content_01\"; filename=\"\(filename)\""))
        #expect(bodyString.contains("Content-Type: \(contentType)"))
        #expect(bodyString.contains("--\(boundary)--"))
    }

    @Test func serviceReportAttachmentKindIsDocument() async throws {
        #expect(ServiceDocumentAttachmentKind.serviceReport.label == "Service Report")
        #expect(ServiceDocumentAttachmentKind.serviceReport.isPhoto == false)
    }

    @Test func serviceReportAttachmentLinksToInvoiceWhenMissing() async throws {
        let customer = Customer(name: "Report Customer")
        let invoice = Invoice(customer: customer, amount: 250)
        let report = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            kind: .serviceReport,
            displayName: "onsite-report.pdf",
            localFilePath: "/tmp/onsite-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let alreadyLinkedInvoiceID = UUID()
        let alreadyLinkedReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            invoiceID: alreadyLinkedInvoiceID,
            kind: .serviceReport,
            displayName: "existing-report.pdf",
            localFilePath: "/tmp/existing-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )

        report.linkToInvoiceIfNeeded(invoice)
        alreadyLinkedReport.linkToInvoiceIfNeeded(invoice)

        #expect(report.canLinkToInvoiceReport == true)
        #expect(report.invoiceID == invoice.id)
        #expect(alreadyLinkedReport.invoiceID == alreadyLinkedInvoiceID)
    }

    @Test func linkingAttachmentToNewBillingTargetClearsStaleQuickBooksAttachmentState() async throws {
        let customer = Customer(name: "Report Customer")
        let estimate = Estimate(customer: customer, quickBooksID: "QB-EST-1", amount: 250)
        let invoice = Invoice(customer: customer, quickBooksID: "QB-INV-1", amount: 250)
        let report = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            estimateID: estimate.id,
            kind: .serviceReport,
            displayName: "onsite-report.pdf",
            localFilePath: "/tmp/onsite-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            quickBooksAttachableID: "estimate-attachable",
            quickBooksSyncError: "old estimate target"
        )

        report.linkToInvoiceIfNeeded(invoice)

        #expect(report.invoiceID == invoice.id)
        #expect(report.estimateID == estimate.id)
        #expect(report.quickBooksAttachableID == nil)
        #expect(report.quickBooksSyncError == nil)
        #expect(report.canBePendingQuickBooksInvoiceAttachment(for: invoice))
    }

    @Test func customerEmailAttachmentsIncludeLatestLinkedOnsiteReport() async throws {
        let customer = Customer(name: "Email Report Customer")
        let serviceCallID = UUID()
        let invoiceURL = URL(fileURLWithPath: "/tmp/gunnaire-invoice.pdf")
        let olderReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            kind: .serviceReport,
            displayName: "older-report.pdf",
            localFilePath: "/tmp/older-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let latestReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            kind: .serviceReport,
            displayName: "latest-report.pdf",
            localFilePath: "/tmp/latest-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 200)
        )
        let unrelatedReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            kind: .serviceReport,
            displayName: "unrelated-report.pdf",
            localFilePath: "/tmp/unrelated-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 300)
        )

        let urls = CustomerDocumentExporter.customerEmailAttachmentURLs(
            primaryDocumentURL: invoiceURL,
            serviceCallID: serviceCallID,
            attachments: [olderReport, unrelatedReport, latestReport]
        )

        #expect(urls.map(\.lastPathComponent) == ["gunnaire-invoice.pdf", "latest-report.pdf"])
    }

    @Test func customerEmailAttachmentsDoNotDuplicatePrimaryOnsiteReport() async throws {
        let customer = Customer(name: "Email Report Customer")
        let serviceCallID = UUID()
        let reportURL = URL(fileURLWithPath: "/tmp/latest-report.pdf")
        let latestReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            kind: .serviceReport,
            displayName: "latest-report.pdf",
            localFilePath: reportURL.path,
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 200)
        )

        let urls = CustomerDocumentExporter.customerEmailAttachmentURLs(
            primaryDocumentURL: reportURL,
            serviceCallID: serviceCallID,
            attachments: [latestReport]
        )

        #expect(urls.map(\.lastPathComponent) == ["latest-report.pdf"])
    }

    @Test func customerEmailAttachmentsPreferReportLinkedToInvoice() async throws {
        let customer = Customer(name: "Email Report Customer")
        let serviceCallID = UUID()
        let invoiceID = UUID()
        let otherInvoiceID = UUID()
        let invoiceURL = URL(fileURLWithPath: "/tmp/gunnaire-invoice.pdf")
        let newestWrongInvoiceReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            invoiceID: otherInvoiceID,
            kind: .serviceReport,
            displayName: "wrong-invoice-report.pdf",
            localFilePath: "/tmp/wrong-invoice-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 300)
        )
        let linkedReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            invoiceID: invoiceID,
            kind: .serviceReport,
            displayName: "linked-invoice-report.pdf",
            localFilePath: "/tmp/linked-invoice-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 200)
        )

        let urls = CustomerDocumentExporter.customerEmailAttachmentURLs(
            primaryDocumentURL: invoiceURL,
            serviceCallID: serviceCallID,
            invoiceID: invoiceID,
            attachments: [newestWrongInvoiceReport, linkedReport]
        )

        #expect(urls.map(\.lastPathComponent) == ["gunnaire-invoice.pdf", "linked-invoice-report.pdf"])
    }

    @Test func customerEmailAttachmentsDoNotFallbackToUnlinkedReportForInvoice() async throws {
        let customer = Customer(name: "Email Report Customer")
        let serviceCallID = UUID()
        let invoiceID = UUID()
        let invoiceURL = URL(fileURLWithPath: "/tmp/gunnaire-invoice.pdf")
        let unlinkedReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            kind: .serviceReport,
            displayName: "unlinked-report.pdf",
            localFilePath: "/tmp/unlinked-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 300)
        )

        let urls = CustomerDocumentExporter.customerEmailAttachmentURLs(
            primaryDocumentURL: invoiceURL,
            serviceCallID: serviceCallID,
            invoiceID: invoiceID,
            attachments: [unlinkedReport]
        )

        #expect(urls.map(\.lastPathComponent) == ["gunnaire-invoice.pdf"])
    }

    @Test func customerEmailAttachmentsUseConvertedEstimateReportForInvoice() async throws {
        let customer = Customer(name: "Email Report Customer")
        let serviceCallID = UUID()
        let invoiceID = UUID()
        let estimateID = UUID()
        let invoiceURL = URL(fileURLWithPath: "/tmp/gunnaire-invoice.pdf")
        let estimateReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            estimateID: estimateID,
            kind: .serviceReport,
            displayName: "estimate-onsite-report.pdf",
            localFilePath: "/tmp/estimate-onsite-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 200)
        )
        let unlinkedReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            kind: .serviceReport,
            displayName: "unlinked-report.pdf",
            localFilePath: "/tmp/unlinked-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 300)
        )

        let urls = CustomerDocumentExporter.customerEmailAttachmentURLs(
            primaryDocumentURL: invoiceURL,
            serviceCallID: serviceCallID,
            invoiceID: invoiceID,
            estimateID: estimateID,
            attachments: [unlinkedReport, estimateReport]
        )

        #expect(urls.map(\.lastPathComponent) == ["gunnaire-invoice.pdf", "estimate-onsite-report.pdf"])
    }

    @Test func customerEmailAttachmentsUseSingleConvertedEstimateReportWhenEstimateLinkMissing() async throws {
        let customer = Customer(name: "Email Report Customer")
        let serviceCallID = UUID()
        let invoiceID = UUID()
        let estimateID = UUID()
        let invoiceURL = URL(fileURLWithPath: "/tmp/gunnaire-invoice.pdf")
        let estimateReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            estimateID: estimateID,
            kind: .serviceReport,
            displayName: "only-estimate-onsite-report.pdf",
            localFilePath: "/tmp/only-estimate-onsite-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 200)
        )

        let urls = CustomerDocumentExporter.customerEmailAttachmentURLs(
            primaryDocumentURL: invoiceURL,
            serviceCallID: serviceCallID,
            invoiceID: invoiceID,
            attachments: [estimateReport]
        )

        #expect(urls.map(\.lastPathComponent) == ["gunnaire-invoice.pdf", "only-estimate-onsite-report.pdf"])
    }

    @Test func customerEmailAttachmentsDoNotGuessConvertedEstimateReportWhenMultipleEstimateReportsExist() async throws {
        let customer = Customer(name: "Email Report Customer")
        let serviceCallID = UUID()
        let invoiceID = UUID()
        let invoiceURL = URL(fileURLWithPath: "/tmp/gunnaire-invoice.pdf")
        let firstEstimateReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            estimateID: UUID(),
            kind: .serviceReport,
            displayName: "first-estimate-report.pdf",
            localFilePath: "/tmp/first-estimate-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 200)
        )
        let secondEstimateReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            estimateID: UUID(),
            kind: .serviceReport,
            displayName: "second-estimate-report.pdf",
            localFilePath: "/tmp/second-estimate-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 300)
        )

        let urls = CustomerDocumentExporter.customerEmailAttachmentURLs(
            primaryDocumentURL: invoiceURL,
            serviceCallID: serviceCallID,
            invoiceID: invoiceID,
            attachments: [secondEstimateReport, firstEstimateReport]
        )

        #expect(urls.map(\.lastPathComponent) == ["gunnaire-invoice.pdf"])
    }

    @Test func customerEmailAttachmentsPreferInvoiceReportOverConvertedEstimateReport() async throws {
        let customer = Customer(name: "Email Report Customer")
        let serviceCallID = UUID()
        let invoiceID = UUID()
        let estimateID = UUID()
        let invoiceURL = URL(fileURLWithPath: "/tmp/gunnaire-invoice.pdf")
        let newerEstimateReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            estimateID: estimateID,
            kind: .serviceReport,
            displayName: "newer-estimate-report.pdf",
            localFilePath: "/tmp/newer-estimate-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 300)
        )
        let invoiceReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            invoiceID: invoiceID,
            estimateID: estimateID,
            kind: .serviceReport,
            displayName: "invoice-report.pdf",
            localFilePath: "/tmp/invoice-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 200)
        )

        let urls = CustomerDocumentExporter.customerEmailAttachmentURLs(
            primaryDocumentURL: invoiceURL,
            serviceCallID: serviceCallID,
            invoiceID: invoiceID,
            estimateID: estimateID,
            attachments: [newerEstimateReport, invoiceReport]
        )

        #expect(urls.map(\.lastPathComponent) == ["gunnaire-invoice.pdf", "invoice-report.pdf"])
    }

    @Test func customerEmailAttachmentsPreferReportLinkedToEstimate() async throws {
        let customer = Customer(name: "Email Estimate Customer")
        let serviceCallID = UUID()
        let estimateID = UUID()
        let otherEstimateID = UUID()
        let estimateURL = URL(fileURLWithPath: "/tmp/gunnaire-estimate.pdf")
        let newestWrongEstimateReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            estimateID: otherEstimateID,
            kind: .serviceReport,
            displayName: "wrong-estimate-report.pdf",
            localFilePath: "/tmp/wrong-estimate-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 300)
        )
        let linkedReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            estimateID: estimateID,
            kind: .serviceReport,
            displayName: "linked-estimate-report.pdf",
            localFilePath: "/tmp/linked-estimate-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 200)
        )

        let urls = CustomerDocumentExporter.customerEmailAttachmentURLs(
            primaryDocumentURL: estimateURL,
            serviceCallID: serviceCallID,
            estimateID: estimateID,
            attachments: [newestWrongEstimateReport, linkedReport]
        )

        #expect(urls.map(\.lastPathComponent) == ["gunnaire-estimate.pdf", "linked-estimate-report.pdf"])
    }

    @Test func serviceReportAttachmentLinksToEstimateWhenMissing() async throws {
        let customer = Customer(name: "Estimate Report Customer")
        let estimate = Estimate(customer: customer, amount: 250)
        let report = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            kind: .serviceReport,
            displayName: "onsite-report.pdf",
            localFilePath: "/tmp/onsite-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let alreadyLinkedEstimateID = UUID()
        let alreadyLinkedReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            estimateID: alreadyLinkedEstimateID,
            kind: .serviceReport,
            displayName: "existing-estimate-report.pdf",
            localFilePath: "/tmp/existing-estimate-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )

        report.linkToEstimateIfNeeded(estimate)
        alreadyLinkedReport.linkToEstimateIfNeeded(estimate)

        #expect(report.estimateID == estimate.id)
        #expect(alreadyLinkedReport.estimateID == alreadyLinkedEstimateID)
    }

    @Test func invoiceAttachmentUploadEligibilityRequiresLinkedQuickBooksInvoice() async throws {
        let customer = Customer(name: "Report Customer")
        let otherCustomer = Customer(name: "Other Report Customer")
        let invoice = Invoice(customer: customer, quickBooksID: "123", amount: 250)
        let estimate = Estimate(customer: customer, quickBooksID: "789", amount: 250)
        let unSyncedReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            invoiceID: invoice.id,
            kind: .serviceReport,
            displayName: "onsite-report.pdf",
            localFilePath: "/tmp/onsite-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let uploadedReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            invoiceID: invoice.id,
            kind: .serviceReport,
            displayName: "uploaded-report.pdf",
            localFilePath: "/tmp/uploaded-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            quickBooksAttachableID: "attach-1"
        )
        let estimateSupport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            estimateID: estimate.id,
            kind: .estimateSupport,
            displayName: "estimate-support.pdf",
            localFilePath: "/tmp/estimate-support.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let photo = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            invoiceID: invoice.id,
            kind: .diagnosticPhoto,
            displayName: "diagnostic.jpg",
            localFilePath: "/tmp/diagnostic.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 1024
        )
        let invoiceSupport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            invoiceID: invoice.id,
            kind: .invoiceSupport,
            displayName: "invoice-support.pdf",
            localFilePath: "/tmp/invoice-support.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let receipt = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            invoiceID: invoice.id,
            kind: .receipt,
            displayName: "receipt.jpg",
            localFilePath: "/tmp/receipt.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 1024
        )
        let wrongCustomerInvoiceAttachment = ServiceDocumentAttachment(
            customer: otherCustomer,
            serviceCallID: UUID(),
            invoiceID: invoice.id,
            kind: .customerDocument,
            displayName: "wrong-customer-invoice.pdf",
            localFilePath: "/tmp/wrong-customer-invoice.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let wrongCustomerEstimateAttachment = ServiceDocumentAttachment(
            customer: otherCustomer,
            serviceCallID: UUID(),
            estimateID: estimate.id,
            kind: .customerDocument,
            displayName: "wrong-customer-estimate.pdf",
            localFilePath: "/tmp/wrong-customer-estimate.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let localOnlyInvoice = Invoice(customer: customer, amount: 250)
        let localOnlyEstimate = Estimate(customer: customer, amount: 250)

        #expect(unSyncedReport.canUploadToQuickBooksInvoice(invoice) == true)
        #expect(uploadedReport.canUploadToQuickBooksInvoice(invoice) == false)
        #expect(photo.canUploadToQuickBooksInvoice(invoice) == true)
        #expect(invoiceSupport.canUploadToQuickBooksInvoice(invoice) == true)
        #expect(invoiceSupport.canUploadToQuickBooksEstimate(estimate) == false)
        #expect(estimateSupport.canUploadToQuickBooksInvoice(invoice) == false)
        #expect(receipt.canUploadToQuickBooksInvoice(invoice) == false)
        #expect(wrongCustomerInvoiceAttachment.canUploadToQuickBooksInvoice(invoice) == false)
        #expect(unSyncedReport.canUploadToQuickBooksInvoice(localOnlyInvoice) == false)
        #expect(unSyncedReport.canBePendingQuickBooksInvoiceAttachment(for: invoice) == true)
        #expect(uploadedReport.canBePendingQuickBooksInvoiceAttachment(for: invoice) == false)
        #expect(receipt.canBePendingQuickBooksInvoiceAttachment(for: invoice) == false)
        #expect(wrongCustomerInvoiceAttachment.canBePendingQuickBooksInvoiceAttachment(for: invoice) == false)
        #expect(estimateSupport.canUploadToQuickBooksEstimate(estimate) == true)
        #expect(wrongCustomerEstimateAttachment.canUploadToQuickBooksEstimate(estimate) == false)
        #expect(estimateSupport.canUploadToQuickBooksEstimate(localOnlyEstimate) == false)
        #expect(receipt.canUploadToQuickBooksEstimate(estimate) == false)
    }

    @MainActor
    @Test func quickBooksInvoiceAttachmentSyncFindsPendingInvoiceAttachments() async throws {
        let customer = Customer(name: "Report Customer")
        let invoice = Invoice(customer: customer, quickBooksID: "123", amount: 250)
        let otherInvoice = Invoice(customer: customer, quickBooksID: "456", amount: 100)
        let pendingReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            invoiceID: invoice.id,
            kind: .serviceReport,
            displayName: "onsite-report.pdf",
            localFilePath: "/tmp/onsite-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let uploadedReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            invoiceID: otherInvoice.id,
            kind: .serviceReport,
            displayName: "uploaded-report.pdf",
            localFilePath: "/tmp/uploaded-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            quickBooksAttachableID: "attach-1"
        )
        let pendingPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            invoiceID: invoice.id,
            kind: .diagnosticPhoto,
            displayName: "diagnostic.jpg",
            localFilePath: "/tmp/diagnostic.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 1024
        )
        let receipt = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            invoiceID: invoice.id,
            kind: .receipt,
            displayName: "receipt.jpg",
            localFilePath: "/tmp/receipt.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 1024
        )

        let pending = QuickBooksInvoiceAttachmentSync.pendingInvoiceAttachments(
            invoices: [invoice, otherInvoice],
            attachments: [pendingReport, uploadedReport, pendingPhoto, receipt]
        )

        #expect(pending.count == 2)
        #expect(pending.contains { $0.attachment === pendingReport && $0.invoice === invoice })
        #expect(pending.contains { $0.attachment === pendingPhoto && $0.invoice === invoice })
        #expect(pending.contains { $0.attachment === receipt } == false)
    }

    @MainActor
    @Test func quickBooksAttachmentSyncLinksJobDocumentsToBillingDocumentsBeforeUpload() async throws {
        let customer = Customer(name: "Linked Customer")
        let otherCustomer = Customer(name: "Other Customer")
        let serviceCallID = UUID()
        let invoice = Invoice(
            serviceCallID: serviceCallID,
            customer: customer,
            quickBooksID: "INV-123",
            amount: 450
        )
        let estimate = Estimate(
            serviceCallID: serviceCallID,
            customer: customer,
            quickBooksID: "EST-123",
            amount: 450
        )
        let serviceReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            kind: .serviceReport,
            displayName: "onsite-report.pdf",
            localFilePath: "/tmp/onsite-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let diagnosticPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            kind: .diagnosticPhoto,
            displayName: "diagnostic.jpg",
            localFilePath: "/tmp/diagnostic.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 1024
        )
        let mismatchedCustomerDocument = ServiceDocumentAttachment(
            customer: otherCustomer,
            serviceCallID: serviceCallID,
            kind: .customerDocument,
            displayName: "wrong-customer.pdf",
            localFilePath: "/tmp/wrong-customer.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )

        let changedCount = QuickBooksInvoiceAttachmentSync.linkServiceCallAttachmentsToBillingDocuments(
            estimates: [estimate],
            invoices: [invoice],
            attachments: [serviceReport, diagnosticPhoto, mismatchedCustomerDocument]
        )
        let pendingInvoices = QuickBooksInvoiceAttachmentSync.pendingInvoiceAttachments(
            invoices: [invoice],
            attachments: [serviceReport, diagnosticPhoto, mismatchedCustomerDocument]
        )
        let pendingEstimates = QuickBooksInvoiceAttachmentSync.pendingEstimateAttachments(
            estimates: [estimate],
            attachments: [serviceReport, diagnosticPhoto, mismatchedCustomerDocument]
        )
        let pendingUploads = QuickBooksInvoiceAttachmentSync.pendingQuickBooksAttachmentUploads(
            estimates: [estimate],
            invoices: [invoice],
            attachments: [serviceReport, diagnosticPhoto, mismatchedCustomerDocument]
        )
        let serviceReportRefs = QuickBooksInvoiceAttachmentSync.quickBooksAttachableReferences(
            for: serviceReport,
            estimates: [estimate],
            invoices: [invoice]
        )

        #expect(changedCount == 4)
        #expect(serviceReport.invoiceID == invoice.id)
        #expect(serviceReport.estimateID == estimate.id)
        #expect(diagnosticPhoto.invoiceID == invoice.id)
        #expect(diagnosticPhoto.estimateID == estimate.id)
        #expect(mismatchedCustomerDocument.invoiceID == nil)
        #expect(mismatchedCustomerDocument.estimateID == nil)
        #expect(pendingInvoices.contains { $0.attachment === serviceReport && $0.invoice === invoice })
        #expect(pendingInvoices.contains { $0.attachment === diagnosticPhoto && $0.invoice === invoice })
        #expect(pendingEstimates.contains { $0.attachment === serviceReport && $0.estimate === estimate })
        #expect(pendingEstimates.contains { $0.attachment === diagnosticPhoto && $0.estimate === estimate })
        #expect(pendingUploads.count == 2)
        #expect(pendingUploads.contains { $0 === serviceReport })
        #expect(pendingUploads.contains { $0 === diagnosticPhoto })
        #expect(serviceReportRefs.map(\.EntityRef.type) == ["Invoice", "Estimate"])
        #expect(serviceReportRefs.map(\.EntityRef.value) == ["INV-123", "EST-123"])
    }

    @MainActor
    @Test func quickBooksAttachmentSyncUsesServiceCallBillingLinksWhenBillingBackReferencesAreMissing() async throws {
        let customer = Customer(name: "Linked Customer")
        let invoice = Invoice(
            customer: customer,
            quickBooksID: "INV-456",
            amount: 450
        )
        let estimate = Estimate(
            customer: customer,
            quickBooksID: "EST-456",
            amount: 450
        )
        let call = ServiceCall(
            type: .service,
            scheduledDate: Date(),
            customer: customer,
            linkedEstimateID: estimate.id,
            linkedInvoiceID: invoice.id
        )
        let serviceReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            kind: .serviceReport,
            displayName: "onsite-report.pdf",
            localFilePath: "/tmp/onsite-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let diagnosticPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            kind: .diagnosticPhoto,
            displayName: "diagnostic.jpg",
            localFilePath: "/tmp/diagnostic.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 1024
        )

        let changedCount = QuickBooksInvoiceAttachmentSync.linkServiceCallAttachmentsToBillingDocuments(
            estimates: [estimate],
            invoices: [invoice],
            serviceCalls: [call],
            attachments: [serviceReport, diagnosticPhoto]
        )

        #expect(changedCount == 4)
        #expect(serviceReport.invoiceID == invoice.id)
        #expect(serviceReport.estimateID == estimate.id)
        #expect(diagnosticPhoto.invoiceID == invoice.id)
        #expect(diagnosticPhoto.estimateID == estimate.id)
        #expect(invoice.serviceCallID == nil)
        #expect(estimate.serviceCallID == nil)
    }

    @MainActor
    @Test func quickBooksAttachmentSyncTracksSpecificAttachedBillingTargets() async throws {
        let customer = Customer(name: "Targeted Attachment Customer")
        let serviceCallID = UUID()
        let invoice = Invoice(
            serviceCallID: serviceCallID,
            customer: customer,
            quickBooksID: "INV-456",
            amount: 750
        )
        let estimate = Estimate(
            serviceCallID: serviceCallID,
            customer: customer,
            quickBooksID: "EST-456",
            amount: 750
        )
        let serviceReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            invoiceID: invoice.id,
            estimateID: estimate.id,
            kind: .serviceReport,
            displayName: "onsite-report.pdf",
            localFilePath: "/tmp/onsite-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            quickBooksAttachableID: "ATTACH-EST"
        )
        let estimateReference = try #require(serviceReport.quickBooksEstimateReference(for: estimate))
        serviceReport.markQuickBooksAttached(to: [estimateReference])

        let invoiceReference = try #require(serviceReport.quickBooksInvoiceReference(for: invoice))
        let allReferences = QuickBooksInvoiceAttachmentSync.quickBooksAttachableReferences(
            for: serviceReport,
            estimates: [estimate],
            invoices: [invoice]
        )
        let missingReferences = QuickBooksInvoiceAttachmentSync.missingQuickBooksAttachableReferences(
            for: serviceReport,
            estimates: [estimate],
            invoices: [invoice]
        )

        #expect(serviceReport.isQuickBooksAttached(to: [estimateReference]))
        #expect(serviceReport.isQuickBooksAttached(to: [invoiceReference]) == false)
        #expect(allReferences.map(\.EntityRef.value) == ["INV-456"])
        #expect(missingReferences.map(\.EntityRef.value) == ["INV-456"])
        #expect(QuickBooksInvoiceAttachmentSync.pendingInvoiceAttachments(invoices: [invoice], attachments: [serviceReport]).count == 1)
        #expect(QuickBooksInvoiceAttachmentSync.pendingEstimateAttachments(estimates: [estimate], attachments: [serviceReport]).isEmpty)
    }

    @MainActor
    @Test func quickBooksAttachmentSyncPreservesKnownTargetTrackingWhenNewBillingDocumentLinks() async throws {
        let customer = Customer(name: "Retarget Attachment Customer")
        let serviceCallID = UUID()
        let invoice = Invoice(
            serviceCallID: serviceCallID,
            customer: customer,
            quickBooksID: "INV-789",
            amount: 525
        )
        let estimate = Estimate(
            serviceCallID: serviceCallID,
            customer: customer,
            quickBooksID: "EST-789",
            amount: 525
        )
        let serviceReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            estimateID: estimate.id,
            kind: .serviceReport,
            displayName: "onsite-report.pdf",
            localFilePath: "/tmp/onsite-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            quickBooksAttachableID: "ATTACH-EST"
        )
        let estimateReference = try #require(serviceReport.quickBooksEstimateReference(for: estimate))
        serviceReport.markQuickBooksAttached(to: [estimateReference])

        serviceReport.linkToInvoiceIfNeeded(invoice)

        #expect(serviceReport.invoiceID == invoice.id)
        #expect(serviceReport.quickBooksAttachableID == "ATTACH-EST")
        #expect(serviceReport.quickBooksAttachedEntityKeys == [
            ServiceDocumentAttachment.quickBooksAttachedEntityKey(
                type: QuickBooksAttachableEntityType.estimate.rawValue,
                value: "EST-789"
            )
        ])
        #expect(serviceReport.quickBooksSyncError == nil)
        let missingReferences = QuickBooksInvoiceAttachmentSync.missingQuickBooksAttachableReferences(
            for: serviceReport,
            estimates: [estimate],
            invoices: [invoice]
        )
        #expect(missingReferences.map(\.EntityRef.value) == ["INV-789"])
    }

    @MainActor
    @Test func quickBooksAttachmentSyncClearsLegacyUnknownTargetWhenNewBillingDocumentLinks() async throws {
        let customer = Customer(name: "Legacy Attachment Customer")
        let serviceCallID = UUID()
        let invoice = Invoice(
            serviceCallID: serviceCallID,
            customer: customer,
            quickBooksID: "INV-LEGACY",
            amount: 525
        )
        let legacyReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            kind: .serviceReport,
            displayName: "onsite-report.pdf",
            localFilePath: "/tmp/onsite-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            quickBooksAttachableID: "LEGACY-ATTACH"
        )

        legacyReport.linkToInvoiceIfNeeded(invoice)

        #expect(legacyReport.invoiceID == invoice.id)
        #expect(legacyReport.quickBooksAttachableID == nil)
        #expect(legacyReport.quickBooksAttachedEntityKeys.isEmpty)
        #expect(legacyReport.quickBooksSyncError == nil)
    }

    @Test func regeneratedGeneratedDocumentClearsQuickBooksAttachmentTargetState() async throws {
        let customer = Customer(name: "Regenerated Attachment Customer")
        let invoice = Invoice(customer: customer, quickBooksID: "INV-REGEN", amount: 500)
        let attachment = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            invoiceID: invoice.id,
            kind: .invoiceSupport,
            displayName: "old-invoice.pdf",
            localFilePath: "/tmp/old-invoice.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 128,
            quickBooksAttachableID: "ATTACH-OLD"
        )
        let reference = try #require(attachment.quickBooksInvoiceReference(for: invoice))
        attachment.markQuickBooksAttached(to: [reference])

        attachment.replaceGeneratedFile(
            displayName: "new-invoice.pdf",
            localFilePath: "/tmp/new-invoice.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 256,
            caption: "Regenerated invoice PDF"
        )

        #expect(attachment.quickBooksAttachableID == nil)
        #expect(attachment.quickBooksSyncError == nil)
        #expect(attachment.quickBooksAttachedEntityKeys.isEmpty)
        #expect(attachment.canUploadToQuickBooksInvoice(invoice))
    }

    @MainActor
    @Test func quickBooksAttachmentSyncFindsPendingEstimateAttachments() async throws {
        let customer = Customer(name: "Estimate Attachment Customer")
        let estimate = Estimate(customer: customer, quickBooksID: "EST-123", amount: 250)
        let localOnlyEstimate = Estimate(customer: customer, amount: 100)
        let pendingEstimatePDF = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            estimateID: estimate.id,
            kind: .estimateSupport,
            displayName: "estimate.pdf",
            localFilePath: "/tmp/estimate.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let uploadedEstimatePDF = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            estimateID: estimate.id,
            kind: .estimateSupport,
            displayName: "uploaded-estimate.pdf",
            localFilePath: "/tmp/uploaded-estimate.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            quickBooksAttachableID: "attach-1"
        )
        let localOnlyAttachment = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            estimateID: localOnlyEstimate.id,
            kind: .estimateSupport,
            displayName: "local-estimate.pdf",
            localFilePath: "/tmp/local-estimate.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )

        let pending = QuickBooksInvoiceAttachmentSync.pendingEstimateAttachments(
            estimates: [estimate, localOnlyEstimate],
            attachments: [pendingEstimatePDF, uploadedEstimatePDF, localOnlyAttachment]
        )

        #expect(pending.count == 1)
        #expect(pending.contains { $0.attachment === pendingEstimatePDF && $0.estimate === estimate })
    }

    @MainActor
    @Test func quickBooksAttachmentSyncQueuesGeneratedBillingPDFsLinkedByServiceCall() async throws {
        let customer = Customer(name: "Generated Billing Customer")
        let serviceCallID = UUID()
        let invoice = Invoice(
            serviceCallID: serviceCallID,
            customer: customer,
            quickBooksID: "INV-123",
            amount: 450
        )
        let estimate = Estimate(
            serviceCallID: serviceCallID,
            customer: customer,
            quickBooksID: "EST-123",
            amount: 450
        )
        let generatedInvoicePDF = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            kind: .invoiceSupport,
            displayName: "paid-invoice.pdf",
            localFilePath: "/tmp/paid-invoice.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 2048
        )
        let generatedEstimatePDF = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            kind: .estimateSupport,
            displayName: "estimate.pdf",
            localFilePath: "/tmp/estimate.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 2048
        )

        let changed = QuickBooksInvoiceAttachmentSync.linkServiceCallAttachmentsToBillingDocuments(
            estimates: [estimate],
            invoices: [invoice],
            attachments: [generatedInvoicePDF, generatedEstimatePDF]
        )
        let pendingInvoices = QuickBooksInvoiceAttachmentSync.pendingInvoiceAttachments(
            invoices: [invoice],
            attachments: [generatedInvoicePDF, generatedEstimatePDF]
        )
        let pendingEstimates = QuickBooksInvoiceAttachmentSync.pendingEstimateAttachments(
            estimates: [estimate],
            attachments: [generatedInvoicePDF, generatedEstimatePDF]
        )

        #expect(changed == 2)
        #expect(generatedInvoicePDF.invoiceID == invoice.id)
        #expect(generatedInvoicePDF.estimateID == nil)
        #expect(generatedEstimatePDF.invoiceID == nil)
        #expect(generatedEstimatePDF.estimateID == estimate.id)
        #expect(pendingInvoices.contains { $0.attachment === generatedInvoicePDF && $0.invoice === invoice })
        #expect(pendingInvoices.contains { $0.attachment === generatedEstimatePDF } == false)
        #expect(pendingEstimates.contains { $0.attachment === generatedInvoicePDF } == false)
        #expect(pendingEstimates.contains { $0.attachment === generatedEstimatePDF && $0.estimate === estimate })
    }

    @Test func serviceDocumentAttachmentExposesLocalFileURLForOpening() async throws {
        let attachment = ServiceDocumentAttachment(
            customer: nil,
            serviceCallID: nil,
            kind: .diagnosticPhoto,
            displayName: "diagnostic.jpg",
            localFilePath: "/tmp/diagnostic.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 128
        )

        #expect(attachment.localFileURL.isFileURL)
        #expect(attachment.localFileURL.path == "/tmp/diagnostic.jpg")
        #expect(attachment.isImage == true)
    }

    @Test func customerPrimaryPhotoPrefersProfileCaptionedImage() async throws {
        let customer = Customer(name: "Photo Customer")
        let olderDiagnostic = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            kind: .diagnosticPhoto,
            displayName: "diagnostic.jpg",
            localFilePath: "/tmp/diagnostic.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 128,
            createdAt: Date(timeIntervalSince1970: 1_800_000_300)
        )
        let profilePhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            kind: .customerDocument,
            displayName: "customer.jpg",
            caption: "Profile photo",
            localFilePath: "/tmp/customer.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 128,
            createdAt: Date(timeIntervalSince1970: 1_800_000_100)
        )
        let generatedReportImage = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            kind: .serviceReport,
            displayName: "report-preview.png",
            localFilePath: "/tmp/report-preview.png",
            contentType: "image/png",
            fileSizeBytes: 128,
            createdAt: Date(timeIntervalSince1970: 1_800_000_400)
        )

        let selected = ServiceDocumentAttachment.primaryCustomerPhoto(
            for: customer,
            in: [olderDiagnostic, profilePhoto, generatedReportImage]
        )

        #expect(selected === profilePhoto)
    }

    @Test func customerPrimaryPhotoPrefersDedicatedProfilePhotoKind() async throws {
        let customer = Customer(name: "Photo Customer")
        let captionedPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            kind: .customerDocument,
            displayName: "captioned-profile.jpg",
            caption: "Profile photo",
            localFilePath: "/tmp/captioned-profile.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 128,
            createdAt: Date(timeIntervalSince1970: 1_800_000_300)
        )
        let dedicatedProfilePhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            kind: .customerProfilePhoto,
            displayName: "customer-front.jpg",
            localFilePath: "/tmp/customer-front.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 128,
            createdAt: Date(timeIntervalSince1970: 1_800_000_100)
        )

        let selected = ServiceDocumentAttachment.primaryCustomerPhoto(
            for: customer,
            in: [captionedPhoto, dedicatedProfilePhoto]
        )

        #expect(ServiceDocumentAttachmentKind.customerProfilePhoto.customerProfileGroupTitle == "Photos")
        #expect(dedicatedProfilePhoto.canUseAsCustomerProfilePhoto)
        #expect(dedicatedProfilePhoto.canLinkToQuickBooksInvoiceAttachment == false)
        #expect(dedicatedProfilePhoto.canLinkToQuickBooksInvoiceDocument == false)
        #expect(dedicatedProfilePhoto.canLinkToQuickBooksEstimateDocument == false)
        #expect(selected === dedicatedProfilePhoto)
    }

    @Test func equipmentPrimaryPhotoPrefersLinkedDataPlatePhoto() async throws {
        let customer = Customer(name: "Equipment Photo Customer")
        let equipment = CustomerEquipment(customer: customer, name: "Main System")
        let olderDiagnostic = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            customerEquipmentID: equipment.id,
            kind: .diagnosticPhoto,
            displayName: "diagnostic.jpg",
            localFilePath: "/tmp/diagnostic.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 128,
            createdAt: Date(timeIntervalSince1970: 1_800_000_500)
        )
        let dataPlate = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            customerEquipmentID: equipment.id,
            kind: .equipmentDataPlatePhoto,
            displayName: "data-plate.jpg",
            localFilePath: "/tmp/data-plate.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 128,
            createdAt: Date(timeIntervalSince1970: 1_800_000_100)
        )
        let receipt = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            customerEquipmentID: equipment.id,
            kind: .receipt,
            displayName: "receipt.jpg",
            localFilePath: "/tmp/receipt.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 128,
            createdAt: Date(timeIntervalSince1970: 1_800_000_800)
        )

        let selected = ServiceDocumentAttachment.primaryEquipmentPhoto(
            for: equipment,
            in: [receipt, olderDiagnostic, dataPlate]
        )

        #expect(dataPlate.canUseAsEquipmentProfilePhoto)
        #expect(receipt.canUseAsEquipmentProfilePhoto == false)
        #expect(selected === dataPlate)
    }

    @Test func equipmentPrimaryPhotoCanResolveFromLinkedServiceCall() async throws {
        let customer = Customer(name: "Equipment Job Photo Customer")
        let equipment = CustomerEquipment(customer: customer, name: "Attic Air Handler")
        let call = ServiceCall(
            customerEquipmentID: equipment.id,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        let jobPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            kind: .diagnosticPhoto,
            displayName: "job-diagnostic.jpg",
            localFilePath: "/tmp/job-diagnostic.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 128
        )

        let selected = ServiceDocumentAttachment.primaryEquipmentPhoto(
            for: equipment,
            in: [jobPhoto],
            serviceCalls: [call]
        )

        #expect(selected === jobPhoto)
    }

    @Test func equipmentDataPlatePhotoStaysEquipmentEvidenceNotCustomerProfile() async throws {
        let customer = Customer(name: "Equipment Photo Customer")
        let equipment = CustomerEquipment(customer: customer, name: "Main System")
        let invoice = Invoice(customer: customer, quickBooksID: "INV-123", amount: 500)
        let estimate = Estimate(customer: customer, quickBooksID: "EST-123", amount: 500)
        let dataPlate = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            customerEquipmentID: equipment.id,
            kind: .equipmentDataPlatePhoto,
            displayName: "data-plate.jpg",
            localFilePath: "/tmp/data-plate.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 128
        )

        #expect(ServiceDocumentAttachmentKind.equipmentDataPlatePhoto.label == "Equipment Data Plate Photo")
        #expect(ServiceDocumentAttachmentKind.equipmentDataPlatePhoto.customerProfileGroupTitle == "Photos")
        #expect(dataPlate.isImage)
        #expect(dataPlate.kind.isPhoto)
        #expect(dataPlate.canUseAsCustomerProfilePhoto == false)
        #expect(dataPlate.canShowInActiveEquipmentHistory)
        #expect(dataPlate.canBePendingQuickBooksInvoiceAttachment(for: invoice))

        dataPlate.linkToInvoiceIfNeeded(invoice)
        dataPlate.linkToEstimateIfNeeded(estimate)

        #expect(dataPlate.canUploadToQuickBooksInvoice(invoice))
        #expect(dataPlate.canUploadToQuickBooksEstimate(estimate))
    }

    @Test func customerPrimaryPhotoFallsBackToLatestUsableImageForThatCustomer() async throws {
        let customer = Customer(name: "Photo Customer")
        let otherCustomer = Customer(name: "Other Customer")
        let olderPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            kind: .beforePhoto,
            displayName: "older.jpg",
            localFilePath: "/tmp/older.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 128,
            createdAt: Date(timeIntervalSince1970: 1_800_000_100)
        )
        let newerPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            kind: .diagnosticPhoto,
            displayName: "newer.jpg",
            localFilePath: "/tmp/newer.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 128,
            createdAt: Date(timeIntervalSince1970: 1_800_000_200)
        )
        let unrelatedPhoto = ServiceDocumentAttachment(
            customer: otherCustomer,
            serviceCallID: nil,
            kind: .diagnosticPhoto,
            displayName: "other.jpg",
            localFilePath: "/tmp/other.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 128,
            createdAt: Date(timeIntervalSince1970: 1_800_000_300)
        )
        let nonImage = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            kind: .customerDocument,
            displayName: "manual.pdf",
            localFilePath: "/tmp/manual.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 128,
            createdAt: Date(timeIntervalSince1970: 1_800_000_400)
        )

        let selected = ServiceDocumentAttachment.primaryCustomerPhoto(
            for: customer,
            in: [olderPhoto, newerPhoto, unrelatedPhoto, nonImage]
        )

        #expect(selected === newerPhoto)
    }

    @Test func customerPrimaryPhotoPrefersCustomerLevelImageOverEquipmentPhoto() async throws {
        let customer = Customer(name: "Photo Customer")
        let equipmentPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            customerEquipmentID: UUID(),
            kind: .diagnosticPhoto,
            displayName: "profile-equipment.jpg",
            caption: "Profile photo from service visit",
            localFilePath: "/tmp/profile-equipment.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 128,
            createdAt: Date(timeIntervalSince1970: 1_800_000_300)
        )
        let customerLevelPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            customerEquipmentID: nil,
            kind: .customerDocument,
            displayName: "customer-front.jpg",
            localFilePath: "/tmp/customer-front.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 128,
            createdAt: Date(timeIntervalSince1970: 1_800_000_100)
        )

        let selected = ServiceDocumentAttachment.primaryCustomerPhoto(
            for: customer,
            in: [equipmentPhoto, customerLevelPhoto]
        )

        #expect(selected === customerLevelPhoto)
    }

    @Test func customerPrimaryPhotoCanFallbackToLinkedFieldPhoto() async throws {
        let customer = Customer(name: "Photo Customer")
        let linkedFieldPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            customerEquipmentID: UUID(),
            kind: .diagnosticPhoto,
            displayName: "equipment-panel.jpg",
            localFilePath: "/tmp/equipment-panel.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 128,
            createdAt: Date(timeIntervalSince1970: 1_800_000_100)
        )

        let selected = ServiceDocumentAttachment.primaryCustomerPhoto(
            for: customer,
            in: [linkedFieldPhoto]
        )

        #expect(selected === linkedFieldPhoto)
    }

    @Test func customerPrimaryPhotoIgnoresBillingAndReceiptImages() async throws {
        let customer = Customer(name: "Photo Customer")
        let diagnosticPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            kind: .diagnosticPhoto,
            displayName: "equipment.jpg",
            localFilePath: "/tmp/equipment.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 128,
            createdAt: Date(timeIntervalSince1970: 1_800_000_100)
        )
        let receiptImage = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            kind: .receipt,
            displayName: "profile-receipt.jpg",
            caption: "Profile photo",
            localFilePath: "/tmp/profile-receipt.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 128,
            createdAt: Date(timeIntervalSince1970: 1_800_000_300)
        )
        let invoiceImage = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            kind: .invoiceSupport,
            displayName: "profile-invoice.jpg",
            caption: "Customer photo",
            localFilePath: "/tmp/profile-invoice.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 128,
            createdAt: Date(timeIntervalSince1970: 1_800_000_400)
        )

        let selected = ServiceDocumentAttachment.primaryCustomerPhoto(
            for: customer,
            in: [diagnosticPhoto, receiptImage, invoiceImage]
        )

        #expect(receiptImage.canUseAsCustomerProfilePhoto == false)
        #expect(invoiceImage.canUseAsCustomerProfilePhoto == false)
        #expect(diagnosticPhoto.canUseAsCustomerProfilePhoto == true)
        #expect(selected === diagnosticPhoto)
    }

    @Test func customerProfileAttachmentsHideFinancialFilesForStandardUsers() async throws {
        let customer = Customer(name: "Document Visibility Customer")
        let serviceReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            kind: .serviceReport,
            displayName: "service-report.pdf",
            localFilePath: "/tmp/service-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let diagnosticPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            kind: .diagnosticPhoto,
            displayName: "diagnostic.jpg",
            localFilePath: "/tmp/diagnostic.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 1024
        )
        let invoiceSupport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            kind: .invoiceSupport,
            displayName: "invoice.pdf",
            localFilePath: "/tmp/invoice.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let estimateSupport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            kind: .estimateSupport,
            displayName: "estimate.pdf",
            localFilePath: "/tmp/estimate.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let receipt = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            kind: .receipt,
            displayName: "receipt.jpg",
            localFilePath: "/tmp/receipt.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 1024
        )
        let attachments: [ServiceDocumentAttachment] = [serviceReport, diagnosticPhoto, invoiceSupport, estimateSupport, receipt]

        let standardVisible = ServiceDocumentAttachment.visibleCustomerProfileAttachments(
            in: attachments,
            canViewFinancials: false
        )
        let adminVisible = ServiceDocumentAttachment.visibleCustomerProfileAttachments(
            in: attachments,
            canViewFinancials: true
        )

        #expect(standardVisible.map(\.kind) == [.serviceReport, .diagnosticPhoto])
        #expect(adminVisible.count == attachments.count)
        #expect(invoiceSupport.isFinancialCustomerProfileAttachment)
        #expect(estimateSupport.isFinancialCustomerProfileAttachment)
        #expect(receipt.isFinancialCustomerProfileAttachment)
    }

    @Test func customerProfileAttachmentKindsUseSeparateBusinessRecordGroups() async throws {
        #expect(ServiceDocumentAttachmentKind.serviceReport.customerProfileGroupTitle == "Service Reports")
        #expect(ServiceDocumentAttachmentKind.estimateSupport.customerProfileGroupTitle == "Estimate Documents")
        #expect(ServiceDocumentAttachmentKind.invoiceSupport.customerProfileGroupTitle == "Invoice Documents")
        #expect(ServiceDocumentAttachmentKind.receipt.customerProfileGroupTitle == "Receipts & Bills")
        #expect(ServiceDocumentAttachmentKind.diagnosticPhoto.customerProfileGroupTitle == "Photos")
        #expect(ServiceDocumentAttachmentKind.customerDocument.customerProfileGroupTitle == "Customer Files")
    }

    @Test func customerProfileAttachmentDetailLinksJobBillingAndStorageContext() async throws {
        let customer = Customer(name: "Report Customer")
        let call = ServiceCall(
            equipmentName: "Main Furnace",
            equipmentModel: "59TN6",
            equipmentSerialNumber: "FURN123",
            equipmentTypeRaw: HVACEquipmentType.gasFurnace.rawValue,
            serviceReportSummary: "Heating maintenance completed.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer,
            status: .completed
        )
        completeRequiredTechnicalReadings(for: call)
        completeRequiredMaintenanceActions(for: call)
        call.setServiceActionStatus(.needsService, for: "heat_exchanger_checked")
        let invoice = Invoice(customer: customer, quickBooksID: "123", amount: 250, status: "paid")
        let estimate = Estimate(customer: customer, quickBooksID: "456", amount: 250, status: "accepted")
        let attachment = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoice.id,
            estimateID: estimate.id,
            kind: .serviceReport,
            displayName: "onsite-report.pdf",
            localFilePath: "/tmp/onsite-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            backendDocumentID: "backend-1",
            quickBooksAttachableID: "attach-1"
        )

        let lines = attachment.customerProfileDetailLines(
            serviceCalls: [call],
            invoices: [invoice],
            estimates: [estimate],
            equipmentProfiles: [],
            canViewFinancials: true
        )

        #expect(lines.contains("Job: Maintenance - Completed"))
        #expect(lines.contains("Report: Ready"))
        #expect(lines.contains { $0.contains("Open Service Concerns:") && $0.contains("Heat exchanger inspected: Needs Service") })
        #expect(lines.contains { $0.contains("Filter checked/replaced") })
        #expect(lines.contains("Invoice: Paid - QuickBooks synced"))
        #expect(lines.contains("Estimate: Accepted - QuickBooks synced"))
        #expect(lines.contains("Attached to QuickBooks invoice"))
        #expect(lines.contains("Synced to company storage"))
    }

    @Test func backendDocumentCreatesLinkedLocalAttachmentForSharedDownload() async throws {
        let customer = Customer(name: "Shared Download Customer")
        let serviceCallID = UUID()
        let invoiceID = UUID()
        let estimateID = UUID()
        let equipmentID = UUID()
        let document = BackendDocumentRecord(
            id: "backend-doc-1",
            filename: "shared-report.pdf",
            contentType: "application/pdf",
            kind: ServiceDocumentAttachmentKind.serviceReport.rawValue,
            serviceCallID: serviceCallID.uuidString,
            invoiceID: invoiceID.uuidString,
            estimateID: estimateID.uuidString,
            customerEquipmentID: equipmentID.uuidString,
            equipmentName: "Downstairs AC",
            customerName: customer.name,
            storedPath: "/documents/shared-report.pdf",
            createdAt: "2026-08-13T20:00:00Z"
        )

        let attachment = ServiceDocumentAttachment.localAttachment(
            from: document,
            existingAttachments: [],
            customer: customer,
            serviceCallID: nil,
            customerEquipmentID: nil,
            localFilePath: "/tmp/shared-report.pdf",
            fileSizeBytes: 4096
        )

        #expect(attachment.customer?.id == customer.id)
        #expect(attachment.serviceCallID == serviceCallID)
        #expect(attachment.invoiceID == invoiceID)
        #expect(attachment.estimateID == estimateID)
        #expect(attachment.customerEquipmentID == equipmentID)
        #expect(attachment.kind == .serviceReport)
        #expect(attachment.displayName == "shared-report.pdf")
        #expect(attachment.localFilePath == "/tmp/shared-report.pdf")
        #expect(attachment.fileSizeBytes == 4096)
        #expect(attachment.backendDocumentID == "backend-doc-1")
        #expect(attachment.caption == "Downstairs AC")
    }

    @Test func backendDocumentDownloadUpdatesExistingLocalAttachmentInsteadOfDuplicating() async throws {
        let customer = Customer(name: "Shared Existing Customer")
        let serviceCallID = UUID()
        let invoiceID = UUID()
        let estimateID = UUID()
        let equipmentID = UUID()
        let existing = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            customerEquipmentID: equipmentID,
            kind: .customerDocument,
            displayName: "old-name.pdf",
            localFilePath: "/tmp/old-name.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 128,
            backendDocumentID: "backend-doc-2"
        )
        let document = BackendDocumentRecord(
            id: "backend-doc-2",
            filename: "updated-report.pdf",
            contentType: "application/pdf",
            kind: ServiceDocumentAttachmentKind.serviceReport.rawValue,
            serviceCallID: serviceCallID.uuidString,
            invoiceID: invoiceID.uuidString,
            estimateID: estimateID.uuidString,
            customerEquipmentID: equipmentID.uuidString,
            equipmentName: "Main Furnace",
            customerName: customer.name,
            storedPath: "/documents/updated-report.pdf",
            createdAt: "2026-08-13T20:00:00Z"
        )

        let hydrated = ServiceDocumentAttachment.localAttachment(
            from: document,
            existingAttachments: [existing],
            customer: customer,
            serviceCallID: nil,
            customerEquipmentID: nil,
            localFilePath: "/tmp/updated-report.pdf",
            fileSizeBytes: 2048
        )

        #expect(hydrated === existing)
        #expect(existing.kind == .serviceReport)
        #expect(existing.displayName == "updated-report.pdf")
        #expect(existing.invoiceID == invoiceID)
        #expect(existing.estimateID == estimateID)
        #expect(existing.customerEquipmentID == equipmentID)
        #expect(existing.localFilePath == "/tmp/updated-report.pdf")
        #expect(existing.fileSizeBytes == 2048)
        #expect(existing.caption == "Main Furnace")
    }

    @Test func customerProfileAttachmentSearchMatchesReportEquipmentAndReadingContext() async throws {
        let customer = Customer(name: "Search Customer")
        let equipment = CustomerEquipment(
            customer: customer,
            equipmentType: .splitSystemAC,
            name: "Downstairs AC",
            modelNumber: "24ABC6"
        )
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            customerEquipmentID: equipment.id,
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "Replaced weak capacitor and verified cooling.",
            type: .service,
            scheduledDate: Date(),
            customer: customer,
            status: .completed
        )
        call.setTechnicalReading("72", for: "return_air_temp")
        call.setTechnicalReading("54", for: "supply_air_temp")
        call.setTechnicalReading("12", for: "superheat")
        call.setServiceActionStatus(.needsService, for: "condenser_coil_serviced")
        let attachment = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            customerEquipmentID: equipment.id,
            kind: .serviceReport,
            displayName: "onsite-report.pdf",
            caption: "Final cooling service report",
            localFilePath: "/tmp/onsite-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )

        #expect(attachment.matchesCustomerProfileSearch(
            "weak capacitor",
            serviceCalls: [call],
            invoices: [],
            estimates: [],
            equipmentProfiles: [equipment],
            canViewFinancials: false
        ))
        #expect(attachment.matchesCustomerProfileSearch(
            "Downstairs AC",
            serviceCalls: [call],
            invoices: [],
            estimates: [],
            equipmentProfiles: [equipment],
            canViewFinancials: false
        ))
        #expect(attachment.matchesCustomerProfileSearch(
            "superheat",
            serviceCalls: [call],
            invoices: [],
            estimates: [],
            equipmentProfiles: [equipment],
            canViewFinancials: false
        ))
        #expect(attachment.matchesCustomerProfileSearch(
            "condenser coil",
            serviceCalls: [call],
            invoices: [],
            estimates: [],
            equipmentProfiles: [equipment],
            canViewFinancials: false
        ))
    }

    @Test func jobAttachmentSearchMatchesOperationalContext() async throws {
        let customer = Customer(name: "Job Attachment Search Customer")
        let equipment = CustomerEquipment(
            customer: customer,
            equipmentType: .splitSystemAC,
            name: "Downstairs AC",
            manufacturer: "Carrier",
            modelNumber: "24ABC6",
            serialNumber: "AC123",
            location: "Basement mechanical room",
            filterSize: "16x25x1"
        )
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            customerEquipmentID: equipment.id,
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "Replaced weak capacitor and verified cooling.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer,
            followUpRequired: true,
            followUpAction: "Return to replace weak capacitor."
        )
        call.setTechnicalReading("12", for: "superheat")
        call.setServiceActionStatus(.needsService, for: "condenser_coil_serviced")
        let attachment = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            customerEquipmentID: equipment.id,
            kind: .diagnosticPhoto,
            displayName: "after-repair.jpg",
            caption: "Outdoor unit after cleaning",
            localFilePath: "/tmp/after-repair.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048
        )

        #expect(attachment.matchesJobAttachmentSearch(
            "basement mechanical",
            serviceCall: call,
            equipmentProfiles: [equipment]
        ))
        #expect(attachment.matchesJobAttachmentSearch(
            "superheat",
            serviceCall: call,
            equipmentProfiles: [equipment]
        ))
        #expect(attachment.matchesJobAttachmentSearch(
            "condenser coil",
            serviceCall: call,
            equipmentProfiles: [equipment]
        ))
        #expect(attachment.matchesJobAttachmentSearch(
            "weak capacitor",
            serviceCall: call,
            equipmentProfiles: [equipment]
        ))
        #expect(attachment.matchesJobAttachmentSearch(
            "unrelated boiler",
            serviceCall: call,
            equipmentProfiles: [equipment]
        ) == false)
    }

    @Test func customerProfileAttachmentSearchRespectsFinancialVisibility() async throws {
        let customer = Customer(name: "Private Billing Customer")
        let invoice = Invoice(customer: customer, quickBooksID: "INV-123", amount: 500, status: "unpaid")
        let invoiceAttachment = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            invoiceID: invoice.id,
            kind: .invoiceSupport,
            displayName: "invoice-500.pdf",
            localFilePath: "/tmp/invoice-500.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            quickBooksAttachableID: "attach-123"
        )

        #expect(invoiceAttachment.matchesCustomerProfileSearch(
            "QuickBooks",
            serviceCalls: [],
            invoices: [invoice],
            estimates: [],
            equipmentProfiles: [],
            canViewFinancials: true
        ))
        #expect(invoiceAttachment.matchesCustomerProfileSearch(
            "invoice",
            serviceCalls: [],
            invoices: [invoice],
            estimates: [],
            equipmentProfiles: [],
            canViewFinancials: false
        ) == false)
    }

    @Test func customerProfileAttachmentDetailShowsQueuedQuickBooksAttachmentStatus() async throws {
        let customer = Customer(name: "Queued Attachment Customer")
        let invoice = Invoice(customer: customer, quickBooksID: "qbo-invoice", amount: 250)
        let estimate = Estimate(customer: customer, quickBooksID: "qbo-estimate", amount: 250)
        let invoiceAttachment = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            invoiceID: invoice.id,
            kind: .invoiceSupport,
            displayName: "invoice.pdf",
            localFilePath: "/tmp/invoice.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let estimateAttachment = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            estimateID: estimate.id,
            kind: .estimateSupport,
            displayName: "estimate.pdf",
            localFilePath: "/tmp/estimate.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )

        let invoiceLines = invoiceAttachment.customerProfileDetailLines(
            serviceCalls: [],
            invoices: [invoice],
            estimates: [estimate],
            equipmentProfiles: [],
            canViewFinancials: true
        )
        let estimateLines = estimateAttachment.customerProfileDetailLines(
            serviceCalls: [],
            invoices: [invoice],
            estimates: [estimate],
            equipmentProfiles: [],
            canViewFinancials: true
        )
        let standardUserLines = invoiceAttachment.customerProfileDetailLines(
            serviceCalls: [],
            invoices: [invoice],
            estimates: [estimate],
            equipmentProfiles: [],
            canViewFinancials: false
        )

        #expect(invoiceLines.contains("Queued for QuickBooks invoice attachment"))
        #expect(estimateLines.contains("Queued for QuickBooks estimate attachment"))
        #expect(standardUserLines.contains("Queued for QuickBooks invoice attachment") == false)
    }

    @Test func customerProfileAttachmentDetailHidesQuickBooksAttachmentStatusForStandardUsers() async throws {
        let customer = Customer(name: "Attachment Privacy Customer")
        let attachment = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            invoiceID: UUID(),
            kind: .serviceReport,
            displayName: "service-report.pdf",
            localFilePath: "/tmp/service-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            quickBooksAttachableID: "qbo-attach-1"
        )

        let adminLines = attachment.customerProfileDetailLines(
            serviceCalls: [],
            invoices: [],
            estimates: [],
            equipmentProfiles: [],
            canViewFinancials: true
        )
        let standardLines = attachment.customerProfileDetailLines(
            serviceCalls: [],
            invoices: [],
            estimates: [],
            equipmentProfiles: [],
            canViewFinancials: false
        )

        #expect(adminLines.contains("Attached to QuickBooks invoice"))
        #expect(standardLines.contains { $0.contains("QuickBooks") } == false)
    }

    @Test func customerProfileAttachmentDetailUsesQuickBooksInvoiceBalanceStatus() async throws {
        let customer = Customer(name: "QBO Attachment Customer")
        let paidInQuickBooks = Invoice(
            customer: customer,
            quickBooksID: "paid-qbo",
            quickBooksBalanceDue: 0,
            amount: 400,
            status: "unpaid"
        )
        let openInQuickBooks = Invoice(
            customer: customer,
            quickBooksID: "open-qbo",
            quickBooksBalanceDue: 125,
            amount: 400,
            status: "paid"
        )
        let paidAttachment = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            invoiceID: paidInQuickBooks.id,
            kind: .serviceReport,
            displayName: "paid-report.pdf",
            localFilePath: "/tmp/paid-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let openAttachment = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            invoiceID: openInQuickBooks.id,
            kind: .serviceReport,
            displayName: "open-report.pdf",
            localFilePath: "/tmp/open-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )

        let paidLines = paidAttachment.customerProfileDetailLines(
            serviceCalls: [],
            invoices: [paidInQuickBooks],
            estimates: [],
            equipmentProfiles: [],
            canViewFinancials: true
        )
        let openLines = openAttachment.customerProfileDetailLines(
            serviceCalls: [],
            invoices: [openInQuickBooks],
            estimates: [],
            equipmentProfiles: [],
            canViewFinancials: true
        )

        #expect(paidLines.contains("Invoice: Paid - QuickBooks synced"))
        #expect(paidLines.contains("Invoice Balance: $0.00"))
        #expect(openLines.contains("Invoice: Partial - QuickBooks synced"))
        #expect(openLines.contains("Invoice Balance: $125.00"))
    }

    @Test func customerProfileAttachmentDetailShowsLinkedEquipment() async throws {
        let customer = Customer(name: "Equipment Attachment Customer")
        let equipment = CustomerEquipment(
            customer: customer,
            equipmentType: .splitSystemAC,
            name: "Downstairs AC",
            manufacturer: "Carrier",
            modelNumber: "24ABC6",
            serialNumber: "AC123"
        )
        let attachment = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            customerEquipmentID: equipment.id,
            kind: .diagnosticPhoto,
            displayName: "compressor-plate.jpg",
            localFilePath: "/tmp/compressor-plate.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048
        )

        let lines = attachment.customerProfileDetailLines(
            serviceCalls: [],
            invoices: [],
            estimates: [],
            equipmentProfiles: [equipment],
            canViewFinancials: false
        )

        #expect(lines.contains { $0.contains("Equipment: Downstairs AC") })
        #expect(lines.contains { $0.contains("Carrier") })
        #expect(lines.contains { $0.contains("AC123") })
    }

    @Test func customerProfileAttachmentDetailInfersEquipmentFromLinkedServiceCall() async throws {
        let customer = Customer(name: "Equipment Attachment Customer")
        let equipment = CustomerEquipment(
            customer: customer,
            equipmentType: .splitSystemAC,
            name: "Downstairs AC",
            manufacturer: "Carrier",
            modelNumber: "24ABC6",
            serialNumber: "AC123"
        )
        let call = ServiceCall(
            customerEquipmentID: equipment.id,
            type: .maintenance,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            customer: customer
        )
        let attachment = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            customerEquipmentID: nil,
            kind: .diagnosticPhoto,
            displayName: "legacy-job-photo.jpg",
            localFilePath: "/tmp/legacy-job-photo.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048
        )

        let lines = attachment.customerProfileDetailLines(
            serviceCalls: [call],
            invoices: [],
            estimates: [],
            equipmentProfiles: [equipment],
            canViewFinancials: false
        )

        #expect(lines.contains { $0.contains("Equipment: Downstairs AC") })
        #expect(lines.contains { $0.contains("Carrier") })
        #expect(lines.contains { $0.contains("AC123") })
    }

    @Test func customerProfileAttachmentDetailShowsOperationalFileMetadata() async throws {
        let customer = Customer(name: "File Metadata Customer")
        let attachment = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            kind: .customerDocument,
            displayName: "manual.pdf",
            localFilePath: "/tmp/manual.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let lines = attachment.customerProfileDetailLines(
            serviceCalls: [],
            invoices: [],
            estimates: [],
            equipmentProfiles: [],
            canViewFinancials: false
        )

        #expect(lines.contains { $0.hasPrefix("Added:") })
        #expect(lines.contains("Size: 2 KB"))
        #expect(lines.contains("Local File: Not downloaded on this device"))
    }

    @Test func customerProfileServiceReportDetailsIncludeSummaryAndTechnicalSnapshot() async throws {
        let customer = Customer(name: "Technical Report Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "System checked and cooling normally.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer,
            status: .completed
        )
        call.setTechnicalReading("76", for: "return_air_temp")
        call.setTechnicalReading("56", for: "supply_air_temp")
        call.setTechnicalReading("12", for: "superheat")
        call.setServiceActionStatus(.completed, for: "condenser_coil_serviced")
        call.setServiceActionStatus(.needsService, for: "condensate_drain_checked")
        let attachment = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            kind: .serviceReport,
            displayName: "onsite-report.pdf",
            localFilePath: "/tmp/onsite-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )

        let lines = attachment.customerProfileDetailLines(
            serviceCalls: [call],
            invoices: [],
            estimates: [],
            equipmentProfiles: [],
            canViewFinancials: false
        )

        #expect(lines.contains("Summary: System checked and cooling normally."))
        #expect(lines.contains { $0.hasPrefix("Readings:") && $0.contains("Return Air Temp") })
        #expect(lines.contains { $0.hasPrefix("Readings:") && $0.contains("Supply Air Temp") })
        #expect(lines.contains { $0.hasPrefix("Readings:") && $0.contains("Superheat") })
        #expect(lines.contains { $0.hasPrefix("Actions:") && $0.contains("Condensate drain checked/treated: Needs Service") })
        #expect(lines.contains { $0.hasPrefix("Actions:") && $0.contains("Condenser coil inspected/washed: Completed") })
        #expect(lines.contains { $0.contains("Invoice") } == false)
        #expect(lines.contains { $0.contains("QuickBooks") } == false)
    }

    @Test func equipmentHistoryAttachmentsExcludeCurrentJobAndUnrelatedEquipment() async throws {
        let customer = Customer(name: "Equipment History Customer")
        let linkedEquipmentID = UUID()
        let unrelatedEquipmentID = UUID()
        let currentCall = ServiceCall(
            customerEquipmentID: linkedEquipmentID,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        let previousCall = ServiceCall(
            customerEquipmentID: linkedEquipmentID,
            type: .service,
            scheduledDate: Date().addingTimeInterval(-86_400),
            customer: customer
        )
        let priorEquipmentReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: previousCall.id,
            customerEquipmentID: linkedEquipmentID,
            kind: .serviceReport,
            displayName: "prior-report.pdf",
            localFilePath: "/tmp/prior-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date().addingTimeInterval(-100)
        )
        let priorEquipmentPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            customerEquipmentID: linkedEquipmentID,
            kind: .diagnosticPhoto,
            displayName: "nameplate.jpg",
            localFilePath: "/tmp/nameplate.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date()
        )
        let currentJobAttachment = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: currentCall.id,
            customerEquipmentID: linkedEquipmentID,
            kind: .diagnosticPhoto,
            displayName: "current-job.jpg",
            localFilePath: "/tmp/current-job.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048
        )
        let unrelatedAttachment = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            customerEquipmentID: unrelatedEquipmentID,
            kind: .customerDocument,
            displayName: "other-unit.pdf",
            localFilePath: "/tmp/other-unit.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let priorInvoicePDF = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: previousCall.id,
            customerEquipmentID: linkedEquipmentID,
            kind: .invoiceSupport,
            displayName: "prior-invoice.pdf",
            localFilePath: "/tmp/prior-invoice.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date().addingTimeInterval(100)
        )
        let priorReceipt = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: previousCall.id,
            customerEquipmentID: linkedEquipmentID,
            kind: .receipt,
            displayName: "receipt.jpg",
            localFilePath: "/tmp/receipt.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 1024,
            createdAt: Date().addingTimeInterval(200)
        )

        let history = ServiceDocumentAttachment.equipmentHistoryAttachments(
            for: currentCall,
            in: [
                priorEquipmentReport,
                priorEquipmentPhoto,
                currentJobAttachment,
                unrelatedAttachment,
                priorInvoicePDF,
                priorReceipt
            ]
        )

        #expect(priorEquipmentReport.canShowInActiveEquipmentHistory == true)
        #expect(priorInvoicePDF.canShowInActiveEquipmentHistory == false)
        #expect(priorReceipt.canShowInActiveEquipmentHistory == false)
        #expect(history.map(\.displayName) == ["nameplate.jpg", "prior-report.pdf"])
    }

    @Test func backfillsMissingEquipmentLinksForExistingJobAttachments() async throws {
        let customer = Customer(name: "Equipment Backfill Customer")
        let otherCustomer = Customer(name: "Other Customer")
        let equipmentID = UUID()
        let otherEquipmentID = UUID()
        let call = ServiceCall(
            customerEquipmentID: equipmentID,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        let unlinkedPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            kind: .diagnosticPhoto,
            displayName: "unlinked-photo.jpg",
            localFilePath: "/tmp/unlinked-photo.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 1024
        )
        let explicitlyLinkedPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            customerEquipmentID: otherEquipmentID,
            kind: .diagnosticPhoto,
            displayName: "other-equipment-photo.jpg",
            localFilePath: "/tmp/other-equipment-photo.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 1024
        )
        let wrongCustomerPhoto = ServiceDocumentAttachment(
            customer: otherCustomer,
            serviceCallID: call.id,
            kind: .diagnosticPhoto,
            displayName: "wrong-customer-photo.jpg",
            localFilePath: "/tmp/wrong-customer-photo.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 1024
        )

        let updated = ServiceDocumentAttachment.backfillMissingEquipmentLinks(
            for: call,
            in: [unlinkedPhoto, explicitlyLinkedPhoto, wrongCustomerPhoto]
        )

        #expect(updated == 1)
        #expect(unlinkedPhoto.customerEquipmentID == equipmentID)
        #expect(explicitlyLinkedPhoto.customerEquipmentID == otherEquipmentID)
        #expect(wrongCustomerPhoto.customerEquipmentID == nil)
    }

    @Test func equipmentHistoryAttachmentsInferPriorEquipmentFromLinkedServiceCall() async throws {
        let customer = Customer(name: "Equipment History Customer")
        let linkedEquipmentID = UUID()
        let currentCall = ServiceCall(
            customerEquipmentID: linkedEquipmentID,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        let previousCall = ServiceCall(
            customerEquipmentID: linkedEquipmentID,
            type: .service,
            scheduledDate: Date().addingTimeInterval(-86_400),
            customer: customer
        )
        let legacyPriorReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: previousCall.id,
            customerEquipmentID: nil,
            kind: .serviceReport,
            displayName: "legacy-prior-report.pdf",
            localFilePath: "/tmp/legacy-prior-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date().addingTimeInterval(-100)
        )
        let currentJobAttachment = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: currentCall.id,
            customerEquipmentID: nil,
            kind: .diagnosticPhoto,
            displayName: "current-job.jpg",
            localFilePath: "/tmp/current-job.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date()
        )

        let history = ServiceDocumentAttachment.equipmentHistoryAttachments(
            for: currentCall,
            in: [legacyPriorReport, currentJobAttachment],
            serviceCalls: [previousCall, currentCall]
        )

        #expect(history.map(\.displayName) == ["legacy-prior-report.pdf"])
    }

    @Test func customerEquipmentAttachmentGroupsFilesByLinkedEquipment() async throws {
        let customer = Customer(name: "Equipment File Customer")
        let downstairs = CustomerEquipment(customer: customer, name: "Downstairs AC", modelNumber: "24ABC6")
        let upstairs = CustomerEquipment(customer: customer, name: "Upstairs Furnace", modelNumber: "59TN6")
        let downstairsCall = ServiceCall(
            customerEquipmentID: downstairs.id,
            type: .maintenance,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            customer: customer
        )
        let downstairsOlder = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            customerEquipmentID: downstairs.id,
            kind: .customerDocument,
            displayName: "downstairs-manual.pdf",
            localFilePath: "/tmp/downstairs-manual.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let downstairsNewer = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            customerEquipmentID: downstairs.id,
            kind: .diagnosticPhoto,
            displayName: "downstairs-nameplate.jpg",
            localFilePath: "/tmp/downstairs-nameplate.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let legacyDownstairsJobPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: downstairsCall.id,
            customerEquipmentID: nil,
            kind: .diagnosticPhoto,
            displayName: "legacy-downstairs-photo.jpg",
            localFilePath: "/tmp/legacy-downstairs-photo.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 25)
        )
        let upstairsPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            customerEquipmentID: upstairs.id,
            kind: .diagnosticPhoto,
            displayName: "upstairs-nameplate.jpg",
            localFilePath: "/tmp/upstairs-nameplate.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 30)
        )
        let unlinked = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            kind: .customerDocument,
            displayName: "unlinked.pdf",
            localFilePath: "/tmp/unlinked.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )

        let groups = ServiceDocumentAttachment.groupedEquipmentAttachments(
            equipmentProfiles: [upstairs, downstairs],
            attachments: [downstairsOlder, downstairsNewer, legacyDownstairsJobPhoto, upstairsPhoto, unlinked],
            serviceCalls: [downstairsCall]
        )

        #expect(groups.map { $0.equipment.name } == ["Downstairs AC", "Upstairs Furnace"])
        #expect(groups.first?.attachments.map(\.displayName) == ["legacy-downstairs-photo.jpg", "downstairs-nameplate.jpg", "downstairs-manual.pdf"])
        #expect(groups.last?.attachments.map(\.displayName) == ["upstairs-nameplate.jpg"])
    }

    @Test func customerLevelAttachmentsExcludeEquipmentHistoryFiles() async throws {
        let customer = Customer(name: "Equipment File Customer")
        let equipment = CustomerEquipment(customer: customer, name: "Downstairs AC", modelNumber: "24ABC6")
        let serviceCall = ServiceCall(
            customerEquipmentID: equipment.id,
            type: .maintenance,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            customer: customer
        )
        let directEquipmentPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            customerEquipmentID: equipment.id,
            kind: .diagnosticPhoto,
            displayName: "equipment-nameplate.jpg",
            localFilePath: "/tmp/equipment-nameplate.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048
        )
        let legacyJobPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCall.id,
            customerEquipmentID: nil,
            kind: .diagnosticPhoto,
            displayName: "legacy-job-photo.jpg",
            localFilePath: "/tmp/legacy-job-photo.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048
        )
        let unlinkedCustomerFile = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            customerEquipmentID: nil,
            kind: .customerDocument,
            displayName: "gate-code.pdf",
            localFilePath: "/tmp/gate-code.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )

        let customerLevel = ServiceDocumentAttachment.customerLevelAttachments(
            in: [directEquipmentPhoto, legacyJobPhoto, unlinkedCustomerFile],
            equipmentProfiles: [equipment],
            serviceCalls: [serviceCall]
        )

        #expect(customerLevel.map(\.displayName) == ["gate-code.pdf"])
        #expect(directEquipmentPhoto.isLinkedToEquipment(equipmentProfiles: [equipment], serviceCalls: [serviceCall]))
        #expect(legacyJobPhoto.isLinkedToEquipment(equipmentProfiles: [equipment], serviceCalls: [serviceCall]))
    }

    @Test func deletingEquipmentProfilePreservesFilesAtCustomerLevel() async throws {
        let customer = Customer(name: "Equipment Delete Customer")
        let equipment = CustomerEquipment(customer: customer, name: "Downstairs AC", modelNumber: "24ABC6")
        let serviceCall = ServiceCall(
            customerEquipmentID: equipment.id,
            type: .maintenance,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            customer: customer
        )
        let directEquipmentFile = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            customerEquipmentID: equipment.id,
            kind: .customerDocument,
            displayName: "downstairs-manual.pdf",
            localFilePath: "/tmp/downstairs-manual.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let legacyJobFile = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCall.id,
            customerEquipmentID: nil,
            kind: .diagnosticPhoto,
            displayName: "legacy-job-photo.jpg",
            localFilePath: "/tmp/legacy-job-photo.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048
        )
        let unrelatedEquipment = CustomerEquipment(customer: customer, name: "Upstairs Furnace")
        let unrelatedFile = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            customerEquipmentID: unrelatedEquipment.id,
            kind: .customerDocument,
            displayName: "upstairs-manual.pdf",
            localFilePath: "/tmp/upstairs-manual.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )

        let detachedCount = ServiceDocumentAttachment.detachEquipmentProfileLinks(
            for: equipment,
            from: [directEquipmentFile, legacyJobFile, unrelatedFile],
            serviceCalls: [serviceCall]
        )
        serviceCall.customerEquipmentID = nil
        let customerLevel = ServiceDocumentAttachment.customerLevelAttachments(
            in: [directEquipmentFile, legacyJobFile, unrelatedFile],
            equipmentProfiles: [unrelatedEquipment],
            serviceCalls: [serviceCall]
        )

        #expect(detachedCount == 1)
        #expect(directEquipmentFile.customerEquipmentID == nil)
        #expect(legacyJobFile.customerEquipmentID == nil)
        #expect(unrelatedFile.customerEquipmentID == unrelatedEquipment.id)
        #expect(customerLevel.map(\.displayName).contains("downstairs-manual.pdf"))
        #expect(customerLevel.map(\.displayName).contains("legacy-job-photo.jpg"))
        #expect(customerLevel.map(\.displayName).contains("upstairs-manual.pdf") == false)
    }

    @Test func customerEquipmentAttachmentGroupSummarizesFileTypes() async throws {
        let customer = Customer(name: "Equipment Summary Customer")
        let equipment = CustomerEquipment(customer: customer, name: "Main System")
        let report = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            customerEquipmentID: equipment.id,
            kind: .serviceReport,
            displayName: "report.pdf",
            localFilePath: "/tmp/report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let photo = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            customerEquipmentID: equipment.id,
            kind: .diagnosticPhoto,
            displayName: "photo.jpg",
            localFilePath: "/tmp/photo.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let dataPlate = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            customerEquipmentID: equipment.id,
            kind: .equipmentDataPlatePhoto,
            displayName: "data-plate.jpg",
            localFilePath: "/tmp/data-plate.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 25)
        )
        let invoice = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            customerEquipmentID: equipment.id,
            kind: .invoiceSupport,
            displayName: "invoice.pdf",
            localFilePath: "/tmp/invoice.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 30)
        )
        let manual = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            customerEquipmentID: equipment.id,
            kind: .customerDocument,
            displayName: "manual.pdf",
            localFilePath: "/tmp/manual.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 40)
        )

        let group = EquipmentAttachmentGroup(equipment: equipment, attachments: [report, photo, dataPlate, invoice, manual])

        #expect(group.serviceReportCount == 1)
        #expect(group.dataPlatePhotoCount == 1)
        #expect(group.photoCount == 1)
        #expect(group.billingDocumentCount == 1)
        #expect(group.otherDocumentCount == 1)
        #expect(group.latestAttachmentDate == manual.createdAt)
        #expect(group.summary == "1 report - 1 data plate - 1 photo - 1 billing file - 1 file")
    }

    @Test func equipmentAttachmentsIncludeDirectAndLinkedJobFiles() async throws {
        let customer = Customer(name: "Equipment File Customer")
        let equipment = CustomerEquipment(customer: customer, name: "Main System")
        let otherEquipment = CustomerEquipment(customer: customer, name: "Other System")
        let linkedCall = ServiceCall(
            customerEquipmentID: equipment.id,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        let directFile = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            customerEquipmentID: equipment.id,
            kind: .customerDocument,
            displayName: "manual.pdf",
            localFilePath: "/tmp/manual.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let legacyJobFile = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: linkedCall.id,
            kind: .invoiceSupport,
            displayName: "invoice.pdf",
            localFilePath: "/tmp/invoice.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let unrelatedFile = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            customerEquipmentID: otherEquipment.id,
            kind: .customerDocument,
            displayName: "other-manual.pdf",
            localFilePath: "/tmp/other-manual.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 30)
        )

        let files = ServiceDocumentAttachment.equipmentAttachments(
            for: equipment,
            in: [directFile, unrelatedFile, legacyJobFile],
            serviceCalls: [linkedCall]
        )

        #expect(files.map(\.displayName) == ["invoice.pdf", "manual.pdf"])
        #expect(EquipmentAttachmentGroup(equipment: equipment, attachments: files).summary == "1 billing file - 1 file")
    }

    @Test func onsiteReportLinkedRecordRowsIncludeInvoiceEstimateAndQuickBooksReferences() async throws {
        let customer = Customer(name: "Linked Report Customer")
        let callID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let estimateID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
        let invoiceID = UUID(uuidString: "33333333-4444-5555-6666-777777777777")!
        let call = ServiceCall(
            id: callID,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        call.linkedEstimateID = estimateID
        call.linkedInvoiceID = invoiceID
        let estimate = Estimate(id: estimateID, customer: customer, quickBooksID: "QBO-EST-42", amount: 500, status: "accepted")
        let invoice = Invoice(id: invoiceID, customer: customer, quickBooksID: "QBO-INV-99", amount: 500, status: "paid")

        let rows = CustomerDocumentExporter.linkedRecordRows(serviceCall: call, estimate: estimate, invoice: invoice)
        let caption = CustomerDocumentExporter.onsiteReportAttachmentCaption(serviceCall: call, estimate: estimate, invoice: invoice)

        #expect(rows.contains { $0.label == "Job ID" && $0.value == "11111111" })
        #expect(rows.contains { $0.label == "Estimate ID" && $0.value == "22222222" })
        #expect(rows.contains { $0.label == "Estimate Amount" && $0.value == "$500.00" })
        #expect(rows.contains { $0.label == "QuickBooks Estimate ID" && $0.value == "QBO-EST-42" })
        #expect(rows.contains { $0.label == "Invoice ID" && $0.value == "33333333" })
        #expect(rows.contains { $0.label == "Invoice Total" && $0.value == "$500.00" })
        #expect(rows.contains { $0.label == "Invoice Balance Due" && $0.value == "$0.00" })
        #expect(rows.contains { $0.label == "QuickBooks Invoice ID" && $0.value == "QBO-INV-99" })
        #expect(caption.contains("Generated onsite maintenance report"))
        #expect(caption.contains("QuickBooks Invoice ID: QBO-INV-99"))
        #expect(caption.contains("QuickBooks Estimate ID: QBO-EST-42"))
    }

    @Test func onsiteReportLinkedRecordRowsCanHideFinancialReferences() async throws {
        let customer = Customer(name: "Linked Report Customer")
        let callID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let estimateID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
        let invoiceID = UUID(uuidString: "33333333-4444-5555-6666-777777777777")!
        let call = ServiceCall(
            id: callID,
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        let estimate = Estimate(id: estimateID, customer: customer, quickBooksID: "QBO-EST-42", amount: 500, status: "accepted")
        let invoice = Invoice(id: invoiceID, customer: customer, quickBooksID: "QBO-INV-99", amount: 500, status: "paid")

        let rows = CustomerDocumentExporter.linkedRecordRows(
            serviceCall: call,
            estimate: estimate,
            invoice: invoice,
            includeFinancials: false
        )
        let caption = CustomerDocumentExporter.onsiteReportAttachmentCaption(
            serviceCall: call,
            estimate: estimate,
            invoice: invoice,
            includeFinancials: false
        )

        #expect(rows.contains { $0.label == "Job ID" && $0.value == "11111111" })
        #expect(rows.contains { $0.label == "Estimate ID" && $0.value == "22222222" })
        #expect(rows.contains { $0.label == "Estimate Status" && $0.value == "Accepted" })
        #expect(rows.contains { $0.label == "Invoice ID" && $0.value == "33333333" })
        #expect(rows.contains { $0.label == "Invoice Status" && $0.value == "Paid" })
        #expect(rows.contains { $0.label.contains("Amount") || $0.label.contains("Total") || $0.label.contains("Balance") } == false)
        #expect(rows.contains { $0.label.contains("QuickBooks") } == false)
        #expect(caption.contains("Generated onsite maintenance report"))
        #expect(caption.contains("QuickBooks") == false)
        #expect(caption.contains("$") == false)
    }

    @Test func billingJobContextIncludesEquipmentHistoryAndReadingTrends() async throws {
        let customer = Customer(name: "Billing Equipment Customer")
        let equipment = CustomerEquipment(
            customer: customer,
            equipmentType: .splitSystemAC,
            name: "Downstairs AC",
            modelNumber: "24ABC6",
            serialNumber: "AC-100"
        )
        let pastCall = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC-100",
            customerEquipmentID: equipment.id,
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "Previous cooling maintenance completed.",
            type: .maintenance,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            customer: customer,
            status: .completed
        )
        pastCall.setTechnicalReading("11", for: "superheat")
        pastCall.setTechnicalReading("238", for: "line_voltage")
        let currentCall = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC-100",
            customerEquipmentID: equipment.id,
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: Date(timeIntervalSince1970: 1_800_086_400),
            customer: customer
        )

        let rows = CustomerDocumentExporter.billingJobContextSummaries(
            for: currentCall,
            equipmentProfiles: [equipment],
            serviceCalls: [pastCall, currentCall]
        )

        #expect(rows.contains { $0.label == "Equipment Profile" && $0.value.contains("Downstairs AC") })
        #expect(rows.contains { $0.label == "Service History" && $0.value.contains("1 job") })
        #expect(rows.contains { $0.label == "Previous Service Context" && $0.value.contains("Previous cooling maintenance completed.") })
        #expect(rows.contains { $0.label == "Reading Trends" && $0.value.contains("Superheat") })
        #expect(rows.contains { $0.label == "Reading Trends" && $0.value.contains("Line Voltage") })
    }

    @Test func invoiceDetailRowsUseQuickBooksBalanceWhenAvailable() async throws {
        let customer = Customer(name: "QBO Invoice Customer")
        let invoice = Invoice(
            customer: customer,
            quickBooksID: "QBO-INV-100",
            quickBooksBalanceDue: 125,
            amount: 500,
            status: "unpaid"
        )
        let localPayment = Payment(invoice: invoice, amount: 500, method: "card")

        let rows = CustomerDocumentExporter.invoiceDetailRows(for: invoice, payments: [localPayment])

        #expect(rows.contains { $0.label == "Status" && $0.value == "Partial" })
        #expect(rows.contains { $0.label == "Invoice Total" && $0.value == "$500.00" })
        #expect(rows.contains { $0.label == "Payments" && $0.value == "$500.00" })
        #expect(rows.contains { $0.label == "Balance Due" && $0.value == "$125.00" })
    }

    @Test func estimateDetailRowsIncludeEachCustomerFacingFieldOnce() async throws {
        let customer = Customer(name: "Estimate Detail Customer")
        let estimate = Estimate(
            customer: customer,
            quickBooksID: "QBO-EST-100",
            lineItemSummary: "Replace condenser fan motor",
            amount: 625,
            status: "accepted",
            notes: "Customer approved repair."
        )

        let rows = CustomerDocumentExporter.estimateDetailRows(for: estimate)

        #expect(rows.filter { $0.label == "Items" }.count == 1)
        #expect(rows.contains { $0.label == "Status" && $0.value == "Accepted" })
        #expect(rows.contains { $0.label == "QuickBooks ID" && $0.value == "QBO-EST-100" })
        #expect(rows.contains { $0.label == "Items" && $0.value == "Replace condenser fan motor" })
        #expect(rows.contains { $0.label == "Notes" && $0.value == "Customer approved repair." })
        #expect(rows.contains { $0.label == "Total" && $0.value == "$625.00" })
    }

    @Test func estimateDetailRowsIncludeDocumentationReadinessWhenAvailable() async throws {
        let customer = Customer(name: "Estimate Documentation Customer")
        let estimate = Estimate(customer: customer, amount: 850, status: "pending")
        let documentationStatus = EstimateDocumentationStatus(
            linkedReportCount: 1,
            linkedPhotoEvidenceCount: 2,
            linkedBillingDocumentCount: 1,
            pendingQuickBooksAttachmentCount: 1,
            failedQuickBooksAttachmentCount: 0,
            syncedQuickBooksAttachmentCount: 0,
            requiresQuickBooksAttachmentSync: true
        )

        let rows = CustomerDocumentExporter.estimateDetailRows(
            for: estimate,
            documentationStatus: documentationStatus
        )

        #expect(rows.contains { $0.label == "Documentation Status" && $0.value == "QuickBooks attachments pending" })
        #expect(rows.contains { $0.label == "Documentation Summary" && $0.value.contains("1 onsite report") })
        #expect(rows.contains { $0.label == "Documentation Summary" && $0.value.contains("2 photos") })
        #expect(rows.contains { $0.label == "Documentation Summary" && $0.value.contains("1 pending") })
        #expect(rows.contains { $0.label == "Documentation Action" && $0.value == "Upload 1 estimate attachment to QuickBooks before emailing." })
    }

    @Test func invoiceDetailRowsIncludeDocumentationReadinessWhenAvailable() async throws {
        let customer = Customer(name: "Documentation Invoice Customer")
        let invoice = Invoice(
            customer: customer,
            quickBooksID: "QBO-INV-101",
            amount: 750,
            status: "unpaid"
        )
        let documentationStatus = InvoiceDocumentationStatus(
            linkedReportCount: 1,
            linkedPhotoEvidenceCount: 0,
            linkedBillingDocumentCount: 0,
            pendingQuickBooksAttachmentCount: 1,
            failedQuickBooksAttachmentCount: 0,
            syncedQuickBooksAttachmentCount: 0,
            requiresQuickBooksAttachmentSync: true
        )

        let rows = CustomerDocumentExporter.invoiceDetailRows(
            for: invoice,
            payments: [],
            documentationStatus: documentationStatus
        )

        #expect(rows.contains { $0.label == "Documentation Status" && $0.value == "QuickBooks attachments pending" })
        #expect(rows.contains { $0.label == "Documentation Summary" && $0.value.contains("1 onsite report") })
        #expect(rows.contains { $0.label == "Documentation Summary" && $0.value.contains("1 pending") })
        #expect(rows.contains { $0.label == "Documentation Action" && $0.value == "Upload 1 invoice attachment to QuickBooks before emailing." })
    }

    @Test func billingDocumentsIncludeLinkedOnsiteDocumentationSummary() async throws {
        let customer = Customer(name: "Billing Documentation Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "System operational after diagnostics.",
            type: .service,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            customer: customer,
            findingsSummary: "Compressor capacitor weak.",
            recommendedWorkSummary: "Replace capacitor and wash condenser coil."
        )
        call.setTechnicalReading("76", for: "return_air_temp")
        call.setTechnicalReading("56", for: "supply_air_temp")
        call.setTechnicalReading("12", for: "superheat")
        call.setServiceActionStatus(.needsService, for: "condenser_coil_serviced")
        call.setServiceActionStatus(.completed, for: "electrical_connections_checked")

        let summaries = CustomerDocumentExporter.billingDocumentationSummaries(for: call)
        let hasOnsiteDocumentation = summaries.contains { summary in
            summary.title == "Onsite Documentation" &&
                summary.rows.contains { row in
                    row.label == "Next Required Action" && row.value == "Complete Line Voltage (V)"
                }
        }
        let hasFindingsSummary = summaries.contains { summary in
            summary.title == "Service Summary" &&
                summary.rows.contains { row in
                    row.label == "Findings" && row.value.contains("capacitor weak")
                }
        }
        let hasTechnicalSnapshot = summaries.contains { summary in
            summary.title == "Technical Snapshot" &&
                summary.rows.contains { row in
                    row.label == "Superheat (F)" && row.value == "12"
                }
        }
        let hasServiceActions = summaries.contains { summary in
            summary.title == "Service Actions" &&
                summary.rows.contains { row in
                    row.label == "Condenser coil inspected/washed" && row.value == "Needs Service"
                } &&
                summary.rows.contains { row in
                    row.label == "Electrical connections checked" && row.value == "Completed"
                }
        }
        let hasOpenConcerns = summaries.contains { summary in
            summary.title == "Open Service Concerns" &&
                summary.rows.contains { row in
                    row.label == "Condenser coil inspected/washed" && row.value == "Needs Service"
                } &&
                summary.rows.contains { row in
                    row.label == "Electrical connections checked"
                } == false
        }

        #expect(hasOnsiteDocumentation)
        #expect(hasFindingsSummary)
        #expect(hasTechnicalSnapshot)
        #expect(hasServiceActions)
        #expect(hasOpenConcerns)
    }

    @Test func billingDocumentationSummariesIncludeAllCapturedTechnicalRowsAndActions() async throws {
        let customer = Customer(name: "Complete Billing Report Customer")
        let call = ServiceCall(
            equipmentName: "Packaged RTU",
            equipmentTypeRaw: HVACEquipmentType.packageUnit.rawValue,
            serviceReportSummary: "Full maintenance report captured.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        let readingDefinitions = Array(call.technicalReadingDefinitions.prefix(16))
        for (index, definition) in readingDefinitions.enumerated() {
            call.setTechnicalReading("\(index + 1)", for: definition.key)
        }
        let actionDefinitions = Array(call.serviceActionDefinitions.prefix(14))
        for definition in actionDefinitions {
            call.setServiceActionStatus(.completed, for: definition.key)
        }

        let summaries = CustomerDocumentExporter.billingDocumentationSummaries(for: call)
        let technicalRows = try #require(summaries.first { $0.title == "Technical Snapshot" }?.rows)
        let actionRows = try #require(summaries.first { $0.title == "Service Actions" }?.rows)

        #expect(technicalRows.count >= readingDefinitions.count)
        #expect(actionRows.count >= actionDefinitions.count)
        #expect(technicalRows.contains { $0.label == readingDefinitions.last?.displayLabel })
        #expect(actionRows.contains { $0.label == actionDefinitions.last?.label })
    }

    @Test func billingDocumentationSummariesIncludeRTUEconomizerDiagnostics() async throws {
        let customer = Customer(name: "RTU Economizer Customer")
        let call = ServiceCall(
            equipmentName: "Main Roof RTU",
            equipmentTypeRaw: HVACEquipmentType.packageUnit.rawValue,
            serviceReportSummary: "Economizer operation verified.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer
        )
        call.setTechnicalReading("68", for: "mixed_air_temp")
        call.setTechnicalReading("35", for: "outdoor_air_damper_position")
        call.setTechnicalReading("Normal", for: "economizer_sensor_status")

        let technicalRows = try #require(CustomerDocumentExporter.billingDocumentationSummaries(for: call)
            .first { $0.title == "Technical Snapshot" }?.rows)

        #expect(technicalRows.contains { $0.label == "Mixed Air Temp (F)" && $0.value == "68" })
        #expect(technicalRows.contains { $0.label == "Outdoor Air Damper Position (%)" && $0.value == "35" })
        #expect(technicalRows.contains { $0.label == "Economizer Sensor" && $0.value == "Normal" })
    }

    @Test func onsiteReportEquipmentHistoryRowsIncludePriorContextAndTrends() async throws {
        let customer = Customer(name: "Report Trend Customer")
        let equipment = CustomerEquipment(
            customer: customer,
            equipmentType: .splitSystemAC,
            name: "Downstairs AC",
            serialNumber: "AC-REPORT-TREND"
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let previousCall = ServiceCall(
            equipmentSerialNumber: "AC-REPORT-TREND",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "Previous cooling maintenance completed.",
            type: .maintenance,
            scheduledDate: now.addingTimeInterval(-86_400 * 90),
            customer: customer,
            status: .completed
        )
        previousCall.setTechnicalReading("9", for: "superheat")
        previousCall.setTechnicalReading("7.1", for: "compressor_amps")
        previousCall.setServiceActionStatus(.monitor, for: "condensate_drain_checked")
        let currentCall = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentSerialNumber: "AC-REPORT-TREND",
            customerEquipmentID: equipment.id,
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "Current cooling maintenance completed.",
            type: .maintenance,
            scheduledDate: now,
            customer: customer,
            status: .completed
        )
        currentCall.setTechnicalReading("14", for: "superheat")
        currentCall.setTechnicalReading("8.6", for: "compressor_amps")

        let rows = CustomerDocumentExporter.equipmentHistoryRows(
            serviceCall: currentCall,
            equipmentProfiles: [equipment],
            serviceCalls: [previousCall, currentCall]
        )

        #expect(rows.contains { $0.label == "Equipment Profile" && $0.value.contains("Downstairs AC") })
        #expect(rows.contains { $0.label == "Service History" && $0.value.contains("2 jobs") })
        #expect(rows.contains { $0.label == "Previous Service Context" && $0.value.contains("Previous cooling maintenance") })
        #expect(rows.contains { $0.label == "Previous Service Context" && $0.value.contains("Condensate drain checked/treated: Monitor") })
        #expect(rows.contains { $0.label == "Reading Trends" && $0.value.contains("Superheat: 14") })
        #expect(rows.contains { $0.label == "Reading Trends" && $0.value.contains("Compressor Amps: 8.6") })
    }

    @Test func onsiteReportEquipmentHistoryRowsRequireMatchingEquipmentProfile() async throws {
        let customer = Customer(name: "No Equipment Report Customer")
        let call = ServiceCall(
            equipmentName: "Unprofiled System",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            customer: customer,
            status: .completed
        )

        let rows = CustomerDocumentExporter.equipmentHistoryRows(
            serviceCall: call,
            equipmentProfiles: [],
            serviceCalls: [call]
        )

        #expect(rows.isEmpty)
    }

    @Test func onsiteReportJobRowsIncludeStructuredCustomerContactContext() async throws {
        let customer = Customer(
            name: "Standalone Report Customer",
            phone: "555-0100",
            email: "customer@example.com",
            address: "123 Customer Rd"
        )
        let technician = Technician(name: "Lead Tech")
        let call = ServiceCall(
            siteAddress: "456 Job Site Ave",
            type: .maintenance,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            assignedTechnician: technician,
            customer: customer,
            status: .inProgress
        )

        let rows = CustomerDocumentExporter.onsiteReportJobRows(for: call)

        #expect(rows.contains { $0.label == "Customer" && $0.value == "Standalone Report Customer" })
        #expect(rows.contains { $0.label == "Customer Address" && $0.value == "123 Customer Rd" })
        #expect(rows.contains { $0.label == "Customer Phone" && $0.value == "555-0100" })
        #expect(rows.contains { $0.label == "Customer Email" && $0.value == "customer@example.com" })
        #expect(rows.contains { $0.label == "Site Address" && $0.value == "456 Job Site Ave" })
        #expect(rows.contains { $0.label == "Technician" && $0.value == "Lead Tech" })
    }

    @Test func onsiteReportJobRowsFallBackToCustomerAddressForSiteAddress() async throws {
        let customer = Customer(name: "Fallback Customer", address: "123 Customer Rd")
        let call = ServiceCall(
            siteAddress: nil,
            type: .service,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            customer: customer
        )

        let rows = CustomerDocumentExporter.onsiteReportJobRows(for: call)

        #expect(rows.contains { $0.label == "Site Address" && $0.value == "123 Customer Rd" })
        #expect(rows.contains { $0.label == "Customer Email" } == false)
        #expect(rows.contains { $0.label == "Customer Phone" } == false)
    }

    @Test func customerProfileAttachmentDetailHidesBillingContextForStandardUsers() async throws {
        let customer = Customer(name: "Report Customer")
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "System checked.",
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer,
            status: .completed
        )
        call.setTechnicalReading("72", for: "return_air_temp")
        let invoice = Invoice(customer: customer, quickBooksID: "123", amount: 250, status: "paid")
        let attachment = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoice.id,
            kind: .serviceReport,
            displayName: "onsite-report.pdf",
            localFilePath: "/tmp/onsite-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            quickBooksSyncError: "403"
        )

        let lines = attachment.customerProfileDetailLines(
            serviceCalls: [call],
            invoices: [invoice],
            estimates: [],
            equipmentProfiles: [],
            canViewFinancials: false
        )

        #expect(lines.contains("Job: Maintenance - Completed"))
        #expect(lines.contains { $0.contains("Documentation is not complete") })
        #expect(lines.contains { $0.contains("Supply Air Temp (F)") })
        #expect(lines.contains { $0.contains("Invoice") } == false)
        #expect(lines.contains { $0.contains("QuickBooks") } == false)
        #expect(lines.contains { $0.contains("403") } == false)
    }

    @Test func onsiteReportAttachmentManifestIncludesSupportFilesAndExcludesGeneratedReports() async throws {
        let customer = Customer(name: "Report Customer")
        let serviceCallID = UUID()
        let diagnosticPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            kind: .diagnosticPhoto,
            displayName: "diagnostic.jpg",
            caption: "Burner compartment",
            localFilePath: "/tmp/diagnostic.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048
        )
        let customerDocument = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            kind: .customerDocument,
            displayName: "site-access.pdf",
            caption: "Gate instructions",
            localFilePath: "/tmp/site-access.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 4096
        )
        let generatedReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            kind: .serviceReport,
            displayName: "generated-report.pdf",
            localFilePath: "/tmp/generated-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 8192
        )

        let summaries = CustomerDocumentExporter.attachmentManifestSummaries(
            for: [diagnosticPhoto, customerDocument, generatedReport]
        )

        #expect(summaries.count == 2)
        #expect(summaries.contains { $0.label == "Diagnostic Photo" && $0.detail.contains("Burner compartment") })
        #expect(summaries.contains { $0.label == "Customer Document" && $0.detail.contains("site-access.pdf") })
        #expect(summaries.contains { $0.detail.contains("generated-report.pdf") } == false)
    }

    @Test func onsiteReportAttachmentManifestIncludesLinkedBillingTrace() async throws {
        let customer = Customer(name: "Report Customer")
        let call = ServiceCall(type: .service, scheduledDate: Date(), customer: customer)
        let estimate = Estimate(serviceCallID: call.id, customer: customer, amount: 250, status: "accepted")
        let invoice = Invoice(serviceCallID: call.id, customer: customer, amount: 250, status: "open")
        call.linkedEstimateID = estimate.id
        call.linkedInvoiceID = invoice.id
        let diagnosticPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoice.id,
            estimateID: estimate.id,
            kind: .diagnosticPhoto,
            displayName: "failed-capacitor.jpg",
            caption: "Failed capacitor",
            localFilePath: "/tmp/failed-capacitor.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            quickBooksAttachableID: "QBO-Attach-123"
        )

        let summaries = CustomerDocumentExporter.attachmentManifestSummaries(
            for: [diagnosticPhoto],
            serviceCall: call,
            estimate: estimate,
            invoice: invoice
        )

        let detail = try #require(summaries.first?.detail)
        #expect(detail.contains("Job ID:"))
        #expect(detail.contains("Estimate ID:"))
        #expect(detail.contains("Invoice ID:"))
        #expect(detail.contains("QuickBooks Attachment ID: QBO-Attach-123"))
    }

    @Test func onsiteReportPhotoCaptionIncludesTimestampForFieldEvidence() async throws {
        let customer = Customer(name: "Photo Evidence Customer")
        let photo = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            kind: .diagnosticPhoto,
            displayName: "before-repair.jpg",
            caption: "Before repair",
            localFilePath: "/tmp/before-repair.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let caption = CustomerDocumentExporter.photoAttachmentCaption(for: photo)

        #expect(caption.contains("Diagnostic Photo"))
        #expect(caption.contains("Before repair"))
        #expect(caption.contains("before-repair.jpg"))
        #expect(caption.contains("2027") || caption.contains("Jan"))
    }

    @Test func onsiteReportPhotoEvidenceIncludesJobImagesInStableOrder() async throws {
        let customer = Customer(name: "Report Customer")
        let serviceCallID = UUID()
        let beforePhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            kind: .beforePhoto,
            displayName: "before.jpg",
            caption: "Before repair",
            localFilePath: "/tmp/before.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let diagnosticPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            kind: .diagnosticPhoto,
            displayName: "diagnostic.jpg",
            caption: "Failed capacitor",
            localFilePath: "/tmp/diagnostic.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 1_800_000_100)
        )
        let customerImage = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            kind: .customerDocument,
            displayName: "panel-label.png",
            caption: "Equipment data plate",
            localFilePath: "/tmp/panel-label.png",
            contentType: "image/png",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 1_800_000_200)
        )
        let generatedReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            kind: .serviceReport,
            displayName: "generated-report.pdf",
            localFilePath: "/tmp/generated-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 8192,
            createdAt: Date(timeIntervalSince1970: 1_800_000_300)
        )

        let evidence = CustomerDocumentExporter.photoEvidenceSummaries(
            for: [generatedReport, customerImage, diagnosticPhoto, beforePhoto]
        )

        #expect(evidence.map(\.label) == ["Before Photo", "Diagnostic Photo", "Customer Document"])
        #expect(evidence[0].detail.contains("Before repair"))
        #expect(evidence[1].detail.contains("Failed capacitor"))
        #expect(evidence[2].detail.contains("Equipment data plate"))
        #expect(evidence.contains { $0.detail.contains("generated-report.pdf") } == false)
    }

    @Test func photoEvidenceExcludesCustomerProfilePhotos() async throws {
        let customer = Customer(name: "Profile Photo Evidence Customer")
        let serviceCallID = UUID()
        let profilePhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            kind: .customerProfilePhoto,
            displayName: "customer-profile.jpg",
            caption: "Customer profile",
            localFilePath: "/tmp/customer-profile.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let diagnosticPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            kind: .diagnosticPhoto,
            displayName: "diagnostic.jpg",
            caption: "Job diagnostic",
            localFilePath: "/tmp/diagnostic.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 1_800_000_100)
        )

        let evidence = CustomerDocumentExporter.photoEvidenceSummaries(for: [profilePhoto, diagnosticPhoto])
        let embedded = CustomerDocumentExporter.embeddedPhotoEvidenceAttachments(for: [profilePhoto, diagnosticPhoto])

        #expect(evidence.map(\.label) == ["Diagnostic Photo"])
        #expect(embedded == [diagnosticPhoto])
    }

    @Test func embeddedPhotoEvidenceIncludesEveryCapturedJobImage() async throws {
        let customer = Customer(name: "Complete Photo Customer")
        let serviceCallID = UUID()
        let photos = (0..<15).map { index in
            ServiceDocumentAttachment(
                customer: customer,
                serviceCallID: serviceCallID,
                kind: index.isMultiple(of: 2) ? .beforePhoto : .diagnosticPhoto,
                displayName: String(format: "field-photo-%02d.jpg", index),
                localFilePath: "/tmp/field-photo-\(index).jpg",
                contentType: "image/jpeg",
                fileSizeBytes: 2048,
                createdAt: Date(timeIntervalSince1970: Double(index))
            )
        }
        let generatedReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            kind: .serviceReport,
            displayName: "generated-report.pdf",
            localFilePath: "/tmp/generated-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 8192,
            createdAt: Date(timeIntervalSince1970: 99)
        )

        let embedded = CustomerDocumentExporter.embeddedPhotoEvidenceAttachments(for: photos + [generatedReport])

        #expect(embedded.count == 15)
        #expect(embedded.map(\.displayName).first == "field-photo-00.jpg")
        #expect(embedded.map(\.displayName).last == "field-photo-14.jpg")
        #expect(embedded.contains { $0.kind == .serviceReport } == false)
    }

    @Test func onsiteReportPhotoEvidenceIncludesLinkedBillingTrace() async throws {
        let customer = Customer(name: "Photo Evidence Customer")
        let call = ServiceCall(type: .maintenance, scheduledDate: Date(), customer: customer)
        let invoice = Invoice(serviceCallID: call.id, customer: customer, amount: 400, status: "open")
        let photo = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoice.id,
            kind: .afterPhoto,
            displayName: "after-repair.jpg",
            caption: "After repair",
            localFilePath: "/tmp/after-repair.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let evidence = CustomerDocumentExporter.photoEvidenceSummaries(
            for: [photo],
            serviceCall: call,
            invoice: invoice
        )

        let detail = try #require(evidence.first?.detail)
        #expect(detail.contains("After repair"))
        #expect(detail.contains("Job ID:"))
        #expect(detail.contains("Invoice ID:"))
    }

    @Test func onsiteReportPhotoEvidenceIncludesLinkedEquipmentTrace() async throws {
        let customer = Customer(name: "Equipment Photo Customer")
        let equipment = CustomerEquipment(
            customer: customer,
            equipmentType: .packageUnit,
            name: "Roof RTU 1",
            manufacturer: "Carrier",
            modelNumber: "48TC",
            serialNumber: "RTU-123"
        )
        let call = ServiceCall(
            equipmentName: "Roof RTU 1",
            equipmentSerialNumber: "RTU-123",
            customerEquipmentID: equipment.id,
            equipmentTypeRaw: HVACEquipmentType.packageUnit.rawValue,
            type: .maintenance,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            customer: customer
        )
        let dataPlatePhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            customerEquipmentID: equipment.id,
            kind: .equipmentDataPlatePhoto,
            displayName: "rtu-data-plate.jpg",
            caption: "RTU data plate",
            localFilePath: "/tmp/rtu-data-plate.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 1_800_000_100)
        )

        let evidence = CustomerDocumentExporter.photoEvidenceSummaries(
            for: [dataPlatePhoto],
            serviceCall: call,
            equipmentProfiles: [equipment]
        )
        let detail = try #require(evidence.first?.detail)
        let caption = CustomerDocumentExporter.photoAttachmentCaption(
            for: dataPlatePhoto,
            serviceCall: call,
            equipmentProfiles: [equipment]
        )

        #expect(detail.contains("Equipment: Roof RTU 1"))
        #expect(detail.contains("Serial RTU-123"))
        #expect(caption.contains("Equipment: Roof RTU 1"))
        #expect(caption.contains("Serial RTU-123"))
    }

    @Test func onsiteReportAttachmentManifestIncludesEquipmentTrace() async throws {
        let customer = Customer(name: "Equipment Manifest Customer")
        let equipment = CustomerEquipment(
            customer: customer,
            equipmentType: .splitSystemAC,
            name: "Downstairs AC",
            serialNumber: "AC-123"
        )
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentSerialNumber: "AC-123",
            customerEquipmentID: equipment.id,
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .service,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            customer: customer
        )
        let document = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            customerEquipmentID: equipment.id,
            kind: .customerDocument,
            displayName: "manufacturer-startup-sheet.pdf",
            caption: "Startup sheet",
            localFilePath: "/tmp/manufacturer-startup-sheet.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 4096
        )

        let summaries = CustomerDocumentExporter.attachmentManifestSummaries(
            for: [document],
            serviceCall: call,
            equipmentProfiles: [equipment]
        )
        let detail = try #require(summaries.first?.detail)

        #expect(detail.contains("Equipment: Downstairs AC"))
        #expect(detail.contains("Serial AC-123"))
        #expect(detail.contains("Job ID:"))
    }

    @Test func billingPhotoAttachmentsAreScopedToInvoiceJobAndTarget() async throws {
        let customer = Customer(name: "Billing Photo Customer")
        let call = ServiceCall(type: .maintenance, scheduledDate: Date(), customer: customer)
        let equipmentID = UUID()
        call.customerEquipmentID = equipmentID
        let invoiceID = UUID()
        let otherInvoiceID = UUID()
        let jobBeforePhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            kind: .beforePhoto,
            displayName: "job-before.jpg",
            localFilePath: "/tmp/job-before.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let invoicePhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoiceID,
            kind: .afterPhoto,
            displayName: "invoice-after.jpg",
            localFilePath: "/tmp/invoice-after.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 200)
        )
        let estimateCarriedForwardPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoiceID,
            estimateID: UUID(),
            kind: .diagnosticPhoto,
            displayName: "estimate-carried-forward.jpg",
            localFilePath: "/tmp/estimate-carried-forward.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 250)
        )
        let equipmentDataPlate = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            customerEquipmentID: equipmentID,
            kind: .equipmentDataPlatePhoto,
            displayName: "equipment-data-plate.jpg",
            localFilePath: "/tmp/equipment-data-plate.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 275)
        )
        let unrelatedEquipmentPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            customerEquipmentID: UUID(),
            kind: .equipmentDataPlatePhoto,
            displayName: "wrong-equipment.jpg",
            localFilePath: "/tmp/wrong-equipment.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 280)
        )
        let wrongInvoicePhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: otherInvoiceID,
            kind: .diagnosticPhoto,
            displayName: "wrong-invoice.jpg",
            localFilePath: "/tmp/wrong-invoice.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 300)
        )
        let unrelatedJobPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            kind: .beforePhoto,
            displayName: "unrelated-job.jpg",
            localFilePath: "/tmp/unrelated-job.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 400)
        )

        let selected = CustomerDocumentExporter.billingPhotoAttachments(
            for: [unrelatedJobPhoto, wrongInvoicePhoto, unrelatedEquipmentPhoto, equipmentDataPlate, invoicePhoto, estimateCarriedForwardPhoto, jobBeforePhoto],
            serviceCall: call,
            invoiceID: invoiceID,
            estimateID: nil
        )

        #expect(selected.map(\.displayName) == ["job-before.jpg", "invoice-after.jpg", "estimate-carried-forward.jpg", "equipment-data-plate.jpg"])
    }

    @Test func billingPhotoAttachmentsAreScopedToEstimateJobAndTarget() async throws {
        let customer = Customer(name: "Estimate Photo Customer")
        let call = ServiceCall(type: .estimate, scheduledDate: Date(), customer: customer)
        let equipmentID = UUID()
        call.customerEquipmentID = equipmentID
        let estimateID = UUID()
        let otherEstimateID = UUID()
        let jobPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            kind: .beforePhoto,
            displayName: "estimate-job.jpg",
            localFilePath: "/tmp/estimate-job.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let estimatePhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            estimateID: estimateID,
            kind: .diagnosticPhoto,
            displayName: "estimate-diagnostic.jpg",
            localFilePath: "/tmp/estimate-diagnostic.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 200)
        )
        let equipmentPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            customerEquipmentID: equipmentID,
            kind: .equipmentDataPlatePhoto,
            displayName: "estimate-equipment-data-plate.jpg",
            localFilePath: "/tmp/estimate-equipment-data-plate.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 250)
        )
        let wrongEstimatePhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            estimateID: otherEstimateID,
            kind: .afterPhoto,
            displayName: "wrong-estimate.jpg",
            localFilePath: "/tmp/wrong-estimate.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 300)
        )
        let invoiceLinkedPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: UUID(),
            estimateID: estimateID,
            kind: .afterPhoto,
            displayName: "invoice-linked.jpg",
            localFilePath: "/tmp/invoice-linked.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 400)
        )

        let selected = CustomerDocumentExporter.billingPhotoAttachments(
            for: [invoiceLinkedPhoto, wrongEstimatePhoto, equipmentPhoto, estimatePhoto, jobPhoto],
            serviceCall: call,
            invoiceID: nil,
            estimateID: estimateID
        )

        #expect(selected.map(\.displayName) == ["estimate-job.jpg", "estimate-diagnostic.jpg", "estimate-equipment-data-plate.jpg"])
    }

    @Test func onsiteReportAttachmentsAreScopedToJobAndLinkedBillingRecords() async throws {
        let customer = Customer(name: "Scoped Report Customer")
        let equipmentID = UUID()
        let call = ServiceCall(type: .service, scheduledDate: Date(), customer: customer)
        call.customerEquipmentID = equipmentID
        let estimate = Estimate(serviceCallID: call.id, customer: customer, amount: 500, status: "accepted")
        let invoice = Invoice(serviceCallID: call.id, customer: customer, amount: 500, status: "open")
        call.linkedEstimateID = estimate.id
        call.linkedInvoiceID = invoice.id

        let jobPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            kind: .beforePhoto,
            displayName: "job-before.jpg",
            localFilePath: "/tmp/job-before.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let estimatePhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            estimateID: estimate.id,
            kind: .diagnosticPhoto,
            displayName: "estimate-diagnostic.jpg",
            localFilePath: "/tmp/estimate-diagnostic.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 200)
        )
        let invoicePhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: invoice.id,
            kind: .afterPhoto,
            displayName: "invoice-after.jpg",
            localFilePath: "/tmp/invoice-after.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 300)
        )
        let wrongInvoicePhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            invoiceID: UUID(),
            kind: .afterPhoto,
            displayName: "wrong-invoice.jpg",
            localFilePath: "/tmp/wrong-invoice.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 400)
        )
        let unrelatedJobPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            kind: .diagnosticPhoto,
            displayName: "unrelated-job.jpg",
            localFilePath: "/tmp/unrelated-job.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 500)
        )
        let equipmentDataPlate = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            customerEquipmentID: equipmentID,
            kind: .equipmentDataPlatePhoto,
            displayName: "equipment-data-plate.jpg",
            localFilePath: "/tmp/equipment-data-plate.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 600)
        )
        let equipmentManual = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            customerEquipmentID: equipmentID,
            kind: .customerDocument,
            displayName: "equipment-manual.pdf",
            localFilePath: "/tmp/equipment-manual.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 650)
        )
        let otherEquipmentDataPlate = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            customerEquipmentID: UUID(),
            kind: .equipmentDataPlatePhoto,
            displayName: "other-equipment-data-plate.jpg",
            localFilePath: "/tmp/other-equipment-data-plate.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 700)
        )
        let equipmentProfilePhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            customerEquipmentID: equipmentID,
            kind: .customerProfilePhoto,
            displayName: "profile-only.jpg",
            localFilePath: "/tmp/profile-only.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 800)
        )
        let equipmentReceipt = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            customerEquipmentID: equipmentID,
            kind: .receipt,
            displayName: "equipment-receipt.pdf",
            localFilePath: "/tmp/equipment-receipt.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 900)
        )

        let selected = CustomerDocumentExporter.onsiteReportAttachments(
            for: [equipmentReceipt, equipmentProfilePhoto, otherEquipmentDataPlate, equipmentManual, equipmentDataPlate, unrelatedJobPhoto, wrongInvoicePhoto, invoicePhoto, estimatePhoto, jobPhoto],
            serviceCall: call,
            estimate: estimate,
            invoice: invoice
        )

        #expect(selected.map(\.displayName) == ["equipment-manual.pdf", "equipment-data-plate.jpg", "invoice-after.jpg", "estimate-diagnostic.jpg", "job-before.jpg"])
    }

    @Test func onsiteReportEvidenceExcludesJobScopedFinancialAndProfileFiles() async throws {
        let customer = Customer(name: "Report Evidence Privacy Customer")
        let call = ServiceCall(type: .maintenance, scheduledDate: Date(), customer: customer)
        let operationalPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            kind: .diagnosticPhoto,
            displayName: "diagnostic.jpg",
            localFilePath: "/tmp/diagnostic.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 1024
        )
        let receipt = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            kind: .receipt,
            displayName: "receipt.pdf",
            localFilePath: "/tmp/receipt.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let invoiceSupport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            kind: .invoiceSupport,
            displayName: "invoice.pdf",
            localFilePath: "/tmp/invoice.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let estimateSupport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            kind: .estimateSupport,
            displayName: "estimate.pdf",
            localFilePath: "/tmp/estimate.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )
        let profilePhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            kind: .customerProfilePhoto,
            displayName: "profile.jpg",
            localFilePath: "/tmp/profile.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 1024
        )
        let generatedReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            kind: .serviceReport,
            displayName: "report.pdf",
            localFilePath: "/tmp/report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )

        let selected = CustomerDocumentExporter.reportEvidenceAttachments(
            for: [receipt, invoiceSupport, estimateSupport, profilePhoto, generatedReport, operationalPhoto],
            serviceCall: call
        )

        #expect(selected.map(\.displayName) == ["diagnostic.jpg"])
    }

    @Test func onsiteReportChecklistCountsActualJobPhotoAttachments() async throws {
        let customer = Customer(name: "Photo Count Customer")
        let call = ServiceCall(
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer,
            beforePhotoCount: 0,
            afterPhotoCount: 0
        )
        let beforePhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            kind: .beforePhoto,
            displayName: "before.jpg",
            localFilePath: "/tmp/before.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 512
        )
        let afterPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            kind: .afterPhoto,
            displayName: "after.jpg",
            localFilePath: "/tmp/after.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 512
        )

        let rows = CustomerDocumentExporter.checklistRows(for: call, attachments: [beforePhoto, afterPhoto])

        #expect(rows.contains { $0.label == "Photo Evidence" && $0.value == "Photo evidence complete - 1 before - 1 after" })
        #expect(rows.contains { $0.label == "Before Photos" && $0.value == "1" })
        #expect(rows.contains { $0.label == "After Photos" && $0.value == "1" })
    }

    @Test func onsiteReportChecklistIgnoresOtherJobPhotoAttachments() async throws {
        let customer = Customer(name: "Photo Count Customer")
        let call = ServiceCall(
            type: .maintenance,
            scheduledDate: Date(),
            customer: customer,
            beforePhotoCount: 1,
            afterPhotoCount: 0
        )
        let unrelatedAfterPhoto = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            kind: .afterPhoto,
            displayName: "unrelated-after.jpg",
            localFilePath: "/tmp/unrelated-after.jpg",
            contentType: "image/jpeg",
            fileSizeBytes: 512
        )

        let rows = CustomerDocumentExporter.checklistRows(for: call, attachments: [unrelatedAfterPhoto])

        #expect(rows.contains { $0.label == "Before Photos" && $0.value == "1" })
        #expect(rows.contains { $0.label == "After Photos" && $0.value == "0" })
    }

    @Test func generatedServiceReportAttachmentCanBeReusedForSameJobBillingLink() async throws {
        let customer = Customer(name: "Report Customer")
        let serviceCallID = UUID()
        let invoiceID = UUID()
        let olderReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            invoiceID: invoiceID,
            kind: .serviceReport,
            displayName: "older-report.pdf",
            localFilePath: "/tmp/older-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let latestReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            invoiceID: invoiceID,
            kind: .serviceReport,
            displayName: "latest-report.pdf",
            localFilePath: "/tmp/latest-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 2048,
            quickBooksAttachableID: "123",
            quickBooksSyncError: "Old error",
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let unrelatedReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            invoiceID: invoiceID,
            kind: .serviceReport,
            displayName: "other-job-report.pdf",
            localFilePath: "/tmp/other-job-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 30)
        )

        let reusable = try #require(ServiceDocumentAttachment.reusableGeneratedServiceReport(
            in: [olderReport, latestReport, unrelatedReport],
            serviceCallID: serviceCallID,
            invoiceID: invoiceID,
            estimateID: nil
        ))

        #expect(reusable.id == latestReport.id)

        reusable.replaceGeneratedFile(
            displayName: "regenerated-report.pdf",
            localFilePath: "/tmp/regenerated-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 4096,
            caption: "Generated onsite service report"
        )

        #expect(reusable.displayName == "regenerated-report.pdf")
        #expect(reusable.fileSizeBytes == 4096)
        #expect(reusable.quickBooksAttachableID == nil)
        #expect(reusable.quickBooksSyncError == nil)
    }

    @Test func generatedServiceReportFallsBackToUnlinkedJobReportWhenInvoiceIsCreatedLater() async throws {
        let customer = Customer(name: "Report Customer")
        let serviceCallID = UUID()
        let invoiceID = UUID()
        let unlinkedReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            kind: .serviceReport,
            displayName: "pre-invoice-report.pdf",
            localFilePath: "/tmp/pre-invoice-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let unrelatedUnlinkedReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: UUID(),
            kind: .serviceReport,
            displayName: "other-job-report.pdf",
            localFilePath: "/tmp/other-job-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 20)
        )

        let reusable = try #require(ServiceDocumentAttachment.reusableGeneratedServiceReport(
            in: [unlinkedReport, unrelatedUnlinkedReport],
            serviceCallID: serviceCallID,
            invoiceID: invoiceID,
            estimateID: nil
        ))
        reusable.linkToInvoiceIfNeeded(Invoice(
            id: invoiceID,
            serviceCallID: serviceCallID,
            customer: customer,
            amount: 250,
            status: "unpaid"
        ))

        #expect(reusable.id == unlinkedReport.id)
        #expect(reusable.invoiceID == invoiceID)
    }

    @Test func generatedServiceReportReusesEstimateReportWhenInvoiceIsCreatedLater() async throws {
        let customer = Customer(name: "Converted Report Customer")
        let serviceCallID = UUID()
        let estimateID = UUID()
        let invoiceID = UUID()
        let estimateReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            estimateID: estimateID,
            kind: .serviceReport,
            displayName: "estimate-report.pdf",
            localFilePath: "/tmp/estimate-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            quickBooksAttachableID: "ATTACH-EST",
            quickBooksAttachedEntityKeysRaw: ServiceDocumentAttachment.quickBooksAttachedEntityKey(
                type: QuickBooksAttachableEntityType.estimate.rawValue,
                value: "EST-123"
            ),
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let unlinkedReport = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            kind: .serviceReport,
            displayName: "unlinked-report.pdf",
            localFilePath: "/tmp/unlinked-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 30)
        )
        let invoice = Invoice(
            id: invoiceID,
            serviceCallID: serviceCallID,
            customer: customer,
            quickBooksID: "INV-123",
            amount: 250,
            status: "unpaid"
        )

        let reusable = try #require(ServiceDocumentAttachment.reusableGeneratedServiceReport(
            in: [unlinkedReport, estimateReport],
            serviceCallID: serviceCallID,
            invoiceID: invoiceID,
            estimateID: estimateID
        ))
        reusable.linkToInvoiceIfNeeded(invoice)

        #expect(reusable.id == estimateReport.id)
        #expect(reusable.invoiceID == invoiceID)
        #expect(reusable.estimateID == estimateID)
        #expect(reusable.quickBooksAttachableID == "ATTACH-EST")
        #expect(reusable.quickBooksAttachedEntityKeys == [
            ServiceDocumentAttachment.quickBooksAttachedEntityKey(
                type: QuickBooksAttachableEntityType.estimate.rawValue,
                value: "EST-123"
            )
        ])
        let invoiceReference = try #require(reusable.quickBooksInvoiceReference(for: invoice))
        #expect(reusable.isQuickBooksAttached(to: [invoiceReference]) == false)
    }

    @Test func reusedGeneratedReportRefreshesBillingAndEquipmentContext() async throws {
        let oldCustomer = Customer(name: "Old Customer")
        let currentCustomer = Customer(name: "Current Customer")
        let serviceCallID = UUID()
        let equipmentID = UUID()
        let invoiceID = UUID()
        let estimateID = UUID()
        let reusable = ServiceDocumentAttachment(
            customer: oldCustomer,
            serviceCallID: serviceCallID,
            customerEquipmentID: nil,
            invoiceID: nil,
            estimateID: estimateID,
            kind: .serviceReport,
            displayName: "pre-invoice-report.pdf",
            localFilePath: "/tmp/pre-invoice-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            quickBooksAttachableID: "old-attachable",
            quickBooksSyncError: "Old target"
        )

        reusable.refreshGeneratedDocumentContext(
            customer: currentCustomer,
            serviceCallID: serviceCallID,
            customerEquipmentID: equipmentID,
            invoiceID: invoiceID,
            estimateID: estimateID
        )

        #expect(reusable.customer?.id == currentCustomer.id)
        #expect(reusable.serviceCallID == serviceCallID)
        #expect(reusable.customerEquipmentID == equipmentID)
        #expect(reusable.invoiceID == invoiceID)
        #expect(reusable.estimateID == estimateID)
        #expect(reusable.quickBooksAttachableID == nil)
        #expect(reusable.quickBooksSyncError == nil)
    }

    @Test func reusedGeneratedReportKeepsQuickBooksAttachmentWhenBillingTargetIsUnchanged() async throws {
        let customer = Customer(name: "Current Customer")
        let serviceCallID = UUID()
        let equipmentID = UUID()
        let invoiceID = UUID()
        let reusable = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            customerEquipmentID: equipmentID,
            invoiceID: invoiceID,
            kind: .serviceReport,
            displayName: "report.pdf",
            localFilePath: "/tmp/report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            quickBooksAttachableID: "attachable-123",
            quickBooksSyncError: nil
        )

        reusable.refreshGeneratedDocumentContext(
            customer: customer,
            serviceCallID: serviceCallID,
            customerEquipmentID: equipmentID,
            invoiceID: invoiceID,
            estimateID: nil
        )

        #expect(reusable.quickBooksAttachableID == "attachable-123")
        #expect(reusable.quickBooksSyncError == nil)
    }

    @Test func reusedGeneratedReportPreservesEstimateAttachmentWhenInvoiceTargetIsAdded() async throws {
        let customer = Customer(name: "Current Customer")
        let serviceCallID = UUID()
        let equipmentID = UUID()
        let invoice = Invoice(
            serviceCallID: serviceCallID,
            customer: customer,
            quickBooksID: "INV-REUSE",
            amount: 700
        )
        let estimate = Estimate(
            serviceCallID: serviceCallID,
            customer: customer,
            quickBooksID: "EST-REUSE",
            amount: 700
        )
        let reusable = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            customerEquipmentID: equipmentID,
            estimateID: estimate.id,
            kind: .serviceReport,
            displayName: "report.pdf",
            localFilePath: "/tmp/report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            quickBooksAttachableID: "attachable-estimate"
        )
        let estimateReference = try #require(reusable.quickBooksEstimateReference(for: estimate))
        reusable.markQuickBooksAttached(to: [estimateReference])

        reusable.refreshGeneratedDocumentContext(
            customer: customer,
            serviceCallID: serviceCallID,
            customerEquipmentID: equipmentID,
            invoiceID: invoice.id,
            estimateID: estimate.id
        )

        #expect(reusable.quickBooksAttachableID == "attachable-estimate")
        #expect(reusable.isQuickBooksAttached(to: [estimateReference]))
        let missingReferences = QuickBooksInvoiceAttachmentSync.missingQuickBooksAttachableReferences(
            for: reusable,
            estimates: [estimate],
            invoices: [invoice]
        )
        #expect(missingReferences.map(\.EntityRef.value) == ["INV-REUSE"])
    }

    @Test func generatedBillingDocumentAttachmentCanBeReusedForSameBillingLink() async throws {
        let customer = Customer(name: "Billing Customer")
        let serviceCallID = UUID()
        let estimateID = UUID()
        let invoiceID = UUID()
        let olderEstimate = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            estimateID: estimateID,
            kind: .estimateSupport,
            displayName: "older-estimate.pdf",
            localFilePath: "/tmp/older-estimate.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let latestEstimate = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            estimateID: estimateID,
            kind: .estimateSupport,
            displayName: "latest-estimate.pdf",
            localFilePath: "/tmp/latest-estimate.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let invoiceDocument = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: serviceCallID,
            invoiceID: invoiceID,
            kind: .invoiceSupport,
            displayName: "invoice.pdf",
            localFilePath: "/tmp/invoice.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 2048,
            createdAt: Date(timeIntervalSince1970: 30)
        )

        let reusableEstimate = try #require(ServiceDocumentAttachment.reusableGeneratedBillingDocument(
            in: [olderEstimate, latestEstimate, invoiceDocument],
            kind: .estimateSupport,
            serviceCallID: serviceCallID,
            invoiceID: nil,
            estimateID: estimateID
        ))
        let reusableInvoice = try #require(ServiceDocumentAttachment.reusableGeneratedBillingDocument(
            in: [olderEstimate, latestEstimate, invoiceDocument],
            kind: .invoiceSupport,
            serviceCallID: serviceCallID,
            invoiceID: invoiceID,
            estimateID: nil
        ))

        #expect(reusableEstimate.id == latestEstimate.id)
        #expect(reusableInvoice.id == invoiceDocument.id)
        #expect(ServiceDocumentAttachment.reusableGeneratedBillingDocument(
            in: [olderEstimate, latestEstimate, invoiceDocument],
            kind: .invoiceSupport,
            serviceCallID: serviceCallID,
            invoiceID: nil,
            estimateID: estimateID
        ) == nil)
    }

    @Test func quickBooksUploadMetadataCanReferenceInvoiceForSend() async throws {
        let metadata = QuickBooksUploadMetadata(
            FileName: "onsite-report.pdf",
            ContentType: "application/pdf",
            Note: "Generated onsite service report",
            AttachableRef: [
                QuickBooksAttachableReference(
                    EntityRef: QuickBooksAttachableEntityRef(type: QuickBooksAttachableEntityType.invoice.rawValue, value: "123"),
                    IncludeOnSend: true
                )
            ]
        )

        let data = try JSONEncoder().encode(metadata)
        let payload = String(data: data, encoding: .utf8) ?? ""

        #expect(payload.contains("\"FileName\":\"onsite-report.pdf\""))
        #expect(payload.contains("\"type\":\"Invoice\""))
        #expect(payload.contains("\"value\":\"123\""))
        #expect(payload.contains("\"IncludeOnSend\":true"))
    }

    @Test func quickBooksUploadMetadataCanReferenceEstimateAndInvoiceTogether() async throws {
        let metadata = QuickBooksUploadMetadata(
            FileName: "onsite-report.pdf",
            ContentType: "application/pdf",
            Note: "Generated onsite service report",
            AttachableRef: [
                QuickBooksAttachableReference(
                    EntityRef: QuickBooksAttachableEntityRef(type: QuickBooksAttachableEntityType.invoice.rawValue, value: "INV-123"),
                    IncludeOnSend: true
                ),
                QuickBooksAttachableReference(
                    EntityRef: QuickBooksAttachableEntityRef(type: QuickBooksAttachableEntityType.estimate.rawValue, value: "EST-123"),
                    IncludeOnSend: true
                )
            ]
        )

        let data = try JSONEncoder().encode(metadata)
        let payload = String(data: data, encoding: .utf8) ?? ""

        #expect(payload.contains("\"type\":\"Invoice\""))
        #expect(payload.contains("\"value\":\"INV-123\""))
        #expect(payload.contains("\"type\":\"Estimate\""))
        #expect(payload.contains("\"value\":\"EST-123\""))
    }

    @Test func quickBooksFaultDecoderHandlesLowercaseAuthorizationFaults() async throws {
        let data = Data(
            #"{"fault":{"error":[{"message":"message=ApplicationAuthorizationFailed; errorCode=003100; statusCode=403","detail":null,"code":"3100","element":null}],"type":"SERVICE"}}"#.utf8
        )

        let envelope = try JSONDecoder().decode(QuickBooksFaultEnvelope.self, from: data)

        #expect(envelope.Fault.Error.first?.code == "3100")
        #expect(envelope.Fault.Error.first?.Message.contains("ApplicationAuthorizationFailed") == true)
    }

    @Test func quickBooksAuthorizationFailureIsReconnectAction() async throws {
        let error = QuickBooksDataAPI.QBError.authorizationFailed(
            statusCode: 403,
            detail: "QuickBooks rejected this app session."
        )

        #expect(error.requiresReconnect == true)
        #expect(error.localizedDescription.contains("Reconnect QuickBooks") == true)
    }

    @MainActor
    @Test func appSchemaIncludesVendorForQuickBooksSync() async throws {
        let schema = GunnAireModelSchema.schema
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)]
        )
        let context = ModelContext(container)
        let vendor = Vendor(quickBooksID: "QB-VENDOR-1", name: "HVAC Supply")

        context.insert(vendor)
        try context.save()

        let vendors = try context.fetch(FetchDescriptor<Vendor>())
        #expect(vendors.count == 1)
        #expect(vendors.first?.quickBooksID == "QB-VENDOR-1")
    }

    @MainActor
    @Test func quickBooksLocalSyncLinksImportedInvoiceToMatchingServiceCall() async throws {
        let schema = GunnAireModelSchema.schema
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)]
        )
        let context = ModelContext(container)
        let customer = Customer(quickBooksID: "QB-CUST-1", name: "Linked QBO Customer")
        let scheduled = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 13, hour: 10)))
        let call = ServiceCall(
            type: .service,
            scheduledDate: scheduled,
            customer: customer
        )
        let estimate = Estimate(
            serviceCallID: call.id,
            customer: customer,
            amount: 500,
            status: "accepted",
            createdAt: scheduled
        )
        call.linkedEstimateID = estimate.id
        context.insert(customer)
        context.insert(call)
        context.insert(estimate)
        try context.save()

        let quickBooksCustomer = QuickBooksCustomer(
            Id: "QB-CUST-1",
            DisplayName: "Linked QBO Customer",
            PrimaryPhone: nil,
            PrimaryEmailAddr: nil,
            BillAddr: nil
        )
        let quickBooksInvoice = try JSONDecoder().decode(QuickBooksInvoice.self, from: Data("""
        {
          "Id": "QB-INV-1",
          "DocNumber": "1042",
          "CustomerRef": { "value": "QB-CUST-1", "name": "Linked QBO Customer" },
          "TotalAmt": 500,
          "Balance": 0,
          "TxnDate": "2026-08-13"
        }
        """.utf8))

        try QuickBooksLocalSync.importSnapshot(
            customers: [quickBooksCustomer],
            items: [],
            estimates: [],
            invoices: [quickBooksInvoice],
            payments: [],
            vendors: [],
            into: context
        )

        let invoices = try context.fetch(FetchDescriptor<Invoice>())
        let importedInvoice = try #require(invoices.first { $0.quickBooksID == "QB-INV-1" })

        #expect(importedInvoice.serviceCallID == call.id)
        #expect(call.linkedInvoiceID == importedInvoice.id)
        #expect(call.status == .invoiced)
        #expect(importedInvoice.quickBooksBalanceDue == 0)
        #expect(importedInvoice.status == "paid")
    }

    @MainActor
    @Test func quickBooksLocalSyncReconcilesInvoiceStatusFromImportedPaymentOnlySnapshot() async throws {
        let schema = GunnAireModelSchema.schema
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)]
        )
        let context = ModelContext(container)
        let customer = Customer(quickBooksID: "QB-CUST-PAY-1", name: "Payment Customer")
        let invoice = Invoice(
            customer: customer,
            quickBooksID: "QB-INV-PAY-1",
            lineItemSummary: "Synced invoice",
            amount: 500,
            status: "unpaid"
        )
        context.insert(customer)
        context.insert(invoice)
        try context.save()

        let quickBooksPayment = try JSONDecoder().decode(QuickBooksPayment.self, from: Data("""
        {
          "Id": "QB-PAY-1",
          "CustomerRef": { "value": "QB-CUST-PAY-1", "name": "Payment Customer" },
          "TotalAmt": 500,
          "TxnDate": "2026-08-13",
          "PaymentRefNum": "AUTH-1",
          "Line": [
            {
              "Amount": 500,
              "LinkedTxn": [
                { "TxnId": "QB-INV-PAY-1", "TxnType": "Invoice" }
              ]
            }
          ],
          "PaymentMethodRef": { "value": "1", "name": "Credit Card" }
        }
        """.utf8))

        try QuickBooksLocalSync.importSnapshot(
            customers: [],
            items: [],
            estimates: [],
            invoices: [],
            payments: [quickBooksPayment],
            vendors: [],
            into: context
        )

        let payments = try context.fetch(FetchDescriptor<Payment>())
        let importedPayment = try #require(payments.first { $0.quickBooksID == "QB-PAY-1" })

        #expect(importedPayment.invoice.id == invoice.id)
        #expect(importedPayment.method == "card")
        #expect(invoice.status == "paid")
        #expect(Invoice.resolvedStatus(for: invoice, payments: payments) == "paid")
    }

    @MainActor
    @Test func quickBooksLocalSyncReconcilesStaleQuickBooksBalanceFromPaymentOnlySnapshot() async throws {
        let schema = GunnAireModelSchema.schema
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)]
        )
        let context = ModelContext(container)
        let customer = Customer(quickBooksID: "QB-CUST-PAY-2", name: "Stale Balance Customer")
        let invoice = Invoice(
            customer: customer,
            quickBooksID: "QB-INV-PAY-2",
            quickBooksBalanceDue: 500,
            lineItemSummary: "Synced invoice with stale balance",
            amount: 500,
            status: "unpaid"
        )
        context.insert(customer)
        context.insert(invoice)
        try context.save()

        let quickBooksPayment = try JSONDecoder().decode(QuickBooksPayment.self, from: Data("""
        {
          "Id": "QB-PAY-2",
          "CustomerRef": { "value": "QB-CUST-PAY-2", "name": "Stale Balance Customer" },
          "TotalAmt": 500,
          "TxnDate": "2026-08-13",
          "PaymentRefNum": "AUTH-2",
          "Line": [
            {
              "Amount": 500,
              "LinkedTxn": [
                { "TxnId": "QB-INV-PAY-2", "TxnType": "Invoice" }
              ]
            }
          ],
          "PaymentMethodRef": { "value": "1", "name": "Credit Card" }
        }
        """.utf8))

        try QuickBooksLocalSync.importSnapshot(
            customers: [],
            items: [],
            estimates: [],
            invoices: [],
            payments: [quickBooksPayment],
            vendors: [],
            into: context
        )

        let payments = try context.fetch(FetchDescriptor<Payment>())

        #expect(invoice.quickBooksBalanceDue == 0)
        #expect(invoice.status == "paid")
        #expect(Invoice.outstandingBalance(for: invoice, payments: payments) == 0)
    }

    @MainActor
    @Test func quickBooksLocalSyncLinksImportedEstimateToMatchingServiceCall() async throws {
        let schema = GunnAireModelSchema.schema
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)]
        )
        let context = ModelContext(container)
        let customer = Customer(quickBooksID: "QB-CUST-EST-1", name: "Estimate Linked Customer")
        let scheduled = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 14, hour: 9)))
        let call = ServiceCall(
            type: .estimate,
            scheduledDate: scheduled,
            customer: customer
        )
        context.insert(customer)
        context.insert(call)
        try context.save()

        let quickBooksCustomer = QuickBooksCustomer(
            Id: "QB-CUST-EST-1",
            DisplayName: "Estimate Linked Customer",
            PrimaryPhone: nil,
            PrimaryEmailAddr: nil,
            BillAddr: nil
        )
        let quickBooksEstimate = try JSONDecoder().decode(QuickBooksEstimate.self, from: Data("""
        {
          "Id": "QB-EST-LINK-1",
          "DocNumber": "2042",
          "CustomerRef": { "value": "QB-CUST-EST-1", "name": "Estimate Linked Customer" },
          "TotalAmt": 875,
          "TxnDate": "2026-08-14",
          "BillEmail": { "Address": "customer@example.com" },
          "EmailStatus": "NotSet"
        }
        """.utf8))

        try QuickBooksLocalSync.importSnapshot(
            customers: [quickBooksCustomer],
            items: [],
            estimates: [quickBooksEstimate],
            invoices: [],
            payments: [],
            vendors: [],
            into: context
        )

        let estimates = try context.fetch(FetchDescriptor<Estimate>())
        let importedEstimate = try #require(estimates.first { $0.quickBooksID == "QB-EST-LINK-1" })

        #expect(importedEstimate.serviceCallID == call.id)
        #expect(call.linkedEstimateID == importedEstimate.id)
        #expect(importedEstimate.amount == 875)
    }

    @MainActor
    @Test func quickBooksLocalSyncDoesNotLinkImportedEstimateWhenServiceCallMatchIsAmbiguous() async throws {
        let schema = GunnAireModelSchema.schema
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)]
        )
        let context = ModelContext(container)
        let customer = Customer(quickBooksID: "QB-CUST-EST-2", name: "Ambiguous Estimate Customer")
        let scheduled = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 15, hour: 9)))
        let firstCall = ServiceCall(type: .estimate, scheduledDate: scheduled, customer: customer)
        let secondCall = ServiceCall(type: .service, scheduledDate: scheduled, customer: customer)
        context.insert(customer)
        context.insert(firstCall)
        context.insert(secondCall)
        try context.save()

        let quickBooksCustomer = QuickBooksCustomer(
            Id: "QB-CUST-EST-2",
            DisplayName: "Ambiguous Estimate Customer",
            PrimaryPhone: nil,
            PrimaryEmailAddr: nil,
            BillAddr: nil
        )
        let quickBooksEstimate = try JSONDecoder().decode(QuickBooksEstimate.self, from: Data("""
        {
          "Id": "QB-EST-AMBIGUOUS-1",
          "DocNumber": "2043",
          "CustomerRef": { "value": "QB-CUST-EST-2", "name": "Ambiguous Estimate Customer" },
          "TotalAmt": 925,
          "TxnDate": "2026-08-15",
          "BillEmail": null,
          "EmailStatus": "NotSet"
        }
        """.utf8))

        try QuickBooksLocalSync.importSnapshot(
            customers: [quickBooksCustomer],
            items: [],
            estimates: [quickBooksEstimate],
            invoices: [],
            payments: [],
            vendors: [],
            into: context
        )

        let estimates = try context.fetch(FetchDescriptor<Estimate>())
        let importedEstimate = try #require(estimates.first { $0.quickBooksID == "QB-EST-AMBIGUOUS-1" })

        #expect(importedEstimate.serviceCallID == nil)
        #expect(firstCall.linkedEstimateID == nil)
        #expect(secondCall.linkedEstimateID == nil)
    }

    @MainActor
    @Test func quickBooksLocalSyncRepairsExistingBillingDocumentLinksAndReportTargets() async throws {
        let schema = GunnAireModelSchema.schema
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)]
        )
        let context = ModelContext(container)
        let customer = Customer(quickBooksID: "QB-CUST-REPAIR-1", name: "Repair Linked Customer")
        let scheduled = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 16, hour: 9)))
        let call = ServiceCall(
            type: .service,
            scheduledDate: scheduled,
            customer: customer
        )
        let estimate = Estimate(
            customer: customer,
            quickBooksID: "QB-EST-REPAIR-1",
            amount: 450,
            status: "accepted"
        )
        let invoice = Invoice(
            serviceCallID: call.id,
            customer: customer,
            quickBooksID: "QB-INV-REPAIR-1",
            amount: 450,
            status: "paid"
        )
        let report = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: call.id,
            kind: .serviceReport,
            displayName: "service-report.pdf",
            localFilePath: "/tmp/service-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 12
        )
        call.linkedEstimateID = estimate.id
        context.insert(customer)
        context.insert(call)
        context.insert(estimate)
        context.insert(invoice)
        context.insert(report)
        try context.save()

        try QuickBooksLocalSync.importSnapshot(
            customers: [],
            items: [],
            estimates: [],
            invoices: [],
            payments: [],
            vendors: [],
            into: context
        )

        #expect(estimate.serviceCallID == call.id)
        #expect(call.linkedInvoiceID == invoice.id)
        #expect(invoice.serviceCallID == call.id)
        #expect(call.status == .invoiced)
        #expect(report.estimateID == estimate.id)
        #expect(report.invoiceID == invoice.id)
    }

    @Test func technicianCalendarAssessmentDetectsWritableCalendar() async throws {
        let calendars = [
            GoogleCalendar(id: "tech@example.com", summary: "Tech Schedule", timeZone: "America/New_York", accessRole: "writer")
        ]

        let assessment = TechnicianCalendarAccessAssessment.evaluate(
            calendarID: "TECH@example.com ",
            availableCalendars: calendars
        )

        #expect(assessment.state == .writable)
        #expect(assessment.calendarLabel.contains("Tech Schedule"))
    }

    @Test func technicianCalendarAssessmentDetectsReadOnlyCalendar() async throws {
        let calendars = [
            GoogleCalendar(id: "tech@example.com", summary: "Tech Schedule", timeZone: "America/New_York", accessRole: "reader")
        ]

        let assessment = TechnicianCalendarAccessAssessment.evaluate(
            calendarID: "tech@example.com",
            availableCalendars: calendars
        )

        #expect(assessment.state == .readOnly)
        #expect(assessment.detail.contains("cannot write"))
    }

    @Test func technicianCalendarAssessmentUsesPrimaryAsWritableFallback() async throws {
        let assessment = TechnicianCalendarAccessAssessment.evaluate(
            calendarID: "primary",
            availableCalendars: []
        )

        #expect(assessment.state == .writable)
        #expect(assessment.calendarLabel == "Primary Calendar")
    }

    @Test func serviceCalendarRoutingOnlyOffersWritableCalendars() async throws {
        let calendars = [
            GoogleCalendar(id: "writer@example.com", summary: "Writer", timeZone: nil, accessRole: "writer"),
            GoogleCalendar(id: "reader@example.com", summary: "Reader", timeZone: nil, accessRole: "reader")
        ]

        let options = ServiceCalendarRouting.routeOptions(from: calendars)

        #expect(options.contains(ServiceCalendarRouteOption(id: "primary", label: "Primary Calendar")))
        #expect(options.contains(where: { $0.id == "writer@example.com" }))
        #expect(options.contains(where: { $0.id == "reader@example.com" }) == false)
    }

    @Test func serviceCalendarRoutingSanitizesReadOnlySelection() async throws {
        let technician = Technician(name: "Tech", contactInfo: "reader@example.com")
        let calendars = [
            GoogleCalendar(id: "reader@example.com", summary: "Reader", timeZone: nil, accessRole: "reader")
        ]

        let selected = ServiceCalendarRouting.validSelection(
            "reader@example.com",
            technician: technician,
            calendars: calendars
        )

        #expect(selected == "primary")
    }

    @Test func serviceCalendarRoutingUsesTechnicianAssignmentTarget() async throws {
        let technician = Technician(name: "Tech", contactInfo: " Tech.Calendar@example.com ")

        let selected = ServiceCalendarRouting.assignedCalendarID(for: technician)

        #expect(selected == "tech.calendar@example.com")
        #expect(ServiceCalendarRouting.assignedCalendarID(for: nil) == "primary")
    }

    @Test func serviceCalendarRoutingDetectsStaleAssignedRoute() async throws {
        let technician = Technician(name: "Tech", contactInfo: "tech.calendar@example.com")

        #expect(ServiceCalendarRouting.hasStaleAssignedCalendarRoute(calendarID: nil, technician: technician))
        #expect(ServiceCalendarRouting.hasStaleAssignedCalendarRoute(calendarID: "old@example.com", technician: technician))
        #expect(ServiceCalendarRouting.hasStaleAssignedCalendarRoute(calendarID: " TECH.CALENDAR@example.com ", technician: technician) == false)
        #expect(ServiceCalendarRouting.hasStaleAssignedCalendarRoute(calendarID: nil, technician: nil) == false)
    }

    @MainActor
    @Test func googleCalendarExportPrefersAssignedTechnicianCalendar() async throws {
        let customer = Customer(name: "Route Customer")
        let technician = Technician(name: "Route Tech", contactInfo: "route.tech@example.com")
        let call = ServiceCall(
            googleCalendarID: "previous.tech@example.com",
            googleEventID: "event-123",
            type: .service,
            scheduledDate: Date(),
            assignedTechnician: technician,
            customer: customer
        )

        let selected = GoogleCalendarScheduleSync.preferredCalendarID(
            for: call,
            availableCalendarIDs: ["previous.tech@example.com", "route.tech@example.com", "primary"],
            writableCalendarIDs: ["previous.tech@example.com", "route.tech@example.com", "primary"]
        )

        #expect(selected == "route.tech@example.com")
    }

    @MainActor
    @Test func googleCalendarExistingEventPatchDoesNotOverwriteExternalDetails() async throws {
        let customer = Customer(name: "Calendar Customer", email: "customer@example.com", address: "123 Local Address")
        let call = ServiceCall(
            googleCalendarID: "primary",
            googleEventID: "event-123",
            googleEventManagedByApp: true,
            eventTitle: "App Title",
            siteAddress: "456 App Address",
            type: .service,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            duration: 3600,
            customer: customer,
            notes: "App notes"
        )

        let patch = GoogleCalendarScheduleSync.makeScheduleOnlyPatch(for: call)
        let encoded = try JSONEncoder().encode(patch)
        let payload = String(data: encoded, encoding: .utf8) ?? ""
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(payload.contains("\"start\""))
        #expect(payload.contains("\"end\""))
        #expect(payload.contains("summary") == false)
        #expect(payload.contains("description") == false)
        #expect(payload.contains("location") == false)
        #expect(payload.contains("attendees") == false)
        #expect(Set(object.keys) == ["start", "end"])
    }

    @MainActor
    @Test func googleCalendarImportedEventsAreReadOnlyForExternalWrites() async throws {
        let customer = Customer(name: "Calendar Customer")
        let importedCall = ServiceCall(
            googleCalendarID: "primary",
            googleEventID: "google-owned-event",
            googleEventManagedByApp: false,
            type: .service,
            scheduledDate: Date(),
            customer: customer
        )
        let appOwnedCall = ServiceCall(
            googleCalendarID: "primary",
            googleEventID: "app-owned-event",
            googleEventManagedByApp: true,
            type: .service,
            scheduledDate: Date(),
            customer: customer
        )
        let newAppCall = ServiceCall(
            googleCalendarID: "primary",
            googleEventManagedByApp: true,
            type: .service,
            scheduledDate: Date(),
            customer: customer
        )

        #expect(GoogleCalendarScheduleSync.shouldAllowGoogleCalendarWrite(for: importedCall) == false)
        #expect(GoogleCalendarScheduleSync.shouldAllowGoogleCalendarWrite(for: appOwnedCall) == true)
        #expect(GoogleCalendarScheduleSync.shouldAllowGoogleCalendarWrite(for: newAppCall) == true)
    }

    @MainActor
    @Test func googleCalendarImportedEventsDoNotPublishAfterLocalEdits() async throws {
        let customer = Customer(name: "Calendar Customer")
        let importedCall = ServiceCall(
            googleCalendarID: "primary",
            googleEventID: "google-owned-event",
            googleEventManagedByApp: false,
            eventTitle: "Imported title",
            siteAddress: "Imported address",
            type: .service,
            scheduledDate: Date(),
            customer: customer,
            notes: "Imported details"
        )
        let appOwnedCall = ServiceCall(
            googleCalendarID: "primary",
            googleEventID: "app-owned-event",
            googleEventManagedByApp: true,
            eventTitle: "App title",
            siteAddress: "App address",
            type: .service,
            scheduledDate: Date(),
            customer: customer,
            notes: "App details"
        )
        let newAppCall = ServiceCall(
            googleCalendarID: "primary",
            googleEventManagedByApp: true,
            eventTitle: "New app event",
            siteAddress: "New address",
            type: .service,
            scheduledDate: Date(),
            customer: customer,
            notes: "New details"
        )

        #expect(GoogleCalendarScheduleSync.shouldPublishAfterLocalSave(for: importedCall) == false)
        #expect(GoogleCalendarScheduleSync.shouldPublishAfterLocalSave(for: appOwnedCall) == true)
        #expect(GoogleCalendarScheduleSync.shouldPublishAfterLocalSave(for: newAppCall) == true)
        #expect(GoogleCalendarScheduleSync.shouldCreateGoogleCalendarEvent(for: importedCall) == false)
        #expect(GoogleCalendarScheduleSync.shouldCreateGoogleCalendarEvent(for: appOwnedCall) == false)
        #expect(GoogleCalendarScheduleSync.shouldCreateGoogleCalendarEvent(for: newAppCall) == true)
    }

    @Test func googleCalendarImportDoesNotBlankExistingManagedDetails() async throws {
        #expect(GoogleCalendarScheduleSync.mergedImportedCalendarText(
            remoteValue: nil,
            existingValue: "Existing Google details",
            isManagedByApp: true
        ) == "Existing Google details")
        #expect(GoogleCalendarScheduleSync.mergedImportedCalendarText(
            remoteValue: "   ",
            existingValue: "Existing Google location",
            isManagedByApp: true
        ) == "Existing Google location")
        #expect(GoogleCalendarScheduleSync.mergedImportedCalendarText(
            remoteValue: "Updated Google title",
            existingValue: "Existing Google title",
            isManagedByApp: true
        ) == "Updated Google title")
    }

    @MainActor
    @Test func googleCalendarSyncDoesNotPublishUnlinkedLocalJobsByDefault() async throws {
        let customer = Customer(name: "Calendar Customer")
        let localCall = ServiceCall(
            googleCalendarID: "primary",
            eventTitle: "Local service call",
            siteAddress: "123 App Address",
            type: .service,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            customer: customer,
            notes: "Local app notes"
        )

        #expect(GoogleCalendarScheduleSync.shouldCreateGoogleCalendarEvent(for: localCall) == false)
        #expect(GoogleCalendarScheduleSync.shouldExportDuringCalendarSync(localCall) == false)
    }

    @MainActor
    @Test func googleCalendarSyncNeverPublishesLocalCalendarEdits() async throws {
        let customer = Customer(name: "Calendar Customer")
        let localCall = ServiceCall(
            googleCalendarID: "primary",
            eventTitle: "Local service call",
            siteAddress: "123 App Address",
            type: .service,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            customer: customer,
            notes: "Local app notes"
        )

        GoogleCalendarScheduleSync.markCalendarCallLocallyEdited(localCall)

        #expect(GoogleCalendarScheduleSync.shouldExportDuringCalendarSync(localCall) == false)
        #expect(GoogleCalendarScheduleSync.shouldCreateGoogleCalendarEvent(for: localCall) == false)
    }

    @MainActor
    @Test func googleCalendarExternalEventsRemainReadOnlyAfterLocalFieldChanges() async throws {
        let customer = Customer(name: "Calendar Customer")
        let importedCall = ServiceCall(
            googleCalendarID: "primary",
            googleEventID: "google-owned-event",
            googleEventManagedByApp: false,
            eventTitle: "Edited local title",
            siteAddress: "",
            type: .service,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            duration: 3600,
            customer: customer,
            notes: ""
        )

        #expect(GoogleCalendarScheduleSync.isExternalGoogleCalendarEvent(importedCall) == true)
        #expect(GoogleCalendarScheduleSync.shouldAllowGoogleCalendarWrite(for: importedCall) == false)
        #expect(GoogleCalendarScheduleSync.shouldPublishAfterLocalSave(for: importedCall) == false)
        #expect(GoogleCalendarScheduleSync.shouldPreserveExternalGoogleCalendarDetails(for: importedCall) == true)
    }

    @Test func googleCalendarDeletedExternalEventsAreRememberedLocally() async throws {
        let calendarID = "shared-calendar@example.com"
        let eventID = "externally-owned-event-\(UUID().uuidString)"

        #expect(GoogleCalendarScheduleSync.isCalendarEventDeleted(calendarID: calendarID, eventID: eventID) == false)

        GoogleCalendarScheduleSync.markCalendarEventDeleted(calendarID: calendarID, eventID: eventID)

        #expect(GoogleCalendarScheduleSync.isCalendarEventDeleted(calendarID: calendarID, eventID: eventID))
    }

    @MainActor
    @Test func googleCalendarAppOwnedEventsPublishScheduleOnlyUpdatesAfterGoogleCreation() async throws {
        let customer = Customer(name: "Calendar Customer")
        let appOwnedCall = ServiceCall(
            googleCalendarID: "primary",
            googleEventID: "app-owned-event",
            googleEventManagedByApp: true,
            eventTitle: "App title",
            siteAddress: "App address",
            type: .service,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            duration: 3600,
            customer: customer,
            notes: "App details"
        )

        #expect(GoogleCalendarScheduleSync.isExternalGoogleCalendarEvent(appOwnedCall))
        #expect(GoogleCalendarScheduleSync.shouldAllowGoogleCalendarWrite(for: appOwnedCall) == true)
        #expect(GoogleCalendarScheduleSync.shouldPublishAfterLocalSave(for: appOwnedCall) == true)
        #expect(GoogleCalendarScheduleSync.shouldPreserveExternalGoogleCalendarDetails(for: appOwnedCall))
        #expect(GoogleCalendarScheduleSync.shouldCreateGoogleCalendarEvent(for: appOwnedCall) == false)
    }

    @MainActor
    @Test func googleCalendarOnlyPatchesCurrentAppManagedEvents() async throws {
        let customer = Customer(name: "Calendar Customer")
        let call = ServiceCall(
            googleCalendarID: "primary",
            googleEventID: "event-123",
            googleEventManagedByApp: true,
            type: .service,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            customer: customer
        )
        let start = GoogleCalendarEventDate(date: nil, dateTime: "2027-01-15T13:00:00Z", timeZone: nil)
        let end = GoogleCalendarEventDate(date: nil, dateTime: "2027-01-15T14:00:00Z", timeZone: nil)
        let unmarkedRemoteEvent = GoogleCalendarEvent(
            id: "event-123",
            summary: "Existing Google title",
            description: "Keep this body",
            location: "Keep this address",
            htmlLink: nil,
            attendees: nil,
            extendedProperties: nil,
            start: start,
            end: end
        )
        let managedRemoteEvent = GoogleCalendarEvent(
            id: "event-123",
            summary: "Existing Google title",
            description: "Keep this body",
            location: "Keep this address",
            htmlLink: nil,
            attendees: nil,
            extendedProperties: GoogleCalendarExtendedProperties(privateProperties: [
                "gunnaireManaged": "true",
                "gunnaireManagedVersion": "4",
                "gunnaireOrigin": "ios-app"
            ]),
            start: start,
            end: end
        )
        let legacyMarkedRemoteEvent = GoogleCalendarEvent(
            id: "event-123",
            summary: "Existing Google title",
            description: "Keep this body",
            location: "Keep this address",
            htmlLink: nil,
            attendees: nil,
            extendedProperties: GoogleCalendarExtendedProperties(privateProperties: ["gunnaireManaged": "true"]),
            start: start,
            end: end
        )

        #expect(GoogleCalendarScheduleSync.shouldPatchExistingGoogleCalendarEvent(for: call, remoteEvent: nil) == false)
        #expect(GoogleCalendarScheduleSync.shouldPatchExistingGoogleCalendarEvent(for: call, remoteEvent: unmarkedRemoteEvent) == false)
        #expect(GoogleCalendarScheduleSync.shouldPatchExistingGoogleCalendarEvent(for: call, remoteEvent: legacyMarkedRemoteEvent) == false)
        #expect(GoogleCalendarScheduleSync.shouldPatchExistingGoogleCalendarEvent(for: call, remoteEvent: managedRemoteEvent) == true)
        #expect(GoogleCalendarScheduleSync.shouldDeleteExistingGoogleCalendarEvent(for: call, remoteEvent: nil) == false)
        #expect(GoogleCalendarScheduleSync.shouldDeleteExistingGoogleCalendarEvent(for: call, remoteEvent: unmarkedRemoteEvent) == false)
        #expect(GoogleCalendarScheduleSync.shouldDeleteExistingGoogleCalendarEvent(for: call, remoteEvent: legacyMarkedRemoteEvent) == false)
        #expect(GoogleCalendarScheduleSync.shouldDeleteExistingGoogleCalendarEvent(for: call, remoteEvent: managedRemoteEvent) == true)
        #expect(GoogleCalendarScheduleSync.shouldAttemptManagedCalendarDeletion(for: call) == true)
    }

    @Test func googleCalendarCreatePayloadMarksAppOwnershipWithoutDroppingVisibleDetails() async throws {
        let customer = Customer(name: "Calendar Customer", address: "123 Main St")
        let call = ServiceCall(
            eventTitle: "App-created service call",
            siteAddress: "456 Field Rd",
            type: .service,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            duration: 3_600,
            customer: customer,
            notes: "Visible job details."
        )
        let event = GoogleCalendarScheduleSync.makeCalendarCreateEvent(for: call)
        let encoded = try JSONEncoder().encode(event)
        let payload = String(data: encoded, encoding: .utf8) ?? ""

        #expect(payload.contains("\"summary\""))
        #expect(payload.contains("\"description\""))
        #expect(payload.contains("\"location\""))
        #expect(payload.contains("\"extendedProperties\""))
        #expect(payload.contains("gunnaireManaged"))
        #expect(payload.contains("gunnaireManagedVersion"))
        #expect(payload.contains("gunnaireOrigin"))
    }

    @MainActor
    @Test func googleCalendarPatchPayloadCannotScrubExternalDetails() async throws {
        let customer = Customer(name: "Calendar Customer")
        let call = ServiceCall(
            googleCalendarID: "primary",
            googleEventID: "event-123",
            googleEventManagedByApp: false,
            eventTitle: "Do not send this title",
            siteAddress: "",
            type: .service,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            duration: 3600,
            customer: customer,
            notes: ""
        )

        let patch = GoogleCalendarScheduleSync.makeManagedEventPatch(for: call, remoteEvent: nil)
        let payload = String(data: try JSONEncoder().encode(patch), encoding: .utf8) ?? ""

        #expect(payload.contains("\"start\""))
        #expect(payload.contains("\"end\""))
        #expect(!payload.contains("summary"))
        #expect(!payload.contains("location"))
        #expect(!payload.contains("description"))
        #expect(!payload.contains("extendedProperties"))
        #expect(!payload.contains("Do not send this title"))
    }

    @MainActor
    @Test func googleCalendarLinkedEventsCannotCreateOrPatchScrubPayloads() async throws {
        let customer = Customer(name: "Calendar Customer")
        let linkedCall = ServiceCall(
            googleCalendarID: "shared-calendar@example.com",
            googleEventID: "google-event-123",
            googleEventManagedByApp: false,
            eventTitle: "",
            siteAddress: "",
            type: .other,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            duration: 3600,
            customer: customer,
            notes: ""
        )

        #expect(GoogleCalendarScheduleSync.shouldAllowGoogleCalendarWrite(for: linkedCall) == false)
        #expect(GoogleCalendarScheduleSync.shouldPublishAfterLocalSave(for: linkedCall) == false)
        #expect(GoogleCalendarScheduleSync.shouldCreateGoogleCalendarEvent(for: linkedCall) == false)
        #expect(GoogleCalendarScheduleSync.shouldPatchExistingGoogleCalendarEvent(for: linkedCall, remoteEvent: nil) == false)

        let payload = String(
            data: try JSONEncoder().encode(GoogleCalendarScheduleSync.makeScheduleOnlyPatch(for: linkedCall)),
            encoding: .utf8
        ) ?? ""

        #expect(payload.contains("summary") == false)
        #expect(payload.contains("location") == false)
        #expect(payload.contains("description") == false)
        #expect(payload.contains("attendees") == false)
    }

    @MainActor
    @Test func googleCalendarLinkedEventsDoNotExportEvenIfMarkedLocallyEdited() async throws {
        let customer = Customer(name: "Calendar Customer")
        let linkedCall = ServiceCall(
            googleCalendarID: "shared-calendar@example.com",
            googleEventID: "google-event-123",
            googleEventManagedByApp: false,
            eventTitle: "Keep Google title",
            siteAddress: "Keep Google location",
            type: .service,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            duration: 3600,
            customer: customer,
            notes: "Keep Google body"
        )

        GoogleCalendarScheduleSync.markCalendarCallLocallyEdited(linkedCall)

        #expect(GoogleCalendarScheduleSync.shouldExportDuringCalendarSync(linkedCall) == false)
        #expect(GoogleCalendarScheduleSync.shouldPublishAfterLocalSave(for: linkedCall) == false)
        #expect(GoogleCalendarScheduleSync.shouldCreateGoogleCalendarEvent(for: linkedCall) == false)
    }

    @MainActor
    @Test func googleCalendarCreateGuardMatchesExistingEventByScheduleSlotOnly() async throws {
        let customer = Customer(name: "Calendar Customer")
        let call = ServiceCall(
            googleCalendarID: "primary",
            googleEventManagedByApp: true,
            eventTitle: "Local app title",
            siteAddress: "Local app address",
            type: .service,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            duration: 3_600,
            customer: customer,
            notes: "Local app notes"
        )
        let remoteEvent = GoogleCalendarEvent(
            id: "google-owned-event",
            summary: "External Google title must remain",
            description: "External Google body must remain",
            location: "External Google location must remain",
            htmlLink: nil,
            attendees: nil,
            extendedProperties: nil,
            start: GoogleCalendarEventDate(date: nil, dateTime: "2027-01-15T08:00:00Z", timeZone: nil),
            end: GoogleCalendarEventDate(date: nil, dateTime: "2027-01-15T09:00:00Z", timeZone: nil)
        )

        #expect(GoogleCalendarScheduleSync.remoteEventMatchesScheduleSlot(call: call, remoteEvent: remoteEvent))
    }

    @MainActor
    @Test func googleCalendarCreateGuardRejectsDifferentScheduleSlot() async throws {
        let customer = Customer(name: "Calendar Customer")
        let call = ServiceCall(
            googleCalendarID: "primary",
            googleEventManagedByApp: true,
            eventTitle: "Local app title",
            type: .service,
            scheduledDate: Date(timeIntervalSince1970: 1_800_000_000),
            duration: 3_600,
            customer: customer
        )
        let remoteEvent = GoogleCalendarEvent(
            id: "different-slot-event",
            summary: "External Google title",
            description: "External Google body",
            location: "External Google location",
            htmlLink: nil,
            attendees: nil,
            extendedProperties: nil,
            start: GoogleCalendarEventDate(date: nil, dateTime: "2027-01-15T10:00:00Z", timeZone: nil),
            end: GoogleCalendarEventDate(date: nil, dateTime: "2027-01-15T11:00:00Z", timeZone: nil)
        )

        #expect(GoogleCalendarScheduleSync.remoteEventMatchesScheduleSlot(call: call, remoteEvent: remoteEvent) == false)
    }

    @Test func googleCalendarImportTreatsManagedMarkersAsReadOnly() async throws {
        let start = GoogleCalendarEventDate(date: nil, dateTime: "2027-01-15T13:00:00Z", timeZone: nil)
        let end = GoogleCalendarEventDate(date: nil, dateTime: "2027-01-15T14:00:00Z", timeZone: nil)
        let externallyManagedEvent = GoogleCalendarEvent(
            id: "external-event",
            summary: "Customer reminder",
            description: "Do not overwrite",
            location: "Customer site",
            htmlLink: nil,
            attendees: nil,
            extendedProperties: nil,
            start: start,
            end: end
        )
        let appManagedEvent = GoogleCalendarEvent(
            id: "app-event",
            summary: "GunnAire service",
            description: "App-created",
            location: "Customer site",
            htmlLink: nil,
            attendees: nil,
            extendedProperties: GoogleCalendarExtendedProperties(privateProperties: [
                "gunnaireManaged": "true",
                "gunnaireManagedVersion": "4",
                "gunnaireOrigin": "ios-app"
            ]),
            start: start,
            end: end
        )
        let legacyMarkedEvent = GoogleCalendarEvent(
            id: "legacy-event",
            summary: "Older touched event",
            description: "Do not overwrite",
            location: "Customer site",
            htmlLink: nil,
            attendees: nil,
            extendedProperties: GoogleCalendarExtendedProperties(privateProperties: ["gunnaireManaged": "true"]),
            start: start,
            end: end
        )

        #expect(GoogleCalendarScheduleSync.isImportedEventManagedByApp(externallyManagedEvent) == false)
        #expect(GoogleCalendarScheduleSync.isImportedEventManagedByApp(legacyMarkedEvent) == false)
        #expect(GoogleCalendarScheduleSync.isImportedEventManagedByApp(appManagedEvent))
    }

    @Test func gmailRawMessageIncludesPdfAttachment() async throws {
        let attachment = GmailAttachment(
            fileName: "GunnAire-Estimate.pdf",
            mimeType: "application/pdf",
            data: Data("pdf-data".utf8)
        )

        let message = GoogleAuthManager.makeGmailRawMessage(
            to: "customer@example.com",
            subject: "Estimate",
            body: "Attached is your estimate.",
            attachments: [attachment]
        )

        #expect(message.contains("Content-Type: multipart/mixed"))
        #expect(message.contains("Content-Type: text/plain; charset=utf-8"))
        #expect(message.contains("Content-Type: application/pdf; name=\"GunnAire-Estimate.pdf\""))
        #expect(message.contains("Content-Disposition: attachment; filename=\"GunnAire-Estimate.pdf\""))
        #expect(message.contains(Data("pdf-data".utf8).base64EncodedString()))
    }

    @Test func generatedBillingDocumentEmailCanCarryPdfAttachment() async throws {
        let attachment = GmailAttachment(
            fileName: "GunnAire-Invoice.pdf",
            mimeType: "application/pdf",
            data: Data("%PDF generated invoice".utf8)
        )

        let message = GoogleAuthManager.makeGmailRawMessage(
            to: "customer@example.com",
            subject: "GunnAire Paid Invoice",
            body: "Attached is your GunnAire paid invoice.",
            attachments: [attachment]
        )

        #expect(message.contains("To: customer@example.com"))
        #expect(message.contains("Subject: GunnAire Paid Invoice"))
        #expect(message.contains("Content-Type: application/pdf; name=\"GunnAire-Invoice.pdf\""))
        #expect(message.contains("Content-Disposition: attachment; filename=\"GunnAire-Invoice.pdf\""))
    }

    @Test func invoiceDocumentLabelUsesOpenInvoiceUntilFullyPaid() async throws {
        let customer = Customer(name: "Invoice Customer")
        let invoice = Invoice(
            customer: customer,
            lineItemSummary: "Service labor",
            amount: 500,
            status: "sent"
        )
        let partialPayment = Payment(invoice: invoice, amount: 125, method: "card")

        #expect(CustomerDocumentExporter.invoiceDocumentLabel(for: invoice, payments: []) == "Invoice")
        #expect(CustomerDocumentExporter.invoiceDocumentCaption(for: invoice, payments: []) == "Generated invoice PDF")
        #expect(CustomerDocumentExporter.invoiceDocumentLabel(for: invoice, payments: [partialPayment]) == "Invoice")
    }

    @Test func invoiceDocumentLabelUsesPaidInvoiceWhenSettled() async throws {
        let customer = Customer(name: "Invoice Customer")
        let paidByStatus = Invoice(
            customer: customer,
            lineItemSummary: "Service labor",
            amount: 500,
            status: "paid"
        )
        let paidByBalance = Invoice(
            customer: customer,
            lineItemSummary: "Service labor",
            amount: 500,
            status: "sent"
        )
        let fullPayment = Payment(invoice: paidByBalance, amount: 500, method: "ach")

        #expect(CustomerDocumentExporter.invoiceDocumentLabel(for: paidByStatus, payments: []) == "Paid Invoice")
        #expect(CustomerDocumentExporter.invoiceDocumentLabel(for: paidByBalance, payments: [fullPayment]) == "Paid Invoice")
        #expect(CustomerDocumentExporter.invoiceDocumentCaption(for: paidByBalance, payments: [fullPayment]) == "Generated paid invoice PDF")
    }

    @Test func mailDraftRoutePersistsAttachmentPaths() async throws {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "GunnAirePendingMailTo")
        defaults.removeObject(forKey: "GunnAirePendingMailSubject")
        defaults.removeObject(forKey: "GunnAirePendingMailBody")
        defaults.removeObject(forKey: "GunnAirePendingMailAttachmentPaths")

        GunnAireAppIntentRouter.storeMailDraftRoute(
            to: "customer@example.com",
            subject: "Service Report",
            body: "Attached.",
            attachmentPaths: ["/tmp/report.pdf"]
        )
        let draft = GunnAireAppIntentRouter.consumePendingMailDraft()

        #expect(draft?.to == "customer@example.com")
        #expect(draft?.subject == "Service Report")
        #expect(draft?.body == "Attached.")
        #expect(draft?.attachmentPaths == ["/tmp/report.pdf"])
    }

    @MainActor
    @Test func googleCalendarRoutingOnlyChangesBeforeEventExists() async throws {
        let customer = Customer(name: "Calendar Customer")
        let linkedAppCall = ServiceCall(
            googleCalendarID: "primary",
            googleEventID: "google-event-123",
            googleEventManagedByApp: true,
            type: .service,
            scheduledDate: Date(),
            customer: customer
        )
        let linkedExternalCall = ServiceCall(
            googleCalendarID: "primary",
            googleEventID: "external-event-123",
            googleEventManagedByApp: false,
            type: .service,
            scheduledDate: Date(),
            customer: customer
        )
        let newCall = ServiceCall(
            googleEventManagedByApp: true,
            type: .service,
            scheduledDate: Date(),
            customer: customer
        )

        #expect(GoogleCalendarScheduleSync.shouldSelectGoogleCalendarBeforeCreate(for: linkedAppCall) == false)
        #expect(GoogleCalendarScheduleSync.shouldSelectGoogleCalendarBeforeCreate(for: linkedExternalCall) == false)
        #expect(GoogleCalendarScheduleSync.shouldSelectGoogleCalendarBeforeCreate(for: newCall) == true)
    }

    @Test func splashVideoLocatorPrefersStoredVideoOverBundledVideo() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let storedURL = tempDirectory.appendingPathComponent("Loading.mp4")
        try Data([0x00, 0x01, 0x02]).write(to: storedURL)

        let bundledURL = URL(fileURLWithPath: "/tmp/bundled/Loading.mp4")
        let resolved = SplashVideoLocator.preferredURL(
            bundledURL: bundledURL,
            storedCandidates: [storedURL],
            fileManager: .default
        )

        #expect(resolved == storedURL)
    }

    @Test func splashVideoLocatorFallsBackToBundledVideoWhenStoredVideoMissing() async throws {
        let missingStoredURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("Loading.mp4")
        let bundledURL = URL(fileURLWithPath: "/tmp/bundled/Loading.mp4")

        let resolved = SplashVideoLocator.preferredURL(
            bundledURL: bundledURL,
            storedCandidates: [missingStoredURL],
            fileManager: .default
        )

        #expect(resolved == bundledURL)
    }

    @Test func splashVideoPreferredDelayUsesFallbackForInvalidDuration() async throws {
        #expect(SplashVideoLocator.preferredFinishDelay(durationSeconds: 0) == 3.0)
        #expect(SplashVideoLocator.preferredFinishDelay(durationSeconds: .infinity) == 3.0)
    }

    @Test func splashVideoPreferredDelayCapsLongVideos() async throws {
        #expect(SplashVideoLocator.preferredFinishDelay(durationSeconds: 2.5) == 2.7)
        #expect(SplashVideoLocator.preferredFinishDelay(durationSeconds: 12) == 6.0)
        #expect(SplashVideoLocator.preferredFinishDelay(durationSeconds: 12, maximumDuration: 4.5) == 4.5)
    }

    @Test func splashVideoSourceDescriptionMatchesExpectedCases() async throws {
        #expect(SplashVideoLocator.Source.custom.description == "Custom Loading.mp4")
        #expect(SplashVideoLocator.Source.bundled.description == "Bundled Loading.mp4")
        #expect(SplashVideoLocator.Source.fallback.description == "Logo Fallback")
    }

    @Test func customerIntelligenceBalanceAccountsForRefunds() async throws {
        let customer = Customer(name: "Balance Customer")
        let invoice = Invoice(customer: customer, amount: 1_000, status: "unpaid")
        let payment = Payment(invoice: invoice, amount: 400, method: "card")
        let refund = Payment(invoice: invoice, amount: 125, method: "card", isRefund: true, refundedPaymentID: payment.id)

        let balance = CustomerIntelligence.outstandingBalance(for: invoice, payments: [payment, refund])

        #expect(balance == 725)
    }

    @Test func invoiceBalanceUsesQuickBooksBalanceWhenPaymentRecordsAreMissing() async throws {
        let customer = Customer(name: "QBO Paid Customer")
        let paidInvoice = Invoice(
            customer: customer,
            quickBooksID: "INV-PAID",
            quickBooksBalanceDue: 0,
            amount: 500,
            status: "unpaid"
        )
        let openInvoice = Invoice(
            customer: customer,
            quickBooksID: "INV-OPEN",
            quickBooksBalanceDue: 125,
            amount: 500,
            status: "paid"
        )

        #expect(Invoice.outstandingBalance(for: paidInvoice, payments: []) == 0)
        #expect(Invoice.isPaid(paidInvoice, payments: []) == true)
        #expect(Invoice.resolvedStatus(for: paidInvoice, payments: []) == "paid")
        #expect(Invoice.outstandingBalance(for: openInvoice, payments: []) == 125)
        #expect(Invoice.isPaid(openInvoice, payments: []) == false)
        #expect(Invoice.resolvedStatus(for: openInvoice, payments: []) == "partial")
    }

    @Test func invoiceLocalPaymentAdjustsStoredQuickBooksBalance() async throws {
        let customer = Customer(name: "QBO Balance Customer")
        let invoice = Invoice(
            customer: customer,
            quickBooksID: "INV-BAL",
            quickBooksBalanceDue: 300,
            amount: 500,
            status: "partial"
        )

        invoice.applyLocalPaymentAmount(125)
        #expect(invoice.quickBooksBalanceDue == 175)
        #expect(Invoice.outstandingBalance(for: invoice, payments: []) == 175)

        invoice.applyLocalPaymentAmount(25, isRefund: true)
        #expect(invoice.quickBooksBalanceDue == 200)
        #expect(Invoice.outstandingBalance(for: invoice, payments: []) == 200)
    }

    @Test func invoiceStatusRankingPreservesPaidStateDuringDuplicateMerge() async throws {
        let paidInvoice = Invoice(customer: Customer(name: "Paid Customer"), amount: 500, status: " Paid ")

        #expect(paidInvoice.normalizedStatus == "paid")
        #expect(Invoice.mostResolvedStatus("unpaid", "paid") == "paid")
        #expect(Invoice.mostResolvedStatus("overdue", "partial") == "partial")
        #expect(Invoice.mostResolvedStatus("paid", "partial") == "paid")
        #expect(Invoice.mostResolvedStatus("", "unpaid") == "unpaid")
    }

    @Test func invoiceDisplayDeduplicationPrefersPaidQuickBooksRecord() async throws {
        let customer = Customer(name: "Display Customer")
        let serviceCallID = UUID()
        let localDuplicate = Invoice(
            serviceCallID: serviceCallID,
            customer: customer,
            amount: 500,
            status: "unpaid",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let quickBooksPaid = Invoice(
            serviceCallID: serviceCallID,
            customer: customer,
            quickBooksID: "INV-123",
            amount: 500,
            status: "paid",
            createdAt: Date(timeIntervalSince1970: 1_800_000_100)
        )

        let displayed = Invoice.displayDeduplicated([localDuplicate, quickBooksPaid])

        #expect(displayed.count == 1)
        #expect(displayed.first === quickBooksPaid)
        #expect(displayed.first?.normalizedStatus == "paid")
    }

    @Test func invoiceDisplayDeduplicationCollapsesLocalAndQuickBooksCopiesForSameServiceCall() async throws {
        let customer = Customer(name: "Display Customer")
        let serviceCallID = UUID()
        let localPaidCopy = Invoice(
            serviceCallID: serviceCallID,
            customer: customer,
            amount: 500,
            status: "paid",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let quickBooksUnpaidCopy = Invoice(
            serviceCallID: serviceCallID,
            customer: customer,
            quickBooksID: "INV-123",
            quickBooksBalanceDue: 500,
            amount: 500,
            status: "unpaid",
            createdAt: Date(timeIntervalSince1970: 1_800_000_100)
        )

        let displayed = Invoice.displayDeduplicated([localPaidCopy, quickBooksUnpaidCopy])

        #expect(displayed.count == 1)
        #expect(displayed.first === localPaidCopy)
        #expect(Invoice.resolvedStatus(for: displayed.first!, payments: []) == "paid")
    }

    @Test func billingInvoiceQueuesDoNotRepeatCollectionInvoicesInOverdueSection() async throws {
        let customer = Customer(name: "Queue Customer")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldDate = Calendar.current.date(byAdding: .day, value: -45, to: now) ?? now
        let recentDate = Calendar.current.date(byAdding: .day, value: -10, to: now) ?? now
        let overdueInvoices = (0..<10).map { index in
            Invoice(
                customer: customer,
                amount: Double(100 + index),
                status: "unpaid",
                createdAt: oldDate.addingTimeInterval(Double(index))
            )
        }
        let recentOpenInvoice = Invoice(
            customer: customer,
            amount: 300,
            status: "unpaid",
            createdAt: recentDate
        )
        let paidInvoice = Invoice(
            customer: customer,
            amount: 500,
            status: "paid",
            createdAt: oldDate
        )
        let displayed = overdueInvoices + [recentOpenInvoice, paidInvoice]

        let collectible = BillingInvoiceQueueBuilder.collectibleInvoices(from: displayed, payments: [])
        let collectionsQueue = BillingInvoiceQueueBuilder.collectionsQueue(from: collectible, limit: 8)
        let overdue = BillingInvoiceQueueBuilder.overdueInvoices(from: collectible, payments: [], now: now)
        let overdueOutsideCollections = BillingInvoiceQueueBuilder.overdueQueueExcludingCollections(
            overdueInvoices: overdue,
            collectionsQueue: collectionsQueue
        )

        #expect(collectible.count == 11)
        #expect(collectionsQueue.count == 8)
        #expect(overdue.count == 10)
        #expect(overdueOutsideCollections.count == 2)
        #expect(Set(overdueOutsideCollections.map(\.id)).isDisjoint(with: Set(collectionsQueue.map(\.id))))
        #expect(overdueOutsideCollections.allSatisfy { BillingInvoiceQueueBuilder.isOverdue($0, payments: [], now: now) })
        #expect(overdueOutsideCollections.contains { $0.id == recentOpenInvoice.id } == false)
        #expect(collectible.contains { $0.id == paidInvoice.id } == false)
    }

    @Test func estimateDisplayDeduplicationPrefersQuickBooksRecord() async throws {
        let customer = Customer(name: "Estimate Display Customer")
        let serviceCallID = UUID()
        let localDuplicate = Estimate(
            serviceCallID: serviceCallID,
            customer: customer,
            amount: 750,
            status: "pending",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let quickBooksEstimate = Estimate(
            serviceCallID: serviceCallID,
            customer: customer,
            quickBooksID: "EST-123",
            amount: 750,
            status: "accepted",
            createdAt: Date(timeIntervalSince1970: 1_800_000_100)
        )

        let displayed = Estimate.displayDeduplicated([localDuplicate, quickBooksEstimate])

        #expect(displayed.count == 1)
        #expect(displayed.first === quickBooksEstimate)
        #expect(displayed.first?.status == "accepted")
    }

    @Test func invoicePaymentHistoryRowsLabelRefundsClearly() async throws {
        let customer = Customer(name: "Refund Customer")
        let invoice = Invoice(customer: customer, amount: 1_000, status: "partial")
        let payment = Payment(
            invoice: invoice,
            amount: 400,
            date: Date(timeIntervalSince1970: 20),
            method: "card"
        )
        let refund = Payment(
            invoice: invoice,
            amount: 125,
            date: Date(timeIntervalSince1970: 40),
            method: "card",
            isRefund: true,
            refundedPaymentID: payment.id
        )

        let rows = CustomerDocumentExporter.invoicePaymentHistoryRows(for: [refund, payment])

        #expect(rows.count == 2)
        #expect(rows[0].value.contains("Payment"))
        #expect(rows[0].value.contains("$400"))
        #expect(rows[1].value.contains("Refund"))
        #expect(rows[1].value.contains("-$125"))
    }

    @Test func paymentSharedCompanyQueueFailureDoesNotRequireQuickBooksRetry() async throws {
        let customer = Customer(name: "Queue Customer")
        let invoice = Invoice(customer: customer, amount: 250, status: "partial")
        let payment = Payment(
            invoice: invoice,
            processorSyncStatus: "needs_attention",
            processorSyncDetail: "Shared company payment queue upload failed: offline",
            amount: 250,
            method: "card"
        )

        #expect(payment.needsSharedCompanyQueueUpload)
        #expect(payment.needsQuickBooksAttention == false)
    }

    @Test func paymentSharedCompanyQueueStatusHelpersDriveRetryState() async throws {
        let customer = Customer(name: "Queue Helper Customer")
        let invoice = Invoice(customer: customer, amount: 250, status: "partial")
        let payment = Payment(invoice: invoice, amount: 250, method: "card")

        payment.markSharedCompanyQueueUnavailable()
        #expect(payment.processorSyncStatus == "local_only")
        #expect(payment.needsSharedCompanyQueueUpload)

        payment.markSharedCompanyQueued()
        #expect(payment.processorSyncStatus == "company_queued")
        #expect(payment.needsSharedCompanyQueueUpload == false)
        #expect(payment.needsQuickBooksAttention == false)

        payment.markSharedCompanyQueueFailed("offline")
        #expect(payment.processorSyncStatus == "needs_attention")
        #expect(payment.processorSyncDetail == "Shared company payment queue upload failed: offline")
        #expect(payment.needsSharedCompanyQueueUpload)
        #expect(payment.needsQuickBooksAttention == false)
    }

    @Test func paymentProcessorFailureStillRequiresQuickBooksRetryWhenNotCompanyQueue() async throws {
        let customer = Customer(name: "Processor Customer")
        let invoice = Invoice(customer: customer, amount: 250, status: "partial")
        let payment = Payment(
            invoice: invoice,
            processorSyncStatus: "needs_attention",
            processorSyncDetail: "QuickBooks Payments authorization failed.",
            amount: 250,
            method: "card"
        )

        #expect(payment.needsSharedCompanyQueueUpload == false)
        #expect(payment.needsQuickBooksAttention)
    }

    @Test func backendPaymentCollectionsDecodeSharedFieldQueueResponse() async throws {
        let json = Data("""
        {
          "payments": [
            {
              "id": "queue-record-1",
              "paymentID": "payment-1",
              "invoiceID": "invoice-1",
              "invoiceQuickBooksID": "123",
              "customerName": "Shared Customer",
              "customerEmail": "customer@example.com",
              "amount": 275.5,
              "method": "card",
              "cardLast4": "4242",
              "authorizationReference": "auth-1",
              "processor": "quickbooks-payments",
              "notes": "Field collection",
              "collectedBy": "tech@gunnaire.com",
              "collectedAt": "2026-08-13T14:00:00Z",
              "createdAt": "2026-08-13T14:01:00Z"
            }
          ]
        }
        """.utf8)

        let records = try GunnAireBackendService.decodePaymentCollections(from: json)

        #expect(records.count == 1)
        #expect(records[0].paymentID == "payment-1")
        #expect(records[0].customerName == "Shared Customer")
        #expect(records[0].amount == 275.5)
        #expect(records[0].collectedBy == "tech@gunnaire.com")
    }

    @Test func backendReadinessDecodesActionableAdminStatusWithoutSecrets() async throws {
        let json = Data("""
        {
          "status": "attention",
          "serviceVersion": "2026.08.26.3",
          "checkedAt": "2026-08-26T20:00:00+00:00",
          "components": [
            {
              "id": "database",
              "title": "Database",
              "status": "ready",
              "detail": "SQLite is readable, writable, and internally consistent."
            },
            {
              "id": "backup",
              "title": "Verified Backup",
              "status": "attention",
              "detail": "No recent verified backup record is available."
            }
          ]
        }
        """.utf8)

        let snapshot = try GunnAireBackendService.decodeReadiness(from: json)

        #expect(snapshot.isReady == false)
        #expect(snapshot.attentionCount == 1)
        #expect(snapshot.serviceVersion == "2026.08.26.3")
        #expect(snapshot.components.first?.isReady == true)
        #expect(snapshot.components.last?.id == "backup")
        #expect(String(decoding: json, as: UTF8.self).contains("refresh_token") == false)
        #expect(String(decoding: json, as: UTF8.self).contains("client_secret") == false)
    }

    @Test func backendQuickBooksWebhookEventsDecodeSafeChangeMetadata() async throws {
        let json = Data("""
        {
          "events": [
            {
              "id": "event-1",
              "entityType": "item",
              "entityID": "84",
              "operation": "created",
              "occurredAt": "2026-08-26T20:00:00Z",
              "receivedAt": "2026-08-26T20:00:01Z"
            }
          ]
        }
        """.utf8)

        let events = try GunnAireBackendService.decodeQuickBooksWebhookEvents(from: json)
        let source = String(decoding: json, as: UTF8.self)

        #expect(events.count == 1)
        #expect(events[0].id == "event-1")
        #expect(events[0].entityLabel == "Item")
        #expect(events[0].summary == "Item created")
        #expect(source.contains("realmID") == false)
        #expect(source.contains("data") == false)
        #expect(source.contains("token") == false)
    }

    @Test func backendDocumentsDecodeSharedDocumentInventoryResponse() async throws {
        let json = Data("""
        {
          "documents": [
            {
              "id": "document-1",
              "filename": "service-report.pdf",
              "contentType": "application/pdf",
              "kind": "service_report",
              "serviceCallID": "call-1",
              "invoiceID": "11111111-1111-1111-1111-111111111111",
              "estimateID": "22222222-2222-2222-2222-222222222222",
              "customerName": "Shared Customer",
              "storedPath": "/storage/service-report.pdf",
              "createdAt": "2026-08-13T14:01:00Z"
            }
          ]
        }
        """.utf8)

        let records = try GunnAireBackendService.decodeDocuments(from: json)

        #expect(records.count == 1)
        #expect(records[0].id == "document-1")
        #expect(records[0].filename == "service-report.pdf")
        #expect(records[0].kind == "service_report")
        #expect(records[0].customerName == "Shared Customer")
        #expect(records[0].invoiceID == "11111111-1111-1111-1111-111111111111")
        #expect(records[0].estimateID == "22222222-2222-2222-2222-222222222222")
        #expect(records[0].invoiceUUID == UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        #expect(records[0].estimateUUID == UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        #expect(records[0].customerEquipmentID == nil)
        #expect(records[0].equipmentName == nil)
    }

    @Test func backendDocumentsDecodeEquipmentMetadataForSharedFiles() async throws {
        let equipmentID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let json = Data("""
        {
          "documents": [
            {
              "id": "document-2",
              "filename": "rtu-data-plate.jpg",
              "contentType": "image/jpeg",
              "kind": "equipment_data_plate_photo",
              "serviceCallID": "call-1",
              "invoiceID": null,
              "estimateID": null,
              "customerEquipmentID": "\(equipmentID.uuidString)",
              "equipmentName": "Roof RTU 1",
              "customerName": "Shared Customer",
              "storedPath": "/storage/rtu-data-plate.jpg",
              "createdAt": "2026-08-13T14:01:00Z"
            }
          ]
        }
        """.utf8)

        let record = try #require(try GunnAireBackendService.decodeDocuments(from: json).first)

        #expect(record.customerEquipmentID == equipmentID.uuidString)
        #expect(record.equipmentName == "Roof RTU 1")
        #expect(record.kind == "equipment_data_plate_photo")
    }

    @Test func backendDocumentRecordsSearchSharedEquipmentMetadata() async throws {
        let document = BackendDocumentRecord(
            id: "document-3",
            filename: "rtu-data-plate.jpg",
            contentType: "image/jpeg",
            kind: "equipment_data_plate_photo",
            serviceCallID: "call-1",
            invoiceID: "invoice-1111",
            estimateID: "estimate-2222",
            customerEquipmentID: "11111111-2222-3333-4444-555555555555",
            equipmentName: "Roof RTU 1",
            customerName: "Shared Customer",
            storedPath: "/storage/rtu-data-plate.jpg",
            createdAt: "2026-08-13T14:01:00Z"
        )

        #expect(document.matchesCustomerName(" shared customer "))
        #expect(document.matchesCustomerName("Other Customer") == false)
        #expect(document.matchesCustomerDocumentSearch("roof rtu"))
        #expect(document.matchesCustomerDocumentSearch("55555555"))
        #expect(document.matchesCustomerDocumentSearch("invoice-1111"))
        #expect(document.matchesCustomerDocumentSearch("estimate-2222"))
        #expect(document.matchesCustomerDocumentSearch("data plate"))
        #expect(document.matchesCustomerDocumentSearch("compressor") == false)
    }

    @Test func customerIntelligencePrioritizesOverdueCollection() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let customer = Customer(
            name: "Priority Customer",
            phone: "555-0100",
            email: "ops@example.com",
            address: "100 Field Way"
        )
        let invoice = Invoice(
            customer: customer,
            amount: 500,
            status: "unpaid",
            createdAt: now.addingTimeInterval(-10 * 24 * 60 * 60)
        )

        let snapshot = CustomerIntelligence.snapshot(
            for: customer,
            serviceCalls: [],
            invoices: [invoice],
            estimates: [],
            payments: [],
            contracts: [],
            now: now
        )

        #expect(snapshot.openBalance == 500)
        #expect(snapshot.overdueInvoiceCount == 1)
        #expect(snapshot.healthScore < 70)
        #expect(snapshot.primaryAction == .collectPayment(invoice.id))
    }

    @Test func customerIntelligenceRanksRiskBeforeHealthyAccounts() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let healthy = Customer(
            name: "Healthy Account",
            phone: "555-0101",
            email: "healthy@example.com",
            address: "200 Maintenance Dr"
        )
        let risky = Customer(
            name: "Risky Account",
            phone: "555-0102",
            email: "risky@example.com",
            address: "300 Receivable Ave"
        )
        let riskyInvoice = Invoice(
            customer: risky,
            amount: 1_200,
            status: "unpaid",
            createdAt: now.addingTimeInterval(-14 * 24 * 60 * 60)
        )

        let snapshots = CustomerIntelligence.snapshots(
            customers: [healthy, risky],
            serviceCalls: [],
            invoices: [riskyInvoice],
            estimates: [],
            payments: [],
            contracts: [],
            now: now
        )

        #expect(snapshots.first?.customer.id == risky.id)
    }

    @Test func customerOperationalSearchMatchesEquipmentReportAndFollowUpContext() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let customer = Customer(
            name: "Searchable Service Customer",
            phone: "555-0199",
            email: "search@example.com",
            address: "900 Field Search Rd"
        )
        let equipment = CustomerEquipment(
            customer: customer,
            equipmentType: .splitSystemAC,
            name: "Downstairs AC",
            manufacturer: "Carrier",
            modelNumber: "24ABC6",
            serialNumber: "AC123",
            location: "Basement mechanical room",
            filterSize: "16x25x1"
        )
        let call = ServiceCall(
            equipmentName: "Downstairs AC",
            equipmentModel: "24ABC6",
            equipmentSerialNumber: "AC123",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            serviceReportSummary: "Cooling service completed.",
            type: .maintenance,
            scheduledDate: now.addingTimeInterval(-86_400),
            customer: customer,
            followUpRequired: true,
            followUpAction: "Return to replace weak capacitor.",
            followUpDueDate: now.addingTimeInterval(86_400 * 2)
        )
        call.setServiceActionStatus(.needsService, for: "condenser_coil_serviced")

        #expect(CustomerIntelligence.matchesOperationalSearch(
            customer: customer,
            query: "basement mechanical",
            serviceCalls: [call],
            equipmentProfiles: [equipment],
            now: now
        ))
        #expect(CustomerIntelligence.matchesOperationalSearch(
            customer: customer,
            query: "weak capacitor",
            serviceCalls: [call],
            equipmentProfiles: [equipment],
            now: now
        ))
        #expect(CustomerIntelligence.matchesOperationalSearch(
            customer: customer,
            query: "condenser coil",
            serviceCalls: [call],
            equipmentProfiles: [equipment],
            now: now
        ))
        #expect(CustomerIntelligence.matchesOperationalSearch(
            customer: customer,
            query: "16x25x1",
            serviceCalls: [call],
            equipmentProfiles: [equipment],
            now: now
        ))
        #expect(CustomerIntelligence.matchesOperationalSearch(
            customer: customer,
            query: "unrelated boiler",
            serviceCalls: [call],
            equipmentProfiles: [equipment],
            now: now
        ) == false)
    }

    @Test func businessSuitePrioritizesOverdueCollectionsAcrossModules() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let customer = Customer(
            name: "Suite Customer",
            phone: "555-0110",
            email: "suite@example.com",
            address: "400 Command Center"
        )
        let invoice = Invoice(
            customer: customer,
            amount: 900,
            status: "unpaid",
            createdAt: now.addingTimeInterval(-11 * 24 * 60 * 60)
        )
        let readyCall = ServiceCall(
            type: .meeting,
            scheduledDate: now.addingTimeInterval(-2 * 60 * 60),
            customer: customer,
            status: .completed,
            workCompletedChecklist: true
        )

        let snapshot = BusinessSuiteIntelligence.snapshot(
            customers: [customer],
            serviceCalls: [readyCall],
            technicians: [],
            contracts: [],
            estimates: [],
            invoices: [invoice],
            payments: [],
            timeEntries: [],
            googleConnected: true,
            quickBooksConnected: true,
            onsitePaymentsReady: true,
            now: now
        )

        #expect(snapshot.openReceivablesTotal == 900)
        #expect(snapshot.readyToBillCount == 1)
        #expect(snapshot.actions.first?.destination == .collectPayment(invoice.id))
    }

    @Test func businessSuiteScoresIntegrationGaps() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let customer = Customer(
            name: "Sync Customer",
            phone: "555-0111",
            email: "sync@example.com",
            address: "500 Integration Ave"
        )
        let call = ServiceCall(
            type: .maintenance,
            scheduledDate: now.addingTimeInterval(24 * 60 * 60),
            customer: customer
        )
        let estimate = Estimate(customer: customer, amount: 1_250, status: "pending")
        let invoice = Invoice(customer: customer, amount: 300, status: "unpaid")

        let snapshot = BusinessSuiteIntelligence.snapshot(
            customers: [customer],
            serviceCalls: [call],
            technicians: [],
            contracts: [],
            estimates: [estimate],
            invoices: [invoice],
            payments: [],
            timeEntries: [],
            googleConnected: true,
            quickBooksConnected: true,
            onsitePaymentsReady: false,
            now: now
        )

        let integrations = try #require(snapshot.workstreams.first { $0.id == .integrations })

        #expect(snapshot.syncAttentionCount == 3)
        #expect(integrations.score < 100)
        #expect(snapshot.actions.contains { $0.destination == .sync })
    }

    @Test func businessSuiteSurfacesTechnicalReportActionsAndOpenConcerns() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let customer = Customer(name: "Documentation Command Customer", address: "700 Report Ave")
        let incompleteReportCall = ServiceCall(
            equipmentName: "Main AC",
            equipmentTypeRaw: HVACEquipmentType.splitSystemAC.rawValue,
            type: .maintenance,
            scheduledDate: now.addingTimeInterval(-60 * 60),
            customer: customer,
            status: .inProgress
        )
        incompleteReportCall.setTechnicalReading("72", for: "return_air_temp")

        let concernCall = ServiceCall(
            equipmentName: "Attic Furnace",
            equipmentTypeRaw: HVACEquipmentType.gasFurnace.rawValue,
            type: .maintenance,
            scheduledDate: now.addingTimeInterval(60 * 60),
            customer: customer,
            status: .completed
        )
        concernCall.setServiceActionStatus(.needsService, for: "heat_exchanger_checked")

        let snapshot = BusinessSuiteIntelligence.snapshot(
            customers: [customer],
            serviceCalls: [incompleteReportCall, concernCall],
            technicians: [],
            contracts: [],
            estimates: [],
            invoices: [],
            payments: [],
            timeEntries: [],
            googleConnected: true,
            quickBooksConnected: true,
            onsitePaymentsReady: true,
            now: now
        )

        let documentation = try #require(snapshot.workstreams.first { $0.id == .documentation })
        let reportAction = try #require(snapshot.actions.first { $0.title == "Complete service report" })

        #expect(documentation.score < 100)
        #expect(documentation.detail.contains("2 report actions"))
        #expect(documentation.detail.contains("1 concern"))
        #expect(documentation.destination == .documentation(incompleteReportCall.id))
        #expect(reportAction.destination == .documentation(incompleteReportCall.id))
        #expect(reportAction.detail.contains("Documentation Command Customer"))
        #expect(reportAction.detail.contains("Complete"))
    }

    @Test func businessSuiteScoresStaleCalendarRoutesAsIntegrationGaps() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let customer = Customer(name: "Route Customer", address: "510 Integration Ave")
        let technician = Technician(name: "Route Tech", contactInfo: "route.tech@example.com")
        let call = ServiceCall(
            googleCalendarID: "previous.tech@example.com",
            googleEventID: "event-123",
            type: .service,
            scheduledDate: now.addingTimeInterval(2 * 60 * 60),
            assignedTechnician: technician,
            customer: customer
        )

        let snapshot = BusinessSuiteIntelligence.snapshot(
            customers: [customer],
            serviceCalls: [call],
            technicians: [technician],
            contracts: [],
            estimates: [],
            invoices: [],
            payments: [],
            timeEntries: [],
            googleConnected: true,
            quickBooksConnected: true,
            onsitePaymentsReady: true,
            now: now
        )

        let integrations = try #require(snapshot.workstreams.first { $0.id == .integrations })

        #expect(snapshot.syncAttentionCount == 1)
        #expect(integrations.detail.contains("1 calendar"))
        #expect(snapshot.actions.contains { $0.title == "Tighten sync coverage" })
    }

    @Test func businessSuiteFlagsPendingQuickBooksDocumentAttachments() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let customer = Customer(name: "Document Sync Customer", address: "520 Integration Ave")
        let invoice = Invoice(
            customer: customer,
            quickBooksID: "INV-520",
            amount: 500,
            status: "paid"
        )
        let report = ServiceDocumentAttachment(
            customer: customer,
            serviceCallID: nil,
            invoiceID: invoice.id,
            kind: .serviceReport,
            displayName: "onsite-report.pdf",
            localFilePath: "/tmp/onsite-report.pdf",
            contentType: "application/pdf",
            fileSizeBytes: 1024
        )

        let snapshot = BusinessSuiteIntelligence.snapshot(
            customers: [customer],
            serviceCalls: [],
            technicians: [],
            contracts: [],
            estimates: [],
            invoices: [invoice],
            payments: [],
            attachments: [report],
            timeEntries: [],
            googleConnected: true,
            quickBooksConnected: true,
            onsitePaymentsReady: true,
            now: now
        )

        let integrations = try #require(snapshot.workstreams.first { $0.id == .integrations })

        #expect(snapshot.syncAttentionCount == 1)
        #expect(integrations.detail.contains("1 QuickBooks"))
        #expect(snapshot.actions.contains { $0.title == "Tighten sync coverage" })
    }

    @Test func businessSuiteKeepsFailedQuickBooksInvoiceUpdatesVisible() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let customer = Customer(name: "Invoice Recovery Customer", address: "530 Integration Ave")
        let invoice = Invoice(
            customer: customer,
            quickBooksID: "INV-530",
            amount: 640,
            status: "unpaid"
        )
        invoice.quickBooksSyncStatus = "needs_attention"
        invoice.quickBooksSyncDetail = "QuickBooks rejected the last line-item update."

        let snapshot = BusinessSuiteIntelligence.snapshot(
            customers: [customer],
            serviceCalls: [],
            technicians: [],
            contracts: [],
            estimates: [],
            invoices: [invoice],
            payments: [],
            timeEntries: [],
            googleConnected: true,
            quickBooksConnected: true,
            onsitePaymentsReady: true,
            now: now
        )

        let integrations = try #require(snapshot.workstreams.first { $0.id == .integrations })

        #expect(snapshot.syncAttentionCount == 1)
        #expect(integrations.detail.contains("1 QuickBooks"))
        #expect(snapshot.actions.contains { $0.destination == .sync })
    }

    @Test func businessSuiteFlagsPricebookMarginAndCostGaps() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let unpricedItem = Item(name: "Emergency Diagnostic", unitPrice: 0)
        let lowMarginItem = Item(name: "Compressor Changeout", unitPrice: 500, purchaseCost: 450)
        let missingCostItem = Item(name: "Maintenance Tune-Up", unitPrice: 189)
        let vendor = Vendor(name: "HVAC Supply")

        let snapshot = BusinessSuiteIntelligence.snapshot(
            customers: [],
            serviceCalls: [],
            technicians: [],
            contracts: [],
            estimates: [],
            invoices: [],
            payments: [],
            timeEntries: [],
            items: [unpricedItem, lowMarginItem, missingCostItem],
            vendors: [vendor],
            googleConnected: true,
            quickBooksConnected: true,
            onsitePaymentsReady: true,
            now: now
        )

        let pricebook = try #require(snapshot.workstreams.first { $0.id == .pricebook })

        #expect(snapshot.catalogItemCount == 3)
        #expect(snapshot.pricebookAttentionCount == 6)
        #expect(pricebook.score < 70)
        #expect(snapshot.actions.contains { $0.title == "Set catalog price" && $0.destination == .quickBooks })
    }

    @Test func businessSuiteKeepsHealthyPricebookStable() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let diagnostic = Item(
            quickBooksID: "QB-ITEM-1",
            name: "Diagnostic Visit",
            unitPrice: 189,
            purchaseCost: 42
        )
        let capacitor = Item(
            quickBooksID: "QB-ITEM-2",
            name: "Capacitor Replacement",
            unitPrice: 329,
            purchaseCost: 90
        )
        let vendor = Vendor(name: "HVAC Supply")

        let snapshot = BusinessSuiteIntelligence.snapshot(
            customers: [],
            serviceCalls: [],
            technicians: [],
            contracts: [],
            estimates: [],
            invoices: [],
            payments: [],
            timeEntries: [],
            items: [diagnostic, capacitor],
            vendors: [vendor],
            googleConnected: true,
            quickBooksConnected: true,
            onsitePaymentsReady: true,
            now: now
        )

        let pricebook = try #require(snapshot.workstreams.first { $0.id == .pricebook })

        #expect(snapshot.pricebookAttentionCount == 0)
        #expect(snapshot.averageGrossMargin > 0.70)
        #expect(pricebook.score == 100)
    }

    @Test func catalogVendorSelectionBuildsSearchableOptionsAndPreservesQuickBooksID() async throws {
        let johnstone = Vendor(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            quickBooksID: "987",
            name: "Johnstone Supply",
            contactInfo: "parts@johnstone.example"
        )
        let amazon = Vendor(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            quickBooksID: "123",
            name: "Amazon Business",
            contactInfo: nil
        )

        let vendors = [johnstone, amazon]
        let options = CatalogVendorSelection.options(for: vendors)

        #expect(options.map(\.title) == ["Amazon Business", "Johnstone Supply"])
        #expect(options.first?.subtitle == "QBO 123")
        #expect(options.last?.subtitle == "parts@johnstone.example")
        #expect(CatalogVendorSelection.selectedVendorID(vendorName: " johnstone supply ", vendors: vendors) == johnstone.id.uuidString)
        #expect(CatalogVendorSelection.quickBooksID(vendorName: "JOHNSTONE SUPPLY", vendors: vendors) == "987")
        #expect(CatalogVendorSelection.quickBooksID(vendorName: "Manual Supply House", vendors: vendors) == nil)
    }

    @Test func billingCatalogSnapshotPreservesApprovedPriceAndCostAfterCatalogChanges() async throws {
        let approvedAt = Date(timeIntervalSinceReferenceDate: 42_000)
        let item = Item(
            name: "45/5 Dual Run Capacitor",
            itemType: .nonInventory,
            unitPrice: 289,
            purchaseCost: 67,
            isTaxable: true,
            sku: "CAP-45-5",
            createdAt: approvedAt
        )
        let snapshotJSON = try #require(CatalogLineItemSnapshot.encoded(from: [item]))

        item.unitPrice = 319
        item.purchaseCost = 82
        item.timestamp = Date()

        let customer = Customer(name: "Snapshot Customer")
        let estimate = Estimate(
            customer: customer,
            lineItemSummary: "45/5 Dual Run Capacitor",
            catalogSnapshotJSON: snapshotJSON,
            amount: 289
        )
        let invoice = Invoice(
            customer: customer,
            catalogSnapshotJSON: estimate.catalogSnapshotJSON,
            amount: estimate.amount
        )

        let estimateLine = try #require(estimate.catalogLineSnapshots.first)
        let invoiceLine = try #require(invoice.catalogLineSnapshots.first)
        #expect(estimateLine.unitPrice == 289)
        #expect(estimateLine.purchaseCost == 67)
        #expect(estimateLine.sku == "CAP-45-5")
        #expect(estimateLine.isTaxable == true)
        #expect(estimateLine.catalogUpdatedAt == approvedAt)
        #expect(invoiceLine == estimateLine)
    }

    @Test func billingCatalogSnapshotPreservesLineQuantityAndReadsLegacySnapshots() throws {
        struct LegacyCatalogLine: Codable {
            let catalogItemID: UUID
            let name: String
            let description: String?
            let sku: String?
            let unitPrice: Double
            let purchaseCost: Double?
            let isTaxable: Bool
            let catalogUpdatedAt: Date
        }

        let item = Item(name: "Condenser Pad", itemType: .nonInventory, unitPrice: 94)
        let quantityJSON = try #require(CatalogLineItemSnapshot.encoded(from: [item], quantities: [item.id: 2.5]))
        let quantityLine = try #require(CatalogLineItemSnapshot.decoded(from: quantityJSON).first)
        #expect(quantityLine.quantity == 2.5)

        let legacy = LegacyCatalogLine(
            catalogItemID: item.id,
            name: item.name,
            description: nil,
            sku: nil,
            unitPrice: item.unitPrice,
            purchaseCost: nil,
            isTaxable: false,
            catalogUpdatedAt: item.timestamp
        )
        let legacyData = try JSONEncoder().encode([legacy])
        let legacyJSON = try #require(String(data: legacyData, encoding: .utf8))
        let legacyLine = try #require(CatalogLineItemSnapshot.decoded(from: legacyJSON).first)
        #expect(legacyLine.quantity == 1)
    }

    @Test func quickBooksSalesLineEncodesQuantityUnitPriceAndExtendedAmount() throws {
        let line = QuickBooksLineItem(
            Amount: 237.50,
            DetailType: "SalesItemLineDetail",
            Description: "Condenser pad",
            SalesItemLineDetail: QuickBooksSalesItemLineDetail(
                ItemRef: QuickBooksReference(value: "QBO-ITEM-42", name: "Condenser Pad"),
                Qty: 2.5,
                UnitPrice: 95
            )
        )
        let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(line)) as? [String: Any]
        let detail = try #require(payload?["SalesItemLineDetail"] as? [String: Any])
        #expect(payload?["Amount"] as? Double == 237.50)
        #expect(detail["Qty"] as? Double == 2.5)
        #expect(detail["UnitPrice"] as? Double == 95)
        #expect((detail["ItemRef"] as? [String: String])?["value"] == "QBO-ITEM-42")
    }

    @Test func quickBooksInvoiceSparseUpdateCarriesConcurrencyTokenAndCompleteLines() throws {
        let lines = [
            QuickBooksLineItem(
                Amount: 189,
                DetailType: "SalesItemLineDetail",
                Description: "Diagnostic service",
                SalesItemLineDetail: QuickBooksSalesItemLineDetail(
                    ItemRef: QuickBooksReference(value: "QBO-1", name: "Diagnostic"),
                    Qty: 1,
                    UnitPrice: 189
                )
            ),
            QuickBooksLineItem(
                Amount: 250,
                DetailType: "SalesItemLineDetail",
                Description: "Repair",
                SalesItemLineDetail: QuickBooksSalesItemLineDetail(
                    ItemRef: QuickBooksReference(value: "QBO-2", name: "Repair"),
                    Qty: 2,
                    UnitPrice: 125
                )
            )
        ]
        let update = QuickBooksInvoiceUpdate(
            Id: "INV-42",
            SyncToken: "7",
            CustomerRef: QuickBooksReference(value: "CUST-1", name: "Customer"),
            Line: lines,
            PrivateNote: "Field revision"
        )

        let payload = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(update)) as? [String: Any]
        )
        #expect(payload["Id"] as? String == "INV-42")
        #expect(payload["SyncToken"] as? String == "7")
        #expect(payload["sparse"] as? Bool == true)
        #expect((payload["Line"] as? [[String: Any]])?.count == 2)
    }

    @Test func invoiceMutationPolicyAllowsDraftEditsAndProtectsSignedOrPaidHistory() {
        let customer = Customer(name: "Invoice Policy Customer")
        let draft = Invoice(customer: customer, amount: 189)
        #expect(BillingInvoiceMutationPolicy.blockedMessage(for: draft, payments: []) == nil)

        draft.finalizedAt = Date()
        #expect(BillingInvoiceMutationPolicy.blockedMessage(for: draft, payments: [])?.contains("finalized") == true)

        let partiallyPaid = Invoice(customer: customer, amount: 400)
        let payment = Payment(invoice: partiallyPaid, amount: 100, method: "card")
        #expect(BillingInvoiceMutationPolicy.blockedMessage(for: partiallyPaid, payments: [payment])?.contains("payment activity") == true)

        let quickBooksPartial = Invoice(
            customer: customer,
            quickBooksID: "QB-88",
            quickBooksBalanceDue: 50,
            amount: 200
        )
        #expect(BillingInvoiceMutationPolicy.blockedMessage(for: quickBooksPartial, payments: [])?.contains("payment activity") == true)

        quickBooksPartial.quickBooksSyncStatus = "pending"
        #expect(BillingInvoiceMutationPolicy.blockedMessage(for: quickBooksPartial, payments: []) == nil)
    }

    @Test func invoiceQuickBooksSyncStatePersistsPendingAndAttentionWork() {
        let customer = Customer(name: "Sync State Customer")
        let localInvoice = Invoice(customer: customer, amount: 90)
        #expect(localInvoice.quickBooksSyncState == "pending")

        localInvoice.quickBooksSyncStatus = "needs_attention"
        localInvoice.quickBooksSyncDetail = "Stale SyncToken"
        #expect(localInvoice.needsQuickBooksAttention)

        let importedInvoice = Invoice(
            customer: customer,
            quickBooksID: "QB-99",
            quickBooksSyncStatus: "synced",
            amount: 90
        )
        #expect(importedInvoice.quickBooksSyncState == "synced")
    }

    @Test func quickBooksInvoicePublicationRecoveryBuildsTheCompleteDurableLineSet() throws {
        let customer = Customer(quickBooksID: "QBO-CUSTOMER-1", name: "Recovery Customer")
        let diagnostic = Item(
            quickBooksID: "QBO-ITEM-1",
            name: "HVAC Diagnostic",
            unitPrice: 189,
            itemDescription: "Diagnostic visit"
        )
        let repair = Item(
            quickBooksID: "QBO-ITEM-2",
            name: "Contactor Repair",
            unitPrice: 125
        )
        let invoice = Invoice(
            customer: customer,
            catalogSnapshotJSON: CatalogLineItemSnapshot.encoded(
                from: [diagnostic, repair],
                quantities: [diagnostic.id: 1, repair.id: 2]
            ),
            amount: 439
        )

        let inputs = try QuickBooksInvoicePublicationRecovery.publicationInputs(
            for: invoice,
            catalogItems: [diagnostic, repair],
            payments: []
        )

        #expect(inputs.customerRef.value == "QBO-CUSTOMER-1")
        #expect(inputs.lines.count == 2)
        #expect(inputs.lines.reduce(0) { $0 + $1.Amount } == 439)
        let repairLine = try #require(inputs.lines.first { $0.SalesItemLineDetail.ItemRef.value == "QBO-ITEM-2" })
        #expect(repairLine.SalesItemLineDetail.Qty == 2)
        #expect(repairLine.SalesItemLineDetail.UnitPrice == 125)
    }

    @Test func quickBooksInvoicePublicationRecoveryPrioritizesAttentionAndProtectsExistingPaymentHistory() throws {
        let customer = Customer(quickBooksID: "QBO-CUSTOMER-2", name: "Queue Customer")
        let item = Item(quickBooksID: "QBO-ITEM-3", name: "Service", unitPrice: 100)
        let snapshot = CatalogLineItemSnapshot.encoded(from: [item])
        let synced = Invoice(
            customer: customer,
            quickBooksID: "QBO-SYNCED",
            quickBooksSyncStatus: "synced",
            catalogSnapshotJSON: snapshot,
            amount: 100
        )
        let pending = Invoice(customer: customer, catalogSnapshotJSON: snapshot, amount: 100)
        let attention = Invoice(
            customer: customer,
            quickBooksSyncStatus: "needs_attention",
            catalogSnapshotJSON: snapshot,
            amount: 100
        )

        let queue = QuickBooksInvoicePublicationRecovery.queuedInvoices(from: [pending, synced, attention])
        #expect(queue.map(\.id) == [attention.id, pending.id])

        let existing = Invoice(
            customer: customer,
            quickBooksID: "QBO-EXISTING",
            quickBooksSyncStatus: "pending",
            catalogSnapshotJSON: snapshot,
            amount: 100
        )
        let payment = Payment(invoice: existing, amount: 25, method: "card")
        #expect(throws: QuickBooksInvoicePublicationRecoveryError.self) {
            try QuickBooksInvoicePublicationRecovery.publicationInputs(
                for: existing,
                catalogItems: [item],
                payments: [payment]
            )
        }

        let localOnly = Invoice(customer: customer, catalogSnapshotJSON: snapshot, amount: 100)
        let localPayment = Payment(invoice: localOnly, amount: 25, method: "card")
        let localInputs = try QuickBooksInvoicePublicationRecovery.publicationInputs(
            for: localOnly,
            catalogItems: [item],
            payments: [localPayment]
        )
        #expect(localInputs.lines.count == 1)
    }

    @Test func catalogItemRetainsQuickBooksPublishStateAcrossOfflineRetries() {
        let offlineItem = Item(name: "Emergency Drain Clearing", unitPrice: 249)
        #expect(offlineItem.quickBooksCatalogSyncState == "pending")
        #expect(offlineItem.needsQuickBooksAttention == false)

        offlineItem.quickBooksSyncStatus = "needs_attention"
        offlineItem.quickBooksSyncDetail = "A QuickBooks income account must be selected."
        #expect(offlineItem.quickBooksCatalogSyncState == "needs_attention")
        #expect(offlineItem.needsQuickBooksAttention == true)

        let syncedItem = Item(quickBooksID: "QBO-ITEM-77", name: "Diagnostic Visit", unitPrice: 189)
        #expect(syncedItem.quickBooksCatalogSyncState == "synced")
        #expect(syncedItem.needsQuickBooksAttention == false)
    }

    @Test func quickBooksCatalogImportReconcilesOnlyAnUnambiguousCompatibleLocalItem() {
        let local = Item(name: "  Condenser Pad ", unitPrice: 95, sku: nil)
        let exactSKU = Item(name: "Filter", unitPrice: 42, sku: "MERV-11")
        let conflictingSKU = Item(name: "Filter", unitPrice: 45, sku: "MERV-13")

        #expect(
            Item.matchingLocalCatalogItem(
                in: [local],
                quickBooksID: "QBO-42",
                name: "condenser pad",
                sku: "CP-36"
            ) === local
        )
        #expect(
            Item.matchingLocalCatalogItem(
                in: [exactSKU, conflictingSKU],
                quickBooksID: "QBO-43",
                name: "Filter",
                sku: "MERV-11"
            ) === exactSKU
        )
        #expect(
            Item.matchingLocalCatalogItem(
                in: [exactSKU, conflictingSKU],
                quickBooksID: "QBO-44",
                name: "Filter",
                sku: nil
            ) == nil
        )
    }

    @Test func changeOrderKeepsOriginalApprovalAndIdentifiesTheRevisedProposal() async throws {
        let customer = Customer(name: "Change Order Customer")
        let approvedAt = Date(timeIntervalSinceReferenceDate: 72_000)
        let original = Estimate(customer: customer, amount: 4_200)
        original.recordCustomerApproval(by: "Jordan Customer", at: approvedAt)

        let revision = Estimate(
            serviceCallID: UUID(),
            parentEstimateID: original.id,
            changeOrderReason: "Condenser pad and disconnect require replacement.",
            customer: customer,
            amount: 4_780
        )

        #expect(original.hasRecordedCustomerApproval)
        #expect(original.customerApprovedAt == approvedAt)
        #expect(revision.isChangeOrder)
        #expect(revision.proposalLabel == "Change Order")
        #expect(revision.parentEstimateID == original.id)
        #expect(revision.changeOrderReason == "Condenser pad and disconnect require replacement.")
        #expect(!revision.hasRecordedCustomerApproval)
    }

    @Test func proposalOptionKeepsAStableGroupAndRecommendationMetadata() async throws {
        let customer = Customer(name: "Proposal Customer")
        let groupID = UUID()
        let better = Estimate(
            proposalGroupID: groupID,
            proposalOption: EstimateProposalOption.better.rawValue,
            proposalIsRecommended: true,
            customer: customer,
            amount: 7_500
        )

        #expect(better.isProposalOption)
        #expect(better.proposalGroupID == groupID)
        #expect(better.proposalOptionKind == .better)
        #expect(better.proposalOptionDisplayName == "Better")
        #expect(better.proposalOptionDisplayDetail == "Better • Recommended")
        #expect(better.proposalLabel == "Better")
        #expect(EstimateProposalOption.good.comparisonRank < EstimateProposalOption.better.comparisonRank)
        #expect(EstimateProposalOption.better.comparisonRank < EstimateProposalOption.best.comparisonRank)
    }

    @Test func onlineServiceRequestKeepsServerIdentitySeparateFromScheduledJobIdentity() async throws {
        let backendID = "online-request-42"
        let request = ServiceRequest(
            backendRequestID: backendID,
            customerName: "Online Booking Customer",
            phone: "555-0100",
            requestedServiceType: .maintenance,
            urgency: .priority,
            summary: "Schedule fall maintenance"
        )

        #expect(request.backendRequestID == backendID)
        #expect(request.status == .new)
        #expect(request.canSchedule == false)
        request.status = .qualified
        #expect(request.canSchedule)
        request.markScheduled(customerID: UUID(), serviceCallID: UUID())
        #expect(request.status == .scheduled)
        #expect(request.backendRequestID == backendID)
    }

    @Test func maintenanceAgreementPreservesTermPricingAndCoveredEquipmentScope() async throws {
        let customer = Customer(name: "Agreement Customer")
        let equipmentID = UUID()
        let termEnd = Date(timeIntervalSinceNow: 60 * 60 * 24 * 20)
        let contract = RecurringMaintenanceContract(
            customer: customer,
            planName: "Comfort Plus",
            schedulePattern: "Every 6 months",
            nextDate: Date(timeIntervalSinceNow: 60 * 60 * 24 * 5),
            termEndsOn: termEnd,
            pricePerVisit: 89,
            includedVisitsPerTerm: 2,
            renewalReminderDays: 30,
            coveredEquipmentIDs: [equipmentID]
        )

        #expect(contract.displayName == "Comfort Plus")
        #expect(contract.coveredEquipmentIDs == [equipmentID])
        #expect(contract.pricePerVisit == 89)
        #expect(contract.includedVisitsPerTerm == 2)
        #expect(contract.needsRenewalAttention)
        #expect(contract.canScheduleVisit)

        contract.updateCoveredEquipmentIDs([])
        #expect(contract.coveredEquipmentIDs.isEmpty)
    }

    @MainActor
    @Test func maintenanceAgreementVisitRemainsDueUntilCompletionAndAdvancesOnlyOnce() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let dueDate = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 9)))
        let customer = Customer(name: "Traceable Agreement Customer")
        let contract = RecurringMaintenanceContract(
            customer: customer,
            planName: "Comfort Care",
            schedulePattern: "Every 6 months",
            nextDate: dueDate,
            includedVisitsPerTerm: 2
        )
        customer.recurringContracts = [contract]
        let call = ServiceCall(
            type: .maintenance,
            scheduledDate: dueDate,
            customer: customer,
            status: .scheduled,
            maintenanceAgreementID: contract.id,
            maintenanceAgreementDueDate: dueDate
        )

        #expect(contract.scheduledVisit(forDueDate: dueDate, in: [call], calendar: calendar)?.id == call.id)
        #expect(contract.nextDate == dueDate)
        #expect(!call.completeLinkedMaintenanceAgreementIfNeeded())

        call.status = .completed
        #expect(call.completeLinkedMaintenanceAgreementIfNeeded())
        let expectedNextDate = try #require(calendar.date(byAdding: .month, value: 6, to: dueDate))
        #expect(contract.nextDate == expectedNextDate)
        #expect(!call.completeLinkedMaintenanceAgreementIfNeeded())

        let schema = GunnAireModelSchema.schema
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)]
        )
        let context = ModelContext(container)
        context.insert(customer)
        context.insert(contract)
        context.insert(call)
        try context.save()

        let persistedCall = try #require(try context.fetch(FetchDescriptor<ServiceCall>()).first { $0.id == call.id })
        #expect(persistedCall.maintenanceAgreementID == contract.id)
        #expect(persistedCall.maintenanceAgreementDueDate == dueDate)
    }

    @MainActor
    @Test func storedQuickBooksPaymentMethodKeepsOnlySafeCustomerScopedMetadata() throws {
        let cardJSON = Data("""
        {
          "id": "card-42",
          "name": "Agreement Customer",
          "cardType": "Visa",
          "number": "4111111111114242",
          "expMonth": "12",
          "expYear": "2030"
        }
        """.utf8)
        let providerCard = try JSONDecoder().decode(QuickBooksPaymentsCardRecord.self, from: cardJSON)
            .associated(withCustomerID: "qbo-customer-42")
        let reference = try #require(providerCard.storedPaymentMethodReference())

        #expect(providerCard.safeLastFour == "4242")
        #expect(providerCard.safeDisplayLabel == "Visa •••• 4242")
        #expect(reference.displayLabel == "Visa •••• 4242")
        #expect(reference.providerCustomerID == "qbo-customer-42")

        let customer = Customer(quickBooksID: "qbo-customer-42", name: "Agreement Customer")
        customer.upsertStoredPaymentMethod(reference)

        #expect(customer.activeStoredPaymentMethods.count == 1)
        #expect(customer.activeStoredPaymentMethods[0].lastFour == "4242")
        #expect(customer.storedPaymentMethodsJSON?.contains("4111111111114242") == false)
        #expect(customer.storedPaymentMethodsJSON?.localizedCaseInsensitiveContains("cvc") == false)

        let schema = GunnAireModelSchema.schema
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)]
        )
        let context = ModelContext(container)
        context.insert(customer)
        try context.save()

        let persisted = try #require(try context.fetch(FetchDescriptor<Customer>()).first)
        #expect(persisted.activeStoredPaymentMethods.first?.displayLabel == "Visa •••• 4242")

        persisted.reconcileQuickBooksStoredPaymentMethods([], providerCustomerID: "qbo-customer-42")
        #expect(persisted.activeStoredPaymentMethods.isEmpty)
        #expect(persisted.storedPaymentMethods.first?.active == false)
    }

    @Test func reusableFieldFormKeepsItsTemplateSnapshotAndJobLink() async throws {
        let customer = Customer(name: "Form Customer")
        let call = ServiceCall(type: .install, scheduledDate: Date(), customer: customer)
        let question = FieldFormQuestion(label: "Start-up confirmed", kind: .toggle, required: true)
        let template = FieldFormTemplate(
            title: "Install Commissioning",
            questions: [question],
            applicableServiceTypes: [.install]
        )
        let response = FieldFormResponse(
            serviceCallID: call.id,
            template: template,
            answers: [question.id: "true"],
            completedByEmail: "tech@gunnaire.com"
        )

        #expect(template.applies(to: .install))
        #expect(!template.applies(to: .maintenance))
        #expect(response.serviceCallID == call.id)
        #expect(response.templateTitle == "Install Commissioning")
        #expect(response.answers[question.id] == "true")
    }

    @MainActor
    @Test func jobActivityRetainsTheOperationalHandoffWithoutCustomerMessageContent() throws {
        let schema = GunnAireModelSchema.schema
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)]
        )
        let context = ModelContext(container)
        let customer = Customer(name: "Activity Customer")
        let call = ServiceCall(type: .service, scheduledDate: Date(), customer: customer)
        context.insert(customer)
        context.insert(call)

        ServiceCallActivity.record(
            for: call,
            action: "Technician assigned",
            detail: "Assigned to Taylor Technician.",
            actorEmail: "dispatch@example.com",
            in: context
        )
        try context.save()

        let activities = try context.fetch(FetchDescriptor<ServiceCallActivity>())
        let activity = try #require(activities.first)
        #expect(activity.serviceCallID == call.id)
        #expect(activity.action == "Technician assigned")
        #expect(activity.detail == "Assigned to Taylor Technician.")
        #expect(activity.actorEmail == "dispatch@example.com")
    }

    @MainActor
    @Test func businessReportingProducesTraceableSalesOperationsAndCostMetrics() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 26, hour: 12)))
        let reportDate = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 9)))
        let customer = Customer(name: "Reporting Customer")
        let technician = Technician(name: "Reporting Technician", contactInfo: "reporting-tech@gunnaire.com", laborCostPerHour: 60)
        let completedCall = ServiceCall(
            type: .service,
            scheduledDate: reportDate,
            assignedTechnician: technician,
            customer: customer,
            status: .completed,
            visitDisposition: .callback,
            workCompletedChecklist: true,
            documentationChecklist: true
        )
        let acceptedEstimate = Estimate(customer: customer, amount: 1_000, status: "accepted", createdAt: reportDate)
        let declinedEstimate = Estimate(customer: customer, amount: 800, status: "rejected", createdAt: reportDate.addingTimeInterval(60))
        let item = Item(name: "Reporting Repair", unitPrice: 300, purchaseCost: 100, createdAt: reportDate)
        let invoice = Invoice(serviceCallID: completedCall.id, customer: customer, amount: 600, createdAt: reportDate)
        invoice.catalogSnapshotJSON = CatalogLineItemSnapshot.encoded(from: [item], quantities: [item.id: 2])
        let payment = Payment(invoice: invoice, amount: 250, date: reportDate.addingTimeInterval(3_600))
        let timeEntry = TimeEntry(
            userEmail: "reporting-tech@gunnaire.com",
            clockIn: reportDate,
            clockOut: reportDate.addingTimeInterval(7_200),
            serviceCall: completedCall
        )

        let snapshot = BusinessReporting.snapshot(
            period: .currentMonth,
            now: now,
            serviceCalls: [completedCall],
            estimates: [acceptedEstimate, declinedEstimate],
            invoices: [invoice],
            payments: [payment],
            timeEntries: [timeEntry],
            technicians: [technician],
            calendar: calendar
        )

        #expect(snapshot.invoicedRevenue == 600)
        #expect(snapshot.collectedRevenue == 250)
        #expect(snapshot.openBalance == 350)
        #expect(snapshot.estimateCount == 2)
        #expect(snapshot.acceptedEstimateCount == 1)
        #expect(snapshot.estimateConversionRate == 0.5)
        #expect(snapshot.completedJobCount == 1)
        #expect(snapshot.correctiveVisitCount == 1)
        #expect(snapshot.correctiveVisitRate == 1)
        #expect(snapshot.materialCost == 200)
        #expect(snapshot.laborCost == 120)
        #expect(snapshot.missingLaborTrackingJobCount == 0)
        #expect(snapshot.knownGrossProfit == 280)
        #expect(abs((snapshot.knownGrossMargin ?? 0) - (280.0 / 600.0)) < 0.0001)
        #expect(snapshot.costCoverageComplete)
        #expect(snapshot.technicianRows.first?.recordedHours == 2)
        #expect(snapshot.technicianRows.first?.completedJobs == 1)
        let csv = BusinessReportCSV.render(snapshot)
        #expect(csv.contains("Data Source,Current GunnAire operational records"))
        #expect(csv.contains("Inclusion Rules,"))
        #expect(csv.contains("Reporting Technician,1,2.00,120.00,0"))
    }

    @MainActor
    @Test func businessReportingHidesProfitWhenMaterialOrLaborCostCoverageIsIncomplete() {
        let now = Date()
        let customer = Customer(name: "Incomplete Cost Customer")
        let technician = Technician(name: "Uncosted Technician", contactInfo: "uncosted@gunnaire.com")
        let call = ServiceCall(
            type: .service,
            scheduledDate: now.addingTimeInterval(-3_600),
            assignedTechnician: technician,
            customer: customer,
            status: .completed
        )
        let invoice = Invoice(serviceCallID: call.id, customer: customer, amount: 200, createdAt: now.addingTimeInterval(-3_000))
        let timeEntry = TimeEntry(
            userEmail: "uncosted@gunnaire.com",
            clockIn: now.addingTimeInterval(-3_600),
            clockOut: now,
            serviceCall: call
        )

        let snapshot = BusinessReporting.snapshot(
            period: .currentMonth,
            now: now,
            serviceCalls: [call],
            estimates: [],
            invoices: [invoice],
            payments: [],
            timeEntries: [timeEntry],
            technicians: [technician]
        )

        #expect(snapshot.missingMaterialCostLineCount == 1)
        #expect(snapshot.uncostedLaborMinutes == 60)
        #expect(!snapshot.costCoverageComplete)
        #expect(snapshot.knownGrossProfit == nil)
        #expect(snapshot.knownGrossMargin == nil)
        #expect(BusinessReportCSV.render(snapshot).contains("Incomplete cost coverage"))

        let noTimeSnapshot = BusinessReporting.snapshot(
            period: .currentMonth,
            now: now,
            serviceCalls: [call],
            estimates: [],
            invoices: [invoice],
            payments: [],
            timeEntries: [],
            technicians: [technician]
        )
        #expect(noTimeSnapshot.missingLaborTrackingJobCount == 1)
        #expect(!noTimeSnapshot.costCoverageComplete)
    }

}
