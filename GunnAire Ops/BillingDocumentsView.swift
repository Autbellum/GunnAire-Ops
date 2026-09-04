import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers

struct BillingDocumentsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.modelContext) private var modelContext
    @Environment(\.gunnaireReduceMotion) private var reduceMotion
    @ObservedObject private var accountingConfigurationStore = QuickBooksAccountingConfigurationStore.shared
    @Query(sort: \Customer.name, order: .forward) private var customers: [Customer]
    @Query(sort: \Item.name, order: .forward) private var items: [Item]
    @Query(sort: \Vendor.name, order: .forward) private var vendors: [Vendor]
    @Query(sort: \ServiceCall.scheduledDate, order: .reverse) private var serviceCalls: [ServiceCall]
    @Query(sort: \Invoice.createdAt, order: .reverse) private var invoices: [Invoice]
    @Query(sort: \Estimate.createdAt, order: .reverse) private var estimates: [Estimate]
    @Query(sort: \Payment.date, order: .reverse) private var payments: [Payment]
    @Query(sort: \TimeEntry.clockIn, order: .reverse) private var timeEntries: [TimeEntry]
    @Query(sort: \ServiceDocumentAttachment.createdAt, order: .reverse) private var attachments: [ServiceDocumentAttachment]
    @Query(sort: \FieldFormTemplate.createdAt, order: .forward) private var fieldFormTemplates: [FieldFormTemplate]
    @Query(sort: \FieldFormResponse.completedAt, order: .reverse) private var fieldFormResponses: [FieldFormResponse]
    @Query(sort: \ServiceCallActivity.occurredAt, order: .reverse) private var serviceCallActivities: [ServiceCallActivity]
    @Query(sort: \CustomerEquipment.name, order: .forward) private var equipmentProfiles: [CustomerEquipment]
    @Query(sort: \CustomerServiceLocation.name, order: .forward) private var serviceLocations: [CustomerServiceLocation]
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]
    @Query(sort: \Technician.name, order: .forward) private var technicians: [Technician]
    @Query(sort: \InventoryMovement.createdAt, order: .reverse) private var inventoryMovements: [InventoryMovement]
    @Query(sort: \PurchaseOrder.updatedAt, order: .reverse) private var purchaseOrders: [PurchaseOrder]
    @Query(sort: \ProjectMilestone.plannedDate, order: .forward) private var projectMilestones: [ProjectMilestone]
    @Query(sort: \RecurringMaintenanceContract.nextDate, order: .forward) private var maintenanceAgreements: [RecurringMaintenanceContract]
    @Query(sort: \CustomerOperationalAlert.createdAt, order: .reverse) private var operationalAlerts: [CustomerOperationalAlert]
    @AppStorage("defaultInvoicePaymentTerms") private var defaultInvoicePaymentTermsRawValue = InvoicePaymentTerms.dueOnReceipt.rawValue
    @AppStorage("requireJobCompletionChecklist") private var requireJobCompletionChecklist = true
    @AppStorage("requireWorkPerformedLogForCloseout") private var requireWorkPerformedLogForCloseout = true

    private let initialServiceCall: ServiceCall?
    private let openCloseoutOnAppear: Bool
    private let openTapToPayOnAppear: Bool
    private let showsDismissButton: Bool
    private let dismissButtonTitle: String
    private let liveAPI = QuickBooksDataAPI.shared
    private let googleAuth = GoogleAuthManager.shared
    private let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    @State private var selectedDocumentKind: BillingDocumentKind
    @State private var invoiceWorkspaceLane: InvoiceWorkspaceLane = .overview
    @State private var selectedJobStage: JobDocumentationStage = .work
    @State private var selectedCustomerID: UUID?
    @State private var selectedServiceLocationID: UUID?
    @State private var loadedSiteAddressSnapshot: String?
    @State private var loadedSiteAddressCustomerID: UUID?
    @State private var selectedItems: Set<UUID> = []
    @State private var notes = ""
    @State private var changeOrderParentEstimateID: UUID?
    @State private var changeOrderReason = ""
    @State private var proposalGroupID: UUID?
    @State private var proposalOption: EstimateProposalOption = .standalone
    @State private var proposalIsRecommended = false
    @State private var customerSearchText = ""
    @State private var customerName = ""
    @State private var customerPhone = ""
    @State private var customerEmail = ""
    @State private var customerAddress = ""
    @State private var itemSearchText = ""
    @State private var catalogFilter: DocumentationCatalogFilter = .recommended
    @State private var newlyCreatedLineItems: [UUID: Item] = [:]
    @State private var documentScopedReviewItemIDs: Set<UUID> = []
    @State private var selectedItemQuantities: [UUID: Double] = [:]
    @State private var selectedItemPriceAdjustments: [UUID: AuthorizedLinePriceAdjustment] = [:]
    @State private var selectedDocumentDiscount: AuthorizedDocumentDiscount?
    @State private var selectedItemEquipmentIDs: [UUID: UUID] = [:]
    @State private var selectedItemAssemblySnapshots: [UUID: CatalogLineAssemblySnapshot] = [:]
    @State private var selectedItemizedAssemblyMemberships: [UUID: Set<UUID>] = [:]
    @State private var selectedInvoicePaymentTerms: InvoicePaymentTerms = .dueOnReceipt
    @State private var invoiceCustomDueDate = Calendar.current.startOfDay(for: Date())
    @State private var itemPendingPriceAdjustment: Item?
    @State private var showingDocumentDiscountEditor = false
    @State private var newItemName = ""
    @State private var newItemType: CatalogItemType = .service
    @State private var newItemSKU = ""
    @State private var newItemDescription = ""
    @State private var newItemPrice = ""
    @State private var newItemCost = ""
    @State private var newItemPreferredVendor = ""
    @State private var newItemVendorPartNumber = ""
    @State private var newItemPurchaseURL = ""
    @State private var newItemPurchaseDescription = ""
    @State private var newItemTaxable = false
    @State private var actionMessage = ""
    @State private var isCreatingDocument = false
    @State private var isImportingQuickBooksItems = false
    @State private var syncingEstimateIDs: Set<UUID> = []
    @State private var didLoadInitialContext = false
    @State private var didAttemptInitialCatalogImport = false
    @State private var openInvoiceAfterEstimateCreation = false
    @State private var didLoadLinkedDocumentContext = false
    @State private var pendingIntentServiceCallID: UUID?
    @State private var showingItemSelector = false
    @State private var showingItemCreator = false
    @State private var selectedInvoiceForEditingID: UUID?
    @State private var selectedInvoiceForCloseout: Invoice?
    @State private var selectedEstimateForApproval: Estimate?
    @State private var selectedEstimateForScheduling: Estimate?
    @State private var selectedEstimateForFinancing: Estimate?
    @State private var customerFinancingReadiness: CustomerFinancingReadiness?
    @State private var isLoadingCustomerFinancingReadiness = false
    @State private var showingProjectPlanSetup = false
    @State private var milestonePendingScheduling: ProjectMilestone?
    @State private var milestonePendingCompletion: ProjectMilestone?
    @State private var milestonePendingInvoice: ProjectMilestone?
    @State private var agreementBillingCandidatePendingReview: MaintenanceAgreementBillingCandidate?
    @State private var agreementBillingSetupPending: RecurringMaintenanceContract?
    @State private var didResolveInitialCloseoutRequest = false
    @State private var generatedCustomerDocumentURL: URL?
    @State private var generatedCustomerDocumentRecipientID: UUID?
    @State private var generatedCustomerDocumentServiceCallID: UUID?
    @State private var generatedCustomerDocumentInvoiceID: UUID?
    @State private var generatedCustomerDocumentEstimateID: UUID?
    @State private var generatedCustomerDocumentKind = "document"
    @State private var isEmailingGeneratedDocument = false
    @State private var showingDocumentationFileImporter = false
    @State private var showingDocumentationCamera = false
    @State private var attachmentKind: ServiceDocumentAttachmentKind = .diagnosticPhoto
    @State private var attachmentCaption = ""
    @State private var attachmentSearchText = ""
    @State private var attachmentMessage: String?
    @State private var attachmentPreviewURL: URL?
    @State private var attachmentPendingMarkup: ServiceDocumentAttachment?
    @State private var sharedJobDocuments: [BackendDocumentRecord] = []
    @State private var sharedJobDocumentsMessage: String?
    @State private var isLoadingSharedJobDocuments = false
    @State private var downloadingSharedJobDocumentID: String?
    @State private var materialSourceByItemID: [UUID: String] = [:]
    @State private var jobMaterialMessage: String?
    private let workspaceMode: BillingWorkspaceMode

    init(
        initialServiceCall: ServiceCall? = nil,
        workspaceMode: BillingWorkspaceMode = .all,
        openCloseoutOnAppear: Bool = false,
        openTapToPayOnAppear: Bool = false,
        showsDismissButton: Bool = false,
        dismissButtonTitle: String = "Minimize"
    ) {
        self.initialServiceCall = initialServiceCall
        self.openCloseoutOnAppear = openCloseoutOnAppear
        self.openTapToPayOnAppear = openTapToPayOnAppear
        self.showsDismissButton = showsDismissButton
        self.dismissButtonTitle = dismissButtonTitle
        self.workspaceMode = workspaceMode
        let initialKind: BillingDocumentKind
        if let initialServiceCall {
            initialKind = initialServiceCall.type == .estimate ? .estimate : .invoice
        } else {
            initialKind = workspaceMode.defaultDocumentKind
        }
        _selectedDocumentKind = State(initialValue: initialKind)
    }

    private var activeServiceCall: ServiceCall? {
        if let initialServiceCall {
            return AppAccess.canAccessServiceCall(
                initialServiceCall,
                email: currentUserEmail,
                users: users,
                serviceCalls: serviceCalls,
                technicians: technicians
            ) ? initialServiceCall : nil
        }
        guard let pendingIntentServiceCallID else { return nil }
        guard let call = serviceCalls.first(where: { $0.id == pendingIntentServiceCallID }) else { return nil }
        return AppAccess.canAccessServiceCall(
            call,
            email: currentUserEmail,
            users: users,
            serviceCalls: serviceCalls,
            technicians: technicians
        ) ? call : nil
    }

    private var selectedGrossSubtotal: Double {
        selectedLineItems.reduce(0) { $0 + effectiveUnitPrice(for: $1) * lineItemQuantity(for: $1) }
    }

    private var selectedDiscountAmount: Double? {
        selectedDocumentDiscount?.amount(for: selectedGrossSubtotal)
    }

    private var selectedTotal: Double {
        max(
            BillingDocumentDiscountPolicy.roundCurrency(
                selectedGrossSubtotal - (selectedDiscountAmount ?? 0)
            ),
            0
        )
    }

    private var documentDiscountValidationMessage: String? {
        BillingDocumentDiscountPolicy.validationMessage(
            for: selectedDocumentDiscount,
            grossSubtotal: selectedGrossSubtotal
        )
    }

    private var selectedHasTaxableLines: Bool {
        selectedLineItems.contains(where: \.isTaxable)
    }

    private var selectedCustomer: Customer? {
        guard let selectedCustomerID else { return nil }
        return customers.first { $0.id == selectedCustomerID }
    }

    private var activeServiceLocations: [CustomerServiceLocation] {
        guard let customer = selectedCustomer ?? activeServiceCall?.customer else { return [] }
        return CustomerServiceLocationPolicy.locations(for: customer.id, in: serviceLocations)
    }

    private var selectedServiceLocation: CustomerServiceLocation? {
        guard let customer = selectedCustomer ?? activeServiceCall?.customer else { return nil }
        return CustomerServiceLocationPolicy.location(
            id: selectedServiceLocationID,
            customerID: customer.id,
            in: serviceLocations,
            includeInactive: true
        )
    }

    private var selectableServiceLocations: [CustomerServiceLocation] {
        guard let selectedServiceLocation,
              !selectedServiceLocation.isActive,
              !activeServiceLocations.contains(where: { $0.id == selectedServiceLocation.id }) else {
            return activeServiceLocations
        }
        return activeServiceLocations + [selectedServiceLocation]
    }

    private var serviceLocationSelection: Binding<UUID?> {
        Binding(
            get: { selectedServiceLocationID },
            set: { newValue in
                selectedServiceLocationID = newValue
                loadedSiteAddressSnapshot = nil
                loadedSiteAddressCustomerID = nil
            }
        )
    }

    private var selectedSiteAddressSnapshot: String? {
        let candidate = activeServiceCall?.siteAddress
            ?? selectedServiceLocation?.address
            ?? (loadedSiteAddressCustomerID == selectedCustomer?.id ? loadedSiteAddressSnapshot : nil)
            ?? selectedCustomer?.address
            ?? customerAddress
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var generatedCustomerDocumentRecipient: Customer? {
        guard let generatedCustomerDocumentRecipientID else { return activeServiceCall?.customer ?? selectedCustomer }
        return customers.first { $0.id == generatedCustomerDocumentRecipientID } ?? activeServiceCall?.customer ?? selectedCustomer
    }

    private var filteredCustomers: [Customer] {
        let query = customerSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return customers }
        return customers.filter { customer in
            customer.name.lowercased().contains(query) ||
            (customer.phone?.lowercased().contains(query) ?? false) ||
            (customer.email?.lowercased().contains(query) ?? false) ||
            (customer.address?.lowercased().contains(query) ?? false)
        }
    }

    private var customerDropdownOptions: [SearchableDropdownOption] {
        customers
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { customer in
                let subtitle = [
                    customer.phone,
                    customer.email,
                    customer.address
                ]
                .compactMap { value in
                    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed?.isEmpty == false ? trimmed : nil
                }
                .joined(separator: " • ")
                return SearchableDropdownOption(
                    id: customer.id.uuidString,
                    title: customer.name,
                    subtitle: subtitle.isEmpty ? nil : subtitle
                )
            }
    }

    private var selectedCustomerDropdownID: Binding<String?> {
        Binding(
            get: { selectedCustomerID?.uuidString },
            set: { selectedCustomerID = $0.flatMap(UUID.init(uuidString:)) }
        )
    }

    private var newItemVendorDropdownOptions: [SearchableDropdownOption] {
        CatalogVendorSelection.options(for: vendors)
    }

    private var selectedNewItemVendorDropdownID: Binding<String?> {
        Binding(
            get: {
                CatalogVendorSelection.selectedVendorID(
                    vendorName: newItemPreferredVendor,
                    vendors: vendors
                )
            },
            set: { selectedID in
                guard let selectedID else {
                    newItemPreferredVendor = ""
                    return
                }
                if let vendor = vendors.first(where: { $0.id.uuidString == selectedID }) {
                    newItemPreferredVendor = vendor.name
                }
            }
        )
    }

    private var selectedLineItems: [Item] {
        var selectedByID: [UUID: Item] = [:]
        for item in items where selectedItems.contains(item.id) {
            selectedByID[item.id] = item
        }
        for item in newlyCreatedLineItems.values where selectedItems.contains(item.id) {
            selectedByID[item.id] = item
        }
        return Array(selectedByID.values)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var documentEquipmentProfiles: [CustomerEquipment] {
        guard let customerID = contextCustomer?.id else { return [] }
        return equipmentProfiles
            .filter { $0.customer?.id == customerID && $0.isActive }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var documentEquipmentSnapshots: [CatalogLineEquipmentSnapshot] {
        documentEquipmentProfiles.map { CatalogLineEquipmentSnapshot(equipment: $0) }
    }

    private var defaultDocumentEquipmentID: UUID? {
        if let activeEquipmentProfile,
           documentEquipmentProfiles.contains(where: { $0.id == activeEquipmentProfile.id }) {
            return activeEquipmentProfile.id
        }
        return documentEquipmentProfiles.count == 1 ? documentEquipmentProfiles.first?.id : nil
    }

    private var selectedLineEquipmentSnapshots: [UUID: CatalogLineEquipmentSnapshot] {
        CatalogLineEquipmentAssignmentPolicy.resolvedSnapshots(
            assignments: selectedItemEquipmentIDs,
            selectedItemIDs: selectedItems,
            available: documentEquipmentSnapshots
        )
    }

    private var selectedLineItemOverflowLabel: String {
        let overflowCount = max(0, selectedLineItems.count - 5)
        let noun = overflowCount == 1 ? "line item" : "line items"
        return "\(overflowCount) more selected \(noun)"
    }

    private var customerSelectionDisplayName: String {
        customerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Not selected"
            : customerName
    }

    private var laborCostAvailabilityMessage: String {
        activeServiceCall == nil ? "No job linked" : "Set a technician rate and complete time"
    }

    private var grossProfitLabel: String {
        selectedLaborCost == nil ? "Gross Profit (materials only)" : "Gross Profit"
    }

    private func uncostedLaborDescription(_ minuteCount: Int) -> String {
        let noun = minuteCount == 1 ? "minute" : "minutes"
        return "\(minuteCount) completed labor \(noun) excluded until that technician has an internal labor rate."
    }

    private func customerActivitySummary(_ customer: Customer) -> String {
        if canViewFinancials {
            return "\(customer.serviceCalls.count) jobs - \(customer.invoices.count) invoices - \(customer.activeContractsCount) active agreements"
        }
        return "\(customer.serviceCalls.count) jobs - \(customer.activeContractsCount) active agreements"
    }

    private func serviceLocationOptionTitle(_ location: CustomerServiceLocation) -> String {
        location.isActive ? location.displayName : "\(location.displayName) (inactive)"
    }

    private func adjustPriceAccessibilityID(for item: Item) -> String {
        "AdjustPrice-\(item.id.uuidString)"
    }

    private func authorizedPriceAdjustmentAccessibilityID(for item: Item) -> String {
        "AuthorizedPriceAdjustment-\(item.id.uuidString)"
    }

    private func authorizedPriceAdjustmentAccessibilityLabel(for item: Item) -> String {
        "Authorized price adjustment for \(item.name)"
    }

    private func lineItemQuantityLabel(for item: Item) -> String {
        "Qty \(lineItemQuantityAccessibilityValue(for: item))"
    }

    private func lineItemQuantityAccessibilityLabel(for item: Item) -> String {
        "Quantity for \(item.name)"
    }

    private func lineItemQuantityAccessibilityValue(for item: Item) -> String {
        lineItemQuantity(for: item).formatted(.number.precision(.fractionLength(0...2)))
    }

    private func paymentDisplayDetail(_ payment: Payment) -> String {
        let date = payment.date.formatted(date: .abbreviated, time: .shortened)
        return "\(payment.methodSummary) - \(date)"
    }

    private func serviceCallSummaryLine(_ call: ServiceCall) -> String {
        "\(call.type.displayName) • \(call.status.rawValue.capitalized)"
    }

    private func estimateAmountStatus(_ estimate: Estimate) -> String {
        "\(estimate.amount.formatted(.currency(code: "USD"))) • \(estimate.status.capitalized)"
    }

    private func estimateApprovalDetail(_ estimate: Estimate, approvedAt: Date) -> String {
        let approver = estimate.customerApprovedByName ?? estimate.customer.name
        let timestamp = approvedAt.formatted(date: .abbreviated, time: .shortened)
        return "Customer approval: \(approver) • \(timestamp)"
    }

    private func invoiceAmountStatus(_ invoice: Invoice) -> String {
        "\(invoice.amount.formatted(.currency(code: "USD"))) • \(invoiceDisplayStatus(for: invoice))"
    }

    private func paymentFinancialDetail(_ payment: Payment) -> String {
        let amount = payment.amount.formatted(.currency(code: "USD"))
        let timestamp = payment.date.formatted(date: .abbreviated, time: .shortened)
        return "\(amount) • \(payment.methodSummary) • \(timestamp)"
    }

    private func documentServiceAddressDetail(_ address: String) -> String {
        "\(selectedDocumentKind.rawValue) service address: \(address)"
    }

    private func estimateListDetail(_ estimate: Estimate) -> String {
        let timestamp = estimate.createdAt.formatted(date: .abbreviated, time: .shortened)
        return "\(estimate.status.capitalized) - \(timestamp)"
    }

    private func invoiceListDetail(_ invoice: Invoice) -> String {
        let due = invoice.effectiveDueDate().formatted(date: .abbreviated, time: .omitted)
        return "\(invoiceDisplayStatus(for: invoice)) • Due \(due)"
    }

    private var selectedCostTotal: Double {
        selectedLineItems.reduce(0) { partial, item in
            let unitCost = selectedItemAssemblySnapshots[item.id]?.presentation == .flatRate
                ? (selectedItemAssemblySnapshots[item.id]?.unitPurchaseCost ?? item.purchaseCost ?? 0)
                : (item.purchaseCost ?? 0)
            return partial + unitCost * lineItemQuantity(for: item)
        }
    }

    private var selectedLaborCosting: JobLaborCosting.Summary? {
        guard let serviceCall = activeServiceCall else { return nil }
        let entries = timeEntries.filter { $0.serviceCall?.id == serviceCall.id }
        return JobLaborCosting.summary(entries: entries, technicians: technicians)
    }

    private var selectedLaborCost: Double? {
        selectedLaborCosting?.totalCost
    }

    private var selectedJobCostTotal: Double {
        selectedCostTotal + (selectedLaborCost ?? 0)
    }

    private var selectedGrossProfit: Double {
        selectedTotal - selectedJobCostTotal
    }

    private var selectedGrossMarginPercent: Double? {
        guard selectedTotal > 0 else { return nil }
        return (selectedGrossProfit / selectedTotal) * 100
    }

    private var selectedCatalogSnapshotJSON: String? {
        CatalogLineItemSnapshot.encoded(
            from: selectedLineItems,
            quantities: selectedItemQuantities,
            priceAdjustments: selectedItemPriceAdjustments,
            servicedEquipment: selectedLineEquipmentSnapshots,
            assemblies: selectedItemAssemblySnapshots,
            documentDiscount: selectedDocumentDiscount
        )
    }

    private var jobMaterialRequirements: [JobMaterialRequirement] {
        guard let activeServiceCall else { return [] }
        return JobMaterialCloseoutPolicy.requirements(
            for: activeServiceCall,
            invoice: currentJobInvoice,
            estimates: estimates,
            projectMilestones: projectMilestones,
            items: items,
            movements: inventoryMovements
        )
    }

    private var jobMaterialCloseoutSummary: JobMaterialCloseoutSummary {
        guard let activeServiceCall else { return .notApplicable }
        return JobMaterialCloseoutPolicy.summary(
            for: activeServiceCall,
            invoice: currentJobInvoice,
            estimates: estimates,
            projectMilestones: projectMilestones,
            items: items,
            movements: inventoryMovements
        )
    }

    private func itemHasInventoryLedger(_ item: Item) -> Bool {
        item.itemType == .nonInventory ||
            item.tracksInventory ||
            inventoryMovements.contains { $0.itemID == item.id }
    }

    private var filteredItems: [Item] {
        let query = itemSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return items.filter { item in
            let haystack = [
                item.name,
                item.sku,
                item.itemDescription,
                item.preferredVendorName,
                item.vendorPartNumber,
                item.purchaseDescription
            ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
            let matchesQuery = query.isEmpty || haystack.contains(query)
            let canDisplay = CatalogItemSelectionPolicy.canDisplay(
                item,
                isSelected: isCatalogItemSelected(item),
                documentScopedReviewItemIDs: documentScopedReviewItemIDs
            )
            return canDisplay && matchesQuery && matchesCatalogFilter(item)
        }
    }

    private var builderItemResults: [Item] {
        Array(filteredItems.prefix(8))
    }

    private var canAddInlineItem: Bool {
        !newItemName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        CatalogItemAmountParser.parseRequiredOrZero(newItemPrice) != nil &&
        CatalogItemAmountParser.isValidOptionalAmount(newItemCost)
    }

    private var catalogItemsAwaitingReview: [Item] {
        items.filter(\.requiresPricebookReview)
    }

    private var currentJobEstimate: Estimate? {
        guard let estimateID = activeServiceCall?.linkedEstimateID else { return nil }
        return estimates.first { $0.id == estimateID }
    }

    private var currentJobInvoice: Invoice? {
        if let activeServiceCall {
            guard let invoiceID = activeServiceCall.linkedInvoiceID else { return nil }
            return invoices.first { $0.id == invoiceID }
        }
        guard let selectedInvoiceForEditingID else { return nil }
        return invoices.first { $0.id == selectedInvoiceForEditingID }
    }

    private var configuredDefaultInvoicePaymentTerms: InvoicePaymentTerms {
        let stored = InvoicePaymentTerms(rawValue: defaultInvoicePaymentTermsRawValue) ?? .dueOnReceipt
        return stored == .custom ? .dueOnReceipt : stored
    }

    private var invoiceTermsIssueDate: Date {
        currentJobInvoice?.createdAt ?? Date()
    }

    private var resolvedInvoiceDueDate: Date {
        let calendar = Calendar.current
        if selectedInvoicePaymentTerms == .custom {
            return calendar.startOfDay(for: invoiceCustomDueDate)
        }
        return selectedInvoicePaymentTerms.dueDate(
            from: invoiceTermsIssueDate,
            calendar: calendar
        ) ?? calendar.startOfDay(for: invoiceTermsIssueDate)
    }

    private var invoiceDueDateIsValid: Bool {
        resolvedInvoiceDueDate >= Calendar.current.startOfDay(for: invoiceTermsIssueDate)
    }

    private var currentProjectMilestones: [ProjectMilestone] {
        guard let serviceCallID = activeServiceCall?.id else { return [] }
        return projectMilestones
            .filter { $0.projectServiceCallID == serviceCallID }
            .sorted {
                if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
                return $0.createdAt < $1.createdAt
            }
    }

    private var projectEstimate: Estimate? {
        guard let estimateID = currentProjectMilestones.first?.estimateID ?? activeServiceCall?.linkedEstimateID else {
            return nil
        }
        return estimates.first { $0.id == estimateID }
    }

    private var currentProjectSummary: ProjectBillingSummary? {
        guard !currentProjectMilestones.isEmpty else { return nil }
        return ProjectBillingPolicy.summary(
            milestones: currentProjectMilestones,
            invoices: invoices,
            payments: payments
        )
    }

    private var currentJobPayments: [Payment] {
        guard let invoice = currentJobInvoice else { return [] }
        return payments.filter { $0.invoice.id == invoice.id }
    }

    private var invoiceMutationBlockedMessage: String? {
        guard selectedDocumentKind == .invoice, let invoice = currentJobInvoice else { return nil }
        return BillingInvoiceMutationPolicy.blockedMessage(for: invoice, payments: currentJobPayments)
    }

    private var invoiceWorkflowBlockedMessage: String? {
        if !currentProjectMilestones.isEmpty, currentJobInvoice == nil {
            return "This job uses a project billing plan. Issue each progress invoice from its approved milestone below."
        }
        if currentJobInvoice != nil {
            return invoiceMutationBlockedMessage
        }
        return activeServiceCall?.invoiceCreationBlockedMessage
    }

    private var invoiceActionTitle: String {
        if isCreatingDocument {
            return currentJobInvoice == nil ? "Creating Invoice..." : "Updating Invoice..."
        }
        return currentJobInvoice == nil ? "Create Invoice" : "Update Invoice"
    }

    private var documentActionTitle: String {
        if selectedDocumentKind == .invoice {
            return invoiceActionTitle
        }
        return isCreatingDocument ? "Creating Estimate..." : "Create Estimate"
    }

    private var documentActionIsDisabled: Bool {
        isCreatingDocument ||
            customerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            selectedItems.isEmpty ||
            documentDiscountValidationMessage != nil ||
            (selectedDocumentKind == .invoice && invoiceWorkflowBlockedMessage != nil)
    }

    private var invoiceActionIsDisabled: Bool {
        isCreatingDocument ||
            customerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            selectedItems.isEmpty ||
            documentDiscountValidationMessage != nil ||
            invoiceWorkflowBlockedMessage != nil
    }

    private var currentJobProposalOptions: [Estimate] {
        guard let serviceCallID = activeServiceCall?.id,
              let groupID = currentJobEstimate?.proposalGroupID else { return [] }
        return estimates
            .filter { $0.serviceCallID == serviceCallID && $0.proposalGroupID == groupID }
            .sorted {
                ($0.proposalOptionKind?.comparisonRank ?? .max) < ($1.proposalOptionKind?.comparisonRank ?? .max)
            }
    }

    private var currentJobBalanceDue: Double? {
        guard let invoice = currentJobInvoice else { return nil }
        return Invoice.outstandingBalance(for: invoice, payments: currentJobPayments)
    }

    private var estimateMetrics: (pending: Int, accepted: Int, followUp: Int) {
        let pending = displayedEstimates.filter { $0.status == "pending" }.count
        let accepted = displayedEstimates.filter { $0.status == "accepted" }.count
        let followUp = displayedEstimates.filter { $0.status == "follow-up" }.count
        return (pending, accepted, followUp)
    }

    private var invoiceMetrics: (open: Int, overdue: Int, outstandingBalance: Double) {
        let openInvoices = displayedInvoices.filter { invoice in
            invoiceBalanceDue(for: invoice) > 0.009
        }
        let overdueInvoices = openInvoices.filter(isInvoiceOverdue)
        let balance = openInvoices.reduce(0) { partial, invoice in
            partial + invoiceBalanceDue(for: invoice)
        }
        return (openInvoices.count, overdueInvoices.count, balance)
    }

    private var estimatesNeedingFollowUp: [Estimate] {
        displayedEstimates.filter { estimate in
            isCurrentProposal(estimate) && (estimate.status == "pending" || estimate.status == "follow-up")
        }
    }

    private var acceptedEstimatesReadyToSchedule: [Estimate] {
        displayedEstimates.filter {
            isCurrentProposal($0) &&
            $0.status == "accepted" &&
            scheduledApprovedWork(for: $0) == nil
        }
    }

    private var collectibleInvoices: [Invoice] {
        BillingInvoiceQueueBuilder.collectibleInvoices(from: displayedInvoices, payments: payments)
    }

    private var overdueInvoices: [Invoice] {
        BillingInvoiceQueueBuilder.overdueInvoices(from: collectibleInvoices, payments: payments)
    }

    private var collectionQueueInvoices: [Invoice] {
        BillingInvoiceQueueBuilder.collectionsQueue(from: collectibleInvoices)
    }

    private var overdueInvoicesOutsideCollectionsQueue: [Invoice] {
        BillingInvoiceQueueBuilder.overdueQueueExcludingCollections(
            overdueInvoices: overdueInvoices,
            collectionsQueue: collectionQueueInvoices
        )
    }

    private var projectMilestonesReadyForBilling: [ProjectMilestone] {
        guard canIssueProjectProgressInvoices else { return [] }
        return projectMilestones
            .filter { milestone in
                guard milestone.invoiceID == nil,
                      let call = serviceCalls.first(where: { $0.id == milestone.projectServiceCallID }),
                      let estimate = estimates.first(where: { $0.id == milestone.estimateID }),
                      AppAccess.canAccessServiceCall(
                        call,
                        email: currentUserEmail,
                        users: users,
                        serviceCalls: serviceCalls,
                        technicians: technicians
                      ) else {
                    return false
                }
                let scheduledVisit = milestone.scheduledVisitID.flatMap { visitID in
                    serviceCalls.first { $0.id == visitID }
                }
                return ProjectBillingPolicy.canInvoice(
                    milestone,
                    estimate: estimate,
                    scheduledVisit: scheduledVisit
                )
            }
            .sorted {
                if $0.plannedDate != $1.plannedDate { return $0.plannedDate < $1.plannedDate }
                if $0.projectServiceCallID != $1.projectServiceCallID {
                    return $0.projectServiceCallID.uuidString < $1.projectServiceCallID.uuidString
                }
                return $0.sequence < $1.sequence
            }
    }

    private var maintenanceAgreementBillingCandidates: [MaintenanceAgreementBillingCandidate] {
        guard canIssueMaintenanceAgreementInvoices else { return [] }
        return maintenanceAgreements
            .compactMap { agreement in
                guard let candidate = MaintenanceAgreementBillingPolicy.firstDueCandidate(
                    for: agreement,
                    serviceCalls: serviceCalls
                ),
                let item = items.first(where: { $0.id == candidate.billingCatalogItemID }),
                !item.requiresPricebookReview,
                item.isAvailableForNewWork else { return nil }
                return candidate
            }
            .sorted {
                if $0.cycleDueDate != $1.cycleDueDate { return $0.cycleDueDate < $1.cycleDueDate }
                if $0.customerID != $1.customerID { return $0.customerID.uuidString < $1.customerID.uuidString }
                return $0.agreementID.uuidString < $1.agreementID.uuidString
            }
    }

    private var maintenanceAgreementsNeedingBillingSetup: [RecurringMaintenanceContract] {
        guard canIssueMaintenanceAgreementInvoices else { return [] }
        return maintenanceAgreements
            .filter { agreement in
                guard MaintenanceAgreementBillingPolicy.isEligibleForBilling(agreement),
                      agreement.agreementPrice.map({ $0 > 0.009 }) == true else { return false }
                guard let billingCatalogItemID = agreement.billingCatalogItemID else { return true }
                guard let item = items.first(where: { $0.id == billingCatalogItemID }),
                      !item.requiresPricebookReview,
                      item.isAvailableForNewWork else { return true }
                return agreement.billingInterval != .perVisit && agreement.billingAnchorDate == nil
            }
            .sorted {
                let lhsName = $0.customer.name
                let rhsName = $1.customer.name
                if lhsName != rhsName { return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
    }

    private var displayedEstimates: [Estimate] {
        let displayEstimates = Estimate.displayDeduplicated(estimates)
        guard !canViewFinancials else { return displayEstimates }
        guard canCollectFieldPayments else { return [] }
        let visibleCallIDs = visibleBillingServiceCallIDsForFieldUser
        let visibleEstimateIDs = visibleLinkedEstimateIDsForFieldUser
        return displayEstimates.filter { estimate in
            if let serviceCallID = estimate.serviceCallID, visibleCallIDs.contains(serviceCallID) {
                return true
            }
            return visibleEstimateIDs.contains(estimate.id)
        }
    }

    private var displayedInvoices: [Invoice] {
        // CloudKit may briefly hydrate an invoice before its required customer
        // relationship arrives. Keep that record in the store and surface a
        // sync status, but never force-render the incomplete relationship.
        let displayInvoices = Invoice.displayDeduplicated(invoices)
            .filter { $0.customer != nil }
        guard !canViewFinancials else { return displayInvoices }
        guard canCollectFieldPayments else { return [] }
        let visibleCallIDs = visibleBillingServiceCallIDsForFieldUser
        let visibleInvoiceIDs = visibleLinkedInvoiceIDsForFieldUser
        return displayInvoices.filter { invoice in
            if let serviceCallID = invoice.serviceCallID, visibleCallIDs.contains(serviceCallID) {
                return true
            }
            return visibleInvoiceIDs.contains(invoice.id)
        }
    }

    private var unresolvedInvoiceRelationshipCount: Int {
        Invoice.displayDeduplicated(invoices)
            .filter { $0.customer == nil }
            .count
    }

    private var visibleBillingServiceCallIDsForFieldUser: Set<UUID> {
        AppAccess.visibleBillingServiceCallIDs(
            email: currentUserEmail,
            users: users,
            serviceCalls: serviceCalls,
            activeServiceCall: activeServiceCall,
            technicians: technicians
        )
    }

    private var visibleLinkedInvoiceIDsForFieldUser: Set<UUID> {
        Set(serviceCalls.compactMap { call in
            visibleBillingServiceCallIDsForFieldUser.contains(call.id) ? call.linkedInvoiceID : nil
        })
    }

    private var visibleLinkedEstimateIDsForFieldUser: Set<UUID> {
        Set(serviceCalls.compactMap { call in
            visibleBillingServiceCallIDsForFieldUser.contains(call.id) ? call.linkedEstimateID : nil
        })
    }

    private var contextCustomer: Customer? {
        if let selectedCustomer {
            return selectedCustomer
        }
        return activeServiceCall?.customer
    }

    private var activeServiceAgreement: RecurringMaintenanceContract? {
        if let activeServiceCall,
           let maintenanceAgreementID = activeServiceCall.maintenanceAgreementID,
           let linkedAgreement = activeServiceCall.customer.recurringContracts.first(where: { $0.id == maintenanceAgreementID }) {
            return linkedAgreement
        }
        return contextCustomer?.recurringContracts
            .filter(\.active)
            .sorted(by: { $0.nextDate < $1.nextDate })
            .first
    }

    private var recentCustomerCalls: [ServiceCall] {
        guard let customer = contextCustomer else { return [] }
        return serviceCalls
            .filter { $0.customer.id == customer.id }
            .sorted(by: { $0.scheduledDate > $1.scheduledDate })
            .prefix(4)
            .map { $0 }
    }

    private var relatedEquipmentCalls: [ServiceCall] {
        guard let call = activeServiceCall,
              let equipmentKey = normalizedEquipmentKey(for: call),
              !equipmentKey.isEmpty else { return [] }
        return serviceCalls.filter { candidate in
            candidate.id != call.id &&
            candidate.customer.id == call.customer.id &&
            normalizedEquipmentKey(for: candidate) == equipmentKey
        }
    }

    private var customerLifetimeInvoiceTotal: Double {
        guard let customer = contextCustomer else { return 0 }
        return invoices
            .filter { $0.customer.id == customer.id }
            .reduce(0) { $0 + $1.amount }
    }

    private var selectedSummary: String {
        selectedLineItems
            .map { item in
                let quantity = lineItemQuantity(for: item)
                let unitPrice = effectiveUnitPrice(for: item)
                let quantityDescription = quantity == 1
                    ? ""
                    : " • Qty \(quantity.formatted(.number.precision(.fractionLength(0...2))))"
                let equipmentDescription = selectedLineEquipmentSnapshots[item.id]
                    .map { " • System: \($0.customerLabel)" } ?? ""
                let assemblyDescription = selectedItemAssemblySnapshots[item.id]
                    .map { " • \($0.lineContext)" } ?? ""
                if let description = item.itemDescription, !description.isEmpty {
                    return "\(item.name) - \((unitPrice * quantity).formatted(.currency(code: "USD")))\(quantityDescription)\(assemblyDescription)\(equipmentDescription) - \(description)"
                }
                return "\(item.name) - \((unitPrice * quantity).formatted(.currency(code: "USD")))\(quantityDescription)\(assemblyDescription)\(equipmentDescription)"
            }
            .joined(separator: "\n")
    }

    private var selectedJobAddress: String? {
        let address = activeServiceCall?.siteAddress ?? activeServiceCall?.customer.address
        guard let address, !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return address
    }

    private var isQuickBooksConnected: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiTestForceQuickBooksConnected") {
            return true
        }
        if ProcessInfo.processInfo.arguments.contains("-uiTestForceQuickBooksDisconnected") {
            return false
        }
        #endif
        return liveAPI.isAuthenticated
    }

    private var accountingConfiguration: BackendQuickBooksAccountingConfiguration? {
        guard let configuration = accountingConfigurationStore.configuration,
              configuration.matches(
                realmID: liveAPI.realmID,
                environment: Config.QuickBooks.environment
              ) else { return nil }
        return configuration
    }

    private var currentUserEmail: String? {
        AppIdentity.currentEmail
    }

    private var canViewFinancials: Bool {
        AppAccess.canViewBillingFinancialDetails(email: currentUserEmail, users: users)
    }

    private var canCollectFieldPayments: Bool {
        AppAccess.canCollectFieldPayments(email: currentUserEmail, users: users)
    }

    private var canApprovePricebookItems: Bool {
        AppAccess.canApprovePricebookItems(email: currentUserEmail, users: users)
    }

    private var canAuthorizePriceAdjustments: Bool {
        AppAccess.canAuthorizePriceAdjustments(email: currentUserEmail, users: users)
    }

    private var canScheduleApprovedWork: Bool {
        AppAccess.canManageDispatch(email: currentUserEmail, users: users)
    }

    private var canManageProjectBillingPlans: Bool {
        AppAccess.canManageProjectBillingPlans(email: currentUserEmail, users: users)
    }

    private var canCompleteProjectMilestones: Bool {
        AppAccess.canCompleteProjectMilestones(email: currentUserEmail, users: users)
    }

    private var canIssueProjectProgressInvoices: Bool {
        AppAccess.canIssueProjectProgressInvoices(email: currentUserEmail, users: users)
    }

    private var canConfigureMaintenanceAgreementBilling: Bool {
        AppAccess.canConfigureMaintenanceAgreementBilling(email: currentUserEmail, users: users)
    }

    private var canIssueMaintenanceAgreementInvoices: Bool {
        AppAccess.canIssueMaintenanceAgreementInvoices(email: currentUserEmail, users: users)
    }

    private var canRecordJobMaterials: Bool {
        AppAccess.canRecordJobMaterials(email: currentUserEmail, users: users)
    }

    private var canRequestJobMaterialReplenishment: Bool {
        AppAccess.canRequestJobMaterialReplenishment(email: currentUserEmail, users: users)
    }

    private var mapsURL: URL? {
        let address = customerAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? selectedJobAddress
            : customerAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        return AppleMapsDirections.destinationURL(address: address)
    }

    private var phoneURL: URL? {
        let phone = customerPhone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phone.isEmpty else { return nil }
        let digits = phone.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        return URL(string: "tel://\(digits)")
    }

    private var emailURL: URL? {
        let email = customerEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { return nil }
        return URL(string: "mailto:\(email)")
    }

    private var estimateFollowUpEmailURL: URL? {
        guard let estimate = currentJobEstimate else { return nil }
        return followUpEmailURL(for: estimate)
    }

    private func followUpEmailDraft(for estimate: Estimate) -> (to: String, subject: String, body: String)? {
        guard let email = estimate.customer.email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else { return nil }
        let reference = estimate.quickBooksID?.isEmpty == false ? estimate.quickBooksID! : String(estimate.id.uuidString.prefix(8))
        return (
            to: email,
            subject: "Estimate Follow-Up - \(reference)",
            body: """
Hello \(estimate.customer.name),

Following up on your estimate for \(estimate.amount.formatted(.currency(code: "USD"))).

Please let us know if you would like to move forward or if you have any questions.

Thank you,
GunnAire
"""
        )
    }

    private func followUpEmailURL(for estimate: Estimate) -> URL? {
        guard let draft = followUpEmailDraft(for: estimate) else { return nil }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = draft.to
        components.queryItems = [
            URLQueryItem(name: "subject", value: draft.subject),
            URLQueryItem(name: "body", value: draft.body)
        ]
        return components.url
    }

    private func openEstimateFollowUpEmail(for estimate: Estimate, fallbackURL: URL) {
        if googleAuth.isAuthenticated, let draft = followUpEmailDraft(for: estimate) {
            GunnAireAppIntentRouter.storeMailDraftRoute(
                to: draft.to,
                subject: draft.subject,
                body: draft.body,
                attachmentPaths: estimateEmailAttachmentPaths(for: estimate),
                customerID: estimate.customer.id,
                serviceCallID: estimate.serviceCallID,
                estimateID: estimate.id,
                workflow: .estimateFollowUp
            )
        } else {
            openURL(fallbackURL)
        }
    }

    private func estimateEmailAttachmentPaths(for estimate: Estimate) -> [String] {
        do {
            let serviceCall = serviceCall(for: estimate)
            if let serviceCall {
                saveCurrentEquipmentProfile(for: serviceCall, announce: false)
                linkExistingEstimateAttachments(to: estimate, serviceCallID: serviceCall.id)
            }
            let url = try CustomerDocumentExporter.exportEstimate(
                estimate,
                serviceCall: serviceCall,
                attachments: attachments,
                equipmentProfiles: equipmentProfiles,
                serviceCalls: serviceCalls
            )
            generatedCustomerDocumentURL = url
            generatedCustomerDocumentRecipientID = estimate.customer.id
            generatedCustomerDocumentServiceCallID = serviceCall?.id
            generatedCustomerDocumentInvoiceID = nil
            generatedCustomerDocumentEstimateID = estimate.id
            generatedCustomerDocumentKind = "estimate"
            var emailAttachments = attachments
            if let estimateAttachment = persistGeneratedBillingDocument(
                url,
                customer: estimate.customer,
                serviceCallID: serviceCall?.id,
                invoiceID: nil,
                estimateID: estimate.id,
                kind: .estimateSupport,
                caption: "Generated estimate PDF",
                successMessage: "Estimate PDF generated for email."
            ) {
                emailAttachments.append(estimateAttachment)
            }
            if let serviceCall {
                let report = try generateAndPersistOnsiteReportAttachment(
                    for: serviceCall,
                    estimate: estimate,
                    invoice: nil,
                    payments: [],
                    attachments: reportEvidenceAttachments(for: serviceCall, in: emailAttachments),
                    equipmentProfiles: equipmentProfiles,
                    serviceCalls: serviceCalls
                )
                report.attachment.linkToEstimateIfNeeded(estimate)
                syncAttachmentIfPossible(report.attachment, data: report.data)
                emailAttachments.append(report.attachment)
            }
            return CustomerDocumentExporter.customerEmailAttachmentURLs(
                primaryDocumentURL: url,
                serviceCallID: serviceCall?.id,
                estimateID: estimate.id,
                attachments: emailAttachments
            ).map(\.path)
        } catch {
            actionMessage = "Could not prepare estimate attachment for email: \(error.localizedDescription)"
            return []
        }
    }

    private func paymentReminderEmailDraft(for invoice: Invoice) -> (to: String, subject: String, body: String)? {
        guard let email = invoice.customer.email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else { return nil }
        return (
            to: email,
            subject: "Payment Reminder From GunnAire",
            body: """
Hello \(invoice.customer.name),

This is a reminder that \(invoiceBalanceDue(for: invoice).formatted(.currency(code: "USD"))) remains due on your GunnAire invoice.
Due date: \(invoice.effectiveDueDate().formatted(date: .long, time: .omitted))

Please let us know if you would like us to take payment or if you have any questions.

Thank you,
GunnAire
"""
        )
    }

    private func paymentReminderEmailURL(for invoice: Invoice) -> URL? {
        guard let draft = paymentReminderEmailDraft(for: invoice) else { return nil }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = draft.to
        components.queryItems = [
            URLQueryItem(name: "subject", value: draft.subject),
            URLQueryItem(name: "body", value: draft.body)
        ]
        return components.url
    }

    private func openPaymentReminderEmail(for invoice: Invoice, fallbackURL: URL) {
        if googleAuth.isAuthenticated, let draft = paymentReminderEmailDraft(for: invoice) {
            GunnAireAppIntentRouter.storeMailDraftRoute(
                to: draft.to,
                subject: draft.subject,
                body: draft.body,
                attachmentPaths: invoiceEmailAttachmentPaths(for: invoice),
                customerID: invoice.customer.id,
                serviceCallID: invoice.serviceCallID,
                invoiceID: invoice.id,
                workflow: .paymentReminder
            )
        } else {
            openURL(fallbackURL)
        }
    }

    private func invoiceEmailAttachmentPaths(for invoice: Invoice) -> [String] {
        do {
            let invoicePayments = payments.filter { $0.invoice.id == invoice.id }
            let serviceCall = serviceCall(for: invoice)
            if let serviceCall {
                saveCurrentEquipmentProfile(for: serviceCall, announce: false)
            }
            let url = try CustomerDocumentExporter.exportInvoice(
                invoice,
                serviceCall: serviceCall,
                payments: invoicePayments,
                attachments: attachments,
                equipmentProfiles: equipmentProfiles,
                serviceCalls: serviceCalls
            )
            generatedCustomerDocumentURL = url
            generatedCustomerDocumentRecipientID = invoice.customer.id
            generatedCustomerDocumentServiceCallID = serviceCall?.id
            generatedCustomerDocumentInvoiceID = invoice.id
            generatedCustomerDocumentEstimateID = linkedEstimate(for: serviceCall)?.id
            let documentLabel = CustomerDocumentExporter.invoiceDocumentLabel(for: invoice, payments: invoicePayments).lowercased()
            generatedCustomerDocumentKind = documentLabel
            var emailAttachments = attachments
            if let invoiceAttachment = persistGeneratedBillingDocument(
                url,
                customer: invoice.customer,
                serviceCallID: serviceCall?.id,
                invoiceID: invoice.id,
                estimateID: nil,
                kind: .invoiceSupport,
                caption: CustomerDocumentExporter.invoiceDocumentCaption(for: invoice, payments: invoicePayments),
                successMessage: "\(CustomerDocumentExporter.invoiceDocumentLabel(for: invoice, payments: invoicePayments)) PDF generated for email."
            ) {
                emailAttachments.append(invoiceAttachment)
            }
            if let serviceCall {
                let linkedEstimate = currentJobEstimate ?? estimates.first { estimate in
                    estimate.id == serviceCall.linkedEstimateID || estimate.serviceCallID == serviceCall.id
                }
                let report = try generateAndPersistOnsiteReportAttachment(
                    for: serviceCall,
                    estimate: linkedEstimate,
                    invoice: invoice,
                    payments: invoicePayments,
                    attachments: reportEvidenceAttachments(for: serviceCall, in: emailAttachments),
                    equipmentProfiles: equipmentProfiles,
                    serviceCalls: serviceCalls
                )
                report.attachment.linkToInvoiceIfNeeded(invoice)
                syncAttachmentIfPossible(report.attachment, data: report.data)
                emailAttachments.append(report.attachment)
            }
            return CustomerDocumentExporter.customerEmailAttachmentURLs(
                primaryDocumentURL: url,
                serviceCallID: serviceCall?.id,
                invoiceID: invoice.id,
                estimateID: linkedEstimate(for: serviceCall)?.id,
                attachments: emailAttachments
            ).map(\.path)
        } catch {
            actionMessage = "Could not prepare invoice attachment for email: \(error.localizedDescription)"
            return []
        }
    }

    private var canEmailGeneratedCustomerDocument: Bool {
        guard googleAuth.isAuthenticated,
              !isEmailingGeneratedDocument,
              generatedCustomerDocumentURL != nil,
              let email = generatedCustomerDocumentRecipient?.email?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !email.isEmpty
    }

    private func emailGeneratedCustomerDocument(_ url: URL) {
        guard googleAuth.isAuthenticated else {
            actionMessage = "Connect Google before emailing generated PDFs from the app."
            return
        }
        guard let recipient = generatedCustomerDocumentRecipient,
              let email = recipient.email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else {
            actionMessage = "Add a customer email before sending this generated document."
            return
        }
        guard recipient.allowsTransactionalEmail else {
            recordGeneratedCustomerDocumentCommunication(
                customer: recipient,
                recipient: email,
                subject: "GunnAire \(generatedCustomerDocumentKind.capitalized) - \(recipient.name)",
                attachmentNames: [],
                deliveryStatus: "suppressed",
                providerMessageID: nil,
                providerStatusDetail: "Transactional email preference is off."
            )
            actionMessage = "Email was not sent because \(recipient.name)'s service and billing email preference is off."
            return
        }
        let subject = "GunnAire \(generatedCustomerDocumentKind.capitalized) - \(recipient.name)"
        let body = """
Hello \(recipient.name),

Attached is your GunnAire \(generatedCustomerDocumentKind).

Please reply with any questions.

Thank you,
GunnAire
"""
        let attachmentURLs = CustomerDocumentExporter.customerEmailAttachmentURLs(
            primaryDocumentURL: url,
            serviceCallID: generatedCustomerDocumentServiceCallID,
            invoiceID: generatedCustomerDocumentInvoiceID,
            estimateID: generatedCustomerDocumentEstimateID,
            attachments: attachments
        )
        var gmailAttachments: [GmailAttachment] = []
        for attachmentURL in attachmentURLs {
            guard let data = try? Data(contentsOf: attachmentURL) else {
                actionMessage = "Could not read \(attachmentURL.lastPathComponent) for email."
                return
            }
            gmailAttachments.append(GmailAttachment(
                fileName: attachmentURL.lastPathComponent,
                mimeType: QuickBooksDataAPI.mimeType(for: attachmentURL),
                data: data
            ))
        }
        guard !gmailAttachments.isEmpty else {
            actionMessage = "Could not read the generated PDF attachment."
            return
        }
        isEmailingGeneratedDocument = true
        actionMessage = "Emailing \(generatedCustomerDocumentKind)..."
        googleAuth.sendGmailMessage(
            to: email,
            subject: subject,
            body: body,
            attachments: gmailAttachments
        ) { result in
            DispatchQueue.main.async {
                isEmailingGeneratedDocument = false
                switch result {
                case .success(let sentMessage):
                    recordGeneratedCustomerDocumentCommunication(
                        customer: recipient,
                        recipient: email,
                        subject: subject,
                        attachmentNames: gmailAttachments.map(\.fileName),
                        deliveryStatus: "sent",
                        providerMessageID: sentMessage.id,
                        providerStatusDetail: nil
                    )
                    let attachmentSummary = gmailAttachments.count == 1 ? "" : " with onsite report"
                    actionMessage = "\(generatedCustomerDocumentKind.capitalized) emailed to \(email)\(attachmentSummary)."
                case .failure(let error):
                    recordGeneratedCustomerDocumentCommunication(
                        customer: recipient,
                        recipient: email,
                        subject: subject,
                        attachmentNames: gmailAttachments.map(\.fileName),
                        deliveryStatus: "failed",
                        providerMessageID: nil,
                        providerStatusDetail: error.localizedDescription
                    )
                    actionMessage = "Generated document email failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func recordGeneratedCustomerDocumentCommunication(
        customer: Customer,
        recipient: String,
        subject: String,
        attachmentNames: [String],
        deliveryStatus: String,
        providerMessageID: String?,
        providerStatusDetail: String?
    ) {
        let now = Date()
        let communication = CustomerCommunication(
            customer: customer,
            serviceCallID: generatedCustomerDocumentServiceCallID,
            invoiceID: generatedCustomerDocumentInvoiceID,
            estimateID: generatedCustomerDocumentEstimateID,
            recipient: recipient,
            subject: subject,
            deliveryStatus: deliveryStatus,
            workflow: .customerDocument,
            actorEmail: googleAuth.signedInEmail,
            consentSnapshot: CustomerCommunicationConsentSnapshot(customer: customer),
            providerStatusDetail: providerStatusDetail,
            deliveredAt: deliveryStatus == "sent" ? now : nil,
            attachmentFileNames: attachmentNames,
            providerMessageID: providerMessageID,
            createdAt: now
        )
        modelContext.insert(communication)
        try? modelContext.save()
        guard GunnAireBackendService.isConfigured else { return }
        Task {
            do {
                let remote = try await GunnAireBackendService.uploadCustomerCommunication(communication)
                communication.markSharedCompanySynced(id: remote.id)
            } catch {
                communication.markSharedCompanySyncFailed(error.localizedDescription)
            }
            try? modelContext.save()
        }
    }

    private var isJobDocumentationMode: Bool {
        activeServiceCall != nil
    }

    private var navigationTitle: String {
        if isJobDocumentationMode {
            return "Job Documentation"
        }
        return workspaceMode.navigationTitle
    }

    private var allowsDocumentSwitching: Bool {
        workspaceMode == .all || isJobDocumentationMode
    }

    private var activeJobAttachments: [ServiceDocumentAttachment] {
        guard let call = activeServiceCall else { return [] }
        return attachments.filter { $0.serviceCallID == call.id }
    }

    private var activeJobReportEvidenceAttachments: [ServiceDocumentAttachment] {
        guard let call = activeServiceCall else { return [] }
        return reportEvidenceAttachments(for: call)
    }

    private func reportEvidenceAttachments(
        for call: ServiceCall,
        in sourceAttachments: [ServiceDocumentAttachment]? = nil
    ) -> [ServiceDocumentAttachment] {
        let source = sourceAttachments ?? attachments
        return CustomerDocumentExporter.reportEvidenceAttachments(for: source, serviceCall: call)
    }

    private var filteredActiveJobAttachments: [ServiceDocumentAttachment] {
        let query = attachmentSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return activeJobAttachments }
        let call = activeServiceCall
        return activeJobAttachments.filter { attachment in
            attachment.matchesJobAttachmentSearch(
                query,
                serviceCall: call,
                equipmentProfiles: equipmentProfiles
            )
        }
    }

    private var groupedActiveJobAttachments: [(kind: ServiceDocumentAttachmentKind, attachments: [ServiceDocumentAttachment])] {
        ServiceDocumentAttachmentKind.allCases.compactMap { kind in
            let group = filteredActiveJobAttachments
                .filter { $0.kind == kind }
                .sorted { $0.createdAt > $1.createdAt }
            return group.isEmpty ? nil : (kind, group)
        }
    }

    private var activeSharedJobDocuments: [BackendDocumentRecord] {
        guard let call = activeServiceCall else { return [] }
        let query = attachmentSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return sharedJobDocuments.filter { document in
            guard document.serviceCallID == call.id.uuidString else {
                return false
            }
            guard !query.isEmpty else { return true }
            return [
                document.filename,
                document.kind,
                document.contentType,
                document.customerName,
                document.createdAt
            ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
            .contains(query)
        }
    }

    private var activeCustomerEquipmentProfiles: [CustomerEquipment] {
        guard let call = activeServiceCall else { return [] }
        return equipmentProfiles.filter { $0.customer?.id == call.customer.id && $0.isActive }
    }

    private var activeEquipmentProfile: CustomerEquipment? {
        guard let call = activeServiceCall else { return nil }
        if let equipmentID = call.customerEquipmentID,
           let linked = activeCustomerEquipmentProfiles.first(where: { $0.id == equipmentID }) {
            return linked
        }
        return activeCustomerEquipmentProfiles.first { $0.matches(call) }
    }

    private var activeEquipmentServicePlanningSnapshot: EquipmentServicePlanningSnapshot? {
        activeEquipmentProfile?.servicePlanningSnapshot(in: serviceCalls)
    }

    private var activeEquipmentHistoryAttachments: [ServiceDocumentAttachment] {
        guard let call = activeServiceCall else { return [] }
        return ServiceDocumentAttachment.equipmentHistoryAttachments(
            for: call,
            in: attachments,
            serviceCalls: serviceCalls
        )
    }

    private var isAttachmentPreviewPresented: Binding<Bool> {
        Binding(
            get: { attachmentPreviewURL != nil },
            set: { isPresented in
                if !isPresented {
                    attachmentPreviewURL = nil
                    attachmentPendingMarkup = nil
                }
            }
        )
    }

    private var customerEquipmentDropdownOptions: [SearchableDropdownOption] {
        activeCustomerEquipmentProfiles
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            .map { equipment in
                let subtitle = [
                    equipment.location,
                    equipment.manufacturer,
                    equipment.modelNumber,
                    equipment.serialNumber.map { "Serial \($0)" }
                ]
                .compactMap { value in
                    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed?.isEmpty == false ? trimmed : nil
                }
                .joined(separator: " • ")
                return SearchableDropdownOption(
                    id: equipment.id.uuidString,
                    title: equipment.displayName,
                    subtitle: subtitle.isEmpty ? nil : subtitle
                )
            }
    }

    private var requestedInitialCloseoutInvoice: Invoice? {
        let invoice = currentJobInvoice
        let decision = BillingInitialCloseoutPolicy.resolve(
            openCloseout: openCloseoutOnAppear,
            autoStartTapToPay: openTapToPayOnAppear,
            canCollectPayment: canCollectFieldPayments,
            invoiceID: invoice?.id,
            hasBalanceDue: invoice.map { !isInvoicePaid($0) } ?? false,
            paymentCollectionBlockedMessage: invoice?.paymentCollectionBlockedMessage
        )
        guard case .present(let invoiceID, _) = decision,
              let invoice,
              invoice.id == invoiceID else { return nil }
        return invoice
    }

    /// The standalone invoice tab intentionally avoids materializing the full
    /// job-documentation view tree. The combined builder has dozens of rich
    /// sections and presentation modifiers; asking SwiftUI to resolve that
    /// single generic type on a physical device can exhaust the main-thread
    /// stack before the first invoice row appears.
    private var usesStackSafeInvoiceWorkspace: Bool {
        workspaceMode == .invoices && initialServiceCall == nil
    }

    private var stackSafeInvoiceWorkspaceContent: AnyView {
        AnyView(
            NavigationStack {
                List {
                    AnyView(stackSafeInvoiceLanePickerSection)
                    if invoiceWorkspaceLane == .overview {
                        AnyView(stackSafeInvoiceSnapshotSection)
                        AnyView(stackSafeGeneratedInvoiceDocumentSection)
                        AnyView(invoiceActionQueues)
                        AnyView(invoicesWorkspaceSection)
                    } else {
                        AnyView(builderDetailsWorkspaceSection)
                    }
                }
                .id(invoiceWorkspaceLane)
                .navigationTitle(navigationTitle)
                .toolbar {
                    if showsDismissButton {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(dismissButtonTitle) {
                                dismiss()
                            }
                        }
                    }
                }
            }
        )
    }

    private var stackSafeInvoiceLanePickerSection: some View {
        Section {
            Picker("Invoice workspace", selection: $invoiceWorkspaceLane) {
                ForEach(InvoiceWorkspaceLane.allCases) { lane in
                    Text(lane.rawValue).tag(lane)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("InvoiceWorkspaceLanePicker")
        }
    }

    @ViewBuilder
    private var stackSafeInvoiceSnapshotSection: some View {
        if canViewFinancials {
            Section("Workspace Snapshot") {
                HStack {
                    workspaceMetricView(title: "Open", value: "\(invoiceMetrics.open)")
                    Spacer()
                    workspaceMetricView(title: "Overdue", value: "\(invoiceMetrics.overdue)")
                    Spacer()
                    workspaceMetricView(
                        title: "Outstanding",
                        value: invoiceMetrics.outstandingBalance.formatted(.currency(code: "USD"))
                    )
                }
                if unresolvedInvoiceRelationshipCount > 0 {
                    Label(
                        "Syncing \(unresolvedInvoiceRelationshipCount) invoice relationship\(unresolvedInvoiceRelationshipCount == 1 ? "" : "s")…",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("InvoiceRelationshipHydrationStatus")
                }
            }
        }
    }

    @ViewBuilder
    private var stackSafeGeneratedInvoiceDocumentSection: some View {
        if let generatedCustomerDocumentURL {
            Section("Customer Documents") {
                ShareLink(item: generatedCustomerDocumentURL) {
                    Label("Share Last Generated Document", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.brandGold)
                .foregroundStyle(Color.primaryBlack)

                Button {
                    emailGeneratedCustomerDocument(generatedCustomerDocumentURL)
                } label: {
                    Label(
                        isEmailingGeneratedDocument ? "Emailing..." : "Email Last Generated Document",
                        systemImage: "paperplane"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(!canEmailGeneratedCustomerDocument)
            }
        }
    }

    /// Erase each small modifier group before adding the next one. This keeps
    /// sheet and dialog support available without recreating the deeply nested
    /// metadata chain that caused the invoice-tab stack overflow.
    private var stackSafeInvoiceWorkspace: AnyView {
        let itemSelection = AnyView(
            stackSafeInvoiceWorkspaceContent
                .sheet(isPresented: $showingItemSelector) {
                    DocumentationItemSelectorView(
                        items: items,
                        selectedItems: selectedItems,
                        selectedItemizedAssemblyIDs: Set(selectedItemizedAssemblyMemberships.keys),
                        documentScopedReviewItemIDs: documentScopedReviewItemIDs,
                        onToggle: toggleItem
                    )
                }
        )
        let itemCreation = AnyView(
            itemSelection
                .sheet(isPresented: $showingItemCreator) {
                    DocumentationItemCreatorView(
                        initialName: itemCreatorInitialName,
                        vendors: vendors,
                        requiresPricebookReview: !canApprovePricebookItems,
                        createdByEmail: currentUserEmail,
                        onCreated: handleCreatedItem
                    )
                }
        )
        let priceAdjustment = AnyView(
            itemCreation
                .sheet(item: $itemPendingPriceAdjustment) { item in
                    LinePriceAdjustmentSheet(
                        item: item,
                        existingAdjustment: selectedItemPriceAdjustments[item.id],
                        onAuthorize: { unitPrice, reason in
                            authorizePriceAdjustment(for: item, unitPrice: unitPrice, reason: reason)
                        },
                        onRemove: {
                            clearPriceAdjustment(for: item)
                        }
                    )
                    .tint(Color.brandGold)
                }
        )
        let documentDiscount = AnyView(
            priceAdjustment
                .sheet(isPresented: $showingDocumentDiscountEditor) {
                    DocumentDiscountSheet(
                        grossSubtotal: selectedGrossSubtotal,
                        existingDiscount: selectedDocumentDiscount,
                        onAuthorize: { kind, value, reason in
                            authorizeDocumentDiscount(kind: kind, value: value, reason: reason)
                        },
                        onRemove: {
                            selectedDocumentDiscount = nil
                        }
                    )
                    .tint(Color.brandGold)
                }
        )
        let agreementReview = AnyView(
            documentDiscount
                .sheet(item: $agreementBillingCandidatePendingReview) { candidate in
                    if let agreement = maintenanceAgreement(for: candidate),
                       let billingItem = billingCatalogItem(for: candidate) {
                        MaintenanceAgreementInvoiceReviewSheet(
                            agreement: agreement,
                            candidate: candidate,
                            billingItem: billingItem,
                            paymentTerms: configuredDefaultInvoicePaymentTerms,
                            quickBooksConnected: isQuickBooksConnected
                        ) {
                            try createMaintenanceAgreementInvoice(for: candidate)
                        }
                        .tint(Color.brandGold)
                    } else {
                        ContentUnavailableView(
                            "Agreement Billing Changed",
                            systemImage: "arrow.clockwise",
                            description: Text("Dismiss this review and reopen the billing queue to use the latest agreement and pricebook data.")
                        )
                    }
                }
        )
        let agreementSetup = AnyView(
            agreementReview
                .sheet(item: $agreementBillingSetupPending) { agreement in
                    MaintenanceAgreementBillingSetupSheet(
                        agreement: agreement,
                        billingItems: items.filter {
                            !$0.requiresPricebookReview && $0.isAvailableForNewWork
                        }
                    ) { itemID, anchorDate in
                        try configureMaintenanceAgreementBilling(
                            agreement,
                            catalogItemID: itemID,
                            anchorDate: anchorDate
                        )
                    }
                    .tint(Color.brandGold)
                }
        )
        let invoiceCloseout = AnyView(
            agreementSetup
                .sheet(item: $selectedInvoiceForCloseout) { invoice in
                    RecordInvoicePaymentView(invoice: invoice)
                        .tint(Color.brandGold)
                }
        )
        let progressInvoice = AnyView(
            invoiceCloseout
                .confirmationDialog(
                    "Create Progress Invoice?",
                    isPresented: Binding(
                        get: { milestonePendingInvoice != nil },
                        set: { if !$0 { milestonePendingInvoice = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    if let milestone = milestonePendingInvoice {
                        Button("Create \(milestone.plannedAmount.formatted(.currency(code: "USD"))) Invoice") {
                            createProgressInvoice(for: milestone)
                            milestonePendingInvoice = nil
                        }
                        Button("Cancel", role: .cancel) { milestonePendingInvoice = nil }
                    }
                } message: {
                    if let milestone = milestonePendingInvoice {
                        Text("This creates a separate \(milestone.billingPercent.formatted(.number.precision(.fractionLength(0...2))))% invoice from the approved contract. The allocation is locked after creation.")
                    }
                }
        )
        let loaded = AnyView(
            progressInvoice
                .onAppear(perform: loadInitialContextIfNeeded)
                .onChange(of: selectedCustomerID) { _, newValue in
                    selectedCustomerDidChange(to: newValue)
                }
                .onChange(of: selectedItems) { _, selectedIDs in
                    selectedItemsDidChange(to: selectedIDs)
                }
        )
        return loaded
    }

    @ViewBuilder
    var body: some View {
        if let invoice = requestedInitialCloseoutInvoice {
            AnyView(
                RecordInvoicePaymentView(
                    invoice: invoice,
                    autoStartTapToPay: openTapToPayOnAppear
                )
                .tint(Color.brandGold)
            )
        } else if usesStackSafeInvoiceWorkspace {
            stackSafeInvoiceWorkspace
        } else {
            AnyView(
                NavigationStack {
                    AnyView(
            List {
                activeJobSections

                AnyView(Group {
                    if !isJobDocumentationMode && canViewFinancials {
                        Section("Workspace Snapshot") {
                            switch workspaceMode {
                            case .all:
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Billing Overview")
                                        .font(.headline)
                                    HStack {
                                        workspaceMetricView(title: "Pending Estimates", value: "\(estimateMetrics.pending)")
                                        Spacer()
                                        workspaceMetricView(title: "Open Invoices", value: "\(invoiceMetrics.open)")
                                    }
                                    HStack {
                                        workspaceMetricView(title: "Estimate Follow-Up", value: "\(estimateMetrics.followUp)")
                                        Spacer()
                                        workspaceMetricView(title: "Outstanding", value: invoiceMetrics.outstandingBalance.formatted(.currency(code: "USD")))
                                    }
                                }
                            case .estimates:
                                HStack {
                                    workspaceMetricView(title: "Pending", value: "\(estimateMetrics.pending)")
                                    Spacer()
                                    workspaceMetricView(title: "Accepted", value: "\(estimateMetrics.accepted)")
                                    Spacer()
                                    workspaceMetricView(title: "Follow-Up", value: "\(estimateMetrics.followUp)")
                                }
                            case .invoices:
                                HStack {
                                    workspaceMetricView(title: "Open", value: "\(invoiceMetrics.open)")
                                    Spacer()
                                    workspaceMetricView(title: "Overdue", value: "\(invoiceMetrics.overdue)")
                                    Spacer()
                                    workspaceMetricView(title: "Outstanding", value: invoiceMetrics.outstandingBalance.formatted(.currency(code: "USD")))
                                }
                            }
                        }
                    }
                })

                AnyView(Group {
                    if !isJobDocumentationMode, let generatedCustomerDocumentURL {
                        Section("Customer Documents") {
                            ShareLink(item: generatedCustomerDocumentURL) {
                                Label("Share Last Generated Document", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)

                            Button {
                                emailGeneratedCustomerDocument(generatedCustomerDocumentURL)
                            } label: {
                                Label(isEmailingGeneratedDocument ? "Emailing..." : "Email Last Generated Document", systemImage: "paperplane")
                            }
                            .buttonStyle(.bordered)
                            .disabled(!canEmailGeneratedCustomerDocument)
                        }
                    }
                })

                AnyView(currentJobDocumentsSection)

                AnyView(Group {
                    if let customer = contextCustomer,
                       !isJobDocumentationMode || selectedJobStage == .work {
                        Section("Customer Context") {
                            if let agreement = activeServiceAgreement {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Active Service Agreement")
                                        .font(.headline)
                                    Text(agreement.schedulePattern)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text("Next visit: \(agreement.nextDate.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text("Reminder: \(agreement.reminderDate.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 2)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Customer History")
                                    .font(.headline)
                                Text(customerActivitySummary(customer))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if canViewFinancials && customerLifetimeInvoiceTotal > 0 {
                                    Text("Lifetime invoiced: \(customerLifetimeInvoiceTotal, format: .currency(code: "USD"))")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }

                            if !recentCustomerCalls.isEmpty {
                                ForEach(recentCustomerCalls) { recentCall in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(serviceCallSummaryLine(recentCall))
                                            .font(.caption)
                                        Text(recentCall.scheduledDate.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        if let notes = recentCall.notes, !notes.isEmpty {
                                            Text(notes)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                                .lineLimit(2)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                    }
                })

                AnyView(estimateActionQueues)

                AnyView(invoiceActionQueues)

                AnyView(equipmentHistorySection)

                AnyView(builderDetailsWorkspaceSection)

                AnyView(estimatesWorkspaceSection)

                AnyView(invoicesWorkspaceSection)

                AnyView(paymentsWorkspaceSection)
            }
            .navigationTitle(navigationTitle)
            .toolbar {
                if showsDismissButton {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(dismissButtonTitle) {
                            dismiss()
                        }
                    }
                }
            }
            .sheet(isPresented: $showingItemSelector) {
                DocumentationItemSelectorView(
                    items: items,
                    selectedItems: selectedItems,
                    selectedItemizedAssemblyIDs: Set(selectedItemizedAssemblyMemberships.keys),
                    documentScopedReviewItemIDs: documentScopedReviewItemIDs,
                    onToggle: toggleItem
                )
            }
            .sheet(isPresented: $showingItemCreator) {
                DocumentationItemCreatorView(
                    initialName: itemCreatorInitialName,
                    vendors: vendors,
                    requiresPricebookReview: !canApprovePricebookItems,
                    createdByEmail: currentUserEmail,
                    onCreated: handleCreatedItem
                )
            }
            .sheet(item: $itemPendingPriceAdjustment) { item in
                LinePriceAdjustmentSheet(
                    item: item,
                    existingAdjustment: selectedItemPriceAdjustments[item.id],
                    onAuthorize: { unitPrice, reason in
                        authorizePriceAdjustment(for: item, unitPrice: unitPrice, reason: reason)
                    },
                    onRemove: {
                        clearPriceAdjustment(for: item)
                    }
                )
                .tint(Color.brandGold)
            }
            .sheet(isPresented: $showingDocumentDiscountEditor) {
                DocumentDiscountSheet(
                    grossSubtotal: selectedGrossSubtotal,
                    existingDiscount: selectedDocumentDiscount,
                    onAuthorize: { kind, value, reason in
                        authorizeDocumentDiscount(kind: kind, value: value, reason: reason)
                    },
                    onRemove: {
                        selectedDocumentDiscount = nil
                    }
                )
                .tint(Color.brandGold)
            }
            .sheet(item: $agreementBillingCandidatePendingReview) { candidate in
                if let agreement = maintenanceAgreement(for: candidate),
                   let billingItem = billingCatalogItem(for: candidate) {
                    MaintenanceAgreementInvoiceReviewSheet(
                        agreement: agreement,
                        candidate: candidate,
                        billingItem: billingItem,
                        paymentTerms: configuredDefaultInvoicePaymentTerms,
                        quickBooksConnected: isQuickBooksConnected
                    ) {
                        try createMaintenanceAgreementInvoice(for: candidate)
                    }
                    .tint(Color.brandGold)
                } else {
                    ContentUnavailableView(
                        "Agreement Billing Changed",
                        systemImage: "arrow.clockwise",
                        description: Text("Dismiss this review and reopen the billing queue to use the latest agreement and pricebook data.")
                    )
                }
            }
            .sheet(item: $agreementBillingSetupPending) { agreement in
                MaintenanceAgreementBillingSetupSheet(
                    agreement: agreement,
                    billingItems: items.filter {
                        !$0.requiresPricebookReview && $0.isAvailableForNewWork
                    }
                ) { itemID, anchorDate in
                    try configureMaintenanceAgreementBilling(
                        agreement,
                        catalogItemID: itemID,
                        anchorDate: anchorDate
                    )
                }
                .tint(Color.brandGold)
            }
            .sheet(isPresented: $showingDocumentationCamera) {
                JobDocumentationCameraPicker(sourceType: .camera) { image in
                    handleCapturedDocumentationImage(image)
                }
            }
            .sheet(item: $selectedInvoiceForCloseout) { invoice in
                RecordInvoicePaymentView(invoice: invoice)
                    .tint(Color.brandGold)
            }
            .sheet(item: $selectedEstimateForApproval) { estimate in
                EstimateApprovalSheet(estimate: estimate) { evidence in
                    recordCustomerApproval(evidence, for: estimate)
                }
                .tint(Color.brandGold)
            }
            .sheet(item: $selectedEstimateForScheduling) { estimate in
                ApprovedEstimateSchedulingSheet(
                    estimate: estimate,
                    sourceCall: serviceCall(for: estimate)
                ) { scheduledDate, duration, workType in
                    createApprovedWorkOrder(
                        for: estimate,
                        scheduledDate: scheduledDate,
                        duration: duration,
                        workType: workType
                    )
                }
                .tint(Color.brandGold)
            }
            .sheet(item: $selectedEstimateForFinancing) { estimate in
                if let readiness = customerFinancingReadiness,
                   CustomerFinancingPolicy.eligibility(
                    readiness: readiness,
                    estimateAmount: estimate.amount,
                    estimateStatus: estimate.status,
                    isCurrentProposal: isCurrentProposal(estimate),
                    proposalSelectionIssue: EstimateProposalPolicy.selectionIssue(for: estimate, in: estimates)
                   ).isEligible {
                    CustomerFinancingHandoffSheet(
                        readiness: readiness,
                        estimate: estimate
                    ) {
                        recordCustomerFinancingReferralOpened(for: estimate, readiness: readiness)
                    }
                    .tint(Color.brandGold)
                }
            }
            .sheet(isPresented: $showingProjectPlanSetup) {
                if let call = activeServiceCall, let estimate = currentJobEstimate {
                    ProjectBillingPlanSetupSheet(
                        contractAmount: estimate.amount,
                        initialDate: call.scheduledDate
                    ) { drafts in
                        createProjectBillingPlan(drafts: drafts, for: call, estimate: estimate)
                    }
                    .tint(Color.brandGold)
                }
            }
            .sheet(item: $milestonePendingScheduling) { milestone in
                ProjectMilestoneSchedulingSheet(milestone: milestone) { date, duration in
                    scheduleProjectMilestoneVisit(milestone, at: date, duration: duration)
                }
                .tint(Color.brandGold)
            }
            .confirmationDialog(
                "Complete Project Milestone?",
                isPresented: Binding(
                    get: { milestonePendingCompletion != nil },
                    set: { if !$0 { milestonePendingCompletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let milestone = milestonePendingCompletion {
                    Button("Mark \(milestone.title) Complete") {
                        completeProjectMilestone(milestone)
                        milestonePendingCompletion = nil
                    }
                    Button("Cancel", role: .cancel) { milestonePendingCompletion = nil }
                }
            } message: {
                Text("Completion records the signed-in employee and time, and may make this milestone eligible for progress billing.")
            }
            .confirmationDialog(
                "Create Progress Invoice?",
                isPresented: Binding(
                    get: { milestonePendingInvoice != nil },
                    set: { if !$0 { milestonePendingInvoice = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let milestone = milestonePendingInvoice {
                    Button("Create \(milestone.plannedAmount.formatted(.currency(code: "USD"))) Invoice") {
                        createProgressInvoice(for: milestone)
                        milestonePendingInvoice = nil
                    }
                    Button("Cancel", role: .cancel) { milestonePendingInvoice = nil }
                }
            } message: {
                if let milestone = milestonePendingInvoice {
                    Text("This creates a separate \(milestone.billingPercent.formatted(.number.precision(.fractionLength(0...2))))% invoice from the approved contract. The allocation is locked after creation.")
                }
            }
            .fileImporter(
                isPresented: $showingDocumentationFileImporter,
                allowedContentTypes: [.image, .pdf, .plainText, .data],
                allowsMultipleSelection: true
            ) { result in
                handleImportedDocumentationFiles(result)
            }
            .fullScreenCover(isPresented: isAttachmentPreviewPresented) {
                if let attachmentPreviewURL {
                    AttachmentPreviewScreen(
                        url: attachmentPreviewURL,
                        onSaveEditedCopy: attachmentPendingMarkup.map { original in
                            { modifiedContentsURL in
                                saveAnnotatedAttachmentCopy(
                                    from: modifiedContentsURL,
                                    original: original
                                )
                            }
                        }
                    )
                        .tint(Color.brandGold)
                }
            }
            .onAppear(perform: loadInitialContextIfNeeded)
            .onChange(of: selectedCustomerID) { _, newValue in
                selectedCustomerDidChange(to: newValue)
            }
            .onChange(of: selectedItems) { _, selectedIDs in
                selectedItemsDidChange(to: selectedIDs)
            }
                    )
                }
            )
        }
    }

    private func selectedCustomerDidChange(to newValue: UUID?) {
        guard let newValue, let customer = customers.first(where: { $0.id == newValue }) else {
            selectedServiceLocationID = nil
            selectedItemEquipmentIDs.removeAll()
            return
        }
        populateCustomerFields(from: customer)
        synchronizeServiceLocation(for: customer)
        reconcileLineEquipmentAssignments()
    }

    private func selectedItemsDidChange(to selectedIDs: Set<UUID>) {
        selectedItemPriceAdjustments = Dictionary(
            uniqueKeysWithValues: selectedItemPriceAdjustments.filter { selectedIDs.contains($0.key) }
        )
        selectedItemAssemblySnapshots = Dictionary(
            uniqueKeysWithValues: selectedItemAssemblySnapshots.filter { selectedIDs.contains($0.key) }
        )
        selectedItemizedAssemblyMemberships = Dictionary(
            uniqueKeysWithValues: selectedItemizedAssemblyMemberships.compactMap { assemblyID, memberIDs in
                let remainingIDs = memberIDs.intersection(selectedIDs)
                return remainingIDs.isEmpty ? nil : (assemblyID, remainingIDs)
            }
        )
        reconcileLineEquipmentAssignments()
    }

    private func proposalOptionRow(
        _ option: Estimate,
        currentEstimateID: UUID
    ) -> AnyView {
        let selectionIssue = EstimateProposalPolicy.selectionIssue(for: option, in: estimates)
        return AnyView(
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.proposalOptionDisplayDetail)
                        .font(.caption)
                    Text(option.amount, format: .currency(code: "USD"))
                    Text(option.status.capitalized)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if option.id == currentEstimateID {
                    Text(option.proposalIsFinalized ? "Approved" : "Current choice")
                        .font(.caption2)
                        .foregroundColor(option.proposalIsFinalized ? .green : .secondary)
                } else {
                    Button("Select") {
                        selectProposalOption(option)
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .disabled(selectionIssue != nil)
                }
            }
        )
    }

    private func loadInitialContextIfNeeded() {
        guard !didLoadInitialContext else { return }
        didLoadInitialContext = true
        FieldFormTemplate.ensureStarterTemplates(in: modelContext)
        try? modelContext.save()
        selectedInvoicePaymentTerms = configuredDefaultInvoicePaymentTerms
        invoiceCustomDueDate = configuredDefaultInvoicePaymentTerms.dueDate(from: Date())
            ?? Calendar.current.startOfDay(for: Date())
        if liveAPI.isAuthenticated {
            Task {
                await accountingConfigurationStore.refresh(
                    realmID: liveAPI.realmID,
                    environment: Config.QuickBooks.environment
                )
            }
        }
        loadCustomerFinancingReadinessIfNeeded()
        loadPendingIntentServiceCallIfNeeded()

        if let call = activeServiceCall {
            selectedCustomerID = call.customer.id
            populateCustomerFields(from: call.customer)
            selectedServiceLocationID = call.serviceLocationID
            if notes.isEmpty, let callNotes = call.notes {
                notes = callNotes
            }
            if call.documentationStartedAt == nil {
                call.documentationStartedAt = Date()
            }
            if call.status == .scheduled {
                call.status = .inProgress
            }
            if customerAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let address = selectedJobAddress {
                customerAddress = address
            }
            if !didLoadLinkedDocumentContext {
                loadLinkedDocumentContextIfNeeded()
            }
            selectedJobStage = JobDocumentationStage.recommended(
                for: call.status,
                hasInvoice: currentJobInvoice != nil,
                invoiceIsPaid: currentJobInvoice.map(isInvoicePaid) ?? false
            )
            openInvoiceAfterEstimateCreation = true
            if GunnAireBackendService.isConfigured, sharedJobDocuments.isEmpty {
                Task {
                    await refreshSharedJobDocuments()
                }
            }
        }

        importQuickBooksItemsIfNeeded()
        resolveInitialCloseoutRequestIfNeeded()
    }

    private func customerFinancingEligibility(for estimate: Estimate) -> CustomerFinancingEligibility {
        CustomerFinancingPolicy.eligibility(
            readiness: customerFinancingReadiness,
            estimateAmount: estimate.amount,
            estimateStatus: estimate.status,
            isCurrentProposal: isCurrentProposal(estimate),
            proposalSelectionIssue: EstimateProposalPolicy.selectionIssue(for: estimate, in: estimates)
        )
    }

    private func loadCustomerFinancingReadinessIfNeeded() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiTestCustomerFinancingReady") {
            customerFinancingReadiness = .uiTestFixture
            return
        }
        #endif
        guard GunnAireBackendService.isConfigured,
              customerFinancingReadiness == nil,
              !isLoadingCustomerFinancingReadiness else {
            return
        }
        isLoadingCustomerFinancingReadiness = true
        Task { @MainActor in
            defer { isLoadingCustomerFinancingReadiness = false }
            do {
                customerFinancingReadiness = try await GunnAireBackendService.fetchCustomerFinancingReadiness()
            } catch {
                // Financing is optional until a provider is approved. A missing or
                // unavailable endpoint must not block offline estimate work.
                customerFinancingReadiness = nil
            }
        }
    }

    private func recordCustomerFinancingReferralOpened(
        for estimate: Estimate,
        readiness: CustomerFinancingReadiness
    ) {
        guard let providerName = readiness.validatedProviderName else {
            actionMessage = "The financing provider configuration is no longer valid. Refresh and try again."
            return
        }
        guard let call = serviceCall(for: estimate)
            ?? serviceCalls.first(where: { $0.linkedEstimateID == estimate.id }) else {
            actionMessage = "The provider application opened, but this estimate is not linked to a job activity timeline."
            return
        }
        let activity = ServiceCallActivity.record(
            for: call,
            action: "Financing Referral Opened",
            detail: CustomerFinancingPolicy.activityDetail(
                providerName: providerName,
                estimateID: estimate.id
            ),
            actorEmail: currentUserEmail,
            in: modelContext
        )
        do {
            try modelContext.save()
            actionMessage = "Opened the secure \(providerName) application. Applicant and credit data remain with the financing provider."
        } catch {
            modelContext.delete(activity)
            actionMessage = "The provider application opened, but GunnAire Ops could not save the referral activity. Try again after data access recovers."
        }
    }

    private func resolveInitialCloseoutRequestIfNeeded() {
        guard !didResolveInitialCloseoutRequest else { return }
        didResolveInitialCloseoutRequest = true

        let invoice = currentJobInvoice
        let decision = BillingInitialCloseoutPolicy.resolve(
            openCloseout: openCloseoutOnAppear,
            autoStartTapToPay: openTapToPayOnAppear,
            canCollectPayment: canCollectFieldPayments,
            invoiceID: invoice?.id,
            hasBalanceDue: invoice.map { !isInvoicePaid($0) } ?? false,
            paymentCollectionBlockedMessage: invoice?.paymentCollectionBlockedMessage
        )
        switch decision {
        case .none:
            break
        case .present:
            break
        case .rejected(let message):
            actionMessage = message
        }
    }

    private func loadLinkedDocumentContextIfNeeded() {
        guard !didLoadLinkedDocumentContext else { return }
        if let invoice = currentJobInvoice {
            loadInvoiceIntoBuilder(invoice, announce: false)
            didLoadLinkedDocumentContext = true
            return
        }
        if let estimate = currentJobEstimate {
            loadEstimateIntoBuilder(estimate, announce: false)
            didLoadLinkedDocumentContext = true
        }
    }

    @ViewBuilder
    private func itemMetaText(for item: Item) -> some View {
        let meta = [
            item.sku.map { "SKU \($0)" },
            item.preferredVendorName,
            item.vendorPartNumber.map { "Vendor # \($0)" }
        ]
        .compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }

        if !meta.isEmpty {
            Text(meta.joined(separator: " • "))
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }

        if let definition = item.assemblyDefinition {
            Label(
                "\(definition.presentation.label) package • \(definition.components.count) included",
                systemImage: "shippingbox"
            )
            .font(.caption2)
            .foregroundStyle(Color.brandGold)
            .accessibilityIdentifier("ItemAssemblyContext-\(item.id.uuidString)")
        } else if let assembly = selectedItemAssemblySnapshots[item.id] {
            Label(assembly.lineContext, systemImage: "shippingbox")
                .font(.caption2)
                .foregroundStyle(Color.brandGold)
        }
    }

    @ViewBuilder
    private func catalogSyncStateLabel(for item: Item) -> some View {
        let state = item.quickBooksCatalogSyncState
        if state == "archived" {
            Label("Archived from new work", systemImage: "archivebox")
                .font(.caption2)
                .foregroundStyle(Color.secondary)
                .accessibilityIdentifier("CatalogSyncState-\(item.id.uuidString)")
        } else if state == "needs_review" {
            Label("Admin pricebook review", systemImage: "person.badge.clock")
                .font(.caption2)
                .foregroundStyle(Color.orange)
                .accessibilityIdentifier("CatalogSyncState-\(item.id.uuidString)")
        } else if isQuickBooksConnected, state != "synced" {
            let needsAttention = state == "needs_attention"
            Label(
                needsAttention
                    ? "QBO needs attention"
                    : (state == "pending_update" ? "QBO update pending" : "QBO publication pending"),
                systemImage: needsAttention ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath"
            )
            .font(.caption2)
            .foregroundStyle(needsAttention ? Color.orange : Color.secondary)
            .accessibilityIdentifier("CatalogSyncState-\(item.id.uuidString)")
        }
    }

    private func populateCustomerFields(from customer: Customer) {
        customerSearchText = customer.name
        customerName = customer.name
        customerPhone = customer.phone ?? ""
        customerEmail = customer.email ?? ""
        customerAddress = customer.address ?? ""
    }

    private func synchronizeServiceLocation(for customer: Customer) {
        if let activeServiceCall, activeServiceCall.customer.id == customer.id {
            selectedServiceLocationID = activeServiceCall.serviceLocationID
            return
        }
        if CustomerServiceLocationPolicy.location(
            id: selectedServiceLocationID,
            customerID: customer.id,
            in: serviceLocations
        ) != nil {
            return
        }
        selectedServiceLocationID = CustomerServiceLocationPolicy
            .preferredLocation(for: customer.id, in: serviceLocations)?.id
    }

    private func saveCustomerProfile() {
        let customer = resolveCustomerForDocument()
        selectedCustomerID = customer.id
        BillingCustomerHandoff.apply(customer: customer, to: activeServiceCall)
        if isQuickBooksConnected, customer.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            syncCustomerToQuickBooks(customer)
        } else {
            actionMessage = customer.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? "\(customer.name) saved and linked to QuickBooks."
                : "\(customer.name) saved locally."
        }
    }

    private func syncCustomerToQuickBooks(_ customer: Customer) {
        actionMessage = "Reconciling \(customer.name) with QuickBooks..."
        liveAPI.recoverOrCreateCustomer(
            QuickBooksCustomerCreateOperation.draft(for: customer)
        ) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let quickBooksCustomer):
                    customer.quickBooksID = quickBooksCustomer.Id
                    do {
                        try modelContext.save()
                        actionMessage = "\(customer.name) is linked to QuickBooks."
                    } catch {
                        actionMessage = "QuickBooks linked \(customer.name), but the local confirmation could not be saved: \(error.localizedDescription)"
                    }
                case .failure(let error):
                    actionMessage = "\(customer.name) saved locally. QuickBooks customer sync failed: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Isolate the current-job document cards from the root List's generic
    /// metadata. This keeps job closeout behavior intact while avoiding the
    /// same type-construction depth that previously exhausted the invoice tab.
    private var currentJobDocumentsSection: AnyView {
                AnyView(Group {
                    if (canViewFinancials || canCollectFieldPayments) &&
                        (currentJobEstimate != nil || currentJobInvoice != nil) &&
                        (!isJobDocumentationMode || selectedJobStage == .billing) {
                        Section("Current Job Documents") {
                            AnyView(Group {
                        if let estimate = currentJobEstimate {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Estimate")
                                    .font(.headline)
                                if estimate.isChangeOrder {
                                    Text("Change order • replaces the prior proposal only after this revision is approved")
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                    if let reason = estimate.changeOrderReason, !reason.isEmpty {
                                        Text("Reason: \(reason)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                if estimate.isProposalOption {
                                    Text("Proposal option: \(estimate.proposalOptionDisplayDetail)")
                                        .font(.caption2)
                                        .foregroundColor(estimate.proposalIsRecommended ? .green : .secondary)
                                }
                                if canViewFinancials {
                                    Text(estimateAmountStatus(estimate))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                } else {
                                    Text(estimate.status.capitalized)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Text(estimate.lineItemSummary)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                if let approvedAt = estimate.customerApprovedAt {
                                    Text(estimateApprovalDetail(estimate, approvedAt: approvedAt))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    if let method = estimate.customerApprovalMethod {
                                        Text("Method: \(method.displayName)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                if currentJobProposalOptions.count > 1 {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("Proposal Options")
                                            .font(.caption.weight(.semibold))
                                        ForEach(currentJobProposalOptions) { option in
                                            proposalOptionRow(
                                                option,
                                                currentEstimateID: estimate.id
                                            )
                                        }
                                        if let issue = EstimateProposalPolicy.selectionIssue(for: estimate, in: estimates) {
                                            Text(issue)
                                                .font(.caption2)
                                                .foregroundStyle(.orange)
                                        } else if estimate.proposalIsFinalized {
                                            Text("The approved option is locked. Use a change order for later scope or price changes.")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.top, 2)
                                }
                                Button("Resume Estimate") {
                                    loadEstimateIntoBuilder(estimate)
                                }
                                .buttonStyle(.bordered)

                                if estimate.status == "accepted", currentJobInvoice == nil {
                                    Button("Create Change Order") {
                                        beginChangeOrder(from: estimate)
                                    }
                                    .buttonStyle(.bordered)
                                }

                                let financingEligibility = customerFinancingEligibility(for: estimate)
                                Menu {
                                    Button {
                                        generateEstimateDocument(estimate)
                                    } label: {
                                        Label("Generate Estimate PDF", systemImage: "doc.richtext")
                                    }

                                    Button {
                                        sendEstimateThroughQuickBooks(estimate)
                                    } label: {
                                        Label("Send Through QuickBooks", systemImage: "paperplane")
                                    }
                                    .disabled(!QuickBooksDataAPI.shared.isAuthenticated || estimate.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false)

                                    if let estimateFollowUpEmailURL {
                                        Button {
                                            openEstimateFollowUpEmail(for: estimate, fallbackURL: estimateFollowUpEmailURL)
                                        } label: {
                                            Label("Draft Estimate Follow-Up", systemImage: "envelope")
                                        }
                                    }

                                    if financingEligibility.isEligible {
                                        Divider()
                                        Button {
                                            selectedEstimateForFinancing = estimate
                                        } label: {
                                            Label("Offer Customer Financing", systemImage: "dollarsign.circle")
                                        }
                                    }
                                } label: {
                                    Label("More Estimate Actions", systemImage: "ellipsis.circle")
                                }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("EstimateMoreActions")

                                HStack {
                                    Button("Record Customer Approval") {
                                        selectedEstimateForApproval = estimate
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(estimate.hasRecordedCustomerApproval)

                                    Button("Mark Rejected") {
                                        estimate.status = "rejected"
                                        activeServiceCall?.followUpRequired = false
                                        activeServiceCall?.followUpAction = nil
                                        activeServiceCall?.followUpDueDate = nil
                                        actionMessage = "Estimate marked rejected."
                                    }
                                    .buttonStyle(.bordered)
                                }

                                if estimate.status == "accepted" {
                                    if let scheduledWork = scheduledApprovedWork(for: estimate) {
                                        Button("Open Scheduled Work") {
                                            GunnAireAppIntentRouter.storeScheduleCallRoute(scheduledWork.id)
                                        }
                                        .buttonStyle(.bordered)
                                    } else if canScheduleApprovedWork {
                                        Button("Schedule Approved Work") {
                                            presentApprovedWorkSchedule(for: estimate)
                                        }
                                        .buttonStyle(.bordered)
                                        .disabled(!estimate.hasRecordedCustomerApproval)
                                    } else {
                                        Text("Dispatch or an administrator must schedule approved work.")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    if !estimate.hasRecordedCustomerApproval {
                                        Text("Record traceable customer approval before scheduling work.")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                }

                                if currentJobInvoice == nil {
                                    Button("Create Invoice From Estimate") {
                                        createInvoiceFromEstimate(estimate)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(Color.brandGold)
                                    .foregroundStyle(Color.primaryBlack)
                                    .disabled(!canCreateOrOpenInvoice(from: estimate))
                                    if let message = invoiceCreationBlockedMessage(for: estimate) {
                                        Text(message)
                                            .font(.caption)
                                            .foregroundColor(.orange)
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                            })

                            AnyView(Group {
                        if let invoice = currentJobInvoice {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(invoice.projectBillingDisplayTitle ?? "Invoice")
                                    .font(.headline)
                                if let projectBillingAuditSummary = invoice.projectBillingAuditSummary {
                                    Text(projectBillingAuditSummary)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if canViewFinancials {
                                    Text(invoiceAmountStatus(invoice))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                } else {
                                    Text(invoiceDisplayStatus(for: invoice))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                if canViewFinancials, let currentJobBalanceDue {
                                    Text("Balance due: \(currentJobBalanceDue, format: .currency(code: "USD"))")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text("\(Invoice.dueStatusDetail(for: invoice, payments: currentJobPayments)) • \(invoice.paymentTermsDisplayName)")
                                        .font(.caption2)
                                        .foregroundStyle(isInvoiceOverdue(invoice) ? Color.red : Color.secondary)
                                }
                                if canViewFinancials && !currentJobPayments.isEmpty {
                                    Text("Payments recorded: \(currentJobPayments.count)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    ForEach(currentJobPayments.prefix(3)) { payment in
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(paymentFinancialDetail(payment))
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                            if let processorDisplayName = payment.processorDisplayName {
                                                Text("Processor: \(processorDisplayName)")
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                    }
                                }
                                if canViewFinancials, let quickBooksID = invoice.quickBooksID, !quickBooksID.isEmpty {
                                    Text("QuickBooks ID: \(quickBooksID)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                if canCollectFieldPayments {
                                    Button(isInvoicePaid(invoice) ? "Invoice Paid" : "Collect Payment") {
                                        openInvoiceCloseout(invoice)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(Color.brandGold)
                                    .foregroundStyle(Color.primaryBlack)
                                    .disabled(isInvoicePaid(invoice))

                                    Button("Resume Invoice") {
                                        openInvoiceCloseout(invoice)
                                    }
                                    .buttonStyle(.bordered)
                                }

                                Button("Send Invoice Through QuickBooks") {
                                    sendInvoiceThroughQuickBooks(invoice)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.blue)
                                .disabled(!QuickBooksDataAPI.shared.isAuthenticated || invoice.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false)

                                Button("Generate Invoice PDF") {
                                    generateInvoiceDocument(invoice)
                                }
                                .buttonStyle(.bordered)

                                if canCollectFieldPayments && !isInvoicePaid(invoice) {
                                    Button("Record Additional Payment") {
                                        openInvoiceCloseout(invoice)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                            })
                        }
                    }
                })
    }

    @ViewBuilder
    private var estimateActionQueues: some View {
                if !isJobDocumentationMode && workspaceMode.showsEstimates && !estimatesNeedingFollowUp.isEmpty {
                    Section("Estimate Follow-Up") {
                        ForEach(estimatesNeedingFollowUp.prefix(6)) { estimate in
                            let linkedCall = serviceCall(for: estimate)
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(estimate.customer.name)
                                            .font(.headline)
                                        Text(estimateAmountStatus(estimate))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Text(estimate.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Text(estimate.lineItemSummary)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                HStack {
                                    Button("Load Estimate") {
                                        loadEstimateIntoBuilder(estimate)
                                    }
                                    .buttonStyle(.bordered)

                                    if let linkedCall {
                                        Button("Open Job") {
                                            openDocumentation(for: linkedCall)
                                        }
                                        .buttonStyle(.bordered)
                                    }

                                    if let followUpURL = followUpEmailURL(for: estimate) {
                                        Button("Draft Follow-Up") {
                                            openEstimateFollowUpEmail(for: estimate, fallbackURL: followUpURL)
                                        }
                                        .buttonStyle(.bordered)
                                    }

                                    Button("Create Invoice") {
                                        createInvoiceFromEstimate(estimate)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(Color.brandGold)
                                    .foregroundStyle(Color.primaryBlack)
                                    .disabled(!canCreateOrOpenInvoice(from: estimate))
                                }
                                if let message = invoiceCreationBlockedMessage(for: estimate) {
                                    Text(message)
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                if !isJobDocumentationMode && workspaceMode.showsEstimates && !acceptedEstimatesReadyToSchedule.isEmpty {
                    Section("Accepted Estimates") {
                        ForEach(acceptedEstimatesReadyToSchedule.prefix(6)) { estimate in
                            let linkedCall = serviceCall(for: estimate)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(estimate.customer.name)
                                    .font(.headline)
                                Text("\(estimate.amount, format: .currency(code: "USD")) • Accepted")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(linkedCall == nil
                                     ? "Choose the work type and appointment time to create an unassigned work order."
                                     : "Choose the appointment time to create a separate approved-work order.")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                HStack {
                                    if let linkedCall {
                                        Button("Open Job") {
                                            openDocumentation(for: linkedCall)
                                        }
                                        .buttonStyle(.bordered)

                                    }

                                    Button("Schedule Work") {
                                        presentApprovedWorkSchedule(for: estimate)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(Color.brandGold)
                                    .foregroundStyle(Color.primaryBlack)
                                    .disabled(!canScheduleApprovedWork || !estimate.hasRecordedCustomerApproval)

                                    Button("Create Invoice") {
                                        createInvoiceFromEstimate(estimate)
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(!canCreateOrOpenInvoice(from: estimate))
                                }
                                if let message = invoiceCreationBlockedMessage(for: estimate) {
                                    Text(message)
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                }
                                if !estimate.hasRecordedCustomerApproval {
                                    Text("Record traceable customer approval before scheduling work.")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

    }

    @ViewBuilder
    private var invoiceActionQueues: some View {
                if canIssueMaintenanceAgreementInvoices &&
                    !isJobDocumentationMode &&
                    workspaceMode.showsInvoices &&
                    !maintenanceAgreementsNeedingBillingSetup.isEmpty {
                    Section("Agreement Billing Setup") {
                        ForEach(maintenanceAgreementsNeedingBillingSetup.prefix(6)) { agreement in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(agreement.customer.name)
                                            .font(.headline)
                                        Text(agreement.displayName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if let price = agreement.agreementPrice {
                                        Text(price, format: .currency(code: "USD"))
                                            .font(.subheadline.weight(.semibold))
                                    }
                                }
                                Text(maintenanceAgreementBillingSetupDetail(for: agreement))
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                if canConfigureMaintenanceAgreementBilling {
                                    Button("Configure Billing") {
                                        agreementBillingSetupPending = agreement
                                    }
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier("ConfigureAgreementBilling-\(agreement.id.uuidString)")
                                } else {
                                    Label("Administrator setup required", systemImage: "lock.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                if canIssueMaintenanceAgreementInvoices &&
                    !isJobDocumentationMode &&
                    workspaceMode.showsInvoices &&
                    !maintenanceAgreementBillingCandidates.isEmpty {
                    Section("Service Agreements Due for Billing") {
                        ForEach(maintenanceAgreementBillingCandidates.prefix(8)) { candidate in
                            if let agreement = maintenanceAgreement(for: candidate),
                               let billingItem = billingCatalogItem(for: candidate) {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(agreement.customer.name)
                                                .font(.headline)
                                            Text("\(agreement.displayName) • \(candidate.interval.displayName)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(candidate.amount, format: .currency(code: "USD"))
                                            .font(.subheadline.weight(.semibold))
                                    }
                                    Text("Billing cycle due \(candidate.cycleDueDate.formatted(date: .abbreviated, time: .omitted)) • \(billingItem.name)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Button("Review & Create Invoice") {
                                        agreementBillingCandidatePendingReview = candidate
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(Color.brandGold)
                                    .foregroundStyle(Color.primaryBlack)
                                    .accessibilityIdentifier("ReviewAgreementInvoice-\(candidate.id)")
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        if maintenanceAgreementBillingCandidates.count > 8 {
                            Text("Create the oldest invoices first; the queue will reveal the next due agreements automatically.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if canViewFinancials &&
                    !isJobDocumentationMode &&
                    workspaceMode.showsInvoices &&
                    !projectMilestonesReadyForBilling.isEmpty {
                    Section("Project Milestones Ready") {
                        ForEach(projectMilestonesReadyForBilling.prefix(8)) { milestone in
                            if let linkedCall = serviceCalls.first(where: { $0.id == milestone.projectServiceCallID }) {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(linkedCall.customer.name)
                                                .font(.headline)
                                            Text("Progress invoice \(milestone.sequence + 1) • \(milestone.title)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(milestone.plannedAmount, format: .currency(code: "USD"))
                                            .font(.subheadline.weight(.semibold))
                                    }
                                    Text("\(milestone.billingPercent.formatted(.number.precision(.fractionLength(0...2))))% of approved project scope • ready for accounting review")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Button("Open Project & Issue Invoice") {
                                        openDocumentation(for: linkedCall)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(Color.brandGold)
                                    .foregroundStyle(Color.primaryBlack)
                                    .accessibilityIdentifier("OpenReadyProjectMilestone-\(milestone.id.uuidString)")
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }

                if canViewFinancials && !isJobDocumentationMode && workspaceMode.showsInvoices && !collectionQueueInvoices.isEmpty {
                    Section("Collections Queue") {
                        ForEach(collectionQueueInvoices) { invoice in
                            let linkedCall = serviceCall(for: invoice)
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(invoice.customer.name)
                                            .font(.headline)
                                        Text("Balance due: \(invoiceBalanceDue(for: invoice), format: .currency(code: "USD"))")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Text("Due \(invoice.effectiveDueDate().formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                HStack {
                                    Button("Open Invoice") {
                                        openInvoiceCloseout(invoice)
                                    }
                                    .buttonStyle(.bordered)

                                    if let linkedCall {
                                        Button("Open Job") {
                                            openDocumentation(for: linkedCall)
                                        }
                                        .buttonStyle(.bordered)
                                    }

                                    if let reminderURL = paymentReminderEmailURL(for: invoice) {
                                        Button("Draft Reminder") {
                                            openPaymentReminderEmail(for: invoice, fallbackURL: reminderURL)
                                        }
                                        .buttonStyle(.bordered)
                                    }

                                    Button("Collect Payment") {
                                        openInvoiceCloseout(invoice)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.green)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                if canViewFinancials && !isJobDocumentationMode && workspaceMode.showsInvoices && !overdueInvoicesOutsideCollectionsQueue.isEmpty {
                    Section("Overdue Invoices") {
                        ForEach(overdueInvoicesOutsideCollectionsQueue.prefix(6)) { invoice in
                            let linkedCall = serviceCall(for: invoice)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(invoice.customer.name)
                                    .font(.headline)
                                Text("\(Invoice.dueStatusDetail(for: invoice, payments: payments)) • \(invoiceBalanceDue(for: invoice), format: .currency(code: "USD")) due")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                                Text(invoice.lineItemSummary)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                HStack {
                                    Button("Open Invoice") {
                                        openInvoiceCloseout(invoice)
                                    }
                                    .buttonStyle(.bordered)

                                    if let linkedCall {
                                        Button("Open Job") {
                                            openDocumentation(for: linkedCall)
                                        }
                                        .buttonStyle(.bordered)
                                    }

                                    if let reminderURL = paymentReminderEmailURL(for: invoice) {
                                        Button("Draft Reminder") {
                                            openPaymentReminderEmail(for: invoice, fallbackURL: reminderURL)
                                        }
                                        .buttonStyle(.bordered)
                                    }

                                    Button("Collect Payment") {
                                        openInvoiceCloseout(invoice)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.green)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

    }

    @ViewBuilder
    private var equipmentHistorySection: some View {
                if !relatedEquipmentCalls.isEmpty {
                    Section("Equipment History") {
                        ForEach(relatedEquipmentCalls.prefix(5)) { historyCall in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(serviceCallSummaryLine(historyCall))
                                    .font(.caption)
                                Text(historyCall.scheduledDate.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                if let notes = historyCall.notes, !notes.isEmpty {
                                    Text(notes)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

    }

    @ViewBuilder
    private var builderDetailsWorkspaceSection: some View {
                if !isJobDocumentationMode {
                Section(workspaceMode == .invoices ? "Invoice Details" : "Builder Details") {
                    if workspaceMode == .all {
                        Picker("Document", selection: $selectedDocumentKind) {
                            ForEach(BillingDocumentKind.allCases) { kind in
                                Text(kind.rawValue).tag(kind)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    SearchableDropdownPicker(
                        title: "Customer",
                        options: customerDropdownOptions,
                        selectedID: selectedCustomerDropdownID,
                        placeholder: "Select Customer",
                        showsClearButton: true
                    )

                    if let editingInvoiceID = selectedInvoiceForEditingID,
                       let editingInvoice = invoices.first(where: { $0.id == editingInvoiceID }) {
                        Label(
                            "Editing \(editingInvoice.customer.name)'s existing invoice",
                            systemImage: "square.and.pencil"
                        )
                        .font(.caption)
                        .foregroundStyle(Color.brandGold)
                        .accessibilityIdentifier("ExistingInvoiceEditContext")

                        Button("Cancel Invoice Edit", role: .cancel) {
                            finishInvoiceWorkspaceEditing(
                                message: "Invoice edit cancelled. The saved invoice was not changed."
                            )
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("CancelInvoiceWorkspaceEdit")
                    }

                    if let selectedCustomer {
                        if let call = activeServiceCall {
                            LabeledContent("Service Property") {
                                Text(call.siteAddress ?? selectedCustomer.address ?? "Not set")
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                            }
                        } else if !selectableServiceLocations.isEmpty {
                            Picker("Service Property", selection: serviceLocationSelection) {
                                Text("Billing / default address").tag(nil as UUID?)
                                ForEach(selectableServiceLocations) { location in
                                    Text(serviceLocationOptionTitle(location))
                                        .tag(location.id as UUID?)
                                }
                            }
                            if let address = selectedSiteAddressSnapshot {
                                Text(documentServiceAddressDetail(address))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if let call = activeServiceCall {
                        Button(selectedCustomerID == call.customer.id ? "Using Job Customer" : "Use Job Customer") {
                            selectedCustomerID = call.customer.id
                            populateCustomerFields(from: call.customer)
                        }
                        .disabled(selectedCustomerID == call.customer.id)
                    }

                    if customers.isEmpty {
                        Text("Create a customer before making invoices or estimates.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...5)

                    if changeOrderParentEstimateID != nil {
                        TextField("Change order reason", text: $changeOrderReason, axis: .vertical)
                            .lineLimit(1...3)
                        Text("The original proposal is retained. This revision must be approved before it can be scheduled or invoiced.")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }

                    if selectedDocumentKind == .estimate {
                        Picker("Present as", selection: $proposalOption) {
                            ForEach(EstimateProposalOption.allCases) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                        if proposalOption != .standalone {
                            Toggle("Recommended option", isOn: $proposalIsRecommended)
                            Text("Create each Good, Better, and Best option with its own line items. The customer chooses one before approval.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Button("End Proposal Set") {
                                endProposalSet()
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    if activeServiceCall != nil {
                        Button("Save Notes Back To Job") {
                            syncNotesToJob()
                        }
                        .buttonStyle(.bordered)
                    }

                    lineItemBuilderView

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Job Costing")
                            .font(.headline)
                        HStack {
                            Text("Revenue")
                            Spacer()
                            Text(selectedTotal, format: .currency(code: "USD"))
                                .foregroundColor(.secondary)
                        }
                        HStack {
                            Text("Materials cost")
                            Spacer()
                            Text(selectedCostTotal, format: .currency(code: "USD"))
                                .foregroundColor(.secondary)
                        }
                        HStack {
                            Text("Completed labor cost")
                            Spacer()
                            if let selectedLaborCost {
                                Text(selectedLaborCost, format: .currency(code: "USD"))
                                    .foregroundColor(.secondary)
                            } else {
                                Text(laborCostAvailabilityMessage)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        HStack {
                            Text("Job cost")
                            Spacer()
                            Text(selectedJobCostTotal, format: .currency(code: "USD"))
                                .foregroundColor(.secondary)
                        }
                        HStack {
                            Text(grossProfitLabel)
                            Spacer()
                            Text(selectedGrossProfit, format: .currency(code: "USD"))
                                .foregroundColor(selectedGrossProfit >= 0 ? .secondary : .red)
                        }
                        if let selectedGrossMarginPercent {
                            HStack {
                                Text("Gross Margin")
                                Spacer()
                                Text("\(selectedGrossMarginPercent, format: .number.precision(.fractionLength(1)))%")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    if activeServiceCall != nil && selectedDocumentKind == .estimate {
                        Toggle("Open Invoice Builder After Estimate", isOn: $openInvoiceAfterEstimateCreation)
                    }

                    Button(documentActionTitle) {
                        createDocument()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brandGold)
                    .foregroundStyle(Color.primaryBlack)
                    .disabled(documentActionIsDisabled)

                    if selectedDocumentKind == .invoice,
                       let message = invoiceWorkflowBlockedMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundColor(.orange)
                    }

                    if !actionMessage.isEmpty {
                        Text(actionMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section("Customer") {
                    TextField("Customer name", text: $customerName)
                    TextField("Address", text: $customerAddress, axis: .vertical)
                        .lineLimit(2...3)
                    if mapsURL != nil || phoneURL != nil || emailURL != nil {
                        HStack {
                            if let phoneURL {
                                Button {
                                    openURL(phoneURL)
                                } label: {
                                    Label("Call", systemImage: "phone")
                                }
                                .buttonStyle(.bordered)
                            }
                            if let emailURL {
                                Button {
                                    openURL(emailURL)
                                } label: {
                                    Label("Email", systemImage: "envelope")
                                }
                                .buttonStyle(.bordered)
                            }
                            if let mapsURL {
                                Button {
                                    openURL(mapsURL)
                                } label: {
                                    Label("Driving Directions", systemImage: "map")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    TextField("Phone", text: $customerPhone)
                        .keyboardType(.phonePad)
                    TextField("Email", text: $customerEmail)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)

                    Button(selectedCustomer == nil ? "Save New Customer" : "Update Customer") {
                        saveCustomerProfile()
                    }
                    .disabled(customerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if isQuickBooksConnected {
                        Text("New customers and approved catalog items publish through QuickBooks. Field-created items wait for administrator review; estimates and invoices sync after every selected line is mapped.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                }

    }

    @ViewBuilder
    private var estimatesWorkspaceSection: some View {
                if canViewFinancials && !isJobDocumentationMode && workspaceMode.showsEstimates {
                    Section("Estimates") {
                        if displayedEstimates.isEmpty {
                            Text("No estimates yet.")
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(displayedEstimates) { estimate in
                                let documentationStatus = serviceCall(for: estimate)?.estimateDocumentationStatus(
                                    estimate: estimate,
                                    attachments: attachments
                                )
                                DisclosureGroup {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(estimate.lineItemSummary)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        if let documentationStatus {
                                            Label(
                                                documentationStatus.sendReadinessLabel,
                                                systemImage: documentationStatus.isReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                                            )
                                            .font(.caption2)
                                            .foregroundColor(documentationStatus.isReady ? .green : .orange)
                                            Text(documentationStatus.summary)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                            Text(documentationStatus.actionSummary)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        if let quickBooksID = estimate.quickBooksID, !quickBooksID.isEmpty {
                                            Text("QuickBooks ID: \(quickBooksID)")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        Button("Create Invoice") {
                                            createInvoiceFromEstimate(estimate)
                                        }
                                        .buttonStyle(.bordered)
                                        .disabled(estimate.status == "invoiced" || !canCreateOrOpenInvoice(from: estimate))
                                        if let message = invoiceCreationBlockedMessage(for: estimate) {
                                            Text(message)
                                                .font(.caption2)
                                                .foregroundColor(.orange)
                                        }

                                        Button("Generate Estimate PDF") {
                                            generateEstimateDocument(estimate)
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                    .padding(.top, 6)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(estimate.customer.name)
                                                .font(.headline)
                                            Text(estimateListDetail(estimate))
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            if let documentationStatus {
                                                Text(documentationStatus.sendReadinessLabel)
                                                    .font(.caption2)
                                                    .foregroundColor(documentationStatus.isReady ? .green : .orange)
                                                    .lineLimit(1)
                                            }
                                        }
                                        Spacer()
                                        Text(estimate.amount, format: .currency(code: "USD"))
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }

    }

    @ViewBuilder
    private var invoicesWorkspaceSection: some View {
                if !isJobDocumentationMode && workspaceMode.showsInvoices {
                    Section("Invoices") {
                        if displayedInvoices.isEmpty {
                            Text("No invoices yet.")
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(displayedInvoices) { invoice in
                                let documentationStatus = serviceCall(for: invoice)?.invoiceDocumentationStatus(
                                    invoice: invoice,
                                    attachments: attachments
                                )
                                DisclosureGroup {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(invoice.lineItemSummary)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        if let documentationStatus {
                                            Label(
                                                documentationStatus.sendReadinessLabel,
                                                systemImage: documentationStatus.isReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                                            )
                                            .font(.caption2)
                                            .foregroundColor(documentationStatus.isReady ? .green : .orange)
                                            Text(documentationStatus.summary)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                            Text(documentationStatus.actionSummary)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        if let signatureName = invoice.customerSignatureName, !signatureName.isEmpty {
                                            Text("Signed by \(signatureName)")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        if invoice.finalizedAt != nil {
                                            Text("Finalized")
                                                .font(.caption2)
                                                .foregroundColor(.green)
                                        }
                                        if canEditInvoice(invoice) {
                                            Button("Edit Line Items") {
                                                beginEditingInvoice(invoice)
                                            }
                                            .buttonStyle(.bordered)
                                            .accessibilityIdentifier("EditInvoice-\(invoice.id.uuidString)")
                                        } else if let lockMessage = BillingInvoiceMutationPolicy.blockedMessage(
                                            for: invoice,
                                            payments: payments
                                        ) {
                                            Label("Line items locked", systemImage: "lock.fill")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .accessibilityHint(lockMessage)
                                        }
                                        if canCollectFieldPayments {
                                            Button("Open Invoice") {
                                                openInvoiceCloseout(invoice)
                                            }
                                            .buttonStyle(.bordered)

                                            Button(isInvoicePaid(invoice) ? "Paid" : "Collect Payment") {
                                                openInvoiceCloseout(invoice)
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .tint(Color.brandGold)
                                            .foregroundStyle(Color.primaryBlack)
                                            .disabled(isInvoicePaid(invoice))
                                        }

                                        Button("Generate Invoice PDF") {
                                            generateInvoiceDocument(invoice)
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                    .padding(.top, 6)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(invoice.customer.name)
                                                .font(.headline)
                                            Text(invoiceListDetail(invoice))
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            if let documentationStatus {
                                                Text(documentationStatus.sendReadinessLabel)
                                                    .font(.caption2)
                                                    .foregroundColor(documentationStatus.isReady ? .green : .orange)
                                                    .lineLimit(1)
                                            }
                                        }
                                        Spacer()
                                        if canViewFinancials {
                                            Text(invoice.amount, format: .currency(code: "USD"))
                                        }
                                    }
                                }
                                .accessibilityIdentifier("InvoiceDisclosure-\(invoice.id.uuidString)")
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }

    }

    @ViewBuilder
    private var paymentsWorkspaceSection: some View {
                if canViewFinancials && !isJobDocumentationMode && workspaceMode.showsPayments {
                    Section("Payments") {
                        if payments.isEmpty {
                            Text("No payments recorded yet.")
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(payments.prefix(12)) { payment in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(payment.invoice.customer.name)
                                        Text(paymentDisplayDetail(payment))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        if let processorDisplayName = payment.processorDisplayName {
                                            Text("Processor: \(processorDisplayName)")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Text(payment.amount, format: .currency(code: "USD"))
                                }
                            }
                        }
                    }
                }
    }

    /// Keep the job-only branch behind a concrete type-erasure boundary.
    ///
    /// This workspace contains a deliberately rich set of job sections. When
    /// the branch was exposed as one deeply nested opaque View type, SwiftUI
    /// attempted to materialize all of that generic metadata even when the
    /// invoice workspace did not have an active job. On physical devices that
    /// exhausted the main-thread stack while opening the Invoices tab.
    private var activeJobSections: AnyView {
        guard let call = activeServiceCall else {
            return AnyView(EmptyView())
        }

        return AnyView(Group {
                    Section("Job") {
                        Text(call.customer.name)
                            .font(.headline)
                        Text(call.scheduledDate.formatted(date: .abbreviated, time: .shortened))
                            .foregroundColor(.secondary)
                        Text("Job Type: \(call.type.displayName)")
                            .foregroundColor(.secondary)
                        if let selectedJobAddress {
                            Button {
                                if let mapsURL {
                                    openURL(mapsURL)
                                }
                            } label: {
                                Label(selectedJobAddress, systemImage: "map")
                                    .foregroundColor(Color.brandGold)
                            }
                            .buttonStyle(.plain)
                        }
                        if let notes = call.notes, !notes.isEmpty {
                            Text(notes)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        if let findingsSummary = call.findingsSummary, !findingsSummary.isEmpty {
                            Text("Findings: \(findingsSummary)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        if let recommendedWorkSummary = call.recommendedWorkSummary, !recommendedWorkSummary.isEmpty {
                            Text("Recommended Work: \(recommendedWorkSummary)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        if call.followUpRequired {
                            Text("Follow-up required")
                                .font(.caption2)
                                .foregroundColor(.orange)
                            if let followUpAction = call.followUpAction, !followUpAction.isEmpty {
                                Text("Next action: \(followUpAction)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            if let followUpDueDate = call.followUpDueDate {
                                Text("Due: \(followUpDueDate.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Button("Schedule Follow-Up Visit") {
                                scheduleFollowUpVisit(for: call)
                            }
                            .buttonStyle(.bordered)
                        }
                        if let equipmentSummary = call.equipmentSummary {
                            Text(equipmentSummary)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        let lifecycle = call.equipmentLifecycleSnapshot
                        if let lifecycleSummary = lifecycle.summary {
                            Text(lifecycleSummary)
                                .font(.caption2)
                                .foregroundColor(
                                    lifecycle.attention == .invalidDates
                                        ? .red
                                        : lifecycle.attention == .none ? .secondary : .orange
                                )
                                .accessibilityIdentifier("JobDocumentationEquipmentLifecycle")
                        }
                        if let planning = activeEquipmentServicePlanningSnapshot,
                           planning.needsAttention,
                           let planningTitle = planning.title,
                           let planningSummary = planning.summary {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(planningTitle)
                                        .font(.caption.weight(.semibold))
                                    Text(planningSummary)
                                        .font(.caption2)
                                    Text("Planning cue—confirm the current diagnosis before presenting options.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: planning.attention == .replacementEvaluation ? "arrow.triangle.2.circlepath" : "wrench.adjustable")
                            }
                            .foregroundStyle(planning.overdueFollowUpCount > 0 ? Color.red : Color.orange)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(planningTitle). \(planningSummary). Planning cue only; confirm before presenting options.")
                            .accessibilityIdentifier("JobDocumentationEquipmentServicePlanning")
                        }
                    }

                    Section("Job Workspace") {
                        Picker("Stage", selection: $selectedJobStage) {
                            ForEach(JobDocumentationStage.allCases) { stage in
                                Text(stage.label).tag(stage)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("JobDocumentationStagePicker")

                        Label(selectedJobStage.guidance, systemImage: selectedJobStage.systemImage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if selectedJobStage == .work || selectedJobStage == .billing {
                        projectBillingSection(for: call)
                    }

                    if selectedJobStage == .closeout {
                        closeoutReadinessSection(for: call)
                    }
                    if selectedJobStage == .work {
                        technicalServiceReportSection(for: call)
                        jobFieldFormsSection(for: call)
                    }
                    if selectedJobStage == .files {
                        equipmentAttachmentHistorySection(for: call)
                        attachmentSection(for: call)
                    }

                    if selectedJobStage == .billing {
                        Section("Documentation Builder") {
                        if allowsDocumentSwitching {
                            Picker("Document", selection: $selectedDocumentKind) {
                                ForEach(BillingDocumentKind.allCases) { kind in
                                    Text(kind.rawValue).tag(kind)
                                }
                            }
                            .pickerStyle(.segmented)
                        } else {
                            HStack {
                                Text("Document")
                                Spacer()
                                Text(selectedDocumentKind.rawValue)
                                    .foregroundColor(.secondary)
                            }
                        }

                        HStack {
                            Text("Customer")
                            Spacer()
                            Text(customerSelectionDisplayName)
                                .foregroundColor(.secondary)
                        }

                        if selectedDocumentKind == .invoice {
                            Picker("Payment Terms", selection: $selectedInvoicePaymentTerms) {
                                ForEach(InvoicePaymentTerms.allCases) { terms in
                                    Text(terms.displayName).tag(terms)
                                }
                            }
                            .accessibilityIdentifier("InvoicePaymentTerms")

                            if selectedInvoicePaymentTerms == .custom {
                                DatePicker(
                                    "Due Date",
                                    selection: $invoiceCustomDueDate,
                                    in: Calendar.current.startOfDay(for: invoiceTermsIssueDate)...,
                                    displayedComponents: .date
                                )
                                .accessibilityIdentifier("InvoiceDueDate")
                            } else {
                                LabeledContent(
                                    "Due Date",
                                    value: resolvedInvoiceDueDate.formatted(date: .abbreviated, time: .omitted)
                                )
                            }

                            Text("The same due date drives customer documents, overdue queues, reminders, and QuickBooks.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Text("Selected Items")
                            Spacer()
                            Text("\(selectedLineItems.count)")
                                .foregroundColor(.secondary)
                        }

                        HStack(spacing: 10) {
                            Button {
                                showingItemSelector = true
                            } label: {
                                Label("Add Line Items", systemImage: "plus.circle")
                            }

                            Button {
                                showingItemCreator = true
                            } label: {
                                Label("Create New Item", systemImage: "plus.square.on.square")
                            }
                        }
                        .buttonStyle(.bordered)
                        .foregroundStyle(Color.brandGold)

                        if !selectedLineItems.isEmpty {
                            ForEach(selectedLineItems.prefix(5)) { item in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.name)
                                                .font(.caption)
                                            Text(lineItemQuantityLabel(for: item))
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                            if let assembly = selectedItemAssemblySnapshots[item.id] {
                                                Label(
                                                    assembly.presentation == .flatRate
                                                        ? "Flat-rate package • \(assembly.components.count) included"
                                                        : "From \(assembly.name)",
                                                    systemImage: "shippingbox"
                                                )
                                                .font(.caption2)
                                                .foregroundStyle(Color.brandGold)
                                                .accessibilityIdentifier("SelectedAssemblyContext-\(item.id.uuidString)")
                                            }
                                            if item.isTaxable {
                                                Text("Taxable")
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                            }
                                            catalogSyncStateLabel(for: item)
                                        }
                                        Spacer()
                                        VStack(alignment: .trailing, spacing: 4) {
                                            Text(effectiveUnitPrice(for: item) * lineItemQuantity(for: item), format: .currency(code: "USD"))
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            if let adjustment = selectedItemPriceAdjustments[item.id] {
                                                Text("\(adjustment.unitPrice < adjustment.pricebookUnitPrice ? "Discounted" : "Adjusted") from \(adjustment.pricebookUnitPrice.formatted(.currency(code: "USD")))")
                                                    .font(.caption2)
                                                    .foregroundStyle(.orange)
                                                    .accessibilityIdentifier(authorizedPriceAdjustmentAccessibilityID(for: item))
                                                    .accessibilityLabel(authorizedPriceAdjustmentAccessibilityLabel(for: item))
                                                    .accessibilityValue(adjustment.reason)
                                            }
                                            if canAuthorizePriceAdjustments {
                                                Button(selectedItemPriceAdjustments[item.id] == nil ? "Discount / Adjust" : "Edit Adjustment") {
                                                    itemPendingPriceAdjustment = item
                                                }
                                                .font(.caption2)
                                                .buttonStyle(.bordered)
                                                .accessibilityIdentifier(adjustPriceAccessibilityID(for: item))
                                            }
                                            HStack(spacing: 8) {
                                                Button {
                                                    removeCatalogLine(item.id)
                                                } label: {
                                                    Image(systemName: "minus.circle")
                                                }
                                                .buttonStyle(.borderless)
                                                .frame(width: 44, height: 44)
                                                .contentShape(Rectangle())
                                                .fixedSize()
                                                .layoutPriority(2)
                                                .accessibilityLabel("Remove \(item.name) from \(selectedDocumentKind.rawValue.lowercased())")
                                                .accessibilityIdentifier("RemoveBillingLine-\(item.id.uuidString)")

                                                Stepper(
                                                    lineItemQuantityLabel(for: item),
                                                    value: lineItemQuantityBinding(for: item),
                                                    in: 0.25...100,
                                                    step: 0.25
                                                )
                                                .labelsHidden()
                                                .fixedSize()
                                                .disabled(isItemizedAssemblyLine(item))
                                                .accessibilityLabel(lineItemQuantityAccessibilityLabel(for: item))
                                                .accessibilityValue(lineItemQuantityAccessibilityValue(for: item))
                                            }
                                        }
                                    }
                                    lineEquipmentPicker(for: item)
                                }
                            }

                            if selectedLineItems.count > 5 {
                                Text(selectedLineItemOverflowLabel)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            Button("Clear Selected Items") {
                                clearSelectedCatalogLines()
                            }
                            .buttonStyle(.bordered)
                        }

                        documentDiscountControls
                        documentSubtotalSummary

                        if selectedHasTaxableLines {
                            Label(
                                "QuickBooks calculates sales tax and the final total from the service address. Approval and collection stay locked until that total returns.",
                                systemImage: "building.columns"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("QuickBooksTaxCalculationNotice")
                        }

                        if let invoice = currentJobInvoice,
                           invoice.quickBooksSyncState != "synced" {
                            Label(
                                invoice.needsQuickBooksAttention ? "QuickBooks needs attention" : "QuickBooks update pending",
                                systemImage: invoice.needsQuickBooksAttention ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath"
                            )
                            .font(.caption)
                            .foregroundStyle(invoice.needsQuickBooksAttention ? Color.orange : Color.secondary)
                            if let detail = invoice.quickBooksSyncDetail, !detail.isEmpty {
                                Text(detail)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }

                        if selectedLineItems.isEmpty {
                            Text("Select or add at least one item below to enable estimate and invoice creation.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        if workspaceMode.showsEstimateBuilder {
                            Button(isCreatingDocument && selectedDocumentKind == .estimate ? "Creating Estimate..." : "Create Estimate") {
                                selectedDocumentKind = .estimate
                                createDocument()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)
                            .disabled(
                                isCreatingDocument ||
                                customerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                selectedItems.isEmpty ||
                                documentDiscountValidationMessage != nil
                            )
                        }

                        if workspaceMode.showsInvoiceBuilder {
                            Button(invoiceActionTitle) {
                                selectedDocumentKind = .invoice
                                createDocument()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                            .disabled(invoiceActionIsDisabled)
                            .accessibilityIdentifier("InvoicePrimaryAction")
                            if let message = invoiceWorkflowBlockedMessage {
                                Text(message)
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                        }
                        if let message = documentDiscountValidationMessage {
                            Text(message)
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                        if let selectedLaborCosting, selectedLaborCosting.uncostedMinutes > 0 {
                            Text(uncostedLaborDescription(selectedLaborCosting.uncostedMinutes))
                                .font(.caption)
                                .foregroundColor(.orange)
                        }

                        if !actionMessage.isEmpty {
                            Text(actionMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        }
                        jobMaterialsSection(for: call)
                    }

                    if selectedJobStage == .files {
                        Section("Customer Documents") {
                        Button {
                            generateOnsiteReport(for: call)
                        } label: {
                            Label("Generate Onsite Report", systemImage: "doc.badge.gearshape")
                        }
                        .buttonStyle(.bordered)

                        if let estimate = currentJobEstimate {
                            Button {
                                generateEstimateDocument(estimate)
                            } label: {
                                Label("Generate Estimate PDF", systemImage: "doc.text")
                            }
                            .buttonStyle(.bordered)
                        }

                        if let invoice = currentJobInvoice {
                            Button {
                                generateInvoiceDocument(invoice)
                            } label: {
                                Label("Generate Invoice PDF", systemImage: "doc.text.fill")
                            }
                            .buttonStyle(.bordered)
                        }

                        if let generatedCustomerDocumentURL {
                            ShareLink(item: generatedCustomerDocumentURL) {
                                Label("Share Last Generated Document", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)

                            Button {
                                emailGeneratedCustomerDocument(generatedCustomerDocumentURL)
                            } label: {
                                Label(isEmailingGeneratedDocument ? "Emailing..." : "Email Last Generated Document", systemImage: "paperplane")
                            }
                            .buttonStyle(.bordered)
                            .disabled(!canEmailGeneratedCustomerDocument)
                        }
                        }
                    }

                    if selectedJobStage == .closeout {
                        jobProgressSection(for: call)
                    }

                    if selectedJobStage == .work {
                        workflowSection(for: call)
                    }
                }
        )
    }

    @ViewBuilder
    private var documentDiscountControls: some View {
        if let discount = selectedDocumentDiscount {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Document Discount", systemImage: "tag.fill")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if let selectedDiscountAmount {
                        Text("−\(selectedDiscountAmount.formatted(.currency(code: "USD")))")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.green)
                    } else {
                        Text("Reauthorization required")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Text("\(discount.valueDisplayName) • \(discount.reason)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("AuthorizedDocumentDiscount")
                if let documentDiscountValidationMessage {
                    Label(documentDiscountValidationMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if canAuthorizePriceAdjustments {
                    Button("Edit Document Discount") {
                        showingDocumentDiscountEditor = true
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("DocumentDiscountAction")
                }
            }
            .padding(.vertical, 2)
        } else if canAuthorizePriceAdjustments, !selectedLineItems.isEmpty {
            Button {
                showingDocumentDiscountEditor = true
            } label: {
                Label("Add Document Discount", systemImage: "tag")
            }
            .font(.caption)
            .buttonStyle(.bordered)
            .accessibilityIdentifier("DocumentDiscountAction")
        }
    }

    @ViewBuilder
    private var documentSubtotalSummary: some View {
        if selectedDocumentDiscount != nil {
            HStack {
                Text("Items Subtotal")
                Spacer()
                Text(selectedGrossSubtotal, format: .currency(code: "USD"))
                    .foregroundStyle(.secondary)
            }
            if let selectedDiscountAmount {
                HStack {
                    Text("Discount")
                    Spacer()
                    Text("−\(selectedDiscountAmount.formatted(.currency(code: "USD")))")
                        .foregroundStyle(.green)
                }
            }
        }
        HStack {
            Text(selectedHasTaxableLines ? "Taxable Subtotal" : "Total")
            Spacer()
            Text(selectedTotal, format: .currency(code: "USD"))
                .font(.headline)
                .accessibilityIdentifier("DocumentNetSubtotal")
        }
    }

    @ViewBuilder
    private var lineItemBuilderView: some View {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Line Items")
                                .font(.headline)
                            Spacer()
                            Button {
                                showingItemCreator = true
                            } label: {
                                Label("Create New Item", systemImage: "plus.square.on.square")
                            }
                            .buttonStyle(.bordered)
                            .foregroundStyle(Color.brandGold)
                        }

                        TextField("Search items to add", text: $itemSearchText)
                            .textInputAutocapitalization(.never)

                        Picker("Catalog Filter", selection: $catalogFilter) {
                            ForEach(DocumentationCatalogFilter.allCases) { filter in
                                Text(filter.label).tag(filter)
                            }
                        }
                        .pickerStyle(.segmented)

                        if items.isEmpty {
                            Text("No catalog items yet. Add one below.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else if builderItemResults.isEmpty {
                            Text("No items match that search.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if let suggestedItemName = nonBlank(itemSearchText) {
                                Button {
                                    newItemName = suggestedItemName
                                    catalogFilter = .selected
                                    showingItemCreator = true
                                } label: {
                                    Label("Create \"\(suggestedItemName)\"", systemImage: "plus.circle")
                                }
                                .buttonStyle(.bordered)
                                .tint(Color.brandGold)
                            }
                        } else {
                            ForEach(builderItemResults) { item in
                                Button {
                                    toggleItem(item)
                                } label: {
                                    HStack {
                                        Image(systemName: isCatalogItemSelected(item) ? "checkmark.circle.fill" : "plus.circle")
                                            .foregroundColor(Color.brandGold)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.name)
                                                .font(.subheadline.weight(.semibold))
                                            if let description = item.itemDescription, !description.isEmpty {
                                                Text(description)
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                                    .lineLimit(1)
                                            }
                                            itemMetaText(for: item)
                                            catalogSyncStateLabel(for: item)
                                        }
                                        Spacer()
                                        Text(item.unitPrice, format: .currency(code: "USD"))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if !selectedLineItems.isEmpty {
                            Divider()
                            ForEach(selectedLineItems) { item in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.name)
                                            if let description = item.itemDescription, !description.isEmpty {
                                                Text(description)
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                                    .lineLimit(1)
                                            }
                                            itemMetaText(for: item)
                                        }
                                        Spacer()
                                        VStack(alignment: .trailing, spacing: 4) {
                                            Text(effectiveUnitPrice(for: item) * lineItemQuantity(for: item), format: .currency(code: "USD"))
                                                .foregroundColor(.secondary)
                                            if let adjustment = selectedItemPriceAdjustments[item.id] {
                                                Text("\(adjustment.unitPrice < adjustment.pricebookUnitPrice ? "Discounted" : "Adjusted") from \(adjustment.pricebookUnitPrice.formatted(.currency(code: "USD")))")
                                                    .font(.caption2)
                                                    .foregroundStyle(.orange)
                                            }
                                            if canAuthorizePriceAdjustments {
                                                Button(selectedItemPriceAdjustments[item.id] == nil ? "Discount / Adjust" : "Edit Adjustment") {
                                                    itemPendingPriceAdjustment = item
                                                }
                                                .font(.caption2)
                                                .buttonStyle(.bordered)
                                                .accessibilityIdentifier(adjustPriceAccessibilityID(for: item))
                                            }

                                            HStack(spacing: 8) {
                                                Button {
                                                    removeCatalogLine(item.id)
                                                } label: {
                                                    Image(systemName: "minus.circle")
                                                }
                                                .buttonStyle(.borderless)
                                                .frame(width: 44, height: 44)
                                                .contentShape(Rectangle())
                                                .fixedSize()
                                                .layoutPriority(2)
                                                .accessibilityLabel("Remove \(item.name) from \(selectedDocumentKind.rawValue.lowercased())")
                                                .accessibilityIdentifier("RemoveBillingLine-\(item.id.uuidString)")

                                                Stepper(
                                                    lineItemQuantityLabel(for: item),
                                                    value: lineItemQuantityBinding(for: item),
                                                    in: 0.25...100,
                                                    step: 0.25
                                                )
                                                .labelsHidden()
                                                .fixedSize()
                                                .disabled(isItemizedAssemblyLine(item))
                                                .accessibilityLabel(lineItemQuantityAccessibilityLabel(for: item))
                                            }
                                        }
                                    }
                                    lineEquipmentPicker(for: item)
                                }
                            }
                        }

                        documentDiscountControls
                        documentSubtotalSummary

                        if !catalogItemsAwaitingReview.isEmpty && !canApprovePricebookItems {
                            Label(
                                "Field-created items stay on this job and wait for Admin pricebook review before QuickBooks publication.",
                                systemImage: "checkmark.shield"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        DisclosureGroup("Create Item") {
                            TextField("New item", text: $newItemName)
                            TextField("SKU", text: $newItemSKU)
                                .textInputAutocapitalization(.characters)
                            Picker("Item Type", selection: $newItemType) {
                                ForEach(CatalogItemType.allCases) { type in
                                    Text(type.rawValue).tag(type)
                                }
                            }
                            .pickerStyle(.segmented)
                            TextField("Description", text: $newItemDescription, axis: .vertical)
                                .lineLimit(2...3)
                            Toggle("Taxable", isOn: $newItemTaxable)
                            HStack {
                                TextField("Price (optional)", text: $newItemPrice)
                                    .keyboardType(.decimalPad)
                                TextField("Cost", text: $newItemCost)
                                    .keyboardType(.decimalPad)
                            }
                            TextField("Typical purchase source", text: $newItemPreferredVendor)
                            if !vendors.isEmpty {
                                SearchableDropdownPicker(
                                    title: "Saved Vendor",
                                    options: newItemVendorDropdownOptions,
                                    selectedID: selectedNewItemVendorDropdownID,
                                    placeholder: "Manual / none",
                                    showsClearButton: true
                                )
                            }
                            TextField("Vendor part #", text: $newItemVendorPartNumber)
                            TextField("Purchase URL", text: $newItemPurchaseURL)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                            TextField("Purchase notes", text: $newItemPurchaseDescription, axis: .vertical)
                                .lineLimit(2...3)
                            Button {
                                addItem()
                            } label: {
                                Label("Add Item", systemImage: "plus.circle.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)
                            .disabled(!canAddInlineItem)
                        }
                    }

    }

    private func syncNotesToJob() {
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        activeServiceCall?.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
        actionMessage = trimmedNotes.isEmpty ? "Cleared job notes." : "Saved documentation notes back to the job."
    }

    @ViewBuilder
    private func jobProgressSection(for call: ServiceCall) -> some View {
        let completionBlockers = operationalCompletionBlockers(for: call)
        Section("Job Progress") {
            Toggle("Work Completed", isOn: Binding(
                get: { call.workCompletedChecklist },
                set: { call.workCompletedChecklist = $0 }
            ))
            Toggle("Documentation Completed", isOn: Binding(
                get: { call.documentationChecklist },
                set: { call.documentationChecklist = $0 }
            ))
            Toggle("Payment Collected", isOn: Binding(
                get: { call.paymentCollectedChecklist },
                set: { call.paymentCollectedChecklist = $0 }
            ))

            Text("Checklist: \(call.checklistCompletedCount)/\(call.checklistTotalCount)")
                .font(.caption)
                .foregroundColor(.secondary)

            if call.status == .scheduled || call.status == .inProgress {
                Button(jobProgressActionLabel(for: call), action: { advanceJobProgress(call) })
                    .buttonStyle(.bordered)
                    .disabled(call.status == .inProgress && !completionBlockers.isEmpty)
            }
            if call.status == .inProgress,
               !completionBlockers.isEmpty {
                Text("Before completion: \(completionBlockers.joined(separator: ", ")).")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("BillingOperationalCloseoutBlockers")
            }
        }
    }

    private func jobProgressActionLabel(for call: ServiceCall) -> String {
        call.status == .scheduled ? "Mark Job In Progress" : "Mark Job Completed"
    }

    private func operationalCompletionBlockers(for call: ServiceCall) -> [String] {
        ServiceWorkLogPolicy.operationalCompletionBlockers(
            for: call,
            requireCompletionChecklist: requireJobCompletionChecklist,
            fieldFormTemplates: fieldFormTemplates,
            fieldFormResponses: fieldFormResponses,
            activities: serviceCallActivities,
            requireWorkPerformedLog: requireWorkPerformedLogForCloseout
        )
    }

    private func advanceJobProgress(_ call: ServiceCall) {
        if call.status == .scheduled {
            call.status = .inProgress
            call.documentationStartedAt = call.documentationStartedAt ?? Date()
            ServiceCallActivity.record(
                for: call,
                action: "Job started",
                detail: "Status changed from scheduled to in progress.",
                actorEmail: currentUserEmail,
                in: modelContext
            )
            return
        }

        let completionBlockers = operationalCompletionBlockers(for: call)
        if !completionBlockers.isEmpty {
            call.status = .inProgress
            actionMessage = "Before completion: \(completionBlockers.joined(separator: ", "))."
            return
        }

        guard call.markDocumentationCompleteIfReady() else {
            call.status = .inProgress
            actionMessage = call.documentationCompletionBlockedMessage
                ?? "Complete required report fields before closing this job."
            return
        }

        let hasInvoice = call.linkedInvoiceID != nil
        call.status = hasInvoice ? .invoiced : .completed
        call.completeLinkedMaintenanceAgreementIfNeeded()
        let nextStatus = hasInvoice ? "invoiced" : "completed"
        ServiceCallActivity.record(
            for: call,
            action: "Job status updated",
            detail: "Status changed from in progress to \(nextStatus).",
            actorEmail: currentUserEmail,
            in: modelContext
        )
    }

    @ViewBuilder
    private func projectBillingSection(for call: ServiceCall) -> some View {
        let milestones = currentProjectMilestones
        if milestones.isEmpty {
            if selectedJobStage == .billing,
               let estimate = currentJobEstimate,
               estimate.status.caseInsensitiveCompare("accepted") == .orderedSame,
               currentJobInvoice == nil,
               canManageProjectBillingPlans {
                Section("Project Billing") {
                    Label("Approved scope can be billed by milestone", systemImage: "building.2")
                        .font(.subheadline.weight(.semibold))
                    Text("Create a compact project plan for deposits, scheduled installation work, commissioning, and final handoff. Percentages must reconcile to the approved contract before any progress invoice can be issued.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        guard estimate.hasRecordedCustomerApproval else {
                            actionMessage = ProjectBillingValidationError.approvalRequired.localizedDescription
                            return
                        }
                        showingProjectPlanSetup = true
                    } label: {
                        Label("Create Project Billing Plan", systemImage: "plus.rectangle.on.folder")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brandGold)
                    .foregroundStyle(Color.primaryBlack)
                    .disabled(!estimate.hasRecordedCustomerApproval)
                    .accessibilityIdentifier("CreateProjectBillingPlan")

                    if !estimate.hasRecordedCustomerApproval {
                        Text(ProjectBillingValidationError.approvalRequired.localizedDescription)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        } else if let summary = currentProjectSummary {
            Section("Project Billing") {
                ProjectBillingSummaryCard(
                    summary: summary,
                    issuedMilestoneCount: milestones.filter { $0.invoiceID != nil }.count,
                    canViewFinancials: canViewFinancials,
                    canIssueProgressInvoices: canIssueProjectProgressInvoices
                )

                ForEach(milestones) { milestone in
                    let state = milestone.displayState(invoices: invoices, payments: payments)
                    let scheduledVisit = milestone.scheduledVisitID.flatMap { visitID in
                        serviceCalls.first { $0.id == visitID }
                    }
                    ProjectMilestoneCard(
                        milestone: milestone,
                        state: state,
                        scheduledVisit: scheduledVisit,
                        linkedInvoice: milestone.linkedInvoice(in: invoices),
                        billingEstimate: projectEstimate ?? currentJobEstimate,
                        canViewFinancials: canViewFinancials,
                        canSchedule: canScheduleApprovedWork,
                        canComplete: canCompleteProjectMilestones,
                        canIssueInvoice: canIssueProjectProgressInvoices,
                        onSchedule: { milestonePendingScheduling = milestone },
                        onComplete: { milestonePendingCompletion = milestone },
                        onCreateInvoice: { milestonePendingInvoice = milestone },
                        onReviewInvoice: { invoice in reviewProjectInvoice(invoice, for: call) },
                        onOpenVisit: { visit in GunnAireAppIntentRouter.storeScheduleCallRoute(visit.id) }
                    )
                }
            }
        }
    }

    private func createProjectBillingPlan(
        drafts: [ProjectMilestonePlanDraft],
        for call: ServiceCall,
        estimate: Estimate
    ) {
        guard AppAccess.canManageProjectBillingPlans(email: currentUserEmail, users: users),
              AppAccess.canAccessServiceCall(call, email: currentUserEmail, users: users, serviceCalls: serviceCalls, technicians: technicians),
              currentProjectMilestones.isEmpty,
              call.linkedInvoiceID == nil,
              call.linkedEstimateID == estimate.id else {
            actionMessage = "The project plan could not be created because the job, role, or approved estimate changed."
            return
        }

        do {
            let created = try ProjectBillingPolicy.makeMilestones(
                drafts: drafts,
                projectServiceCallID: call.id,
                estimate: estimate,
                createdByEmail: currentUserEmail
            )
            for milestone in created { modelContext.insert(milestone) }
            let activity = ServiceCallActivity(
                serviceCallID: call.id,
                action: "Project billing plan created",
                detail: "\(created.count) milestones allocate 100% of approved estimate \(estimate.id.uuidString.prefix(8)).",
                actorEmail: currentUserEmail
            )
            modelContext.insert(activity)
            do {
                try modelContext.save()
                showingProjectPlanSetup = false
                actionMessage = "Project billing plan created. Approval and completed work remain separate billing triggers."
            } catch {
                for milestone in created { modelContext.delete(milestone) }
                modelContext.delete(activity)
                actionMessage = "Could not save the project billing plan: \(error.localizedDescription)"
            }
        } catch {
            actionMessage = error.localizedDescription
        }
    }

    private func scheduleProjectMilestoneVisit(
        _ milestone: ProjectMilestone,
        at date: Date,
        duration: TimeInterval
    ) {
        guard let call = activeServiceCall,
              milestone.projectServiceCallID == call.id,
              milestone.invoiceID == nil,
              milestone.scheduledVisitID == nil,
              date > Date(),
              duration > 0,
              AppAccess.canManageDispatch(email: currentUserEmail, users: users),
              AppAccess.canAccessServiceCall(call, email: currentUserEmail, users: users, serviceCalls: serviceCalls, technicians: technicians) else {
            actionMessage = "The milestone visit could not be scheduled because the job, role, or milestone changed."
            return
        }

        let visit = ServiceCall(
            eventTitle: "\(call.customer.name) • \(milestone.title)",
            siteAddress: call.siteAddress,
            serviceLocationID: call.serviceLocationID,
            equipmentName: call.equipmentName,
            equipmentManufacturer: call.equipmentManufacturer,
            equipmentModel: call.equipmentModel,
            equipmentSerialNumber: call.equipmentSerialNumber,
            equipmentLocation: call.equipmentLocation,
            equipmentInstallDate: call.equipmentInstallDate,
            equipmentWarrantyExpiration: call.equipmentWarrantyExpiration,
            customerEquipmentID: call.customerEquipmentID,
            equipmentTypeRaw: call.equipmentTypeRaw,
            equipmentNotes: call.equipmentNotes,
            type: call.type,
            dispatchUrgency: call.dispatchUrgency,
            scheduledDate: date,
            duration: duration,
            assignedTechnician: call.assignedTechnician,
            additionalTechnicianIDs: call.assignedCrewTechnicianIDs,
            customer: call.customer,
            notes: "Project milestone \(milestone.sequence + 1): \(milestone.title). Parent job \(call.id.uuidString.prefix(8))."
        )
        let priorStatus = milestone.status
        modelContext.insert(visit)
        milestone.markScheduled(visitID: visit.id)
        let activity = ServiceCallActivity(
            serviceCallID: call.id,
            action: "Project milestone scheduled",
            detail: "\(milestone.title) scheduled for \(date.formatted(date: .abbreviated, time: .shortened)).",
            actorEmail: currentUserEmail
        )
        modelContext.insert(activity)
        do {
            try modelContext.save()
            milestonePendingScheduling = nil
            actionMessage = "\(milestone.title) was added to the dispatch schedule."
        } catch {
            milestone.scheduledVisitID = nil
            milestone.status = priorStatus
            modelContext.delete(visit)
            modelContext.delete(activity)
            actionMessage = "Could not schedule the milestone visit: \(error.localizedDescription)"
        }
    }

    private func completeProjectMilestone(_ milestone: ProjectMilestone) {
        guard let call = activeServiceCall,
              milestone.projectServiceCallID == call.id,
              milestone.invoiceID == nil,
              AppAccess.canCompleteProjectMilestones(email: currentUserEmail, users: users),
              AppAccess.canAccessServiceCall(call, email: currentUserEmail, users: users, serviceCalls: serviceCalls, technicians: technicians) else {
            actionMessage = "The milestone could not be completed because the job, role, or milestone changed."
            return
        }
        if let visitID = milestone.scheduledVisitID,
           let visit = serviceCalls.first(where: { $0.id == visitID }),
           visit.status != .completed,
           visit.status != .invoiced {
            actionMessage = "Complete the scheduled milestone visit before releasing this billing stage."
            return
        }

        let priorStatus = milestone.status
        let priorCompletedAt = milestone.completedAt
        let priorCompletedBy = milestone.completedByEmail
        guard milestone.markCompleted(by: currentUserEmail) else {
            actionMessage = "This milestone already has an invoice and cannot be changed."
            return
        }
        let activity = ServiceCallActivity(
            serviceCallID: call.id,
            action: "Project milestone completed",
            detail: "\(milestone.title) is ready for billing review.",
            actorEmail: currentUserEmail
        )
        modelContext.insert(activity)
        do {
            try modelContext.save()
            actionMessage = "\(milestone.title) is ready for billing review."
        } catch {
            milestone.status = priorStatus
            milestone.completedAt = priorCompletedAt
            milestone.completedByEmail = priorCompletedBy
            modelContext.delete(activity)
            actionMessage = "Could not save milestone completion: \(error.localizedDescription)"
        }
    }

    private func maintenanceAgreement(
        for candidate: MaintenanceAgreementBillingCandidate
    ) -> RecurringMaintenanceContract? {
        maintenanceAgreements.first { agreement in
            agreement.id == candidate.agreementID && agreement.customer.id == candidate.customerID
        }
    }

    private func billingCatalogItem(
        for candidate: MaintenanceAgreementBillingCandidate
    ) -> Item? {
        items.first { item in
            item.id == candidate.billingCatalogItemID &&
            !item.requiresPricebookReview &&
            item.isAvailableForNewWork
        }
    }

    private func maintenanceAgreementBillingSetupDetail(
        for agreement: RecurringMaintenanceContract
    ) -> String {
        guard let billingCatalogItemID = agreement.billingCatalogItemID else {
            return "Select the approved pricebook item that will map every agreement invoice to QuickBooks."
        }
        guard let item = items.first(where: { $0.id == billingCatalogItemID }) else {
            return "The selected billing item is no longer in the company pricebook. Choose a replacement before invoicing."
        }
        if item.requiresPricebookReview {
            return "\(item.name) is awaiting administrator pricebook review and cannot publish to QuickBooks yet."
        }
        if item.isCatalogArchived {
            return "\(item.name) is archived from new work. Choose an active billing item before releasing another agreement invoice."
        }
        return "Set the first billing date before releasing \(agreement.billingInterval.displayName.lowercased()) invoices."
    }

    private func configureMaintenanceAgreementBilling(
        _ agreement: RecurringMaintenanceContract,
        catalogItemID: UUID,
        anchorDate: Date?
    ) throws {
        guard canConfigureMaintenanceAgreementBilling else {
            throw MaintenanceAgreementBillingWorkflowError.unauthorizedConfiguration
        }
        guard MaintenanceAgreementBillingPolicy.isEligibleForBilling(agreement),
              let item = items.first(where: { $0.id == catalogItemID }),
              !item.requiresPricebookReview,
              item.isAvailableForNewWork else {
            throw MaintenanceAgreementBillingWorkflowError.billingItemUnavailable
        }

        let priorLifecycleJSON = agreement.lifecycleJSON
        do {
            try agreement.configureBilling(
                catalogItemID: catalogItemID,
                anchorDate: anchorDate,
                byEmail: currentUserEmail
            )
            try modelContext.save()
            actionMessage = "Billing setup saved for \(agreement.customer.name) • \(agreement.displayName)."
        } catch {
            agreement.lifecycleJSON = priorLifecycleJSON
            throw MaintenanceAgreementBillingWorkflowError.saveFailed(error.localizedDescription)
        }
    }

    private func createMaintenanceAgreementInvoice(
        for candidate: MaintenanceAgreementBillingCandidate
    ) throws {
        guard canIssueMaintenanceAgreementInvoices else {
            throw MaintenanceAgreementBillingWorkflowError.unauthorizedInvoice
        }
        guard let agreement = maintenanceAgreement(for: candidate),
              let billingItem = billingCatalogItem(for: candidate),
              let refreshedCandidate = MaintenanceAgreementBillingPolicy.firstDueCandidate(
                for: agreement,
                serviceCalls: serviceCalls
              ),
              refreshedCandidate.id == candidate.id,
              abs(refreshedCandidate.amount - candidate.amount) < 0.005 else {
            throw MaintenanceAgreementBillingWorkflowError.cycleChanged
        }

        let createdAt = Date()
        let actor = AppAccess.normalizedEmail(currentUserEmail)
        guard !actor.isEmpty else {
            throw MaintenanceAgreementBillingWorkflowError.unauthorizedInvoice
        }
        let adjustment: AuthorizedLinePriceAdjustment?
        if abs(billingItem.unitPrice - candidate.amount) >= 0.005 {
            adjustment = AuthorizedLinePriceAdjustment(
                pricebookUnitPrice: billingItem.unitPrice,
                unitPrice: candidate.amount,
                reason: "Customer-approved \(candidate.interval.displayName.lowercased()) price for \(agreement.displayName)",
                authorizedByEmail: agreement.lifecycle?.approvalRecordedByEmail ?? actor,
                authorizedAt: agreement.lifecycle?.approvedAt ?? createdAt
            )
        } else {
            adjustment = nil
        }
        let snapshot = CatalogLineItemSnapshot(
            item: billingItem,
            priceAdjustment: adjustment
        )
        guard let snapshotJSON = CatalogLineItemSnapshot.encoded(snapshots: [snapshot]) else {
            throw MaintenanceAgreementBillingWorkflowError.invoiceConstructionFailed
        }

        let dueDate = configuredDefaultInvoicePaymentTerms.dueDate(from: createdAt)
            ?? Calendar.current.startOfDay(for: createdAt)
        let cycleDate = candidate.cycleDueDate.formatted(date: .abbreviated, time: .omitted)
        let invoice = Invoice(
            serviceCallID: candidate.serviceCallID,
            siteAddress: agreement.customer.address,
            customer: agreement.customer,
            workType: .service,
            lineItemSummary: "\(agreement.displayName) — \(candidate.interval.displayName) billing",
            catalogSnapshotJSON: snapshotJSON,
            amount: candidate.amount,
            taxCalculationStatus: billingItem.isTaxable ? .pendingQuickBooks : .notApplicable,
            status: "unpaid",
            dueDate: dueDate,
            notes: "Maintenance agreement \(String(agreement.id.uuidString.prefix(8)).uppercased()) • billing cycle \(cycleDate)",
            createdAt: createdAt
        )

        let priorLifecycleJSON = agreement.lifecycleJSON
        let linkedCall = candidate.serviceCallID.flatMap { serviceCallID in
            serviceCalls.first { $0.id == serviceCallID }
        }
        let priorLinkedInvoiceID = linkedCall?.linkedInvoiceID
        let priorCallStatus = linkedCall?.status
        modelContext.insert(invoice)
        do {
            try agreement.recordBillingInvoice(
                refreshedCandidate,
                invoiceID: invoice.id,
                generatedByEmail: actor,
                generatedAt: createdAt
            )
            linkedCall?.linkedInvoiceID = invoice.id
            linkedCall?.status = .invoiced
            try modelContext.save()
        } catch {
            agreement.lifecycleJSON = priorLifecycleJSON
            linkedCall?.linkedInvoiceID = priorLinkedInvoiceID
            if let priorCallStatus { linkedCall?.status = priorCallStatus }
            modelContext.delete(invoice)
            throw MaintenanceAgreementBillingWorkflowError.saveFailed(error.localizedDescription)
        }

        actionMessage = isQuickBooksConnected
            ? "Agreement invoice created locally. Publishing its approved item and invoice to QuickBooks..."
            : "Agreement invoice created locally. QuickBooks publication is pending until the connection is available."
        syncInvoiceIfNeeded(invoice, customer: agreement.customer, items: [billingItem])
    }

    private func createProgressInvoice(for milestone: ProjectMilestone) {
        guard let call = activeServiceCall,
              let estimate = projectEstimate,
              milestone.projectServiceCallID == call.id,
              milestone.estimateID == estimate.id,
              AppAccess.canIssueProjectProgressInvoices(email: currentUserEmail, users: users),
              AppAccess.canAccessServiceCall(call, email: currentUserEmail, users: users, serviceCalls: serviceCalls, technicians: technicians) else {
            actionMessage = "The progress invoice could not be created because the job, role, or approved estimate changed."
            return
        }

        let scheduledVisit = milestone.scheduledVisitID.flatMap { visitID in
            serviceCalls.first { $0.id == visitID }
        }
        guard ProjectBillingPolicy.canInvoice(milestone, estimate: estimate, scheduledVisit: scheduledVisit) else {
            actionMessage = "Complete the required milestone work before creating this progress invoice."
            return
        }

        do {
            try ProjectBillingPolicy.validatePersistedPlan(currentProjectMilestones, contractAmount: estimate.amount)
            let snapshotJSON = try ProjectBillingPolicy.progressDocumentSnapshotJSON(
                from: estimate.catalogSnapshotJSON,
                targetAmount: milestone.plannedAmount
            )
            guard BillingDocumentDiscountPolicy.currencyCents(
                BillingDocumentDiscountPolicy.netSubtotal(snapshotJSON: snapshotJSON) ?? -1
            ) == BillingDocumentDiscountPolicy.currencyCents(milestone.plannedAmount) else {
                throw ProjectBillingValidationError.invalidPersistedPlan
            }
            let invoiceCreatedAt = Date()
            let invoiceDueDate = configuredDefaultInvoicePaymentTerms.dueDate(from: invoiceCreatedAt)
                ?? Calendar.current.startOfDay(for: invoiceCreatedAt)

            let invoice = Invoice(
                serviceCallID: call.id,
                serviceLocationID: call.serviceLocationID,
                siteAddress: call.siteAddress,
                customer: call.customer,
                workType: InvoiceWorkType.inferred(from: call),
                lineItemSummary: "\(milestone.title) — \(milestone.billingPercent.formatted(.number.precision(.fractionLength(0...2))))% of approved project scope",
                catalogSnapshotJSON: snapshotJSON,
                amount: milestone.plannedAmount,
                projectMilestoneID: milestone.id,
                projectMilestoneSequence: milestone.sequence,
                projectMilestoneTitle: milestone.title,
                projectContractAmount: estimate.amount,
                projectBillingPercent: milestone.billingPercent,
                status: "unpaid",
                dueDate: invoiceDueDate,
                notes: "Progress billing against approved estimate \(estimate.id.uuidString.prefix(8)).",
                createdAt: invoiceCreatedAt
            )
            let priorStatus = milestone.status
            let priorCompletedAt = milestone.completedAt
            let priorCompletedBy = milestone.completedByEmail
            let priorLinkedInvoiceID = call.linkedInvoiceID
            let priorEstimateStatus = estimate.status
            if milestone.billingTrigger == .milestoneCompletion, milestone.completedAt == nil {
                _ = milestone.markCompleted(by: currentUserEmail)
            }
            guard milestone.markInvoiced(invoiceID: invoice.id) else {
                actionMessage = "This milestone already has an invoice."
                return
            }
            modelContext.insert(invoice)
            call.linkedInvoiceID = invoice.id
            let planWillBeFullyInvoiced = currentProjectMilestones.allSatisfy { existing in
                existing.id == milestone.id || existing.invoiceID != nil
            }
            if planWillBeFullyInvoiced {
                estimate.status = "invoiced"
                call.status = .invoiced
            }
            let activity = ServiceCallActivity(
                serviceCallID: call.id,
                action: "Progress invoice created",
                detail: "\(milestone.title): \(milestone.billingPercent.formatted(.number.precision(.fractionLength(0...2))))% / \(milestone.plannedAmount.formatted(.currency(code: "USD"))).",
                actorEmail: currentUserEmail
            )
            modelContext.insert(activity)

            do {
                try modelContext.save()
                linkExistingInvoiceAttachments(to: invoice, serviceCallID: call.id)
                actionMessage = isQuickBooksConnected
                    ? "Progress invoice created locally. Syncing the approved milestone allocation to QuickBooks..."
                    : "Progress invoice created locally. QuickBooks publication is pending."
                let restoredItems = restoredCatalogItems(
                    snapshotJSON: invoice.catalogSnapshotJSON,
                    lineItemSummary: invoice.lineItemSummary
                )
                syncInvoiceIfNeeded(invoice, customer: call.customer, items: restoredItems)
            } catch {
                milestone.invoiceID = nil
                milestone.status = priorStatus
                milestone.completedAt = priorCompletedAt
                milestone.completedByEmail = priorCompletedBy
                call.linkedInvoiceID = priorLinkedInvoiceID
                estimate.status = priorEstimateStatus
                modelContext.delete(invoice)
                modelContext.delete(activity)
                actionMessage = "Could not save the progress invoice: \(error.localizedDescription)"
            }
        } catch {
            actionMessage = error.localizedDescription
        }
    }

    private func reviewProjectInvoice(_ invoice: Invoice, for call: ServiceCall) {
        guard invoice.serviceCallID == call.id,
              AppAccess.canAccessServiceCall(call, email: currentUserEmail, users: users, serviceCalls: serviceCalls, technicians: technicians) else {
            actionMessage = "This project invoice is not available to the signed-in account."
            return
        }
        call.linkedInvoiceID = invoice.id
        selectedDocumentKind = .invoice
        selectedJobStage = .billing
        loadInvoiceIntoBuilder(invoice, announce: false)
        try? modelContext.save()
        actionMessage = "Loaded \(invoice.projectBillingDisplayTitle ?? "progress invoice") for review. Its approved milestone allocation is locked."
    }

    @ViewBuilder
    private func jobMaterialsSection(for call: ServiceCall) -> some View {
        let requirements = jobMaterialRequirements
        if currentJobInvoice != nil, !requirements.isEmpty {
            let completedCount = requirements.filter {
                materialStatus(for: $0, call: call).isComplete
            }.count
            Section("Job Materials") {
                HStack {
                    Label(
                        completedCount == requirements.count ? "Stock use recorded" : "Stock use needs review",
                        systemImage: completedCount == requirements.count ? "checkmark.seal.fill" : "shippingbox.and.arrow.backward"
                    )
                    .foregroundStyle(completedCount == requirements.count ? Color.green : Color.orange)
                    Spacer()
                    Text("\(completedCount)/\(requirements.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Text("The invoice keeps the customer charge. This compact ledger handoff records the physical part against this job and its stock location.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(requirements) { requirement in
                    let source = selectedMaterialSource(for: requirement, call: call)
                    let status = materialStatus(for: requirement, call: call)
                    let sourceStatus = materialStatus(for: requirement, call: call, at: source)
                    let sourceAvailable = InventoryLedger.availableQuantity(
                        for: requirement.item.id,
                        at: source,
                        movements: inventoryMovements
                    ) + sourceStatus.openReservedQuantity
                    let sourceOnHand = InventoryLedger.onHandQuantity(
                        for: requirement.item.id,
                        at: source,
                        movements: inventoryMovements
                    )
                    let restockQuantity = InventoryReplenishment.suggestedQuantity(
                        for: requirement.item,
                        onHand: sourceOnHand
                    )
                    let existingRestockOrder = InventoryReplenishment.openOrder(
                        for: requirement.item,
                        serviceCallID: call.id,
                        purchaseOrders: purchaseOrders
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(requirement.item.name)
                                    .font(.subheadline.weight(.semibold))
                                Text(materialProgressText(requirement: requirement, status: status))
                                    .font(.caption)
                                    .foregroundStyle(status.isComplete ? Color.secondary : Color.orange)
                            }
                            Spacer()
                            if status.isComplete {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .accessibilityLabel("Stock use complete")
                            }
                        }

                        Picker("Stock source", selection: materialSourceBinding(for: requirement, call: call)) {
                            ForEach(materialSourceLocations(for: requirement.item), id: \.self) { location in
                                Text(location).tag(location)
                            }
                        }
                        .pickerStyle(.menu)

                        HStack {
                            Text("Available to this job: \(sourceAvailable.formatted(.number.precision(.fractionLength(0...2))))")
                                .font(.caption2)
                                .foregroundStyle(sourceAvailable < status.remainingToRecord ? Color.orange : Color.secondary)
                            Spacer()
                            if status.remainingToRecord > 0.0001, canRecordJobMaterials {
                                Button("Record \(status.remainingToRecord.formatted(.number.precision(.fractionLength(0...2)))) Used") {
                                    recordRemainingMaterialUse(requirement, call: call, source: source)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Color.brandGold)
                                .foregroundStyle(Color.primaryBlack)
                                .accessibilityIdentifier("RecordJobMaterialUse-\(requirement.item.id.uuidString)")
                            } else if status.remainingToRecord > 0.0001 {
                                Text("Field or Admin account required")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if status.overRecordedQuantity > 0.0001 {
                            Text("Recorded use exceeds the invoiced quantity by \(status.overRecordedQuantity.formatted(.number.precision(.fractionLength(0...2)))). Review the invoice or record a return before closeout.")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }

                        if restockQuantity > 0.0001 {
                            HStack {
                                Label(
                                    "\(source) needs \(restockQuantity.formatted(.number.precision(.fractionLength(0...2)))) to reach its reorder point",
                                    systemImage: "exclamationmark.triangle.fill"
                                )
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                Spacer()
                                if let existingRestockOrder {
                                    Text("\(existingRestockOrder.status.displayName) • \(existingRestockOrder.number)")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .accessibilityIdentifier("RestockRequestStatus-\(requirement.item.id.uuidString)")
                                } else if canRequestJobMaterialReplenishment {
                                    Button("Request Restock") {
                                        requestMaterialRestock(
                                            requirement,
                                            call: call,
                                            source: source,
                                            onHand: sourceOnHand
                                        )
                                    }
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier("RequestRestock-\(requirement.item.id.uuidString)")
                                }
                            }
                        }
                    }
                }

                if let jobMaterialMessage {
                    Text(jobMaterialMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func materialStatus(
        for requirement: JobMaterialRequirement,
        call: ServiceCall,
        at location: String? = nil
    ) -> InventoryJobMaterialStatus {
        InventoryLedger.jobMaterialStatus(
            for: requirement.item.id,
            serviceCallID: call.id,
            requiredQuantity: requirement.quantity,
            at: location,
            movements: inventoryMovements
        )
    }

    private func materialProgressText(
        requirement: JobMaterialRequirement,
        status: InventoryJobMaterialStatus
    ) -> String {
        let required = requirement.quantity.formatted(.number.precision(.fractionLength(0...2)))
        let used = status.netUsedQuantity.formatted(.number.precision(.fractionLength(0...2)))
        let reserved = status.openReservedQuantity.formatted(.number.precision(.fractionLength(0...2)))
        return "Invoice \(required) • Used \(used) • Reserved \(reserved)"
    }

    private func materialSourceLocations(for item: Item) -> [String] {
        var locations = Set(InventoryLedger.locations(for: item.id, movements: inventoryMovements))
        if let configured = item.defaultInventoryLocation?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            locations.insert(configured)
        }
        if locations.isEmpty {
            locations.insert("Warehouse")
        }
        return locations.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func selectedMaterialSource(for requirement: JobMaterialRequirement, call: ServiceCall) -> String {
        let locations = materialSourceLocations(for: requirement.item)
        if let selected = materialSourceByItemID[requirement.item.id], locations.contains(selected) {
            return selected
        }
        if let reservedLocation = locations.first(where: {
            materialStatus(for: requirement, call: call, at: $0).openReservedQuantity > 0.0001
        }) {
            return reservedLocation
        }
        if let configured = requirement.item.defaultInventoryLocation?.trimmingCharacters(in: .whitespacesAndNewlines),
           locations.contains(configured) {
            return configured
        }
        return locations.max {
            InventoryLedger.onHandQuantity(for: requirement.item.id, at: $0, movements: inventoryMovements) <
                InventoryLedger.onHandQuantity(for: requirement.item.id, at: $1, movements: inventoryMovements)
        } ?? "Warehouse"
    }

    private func materialSourceBinding(for requirement: JobMaterialRequirement, call: ServiceCall) -> Binding<String> {
        Binding(
            get: { selectedMaterialSource(for: requirement, call: call) },
            set: { materialSourceByItemID[requirement.item.id] = $0 }
        )
    }

    private func recordRemainingMaterialUse(
        _ requirement: JobMaterialRequirement,
        call: ServiceCall,
        source: String
    ) {
        guard canRecordJobMaterials, AppAccess.canAccessServiceCall(
            call,
            email: currentUserEmail,
            users: users,
            serviceCalls: serviceCalls,
            technicians: technicians
        ) else {
            jobMaterialMessage = "A Field Technician or Admin account assigned to this job is required to record stock."
            return
        }
        let status = materialStatus(for: requirement, call: call)
        let quantity = status.remainingToRecord
        guard quantity > 0.0001 else {
            jobMaterialMessage = "The invoiced quantity for \(requirement.item.name) is already accounted for."
            return
        }
        let normalizedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSource.isEmpty else {
            jobMaterialMessage = "Choose the truck or warehouse that supplied this part."
            return
        }
        let onHandBeforeUse = InventoryLedger.onHandQuantity(
            for: requirement.item.id,
            at: normalizedSource,
            movements: inventoryMovements
        )
        let wasTrackingInventory = requirement.item.tracksInventory
        let priorDefaultLocation = requirement.item.defaultInventoryLocation
        requirement.item.tracksInventory = true
        requirement.item.defaultInventoryLocation = normalizedSource

        let movement = InventoryMovement(
            item: requirement.item,
            type: .consume,
            quantity: quantity,
            sourceLocation: normalizedSource,
            serviceCallID: call.id,
            notes: "Recorded from the job invoice material handoff.",
            createdByEmail: currentUserEmail
        )
        let activity = ServiceCallActivity(
            serviceCallID: call.id,
            action: "Material used",
            detail: "\(quantity.formatted(.number.precision(.fractionLength(0...2)))) × \(requirement.item.name) from \(normalizedSource).",
            actorEmail: currentUserEmail
        )
        modelContext.insert(movement)
        modelContext.insert(activity)
        do {
            try modelContext.save()
            let remainingOnHand = onHandBeforeUse - quantity
            jobMaterialMessage = remainingOnHand < -0.0001
                ? "Recorded \(requirement.item.name). \(normalizedSource) is now negative by \((-remainingOnHand).formatted(.number.precision(.fractionLength(0...2)))); replenish or reconcile the count."
                : "Recorded \(quantity.formatted(.number.precision(.fractionLength(0...2)))) × \(requirement.item.name) from \(normalizedSource)."
        } catch {
            requirement.item.tracksInventory = wasTrackingInventory
            requirement.item.defaultInventoryLocation = priorDefaultLocation
            modelContext.delete(activity)
            modelContext.delete(movement)
            jobMaterialMessage = "Could not save material use: \(error.localizedDescription)"
        }
    }

    private func requestMaterialRestock(
        _ requirement: JobMaterialRequirement,
        call: ServiceCall,
        source: String,
        onHand: Double
    ) {
        guard canRequestJobMaterialReplenishment,
              AppAccess.canAccessServiceCall(
                call,
                email: currentUserEmail,
                users: users,
                serviceCalls: serviceCalls,
                technicians: technicians
              ) else {
            jobMaterialMessage = "A Field Technician or Admin account assigned to this job is required to request restock."
            return
        }
        if let existing = InventoryReplenishment.openOrder(
            for: requirement.item,
            serviceCallID: call.id,
            purchaseOrders: purchaseOrders
        ) {
            jobMaterialMessage = "Restock is already tracked on \(existing.number)."
            return
        }
        guard let request = InventoryReplenishment.request(
            for: requirement.item,
            serviceCallID: call.id,
            sourceLocation: source,
            onHand: onHand,
            actorEmail: currentUserEmail
        ) else {
            jobMaterialMessage = "\(source) is already at or above the reorder point."
            return
        }
        let activity = ServiceCallActivity(
            serviceCallID: call.id,
            action: "Restock requested",
            detail: "\(request.quantity.formatted(.number.precision(.fractionLength(0...2)))) × \(requirement.item.name) for \(source) on \(request.number).",
            actorEmail: currentUserEmail
        )
        modelContext.insert(request)
        modelContext.insert(activity)
        do {
            try modelContext.save()
            jobMaterialMessage = "Restock requested on \(request.number). An administrator must review the supplier and place the order."
        } catch {
            modelContext.delete(activity)
            modelContext.delete(request)
            jobMaterialMessage = "Could not save the restock request: \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private func jobFieldFormsSection(for call: ServiceCall) -> some View {
        let templates = fieldFormTemplates
            .filter { $0.isActive && $0.applies(to: call.type) }
            .sorted { lhs, rhs in
                if lhs.requiresCompletionForCloseout != rhs.requiresCompletionForCloseout {
                    return lhs.requiresCompletionForCloseout
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        let responses = fieldFormResponses.filter { $0.serviceCallID == call.id }
        let readiness = FieldFormCloseoutPolicy.readiness(
            serviceCallID: call.id,
            serviceType: call.type,
            templates: fieldFormTemplates,
            responses: fieldFormResponses
        )
        let missingIDs = Set(readiness.missingRequirements.map(\.templateID))
        let remainingTemplates = templates.filter { !missingIDs.contains($0.id) }

        Section("Field Forms") {
            if templates.isEmpty {
                Text("No active forms apply to this job type. An administrator can configure them in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Label(
                        readiness.statusLabel,
                        systemImage: readiness.isReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(readiness.isReady ? Color.green : Color.orange)
                    Spacer()
                    if readiness.totalCount > 0 {
                        Text("\(readiness.completedCount)/\(readiness.totalCount)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("JobFieldFormsReadiness")

                ForEach(readiness.missingRequirements) { requirement in
                    if let template = templates.first(where: { $0.id == requirement.templateID }) {
                        NavigationLink {
                            FieldFormResponseEditor(
                                template: template,
                                serviceCall: call,
                                actorEmail: currentUserEmail
                            )
                        } label: {
                            Label("Complete \(template.title)", systemImage: "checklist.unchecked")
                        }
                        .accessibilityIdentifier("CompleteRequiredFieldForm-\(template.id.uuidString)")
                    }
                }

                if !remainingTemplates.isEmpty {
                    DisclosureGroup(readiness.isReady ? "Forms and completed records" : "Other and completed forms") {
                        ForEach(remainingTemplates) { template in
                            jobFieldFormRow(template, call: call, responses: responses)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func jobFieldFormRow(
        _ template: FieldFormTemplate,
        call: ServiceCall,
        responses: [FieldFormResponse]
    ) -> some View {
        if let response = FieldFormCloseoutPolicy.latestResponse(
            completing: template,
            serviceCallID: call.id,
            responses: responses
        ) {
            NavigationLink {
                FieldFormResponseDetailView(
                    response: response,
                    template: fieldFormTemplates.first { $0.id == response.templateID },
                    serviceCall: call,
                    attachment: fieldFormAttachment(for: response, call: call)
                )
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(template.title)
                        Text("Completed \(response.completedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        } else {
            NavigationLink {
                FieldFormResponseEditor(
                    template: template,
                    serviceCall: call,
                    actorEmail: currentUserEmail
                )
            } label: {
                Label(
                    template.requiresCompletionForCloseout ? "Complete \(template.title)" : template.title,
                    systemImage: template.requiresCompletionForCloseout ? "checklist.unchecked" : "checklist"
                )
            }
        }
    }

    private func fieldFormAttachment(
        for response: FieldFormResponse,
        call: ServiceCall
    ) -> ServiceDocumentAttachment? {
        let marker = "[FieldFormResponse:\(response.id.uuidString)]"
        return attachments.first {
            $0.serviceCallID == call.id && ($0.caption?.contains(marker) ?? false)
        }
    }

    @ViewBuilder
    private func closeoutReadinessSection(for call: ServiceCall) -> some View {
        let readiness = call.closeoutReadiness(
            invoice: currentJobInvoice,
            payments: currentJobPayments,
            attachments: activeJobAttachments,
            fieldFormTemplates: fieldFormTemplates,
            fieldFormResponses: fieldFormResponses,
            timeEntries: timeEntries,
            materialReadiness: jobMaterialCloseoutSummary,
            serviceCallActivities: serviceCallActivities,
            requireWorkPerformedLog: requireWorkPerformedLogForCloseout
        )
        let photoEvidence = call.photoEvidenceStatus(from: activeJobAttachments)
        let documentationPackageSummary = call.billingDocumentationPackageSummary(
            invoice: currentJobInvoice,
            estimate: currentJobEstimate,
            attachments: activeJobAttachments
        )
        let jobTimeEntries = timeEntries.filter {
            $0.serviceCall?.id == call.id && $0.activity == .job
        }
        let openJobTimeCount = jobTimeEntries.filter(\.isOpen).count
        let materialReadiness = jobMaterialCloseoutSummary
        Section("Closeout Readiness") {
            HStack {
                Label(
                    readiness.statusLabel,
                    systemImage: readiness.isReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundColor(readiness.isReady ? .green : .orange)
                Spacer()
                Text(readiness.summary)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            Text("\(photoEvidence.statusLabel) - \(photoEvidence.summary)")
                .font(.caption)
                .foregroundColor(photoEvidence.isReady ? .secondary : .orange)
            if let documentationPackageSummary {
                Text(documentationPackageSummary)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if !jobTimeEntries.isEmpty {
                Label(
                    openJobTimeCount == 0
                        ? "Job time stopped"
                        : "\(openJobTimeCount) job timer\(openJobTimeCount == 1 ? "" : "s") still running",
                    systemImage: openJobTimeCount == 0 ? "clock.badge.checkmark" : "clock.badge.exclamationmark"
                )
                .font(.caption)
                .foregroundStyle(openJobTimeCount == 0 ? Color.secondary : Color.orange)
                .accessibilityIdentifier("JobTimeCloseoutStatus")
            }
            if materialReadiness.isApplicable {
                Label(
                    materialReadiness.isReady
                        ? "Material ledger complete"
                        : "\(materialReadiness.statusLabel) in Billing",
                    systemImage: materialReadiness.isReady ? "shippingbox.fill" : "shippingbox.and.arrow.backward"
                )
                .font(.caption)
                .foregroundStyle(materialReadiness.isReady ? Color.secondary : Color.orange)
                .accessibilityIdentifier("JobMaterialCloseoutStatus")
            }

            if readiness.missingItems.isEmpty {
                Text("Required report, billing, signature, payment, and QuickBooks attachment evidence is complete.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                if let nextAction = readiness.nextAction {
                    Button {
                        openNextCloseoutAction(nextAction)
                    } label: {
                        Label("Next: \(nextAction.label)", systemImage: "arrow.right.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brandGold)
                    .foregroundStyle(Color.primaryBlack)
                    .accessibilityIdentifier("JobCloseoutNextAction")
                    .accessibilityHint("Opens the workspace needed to resolve the first closeout requirement.")
                }

                DisclosureGroup("Missing closeout items") {
                    ForEach(readiness.missingActionItems, id: \.self) { item in
                        Label(item, systemImage: "circle")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private func openNextCloseoutAction(_ action: JobCloseoutNextAction) {
        switch action.destination {
        case .work:
            withAnimation(GunnAireAccessibilityMotionPolicy.standardAnimation(reduceMotion: reduceMotion)) {
                selectedJobStage = .work
            }
        case .files:
            withAnimation(GunnAireAccessibilityMotionPolicy.standardAnimation(reduceMotion: reduceMotion)) {
                selectedJobStage = .files
            }
        case .billing:
            withAnimation(GunnAireAccessibilityMotionPolicy.standardAnimation(reduceMotion: reduceMotion)) {
                selectedJobStage = .billing
            }
        case .invoiceCloseout:
            guard let invoice = currentJobInvoice else {
                withAnimation(GunnAireAccessibilityMotionPolicy.standardAnimation(reduceMotion: reduceMotion)) {
                    selectedJobStage = .billing
                }
                return
            }
            openInvoiceCloseout(invoice)
        case .timeClock:
            GunnAireAppIntentRouter.store(.timeClock)
        }
    }

    @ViewBuilder
    private func technicalServiceReportSection(for call: ServiceCall) -> some View {
        Section("Technical HVAC Report") {
            if !activeCustomerEquipmentProfiles.isEmpty {
                SearchableDropdownPicker(
                    title: "Customer Equipment",
                    options: customerEquipmentDropdownOptions,
                    selectedID: Binding(
                        get: { call.customerEquipmentID?.uuidString },
                        set: { selectedValue in
                            let selectedID = selectedValue.flatMap(UUID.init(uuidString:))
                            call.customerEquipmentID = selectedID
                            if let selectedID,
                               let equipment = activeCustomerEquipmentProfiles.first(where: { $0.id == selectedID }) {
                                applyEquipmentProfile(equipment, to: call)
                            }
                        }
                    ),
                    placeholder: "No linked equipment",
                    showsClearButton: true
                )
            }

            if let summary = latestServiceContextSummary(for: call) {
                Label(summary, systemImage: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            let lifecycle = call.equipmentLifecycleSnapshot
            if let lifecycleSummary = lifecycle.summary {
                Label(lifecycleSummary, systemImage: "calendar.badge.clock")
                    .font(.caption)
                    .foregroundColor(
                        lifecycle.attention == .invalidDates
                            ? .red
                            : lifecycle.attention == .none ? .secondary : .orange
                    )
            }
            if let previousCall = latestCompletedServiceCall(for: call),
               !previousCall.populatedTechnicalReadingRows.isEmpty {
                Button {
                    copyPreviousTechnicalReadings(from: previousCall, to: call)
                } label: {
                    Label("Use Previous Readings", systemImage: "arrow.down.doc")
                }
                .buttonStyle(.bordered)
            }

            SearchableDropdownPicker(
                title: "Equipment Type",
                options: HVACEquipmentType.allCases.map {
                    SearchableDropdownOption(id: $0.rawValue, title: $0.displayName)
                },
                selectedID: equipmentTypeSelection(for: call),
                placeholder: "Select Equipment Type",
                showsClearButton: true
            )

            reportReadinessView(for: call)

            DisclosureGroup {
                TextField("Equipment Name", text: optionalServiceCallTextBinding(call, \.equipmentName))
                TextField("Manufacturer", text: optionalServiceCallTextBinding(call, \.equipmentManufacturer))
                TextField("Model", text: optionalServiceCallTextBinding(call, \.equipmentModel))
                TextField("Serial Number", text: optionalServiceCallTextBinding(call, \.equipmentSerialNumber))
                TextField("Equipment Location", text: optionalServiceCallTextBinding(call, \.equipmentLocation))
                if call.equipmentInstallDate == nil {
                    Button("Set Install Date") {
                        call.equipmentInstallDate = Date()
                        call.diagnosticsCaptured = true
                    }
                    .buttonStyle(.bordered)
                } else {
                    DatePicker(
                        "Install Date",
                        selection: optionalServiceCallDateBinding(call, \.equipmentInstallDate),
                        displayedComponents: .date
                    )
                    Button("Clear Install Date") {
                        call.equipmentInstallDate = nil
                    }
                    .buttonStyle(.bordered)
                }

                if call.equipmentWarrantyExpiration == nil {
                    Button("Set Warranty Expiration") {
                        call.equipmentWarrantyExpiration = Calendar.current.date(
                            byAdding: .year,
                            value: 1,
                            to: Date()
                        ) ?? Date()
                        call.diagnosticsCaptured = true
                    }
                    .buttonStyle(.bordered)
                } else {
                    DatePicker(
                        "Warranty Expiration",
                        selection: optionalServiceCallDateBinding(call, \.equipmentWarrantyExpiration),
                        displayedComponents: .date
                    )
                    Button("Clear Warranty Expiration") {
                        call.equipmentWarrantyExpiration = nil
                    }
                    .buttonStyle(.bordered)
                }

                if let validationMessage = call.equipmentLifecycleSnapshot.validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("JobDocumentationEquipmentDateValidation")
                }

                Button(call.customerEquipmentID == nil ? "Save as Customer Equipment" : "Update Customer Equipment") {
                    saveCurrentEquipmentProfile(for: call)
                }
                .buttonStyle(.bordered)
                .disabled(
                    call.equipmentName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false ||
                        call.equipmentType == nil ||
                        call.equipmentLifecycleSnapshot.validationMessage != nil
                )
            } label: {
                HStack {
                    Label("Equipment Profile", systemImage: "wrench.and.screwdriver")
                    Spacer()
                    Text(equipmentProfileSummary(for: call))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            technicalReadingAttentionSection(for: call)

            if call.equipmentType == nil {
                Label("Select an equipment type to load the correct technical readings and service actions.", systemImage: "list.bullet.rectangle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(call.groupedTechnicalReadingDefinitions) { group in
                    DisclosureGroup {
                        Button {
                            call.markBlankTechnicalReadingsUnableToTest(in: group)
                        } label: {
                            Label("Mark Blank Fields Unable To Test", systemImage: "checklist.unchecked")
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)

                        ForEach(call.prioritizedTechnicalReadingDefinitions(in: group)) { definition in
                            technicalReadingInput(for: call, definition: definition)
                        }
                    } label: {
                        let progress = call.technicalReadingProgress(in: group)
                        HStack {
                            Text(group.title)
                            Spacer()
                            Text(progress.summary)
                                .font(.caption)
                                .foregroundColor(progress.needsAttention ? .orange : .secondary)
                        }
                    }
                }
            }

            if call.technicalReadingDefinitions.contains(where: { $0.key == "temperature_split" }) {
                HStack {
                    Button("Calculate Temp Split") {
                        calculateTemperatureSplit(for: call)
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    let split = call.technicalReading(for: "temperature_split")
                    if !split.isEmpty {
                        Text("\(split) F")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            if call.technicalReadingDefinitions.contains(where: { $0.key == "temperature_rise" }) {
                HStack {
                    Button("Calculate Temp Rise") {
                        calculateTemperatureRise(for: call)
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    let rise = call.technicalReading(for: "temperature_rise")
                    if !rise.isEmpty {
                        Text("\(rise) F")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            if call.technicalReadingDefinitions.contains(where: { $0.key == "superheat" }) {
                HStack {
                    Button("Calculate Superheat") {
                        calculateSuperheat(for: call)
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    let superheat = call.technicalReading(for: "superheat")
                    if !superheat.isEmpty {
                        Text("\(superheat) F")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            if call.technicalReadingDefinitions.contains(where: { $0.key == "subcooling" }) {
                HStack {
                    Button("Calculate Subcooling") {
                        calculateSubcooling(for: call)
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    let subcooling = call.technicalReading(for: "subcooling")
                    if !subcooling.isEmpty {
                        Text("\(subcooling) F")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            if call.technicalReadingDefinitions.contains(where: { $0.key == "total_external_static" }) {
                HStack {
                    Button("Calculate Total Static") {
                        calculateTotalExternalStatic(for: call)
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    let totalStatic = call.technicalReading(for: "total_external_static")
                    if !totalStatic.isEmpty {
                        Text("\(totalStatic) in. w.c.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            TextField("Filter Size", text: optionalServiceCallTextBinding(call, \.filterSize))
            TextField("Equipment Notes", text: optionalServiceCallTextBinding(call, \.equipmentNotes), axis: .vertical)
                .lineLimit(2...4)
            serviceReportOptionPicker(
                "Filter Condition",
                selection: optionalServiceCallTextBinding(call, \.filterCondition),
                options: ["New", "Clean", "Dirty", "Replaced", "Needs Replacement", "Not Applicable"]
            )
            serviceReportOptionPicker(
                "Indoor Coil Condition",
                selection: optionalServiceCallTextBinding(call, \.indoorCoilCondition),
                options: ["Clean", "Light Dust", "Dirty", "Impacted", "Frozen", "Damaged", "Not Accessible", "Not Applicable"]
            )
            serviceReportOptionPicker(
                "Outdoor Coil Condition",
                selection: optionalServiceCallTextBinding(call, \.outdoorCoilCondition),
                options: ["Clean", "Light Dust", "Dirty", "Impacted", "Damaged", "Washed", "Not Accessible", "Not Applicable"]
            )
            serviceReportOptionPicker(
                "Drain Line Condition",
                selection: optionalServiceCallTextBinding(call, \.drainLineCondition),
                options: ["Clear", "Slow", "Clogged", "Cleared", "Treated", "Needs Repair", "Not Applicable"]
            )
            serviceReportOptionPicker(
                "Thermostat Operation",
                selection: optionalServiceCallTextBinding(call, \.thermostatOperation),
                options: ["Normal", "Calibrated", "Battery Replaced", "Faulty", "Needs Replacement", "Not Tested"]
            )

            serviceActionChecklistView(for: call)

            TextField("Service Report Summary", text: optionalServiceCallTextBinding(call, \.serviceReportSummary), axis: .vertical)
                .lineLimit(2...5)

            if !call.populatedTechnicalReadingRows.isEmpty {
                Text("\(call.populatedTechnicalReadingRows.count) technical reading\(call.populatedTechnicalReadingRows.count == 1 ? "" : "s") captured")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func technicalReadingAttentionSection(for call: ServiceCall) -> some View {
        let definitions = call.attentionTechnicalReadingDefinitions
        if !definitions.isEmpty {
            DisclosureGroup {
                ForEach(definitions) { definition in
                    technicalReadingInput(for: call, definition: definition)
                }
            } label: {
                HStack {
                    Label("Attention Required", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Spacer()
                    Text("\(definitions.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private func serviceActionChecklistView(for call: ServiceCall) -> some View {
        if !call.groupedServiceActionDefinitions.isEmpty {
            DisclosureGroup("Equipment Service Actions") {
                ForEach(call.groupedServiceActionDefinitions) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(group.title)
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)
                            Spacer()
                            Menu {
                                Button("Mark Unchecked Completed") {
                                    call.markUncheckedServiceActions(.completed, in: group)
                                }
                                Button("Mark Unchecked N/A") {
                                    call.markUncheckedServiceActions(.notApplicable, in: group)
                                }
                            } label: {
                                Label("Group Actions", systemImage: "ellipsis.circle")
                                    .font(.caption)
                            }
                        }
                        ForEach(group.definitions) { definition in
                            serviceActionStatusPicker(definition, call: call)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func serviceActionStatusPicker(_ definition: HVACServiceActionDefinition, call: ServiceCall) -> some View {
        let title = definition.required ? "\(definition.label) *" : definition.label
        return SearchableDropdownPicker(
            title: title,
            options: HVACServiceActionStatus.allCases.map { SearchableDropdownOption(id: $0.rawValue, title: $0.label) },
            selectedID: serviceActionStatusSelection(for: call, key: definition.key),
            placeholder: "Not Checked",
            showsClearButton: true
        )
    }

    private func equipmentProfileSummary(for call: ServiceCall) -> String {
        let parts = [
            call.equipmentName,
            call.equipmentManufacturer,
            call.equipmentModel,
            call.equipmentSerialNumber.map { "S/N \($0)" }
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if !parts.isEmpty {
            return parts.joined(separator: " • ")
        }
        return call.equipmentType?.displayName ?? "Not set"
    }

    @ViewBuilder
    private func reportReadinessView(for call: ServiceCall) -> some View {
        let missingLabels = call.serviceReportMissingRequirementLabels
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    missingLabels.isEmpty ? "Report Ready" : "Report Needs Details",
                    systemImage: missingLabels.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundColor(missingLabels.isEmpty ? .green : .orange)
                Spacer()
                Text(call.serviceReportReadinessSummary)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
            }

            if !missingLabels.isEmpty {
                if let nextAction = call.nextServiceReportActionLabel {
                    Label(nextAction, systemImage: "arrow.forward.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.orange)
                }
                if let actionSummary = call.serviceReportActionSummary {
                    Text(actionSummary)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                DisclosureGroup("Missing required report items") {
                    ForEach(missingLabels, id: \.self) { label in
                        Label(label, systemImage: "circle")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private func latestServiceContextSummary(for call: ServiceCall) -> String? {
        guard let equipment = activeCustomerEquipmentProfiles.first(where: { $0.matches(call) }) else {
            return nil
        }
        return equipment.latestServiceContextSummary(
            in: serviceCalls.filter { $0.id != call.id },
            now: Date()
        )
    }

    private func latestCompletedServiceCall(for call: ServiceCall) -> ServiceCall? {
        guard let equipment = activeCustomerEquipmentProfiles.first(where: { $0.matches(call) }) else {
            return nil
        }
        return equipment.latestCompletedServiceCall(
            in: serviceCalls.filter { $0.id != call.id },
            now: Date()
        )
    }

    private func copyPreviousTechnicalReadings(from previousCall: ServiceCall, to call: ServiceCall) {
        let copiedCount = call.copyTechnicalReadings(from: previousCall)
        if copiedCount == 0 {
            actionMessage = "No blank matching readings were available to copy from the previous service."
        } else {
            actionMessage = "Copied \(copiedCount) previous technical reading\(copiedCount == 1 ? "" : "s") into blank fields."
        }
    }

    @ViewBuilder
    private func technicalReadingInput(for call: ServiceCall, definition: HVACTechnicalReadingDefinition) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if call.requiredTechnicalReadingDefinitions.contains(definition) {
                    Text("Required")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.orange)
                }
                if let hint = definition.inputHint {
                    Text(hint)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            if definition.isCalculated {
                calculatedTechnicalReadingValue(for: call, definition: definition)
            } else if definition.options.isEmpty {
                HStack {
                    TextField(definition.displayLabel, text: technicalReadingBinding(for: call, key: definition.key))
                        .keyboardType(.numbersAndPunctuation)
                    Button(HVACTechnicalReadingDefinition.unableToTestValue) {
                        call.setTechnicalReading(HVACTechnicalReadingDefinition.unableToTestValue, for: definition.key)
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                }
            } else {
                serviceReportOptionPicker(
                    definition.displayLabel,
                    selection: technicalReadingBinding(for: call, key: definition.key),
                    options: definition.options
                )
            }

            if let issue = call.technicalReadingValidationIssue(for: definition) {
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundColor(.orange)
            } else if let expectedRange = definition.expectedRangeLabel {
                Text("Expected range: \(expectedRange)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func calculatedTechnicalReadingValue(for call: ServiceCall, definition: HVACTechnicalReadingDefinition) -> some View {
        let value = call.technicalReading(for: definition.key).trimmingCharacters(in: .whitespacesAndNewlines)
        let isNonNumericStatus = HVACTechnicalReadingDefinition.isNonNumericStatus(value)
        HStack {
            Label(
                value.isEmpty ? "Calculated after source readings are entered" : "\(value)\(!isNonNumericStatus ? definition.unit.map { " \($0)" } ?? "" : "")",
                systemImage: value.isEmpty ? "function" : "checkmark.circle.fill"
            )
            .font(.subheadline)
            .foregroundColor(value.isEmpty ? .secondary : .green)
            Spacer()
            Button(HVACTechnicalReadingDefinition.unableToTestValue) {
                call.setTechnicalReading(HVACTechnicalReadingDefinition.unableToTestValue, for: definition.key)
            }
            .buttonStyle(.bordered)
            .font(.caption)
        }
        if let hint = definition.calculationSourceHint {
            Text(hint)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private func serviceReportOptionPicker(_ title: String, selection: Binding<String>, options: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SearchableDropdownPicker(
                title: title,
                options: dropdownOptions(options, currentValue: selection.wrappedValue),
                selectedID: optionalStringSelection(selection),
                placeholder: "Not Set",
                showsClearButton: true
            )
            if shouldShowCustomOptionField(selection.wrappedValue, options: options) {
                TextField("Specify \(title)", text: customOptionBinding(selection, options: options))
                    .textInputAutocapitalization(.words)
            }
        }
    }

    private func dropdownOptions(_ options: [String], currentValue: String) -> [SearchableDropdownOption] {
        let trimmedCurrentValue = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var dropdownOptions = options.map { SearchableDropdownOption(id: $0, title: $0) }
        if !trimmedCurrentValue.isEmpty,
           !options.contains(where: { $0.caseInsensitiveCompare(trimmedCurrentValue) == .orderedSame }) {
            dropdownOptions.append(SearchableDropdownOption(id: trimmedCurrentValue, title: trimmedCurrentValue, subtitle: "Custom"))
        }
        return dropdownOptions
    }

    private func shouldShowCustomOptionField(_ value: String, options: [String]) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.caseInsensitiveCompare("Other") == .orderedSame ||
            !options.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
    }

    private func customOptionBinding(_ selection: Binding<String>, options: [String]) -> Binding<String> {
        Binding(
            get: {
                let trimmed = selection.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !options.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
                    return ""
                }
                return trimmed
            },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                selection.wrappedValue = trimmed.isEmpty ? "Other" : trimmed
            }
        )
    }

    private func optionalStringSelection(_ selection: Binding<String>) -> Binding<String?> {
        Binding<String?>(
            get: {
                let trimmed = selection.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            },
            set: { newValue in
                selection.wrappedValue = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
        )
    }

    private func optionalServiceCallTextBinding(_ call: ServiceCall, _ keyPath: ReferenceWritableKeyPath<ServiceCall, String?>) -> Binding<String> {
        Binding(
            get: { call[keyPath: keyPath] ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                call[keyPath: keyPath] = trimmed.isEmpty ? nil : trimmed
                if !trimmed.isEmpty {
                    call.diagnosticsCaptured = true
                }
            }
        )
    }

    private func optionalServiceCallDateBinding(_ call: ServiceCall, _ keyPath: ReferenceWritableKeyPath<ServiceCall, Date?>) -> Binding<Date> {
        Binding(
            get: { call[keyPath: keyPath] ?? Date() },
            set: { newValue in
                call[keyPath: keyPath] = newValue
                call.diagnosticsCaptured = true
            }
        )
    }

    private func technicalReadingBinding(for call: ServiceCall, key: String) -> Binding<String> {
        Binding(
            get: { call.technicalReading(for: key) },
            set: { call.setTechnicalReading($0, for: key) }
        )
    }

    private func serviceActionStatusSelection(for call: ServiceCall, key: String) -> Binding<String?> {
        Binding<String?>(
            get: {
                let status = call.serviceActionStatus(for: key)
                return status == .notChecked ? nil : status.rawValue
            },
            set: { newValue in
                let status = newValue.flatMap(HVACServiceActionStatus.init(rawValue:)) ?? .notChecked
                call.setServiceActionStatus(status, for: key)
            }
        )
    }

    private func equipmentTypeSelection(for call: ServiceCall) -> Binding<String?> {
        Binding<String?>(
            get: { call.equipmentType?.rawValue },
            set: { selectedID in
                if let selectedID,
                   let equipmentType = HVACEquipmentType(rawValue: selectedID) {
                    call.equipmentType = equipmentType
                    call.diagnosticsCaptured = true
                } else {
                    call.equipmentType = nil
                }
            }
        )
    }

    private func applyEquipmentProfile(_ equipment: CustomerEquipment, to call: ServiceCall) {
        equipment.apply(to: call)
        call.equipmentVerifiedChecklist = true
        call.diagnosticsCaptured = true
        let linkedCount = ServiceDocumentAttachment.backfillMissingEquipmentLinks(for: call, in: attachments)
        let baselineCount = equipment.applyTechnicalBaselines(to: call)
        let baselineMessage = baselineCount > 0
            ? " Pre-filled \(baselineCount) equipment baseline reading\(baselineCount == 1 ? "" : "s")."
            : ""
        actionMessage = linkedCount > 0
            ? "Loaded equipment profile and linked \(linkedCount) existing job file\(linkedCount == 1 ? "" : "s") to this equipment.\(baselineMessage)"
            : "Loaded equipment profile for this job.\(baselineMessage)"
    }

    private func saveCurrentEquipmentProfile(for call: ServiceCall, announce: Bool = true) {
        let equipmentName = call.equipmentName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let equipmentName, !equipmentName.isEmpty else {
            if announce {
                actionMessage = "Enter equipment name before saving a customer equipment profile."
            }
            return
        }
        guard let equipmentType = call.equipmentType else {
            if announce {
                actionMessage = "Select equipment type before saving a customer equipment profile."
            }
            return
        }
        if let validationMessage = call.equipmentLifecycleSnapshot.validationMessage {
            if announce {
                actionMessage = validationMessage
            }
            return
        }

        let equipment: CustomerEquipment
        if let existingID = call.customerEquipmentID,
           let existing = equipmentProfiles.first(where: { $0.id == existingID }) {
            equipment = existing
        } else if let serial = call.equipmentSerialNumber?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !serial.isEmpty,
                  let existing = equipmentProfiles.first(where: {
                      $0.customer?.id == call.customer.id &&
                      $0.serialNumber?.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(serial) == .orderedSame
                  }) {
            equipment = existing
            call.customerEquipmentID = existing.id
        } else {
            equipment = CustomerEquipment(customer: call.customer, name: equipmentName)
            modelContext.insert(equipment)
            call.customerEquipmentID = equipment.id
        }

        equipment.updateFrom(
            serviceLocationID: call.serviceLocationID,
            equipmentType: equipmentType,
            name: equipmentName,
            manufacturer: call.equipmentManufacturer,
            modelNumber: call.equipmentModel,
            serialNumber: call.equipmentSerialNumber,
            location: call.equipmentLocation,
            installDate: call.equipmentInstallDate,
            warrantyExpiration: call.equipmentWarrantyExpiration,
            filterSize: call.filterSize,
            notes: CustomerEquipment.mergedNotes(
                existing: equipment.notes,
                currentProfileNote: call.equipmentNotes,
                serviceHistoryNote: call.equipmentProfileServiceHistoryNote
            ),
            isActive: true
        )
        let baselineCount = equipment.updateTechnicalBaselines(from: call)
        call.equipmentVerifiedChecklist = true
        let linkedCount = ServiceDocumentAttachment.backfillMissingEquipmentLinks(for: call, in: attachments)
        try? modelContext.save()
        if announce {
            let baselineMessage = baselineCount > 0
                ? " Saved \(baselineCount) equipment baseline reading\(baselineCount == 1 ? "" : "s")."
                : ""
            actionMessage = linkedCount > 0
                ? "Saved equipment profile to \(call.customer.name) and linked \(linkedCount) existing job file\(linkedCount == 1 ? "" : "s").\(baselineMessage)"
                : "Saved equipment profile to \(call.customer.name).\(baselineMessage)"
        }
    }

    private func calculateTemperatureSplit(for call: ServiceCall) {
        guard call.calculateTemperatureSplitReading() != nil else {
            actionMessage = "Enter return and supply air temperatures before calculating temperature split."
            return
        }
        actionMessage = "Temperature split calculated."
    }

    private func calculateTemperatureRise(for call: ServiceCall) {
        guard call.calculateTemperatureRiseReading() != nil else {
            actionMessage = "Enter return and supply air temperatures before calculating temperature rise."
            return
        }
        actionMessage = "Temperature rise calculated."
    }

    private func calculateSuperheat(for call: ServiceCall) {
        guard call.calculateSuperheatReading() != nil else {
            actionMessage = "Enter suction line temperature and suction saturation temperature before calculating superheat."
            return
        }
        actionMessage = "Superheat calculated."
    }

    private func calculateSubcooling(for call: ServiceCall) {
        guard call.calculateSubcoolingReading() != nil else {
            actionMessage = "Enter liquid line temperature and liquid saturation temperature before calculating subcooling."
            return
        }
        actionMessage = "Subcooling calculated."
    }

    private func calculateTotalExternalStatic(for call: ServiceCall) {
        guard call.calculateTotalExternalStaticReading() != nil else {
            actionMessage = "Enter return and supply static pressure before calculating total external static."
            return
        }
        actionMessage = "Total external static calculated."
    }

    @ViewBuilder
    private func attachmentSection(for call: ServiceCall) -> some View {
        Section("Photos & Attachments") {
            Picker("Type", selection: $attachmentKind) {
                ForEach(ServiceDocumentAttachmentKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }

            TextField("Caption or note", text: $attachmentCaption)

            HStack {
                Button {
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        showingDocumentationCamera = true
                    } else {
                        attachmentMessage = "Camera is not available on this device."
                    }
                } label: {
                    Label("Camera", systemImage: "camera")
                }
                .buttonStyle(.bordered)

                Button {
                    showingDocumentationFileImporter = true
                } label: {
                    Label("Files", systemImage: "paperclip")
                }
                .buttonStyle(.bordered)
            }

            if let attachmentMessage {
                Text(attachmentMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if !activeJobAttachments.isEmpty {
                TextField("Search attachments", text: $attachmentSearchText)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
            }

            if activeJobAttachments.isEmpty {
                Text("No photos or documents attached to this job yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if filteredActiveJobAttachments.isEmpty {
                Text("No attachments match that search.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(groupedActiveJobAttachments, id: \.kind) { group in
                    DisclosureGroup {
                        ForEach(group.attachments) { attachment in
                            jobAttachmentRow(for: attachment)
                        }
                    } label: {
                        HStack {
                            Text(group.kind.label)
                            Spacer()
                            Text("\(group.attachments.count)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            Divider()

            HStack {
                Text("Shared Company Job Files")
                    .font(.headline)
                Spacer()
                Button(isLoadingSharedJobDocuments ? "Refreshing..." : "Refresh") {
                    Task {
                        await refreshSharedJobDocuments()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isLoadingSharedJobDocuments || !GunnAireBackendService.isConfigured)
            }

            if !GunnAireBackendService.isConfigured {
                Text("Shared company storage is not configured for this build.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if activeSharedJobDocuments.isEmpty {
                Text(sharedJobDocumentsMessage ?? "No shared company files loaded for this job.")
                    .font(.caption)
                    .foregroundColor((sharedJobDocumentsMessage ?? "").localizedCaseInsensitiveContains("failed") ? .orange : .secondary)
            } else {
                ForEach(activeSharedJobDocuments.prefix(8)) { document in
                    sharedJobDocumentRow(document)
                }
                if let sharedJobDocumentsMessage {
                    Text(sharedJobDocumentsMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func equipmentAttachmentHistorySection(for call: ServiceCall) -> some View {
        if !activeEquipmentHistoryAttachments.isEmpty {
            Section("Equipment File History") {
                ForEach(activeEquipmentHistoryAttachments.prefix(8)) { attachment in
                    jobAttachmentRow(for: attachment, allowsRemoval: false)
                }
            }
        }
    }

    private func sharedJobDocumentRow(_ document: BackendDocumentRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: document.contentType.lowercased().hasPrefix("image/") ? "photo" : "externaldrive.badge.checkmark")
                .foregroundColor(Color.brandGold)
                .frame(width: 42, height: 42)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(document.filename)
                        .lineLimit(1)
                    Spacer()
                    if let createdAt = document.createdAt, !createdAt.isEmpty {
                        Text(sharedJobDocumentDisplayDate(createdAt))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                HStack {
                    Text(sharedJobDocumentKindLabel(document.kind))
                    Text("Company storage")
                }
                .font(.caption2)
                .foregroundColor(.secondary)
                if let equipmentLabel = sharedJobDocumentEquipmentLabel(document) {
                    Text(equipmentLabel)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                Button(downloadingSharedJobDocumentID == document.id ? "Downloading..." : "Download & Open") {
                    Task {
                        await downloadSharedJobDocument(document)
                    }
                }
                .buttonStyle(.bordered)
                .font(.caption)
                .disabled(downloadingSharedJobDocumentID != nil)
            }
        }
    }

    @ViewBuilder
    private func jobAttachmentRow(for attachment: ServiceDocumentAttachment, allowsRemoval: Bool = true) -> some View {
        HStack(alignment: .top, spacing: 10) {
            jobAttachmentThumbnail(for: attachment)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(attachment.displayName)
                        .lineLimit(1)
                    Spacer()
                    Text(attachment.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if let caption = attachment.caption, !caption.isEmpty {
                    Text(caption)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                HStack {
                    Text(byteCountFormatter.string(fromByteCount: Int64(attachment.fileSizeBytes)))
                    if attachment.backendDocumentID != nil {
                        Text("Company storage")
                    }
                    if attachment.quickBooksAttachableID != nil {
                        Text("QuickBooks")
                    }
                    if attachment.quickBooksSyncError?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                        Text("Sync issue")
                    }
                }
                .font(.caption2)
                .foregroundColor(.secondary)

                HStack(spacing: 12) {
                    Button {
                        previewJobAttachment(attachment)
                    } label: {
                        Label("Preview", systemImage: attachment.isImage ? "photo" : "doc.text.magnifyingglass")
                    }
                    .frame(minHeight: 44)

                    if attachment.isImage, allowsRemoval {
                        Button {
                            annotateJobAttachment(attachment)
                        } label: {
                            Label("Annotate", systemImage: "pencil.tip.crop.circle")
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("AnnotateAttachment-\(attachment.id)")
                    }

                    ShareLink(item: attachment.localFileURL) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .frame(minHeight: 44)
                }
                .font(.caption)
                .buttonStyle(.borderless)

                if allowsRemoval {
                    Button(role: .destructive) {
                        removeJobAttachment(attachment)
                    } label: {
                        Label("Remove Attachment", systemImage: "trash")
                    }
                    .font(.caption)
                    .frame(minHeight: 44)
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private func previewJobAttachment(_ attachment: ServiceDocumentAttachment) {
        let url = attachment.localFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            attachmentMessage = "\(attachment.displayName) is no longer available on this device."
            return
        }
        attachmentPendingMarkup = nil
        attachmentPreviewURL = url
    }

    private func annotateJobAttachment(_ attachment: ServiceDocumentAttachment) {
        guard attachment.isImage else {
            attachmentMessage = "Only image attachments can be annotated."
            return
        }
        guard attachment.serviceCallID == activeServiceCall?.id else {
            attachmentMessage = "Open the attachment's current job before annotating it."
            return
        }
        let url = attachment.localFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            attachmentMessage = "\(attachment.displayName) is no longer available on this device."
            return
        }
        attachmentPendingMarkup = attachment
        attachmentPreviewURL = url
    }

    private func saveAnnotatedAttachmentCopy(
        from modifiedContentsURL: URL,
        original: ServiceDocumentAttachment
    ) {
        guard let call = activeServiceCall, original.serviceCallID == call.id else {
            attachmentMessage = "The active job changed before the annotated copy could be saved."
            return
        }

        var storedURL: URL?
        do {
            let data = try Data(contentsOf: modifiedContentsURL)
            guard !data.isEmpty else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let metadata = AttachmentMarkupCopyPolicy.metadata(
                originalDisplayName: original.displayName,
                originalCaption: original.caption,
                modifiedContentsURL: modifiedContentsURL
            )
            let savedURL = try persistAttachmentData(data, originalFilename: metadata.filename)
            storedURL = savedURL
            let resolvedContentType = contentType(for: modifiedContentsURL)
            let attachment = ServiceDocumentAttachment(
                customer: original.customer ?? call.customer,
                serviceCallID: call.id,
                customerEquipmentID: original.customerEquipmentID,
                invoiceID: original.invoiceID,
                estimateID: original.estimateID,
                maintenanceContractID: original.maintenanceContractID,
                fleetVehicleID: original.fleetVehicleID,
                fleetVehicleEventID: original.fleetVehicleEventID,
                expenseClaimID: original.expenseClaimID,
                kind: original.kind,
                displayName: savedURL.lastPathComponent,
                caption: metadata.caption,
                localFilePath: savedURL.path,
                contentType: resolvedContentType == "application/octet-stream"
                    ? original.contentType
                    : resolvedContentType,
                fileSizeBytes: data.count
            )
            modelContext.insert(attachment)
            applyAttachmentProgress(attachment, to: call)
            try modelContext.save()
            attachmentMessage = "Saved annotated copy. The original photo was preserved."
            attachmentPreviewURL = nil
            attachmentPendingMarkup = nil
            syncAttachmentIfPossible(attachment, data: data)
        } catch {
            if let storedURL {
                try? FileManager.default.removeItem(at: storedURL)
            }
            attachmentMessage = "Could not save annotated copy: \(error.localizedDescription)"
        }
    }

    private func refreshSharedJobDocuments() async {
        guard GunnAireBackendService.isConfigured else {
            sharedJobDocumentsMessage = "Shared company storage is not configured."
            return
        }
        isLoadingSharedJobDocuments = true
        defer { isLoadingSharedJobDocuments = false }
        do {
            sharedJobDocuments = try await GunnAireBackendService.fetchDocuments()
            sharedJobDocumentsMessage = "Loaded \(activeSharedJobDocuments.count) shared company file\(activeSharedJobDocuments.count == 1 ? "" : "s") for this job."
        } catch {
            sharedJobDocumentsMessage = "Shared job file refresh failed: \(error.localizedDescription)"
        }
    }

    private func downloadSharedJobDocument(_ document: BackendDocumentRecord) async {
        downloadingSharedJobDocumentID = document.id
        defer { downloadingSharedJobDocumentID = nil }
        do {
            let data = try await GunnAireBackendService.downloadDocument(id: document.id)
            let cachedURL = try persistSharedJobDocument(data, document: document)
            hydrateSharedJobDocumentAttachment(document, cachedURL: cachedURL, fileSizeBytes: data.count)
            attachmentPreviewURL = cachedURL
            sharedJobDocumentsMessage = "Downloaded \(document.filename)."
        } catch {
            sharedJobDocumentsMessage = "Shared job file download failed: \(error.localizedDescription)"
        }
    }

    private func persistSharedJobDocument(_ data: Data, document: BackendDocumentRecord) throws -> URL {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let folder = documents.appendingPathComponent("GunnAire Shared Job Files", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(document.id)-\(sanitizeAttachmentFilename(document.filename))")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func hydrateSharedJobDocumentAttachment(
        _ document: BackendDocumentRecord,
        cachedURL: URL,
        fileSizeBytes: Int
    ) {
        guard let call = activeServiceCall else { return }
        let attachment = ServiceDocumentAttachment.localAttachment(
            from: document,
            existingAttachments: attachments,
            customer: call.customer,
            serviceCallID: call.id,
            customerEquipmentID: call.customerEquipmentID,
            localFilePath: cachedURL.path,
            fileSizeBytes: fileSizeBytes
        )
        if attachment.modelContext == nil {
            modelContext.insert(attachment)
        }
        try? modelContext.save()
    }

    private func sharedJobDocumentKindLabel(_ kind: String) -> String {
        ServiceDocumentAttachmentKind(rawValue: kind)?.label ??
            kind.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func sharedJobDocumentEquipmentLabel(_ document: BackendDocumentRecord) -> String? {
        if let equipmentName = document.equipmentName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !equipmentName.isEmpty {
            return "Equipment: \(equipmentName)"
        }
        if let equipmentID = document.customerEquipmentID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !equipmentID.isEmpty {
            return "Equipment ID: \(equipmentID.prefix(8))"
        }
        return nil
    }

    private func sharedJobDocumentDisplayDate(_ value: String) -> String {
        let date = ISO8601DateFormatter().date(from: value) ?? Date(timeIntervalSince1970: 0)
        return Self.sharedJobDocumentDateFormatter.string(from: date)
    }

    private static let sharedJobDocumentDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    @ViewBuilder
    private func jobAttachmentThumbnail(for attachment: ServiceDocumentAttachment) -> some View {
        if attachment.isImage,
           let image = UIImage(contentsOfFile: attachment.localFilePath) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(.separator), lineWidth: 0.5)
                )
                .accessibilityLabel("Attachment preview")
        } else {
            Image(systemName: attachment.isImage ? "photo" : "doc")
                .foregroundStyle(Color.brandGold)
                .frame(width: 56, height: 56)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityLabel(attachment.isImage ? "Photo attachment" : "Document attachment")
        }
    }

    private func handleCapturedDocumentationImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.85) else {
            attachmentMessage = "Could not encode camera image."
            return
        }
        let filename = "job-photo-\(UUID().uuidString).jpg"
        saveDocumentationAttachment(data: data, filename: filename, contentType: "image/jpeg")
    }

    private func handleImportedDocumentationFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            attachmentMessage = "File import failed: \(error.localizedDescription)"
        case .success(let urls):
            guard !urls.isEmpty else { return }
            var savedCount = 0
            var lastError: String?
            for url in urls {
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                do {
                    let data = try Data(contentsOf: url)
                    saveDocumentationAttachment(
                        data: data,
                        filename: url.lastPathComponent,
                        contentType: contentType(for: url)
                    )
                    savedCount += 1
                } catch {
                    lastError = error.localizedDescription
                }
            }
            if let lastError, savedCount == 0 {
                attachmentMessage = "Could not import file: \(lastError)"
            } else if savedCount > 1 {
                attachmentMessage = "Attached \(savedCount) files."
            }
        }
    }

    private func saveDocumentationAttachment(data: Data, filename: String, contentType: String) {
        guard let call = activeServiceCall else {
            attachmentMessage = "Open a job before attaching files."
            return
        }
        do {
            let storedURL = try persistAttachmentData(data, originalFilename: filename)
            let attachment = ServiceDocumentAttachment(
                customer: call.customer,
                serviceCallID: call.id,
                customerEquipmentID: call.customerEquipmentID,
                invoiceID: call.linkedInvoiceID,
                estimateID: call.linkedEstimateID,
                kind: attachmentKind,
                displayName: storedURL.lastPathComponent,
                caption: nilIfBlank(attachmentCaption),
                localFilePath: storedURL.path,
                contentType: contentType,
                fileSizeBytes: data.count
            )
            modelContext.insert(attachment)
            applyAttachmentProgress(attachment, to: call)
            try modelContext.save()
            attachmentCaption = ""
            attachmentMessage = "Attached \(attachment.displayName)."
            syncAttachmentIfPossible(attachment, data: data)
        } catch {
            attachmentMessage = "Could not save attachment: \(error.localizedDescription)"
        }
    }

    private func removeJobAttachment(_ attachment: ServiceDocumentAttachment) {
        let fileURL = attachment.localFileURL
        let displayName = attachment.displayName
        let linkedCall = attachment.serviceCallID.flatMap { callID in
            serviceCalls.first { $0.id == callID }
        }
        let remainingAttachments = linkedCall.map { call in
            attachments.filter { $0.serviceCallID == call.id && $0.id != attachment.id }
        }
        modelContext.delete(attachment)
        do {
            if let linkedCall, let remainingAttachments {
                linkedCall.refreshAttachmentProgress(from: remainingAttachments)
            }
            try modelContext.save()
            try? FileManager.default.removeItem(at: fileURL)
            attachmentMessage = "Removed \(displayName)."
        } catch {
            attachmentMessage = "Could not remove attachment: \(error.localizedDescription)"
        }
    }

    private func persistAttachmentData(_ data: Data, originalFilename: String) throws -> URL {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let folder = documents.appendingPathComponent("GunnAire Attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sanitizedName = sanitizeAttachmentFilename(originalFilename)
        let url = folder.appendingPathComponent("\(UUID().uuidString)-\(sanitizedName)")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func sanitizeAttachmentFilename(_ filename: String) -> String {
        let base = filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "attachment" : filename
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return base.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
    }

    private func applyAttachmentProgress(_ attachment: ServiceDocumentAttachment, to call: ServiceCall) {
        call.refreshAttachmentProgress(from: attachments + [attachment])
        call.documentationChecklist = true
    }

    private func syncAttachmentIfPossible(_ attachment: ServiceDocumentAttachment, data: Data) {
        if GunnAireBackendService.isConfigured {
            Task {
                do {
                    let response = try await GunnAireBackendService.uploadDocument(
                        data: data,
                        filename: attachment.displayName,
                        contentType: attachment.contentType,
                        kind: attachment.kindRaw,
                        serviceCallID: attachment.serviceCallID,
                        invoiceID: attachment.invoiceID,
                        estimateID: attachment.estimateID,
                        customerEquipmentID: attachment.customerEquipmentID,
                        equipmentName: attachment.linkedEquipment(in: equipmentProfiles, serviceCalls: serviceCalls)?.displayName,
                        customerName: attachment.customer?.name
                    )
                    attachment.markSharedCompanyStored(id: response.id)
                    try? modelContext.save()
                } catch {
                    attachment.markSharedCompanyUploadFailed(error.localizedDescription)
                    try? modelContext.save()
                    attachmentMessage = "Attachment saved locally. Company storage upload failed: \(error.localizedDescription)"
                }
            }
        }

        syncAttachmentToQuickBooksIfPossible(attachment)
    }

    private func linkExistingServiceReports(to invoice: Invoice, serviceCallID: UUID?) {
        linkExistingInvoiceAttachments(to: invoice, serviceCallID: serviceCallID)
    }

    private func linkExistingInvoiceAttachments(to invoice: Invoice, serviceCallID: UUID?) {
        guard let serviceCallID else { return }
        let invoiceAttachments = attachments.filter {
            $0.serviceCallID == serviceCallID &&
                $0.canLinkToQuickBooksInvoiceDocument &&
                $0.customerMatches(invoice.customer)
        }
        guard !invoiceAttachments.isEmpty else { return }

        for attachment in invoiceAttachments {
            attachment.linkToInvoiceIfNeeded(invoice)
        }
        try? modelContext.save()
        syncLinkedInvoiceAttachmentsToQuickBooks(invoice)
    }

    private func linkExistingEstimateAttachments(to estimate: Estimate, serviceCallID: UUID?) {
        guard let serviceCallID else { return }
        let estimateAttachments = attachments.filter {
            $0.serviceCallID == serviceCallID &&
                $0.canLinkToQuickBooksEstimateDocument &&
                $0.customerMatches(estimate.customer)
        }
        guard !estimateAttachments.isEmpty else { return }

        for attachment in estimateAttachments {
            attachment.linkToEstimateIfNeeded(estimate)
        }
        try? modelContext.save()
        syncLinkedEstimateAttachmentsToQuickBooks(estimate)
    }

    private func syncLinkedServiceReportsToQuickBooks(_ invoice: Invoice) {
        syncLinkedInvoiceAttachmentsToQuickBooks(invoice)
    }

    private func prepareLinkedOnsiteReportForInvoiceCreation(_ invoice: Invoice, serviceCall: ServiceCall?) -> String? {
        guard let serviceCall else { return nil }
        linkExistingInvoiceAttachments(to: invoice, serviceCallID: serviceCall.id)
        saveCurrentEquipmentProfile(for: serviceCall, announce: false)
        do {
            let linkedEstimate = estimates.first { estimate in
                estimate.id == serviceCall.linkedEstimateID || estimate.serviceCallID == serviceCall.id
            }
            let invoicePayments = payments.filter { $0.invoice.id == invoice.id }
            let report = try generateAndPersistOnsiteReportAttachment(
                for: serviceCall,
                estimate: linkedEstimate,
                invoice: invoice,
                payments: invoicePayments,
                attachments: reportEvidenceAttachments(for: serviceCall),
                equipmentProfiles: equipmentProfiles,
                serviceCalls: serviceCalls
            )
            report.attachment.linkToInvoiceIfNeeded(invoice)
            syncAttachmentIfPossible(report.attachment, data: report.data)
            return nil
        } catch {
            return "Invoice created, but the onsite report could not be generated automatically: \(error.localizedDescription)"
        }
    }

    private func syncLinkedInvoiceAttachmentsToQuickBooks(_ invoice: Invoice) {
        let invoiceAttachments = attachments.filter {
            $0.invoiceID == invoice.id && $0.canLinkToQuickBooksInvoiceDocument
        }
        for attachment in invoiceAttachments {
            syncAttachmentToQuickBooksIfPossible(attachment)
        }
    }

    private func syncLinkedEstimateAttachmentsToQuickBooks(_ estimate: Estimate) {
        let estimateAttachments = attachments.filter {
            $0.estimateID == estimate.id && $0.canLinkToQuickBooksEstimateDocument
        }
        for attachment in estimateAttachments {
            syncAttachmentToQuickBooksIfPossible(attachment)
        }
    }

    @discardableResult
    private func prepareEstimateDocumentationForQuickBooksSend(_ estimate: Estimate) -> Bool {
        do {
            let linkedCall = serviceCall(for: estimate)
            if let linkedCall {
                saveCurrentEquipmentProfile(for: linkedCall, announce: false)
                linkExistingEstimateAttachments(to: estimate, serviceCallID: linkedCall.id)
            }
            let url = try CustomerDocumentExporter.exportEstimate(
                estimate,
                serviceCall: linkedCall,
                attachments: attachments,
                equipmentProfiles: equipmentProfiles,
                serviceCalls: serviceCalls
            )
            let data = try Data(contentsOf: url)
            generatedCustomerDocumentURL = url
            generatedCustomerDocumentRecipientID = estimate.customer.id
            generatedCustomerDocumentServiceCallID = linkedCall?.id
            generatedCustomerDocumentInvoiceID = nil
            generatedCustomerDocumentEstimateID = estimate.id
            generatedCustomerDocumentKind = "estimate"

            let attachment: ServiceDocumentAttachment
            if let reusable = ServiceDocumentAttachment.reusableGeneratedBillingDocument(
                in: attachments,
                kind: .estimateSupport,
                serviceCallID: linkedCall?.id,
                invoiceID: nil,
                estimateID: estimate.id
            ) {
                reusable.replaceGeneratedFile(
                    displayName: url.lastPathComponent,
                    localFilePath: url.path,
                    contentType: "application/pdf",
                    fileSizeBytes: data.count,
                    caption: "Generated estimate PDF"
                )
                reusable.refreshGeneratedDocumentContext(
                    customer: estimate.customer,
                    serviceCallID: linkedCall?.id,
                    customerEquipmentID: linkedCall?.customerEquipmentID,
                    invoiceID: nil,
                    estimateID: estimate.id
                )
                attachment = reusable
            } else {
                let generated = ServiceDocumentAttachment(
                    customer: estimate.customer,
                    serviceCallID: linkedCall?.id,
                    customerEquipmentID: linkedCall?.customerEquipmentID,
                    invoiceID: nil,
                    estimateID: estimate.id,
                    kind: .estimateSupport,
                    displayName: url.lastPathComponent,
                    caption: "Generated estimate PDF",
                    localFilePath: url.path,
                    contentType: "application/pdf",
                    fileSizeBytes: data.count
                )
                modelContext.insert(generated)
                attachment = generated
            }

            try? modelContext.save()
            syncAttachmentIfPossible(attachment, data: data)
            if let linkedCall {
                do {
                    let report = try generateAndPersistOnsiteReportAttachment(
                        for: linkedCall,
                        estimate: estimate,
                        invoice: nil,
                        payments: [],
                        attachments: reportEvidenceAttachments(for: linkedCall),
                        equipmentProfiles: equipmentProfiles,
                        serviceCalls: serviceCalls
                    )
                    syncAttachmentIfPossible(report.attachment, data: report.data)
                } catch {
                    actionMessage = "Could not prepare the onsite report before sending this estimate: \(error.localizedDescription)"
                    return false
                }
            }
            syncLinkedEstimateAttachmentsToQuickBooks(estimate)
            return true
        } catch {
            actionMessage = "Could not prepare the estimate PDF before sending: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    private func prepareInvoiceDocumentationForQuickBooksSend(_ invoice: Invoice) -> Bool {
        let linkedServiceCall = serviceCall(for: invoice)
        guard prepareInvoicePDFForQuickBooksSend(invoice, serviceCall: linkedServiceCall) else {
            return false
        }

        guard let serviceCall = linkedServiceCall else {
            syncLinkedInvoiceAttachmentsToQuickBooks(invoice)
            return true
        }

        linkExistingInvoiceAttachments(to: invoice, serviceCallID: serviceCall.id)
        saveCurrentEquipmentProfile(for: serviceCall, announce: false)

        do {
            let linkedEstimate = currentJobEstimate ?? estimates.first { estimate in
                estimate.id == serviceCall.linkedEstimateID || estimate.serviceCallID == serviceCall.id
            }
            let invoicePayments = payments.filter { $0.invoice.id == invoice.id }
            let report = try generateAndPersistOnsiteReportAttachment(
                for: serviceCall,
                estimate: linkedEstimate,
                invoice: invoice,
                payments: invoicePayments,
                attachments: reportEvidenceAttachments(for: serviceCall),
                equipmentProfiles: equipmentProfiles,
                serviceCalls: serviceCalls
            )
            report.attachment.linkToInvoiceIfNeeded(invoice)
            serviceCall.markDocumentationCompleteIfReady()
            try? modelContext.save()
            syncAttachmentIfPossible(report.attachment, data: report.data)
            syncLinkedInvoiceAttachmentsToQuickBooks(invoice)
            return true
        } catch {
            actionMessage = "Could not prepare the onsite report before sending this invoice: \(error.localizedDescription)"
            return false
        }
    }

    private func generateAndPersistOnsiteReportAttachment(
        for serviceCall: ServiceCall,
        estimate: Estimate?,
        invoice: Invoice?,
        payments: [Payment],
        attachments jobAttachments: [ServiceDocumentAttachment],
        equipmentProfiles: [CustomerEquipment],
        serviceCalls: [ServiceCall]
    ) throws -> (attachment: ServiceDocumentAttachment, data: Data) {
        let url = try CustomerDocumentExporter.exportOnsiteReport(
            serviceCall: serviceCall,
            estimate: estimate,
            invoice: invoice,
            payments: payments,
            attachments: jobAttachments,
            equipmentProfiles: equipmentProfiles,
            serviceCalls: serviceCalls,
            fieldFormTemplates: fieldFormTemplates,
            fieldFormResponses: fieldFormResponses.filter { $0.serviceCallID == serviceCall.id },
            timeEntries: timeEntries,
            materialReadiness: JobMaterialCloseoutPolicy.summary(
                for: serviceCall,
                invoice: invoice,
                estimates: estimates,
                projectMilestones: projectMilestones,
                items: items,
                movements: inventoryMovements
            ),
            serviceCallActivities: serviceCallActivities,
            requireWorkPerformedLog: requireWorkPerformedLogForCloseout,
            includeFinancials: canViewFinancials || canCollectFieldPayments
        )
        let data = try Data(contentsOf: url)
        let invoiceID = invoice?.id ?? serviceCall.linkedInvoiceID
        let estimateID = estimate?.id ?? serviceCall.linkedEstimateID
        let caption = CustomerDocumentExporter.onsiteReportAttachmentCaption(
            serviceCall: serviceCall,
            estimate: estimate,
            invoice: invoice,
            includeFinancials: canViewFinancials || canCollectFieldPayments
        )

        let attachment: ServiceDocumentAttachment
        if let reusable = ServiceDocumentAttachment.reusableGeneratedServiceReport(
            in: attachments,
            serviceCallID: serviceCall.id,
            invoiceID: invoiceID,
            estimateID: estimateID
        ) {
            reusable.replaceGeneratedFile(
                displayName: url.lastPathComponent,
                localFilePath: url.path,
                contentType: "application/pdf",
                fileSizeBytes: data.count,
                caption: caption
            )
            reusable.refreshGeneratedDocumentContext(
                customer: serviceCall.customer,
                serviceCallID: serviceCall.id,
                customerEquipmentID: serviceCall.customerEquipmentID,
                invoiceID: invoiceID,
                estimateID: estimateID
            )
            attachment = reusable
        } else {
            let generated = ServiceDocumentAttachment(
                customer: serviceCall.customer,
                serviceCallID: serviceCall.id,
                customerEquipmentID: serviceCall.customerEquipmentID,
                invoiceID: invoiceID,
                estimateID: estimateID,
                kind: .serviceReport,
                displayName: url.lastPathComponent,
                caption: caption,
                localFilePath: url.path,
                contentType: "application/pdf",
                fileSizeBytes: data.count
            )
            modelContext.insert(generated)
            attachment = generated
        }

        serviceCall.markDocumentationCompleteIfReady()
        try? modelContext.save()
        return (attachment, data)
    }

    @discardableResult
    private func prepareInvoicePDFForQuickBooksSend(_ invoice: Invoice, serviceCall: ServiceCall?) -> Bool {
        do {
            let invoicePayments = payments.filter { $0.invoice.id == invoice.id }
            let url = try CustomerDocumentExporter.exportInvoice(
                invoice,
                serviceCall: serviceCall,
                payments: invoicePayments,
                attachments: attachments,
                equipmentProfiles: equipmentProfiles,
                serviceCalls: serviceCalls
            )
            generatedCustomerDocumentURL = url
            generatedCustomerDocumentRecipientID = invoice.customer.id
            generatedCustomerDocumentServiceCallID = serviceCall?.id
            generatedCustomerDocumentInvoiceID = invoice.id
            generatedCustomerDocumentEstimateID = linkedEstimate(for: serviceCall)?.id
            let documentLabel = CustomerDocumentExporter.invoiceDocumentLabel(for: invoice, payments: invoicePayments)
            generatedCustomerDocumentKind = documentLabel.lowercased()
            guard persistGeneratedBillingDocument(
                url,
                customer: invoice.customer,
                serviceCallID: serviceCall?.id,
                invoiceID: invoice.id,
                estimateID: nil,
                kind: .invoiceSupport,
                caption: CustomerDocumentExporter.invoiceDocumentCaption(for: invoice, payments: invoicePayments),
                successMessage: "\(documentLabel) PDF prepared for QuickBooks send."
            ) != nil else {
                return false
            }
            return true
        } catch {
            actionMessage = "Could not prepare the invoice PDF before sending: \(error.localizedDescription)"
            return false
        }
    }

    private func syncAttachmentToQuickBooksIfPossible(_ attachment: ServiceDocumentAttachment) {
        guard attachment.quickBooksAttachableID == nil,
              QuickBooksDataAPI.shared.isAuthenticated else {
            return
        }

        let references = QuickBooksInvoiceAttachmentSync.quickBooksAttachableReferences(
            for: attachment,
            estimates: estimates,
            invoices: invoices
        )
        guard !references.isEmpty else { return }

        QuickBooksDataAPI.shared.uploadDocument(
            fileURL: attachment.localFileURL,
            note: attachment.caption,
            attachableReferences: references
        ) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let attachableID):
                    attachment.quickBooksAttachableID = attachableID
                    attachment.quickBooksSyncError = nil
                    try? modelContext.save()
                case .failure(let error):
                    attachment.quickBooksSyncError = error.localizedDescription
                    try? modelContext.save()
                }
            }
        }
    }

    private func contentType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mimeType = type.preferredMIMEType {
            return mimeType
        }
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "pdf": return "application/pdf"
        default: return "application/octet-stream"
        }
    }

    private func nilIfBlank(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func loadPendingIntentServiceCallIfNeeded() {
        guard initialServiceCall == nil, pendingIntentServiceCallID == nil else { return }
        pendingIntentServiceCallID = GunnAireAppIntentRouter.consumePendingServiceCallID()
        if let call = activeServiceCall {
            selectedDocumentKind = call.type == .estimate ? .estimate : .invoice
        }
    }

    private func addItem() {
        guard let price = CatalogItemAmountParser.parseRequiredOrZero(newItemPrice) else { return }
        let cost = CatalogItemAmountParser.parseOptional(newItemCost)
        let preferredVendorName = nonBlank(newItemPreferredVendor)
        let preferredVendorQuickBooksID = CatalogVendorSelection.quickBooksID(
            vendorName: preferredVendorName,
            vendors: vendors
        )
        let item = Item(
            quickBooksSyncStatus: canApprovePricebookItems ? nil : "needs_review",
            quickBooksSyncDetail: canApprovePricebookItems ? nil : "Administrator pricebook review is required before QuickBooks publication.",
            pricebookReviewStatus: canApprovePricebookItems ? .approved : .needsReview,
            pricebookCreatedByEmail: currentUserEmail,
            name: newItemName.trimmingCharacters(in: .whitespacesAndNewlines),
            itemType: newItemType,
            unitPrice: price,
            purchaseCost: cost,
            isTaxable: newItemTaxable,
            itemDescription: nonBlank(newItemDescription),
            sku: nonBlank(newItemSKU),
            preferredVendorName: preferredVendorName,
            preferredVendorQuickBooksID: preferredVendorQuickBooksID,
            vendorPartNumber: nonBlank(newItemVendorPartNumber),
            purchaseURL: nonBlank(newItemPurchaseURL),
            purchaseDescription: nonBlank(newItemPurchaseDescription)
        )
        modelContext.insert(item)
        do {
            try modelContext.save()
            selectCreatedItem(item)
            actionMessage = item.requiresPricebookReview
                ? "Added \(item.name) to this \(selectedDocumentKind.rawValue.lowercased()). Admin must review it before QuickBooks publication."
                : (isQuickBooksConnected
                    ? "Added \(item.name). Publishing it to QuickBooks..."
                    : "Added \(item.name) to this \(selectedDocumentKind.rawValue.lowercased()). It will publish to QuickBooks when a company connection is available.")
            publishCatalogItemIfPossible(item)
        } catch {
            actionMessage = "Could not save \(item.name): \(error.localizedDescription)"
        }
        itemSearchText = ""
        newItemName = ""
        newItemType = .service
        newItemSKU = ""
        newItemDescription = ""
        newItemPrice = ""
        newItemCost = ""
        newItemPreferredVendor = ""
        newItemVendorPartNumber = ""
        newItemPurchaseURL = ""
        newItemPurchaseDescription = ""
        newItemTaxable = false
    }

    private func selectCreatedItem(_ item: Item) {
        newlyCreatedLineItems[item.id] = item
        if item.requiresPricebookReview {
            documentScopedReviewItemIDs.insert(item.id)
        }
        selectedItems.insert(item.id)
        selectedItemQuantities[item.id] = selectedItemQuantities[item.id] ?? 1
        catalogFilter = .selected
    }

    private var itemCreatorInitialName: String {
        nonBlank(newItemName) ?? nonBlank(itemSearchText) ?? ""
    }

    private func handleCreatedItem(_ item: Item) {
        selectCreatedItem(item)
        itemSearchText = ""
        newItemName = ""
        actionMessage = item.requiresPricebookReview
            ? "Added \(item.name) to this \(selectedDocumentKind.rawValue.lowercased()). Admin must review it before QuickBooks publication."
            : (isQuickBooksConnected
                ? "Added \(item.name). Publishing it to QuickBooks..."
                : "Added \(item.name) to this \(selectedDocumentKind.rawValue.lowercased()). It will publish to QuickBooks when a company connection is available.")
        publishCatalogItemIfPossible(item)
    }

    private func nonBlank(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func importQuickBooksItems() {
        guard canApprovePricebookItems, isQuickBooksConnected else { return }
        isImportingQuickBooksItems = true
        actionMessage = "Loading QuickBooks catalog..."
        liveAPI.fetchItems { result in
            DispatchQueue.main.async {
                isImportingQuickBooksItems = false
                switch result {
                case .failure(let error):
                    actionMessage = "QuickBooks catalog sync failed: \(error.localizedDescription)"
                case .success(let quickBooksItems):
                    var imported = 0
                    for quickBooksItem in quickBooksItems {
                        let normalizedID = quickBooksItem.Id.trimmingCharacters(in: .whitespacesAndNewlines)
                        let linkedLocalItems = QuickBooksCatalogMappingIntegrity.linkedItems(
                            to: normalizedID,
                            in: items
                        )
                        if linkedLocalItems.count > 1 {
                            QuickBooksCatalogMappingIntegrity.markConflictsForReview(in: items)
                            continue
                        }
                        if let existing = Item.matchingLocalCatalogItem(
                            in: items,
                            quickBooksID: normalizedID,
                            name: quickBooksItem.Name,
                            sku: quickBooksItem.Sku
                        ) {
                            applyQuickBooksItem(quickBooksItem, to: existing)
                            continue
                        }

                        let localItem = Item(
                            quickBooksID: normalizedID,
                            name: quickBooksItem.Name,
                            itemType: CatalogItemType(rawValue: quickBooksItem.ItemType ?? "") ?? .service,
                            unitPrice: quickBooksItem.UnitPrice ?? 0,
                            purchaseCost: quickBooksItem.PurchaseCost,
                            isTaxable: quickBooksItem.Taxable ?? false,
                            itemDescription: quickBooksItem.Description,
                            sku: quickBooksItem.Sku,
                            preferredVendorName: quickBooksItem.PrefVendorRef?.name,
                            preferredVendorQuickBooksID: quickBooksItem.PrefVendorRef?.value,
                            purchaseDescription: quickBooksItem.PurchaseDesc
                        )
                        modelContext.insert(localItem)
                        imported += 1
                    }
                    saveQuickBooksSyncState()
                    actionMessage = imported == 0
                        ? "QuickBooks catalog is already up to date."
                        : "Imported \(imported) catalog items from QuickBooks."
                }
            }
        }
    }

    private func importQuickBooksItemsIfNeeded() {
        guard !didAttemptInitialCatalogImport else { return }
        didAttemptInitialCatalogImport = true
        guard canApprovePricebookItems, isQuickBooksConnected, items.isEmpty else { return }
        importQuickBooksItems()
    }

    private func publishCatalogItemIfPossible(_ item: Item) {
        guard !item.requiresPricebookReview, !item.isCatalogArchived else { return }
        guard isQuickBooksConnected, itemNeedsQuickBooksSync(item) else { return }
        prepareQuickBooksItemsForDocument([item]) { result in
            switch result {
            case .success:
                actionMessage = "Added \(item.name) and synced it to QuickBooks."
            case .failure(let error):
                actionMessage = "Added \(item.name) locally. QuickBooks publish is pending: \(error.localizedDescription)"
            }
        }
    }

    private func applyQuickBooksItem(_ quickBooksItem: QuickBooksItem, to item: Item) {
        guard !item.requiresPricebookReview else { return }
        QuickBooksCatalogSnapshotApplication.apply(quickBooksItem, to: item)
    }

    private func saveQuickBooksSyncState() {
        do {
            try modelContext.save()
        } catch {
            actionMessage = "QuickBooks sync saved remotely, but the app could not save the updated local IDs: \(error.localizedDescription)"
        }
    }

    private func markQuickBooksCatalogSyncFailure(for items: [Item], error: Error) {
        let detail = error.localizedDescription
        for item in items where itemNeedsQuickBooksSync(item) {
            item.quickBooksSyncStatus = "needs_attention"
            item.quickBooksSyncDetail = detail
        }
        saveQuickBooksSyncState()
    }

    private func loadEstimateIntoBuilder(_ estimate: Estimate, announce: Bool = true) {
        changeOrderParentEstimateID = nil
        changeOrderReason = ""
        proposalGroupID = estimate.proposalGroupID
        proposalOption = estimate.proposalOptionKind ?? .standalone
        proposalIsRecommended = estimate.proposalIsRecommended
        selectedServiceLocationID = estimate.serviceLocationID
        applyDocumentContext(
            customer: estimate.customer,
            notes: estimate.notes,
            lineItemSummary: estimate.lineItemSummary,
            catalogSnapshotJSON: estimate.catalogSnapshotJSON,
            preferredKind: .estimate,
            announce: announce
        )
        loadedSiteAddressSnapshot = estimate.siteAddress
        loadedSiteAddressCustomerID = estimate.customer.id
    }

    private func beginChangeOrder(from estimate: Estimate) {
        changeOrderParentEstimateID = estimate.id
        changeOrderReason = "Scope revised after field diagnosis."
        proposalGroupID = nil
        proposalOption = .standalone
        proposalIsRecommended = false
        selectedServiceLocationID = estimate.serviceLocationID
        applyDocumentContext(
            customer: estimate.customer,
            notes: estimate.notes,
            lineItemSummary: estimate.lineItemSummary,
            catalogSnapshotJSON: estimate.catalogSnapshotJSON,
            preferredKind: .estimate,
            announce: false
        )
        loadedSiteAddressSnapshot = estimate.siteAddress
        loadedSiteAddressCustomerID = estimate.customer.id
        actionMessage = "Change order started. Update the line items, explain the scope change, then send this revised proposal for a new approval."
    }

    private func endProposalSet() {
        proposalGroupID = nil
        proposalOption = .standalone
        proposalIsRecommended = false
        actionMessage = "Proposal set ended. New estimates will be standalone."
    }

    private func selectProposalOption(_ estimate: Estimate) {
        guard let call = activeServiceCall else { return }
        if let issue = EstimateProposalPolicy.selectionIssue(for: estimate, in: estimates) {
            actionMessage = issue
            return
        }
        guard EstimateProposalPolicy.select(estimate, in: estimates) else {
            actionMessage = "This proposal option cannot be selected until its approval conflict is resolved."
            return
        }
        call.linkedEstimateID = estimate.id
        call.followUpRequired = false
        call.followUpAction = nil
        call.followUpDueDate = nil
        actionMessage = "\(estimate.proposalOptionDisplayName) selected. Record customer approval when they choose this option."
    }

    private func recordCustomerApproval(_ evidence: EstimateApprovalEvidence, for estimate: Estimate) -> Bool {
        guard EstimateProposalPolicy.recordApproval(
            for: estimate,
            in: estimates,
            customerName: evidence.customerName,
            method: evidence.method,
            reference: evidence.reference,
            signatureImageBase64: evidence.signatureImageBase64,
            recordedByEmail: currentUserEmail
        ) else {
            actionMessage = EstimateProposalPolicy.selectionIssue(for: estimate, in: estimates)
                ?? "Approval evidence could not be applied to this proposal option."
            return false
        }
        activeServiceCall?.linkedEstimateID = estimate.id
        activeServiceCall?.followUpRequired = false
        activeServiceCall?.followUpAction = nil
        activeServiceCall?.followUpDueDate = nil
        if let call = activeServiceCall {
            ServiceCallActivity.record(
                for: call,
                action: estimate.isChangeOrder ? "Change order approved" : "Estimate approved",
                detail: "Customer approval recorded by \(evidence.method.displayName.lowercased()) for \(estimate.amount.formatted(.currency(code: "USD"))).",
                actorEmail: currentUserEmail,
                in: modelContext
            )
        }
        actionMessage = "Customer approval evidence recorded."
        return true
    }

    private func prepareInvoiceFromEstimate(_ estimate: Estimate) {
        selectedServiceLocationID = estimate.serviceLocationID
        applyDocumentContext(
            customer: estimate.customer,
            notes: estimate.notes,
            lineItemSummary: estimate.lineItemSummary,
            catalogSnapshotJSON: estimate.catalogSnapshotJSON,
            preferredKind: .invoice,
            announce: false
        )
        loadedSiteAddressSnapshot = estimate.siteAddress
        loadedSiteAddressCustomerID = estimate.customer.id
        actionMessage = "Estimate loaded into the invoice builder for this job."
    }

    private func createInvoiceFromEstimate(_ estimate: Estimate) {
        guard isCurrentProposal(estimate) else {
            actionMessage = "A newer change order is the active proposal. Invoice the approved current proposal instead."
            return
        }
        if let issue = EstimateProposalPolicy.selectionIssue(for: estimate, in: estimates) {
            actionMessage = issue
            return
        }
        guard currentProjectMilestones.isEmpty else {
            actionMessage = "This job uses milestone billing. Create or review the next progress invoice in Project Billing."
            return
        }
        guard !estimate.isProposalOption || estimate.hasRecordedCustomerApproval else {
            actionMessage = "Record the customer's approval for the selected proposal option before creating an invoice."
            return
        }
        if let existingInvoice = invoice(for: estimate) {
            selectedInvoiceForCloseout = existingInvoice
            actionMessage = "Opened the existing invoice for this estimate."
            return
        }
        if let linkedCall = serviceCall(for: estimate),
           !linkedCall.canCreateInvoiceDocument {
            actionMessage = linkedCall.invoiceCreationBlockedMessage ?? "Complete required field documentation before creating an invoice."
            return
        }

        let conversion = convertEstimate(estimate)
        let invoice = conversion.invoice
        selectedInvoiceForCloseout = invoice
        let restoredItems = restoredCatalogItems(snapshotJSON: estimate.catalogSnapshotJSON, lineItemSummary: estimate.lineItemSummary)
        if let reportErrorMessage = conversion.reportErrorMessage {
            actionMessage = reportErrorMessage
            if isQuickBooksConnected, !restoredItems.isEmpty {
                syncInvoiceIfNeeded(invoice, customer: estimate.customer, items: restoredItems)
            }
        } else if isQuickBooksConnected, !restoredItems.isEmpty {
            actionMessage = "Invoice created from estimate. Syncing to QuickBooks..."
            syncInvoiceIfNeeded(invoice, customer: estimate.customer, items: restoredItems)
        } else if isQuickBooksConnected {
            actionMessage = "Invoice created from estimate. QuickBooks sync skipped because the estimate lines do not match local catalog items."
        } else {
            actionMessage = "Invoice created from estimate."
        }
    }

    private func loadInvoiceIntoBuilder(_ invoice: Invoice, announce: Bool = true) {
        selectedServiceLocationID = invoice.serviceLocationID
        selectedInvoicePaymentTerms = invoice.paymentTerms()
        invoiceCustomDueDate = invoice.effectiveDueDate()
        applyDocumentContext(
            customer: invoice.customer,
            notes: invoice.notes,
            lineItemSummary: invoice.lineItemSummary,
            catalogSnapshotJSON: invoice.catalogSnapshotJSON,
            preferredKind: .invoice,
            announce: announce
        )
        loadedSiteAddressSnapshot = invoice.siteAddress
        loadedSiteAddressCustomerID = invoice.customer.id
    }

    private func applyDocumentContext(
        customer: Customer,
        notes: String?,
        lineItemSummary: String,
        catalogSnapshotJSON: String?,
        preferredKind: BillingDocumentKind,
        announce: Bool
    ) {
        selectedDocumentKind = preferredKind
        selectedCustomerID = customer.id
        populateCustomerFields(from: customer)
        if customerAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let address = selectedJobAddress {
            customerAddress = address
        }
        self.notes = notes ?? ""

        let restoredItems = restoredCatalogItems(snapshotJSON: catalogSnapshotJSON, lineItemSummary: lineItemSummary)
        let snapshots = CatalogLineItemSnapshot.decoded(from: catalogSnapshotJSON)
        newlyCreatedLineItems.removeAll()
        if restoredItems.isEmpty {
            clearSelectedCatalogLines()
        } else {
            selectedItems = Set(restoredItems.map(\.id))
            documentScopedReviewItemIDs = Set(
                restoredItems.filter(\.requiresPricebookReview).map(\.id)
            )
            selectedDocumentDiscount = CatalogLineItemSnapshot.documentDiscount(from: catalogSnapshotJSON)
            selectedItemQuantities = Dictionary(
                uniqueKeysWithValues: snapshots.map { ($0.catalogItemID, $0.quantity) }
            )
            selectedItemPriceAdjustments = Dictionary(
                uniqueKeysWithValues: snapshots.compactMap { snapshot in
                    snapshot.authorizedPriceAdjustment.map { (snapshot.catalogItemID, $0) }
                }
            )
            selectedItemEquipmentIDs = CatalogLineEquipmentAssignmentPolicy.restoredAssignments(
                from: snapshots,
                available: documentEquipmentSnapshots
            )
            selectedItemAssemblySnapshots = Dictionary(
                uniqueKeysWithValues: snapshots.compactMap { snapshot in
                    snapshot.assembly.map { (snapshot.catalogItemID, $0) }
                }
            )
            selectedItemizedAssemblyMemberships = CatalogAssemblyPolicy.restoredItemizedMemberships(
                from: snapshots
            )
            reconcileLineEquipmentAssignments()
        }

        if announce {
            actionMessage = "Loaded the saved \(preferredKind.rawValue.lowercased()) back into the builder."
        }
    }

    private func generateOnsiteReport(for serviceCall: ServiceCall) {
        do {
            saveCurrentEquipmentProfile(for: serviceCall, announce: false)
            let url = try CustomerDocumentExporter.exportOnsiteReport(
                serviceCall: serviceCall,
                estimate: currentJobEstimate,
                invoice: currentJobInvoice,
                payments: currentJobPayments,
                attachments: activeJobReportEvidenceAttachments,
                equipmentProfiles: equipmentProfiles,
                serviceCalls: serviceCalls,
                fieldFormTemplates: fieldFormTemplates,
                fieldFormResponses: fieldFormResponses.filter { $0.serviceCallID == serviceCall.id },
                timeEntries: timeEntries,
                materialReadiness: JobMaterialCloseoutPolicy.summary(
                    for: serviceCall,
                    invoice: currentJobInvoice,
                    estimates: estimates,
                    projectMilestones: projectMilestones,
                    items: items,
                    movements: inventoryMovements
                ),
                serviceCallActivities: serviceCallActivities,
                requireWorkPerformedLog: requireWorkPerformedLogForCloseout,
                includeFinancials: canViewFinancials || canCollectFieldPayments
            )
            generatedCustomerDocumentURL = url
            generatedCustomerDocumentRecipientID = serviceCall.customer.id
            generatedCustomerDocumentServiceCallID = serviceCall.id
            generatedCustomerDocumentInvoiceID = currentJobInvoice?.id ?? serviceCall.linkedInvoiceID
            generatedCustomerDocumentEstimateID = currentJobEstimate?.id ?? serviceCall.linkedEstimateID
            generatedCustomerDocumentKind = "\(serviceCall.type.displayName.lowercased()) report"
            if !serviceCall.markDocumentationCompleteIfReady() {
                serviceCall.documentationChecklist = false
            }
            persistGeneratedOnsiteReport(url, for: serviceCall)
        } catch {
            actionMessage = "Could not generate onsite report: \(error.localizedDescription)"
        }
    }

    private func persistGeneratedOnsiteReport(_ url: URL, for serviceCall: ServiceCall) {
        do {
            let data = try Data(contentsOf: url)
            let invoice = currentJobInvoice
            let estimate = currentJobEstimate
            let invoiceID = invoice?.id ?? serviceCall.linkedInvoiceID
            let estimateID = estimate?.id ?? serviceCall.linkedEstimateID
            let caption = CustomerDocumentExporter.onsiteReportAttachmentCaption(
                serviceCall: serviceCall,
                estimate: estimate,
                invoice: invoice,
                includeFinancials: canViewFinancials || canCollectFieldPayments
            )
            let attachment: ServiceDocumentAttachment
            if let reusable = ServiceDocumentAttachment.reusableGeneratedServiceReport(
                in: attachments,
                serviceCallID: serviceCall.id,
                invoiceID: invoiceID,
                estimateID: estimateID
            ) {
                reusable.replaceGeneratedFile(
                    displayName: url.lastPathComponent,
                    localFilePath: url.path,
                    contentType: "application/pdf",
                    fileSizeBytes: data.count,
                    caption: caption
                )
                reusable.refreshGeneratedDocumentContext(
                    customer: serviceCall.customer,
                    serviceCallID: serviceCall.id,
                    customerEquipmentID: serviceCall.customerEquipmentID,
                    invoiceID: invoiceID,
                    estimateID: estimateID
                )
                attachment = reusable
            } else {
                let generated = ServiceDocumentAttachment(
                    customer: serviceCall.customer,
                    serviceCallID: serviceCall.id,
                    customerEquipmentID: serviceCall.customerEquipmentID,
                    invoiceID: invoiceID,
                    estimateID: estimateID,
                    kind: .serviceReport,
                    displayName: url.lastPathComponent,
                    caption: caption,
                    localFilePath: url.path,
                    contentType: "application/pdf",
                    fileSizeBytes: data.count
                )
                modelContext.insert(generated)
                attachment = generated
            }
            if attachment.invoiceID == nil {
                attachment.invoiceID = invoiceID
            }
            if attachment.estimateID == nil {
                attachment.estimateID = estimateID
            }
            try? modelContext.save()
            syncAttachmentIfPossible(attachment, data: data)
            let completionNote = serviceCall.documentationCompletionBlockedMessage.map { " \($0)" } ?? ""
            if invoice?.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                actionMessage = "Onsite report generated and queued for QuickBooks invoice attachment.\(completionNote)"
            } else {
                actionMessage = "Onsite report generated and saved to this job.\(completionNote)"
            }
        } catch {
            actionMessage = "Onsite report generated, but could not save it as a job attachment: \(error.localizedDescription)"
        }
    }

    private func generateEstimateDocument(_ estimate: Estimate) {
        do {
            let serviceCall = serviceCall(for: estimate)
            if let serviceCall {
                saveCurrentEquipmentProfile(for: serviceCall, announce: false)
            }
            let url = try CustomerDocumentExporter.exportEstimate(
                estimate,
                serviceCall: serviceCall,
                attachments: attachments,
                equipmentProfiles: equipmentProfiles,
                serviceCalls: serviceCalls
            )
            generatedCustomerDocumentURL = url
            generatedCustomerDocumentRecipientID = estimate.customer.id
            generatedCustomerDocumentServiceCallID = serviceCall?.id
            generatedCustomerDocumentInvoiceID = nil
            generatedCustomerDocumentEstimateID = estimate.id
            generatedCustomerDocumentKind = "estimate"
            persistGeneratedBillingDocument(
                url,
                customer: estimate.customer,
                serviceCallID: serviceCall?.id,
                invoiceID: nil,
                estimateID: estimate.id,
                kind: .estimateSupport,
                caption: "Generated estimate PDF",
                successMessage: "Estimate PDF generated and saved to this customer."
            )
        } catch {
            actionMessage = "Could not generate estimate PDF: \(error.localizedDescription)"
        }
    }

    private func generateInvoiceDocument(_ invoice: Invoice) {
        do {
            let invoicePayments = payments.filter { $0.invoice.id == invoice.id }
            let serviceCall = serviceCall(for: invoice)
            if let serviceCall {
                saveCurrentEquipmentProfile(for: serviceCall, announce: false)
            }
            let url = try CustomerDocumentExporter.exportInvoice(
                invoice,
                serviceCall: serviceCall,
                payments: invoicePayments,
                attachments: attachments,
                equipmentProfiles: equipmentProfiles,
                serviceCalls: serviceCalls
            )
            generatedCustomerDocumentURL = url
            generatedCustomerDocumentRecipientID = invoice.customer.id
            generatedCustomerDocumentServiceCallID = serviceCall?.id
            generatedCustomerDocumentInvoiceID = invoice.id
            generatedCustomerDocumentEstimateID = linkedEstimate(for: serviceCall)?.id
            let documentLabel = CustomerDocumentExporter.invoiceDocumentLabel(for: invoice, payments: invoicePayments).lowercased()
            generatedCustomerDocumentKind = documentLabel
            persistGeneratedBillingDocument(
                url,
                customer: invoice.customer,
                serviceCallID: serviceCall?.id,
                invoiceID: invoice.id,
                estimateID: nil,
                kind: .invoiceSupport,
                caption: CustomerDocumentExporter.invoiceDocumentCaption(for: invoice, payments: invoicePayments),
                successMessage: "\(CustomerDocumentExporter.invoiceDocumentLabel(for: invoice, payments: invoicePayments)) PDF generated and saved to this customer."
            )
        } catch {
            actionMessage = "Could not generate invoice PDF: \(error.localizedDescription)"
        }
    }

    @discardableResult
    private func persistGeneratedBillingDocument(
        _ url: URL,
        customer: Customer,
        serviceCallID: UUID?,
        invoiceID: UUID?,
        estimateID: UUID?,
        kind: ServiceDocumentAttachmentKind,
        caption: String,
        successMessage: String
    ) -> ServiceDocumentAttachment? {
        do {
            let data = try Data(contentsOf: url)
            let attachment: ServiceDocumentAttachment
            if let reusable = ServiceDocumentAttachment.reusableGeneratedBillingDocument(
                in: attachments,
                kind: kind,
                serviceCallID: serviceCallID,
                invoiceID: invoiceID,
                estimateID: estimateID
            ) {
                reusable.replaceGeneratedFile(
                    displayName: url.lastPathComponent,
                    localFilePath: url.path,
                    contentType: "application/pdf",
                    fileSizeBytes: data.count,
                    caption: caption
                )
                let equipmentID = serviceCallID.flatMap { id in serviceCalls.first { $0.id == id }?.customerEquipmentID }
                reusable.refreshGeneratedDocumentContext(
                    customer: customer,
                    serviceCallID: serviceCallID,
                    customerEquipmentID: equipmentID,
                    invoiceID: invoiceID,
                    estimateID: estimateID
                )
                attachment = reusable
            } else {
                let generated = ServiceDocumentAttachment(
                    customer: customer,
                    serviceCallID: serviceCallID,
                    customerEquipmentID: serviceCallID.flatMap { id in serviceCalls.first { $0.id == id }?.customerEquipmentID },
                    invoiceID: invoiceID,
                    estimateID: estimateID,
                    kind: kind,
                    displayName: url.lastPathComponent,
                    caption: caption,
                    localFilePath: url.path,
                    contentType: "application/pdf",
                    fileSizeBytes: data.count
                )
                modelContext.insert(generated)
                attachment = generated
            }
            try? modelContext.save()
            syncAttachmentIfPossible(attachment, data: data)
            actionMessage = successMessage
            return attachment
        } catch {
            actionMessage = "\(successMessage) Company document history was not updated: \(error.localizedDescription)"
            return nil
        }
    }

    private func sendEstimateThroughQuickBooks(_ estimate: Estimate) {
        guard QuickBooksDataAPI.shared.isAuthenticated else {
            actionMessage = "Connect QuickBooks before sending the estimate."
            return
        }
        guard let quickBooksID = estimate.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !quickBooksID.isEmpty else {
            actionMessage = "Create or sync this estimate to QuickBooks before sending it."
            return
        }
        guard prepareEstimateDocumentationForQuickBooksSend(estimate) else {
            return
        }
        let trimmedEmail = estimate.customer.email?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let email = trimmedEmail.flatMap { $0.isEmpty ? nil : $0 }
        actionMessage = "Prepared estimate PDF and attachments. Sending estimate through QuickBooks..."
        QuickBooksDataAPI.shared.sendEstimate(id: quickBooksID, to: email) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    if estimate.status.caseInsensitiveCompare("accepted") != .orderedSame &&
                        estimate.status.caseInsensitiveCompare("rejected") != .orderedSame {
                        estimate.status = "sent"
                    }
                    try? modelContext.save()
                    if let email {
                        actionMessage = "Estimate sent through QuickBooks to \(email)."
                    } else {
                        actionMessage = "Estimate sent through QuickBooks."
                    }
                case .failure(let error):
                    actionMessage = "QuickBooks estimate send failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func sendInvoiceThroughQuickBooks(_ invoice: Invoice) {
        guard QuickBooksDataAPI.shared.isAuthenticated else {
            actionMessage = "Connect QuickBooks before sending the invoice."
            return
        }
        guard let quickBooksID = invoice.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !quickBooksID.isEmpty else {
            actionMessage = "Create or sync this invoice to QuickBooks before sending it."
            return
        }
        guard prepareInvoiceDocumentationForQuickBooksSend(invoice) else {
            return
        }
        let trimmedEmail = invoice.customer.email?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let email = trimmedEmail.flatMap { $0.isEmpty ? nil : $0 }
        actionMessage = "Prepared service report and invoice attachments. Sending invoice through QuickBooks..."
        QuickBooksDataAPI.shared.sendInvoice(id: quickBooksID, to: email) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    if !isInvoicePaid(invoice) &&
                        invoice.status.caseInsensitiveCompare("partial") != .orderedSame {
                        invoice.status = "sent"
                    }
                    try? modelContext.save()
                    if let email {
                        actionMessage = "Invoice sent through QuickBooks to \(email)."
                    } else {
                        actionMessage = "Invoice sent through QuickBooks."
                    }
                case .failure(let error):
                    actionMessage = "QuickBooks invoice send failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func serviceCall(for estimate: Estimate) -> ServiceCall? {
        guard let serviceCallID = estimate.serviceCallID else { return nil }
        return serviceCalls.first(where: { $0.id == serviceCallID })
    }

    private func canCreateOrOpenInvoice(from estimate: Estimate) -> Bool {
        guard isCurrentProposal(estimate) else { return false }
        guard EstimateProposalPolicy.selectionIssue(for: estimate, in: estimates) == nil else { return false }
        guard currentProjectMilestones.isEmpty else { return false }
        if estimate.isProposalOption && !estimate.hasRecordedCustomerApproval {
            return false
        }
        if invoice(for: estimate) != nil {
            return true
        }
        return serviceCall(for: estimate)?.canCreateInvoiceDocument ?? true
    }

    private func invoiceCreationBlockedMessage(for estimate: Estimate) -> String? {
        guard isCurrentProposal(estimate) else {
            return "A newer change order is the active proposal. Invoice the approved current proposal instead."
        }
        if let issue = EstimateProposalPolicy.selectionIssue(for: estimate, in: estimates) {
            return issue
        }
        if !currentProjectMilestones.isEmpty {
            return "This job uses milestone billing. Issue each progress invoice from Project Billing."
        }
        if estimate.isProposalOption && !estimate.hasRecordedCustomerApproval {
            return "Record customer approval for the selected proposal option before invoicing."
        }
        guard invoice(for: estimate) == nil else { return nil }
        return serviceCall(for: estimate)?.invoiceCreationBlockedMessage
    }

    private func serviceCall(for invoice: Invoice) -> ServiceCall? {
        guard let serviceCallID = invoice.serviceCallID else { return nil }
        return serviceCalls.first(where: { $0.id == serviceCallID })
    }

    private func linkedEstimate(for serviceCall: ServiceCall?) -> Estimate? {
        guard let serviceCall else { return nil }
        if let linkedEstimateID = serviceCall.linkedEstimateID,
           let estimate = estimates.first(where: { $0.id == linkedEstimateID }) {
            return estimate
        }
        return estimates.first { $0.serviceCallID == serviceCall.id }
    }

    private func isCurrentProposal(_ estimate: Estimate) -> Bool {
        guard let serviceCallID = estimate.serviceCallID else { return true }
        guard let serviceCall = serviceCalls.first(where: { $0.id == serviceCallID }) else { return true }
        return serviceCall.linkedEstimateID == estimate.id
    }

    private func invoice(for estimate: Estimate) -> Invoice? {
        if let serviceCallID = estimate.serviceCallID,
           let linkedInvoiceID = serviceCalls.first(where: { $0.id == serviceCallID })?.linkedInvoiceID {
            return invoices.first(where: { $0.id == linkedInvoiceID })
        }
        return invoices.first { invoice in
            invoice.customer.id == estimate.customer.id &&
            invoice.lineItemSummary == estimate.lineItemSummary &&
            abs(invoice.amount - estimate.amount) < 0.01
        }
    }

    private func openDocumentation(for serviceCall: ServiceCall) {
        GunnAireAppIntentRouter.storeDocumentationRoute(serviceCall.id)
    }

    private func matchingItemIDs(from lineItemSummary: String) -> Set<UUID> {
        let itemNames = lineItemSummary
            .split(separator: "\n")
            .map { line in
                let value = String(line)
                if let range = value.range(of: " - ") {
                    return normalizedItemLookupKey(String(value[..<range.lowerBound]))
                }
                return normalizedItemLookupKey(value)
            }
            .filter { !$0.isEmpty }

        guard !itemNames.isEmpty else { return [] }

        let exactMatches = items.filter { itemNames.contains(normalizedItemLookupKey($0.name)) }
        if !exactMatches.isEmpty {
            return Set(exactMatches.map(\.id))
        }

        let containsMatches = items.filter { item in
            let normalizedName = normalizedItemLookupKey(item.name)
            return itemNames.contains { savedName in
                normalizedName.contains(savedName) || savedName.contains(normalizedName)
            }
        }
        return Set(containsMatches.map(\.id))
    }

    private func restoredCatalogItems(snapshotJSON: String?, lineItemSummary: String) -> [Item] {
        let snapshotIDs = Set(CatalogLineItemSnapshot.decoded(from: snapshotJSON).map(\.catalogItemID))
        if !snapshotIDs.isEmpty {
            return items.filter { snapshotIDs.contains($0.id) }
        }
        let summaryIDs = matchingItemIDs(from: lineItemSummary)
        return items.filter { summaryIDs.contains($0.id) }
    }

    private func invoiceBalanceDue(for invoice: Invoice) -> Double {
        Invoice.outstandingBalance(for: invoice, payments: payments)
    }

    private func isInvoicePaid(_ invoice: Invoice) -> Bool {
        Invoice.isPaid(invoice, payments: payments)
    }

    private func isInvoiceOverdue(_ invoice: Invoice) -> Bool {
        BillingInvoiceQueueBuilder.isOverdue(invoice, payments: payments)
    }

    private func invoiceDisplayStatus(for invoice: Invoice) -> String {
        if isInvoicePaid(invoice) { return "Paid" }
        if isInvoiceOverdue(invoice) { return "Overdue" }
        let balance = invoiceBalanceDue(for: invoice)
        if balance > 0.009 && balance < invoice.amount { return "Partial" }
        return "Open"
    }

    private func invoiceBalanceDueIgnoringStatus(for invoice: Invoice) -> Double {
        Invoice.outstandingBalance(for: invoice, payments: payments)
    }

    private func normalizedItemLookupKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func scheduleFollowUpVisit(for sourceCall: ServiceCall) {
        if let blocker = CustomerOperationalAlertPolicy.schedulingBlocker(
            customerID: sourceCall.customer.id,
            serviceLocationID: sourceCall.serviceLocationID,
            in: operationalAlerts
        ) {
            actionMessage = CustomerOperationalAlertPolicy.bookingRestrictionMessage(for: blocker)
            return
        }
        let followUpCall = sourceCall.makeFollowUpVisit()
        modelContext.insert(followUpCall)
        ServiceCallActivity.record(
            for: sourceCall,
            action: sourceCall.isCorrectiveWorkClassification ? "Corrective visit scheduled" : "Follow-up visit scheduled",
            detail: "Linked follow-up for \(followUpCall.scheduledDate.formatted(date: .abbreviated, time: .shortened)).",
            actorEmail: currentUserEmail,
            in: modelContext
        )
        ServiceCallActivity.record(
            for: followUpCall,
            action: "Created from prior job",
            detail: "Linked to source job \(String(sourceCall.id.uuidString.prefix(8)).uppercased()).",
            actorEmail: currentUserEmail,
            in: modelContext
        )
        actionMessage = "Scheduled follow-up visit for \(followUpCall.scheduledDate.formatted(date: .abbreviated, time: .shortened))."
    }

    private func scheduledApprovedWork(for estimate: Estimate) -> ServiceCall? {
        ApprovedEstimateScheduling.existingWorkOrder(for: estimate, in: serviceCalls)
    }

    private func presentApprovedWorkSchedule(for estimate: Estimate) {
        guard canScheduleApprovedWork else {
            actionMessage = "Only Dispatch or an administrator can create scheduled work from an approved estimate."
            return
        }
        if let issue = EstimateProposalPolicy.selectionIssue(for: estimate, in: estimates) {
            actionMessage = issue
            return
        }
        guard estimate.hasRecordedCustomerApproval else {
            actionMessage = "Record traceable customer approval before scheduling this estimate."
            return
        }
        if let existing = scheduledApprovedWork(for: estimate) {
            actionMessage = "This approved estimate already has scheduled work. Opening that work order instead."
            GunnAireAppIntentRouter.storeScheduleCallRoute(existing.id)
            return
        }
        let sourceCall = serviceCall(for: estimate)
        if let blocker = CustomerOperationalAlertPolicy.schedulingBlocker(
            customerID: estimate.customer.id,
            serviceLocationID: estimate.serviceLocationID ?? sourceCall?.serviceLocationID,
            in: operationalAlerts
        ) {
            actionMessage = CustomerOperationalAlertPolicy.bookingRestrictionMessage(for: blocker)
            return
        }
        selectedEstimateForScheduling = estimate
    }

    @discardableResult
    private func createApprovedWorkOrder(
        for estimate: Estimate,
        scheduledDate: Date,
        duration: TimeInterval,
        workType: ServiceCallType
    ) -> Bool {
        guard canScheduleApprovedWork else {
            actionMessage = "Only Dispatch or an administrator can create scheduled work from an approved estimate."
            return false
        }
        if let issue = EstimateProposalPolicy.selectionIssue(for: estimate, in: estimates) {
            actionMessage = issue
            return false
        }
        if let existing = scheduledApprovedWork(for: estimate) {
            actionMessage = "This approved estimate already has scheduled work. Opening that work order instead."
            GunnAireAppIntentRouter.storeScheduleCallRoute(existing.id)
            return true
        }

        let sourceCall = serviceCall(for: estimate)
        if let blocker = CustomerOperationalAlertPolicy.schedulingBlocker(
            customerID: estimate.customer.id,
            serviceLocationID: estimate.serviceLocationID ?? sourceCall?.serviceLocationID,
            in: operationalAlerts
        ) {
            actionMessage = CustomerOperationalAlertPolicy.bookingRestrictionMessage(for: blocker)
            return false
        }
        let priorServiceCallID = estimate.serviceCallID
        let priorScheduledServiceCallID = estimate.scheduledServiceCallID
        let priorFollowUp = sourceCall.map { ($0.followUpRequired, $0.followUpAction, $0.followUpDueDate) }
        do {
            let approvedWorkCall = try ApprovedEstimateScheduling.makeWorkOrder(
                for: estimate,
                sourceCall: sourceCall,
                scheduledDate: scheduledDate,
                duration: duration,
                workType: workType
            )
            modelContext.insert(approvedWorkCall)
            estimate.scheduledServiceCallID = approvedWorkCall.id
            if estimate.serviceCallID == nil {
                estimate.serviceCallID = approvedWorkCall.id
            }
            sourceCall?.followUpRequired = false
            sourceCall?.followUpAction = nil
            sourceCall?.followUpDueDate = nil
            ServiceCallActivity.record(
                for: approvedWorkCall,
                action: "Approved estimate scheduled",
                detail: "Created unassigned \(workType.displayName.lowercased()) work from approved estimate \(String(estimate.id.uuidString.prefix(8)).uppercased()) for \(estimate.amount.formatted(.currency(code: "USD"))).",
                actorEmail: currentUserEmail,
                in: modelContext
            )
            if let sourceCall, sourceCall.id != approvedWorkCall.id {
                ServiceCallActivity.record(
                    for: sourceCall,
                    action: "Approved work scheduled",
                    detail: "Created work order \(String(approvedWorkCall.id.uuidString.prefix(8)).uppercased()) for \(scheduledDate.formatted(date: .abbreviated, time: .shortened)).",
                    actorEmail: currentUserEmail,
                    in: modelContext
                )
            }
            try modelContext.save()
            selectedEstimateForScheduling = nil
            actionMessage = "Approved work scheduled for \(scheduledDate.formatted(date: .abbreviated, time: .shortened)). Assign the crew from the Schedule workspace."
            GunnAireAppIntentRouter.storeScheduleCallRoute(approvedWorkCall.id)
            return true
        } catch {
            estimate.serviceCallID = priorServiceCallID
            estimate.scheduledServiceCallID = priorScheduledServiceCallID
            if let sourceCall, let priorFollowUp {
                sourceCall.followUpRequired = priorFollowUp.0
                sourceCall.followUpAction = priorFollowUp.1
                sourceCall.followUpDueDate = priorFollowUp.2
            }
            modelContext.rollback()
            actionMessage = "Could not schedule approved work: \(error.localizedDescription)"
            return false
        }
    }

    private func matchesCatalogFilter(_ item: Item) -> Bool {
        switch catalogFilter {
        case .recommended:
            return recommendedItemMatch(item)
        case .service:
            return item.itemType == .service
        case .materials:
            return item.itemType == .nonInventory
        case .selected:
            return isCatalogItemSelected(item)
        case .all:
            return true
        }
    }

    private func recommendedItemMatch(_ item: Item) -> Bool {
        let haystack = "\(item.name) \(item.itemDescription ?? "")".lowercased()
        switch activeServiceCall?.type {
        case .service, .repair:
            return item.itemType == .service ||
                haystack.contains("repair") ||
                haystack.contains("diagnostic") ||
                haystack.contains("labor")
        case .estimate:
            return haystack.contains("estimate") ||
                haystack.contains("proposal") ||
                haystack.contains("system") ||
                item.itemType == .service
        case .replacement, .install:
            return item.itemType == .nonInventory ||
                haystack.contains("install") ||
                haystack.contains("equipment") ||
                haystack.contains("system")
        case .maintenance:
            return haystack.contains("maintenance") ||
                haystack.contains("tune") ||
                haystack.contains("clean") ||
                haystack.contains("filter") ||
                item.itemType == .service
        case .meeting, .reminder, .siteVisit, .other:
            return item.itemType == .service ||
                haystack.contains("labor") ||
                haystack.contains("trip") ||
                haystack.contains("consult")
        case nil:
            return true
        }
    }

    private func toggleItem(_ item: Item) {
        if isCatalogItemSelected(item) {
            if item.assemblyDefinition?.presentation == .itemized {
                removeAssembly(item.id)
            } else {
                removeCatalogLine(item.id)
            }
            return
        }

        guard CatalogItemSelectionPolicy.canAdd(
            item,
            documentScopedReviewItemIDs: documentScopedReviewItemIDs
        ) else {
            actionMessage = item.requiresPricebookReview
                ? "\(item.name) is awaiting administrator review and remains limited to the document where it was created."
                : "\(item.name) is archived from new work. Ask an administrator to restore and reconcile it before adding it."
            return
        }

        do {
            let selection = try CatalogAssemblyPolicy.selection(root: item, catalogItems: items)
            let incomingIDs = Set(selection.lineItems.map(\.id))
            let conflictingIDs = incomingIDs.intersection(selectedItems)
            guard conflictingIDs.isEmpty else {
                let conflictNames = items
                    .filter { conflictingIDs.contains($0.id) }
                    .map(\.name)
                    .sorted()
                    .joined(separator: ", ")
                actionMessage = "Remove the already selected package line\(conflictingIDs.count == 1 ? "" : "s") first: \(conflictNames)."
                return
            }

            for lineItem in selection.lineItems {
                selectedItems.insert(lineItem.id)
                selectedItemQuantities[lineItem.id] = selection.quantities[lineItem.id] ?? 1
                if let defaultDocumentEquipmentID {
                    selectedItemEquipmentIDs[lineItem.id] = defaultDocumentEquipmentID
                }
            }
            selectedItemAssemblySnapshots.merge(selection.assemblySnapshots) { _, incoming in incoming }
            selectedItemizedAssemblyMemberships.merge(selection.itemizedAssemblyMemberships) { _, incoming in incoming }

            if let definition = item.assemblyDefinition {
                actionMessage = definition.presentation == .flatRate
                    ? "Added \(item.name) as one flat-rate customer line with included materials retained for job costing."
                    : "Added \(item.name) as \(selection.lineItems.count) itemized customer lines."
            }
        } catch {
            actionMessage = error.localizedDescription
        }
    }

    private func isCatalogItemSelected(_ item: Item) -> Bool {
        if item.assemblyDefinition?.presentation == .itemized {
            return selectedItemizedAssemblyMemberships[item.id] != nil
        }
        return selectedItems.contains(item.id)
    }

    private func isItemizedAssemblyLine(_ item: Item) -> Bool {
        selectedItemAssemblySnapshots[item.id]?.presentation == .itemized
    }

    private func removeCatalogLine(_ itemID: UUID) {
        if let assembly = selectedItemAssemblySnapshots[itemID], assembly.presentation == .itemized {
            removeAssembly(assembly.assemblyItemID)
            return
        }
        selectedItems.remove(itemID)
        selectedItemQuantities.removeValue(forKey: itemID)
        selectedItemPriceAdjustments.removeValue(forKey: itemID)
        selectedItemEquipmentIDs.removeValue(forKey: itemID)
        selectedItemAssemblySnapshots.removeValue(forKey: itemID)
    }

    private func removeAssembly(_ assemblyItemID: UUID) {
        let memberIDs = selectedItemizedAssemblyMemberships[assemblyItemID] ?? Set(
            selectedItemAssemblySnapshots.compactMap { itemID, snapshot in
                snapshot.assemblyItemID == assemblyItemID ? itemID : nil
            }
        )
        for itemID in memberIDs {
            selectedItems.remove(itemID)
            selectedItemQuantities.removeValue(forKey: itemID)
            selectedItemPriceAdjustments.removeValue(forKey: itemID)
            selectedItemEquipmentIDs.removeValue(forKey: itemID)
            selectedItemAssemblySnapshots.removeValue(forKey: itemID)
        }
        selectedItemizedAssemblyMemberships.removeValue(forKey: assemblyItemID)
    }

    private func clearSelectedCatalogLines() {
        selectedItems.removeAll()
        newlyCreatedLineItems.removeAll()
        documentScopedReviewItemIDs.removeAll()
        selectedItemQuantities.removeAll()
        selectedItemPriceAdjustments.removeAll()
        selectedDocumentDiscount = nil
        selectedItemEquipmentIDs.removeAll()
        selectedItemAssemblySnapshots.removeAll()
        selectedItemizedAssemblyMemberships.removeAll()
    }

    @ViewBuilder
    private func lineEquipmentPicker(for item: Item) -> some View {
        if !documentEquipmentProfiles.isEmpty {
            Picker("Serviced System", selection: lineEquipmentSelectionBinding(for: item)) {
                Text("Not linked").tag(nil as UUID?)
                ForEach(documentEquipmentProfiles) { equipment in
                    Text(equipment.displayName).tag(equipment.id as UUID?)
                }
            }
            .pickerStyle(.menu)
            .font(.caption)
            .accessibilityIdentifier("LineEquipmentPicker-\(item.id.uuidString)")
            .accessibilityHint("Links this line to the customer system serviced and includes that context in QuickBooks.")
        }
    }

    private func lineEquipmentSelectionBinding(for item: Item) -> Binding<UUID?> {
        Binding(
            get: { selectedItemEquipmentIDs[item.id] },
            set: { equipmentID in
                guard let equipmentID,
                      documentEquipmentProfiles.contains(where: { $0.id == equipmentID }) else {
                    selectedItemEquipmentIDs.removeValue(forKey: item.id)
                    return
                }
                selectedItemEquipmentIDs[item.id] = equipmentID
            }
        )
    }

    private func reconcileLineEquipmentAssignments() {
        let availableIDs = Set(documentEquipmentProfiles.map(\.id))
        selectedItemEquipmentIDs = Dictionary(
            uniqueKeysWithValues: selectedItemEquipmentIDs.compactMap { itemID, equipmentID in
                guard selectedItems.contains(itemID), availableIDs.contains(equipmentID) else { return nil }
                return (itemID, equipmentID)
            }
        )
        guard let defaultDocumentEquipmentID else { return }
        for itemID in selectedItems where selectedItemEquipmentIDs[itemID] == nil {
            selectedItemEquipmentIDs[itemID] = defaultDocumentEquipmentID
        }
    }

    private func lineItemQuantity(for item: Item) -> Double {
        max(selectedItemQuantities[item.id] ?? 1, 0.25)
    }

    private func lineItemQuantityBinding(for item: Item) -> Binding<Double> {
        Binding(
            get: { lineItemQuantity(for: item) },
            set: { selectedItemQuantities[item.id] = min(max($0, 0.25), 100) }
        )
    }

    private func effectiveUnitPrice(for item: Item) -> Double {
        selectedItemPriceAdjustments[item.id]?.unitPrice ?? item.unitPrice
    }

    private func authorizePriceAdjustment(for item: Item, unitPrice: Double, reason: String) -> String? {
        do {
            selectedItemPriceAdjustments[item.id] = try BillingPriceAdjustmentPolicy.authorize(
                item: item,
                unitPrice: unitPrice,
                reason: reason,
                actorEmail: currentUserEmail,
                users: users
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func clearPriceAdjustment(for item: Item) {
        selectedItemPriceAdjustments.removeValue(forKey: item.id)
    }

    private func authorizeDocumentDiscount(
        kind: BillingDocumentDiscountKind,
        value: Double,
        reason: String
    ) -> String? {
        do {
            selectedDocumentDiscount = try BillingDocumentDiscountPolicy.authorize(
                kind: kind,
                value: value,
                grossSubtotal: selectedGrossSubtotal,
                reason: reason,
                actorEmail: currentUserEmail,
                users: users
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func resolveCustomerForDocument() -> Customer {
        let trimmedName = customerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPhone = customerPhone.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = customerEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAddress = customerAddress.trimmingCharacters(in: .whitespacesAndNewlines)

        if let selectedCustomer {
            selectedCustomer.name = trimmedName
            selectedCustomer.phone = trimmedPhone.isEmpty ? nil : trimmedPhone
            selectedCustomer.email = trimmedEmail.isEmpty ? nil : trimmedEmail
            selectedCustomer.address = trimmedAddress.isEmpty ? nil : trimmedAddress
            return selectedCustomer
        }

        let customer = Customer(
            name: trimmedName,
            phone: trimmedPhone.isEmpty ? nil : trimmedPhone,
            email: trimmedEmail.isEmpty ? nil : trimmedEmail,
            address: trimmedAddress.isEmpty ? nil : trimmedAddress
        )
        modelContext.insert(customer)
        return customer
    }

    private func createDocument() {
        guard !selectedLineItems.isEmpty else { return }
        if let documentDiscountValidationMessage {
            actionMessage = documentDiscountValidationMessage
            return
        }

        isCreatingDocument = true
        let customer = resolveCustomerForDocument()
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedCustomerID = customer.id
        BillingCustomerHandoff.apply(customer: customer, to: activeServiceCall)
        activeServiceCall?.notes = trimmedNotes.isEmpty ? activeServiceCall?.notes : trimmedNotes

        switch selectedDocumentKind {
        case .estimate:
            let normalizedChangeOrderReason = changeOrderReason.trimmingCharacters(in: .whitespacesAndNewlines)
            if changeOrderParentEstimateID != nil && normalizedChangeOrderReason.isEmpty {
                actionMessage = "Enter a reason for the change order before creating the revised estimate."
                isCreatingDocument = false
                return
            }
            let resolvedProposalGroupID = proposalOption == .standalone ? nil : (proposalGroupID ?? UUID())
            if proposalOption != .standalone {
                proposalGroupID = resolvedProposalGroupID
            }
            let resolvedServiceLocationID = activeServiceCall?.serviceLocationID ?? selectedServiceLocationID
            if let resolvedProposalGroupID,
               let issue = EstimateProposalPolicy.creationIssue(
                   groupID: resolvedProposalGroupID,
                   option: proposalOption,
                   customerID: customer.id,
                   serviceCallID: activeServiceCall?.id,
                   serviceLocationID: resolvedServiceLocationID,
                   in: estimates
               ) {
                actionMessage = issue
                isCreatingDocument = false
                return
            }
            let estimate = Estimate(
                serviceCallID: activeServiceCall?.id,
                serviceLocationID: resolvedServiceLocationID,
                siteAddress: selectedSiteAddressSnapshot,
                parentEstimateID: changeOrderParentEstimateID,
                changeOrderReason: changeOrderParentEstimateID == nil ? nil : normalizedChangeOrderReason,
                proposalGroupID: resolvedProposalGroupID,
                proposalOption: proposalOption == .standalone ? nil : proposalOption.rawValue,
                proposalIsRecommended: proposalOption == .standalone ? false : proposalIsRecommended,
                customer: customer,
                lineItemSummary: selectedSummary,
                catalogSnapshotJSON: selectedCatalogSnapshotJSON,
                amount: selectedTotal,
                notes: trimmedNotes.isEmpty ? nil : trimmedNotes
            )
            modelContext.insert(estimate)
            EstimateProposalPolicy.enforceSingleRecommendation(for: estimate, in: estimates + [estimate])
            activeServiceCall?.linkedEstimateID = estimate.id
            linkExistingEstimateAttachments(to: estimate, serviceCallID: activeServiceCall?.id)
            let documentTitle = estimate.isChangeOrder ? "Change order" : "Estimate"
            actionMessage = isQuickBooksConnected
                ? "\(documentTitle) created locally. Syncing to QuickBooks..."
                : "\(documentTitle) created locally."
            guard saveBillingContext(failureMessage: "Could not save estimate locally") else {
                isCreatingDocument = false
                return
            }
            syncEstimateIfNeeded(estimate, customer: customer, items: selectedLineItems)
            if openInvoiceAfterEstimateCreation {
                selectedDocumentKind = .invoice
                actionMessage = "Estimate created. Review and create the invoice when ready."
            } else {
                clearSelectedCatalogLines()
                notes = ""
                changeOrderParentEstimateID = nil
                changeOrderReason = ""
                if proposalOption == .standalone {
                    proposalGroupID = nil
                    proposalIsRecommended = false
                }
            }

        case .invoice:
            guard invoiceDueDateIsValid else {
                actionMessage = "Choose a due date on or after the invoice date."
                isCreatingDocument = false
                return
            }
            if currentJobInvoice == nil,
               let activeServiceCall,
               !activeServiceCall.canCreateInvoiceDocument {
                actionMessage = activeServiceCall.invoiceCreationBlockedMessage ?? "Complete required field documentation before creating an invoice."
                isCreatingDocument = false
                return
            }
            let invoice: Invoice
            let isUpdatingExistingInvoice: Bool
            if let currentJobInvoice {
                if let blockedMessage = BillingInvoiceMutationPolicy.blockedMessage(
                    for: currentJobInvoice,
                    payments: currentJobPayments
                ) {
                    actionMessage = blockedMessage
                    isCreatingDocument = false
                    return
                }
                invoice = currentJobInvoice
                isUpdatingExistingInvoice = true
                invoice.customer = customer
                invoice.serviceLocationID = activeServiceCall?.serviceLocationID ?? selectedServiceLocationID
                invoice.siteAddress = selectedSiteAddressSnapshot
                if let activeServiceCall {
                    invoice.workType = InvoiceWorkType.inferred(from: activeServiceCall)
                }
                invoice.lineItemSummary = selectedSummary
                invoice.catalogSnapshotJSON = selectedCatalogSnapshotJSON
                invoice.amount = selectedTotal
                invoice.salesTaxAmount = 0
                invoice.taxCalculationStatusRawValue = selectedHasTaxableLines
                    ? BillingTaxCalculationStatus.pendingQuickBooks.rawValue
                    : BillingTaxCalculationStatus.notApplicable.rawValue
                invoice.taxCalculatedAt = nil
                invoice.dueDate = resolvedInvoiceDueDate
                invoice.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
                invoice.quickBooksSyncStatus = "pending"
                invoice.quickBooksSyncDetail = isQuickBooksConnected
                    ? "Invoice update is waiting for QuickBooks confirmation."
                    : "Invoice changed while QuickBooks was unavailable. Reconnect and update this invoice again to publish it."
                actionMessage = isQuickBooksConnected
                    ? "Invoice updated locally. Syncing the complete line-item set to QuickBooks..."
                    : "Invoice updated locally. QuickBooks publication is pending."
            } else {
                invoice = Invoice(
                    serviceCallID: activeServiceCall?.id,
                    serviceLocationID: activeServiceCall?.serviceLocationID ?? selectedServiceLocationID,
                    siteAddress: selectedSiteAddressSnapshot,
                    customer: customer,
                    workType: InvoiceWorkType.inferred(from: activeServiceCall),
                    lineItemSummary: selectedSummary,
                    catalogSnapshotJSON: selectedCatalogSnapshotJSON,
                    amount: selectedTotal,
                    status: "unpaid",
                    dueDate: resolvedInvoiceDueDate,
                    notes: trimmedNotes.isEmpty ? nil : trimmedNotes
                )
                isUpdatingExistingInvoice = false
                modelContext.insert(invoice)
                activeServiceCall?.linkedInvoiceID = invoice.id
                activeServiceCall?.markDocumentationCompleteIfReady()
                activeServiceCall?.status = .invoiced
                let reportErrorMessage = prepareLinkedOnsiteReportForInvoiceCreation(invoice, serviceCall: activeServiceCall)
                actionMessage = reportErrorMessage ?? (isQuickBooksConnected ? "Invoice created locally with onsite report. Syncing to QuickBooks..." : "Invoice created locally with onsite report.")
            }
            guard saveBillingContext(failureMessage: isUpdatingExistingInvoice ? "Could not update invoice locally" : "Could not save invoice locally") else {
                isCreatingDocument = false
                return
            }
            let shouldReturnToInvoiceOverview = isUpdatingExistingInvoice && selectedInvoiceForEditingID == invoice.id
            syncInvoiceIfNeeded(invoice, customer: customer, items: selectedLineItems)
            if shouldReturnToInvoiceOverview {
                finishInvoiceWorkspaceEditing()
            } else if !isUpdatingExistingInvoice {
                clearSelectedCatalogLines()
                notes = ""
                selectedInvoicePaymentTerms = configuredDefaultInvoicePaymentTerms
                invoiceCustomDueDate = configuredDefaultInvoicePaymentTerms.dueDate(from: Date())
                    ?? Calendar.current.startOfDay(for: Date())
            }
        }
        isCreatingDocument = false
    }

    private func saveBillingContext(failureMessage: String) -> Bool {
        do {
            try modelContext.save()
            return true
        } catch {
            actionMessage = "\(failureMessage): \(error.localizedDescription)"
            return false
        }
    }

    private func openPaymentsForInvoice(_ invoice: Invoice) {
        GunnAireAppIntentRouter.storePaymentCollectionRoute(invoice.id)
    }

    private func openInvoiceCloseout(_ invoice: Invoice) {
        guard canCollectFieldPayments else {
            actionMessage = "Your role cannot open invoice collection tools."
            return
        }
        if let blockedMessage = invoice.paymentCollectionBlockedMessage {
            actionMessage = blockedMessage
            return
        }
        selectedInvoiceForCloseout = invoice
    }

    private func canEditInvoice(_ invoice: Invoice) -> Bool {
        guard BillingInvoiceMutationPolicy.blockedMessage(for: invoice, payments: payments) == nil else {
            return false
        }
        if canViewFinancials {
            return true
        }
        guard canCollectFieldPayments,
              let call = serviceCall(for: invoice) else { return false }
        return AppAccess.canAccessServiceCall(
            call,
            email: currentUserEmail,
            users: users,
            serviceCalls: serviceCalls,
            technicians: technicians
        )
    }

    private func beginEditingInvoice(_ invoice: Invoice) {
        guard canEditInvoice(invoice) else {
            actionMessage = BillingInvoiceMutationPolicy.blockedMessage(for: invoice, payments: payments)
                ?? "This account cannot edit that invoice."
            return
        }

        selectedInvoiceForEditingID = invoice.id
        selectedDocumentKind = .invoice
        selectedJobStage = .billing
        loadInvoiceIntoBuilder(invoice, announce: false)
        invoiceWorkspaceLane = .newInvoice
        actionMessage = "Editing the existing invoice. Save with Update Invoice; QuickBooks remains pending until it confirms the complete line-item set."
    }

    private func finishInvoiceWorkspaceEditing(message: String? = nil) {
        selectedInvoiceForEditingID = nil
        if initialServiceCall == nil {
            pendingIntentServiceCallID = nil
        }
        clearSelectedCatalogLines()
        notes = ""
        selectedInvoicePaymentTerms = configuredDefaultInvoicePaymentTerms
        invoiceCustomDueDate = configuredDefaultInvoicePaymentTerms.dueDate(from: Date())
            ?? Calendar.current.startOfDay(for: Date())
        invoiceWorkspaceLane = .overview
        if let message {
            actionMessage = message
        }
    }

    private func syncEstimateIfNeeded(_ estimate: Estimate, customer: Customer, items: [Item]) {
        guard isQuickBooksConnected else { return }
        guard syncingEstimateIDs.insert(estimate.id).inserted else { return }
        ensureQuickBooksDocumentInputs(customer: customer, items: items) { result in
            switch result {
            case .failure(let error):
                syncingEstimateIDs.remove(estimate.id)
                actionMessage = "Estimate saved locally. QuickBooks sync failed: \(error.localizedDescription)"
            case .success(let syncedItems):
                let lines: [QuickBooksLineItem]
                do {
                    lines = try QuickBooksDocumentLinePublication.lines(
                        snapshotJSON: estimate.catalogSnapshotJSON,
                        expectedSubtotal: estimate.subtotalAmount,
                        catalogItems: catalogItemsForDocumentPublication(syncedItems)
                    )
                } catch {
                    syncingEstimateIDs.remove(estimate.id)
                    actionMessage = "Estimate saved locally. QuickBooks sync stopped: \(error.localizedDescription)"
                    return
                }
                let payload = QuickBooksEstimateCreate(
                    CustomerRef: QuickBooksReference(value: customer.quickBooksID ?? "", name: customer.name),
                    Line: lines,
                    PrivateNote: quickBooksPrivateNote(for: estimate),
                    BillEmail: customer.email.flatMap { $0.isEmpty ? nil : QuickBooksEmailAddress(Address: $0) },
                    ShipAddr: estimate.siteAddress.flatMap(nilIfBlank).map { QuickBooksAddress(Line1: $0) },
                    GlobalTaxCalculation: "TaxExcluded",
                    ApplyTaxAfterDiscount: estimate.documentDiscount == nil ? nil : true
                )
                liveAPI.fetchEstimates { fetchResult in
                    DispatchQueue.main.async {
                        switch fetchResult {
                        case .failure(let error):
                            syncingEstimateIDs.remove(estimate.id)
                            actionMessage = "Estimate saved locally. QuickBooks reconciliation failed, so no duplicate-prone create was attempted: \(error.localizedDescription)"
                        case .success(let remoteEstimates):
                            do {
                                if let recovered = try QuickBooksEstimatePublicationRecovery.matchingRemoteEstimate(
                                    for: estimate,
                                    in: remoteEstimates
                                ) {
                                    finishQuickBooksEstimateSync(
                                        .success(recovered),
                                        estimate: estimate,
                                        recoveredExisting: true
                                    )
                                    return
                                }
                            } catch {
                                syncingEstimateIDs.remove(estimate.id)
                                actionMessage = error.localizedDescription
                                return
                            }

                            liveAPI.createEstimate(payload) { apiResult in
                                DispatchQueue.main.async {
                                    finishQuickBooksEstimateSync(
                                        apiResult,
                                        estimate: estimate,
                                        recoveredExisting: false
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func finishQuickBooksEstimateSync(
        _ result: Result<QuickBooksEstimate, Error>,
        estimate: Estimate,
        recoveredExisting: Bool
    ) {
        syncingEstimateIDs.remove(estimate.id)
        switch result {
        case .success(let quickBooksEstimate):
            estimate.quickBooksID = quickBooksEstimate.Id
            let taxIssue = estimate.applyQuickBooksTaxResult(
                total: quickBooksEstimate.TotalAmt,
                reportedTax: quickBooksEstimate.TxnTaxDetail?.TotalTax
            )
            saveQuickBooksSyncState()
            syncLinkedEstimateAttachmentsToQuickBooks(estimate)
            if let taxIssue {
                actionMessage = "Estimate is linked to QuickBooks, but its tax total needs review: \(taxIssue)"
            } else {
                actionMessage = recoveredExisting
                    ? "Existing QuickBooks estimate recovered without creating a duplicate."
                    : "Estimate created and synced to QuickBooks."
            }
        case .failure(let error):
            actionMessage = "Estimate saved locally. QuickBooks sync failed: \(error.localizedDescription)"
        }
    }

    private func quickBooksPrivateNote(for estimate: Estimate) -> String? {
        let entries = [
            estimate.notes?.trimmingCharacters(in: .whitespacesAndNewlines),
            estimate.changeOrderReason.map { "Change order reason: \($0)" }
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        let adjustedNote = BillingPriceAdjustmentAudit.quickBooksPrivateNote(
            existing: entries.isEmpty ? nil : entries.joined(separator: "\n"),
            snapshotJSON: estimate.catalogSnapshotJSON
        )
        let discountedNote = BillingDocumentDiscountAudit.quickBooksPrivateNote(
            existing: adjustedNote,
            snapshotJSON: estimate.catalogSnapshotJSON
        )
        return QuickBooksEstimateLineage.appendingLineage(to: discountedNote, for: estimate)
    }

    private func quickBooksPrivateNote(for invoice: Invoice) -> String? {
        QuickBooksInvoiceLineage.appendingLineage(
            to: BillingDocumentDiscountAudit.quickBooksPrivateNote(
                existing: BillingPriceAdjustmentAudit.quickBooksPrivateNote(
                    existing: invoice.accountingPrivateNote,
                    snapshotJSON: invoice.catalogSnapshotJSON
                ),
                snapshotJSON: invoice.catalogSnapshotJSON
            ),
            for: invoice
        )
    }

    private func syncInvoiceIfNeeded(_ invoice: Invoice, customer: Customer, items: [Item]) {
        guard isQuickBooksConnected else {
            invoice.quickBooksSyncStatus = "pending"
            invoice.quickBooksSyncDetail = "QuickBooks is not connected. Reconnect and update this invoice again to publish its current line items."
            saveQuickBooksSyncState()
            return
        }
        ensureQuickBooksDocumentInputs(customer: customer, items: items) { result in
            switch result {
            case .failure(let error):
                markQuickBooksInvoiceSyncFailure(invoice, error: error)
                actionMessage = "Invoice saved locally. QuickBooks sync failed: \(error.localizedDescription)"
            case .success(let syncedItems):
                let lines: [QuickBooksLineItem]
                do {
                    lines = try QuickBooksDocumentLinePublication.lines(
                        snapshotJSON: invoice.catalogSnapshotJSON,
                        expectedSubtotal: invoice.subtotalAmount,
                        catalogItems: catalogItemsForDocumentPublication(syncedItems)
                    )
                } catch {
                    markQuickBooksInvoiceSyncFailure(invoice, error: error)
                    actionMessage = "Invoice saved locally. QuickBooks sync stopped: \(error.localizedDescription)"
                    return
                }
                if let quickBooksID = invoice.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !quickBooksID.isEmpty {
                    updateQuickBooksInvoice(
                        invoice,
                        quickBooksID: quickBooksID,
                        customer: customer,
                        lines: lines
                    )
                } else {
                    createQuickBooksInvoice(invoice, customer: customer, lines: lines)
                }
            }
        }
    }

    private func createQuickBooksInvoice(
        _ invoice: Invoice,
        customer: Customer,
        lines: [QuickBooksLineItem]
    ) {
        let payload = QuickBooksInvoiceCreate(
            CustomerRef: QuickBooksReference(value: customer.quickBooksID ?? "", name: customer.name),
            Line: lines,
            PrivateNote: quickBooksPrivateNote(for: invoice),
            BillEmail: customer.email.flatMap { $0.isEmpty ? nil : QuickBooksEmailAddress(Address: $0) },
            ShipAddr: invoice.siteAddress.flatMap(nilIfBlank).map { QuickBooksAddress(Line1: $0) },
            DueDate: QuickBooksDateOnly.string(from: invoice.effectiveDueDate()),
            GlobalTaxCalculation: "TaxExcluded",
            ApplyTaxAfterDiscount: invoice.documentDiscount == nil ? nil : true
        )
        liveAPI.fetchInvoices { fetchResult in
            DispatchQueue.main.async {
                switch fetchResult {
                case .failure(let error):
                    markQuickBooksInvoiceSyncFailure(invoice, error: error)
                    actionMessage = "Invoice saved locally. QuickBooks reconciliation failed, so no duplicate-prone create was attempted: \(error.localizedDescription)"
                case .success(let remoteInvoices):
                    do {
                        if let recovered = try QuickBooksInvoicePublicationRecovery.matchingRemoteInvoice(
                            for: invoice,
                            in: remoteInvoices
                        ) {
                            applyQuickBooksInvoiceSync(recovered, to: invoice)
                            syncLinkedServiceReportsToQuickBooks(invoice)
                            actionMessage = invoice.needsQuickBooksAttention
                                ? "Existing QuickBooks invoice recovered, but its tax total needs review: \(invoice.quickBooksSyncDetail ?? "Refresh the invoice in QuickBooks.")"
                                : "Existing QuickBooks invoice recovered without creating a duplicate."
                            return
                        }
                    } catch {
                        markQuickBooksInvoiceSyncFailure(invoice, error: error)
                        actionMessage = error.localizedDescription
                        return
                    }

                    liveAPI.createInvoice(
                        payload,
                        requestID: QuickBooksInvoiceLineage.createRequestID(for: invoice)
                    ) { apiResult in
                        DispatchQueue.main.async {
                            switch apiResult {
                            case .success(let quickBooksInvoice):
                                applyQuickBooksInvoiceSync(quickBooksInvoice, to: invoice)
                                syncLinkedServiceReportsToQuickBooks(invoice)
                                actionMessage = invoice.needsQuickBooksAttention
                                    ? "Invoice is linked to QuickBooks, but its tax total needs review: \(invoice.quickBooksSyncDetail ?? "Refresh the invoice in QuickBooks.")"
                                    : "Invoice created and synced to QuickBooks."
                            case .failure(let error):
                                markQuickBooksInvoiceSyncFailure(invoice, error: error)
                                actionMessage = "Invoice saved locally. QuickBooks sync failed: \(error.localizedDescription)"
                            }
                        }
                    }
                }
            }
        }
    }

    private func updateQuickBooksInvoice(
        _ invoice: Invoice,
        quickBooksID: String,
        customer: Customer,
        lines: [QuickBooksLineItem]
    ) {
        liveAPI.fetchInvoice(id: quickBooksID) { fetchResult in
            DispatchQueue.main.async {
                switch fetchResult {
                case .failure(let error):
                    markQuickBooksInvoiceSyncFailure(invoice, error: error)
                    actionMessage = "Invoice updated locally. QuickBooks refresh failed: \(error.localizedDescription)"
                case .success(let currentQuickBooksInvoice):
                    guard let syncToken = currentQuickBooksInvoice.SyncToken?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !syncToken.isEmpty else {
                        let error = QuickBooksDataAPI.QBError.missingSyncToken(entity: "invoice \(quickBooksID)")
                        markQuickBooksInvoiceSyncFailure(invoice, error: error)
                        actionMessage = "Invoice updated locally. \(error.localizedDescription)"
                        return
                    }
                    let payload = QuickBooksInvoiceUpdate(
                        Id: quickBooksID,
                        SyncToken: syncToken,
                        CustomerRef: QuickBooksReference(value: customer.quickBooksID ?? "", name: customer.name),
                        Line: lines,
                        PrivateNote: quickBooksPrivateNote(for: invoice),
                        BillEmail: customer.email.flatMap { $0.isEmpty ? nil : QuickBooksEmailAddress(Address: $0) },
                        ShipAddr: invoice.siteAddress.flatMap(nilIfBlank).map { QuickBooksAddress(Line1: $0) },
                        DueDate: QuickBooksDateOnly.string(from: invoice.effectiveDueDate()),
                        GlobalTaxCalculation: "TaxExcluded",
                        ApplyTaxAfterDiscount: invoice.documentDiscount == nil ? nil : true
                    )
                    liveAPI.updateInvoice(payload) { updateResult in
                        DispatchQueue.main.async {
                            switch updateResult {
                            case .success(let quickBooksInvoice):
                                applyQuickBooksInvoiceSync(quickBooksInvoice, to: invoice)
                                syncLinkedServiceReportsToQuickBooks(invoice)
                                actionMessage = invoice.needsQuickBooksAttention
                                    ? "Invoice lines reached QuickBooks, but the tax total needs review: \(invoice.quickBooksSyncDetail ?? "Refresh the invoice in QuickBooks.")"
                                    : "Invoice line items updated and synced to QuickBooks."
                            case .failure(let error):
                                markQuickBooksInvoiceSyncFailure(invoice, error: error)
                                actionMessage = "Invoice updated locally. QuickBooks update failed: \(error.localizedDescription)"
                            }
                        }
                    }
                }
            }
        }
    }

    private func applyQuickBooksInvoiceSync(_ quickBooksInvoice: QuickBooksInvoice, to invoice: Invoice) {
        invoice.quickBooksID = quickBooksInvoice.Id
        invoice.quickBooksBalanceDue = quickBooksInvoice.Balance
        if let rawDueDate = quickBooksInvoice.DueDate,
           let dueDate = QuickBooksDateOnly.date(from: rawDueDate) {
            invoice.dueDate = dueDate
        }
        let taxIssue = invoice.applyQuickBooksTaxResult(
            total: quickBooksInvoice.TotalAmt,
            reportedTax: quickBooksInvoice.TxnTaxDetail?.TotalTax
        )
        invoice.quickBooksSyncStatus = taxIssue == nil ? "synced" : "needs_attention"
        invoice.quickBooksSyncDetail = taxIssue
        invoice.quickBooksLastSyncedAt = Date()
        saveQuickBooksSyncState()
    }

    private func markQuickBooksInvoiceSyncFailure(_ invoice: Invoice, error: Error) {
        invoice.quickBooksSyncStatus = "needs_attention"
        invoice.quickBooksSyncDetail = error.localizedDescription
        saveQuickBooksSyncState()
    }

    private func ensureQuickBooksDocumentInputs(
        customer: Customer,
        items: [Item],
        completion: @escaping (Result<[Item], Error>) -> Void
    ) {
        ensureQuickBooksCustomer(customer) { customerResult in
            switch customerResult {
            case .failure(let error):
                completion(.failure(error))
            case .success:
                prepareQuickBooksItemsForDocument(items, completion: completion)
            }
        }
    }

    private func ensureQuickBooksCustomer(_ customer: Customer, completion: @escaping (Result<Void, Error>) -> Void) {
        if let quickBooksID = customer.quickBooksID, !quickBooksID.isEmpty {
            completion(.success(()))
            return
        }

        liveAPI.recoverOrCreateCustomer(
            QuickBooksCustomerCreateOperation.draft(for: customer)
        ) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let quickBooksCustomer):
                    customer.quickBooksID = quickBooksCustomer.Id
                    saveQuickBooksSyncState()
                    completion(.success(()))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }

    private func prepareQuickBooksItemsForDocument(
        _ items: [Item],
        completion: @escaping (Result<[Item], Error>) -> Void
    ) {
        do {
            try QuickBooksCatalogMappingIntegrity.validateDocumentItems(items, against: self.items)
        } catch {
            QuickBooksCatalogMappingIntegrity.markConflictsForReview(in: self.items)
            saveQuickBooksSyncState()
            completion(.failure(error))
            return
        }
        if let item = items.first(where: \.requiresPricebookReview) {
            completion(.failure(PricebookPublicationError.reviewRequired(item.name)))
            return
        }
        if let item = items.first(where: \.isCatalogArchived) {
            completion(.failure(PricebookPublicationError.archived(item.name)))
            return
        }
        guard items.contains(where: itemNeedsQuickBooksSync) else {
            completion(.success(items))
            return
        }

        Task { @MainActor in
            await accountingConfigurationStore.refresh(
                realmID: liveAPI.realmID,
                environment: Config.QuickBooks.environment
            )
            let accountingConfiguration = self.accountingConfiguration
            liveAPI.fetchItems { result in
                DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    markQuickBooksCatalogSyncFailure(for: items.filter(itemNeedsQuickBooksSync), error: error)
                    completion(.failure(error))
                case .success(let quickBooksItems):
                    for item in items where itemNeedsQuickBooksSync(item) {
                        do {
                            if let quickBooksItem = try PricebookReviewPublication.matchingRemoteItem(
                                for: item,
                                in: quickBooksItems
                            ) {
                                try QuickBooksCatalogMappingIntegrity.validateAssignment(
                                    of: quickBooksItem.Id,
                                    to: item,
                                    in: self.items
                                )
                                let shouldStageReactivation = item.isAvailableForNewWork && quickBooksItem.Active == false
                                applyQuickBooksItem(quickBooksItem, to: item)
                                if shouldStageReactivation {
                                    item.restoreToPricebook(by: currentUserEmail)
                                    saveQuickBooksSyncState()
                                    completion(.failure(PricebookPublicationError.inactiveQuickBooksMatch(item.name)))
                                    return
                                }
                            }
                        } catch {
                            markQuickBooksCatalogSyncFailure(for: [item], error: error)
                            completion(.failure(error))
                            return
                        }
                    }

                    let remainingLocalItems = items.filter(itemNeedsQuickBooksSync)
                    guard !remainingLocalItems.isEmpty else {
                        saveQuickBooksSyncState()
                        completion(.success(items))
                        return
                    }

                    guard let incomeAccountRef = QuickBooksItemAccountResolver.incomeAccountRef(
                        from: quickBooksItems,
                        configuration: accountingConfiguration
                    ) else {
                        let error = QuickBooksDataAPI.QBError.missingDefaultIncomeAccountRef
                        markQuickBooksCatalogSyncFailure(for: remainingLocalItems, error: error)
                        completion(.failure(error))
                        return
                    }

                    ensureQuickBooksItems(
                        items,
                        index: 0,
                        incomeAccountRef: incomeAccountRef,
                        expenseAccountRef: QuickBooksItemAccountResolver.configuredExpenseAccountRef(
                            configuration: accountingConfiguration
                        ),
                        synced: [],
                        completion: completion
                    )
                }
                }
            }
        }
    }

    private func itemNeedsQuickBooksSync(_ item: Item) -> Bool {
        item.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }

    private func catalogItemsForDocumentPublication(_ documentItems: [Item]) -> [Item] {
        var itemsByID = Dictionary(self.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for item in documentItems {
            itemsByID[item.id] = item
        }
        return Array(itemsByID.values)
    }

    private func ensureQuickBooksItems(
        _ items: [Item],
        index: Int,
        incomeAccountRef: QuickBooksReference,
        expenseAccountRef: QuickBooksReference?,
        synced: [Item],
        completion: @escaping (Result<[Item], Error>) -> Void
    ) {
        guard index < items.count else {
            completion(.success(synced))
            return
        }

        let item = items[index]
        if let quickBooksID = item.quickBooksID, !quickBooksID.isEmpty {
            ensureQuickBooksItems(
                items,
                index: index + 1,
                incomeAccountRef: incomeAccountRef,
                expenseAccountRef: expenseAccountRef,
                synced: synced + [item],
                completion: completion
            )
            return
        }

        let payload = QuickBooksCatalogCreateOperation.payload(
            for: item,
            incomeAccountRef: incomeAccountRef,
            expenseAccountRef: expenseAccountRef
        )
        liveAPI.createItem(
            payload,
            requestID: QuickBooksCatalogCreateOperation.requestID(for: item.id)
        ) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let quickBooksItem):
                    applyQuickBooksItem(quickBooksItem, to: item)
                    saveQuickBooksSyncState()
                    ensureQuickBooksItems(
                        items,
                        index: index + 1,
                        incomeAccountRef: incomeAccountRef,
                        expenseAccountRef: expenseAccountRef,
                        synced: synced + [item],
                        completion: completion
                    )
                case .failure(let error):
                    markQuickBooksCatalogSyncFailure(for: [item], error: error)
                    completion(.failure(error))
                }
            }
        }
    }

    @discardableResult
    private func convertEstimate(_ estimate: Estimate) -> (invoice: Invoice, reportErrorMessage: String?) {
        let createdAt = Date()
        let dueDate = configuredDefaultInvoicePaymentTerms.dueDate(from: createdAt)
            ?? Calendar.current.startOfDay(for: createdAt)
        let invoice = Invoice.draft(from: estimate, dueDate: dueDate, createdAt: createdAt)
        estimate.status = "invoiced"
        modelContext.insert(invoice)
        var linkedServiceCall: ServiceCall?
        if let serviceCallID = estimate.serviceCallID,
           let calls = try? modelContext.fetch(FetchDescriptor<ServiceCall>()),
           let call = calls.first(where: { $0.id == serviceCallID }) {
            linkedServiceCall = call
            call.linkedInvoiceID = invoice.id
            call.status = .invoiced
            call.markDocumentationCompleteIfReady()
            ServiceCallActivity.record(for: call, action: "Invoice created", detail: "Estimate converted to invoice and job marked invoiced.", actorEmail: currentUserEmail, in: modelContext)
        }
        invoice.workType = InvoiceWorkType.inferred(from: linkedServiceCall)
        let reportErrorMessage = prepareLinkedOnsiteReportForInvoiceCreation(invoice, serviceCall: linkedServiceCall)
        return (invoice, reportErrorMessage)
    }

    @ViewBuilder
    private func workflowSection(for call: ServiceCall) -> some View {
        Section(jobWorkflowTitle(for: call)) {
            Text("Workflow progress: \(call.workflowChecklistCompletedCount)/\(call.workflowChecklistTotalCount)")
                .font(.caption)
                .foregroundColor(.secondary)

            switch call.type {
            case .service, .repair:
                Toggle("Diagnostics captured", isOn: Binding(
                    get: { call.diagnosticsCaptured },
                    set: { call.diagnosticsCaptured = $0 }
                ))
                Toggle("Recommended work reviewed with customer", isOn: Binding(
                    get: { call.quoteReviewedWithCustomer },
                    set: { call.quoteReviewedWithCustomer = $0 }
                ))
                Toggle("Safety checks completed", isOn: Binding(
                    get: { call.safetyChecklistComplete },
                    set: { call.safetyChecklistComplete = $0 }
                ))
                Text("Use this for diagnostic and repair calls before building the invoice.")
                    .font(.caption2)
                    .foregroundColor(.secondary)

            case .estimate:
                Toggle("Scope reviewed with customer", isOn: Binding(
                    get: { call.quoteReviewedWithCustomer },
                    set: { call.quoteReviewedWithCustomer = $0 }
                ))
                Toggle("Findings captured for quote", isOn: Binding(
                    get: { call.diagnosticsCaptured },
                    set: { call.diagnosticsCaptured = $0 }
                ))
                Toggle("Follow-up scheduled", isOn: Binding(
                    get: { call.followUpRequired },
                    set: { call.followUpRequired = $0 }
                ))
                Text("Estimate jobs should leave with a reviewed scope and a clear next step.")
                    .font(.caption2)
                    .foregroundColor(.secondary)

            case .replacement, .install:
                Toggle("Equipment verified", isOn: Binding(
                    get: { call.equipmentVerifiedChecklist },
                    set: { call.equipmentVerifiedChecklist = $0 }
                ))
                Toggle("Startup checklist complete", isOn: Binding(
                    get: { call.startupChecklistComplete },
                    set: { call.startupChecklistComplete = $0 }
                ))
                Toggle("Safety checks completed", isOn: Binding(
                    get: { call.safetyChecklistComplete },
                    set: { call.safetyChecklistComplete = $0 }
                ))
                Text("Install jobs should verify model/serial, startup, and safety before closeout.")
                    .font(.caption2)
                    .foregroundColor(.secondary)

            case .maintenance:
                Toggle("Maintenance checklist complete", isOn: Binding(
                    get: { call.maintenanceChecklistComplete },
                    set: { call.maintenanceChecklistComplete = $0 }
                ))
                Toggle("Safety checks completed", isOn: Binding(
                    get: { call.safetyChecklistComplete },
                    set: { call.safetyChecklistComplete = $0 }
                ))
                Toggle("Customer notified of findings", isOn: Binding(
                    get: { call.customerNotified },
                    set: { call.customerNotified = $0 }
                ))
                Text("Maintenance jobs should leave with service completed, safety checked, and customer informed.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            case .meeting, .reminder, .siteVisit, .other:
                Toggle("Arrival confirmed", isOn: Binding(
                    get: { call.arrivalConfirmed },
                    set: { arrived in
                        if arrived {
                            call.markTechnicianArrived()
                        } else {
                            call.arrivalConfirmed = false
                            call.technicianArrivedAt = nil
                        }
                    }
                ))
                Toggle("Action items documented", isOn: Binding(
                    get: { call.workCompletedChecklist },
                    set: { call.workCompletedChecklist = $0 }
                ))
                Toggle("Notes completed", isOn: Binding(
                    get: { call.documentationChecklist },
                    set: { call.documentationChecklist = $0 }
                ))
                Text("General appointments should capture attendance, action items, and notes before closeout.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            }
        }

    private func jobWorkflowTitle(for call: ServiceCall) -> String {
        switch call.type {
        case .service:
            return "Service Workflow"
        case .repair:
            return "Repair Workflow"
        case .estimate:
            return "Estimate Workflow"
        case .replacement:
            return "Replacement Workflow"
        case .install:
            return "Install Workflow"
        case .maintenance:
            return "Maintenance Workflow"
        case .meeting:
            return "Meeting Workflow"
        case .reminder:
            return "Reminder Workflow"
        case .siteVisit:
            return "Site Visit Workflow"
        case .other:
            return "General Workflow"
        }
    }

    private func normalizedEquipmentKey(for call: ServiceCall) -> String? {
        if let serial = call.equipmentSerialNumber?.trimmingCharacters(in: .whitespacesAndNewlines),
           !serial.isEmpty {
            return "serial:\(serial.lowercased())"
        }

        let equipmentName = call.equipmentName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let equipmentModel = call.equipmentModel?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let composite = "\(equipmentName)|\(equipmentModel)"
        return composite == "|" || composite.isEmpty ? nil : composite
    }
}

enum BillingCustomerHandoff {
    /// Customer.address is the billing/default address. A job's service address is
    /// a historical operational snapshot and must not be rewritten by billing edits.
    static func apply(customer: Customer, to serviceCall: ServiceCall?) {
        serviceCall?.customer = customer
    }
}

@ViewBuilder
private func workspaceMetricView(title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(title)
            .font(.caption)
            .foregroundColor(.secondary)
        Text(value)
            .font(.headline)
    }
}

enum ApprovedEstimateSchedulingError: LocalizedError, Equatable {
    case approvalRequired
    case appointmentMustBeFuture
    case invalidDuration

    var errorDescription: String? {
        switch self {
        case .approvalRequired:
            return "Record traceable customer approval before scheduling this estimate."
        case .appointmentMustBeFuture:
            return "Choose an appointment time in the future."
        case .invalidDuration:
            return "Choose a work duration between 30 minutes and 12 hours."
        }
    }
}

enum ApprovedEstimateScheduling {
    static let workTypes: [ServiceCallType] = [.service, .repair, .replacement, .install, .maintenance, .siteVisit, .other]
    static let durationOptions: [TimeInterval] = [3_600, 7_200, 14_400, 28_800]

    static func existingWorkOrder(for estimate: Estimate, in serviceCalls: [ServiceCall]) -> ServiceCall? {
        if let scheduledID = estimate.scheduledServiceCallID,
           let linked = serviceCalls.first(where: { $0.id == scheduledID && $0.status != .cancelled }) {
            return linked
        }
        return serviceCalls.first { call in
            call.linkedEstimateID == estimate.id &&
            call.id != estimate.serviceCallID &&
            call.status != .cancelled
        }
    }

    static func defaultScheduledDate(after date: Date = Date(), calendar: Calendar = .current) -> Date {
        let nextDay = calendar.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86_400)
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: nextDay) ?? nextDay
    }

    static func defaultWorkType(sourceCall: ServiceCall?) -> ServiceCallType {
        guard let sourceCall else { return .install }
        return sourceCall.type == .estimate ? .install : sourceCall.type
    }

    static func makeWorkOrder(
        for estimate: Estimate,
        sourceCall: ServiceCall?,
        scheduledDate: Date,
        duration: TimeInterval,
        workType: ServiceCallType,
        now: Date = Date()
    ) throws -> ServiceCall {
        guard estimate.hasRecordedCustomerApproval else {
            throw ApprovedEstimateSchedulingError.approvalRequired
        }
        guard scheduledDate > now else {
            throw ApprovedEstimateSchedulingError.appointmentMustBeFuture
        }
        guard duration >= 1_800, duration <= 43_200 else {
            throw ApprovedEstimateSchedulingError.invalidDuration
        }

        let scope = estimate.lineItemSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let estimateNotes = estimate.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceRecommendation = sourceCall?.recommendedWorkSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fieldRecommendation = sourceRecommendation.flatMap { value in
            value.isEmpty ? nil : "Field recommendation:\n\(value)"
        }
        let notes = [
            "Scheduled from approved estimate \(String(estimate.id.uuidString.prefix(8)).uppercased()).",
            scope.isEmpty ? nil : "Approved scope:\n\(scope)",
            estimateNotes?.isEmpty == false ? estimateNotes : nil,
            fieldRecommendation
        ]
        .compactMap { $0 }
        .joined(separator: "\n\n")

        let workOrder = ServiceCall(
            googleEventManagedByApp: true,
            eventTitle: "\(workType.displayName) — \(estimate.customer.name)",
            siteAddress: sourceCall?.siteAddress ?? estimate.siteAddress ?? estimate.customer.address,
            serviceLocationID: sourceCall?.serviceLocationID ?? estimate.serviceLocationID,
            equipmentName: sourceCall?.equipmentName,
            equipmentManufacturer: sourceCall?.equipmentManufacturer,
            equipmentModel: sourceCall?.equipmentModel,
            equipmentSerialNumber: sourceCall?.equipmentSerialNumber,
            equipmentLocation: sourceCall?.equipmentLocation,
            equipmentInstallDate: sourceCall?.equipmentInstallDate,
            equipmentWarrantyExpiration: sourceCall?.equipmentWarrantyExpiration,
            customerEquipmentID: sourceCall?.customerEquipmentID,
            type: workType,
            scheduledDate: scheduledDate,
            duration: duration,
            customer: estimate.customer,
            status: .scheduled,
            notes: notes,
            findingsSummary: sourceCall?.findingsSummary,
            recommendedWorkSummary: scope.isEmpty ? sourceCall?.recommendedWorkSummary : scope,
            followUpRequired: false,
            linkedEstimateID: estimate.id
        )
        if let sourceCall {
            workOrder.inheritEquipmentProfile(from: sourceCall)
            workOrder.dispatchUrgency = sourceCall.dispatchUrgency
        }
        return workOrder
    }
}

struct ApprovedEstimateSchedulingSheet: View {
    @Environment(\.dismiss) private var dismiss

    let estimate: Estimate
    let sourceCall: ServiceCall?
    let onSchedule: (Date, TimeInterval, ServiceCallType) -> Bool

    @State private var scheduledDate: Date
    @State private var duration: TimeInterval
    @State private var workType: ServiceCallType
    @State private var validationMessage: String?

    init(
        estimate: Estimate,
        sourceCall: ServiceCall?,
        onSchedule: @escaping (Date, TimeInterval, ServiceCallType) -> Bool
    ) {
        self.estimate = estimate
        self.sourceCall = sourceCall
        self.onSchedule = onSchedule
        _scheduledDate = State(initialValue: ApprovedEstimateScheduling.defaultScheduledDate())
        let sourceDuration = sourceCall?.duration
        let initialDuration = sourceDuration.flatMap { duration in
            ApprovedEstimateScheduling.durationOptions.contains(duration) ? duration : nil
        } ?? 7_200
        _duration = State(initialValue: initialDuration)
        _workType = State(initialValue: ApprovedEstimateScheduling.defaultWorkType(sourceCall: sourceCall))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Approved Scope") {
                    LabeledContent("Customer", value: estimate.customer.name)
                    LabeledContent("Estimate", value: estimate.amount.formatted(.currency(code: "USD")))
                    if let approvalDate = estimate.customerApprovedAt {
                        LabeledContent("Approved", value: approvalDate.formatted(date: .abbreviated, time: .shortened))
                    }
                    Text(estimate.lineItemSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Appointment") {
                    DatePicker(
                        "Start",
                        selection: $scheduledDate,
                        in: Date()...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    Picker("Work type", selection: $workType) {
                        ForEach(ApprovedEstimateScheduling.workTypes, id: \.rawValue) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    Picker("Planned duration", selection: $duration) {
                        ForEach(ApprovedEstimateScheduling.durationOptions, id: \.self) { seconds in
                            Text(durationLabel(seconds)).tag(seconds)
                        }
                    }
                }

                Section {
                    Label(
                        "The work order starts unassigned so Dispatch can verify crew availability, qualifications, and travel before committing a technician.",
                        systemImage: "person.2.badge.gearshape"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let validationMessage {
                        Text(validationMessage)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Schedule Approved Work")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create Work Order") {
                        guard scheduledDate > Date() else {
                            validationMessage = ApprovedEstimateSchedulingError.appointmentMustBeFuture.localizedDescription
                            return
                        }
                        if onSchedule(scheduledDate, duration, workType) {
                            dismiss()
                        } else {
                            validationMessage = "The work order could not be saved. Review the appointment details and try again."
                        }
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func durationLabel(_ seconds: TimeInterval) -> String {
        let hours = seconds / 3_600
        return hours == 1 ? "1 hour" : "\(hours.formatted(.number.precision(.fractionLength(0...1)))) hours"
    }
}

enum JobDocumentationStage: String, CaseIterable, Identifiable {
    case work
    case files
    case billing
    case closeout

    var id: String { rawValue }

    var label: String {
        switch self {
        case .work: "Work"
        case .files: "Files"
        case .billing: "Billing"
        case .closeout: "Closeout"
        }
    }

    var systemImage: String {
        switch self {
        case .work: "wrench.and.screwdriver"
        case .files: "folder"
        case .billing: "doc.text"
        case .closeout: "checkmark.circle"
        }
    }

    var guidance: String {
        switch self {
        case .work:
            "Record HVAC readings, findings, equipment details, and workflow checks."
        case .files:
            "Capture job photos and files, then create customer-ready documents."
        case .billing:
            "Build the estimate or invoice and review documents linked to this job."
        case .closeout:
            "Resolve readiness items, complete the checklist, and finish the job."
        }
    }

    static func recommended(
        for status: JobStatus,
        hasInvoice: Bool,
        invoiceIsPaid: Bool
    ) -> JobDocumentationStage {
        if hasInvoice {
            return invoiceIsPaid ? .closeout : .billing
        }
        if status == .completed || status == .invoiced {
            return .closeout
        }
        return .work
    }
}

private enum DocumentationCatalogFilter: String, CaseIterable, Identifiable {
    case recommended
    case service
    case materials
    case selected
    case all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recommended:
            return "Recommended"
        case .service:
            return "Services"
        case .materials:
            return "Materials"
        case .selected:
            return "Selected"
        case .all:
            return "All"
        }
    }
}

enum BillingInitialCloseoutPolicy {
    enum Decision: Equatable {
        case none
        case present(invoiceID: UUID, autoStartTapToPay: Bool)
        case rejected(String)
    }

    static func resolve(
        openCloseout: Bool,
        autoStartTapToPay: Bool,
        canCollectPayment: Bool,
        invoiceID: UUID?,
        hasBalanceDue: Bool,
        paymentCollectionBlockedMessage: String? = nil
    ) -> Decision {
        guard openCloseout else { return .none }
        guard canCollectPayment else {
            return .rejected("Your business account cannot collect invoice payments.")
        }
        guard let invoiceID else {
            return .rejected("This job does not have an invoice to collect yet.")
        }
        if let paymentCollectionBlockedMessage {
            return .rejected(paymentCollectionBlockedMessage)
        }
        guard hasBalanceDue else {
            return .rejected("This invoice is already paid. No collection is needed.")
        }
        return .present(invoiceID: invoiceID, autoStartTapToPay: autoStartTapToPay)
    }
}

private struct RecordInvoicePaymentView: View {
    @AppStorage("requireCustomerSignature") private var requireCustomerSignature = true
    @AppStorage("enableOnsitePayments") private var enableOnsitePayments = false
    @AppStorage("onsitePaymentProcessor") private var onsitePaymentProcessor = OnsitePaymentProcessor.none.rawValue

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var serviceCalls: [ServiceCall]
    @Query private var payments: [Payment]
    @Query private var attachments: [ServiceDocumentAttachment]
    @Query(sort: \Item.name, order: .forward) private var catalogItems: [Item]

    let invoice: Invoice
    let autoStartTapToPay: Bool
    @StateObject private var onsitePaymentManager = OnsitePaymentManager.shared
    @State private var amount: String
    @State private var shouldRecordPayment: Bool
    @State private var method = "card"
    @State private var completionNotes = ""
    @State private var signatureName = ""
    @State private var signatureStrokes: [[CGPoint]] = []
    @State private var cardLast4 = ""
    @State private var authorizationCode = ""
    @State private var paymentNotes = ""
    @State private var tapToPayMessage = ""
    @State private var didTriggerAutoTapToPay = false
    @State private var isProcessingQuickBooksPayment = false
    @State private var processCardWithQuickBooks = false
    @State private var cardholderName = ""
    @State private var cardNumber = ""
    @State private var expirationMonth = ""
    @State private var expirationYear = ""
    @State private var cardCVC = ""
    @State private var billingPostalCode = ""
    @State private var achAccountHolderName = ""
    @State private var achAccountNumber = ""
    @State private var achRoutingNumber = ""
    @State private var achPhone = ""
    @State private var achCheckNumber = ""
    @State private var achAccountType: QuickBooksBankAccountType = .businessChecking

    init(invoice: Invoice, autoStartTapToPay: Bool = false) {
        self.invoice = invoice
        self.autoStartTapToPay = autoStartTapToPay
        _amount = State(initialValue: String(format: "%.2f", invoice.amount))
        _shouldRecordPayment = State(initialValue: !Invoice.isPaid(invoice, payments: []))
        _completionNotes = State(initialValue: invoice.completionNotes ?? "")
        _signatureName = State(initialValue: invoice.customerSignatureName ?? "")
    }

    private var hasSignatureDrawing: Bool {
        !signatureStrokes.flatMap { $0 }.isEmpty
    }

    private var hasCapturedSignature: Bool {
        hasSignatureDrawing || invoice.customerSignatureImageBase64 != nil
    }

    private var balanceDue: Double {
        Invoice.outstandingBalance(for: invoice, payments: payments)
    }

    private var paidAmountRecorded: Double {
        max(invoice.amount - balanceDue, 0)
    }

    private var selectedProcessor: OnsitePaymentProcessor {
        OnsitePaymentProcessor(rawValue: onsitePaymentProcessor) ?? .none
    }

    private var quickBooksPaymentsEnabled: Bool {
        QuickBooksDataAPI.shared.canUseQuickBooksPaymentsAPI
    }

    private var linkedServiceCall: ServiceCall? {
        if let serviceCallID = invoice.serviceCallID,
           let call = serviceCalls.first(where: { $0.id == serviceCallID }) {
            return call
        }
        return serviceCalls.first { $0.linkedInvoiceID == invoice.id }
    }

    private var invoiceDocumentationStatus: InvoiceDocumentationStatus? {
        linkedServiceCall?.invoiceDocumentationStatus(invoice: invoice, attachments: attachments)
    }

    private var closeoutPaymentFormIsValid: Bool {
        guard shouldRecordPayment else { return true }
        if method == "card", quickBooksPaymentsEnabled {
            return !cardholderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                cardNumber.filter(\.isNumber).count >= 12 &&
                expirationMonth.filter(\.isNumber).count >= 1 &&
                expirationYear.filter(\.isNumber).count == 4 &&
                cardCVC.filter(\.isNumber).count >= 3
        }
        if method == "ach", quickBooksPaymentsEnabled {
            return !achAccountHolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                achAccountHolderName.trimmingCharacters(in: .whitespacesAndNewlines).count <= 64 &&
                (4...17).contains(achAccountNumber.filter(\.isNumber).count) &&
                achRoutingNumber.filter(\.isNumber).count == 9 &&
                achPhone.filter(\.isNumber).count == 10
        }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Invoice") {
                    Text(invoice.customer.name)
                    Text(invoice.amount, format: .currency(code: "USD"))
                    Text("Balance due: \(balanceDue, format: .currency(code: "USD"))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if let quickBooksID = invoice.quickBooksID, !quickBooksID.isEmpty {
                        Text("QuickBooks ID: \(quickBooksID)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if let invoiceDocumentationStatus {
                    Section("Documentation") {
                        Label(
                            invoiceDocumentationStatus.statusLabel,
                            systemImage: invoiceDocumentationStatus.isReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                        )
                        .foregroundColor(invoiceDocumentationStatus.isReady ? .green : .orange)
                        Text(invoiceDocumentationStatus.summary)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(invoiceDocumentationStatus.actionSummary)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section("Completion") {
                    TextField("Completion notes", text: $completionNotes, axis: .vertical)
                        .lineLimit(2...4)
                    TextField("Customer signature name", text: $signatureName)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Customer signature")
                            .font(.subheadline)
                        SignaturePad(strokes: $signatureStrokes)
                            .frame(height: 180)
                        HStack {
                            if invoice.customerSignatureImageBase64 != nil || hasSignatureDrawing {
                                Text(hasSignatureDrawing ? "Signature captured for this closeout." : "A saved signature already exists for this invoice.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("Clear") {
                                signatureStrokes = []
                            }
                            .font(.caption)
                        }
                    }
                    if requireCustomerSignature {
                        Text("A customer name and signature are required before finalizing this invoice.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section("Payment") {
                    Toggle("Record payment now", isOn: $shouldRecordPayment)
                    if shouldRecordPayment {
                        TextField("Amount", text: $amount)
                            .keyboardType(.decimalPad)
                        Picker("Method", selection: $method) {
                            Text("Card").tag("card")
                            Text("ACH").tag("ach")
                            Text("Cash").tag("cash")
                            Text("Check").tag("check")
                        }
                        if method == "card" {
                            if enableOnsitePayments && OnsitePaymentManager.shared.tapToPayAvailableInCurrentBuild {
                                Button(onsitePaymentManager.isProcessing ? "Processing Tap to Pay on iPhone..." : "Start Tap to Pay on iPhone") {
                                    Task {
                                        await runTapToPay()
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Color.brandGold)
                                .foregroundStyle(Color.primaryBlack)
                                .disabled(onsitePaymentManager.isProcessing || Double(amount) == nil || selectedProcessor == .none)

                                if !tapToPayMessage.isEmpty {
                                    Text(tapToPayMessage)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }

                            if quickBooksPaymentsEnabled {
                                Text("QuickBooks card processing")
                                    .font(.subheadline.weight(.semibold))
                                TextField("Cardholder name", text: $cardholderName)
                                SecureField("Card number", text: $cardNumber)
                                    .keyboardType(.numberPad)
                                    .privacySensitive()
                                HStack {
                                    TextField("Exp MM", text: $expirationMonth)
                                        .keyboardType(.numberPad)
                                    TextField("Exp YYYY", text: $expirationYear)
                                        .keyboardType(.numberPad)
                                    SecureField("CVC", text: $cardCVC)
                                        .keyboardType(.numberPad)
                                        .privacySensitive()
                                }
                                TextField("Billing ZIP", text: $billingPostalCode)
                                    .keyboardType(.numbersAndPunctuation)
                                Text("Card details are only used to create a QuickBooks Payments token for this transaction and are not saved locally.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                TextField("Card last 4", text: $cardLast4)
                                    .keyboardType(.numberPad)
                                TextField("Authorization ref", text: $authorizationCode)
                                Text(Config.QuickBooks.enablePaymentsScope ? "QuickBooks Payments is not connected. This card entry will only record a manual payment note." : "QuickBooks Payments scope is disabled. This card entry will only record a manual payment note.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        if method == "ach", quickBooksPaymentsEnabled {
                            TextField("Account holder name", text: $achAccountHolderName)
                            SecureField("Bank account number", text: $achAccountNumber)
                                .keyboardType(.numberPad)
                                .privacySensitive()
                            TextField("Routing number", text: $achRoutingNumber)
                                .keyboardType(.numberPad)
                            TextField("Phone", text: $achPhone)
                                .keyboardType(.phonePad)
                            Picker("Account type", selection: $achAccountType) {
                                ForEach(QuickBooksBankAccountType.allCases) { type in
                                    Text(type.displayName).tag(type)
                                }
                            }
                            TextField("Check number (optional)", text: $achCheckNumber)
                                .keyboardType(.numbersAndPunctuation)
                            Text("Bank details are only used to create a QuickBooks Payments token for this ACH/eCheck transaction and are not saved locally.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        TextField("Payment notes", text: $paymentNotes, axis: .vertical)
                            .lineLimit(2...4)
                        if enableOnsitePayments && OnsitePaymentManager.shared.tapToPayAvailableInCurrentBuild {
                            Text(onsitePaymentManager.processorStatusDetail())
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text("Finalize the documentation now and leave the invoice open for later collection.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Finalize Invoice")
            .onAppear {
                loadSuggestedCloseoutValues()
                triggerAutoTapToPayIfNeeded()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isProcessingQuickBooksPayment ? "Processing..." : (shouldRecordPayment ? "Save" : "Finalize")) {
                        Task {
                            await savePayment()
                        }
                    }
                    .disabled(
                        (shouldRecordPayment && (!closeoutPaymentFormIsValid || Double(amount) == nil)) ||
                        isProcessingQuickBooksPayment ||
                        (requireCustomerSignature &&
                         (signatureName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !hasCapturedSignature))
                    )
                }
            }
        }
    }

    private func loadSuggestedCloseoutValues() {
        if shouldRecordPayment {
            amount = String(format: "%.2f", balanceDue > 0 ? balanceDue : invoice.amount)
        }
        cardholderName = invoice.customer.name
        processCardWithQuickBooks = quickBooksPaymentsEnabled && method == "card"
        achAccountHolderName = invoice.customer.name
        achAccountNumber = ""
        achRoutingNumber = ""
        achPhone = invoice.customer.phone ?? ""
        achCheckNumber = ""
        achAccountType = .businessChecking
    }

    private func runTapToPay() async {
        guard let amountValue = Double(amount), amountValue > 0 else {
            tapToPayMessage = "Enter a valid amount before starting Tap to Pay on iPhone."
            return
        }

        do {
            let result = try await onsitePaymentManager.startTapToPay(amount: amountValue, customerName: invoice.customer.name)
            cardLast4 = result.cardLast4
            authorizationCode = result.authorizationCode
            paymentNotes = result.paymentSummary
            tapToPayMessage = "\(result.processorName) approved \(result.amount.formatted(.currency(code: "USD")))."
        } catch {
            tapToPayMessage = error.localizedDescription
        }
    }

    private func triggerAutoTapToPayIfNeeded() {
        guard autoStartTapToPay, !didTriggerAutoTapToPay else { return }
        guard shouldRecordPayment, method == "card" else { return }
        guard selectedProcessor.supportsTapToPay, onsitePaymentManager.processorReady() else { return }
        didTriggerAutoTapToPay = true
        Task {
            await runTapToPay()
        }
    }

    private func savePayment() async {
        let paidAmount = shouldRecordPayment ? (Double(amount) ?? 0) : 0
        guard !shouldRecordPayment || paidAmount > 0 else { return }
        let previousPaidAmount = paidAmountRecorded
        let trimmedSignatureName = signatureName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCompletionNotes = completionNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCardLast4 = cardLast4.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAuthorization = authorizationCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPaymentNotes = paymentNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBillingPostalCode = billingPostalCode.trimmingCharacters(in: .whitespacesAndNewlines)

        invoice.customerSignatureName = trimmedSignatureName.isEmpty ? nil : trimmedSignatureName
        invoice.customerSignatureImageBase64 = signatureImageBase64()
        invoice.customerSignedAt = invoice.customerSignatureName == nil ? nil : Date()
        invoice.completionNotes = trimmedCompletionNotes.isEmpty ? nil : trimmedCompletionNotes
        invoice.finalizedAt = Date()
        var recordedPayment: Payment?

        if shouldRecordPayment {
            if method == "card", quickBooksPaymentsEnabled {
                isProcessingQuickBooksPayment = true
                defer { isProcessingQuickBooksPayment = false }

                do {
                    let localPaymentID = UUID()
                    let result = try await QuickBooksPaymentsService.shared.processCardPayment(
                        localPaymentID: localPaymentID,
                        invoice: invoice,
                        amount: paidAmount,
                        cardInput: QuickBooksPaymentsCardInput(
                            cardholderName: cardholderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? invoice.customer.name : cardholderName.trimmingCharacters(in: .whitespacesAndNewlines),
                            cardNumber: cardNumber.filter(\.isNumber),
                            expMonth: expirationMonth.filter(\.isNumber),
                            expYear: expirationYear.filter(\.isNumber),
                            cvc: cardCVC.filter(\.isNumber),
                            postalCode: trimmedBillingPostalCode.isEmpty ? nil : trimmedBillingPostalCode,
                            addressLine: invoice.customer.address,
                            city: nil,
                            region: nil,
                            country: "US"
                        ),
                        note: trimmedPaymentNotes.isEmpty ? nil : trimmedPaymentNotes,
                        catalogItems: catalogItems
                    )

                    let resolvedCardLast4: String?
                    if !trimmedCardLast4.isEmpty {
                        resolvedCardLast4 = trimmedCardLast4
                    } else if let masked = result.charge.card?.number?.suffix(4) {
                        resolvedCardLast4 = String(masked)
                    } else {
                        resolvedCardLast4 = nil
                    }

                    let payment = Payment(
                        id: localPaymentID,
                        invoice: invoice,
                        quickBooksID: result.accountingPayment?.Id,
                        quickBooksChargeID: result.charge.id,
                        quickBooksClientTransID: result.clientTransactionID,
                        quickBooksAccountingSyncStatus: result.accountingError == nil ? "synced" : "needs_attention",
                        quickBooksAccountingSyncDetail: result.accountingError,
                        amount: paidAmount,
                        method: "card",
                        cardLast4: resolvedCardLast4,
                        authorizationReference: result.charge.authCode ?? (trimmedAuthorization.isEmpty ? nil : trimmedAuthorization),
                        notes: trimmedPaymentNotes.isEmpty ? nil : trimmedPaymentNotes,
                        processor: OnsitePaymentProcessor.quickBooksPayments.rawValue
                    )
                    modelContext.insert(payment)
                    recordedPayment = payment

                    if let accountingError = result.accountingError {
                        tapToPayMessage = "Charge captured, but accounting sync still needs attention: \(accountingError)"
                    }
                } catch {
                    tapToPayMessage = error.localizedDescription
                    return
                }
            } else if method == "ach", quickBooksPaymentsEnabled {
                isProcessingQuickBooksPayment = true
                defer { isProcessingQuickBooksPayment = false }

                do {
                    let localPaymentID = UUID()
                    let result = try await QuickBooksPaymentsService.shared.processBankPayment(
                        localPaymentID: localPaymentID,
                        invoice: invoice,
                        amount: paidAmount,
                        bankInput: QuickBooksPaymentsBankAccountInput(
                            accountHolderName: achAccountHolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? invoice.customer.name : achAccountHolderName.trimmingCharacters(in: .whitespacesAndNewlines),
                            accountNumber: achAccountNumber.filter(\.isNumber),
                            routingNumber: achRoutingNumber.filter(\.isNumber),
                            phone: achPhone.filter(\.isNumber),
                            accountType: achAccountType,
                            checkNumber: achCheckNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : achCheckNumber.trimmingCharacters(in: .whitespacesAndNewlines)
                        ),
                        note: trimmedPaymentNotes.isEmpty ? nil : trimmedPaymentNotes,
                        catalogItems: catalogItems
                    )

                    let payment = Payment(
                        id: localPaymentID,
                        invoice: invoice,
                        quickBooksID: result.accountingPayment?.Id,
                        quickBooksChargeID: result.charge.id,
                        quickBooksClientTransID: result.clientTransactionID,
                        quickBooksAccountingSyncStatus: result.accountingError == nil ? "synced" : "needs_attention",
                        quickBooksAccountingSyncDetail: result.accountingError,
                        amount: paidAmount,
                        method: "ach",
                        authorizationReference: result.charge.authCode ?? (trimmedAuthorization.isEmpty ? nil : trimmedAuthorization),
                        notes: trimmedPaymentNotes.isEmpty ? nil : trimmedPaymentNotes,
                        processor: OnsitePaymentProcessor.quickBooksPayments.rawValue
                    )
                    modelContext.insert(payment)
                    recordedPayment = payment

                    if let accountingError = result.accountingError {
                        tapToPayMessage = "ACH payment submitted, but accounting sync still needs attention: \(accountingError)"
                    }
                } catch {
                    tapToPayMessage = error.localizedDescription
                    return
                }
            } else {
            let recordedMethod: String
            if method == "card", !trimmedCardLast4.isEmpty {
                recordedMethod = trimmedAuthorization.isEmpty ? "card ••••\(trimmedCardLast4)" : "card ••••\(trimmedCardLast4) auth \(trimmedAuthorization)"
            } else {
                recordedMethod = method
            }

            let payment = Payment(
                invoice: invoice,
                amount: paidAmount,
                method: recordedMethod,
                cardLast4: trimmedCardLast4.isEmpty ? nil : trimmedCardLast4,
                authorizationReference: trimmedAuthorization.isEmpty ? nil : trimmedAuthorization,
                notes: trimmedPaymentNotes.isEmpty ? nil : trimmedPaymentNotes,
                processor: method == "card"
                    ? (authorizationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "manual-entry" : selectedProcessor.rawValue)
                    : "onsite-recorded"
            )
            modelContext.insert(payment)
            recordedPayment = payment
            }
        }

        let totalPaid = previousPaidAmount + paidAmount
        if totalPaid >= invoice.amount {
            invoice.status = "paid"
        } else if totalPaid > 0 {
            invoice.status = "partial"
        } else {
            invoice.status = "unpaid"
        }
        if shouldRecordPayment {
            invoice.applyLocalPaymentAmount(paidAmount)
        }

        if let serviceCallID = invoice.serviceCallID,
           let call = serviceCalls.first(where: { $0.id == serviceCallID }) {
            let previousStatus = call.status
            call.markDocumentationCompleteIfReady()
            call.workCompletedChecklist = true
            call.paymentCollectedChecklist = totalPaid > 0
            call.status = Invoice.isPaid(invoice, payments: payments.filter { $0.invoice.id == invoice.id }) ? .completed : .invoiced
            if call.status == .completed {
                call.completeLinkedMaintenanceAgreementIfNeeded()
            }
            let paymentOutcome = Invoice.isPaid(invoice, payments: payments.filter { $0.invoice.id == invoice.id }) ? "paid in full" : "recorded with an outstanding balance"
            ServiceCallActivity.record(for: call, action: "Payment recorded", detail: "Payment \(paymentOutcome); job status changed from \(previousStatus.rawValue) to \(call.status.rawValue).", actorEmail: AppIdentity.currentEmail, in: modelContext)
            if !trimmedCompletionNotes.isEmpty {
                call.notes = mergedJobNotes(existing: call.notes, completionNotes: trimmedCompletionNotes)
            }
        }

        if let recordedPayment {
            await queueCloseoutPaymentWithBackend(recordedPayment)
        }

        dismiss()
    }

    private func queueCloseoutPaymentWithBackend(_ payment: Payment) async {
        guard GunnAireBackendService.isConfigured else {
            payment.markSharedCompanyQueueUnavailable()
            try? modelContext.save()
            return
        }
        do {
            _ = try await GunnAireBackendService.uploadPaymentCollection(payment)
            payment.markSharedCompanyQueued()
        } catch {
            payment.markSharedCompanyQueueFailed(error.localizedDescription)
        }
        try? modelContext.save()
    }

    private func signatureImageBase64() -> String? {
        guard let image = SignatureRenderer.image(from: signatureStrokes) else { return invoice.customerSignatureImageBase64 }
        return image.pngData()?.base64EncodedString()
    }

    private func mergedJobNotes(existing: String?, completionNotes: String) -> String {
        let trimmedExisting = existing?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedExisting.isEmpty {
            return completionNotes
        }
        if trimmedExisting.localizedCaseInsensitiveContains(completionNotes) {
            return trimmedExisting
        }
        return "\(trimmedExisting)\n\nCloseout Notes:\n\(completionNotes)"
    }
}

private struct DocumentationItemSelectorView: View {
    @Environment(\.dismiss) private var dismiss

    let items: [Item]
    let selectedItems: Set<UUID>
    let selectedItemizedAssemblyIDs: Set<UUID>
    let documentScopedReviewItemIDs: Set<UUID>
    let onToggle: (Item) -> Void

    @State private var searchText = ""
    @State private var expandedItemTypes = Set(CatalogItemType.allCases)

    private var filteredItems: [Item] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sortedItems = items
            .filter {
                CatalogItemSelectionPolicy.canDisplay(
                    $0,
                    isSelected: isSelected($0),
                    documentScopedReviewItemIDs: documentScopedReviewItemIDs
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !query.isEmpty else { return sortedItems }
        return sortedItems.filter { item in
            [
                item.name,
                item.sku,
                item.itemDescription,
                item.preferredVendorName,
                item.vendorPartNumber,
                item.purchaseDescription
            ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
            .contains(query)
        }
    }

    private var groupedItems: [(type: CatalogItemType, items: [Item])] {
        CatalogItemType.allCases.compactMap { type in
            let matches = filteredItems.filter { $0.itemType == type }
            return matches.isEmpty ? nil : (type, matches)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if filteredItems.isEmpty {
                    Text("No matching items.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(groupedItems, id: \.type) { group in
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { expandedItemTypes.contains(group.type) },
                                set: { isExpanded in
                                    if isExpanded {
                                        expandedItemTypes.insert(group.type)
                                    } else {
                                        expandedItemTypes.remove(group.type)
                                    }
                                }
                            )
                        ) {
                            ForEach(group.items) { item in
                                itemRow(item)
                            }
                        } label: {
                            HStack {
                                Text(group.type.rawValue)
                                Spacer()
                                Text("\(selectedCount(in: group.items))/\(group.items.count)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Select Items")
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Text("\(selectedItems.count) lines selected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func selectedCount(in groupItems: [Item]) -> Int {
        groupItems.filter(isSelected).count
    }

    private func isSelected(_ item: Item) -> Bool {
        if item.assemblyDefinition?.presentation == .itemized {
            return selectedItemizedAssemblyIDs.contains(item.id)
        }
        return selectedItems.contains(item.id)
    }

    private func itemRow(_ item: Item) -> some View {
        Button {
            onToggle(item)
        } label: {
            HStack {
                Image(systemName: isSelected(item) ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(Color.brandGold)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.headline)
                    if let description = item.itemDescription, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    let meta = [
                        item.sku.map { "SKU \($0)" },
                        item.preferredVendorName,
                        item.vendorPartNumber.map { "Vendor # \($0)" }
                    ]
                    .compactMap { value in
                        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                        return trimmed?.isEmpty == false ? trimmed : nil
                    }
                    if !meta.isEmpty {
                        Text(meta.joined(separator: " • "))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    if let definition = item.assemblyDefinition {
                        Label(
                            "\(definition.presentation.label) package • \(definition.components.count) included",
                            systemImage: "shippingbox"
                        )
                        .font(.caption2)
                        .foregroundStyle(Color.brandGold)
                        .accessibilityIdentifier("ItemAssemblyContext-\(item.id.uuidString)")
                    }
                    Text(item.isTaxable ? "Taxable" : "Non-taxable")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if item.isCatalogArchived {
                        Label("Archived • remove only", systemImage: "archivebox")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(item.unitPrice, format: .currency(code: "USD"))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct LinePriceAdjustmentSheet: View {
    @Environment(\.dismiss) private var dismiss

    let item: Item
    let existingAdjustment: AuthorizedLinePriceAdjustment?
    let onAuthorize: (Double, String) -> String?
    let onRemove: () -> Void

    @State private var unitPriceText: String
    @State private var reason: String
    @State private var validationMessage: String?

    init(
        item: Item,
        existingAdjustment: AuthorizedLinePriceAdjustment?,
        onAuthorize: @escaping (Double, String) -> String?,
        onRemove: @escaping () -> Void
    ) {
        self.item = item
        self.existingAdjustment = existingAdjustment
        self.onAuthorize = onAuthorize
        self.onRemove = onRemove
        _unitPriceText = State(initialValue: String(format: "%.2f", existingAdjustment?.unitPrice ?? item.unitPrice))
        _reason = State(initialValue: existingAdjustment?.reason ?? "")
    }

    private var parsedUnitPrice: Double? {
        CatalogItemAmountParser.parse(unitPriceText)
    }

    private var canAuthorize: Bool {
        parsedUnitPrice != nil &&
        reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false &&
        reason.count <= 240
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Line Item") {
                    LabeledContent("Item", value: item.name)
                    LabeledContent("Pricebook Price", value: item.unitPrice.formatted(.currency(code: "USD")))
                    TextField("Adjusted unit price", text: $unitPriceText)
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("PriceAdjustmentUnitPrice")
                    TextField("Business reason", text: $reason, axis: .vertical)
                        .lineLimit(2...4)
                        .accessibilityIdentifier("PriceAdjustmentReason")
                    Text("This adjustment applies only to this estimate or invoice. The shared pricebook remains unchanged.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let existingAdjustment {
                    Section("Authorization") {
                        LabeledContent("Authorized By", value: existingAdjustment.authorizedByEmail)
                        LabeledContent(
                            "Authorized At",
                            value: existingAdjustment.authorizedAt.formatted(date: .abbreviated, time: .shortened)
                        )
                        Button("Remove Adjustment", role: .destructive) {
                            onRemove()
                            dismiss()
                        }
                    }
                }

                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Discount or Adjust")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Authorize Price") {
                        guard let parsedUnitPrice else { return }
                        if let errorMessage = onAuthorize(parsedUnitPrice, reason) {
                            validationMessage = errorMessage
                        } else {
                            dismiss()
                        }
                    }
                    .disabled(!canAuthorize)
                }
            }
        }
    }
}

private struct DocumentDiscountSheet: View {
    @Environment(\.dismiss) private var dismiss

    let grossSubtotal: Double
    let existingDiscount: AuthorizedDocumentDiscount?
    let onAuthorize: (BillingDocumentDiscountKind, Double, String) -> String?
    let onRemove: () -> Void

    @State private var kind: BillingDocumentDiscountKind
    @State private var valueText: String
    @State private var reason: String
    @State private var validationMessage: String?

    init(
        grossSubtotal: Double,
        existingDiscount: AuthorizedDocumentDiscount?,
        onAuthorize: @escaping (BillingDocumentDiscountKind, Double, String) -> String?,
        onRemove: @escaping () -> Void
    ) {
        self.grossSubtotal = grossSubtotal
        self.existingDiscount = existingDiscount
        self.onAuthorize = onAuthorize
        self.onRemove = onRemove
        let initialKind = existingDiscount?.kind ?? .percentage
        _kind = State(initialValue: initialKind)
        _valueText = State(
            initialValue: existingDiscount.map {
                $0.value.formatted(.number.precision(.fractionLength(0...2)))
            } ?? ""
        )
        _reason = State(initialValue: existingDiscount?.reason ?? "")
    }

    private var parsedValue: Double? {
        CatalogItemAmountParser.parse(valueText)
    }

    private var canAuthorize: Bool {
        parsedValue.map { $0 > 0 } == true &&
        reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false &&
        reason.count <= 240
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Document Discount") {
                    LabeledContent("Items Subtotal", value: grossSubtotal.formatted(.currency(code: "USD")))
                    Picker("Discount Type", selection: $kind) {
                        ForEach(BillingDocumentDiscountKind.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("DocumentDiscountKind")

                    TextField(kind == .percentage ? "Percent" : "Amount", text: $valueText)
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("DocumentDiscountValue")
                    TextField("Customer-visible reason", text: $reason, axis: .vertical)
                        .lineLimit(2...4)
                        .accessibilityIdentifier("DocumentDiscountReason")
                    Text("The discount is locked to this exact set of lines. Editing quantity or price requires administrator reauthorization.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let existingDiscount {
                    Section("Authorization") {
                        LabeledContent(
                            "Authorized",
                            value: existingDiscount.authorizedAt.formatted(date: .abbreviated, time: .shortened)
                        )
                        Button("Remove Document Discount", role: .destructive) {
                            onRemove()
                            dismiss()
                        }
                    }
                }

                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle(existingDiscount == nil ? "Add Discount" : "Edit Discount")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Authorize") {
                        guard let parsedValue else { return }
                        if let errorMessage = onAuthorize(kind, parsedValue, reason) {
                            validationMessage = errorMessage
                        } else {
                            dismiss()
                        }
                    }
                    .disabled(!canAuthorize)
                    .accessibilityIdentifier("AuthorizeDocumentDiscount")
                }
            }
        }
        .frame(minWidth: 500, minHeight: 520)
    }
}

private enum CatalogItemAmountParser {
    static func parse(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized = trimmed
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")

        if normalized.hasPrefix("("), normalized.hasSuffix(")") {
            let start = normalized.index(after: normalized.startIndex)
            let end = normalized.index(before: normalized.endIndex)
            return Double(String(normalized[start..<end])).map { -$0 }
        }

        return Double(normalized)
    }

    static func parseRequiredOrZero(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return parse(trimmed)
    }

    static func parseOptional(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return parse(trimmed)
    }

    static func isValidOptionalAmount(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || parse(trimmed) != nil
    }
}

enum PricebookPublicationError: LocalizedError, Equatable {
    case reviewRequired(String)
    case archived(String)
    case inactiveQuickBooksMatch(String)

    var errorDescription: String? {
        switch self {
        case .reviewRequired(let itemName):
            return "\(itemName) needs administrator pricebook review before it can publish to QuickBooks. The document remains saved locally."
        case .archived(let itemName):
            return "\(itemName) is archived from new work. Restore and reconcile it or replace the document line before publishing to QuickBooks."
        case .inactiveQuickBooksMatch(let itemName):
            return "\(itemName) matches an inactive QuickBooks item. The existing identity was linked safely; an administrator must review its staged reactivation before this document can publish."
        }
    }
}

enum CatalogVendorSelection {
    static func options(for vendors: [Vendor]) -> [SearchableDropdownOption] {
        vendors
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { vendor in
                let contactInfo = vendor.contactInfo?.trimmingCharacters(in: .whitespacesAndNewlines)
                return SearchableDropdownOption(
                    id: vendor.id.uuidString,
                    title: vendor.name,
                    subtitle: contactInfo?.isEmpty == false ? contactInfo :
                        vendor.quickBooksID.map { "QBO \($0)" }
                )
            }
    }

    static func selectedVendorID(vendorName: String?, vendors: [Vendor]) -> String? {
        guard let vendorName = vendorName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !vendorName.isEmpty else { return nil }
        return vendors.first { $0.name.caseInsensitiveCompare(vendorName) == .orderedSame }?.id.uuidString
    }

    static func quickBooksID(vendorName: String?, vendors: [Vendor]) -> String? {
        guard let vendorName = vendorName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !vendorName.isEmpty else { return nil }
        return vendors.first { $0.name.caseInsensitiveCompare(vendorName) == .orderedSame }?.quickBooksID
    }
}

enum BillingInvoiceMutationPolicy {
    static func blockedMessage(for invoice: Invoice, payments: [Payment]) -> String? {
        if invoice.isProjectProgressInvoice {
            return "Progress-invoice lines are locked to the approved milestone allocation. Correct the project plan before invoicing, or create a separate approved adjustment."
        }
        if invoice.finalizedAt != nil || invoice.customerSignedAt != nil {
            return "This invoice is finalized or customer-signed. Create an approved adjustment instead of changing its line items."
        }

        let relatedPayments = payments.filter { $0.invoice.id == invoice.id }
        let netPaymentAmount = relatedPayments.reduce(0.0) { partial, payment in
            partial + (payment.isRefund ? -payment.amount : payment.amount)
        }
        let normalizedStatus = invoice.normalizedStatus
        let quickBooksShowsPartialPayment: Bool
        if let balance = invoice.quickBooksBalanceDue,
           invoice.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
           invoice.quickBooksSyncState == "synced" {
            quickBooksShowsPartialPayment = balance < invoice.amount - 0.009
        } else {
            quickBooksShowsPartialPayment = false
        }

        if abs(netPaymentAmount) > 0.009 ||
            normalizedStatus == "paid" ||
            normalizedStatus == "partial" ||
            quickBooksShowsPartialPayment {
            return "This invoice has payment activity. Add a separate adjustment or change order so payment and reconciliation history stay intact."
        }

        return nil
    }
}

enum BillingInvoiceQueueBuilder {
    static let defaultCollectionsLimit = 8

    static func collectibleInvoices(from invoices: [Invoice], payments: [Payment]) -> [Invoice] {
        invoices.filter { invoice in
            invoice.isReadyForPaymentCollection &&
                Invoice.outstandingBalance(for: invoice, payments: payments) > 0.009
        }
    }

    static func collectionsQueue(
        from invoices: [Invoice],
        payments: [Payment],
        limit: Int = defaultCollectionsLimit
    ) -> [Invoice] {
        collectionsQueue(
            from: collectibleInvoices(from: invoices, payments: payments),
            limit: limit
        )
    }

    static func collectionsQueue(
        from collectibleInvoices: [Invoice],
        limit: Int = defaultCollectionsLimit
    ) -> [Invoice] {
        Array(collectibleInvoices.prefix(max(0, limit)))
    }

    static func overdueInvoices(
        from invoices: [Invoice],
        payments: [Payment],
        now: Date = Date()
    ) -> [Invoice] {
        invoices.filter { isOverdue($0, payments: payments, now: now) }
    }

    static func overdueQueueExcludingCollections(
        overdueInvoices: [Invoice],
        collectionsQueue: [Invoice]
    ) -> [Invoice] {
        let collectionIDs = Set(collectionsQueue.map(\.id))
        return overdueInvoices.filter { !collectionIDs.contains($0.id) }
    }

    static func isOverdue(
        _ invoice: Invoice,
        payments: [Payment],
        now: Date = Date()
    ) -> Bool {
        Invoice.isOverdue(invoice, payments: payments, now: now)
    }
}

private struct DocumentationItemCreatorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let vendors: [Vendor]
    let requiresPricebookReview: Bool
    let createdByEmail: String?
    let onCreated: (Item) -> Void

    @State private var name: String
    @State private var itemType: CatalogItemType = .service
    @State private var sku = ""
    @State private var description = ""
    @State private var price = ""
    @State private var cost = ""
    @State private var preferredVendor = ""
    @State private var vendorPartNumber = ""
    @State private var purchaseURL = ""
    @State private var purchaseDescription = ""
    @State private var isTaxable = false
    @State private var creationMessage = ""
    @FocusState private var isEditing: Bool

    private var vendorDropdownOptions: [SearchableDropdownOption] {
        CatalogVendorSelection.options(for: vendors)
    }

    private var selectedVendorDropdownID: Binding<String?> {
        Binding(
            get: {
                CatalogVendorSelection.selectedVendorID(
                    vendorName: preferredVendor,
                    vendors: vendors
                )
            },
            set: { selectedID in
                guard let selectedID else {
                    preferredVendor = ""
                    return
                }
                if let vendor = vendors.first(where: { $0.id.uuidString == selectedID }) {
                    preferredVendor = vendor.name
                }
            }
        )
    }

    init(
        initialName: String = "",
        vendors: [Vendor] = [],
        requiresPricebookReview: Bool = false,
        createdByEmail: String? = nil,
        onCreated: @escaping (Item) -> Void
    ) {
        self.vendors = vendors
        self.requiresPricebookReview = requiresPricebookReview
        self.createdByEmail = createdByEmail
        self.onCreated = onCreated
        _name = State(initialValue: initialName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Sales") {
                    TextField("Item name", text: $name)
                        .focused($isEditing)
                    TextField("SKU", text: $sku)
                        .textInputAutocapitalization(.characters)
                        .focused($isEditing)
                    Picker("Item Type", selection: $itemType) {
                        ForEach(CatalogItemType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(2...3)
                        .focused($isEditing)
                    Toggle("Taxable", isOn: $isTaxable)
                    TextField("Sales price (optional)", text: $price)
                        .keyboardType(.decimalPad)
                        .focused($isEditing)
                    if requiresPricebookReview {
                        Label(
                            "This job can use the item now. An administrator must review it before it becomes a reusable QuickBooks catalog item.",
                            systemImage: "person.badge.clock"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Section("Purchasing") {
                    TextField("Purchase price", text: $cost)
                        .keyboardType(.decimalPad)
                        .focused($isEditing)
                    TextField("Typical purchase source", text: $preferredVendor)
                        .focused($isEditing)
                    if !vendors.isEmpty {
                        SearchableDropdownPicker(
                            title: "Saved Vendor",
                            options: vendorDropdownOptions,
                            selectedID: selectedVendorDropdownID,
                            placeholder: "Manual / none",
                            showsClearButton: true
                        )
                    }
                    TextField("Vendor part #", text: $vendorPartNumber)
                        .focused($isEditing)
                    TextField("Purchase URL", text: $purchaseURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .focused($isEditing)
                    TextField("Purchase notes", text: $purchaseDescription, axis: .vertical)
                        .lineLimit(2...3)
                        .focused($isEditing)
                }

                if !creationMessage.isEmpty {
                    Text(creationMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Create Item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveItem()
                    }
                    .disabled(
                        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        CatalogItemAmountParser.parseRequiredOrZero(price) == nil ||
                        !CatalogItemAmountParser.isValidOptionalAmount(cost)
                    )
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isEditing = false }
                        .accessibilityLabel("Done Editing Item")
                }
            }
        }
    }

    private func saveItem() {
        guard let salesPrice = CatalogItemAmountParser.parseRequiredOrZero(price) else { return }
        let preferredVendorName = nonBlank(preferredVendor)
        let preferredVendorQuickBooksID = CatalogVendorSelection.quickBooksID(
            vendorName: preferredVendorName,
            vendors: vendors
        )
        let item = Item(
            quickBooksSyncStatus: requiresPricebookReview ? "needs_review" : nil,
            quickBooksSyncDetail: requiresPricebookReview ? "Administrator pricebook review is required before QuickBooks publication." : nil,
            pricebookReviewStatus: requiresPricebookReview ? .needsReview : .approved,
            pricebookCreatedByEmail: createdByEmail,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            itemType: itemType,
            unitPrice: salesPrice,
            purchaseCost: CatalogItemAmountParser.parseOptional(cost),
            isTaxable: isTaxable,
            itemDescription: nonBlank(description),
            sku: nonBlank(sku),
            preferredVendorName: preferredVendorName,
            preferredVendorQuickBooksID: preferredVendorQuickBooksID,
            vendorPartNumber: nonBlank(vendorPartNumber),
            purchaseURL: nonBlank(purchaseURL),
            purchaseDescription: nonBlank(purchaseDescription)
        )
        modelContext.insert(item)
        do {
            try modelContext.save()
            onCreated(item)
            dismiss()
        } catch {
            creationMessage = "Could not save item: \(error.localizedDescription)"
        }
    }

    private func nonBlank(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct SignaturePad: View {
    @Binding var strokes: [[CGPoint]]

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemBackground))
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4]))
                Path { path in
                    for stroke in strokes where !stroke.isEmpty {
                        path.move(to: stroke[0])
                        for point in stroke.dropFirst() {
                            path.addLine(to: point)
                        }
                    }
                }
                .stroke(Color.primary, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let point = CGPoint(
                            x: min(max(0, value.location.x), geometry.size.width),
                            y: min(max(0, value.location.y), geometry.size.height)
                        )
                        if strokes.isEmpty || value.startLocation == value.location {
                            strokes.append([point])
                        } else if let lastIndex = strokes.indices.last {
                            strokes[lastIndex].append(point)
                        }
                    }
            )
        }
    }
}

enum SignatureRenderer {
    static func image(from strokes: [[CGPoint]], size: CGSize = CGSize(width: 600, height: 240)) -> UIImage? {
        let validStrokes = strokes.filter { !$0.isEmpty }
        guard !validStrokes.isEmpty else { return nil }

        let points = validStrokes.flatMap { $0 }
        guard let minX = points.map(\.x).min(),
              let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(),
              let maxY = points.map(\.y).max() else {
            return nil
        }
        let padding: CGFloat = 18
        let sourceWidth = max(maxX - minX, 1)
        let sourceHeight = max(maxY - minY, 1)
        let scale = min(
            (size.width - padding * 2) / sourceWidth,
            (size.height - padding * 2) / sourceHeight
        )
        let renderedWidth = sourceWidth * scale
        let renderedHeight = sourceHeight * scale
        let offset = CGPoint(
            x: (size.width - renderedWidth) / 2,
            y: (size.height - renderedHeight) / 2
        )

        func renderedPoint(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: offset.x + (point.x - minX) * scale,
                y: offset.y + (point.y - minY) * scale
            )
        }

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.clear.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.black.setStroke()
            let bezier = UIBezierPath()
            bezier.lineWidth = 3
            bezier.lineCapStyle = .round
            bezier.lineJoinStyle = .round

            for stroke in validStrokes {
                guard let first = stroke.first else { continue }
                bezier.move(to: renderedPoint(first))
                for point in stroke.dropFirst() {
                    bezier.addLine(to: renderedPoint(point))
                }
            }

            bezier.stroke()
        }
    }
}

private struct JobDocumentationCameraPicker: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    let onImagePicked: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let parent: JobDocumentationCameraPicker

        init(_ parent: JobDocumentationCameraPicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImagePicked(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

private struct CustomerFinancingHandoffSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let readiness: CustomerFinancingReadiness
    let estimate: Estimate
    let onOpenAccepted: () -> Void

    @State private var openMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Financing Offer") {
                    LabeledContent("Provider") {
                        Text(readiness.validatedProviderName ?? "Unavailable")
                            .accessibilityIdentifier("CustomerFinancingProvider")
                    }
                    LabeledContent("Estimate Total") {
                        Text(estimate.amount, format: .currency(code: "USD"))
                            .accessibilityIdentifier("CustomerFinancingEstimateTotal")
                    }
                    if let host = readiness.providerHost {
                        LabeledContent("Secure Application") {
                            Text(host)
                                .accessibilityIdentifier("CustomerFinancingProviderHost")
                        }
                    }
                    if let amountRangeDetail = readiness.amountRangeDetail {
                        Text(amountRangeDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Before You Continue") {
                    Label(
                        "The customer completes the application directly with the financing provider.",
                        systemImage: "safari"
                    )
                    Label(
                        "GunnAire Ops does not collect or store applicant, credit, underwriting, or decision data.",
                        systemImage: "lock.shield"
                    )
                    Label(
                        "Rates, terms, eligibility, and credit decisions come only from the financing provider.",
                        systemImage: "doc.text.magnifyingglass"
                    )
                    if let openMessage {
                        Text(openMessage)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("CustomerFinancingOpenMessage")
                    }
                }
            }
            .navigationTitle("Customer Financing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Open Secure Application") {
                        openProviderApplication()
                    }
                    .disabled(readiness.validatedApplicationURL == nil)
                    .accessibilityIdentifier("OpenCustomerFinancingApplication")
                }
            }
        }
    }

    private func openProviderApplication() {
        guard let applicationURL = readiness.validatedApplicationURL else {
            openMessage = "The provider application URL is invalid. Ask an administrator to review backend readiness."
            return
        }
        openURL(applicationURL) { accepted in
            Task { @MainActor in
                guard accepted else {
                    openMessage = "This device could not open the provider application. Check browser restrictions and try again."
                    return
                }
                onOpenAccepted()
                dismiss()
            }
        }
    }
}

private enum MaintenanceAgreementBillingWorkflowError: LocalizedError {
    case unauthorizedConfiguration
    case unauthorizedInvoice
    case billingItemUnavailable
    case cycleChanged
    case invoiceConstructionFailed
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .unauthorizedConfiguration:
            "Only an administrator can configure an agreement's accounting item and first billing date."
        case .unauthorizedInvoice:
            "Only Accounting or an administrator can issue maintenance-agreement invoices."
        case .billingItemUnavailable:
            "Choose an administrator-approved pricebook item before billing this agreement."
        case .cycleChanged:
            "This billing cycle changed or was invoiced on another device. Close the review and use the refreshed queue."
        case .invoiceConstructionFailed:
            "The approved agreement line could not be captured for this invoice."
        case .saveFailed(let detail):
            "The agreement invoice was not committed: \(detail)"
        }
    }
}

private struct MaintenanceAgreementBillingSetupSheet: View {
    @Environment(\.dismiss) private var dismiss

    let agreement: RecurringMaintenanceContract
    let billingItems: [Item]
    let onSave: (UUID, Date?) throws -> Void

    @State private var selectedItemID: UUID?
    @State private var anchorDate: Date
    @State private var errorMessage: String?

    init(
        agreement: RecurringMaintenanceContract,
        billingItems: [Item],
        onSave: @escaping (UUID, Date?) throws -> Void
    ) {
        self.agreement = agreement
        self.billingItems = billingItems.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        self.onSave = onSave
        _selectedItemID = State(initialValue: agreement.billingCatalogItemID)
        _anchorDate = State(
            initialValue: agreement.billingAnchorDate
                ?? Calendar.current.startOfDay(for: Date())
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Approved Agreement") {
                    LabeledContent("Customer", value: agreement.customer.name)
                    LabeledContent("Plan", value: agreement.displayName)
                    LabeledContent(
                        "Price",
                        value: (agreement.agreementPrice ?? 0).formatted(.currency(code: "USD"))
                    )
                    LabeledContent("Interval", value: agreement.billingInterval.displayName)
                    Text("The approved customer price and interval cannot be edited here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Accounting Setup") {
                    Picker("Billing item", selection: $selectedItemID) {
                        Text("Select approved item").tag(UUID?.none)
                        ForEach(billingItems) { item in
                            Text("\(item.name) • \(item.unitPrice.formatted(.currency(code: "USD")))")
                                .tag(Optional(item.id))
                        }
                    }
                    .accessibilityIdentifier("AgreementBillingSetupItem")

                    if agreement.billingInterval != .perVisit {
                        DatePicker(
                            "First billing date",
                            selection: $anchorDate,
                            displayedComponents: .date
                        )
                        .accessibilityIdentifier("AgreementBillingSetupDate")
                    } else {
                        Text("A completed agreement-linked maintenance visit releases each per-visit invoice.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("The item provides the QuickBooks product/service mapping. If its price differs, each invoice retains the customer-approved agreement price and audit evidence without changing the company pricebook.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if billingItems.isEmpty {
                    Section {
                        Label(
                            "No approved pricebook items are available. Approve or create the service item in the invoice pricebook first.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Agreement Billing Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(selectedItemID == nil)
                        .accessibilityIdentifier("SaveAgreementBillingSetup")
                }
            }
        }
        .frame(minWidth: 520, minHeight: 500)
    }

    private func save() {
        guard let selectedItemID else {
            errorMessage = "Select an approved billing item."
            return
        }
        do {
            try onSave(
                selectedItemID,
                agreement.billingInterval == .perVisit
                    ? nil
                    : Calendar.current.startOfDay(for: anchorDate)
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct MaintenanceAgreementInvoiceReviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    let agreement: RecurringMaintenanceContract
    let candidate: MaintenanceAgreementBillingCandidate
    let billingItem: Item
    let paymentTerms: InvoicePaymentTerms
    let quickBooksConnected: Bool
    let onCreate: () throws -> Void

    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Billing Cycle") {
                    LabeledContent("Customer", value: agreement.customer.name)
                    LabeledContent("Agreement", value: agreement.displayName)
                    LabeledContent("Cycle", value: candidate.interval.displayName)
                    LabeledContent(
                        "Cycle due",
                        value: candidate.cycleDueDate.formatted(date: .abbreviated, time: .omitted)
                    )
                    if candidate.serviceCallID != nil {
                        Label("Released by a completed maintenance visit", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                Section("Invoice") {
                    LabeledContent("Catalog item", value: billingItem.name)
                    LabeledContent("Approved amount", value: candidate.amount.formatted(.currency(code: "USD")))
                    LabeledContent("Payment terms", value: paymentTerms.displayName)
                    if abs(billingItem.unitPrice - candidate.amount) >= 0.005 {
                        Text("The immutable invoice line will use the customer-approved agreement amount; the shared pricebook item remains \(billingItem.unitPrice.formatted(.currency(code: "USD"))).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if billingItem.isTaxable {
                        Label(
                            "QuickBooks must calculate tax before this invoice can be collected.",
                            systemImage: "percent"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }

                Section("Publication") {
                    Label(
                        quickBooksConnected
                            ? "The approved item and invoice will publish to QuickBooks after the local invoice is committed."
                            : "The invoice will remain safely queued for QuickBooks publication until the connection is restored.",
                        systemImage: quickBooksConnected ? "arrow.triangle.2.circlepath.circle.fill" : "clock.badge.exclamationmark"
                    )
                    .font(.caption)
                    .foregroundStyle(quickBooksConnected ? .green : .orange)
                    Text("This creates one reviewable invoice. It does not charge a saved card or enable automatic payments.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    Button(isCreating ? "Creating Invoice..." : "Create Invoice") {
                        createInvoice()
                    }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brandGold)
                    .foregroundStyle(Color.primaryBlack)
                    .disabled(isCreating)
                    .accessibilityIdentifier("CreateAgreementInvoice")
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                }
                .background(.regularMaterial)
            }
            .navigationTitle("Review Agreement Invoice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 560)
    }

    private func createInvoice() {
        guard !isCreating else { return }
        isCreating = true
        errorMessage = nil
        do {
            try onCreate()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isCreating = false
        }
    }
}

private enum BillingDocumentKind: String, CaseIterable, Identifiable {
    case estimate = "Estimate"
    case invoice = "Invoice"

    var id: String { rawValue }
}

private enum InvoiceWorkspaceLane: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case newInvoice = "New Invoice"

    var id: String { rawValue }
}

enum BillingWorkspaceMode {
    case all
    case estimates
    case invoices

    fileprivate var defaultDocumentKind: BillingDocumentKind {
        switch self {
        case .all, .invoices:
            return .invoice
        case .estimates:
            return .estimate
        }
    }

    var navigationTitle: String {
        switch self {
        case .all:
            return "Invoices & Estimates"
        case .estimates:
            return "Estimates"
        case .invoices:
            return "Invoices"
        }
    }

    var showsEstimates: Bool {
        switch self {
        case .all, .estimates:
            return true
        case .invoices:
            return false
        }
    }

    var showsInvoices: Bool {
        switch self {
        case .all, .invoices:
            return true
        case .estimates:
            return false
        }
    }

    var showsPayments: Bool {
        switch self {
        case .all, .invoices:
            return true
        case .estimates:
            return false
        }
    }

    var showsEstimateBuilder: Bool {
        switch self {
        case .all, .estimates:
            return true
        case .invoices:
            return false
        }
    }

    var showsInvoiceBuilder: Bool {
        switch self {
        case .all, .invoices:
            return true
        case .estimates:
            return false
        }
    }
}

#Preview {
    BillingDocumentsView()
}
