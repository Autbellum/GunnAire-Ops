import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import UIKit
import os

struct ReceiptsAndBillsView: View {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "GunnAireOps", category: "ReceiptsAndBills")
    @Environment(\.modelContext) private var modelContext

    private struct LegacyPendingUploadRecord: Codable {
        let id: UUID
        let filePath: String
        let displayName: String
        let entityTypeRaw: String?
        let entityID: String?
        let createdAt: Date
        let lastError: String?
    }

    private struct WarrantyClaimQueueRow: Identifiable {
        let equipment: CustomerEquipment
        let claim: EquipmentWarrantyClaim

        var id: UUID { claim.id }
    }

    struct PendingUploadRecord: Codable, Identifiable {
        let id: UUID
        let filePath: String
        let displayName: String
        let entityTypeRaw: String?
        let entityID: String?
        let createdAt: Date
        var retryCount: Int
        var lastAttemptAt: Date?
        var nextRetryAt: Date?
        var isTerminalFailure: Bool
        var lastError: String?
    }

    private let pendingUploadsStorageKey = "ReceiptsBillsPendingUploads.v1"
    private let maxAutoRetryCount = 8

    @Query(sort: \ServiceCall.scheduledDate, order: .reverse) private var serviceCalls: [ServiceCall]
    @Query(sort: \Invoice.createdAt, order: .reverse) private var invoices: [Invoice]
    @Query(sort: \Estimate.createdAt, order: .reverse) private var estimates: [Estimate]
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]
    @Query(sort: \Vendor.name, order: .forward) private var vendors: [Vendor]
    @Query(sort: \Item.name, order: .forward) private var catalogItems: [Item]
    @Query(sort: \PurchaseOrder.updatedAt, order: .reverse) private var purchaseOrders: [PurchaseOrder]
    @Query(sort: \InventoryMovement.createdAt, order: .reverse) private var inventoryMovements: [InventoryMovement]
    @Query(sort: \CustomerEquipment.name, order: .forward) private var equipmentProfiles: [CustomerEquipment]
    @ObservedObject private var googleAuth = GoogleAuthManager.shared
    @ObservedObject private var quickBooksAPI = QuickBooksDataAPI.shared
    @ObservedObject private var accountingConfigurationStore = QuickBooksAccountingConfigurationStore.shared

    @State private var showingReceiptPicker = false
    @State private var showingBillPicker = false
    @State private var showingReceiptCamera = false
    @State private var showCameraUnavailableAlert = false

    @State private var receiptImage: UIImage?
    @State private var billImage: UIImage?
    @State private var receiptURL: URL?
    @State private var billURL: URL?

    @State private var receiptImportMessage: String? = nil
    @State private var billImportMessage: String? = nil
    @State private var selectedWorkspace: ReceiptsBillsWorkspace = .documents
    @State private var isSyncing = false
    @State private var syncMessage: String?
    @State private var selectedAttachEntityType: QuickBooksAttachableEntityType = .invoice
    @State private var attachEntityID: String = ""
    @State private var selectedServiceCallID: UUID?
    @State private var selectedJobDocumentStage: JobDocumentStage = .supporting
    @State private var isLoadingAttachTargets = false
    @State private var attachTargetOptions: [AttachTargetOption] = []
    @State private var selectedAttachTargetID: String = ""
    @State private var attachLookupMessage: String?
    @State private var pendingUploads: [PendingUploadRecord] = []
    @State private var selectedPendingUploadForDetail: PendingUploadRecord?
    @State private var pendingUploadForDeletion: PendingUploadRecord?
    @State private var showingClearQueueConfirmation = false
    @State private var queueFilter: QueueFilter = .all
    @State private var queueSort: QueueSort = .nextRetry
    @State private var isUploadingReceiptToBackend = false
    @State private var backendUploadMessage: String?
    @State private var newPurchaseOrderVendorID: UUID?
    @State private var newPurchaseOrderServiceCallID: UUID?
    @State private var newPurchaseOrderItemID: UUID?
    @State private var newPurchaseOrderQuantity = "1"
    @State private var newPurchaseOrderUnitCost = ""
    @State private var newPurchaseOrderSerialTrackingRequired = false
    @State private var newPurchaseOrderLines: [PurchaseOrderLine] = []
    @State private var newPurchaseOrderShippingCost = ""
    @State private var newPurchaseOrderNotes = ""
    @State private var purchaseOrderMessage: String?
    @State private var purchaseOrderPendingConfirmation: PurchaseOrder?
    @State private var purchaseOrderPendingReceipt: PurchaseOrder?
    @State private var purchaseOrderPendingBill: PurchaseOrder?
    @State private var purchaseOrderPendingAssetInstallation: PurchaseOrderAssetInstallationContext?
    @State private var purchaseOrderPendingVendorReturn: PurchaseOrder?
    @State private var purchaseOrderPendingVendorReturnAction: PurchaseOrderVendorReturnActionContext?
    @State private var purchaseOrderPendingVendorCredit: PurchaseOrderVendorCreditContext?
    @State private var quickBooksBillPendingPublication: QuickBooksBillPublicationContext?
    @State private var quickBooksVendorCreditPendingPublication: QuickBooksVendorCreditPublicationContext?
    @State private var quickBooksPublishingKey: String?
    @State private var warrantyClaimsEquipment: CustomerEquipment?
    @State private var expandedVendorReturnOrderIDs: Set<UUID> = []
    @State private var selectedInventoryItemID: UUID?
    @State private var inventoryMovementType: InventoryMovementType = .receive
    @State private var inventoryQuantity = "1"
    @State private var inventorySourceLocation = "Warehouse"
    @State private var inventoryDestinationLocation = "Warehouse"
    @State private var inventoryServiceCallID: UUID?
    @State private var inventoryNotes = ""
    @State private var inventoryMessage: String?
    @State private var inventoryCountItem: Item?
    @State private var manualInventoryMovementExpanded = false

    private enum QueueFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case due = "Due"
        case terminal = "Terminal"
        var id: String { rawValue }
    }

    private enum QueueSort: String, CaseIterable, Identifiable {
        case nextRetry = "Next Retry"
        case retries = "Retries"
        case oldest = "Oldest"
        var id: String { rawValue }
    }

    private enum JobDocumentStage: String, CaseIterable, Identifiable {
        case before = "Before Photos"
        case after = "After Photos"
        case supporting = "Supporting Docs"

        var id: String { rawValue }
    }

    private var selectedServiceCall: ServiceCall? {
        guard let selectedServiceCallID else { return nil }
        return serviceCalls.first { $0.id == selectedServiceCallID }
    }

    private var duePendingUploadsCount: Int {
        let now = Date()
        return pendingUploads.filter { record in
            guard !record.isTerminalFailure else { return false }
            guard let nextRetryAt = record.nextRetryAt else { return true }
            return nextRetryAt <= now
        }.count
    }

    private var terminalPendingUploadsCount: Int {
        pendingUploads.filter(\.isTerminalFailure).count
    }

    private var filteredPendingUploads: [PendingUploadRecord] {
        let now = Date()
        let filtered: [PendingUploadRecord]
        switch queueFilter {
        case .all:
            filtered = pendingUploads
        case .due:
            filtered = pendingUploads.filter { record in
                guard !record.isTerminalFailure else { return false }
                guard let nextRetryAt = record.nextRetryAt else { return true }
                return nextRetryAt <= now
            }
        case .terminal:
            filtered = pendingUploads.filter(\.isTerminalFailure)
        }

        switch queueSort {
        case .nextRetry:
            return filtered.sorted { lhs, rhs in
                let lhsNext = lhs.nextRetryAt ?? .distantFuture
                let rhsNext = rhs.nextRetryAt ?? .distantFuture
                if lhsNext != rhsNext { return lhsNext < rhsNext }
                return lhs.createdAt < rhs.createdAt
            }
        case .retries:
            return filtered.sorted { lhs, rhs in
                if lhs.retryCount != rhs.retryCount { return lhs.retryCount > rhs.retryCount }
                return lhs.createdAt < rhs.createdAt
            }
        case .oldest:
            return filtered.sorted { lhs, rhs in
                lhs.createdAt < rhs.createdAt
            }
        }
    }

    private var isAdminUser: Bool {
        AppAccess.isAdmin(
            email: AppIdentity.currentEmail,
            users: users
        )
    }

    private var canRecordWarrantyCredit: Bool {
        AppAccess.canPerformWarrantyClaimAction(
            .recordCredit,
            email: AppIdentity.currentEmail,
            users: users
        )
    }

    private var quickBooksAccountingConfiguration: BackendQuickBooksAccountingConfiguration? {
        guard let configuration = accountingConfigurationStore.configuration,
              configuration.matches(
                realmID: quickBooksAPI.realmID,
                environment: quickBooksAPI.currentEnvironment
              ),
              configuration.isComplete else { return nil }
        return configuration
    }

    private var availableWorkspaces: [ReceiptsBillsWorkspace] {
        ReceiptsBillsWorkspace.available(
            isAdminUser: isAdminUser,
            canRecordWarrantyCredit: canRecordWarrantyCredit
        )
    }

    private var selectedWorkspaceGuidance: String {
        if selectedWorkspace == .purchasing, !isAdminUser, canRecordWarrantyCredit {
            return "Match approved warranty recoveries to vendor and QuickBooks credit evidence. Purchasing and inventory controls remain administrator-only."
        }
        return selectedWorkspace.guidance
    }

    private var activePurchaseOrders: [PurchaseOrder] {
        purchaseOrders.filter { order in
            guard order.status != .cancelled else { return false }
            if order.status == .received {
                let hasUnpublishedBill = order.vendorBills.contains {
                    $0.quickBooksBillID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
                }
                let hasUnpublishedVendorCredit = order.vendorReturns.contains {
                    guard let credit = $0.creditEvidence else { return false }
                    return credit.quickBooksVendorCreditID?
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
                }
                return order.billMatch.state != .matched ||
                    order.hasOpenVendorReturnAttention ||
                    hasUnpublishedBill ||
                    hasUnpublishedVendorCredit
            }
            return true
        }
    }

    private var recentReceivedPurchaseOrders: [PurchaseOrder] {
        purchaseOrders
            .filter {
                $0.status == .received &&
                    $0.billMatch.state == .matched &&
                    !$0.hasOpenVendorReturnAttention
            }
            .sorted {
                let lhsDate = $0.receivedAt ?? $0.updatedAt
                let rhsDate = $1.receivedAt ?? $1.updatedAt
                if lhsDate == rhsDate { return $0.number > $1.number }
                return lhsDate > rhsDate
            }
    }

    private var selectedPurchaseOrderVendor: Vendor? {
        newPurchaseOrderVendorID.flatMap { id in vendors.first { $0.id == id } }
    }

    private var selectedPurchaseOrderItem: Item? {
        newPurchaseOrderItemID.flatMap { id in catalogItems.first { $0.id == id } }
    }

    private var selectedInventoryItem: Item? {
        selectedInventoryItemID.flatMap { id in catalogItems.first { $0.id == id } }
    }

    private var lowStockItems: [Item] {
        catalogItems.filter { item in
            guard item.tracksInventory, let reorderPoint = item.reorderPoint, reorderPoint > 0 else { return false }
            return InventoryLedger.availableQuantity(for: item.id, movements: inventoryMovements) <= reorderPoint
        }
    }

    private var openWarrantyClaimRows: [WarrantyClaimQueueRow] {
        equipmentProfiles
            .flatMap { equipment in
                equipment.openWarrantyClaims.map { WarrantyClaimQueueRow(equipment: equipment, claim: $0) }
            }
            .sorted {
                if $0.claim.updatedAt != $1.claim.updatedAt { return $0.claim.updatedAt < $1.claim.updatedAt }
                return $0.claim.id.uuidString < $1.claim.id.uuidString
            }
    }

    var body: some View {
        ZStack {
            WatermarkBackground()
            NavigationStack {
                Form {
                    Section("Receipts & Bills Workspace") {
                        let workspaces = availableWorkspaces
                        if workspaces.count > 1 {
                            Picker("Workspace", selection: $selectedWorkspace) {
                                ForEach(workspaces) { workspace in
                                    Text(workspace.label).tag(workspace)
                                }
                            }
                            .pickerStyle(.segmented)
                            .accessibilityIdentifier("ReceiptsBillsWorkspacePicker")
                        }

                        Label(selectedWorkspaceGuidance, systemImage: selectedWorkspace.systemImage)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if !isAdminUser, canRecordWarrantyCredit {
                            Text("Accounting can review warranty claims and record approved vendor credits. Supplier orders, receiving, stock adjustments, and QuickBooks administration remain administrator-only.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else if !isAdminUser {
                            Text("Purchasing, stock adjustments, and QuickBooks recovery require an administrator account.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let syncMessage, !syncMessage.isEmpty {
                        Section("Action Status") {
                            Text(syncMessage)
                                .font(.caption)
                                .foregroundStyle(syncMessage.localizedCaseInsensitiveContains("failed") ? .orange : .secondary)
                        }
                    }

                    if selectedWorkspace == .documents {
                    Section(header: Text("Upload Receipts")
                        .font(.headline)
                        .foregroundColor(Color.brandGold)) {
                        Button(action: {
                            showingReceiptPicker = true
                        }) {
                            Label("Select Receipt File or Image", systemImage: "tray.and.arrow.down.fill")
                                .bold()
                                .foregroundColor(Color.brandGold)
                        }
                        Button(action: {
                            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                                showingReceiptCamera = true
                            } else {
                                showCameraUnavailableAlert = true
                            }
                        }) {
                            Label("Capture Receipt With Camera", systemImage: "camera.fill")
                                .bold()
                                .foregroundColor(Color.brandGold)
                        }
                        if receiptImage != nil {
                            Text("Receipt selected")
                                .foregroundColor(.secondary)
                        }
                        if let receiptImportMessage {
                            Text(receiptImportMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Button {
                            Task {
                                await uploadReceiptToBackend()
                            }
                        } label: {
                            Label(isUploadingReceiptToBackend ? "Uploading Receipt..." : "Upload Receipt to Company Storage", systemImage: "icloud.and.arrow.up")
                        }
                        .disabled(isUploadingReceiptToBackend || receiptURL == nil || !GunnAireBackendService.isConfigured)

                        if !GunnAireBackendService.isConfigured {
                            Text("Shared receipt storage is not configured yet.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        if let backendUploadMessage {
                            Text(backendUploadMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if isAdminUser {
                        Section(header: Text("Upload Vendor Bills")
                            .font(.headline)
                            .foregroundColor(Color.brandGold)) {
                            Button(action: {
                                showingBillPicker = true
                            }) {
                                Label("Select Bill File or Image", systemImage: "doc.plaintext")
                                    .bold()
                                    .foregroundColor(Color.brandGold)
                            }
                            if billImage != nil {
                                Text("Bill selected")
                                    .foregroundColor(.secondary)
                            }
                            if let billImportMessage {
                                Text(billImportMessage)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    }

                    if selectedWorkspace == .purchasing {
                        warrantyClaimsSection
                        if isAdminUser {
                            purchaseOrdersSection
                        }
                    }

                    if selectedWorkspace == .inventory, isAdminUser {
                        inventorySection
                    }

                    if selectedWorkspace == .documents {
                    Section(header: Text("Sync and Transactions")
                        .font(.headline)
                        .foregroundColor(Color.brandGold)) {
                        Picker("Service Call", selection: $selectedServiceCallID) {
                            Text("None").tag(UUID?.none)
                            ForEach(serviceCalls) { call in
                                Text("\(call.customer.name) • \(call.scheduledDate.formatted(date: .abbreviated, time: .shortened))")
                                    .tag(UUID?.some(call.id))
                            }
                        }

                        Picker("Documentation Type", selection: $selectedJobDocumentStage) {
                            ForEach(JobDocumentStage.allCases) { stage in
                                Text(stage.rawValue).tag(stage)
                            }
                        }

                        if let selectedServiceCall {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Linked job: \(selectedServiceCall.customer.name)")
                                if let address = selectedServiceCall.siteAddress ?? selectedServiceCall.customer.address,
                                   !address.isEmpty {
                                    Text(address)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Text("Current photos: \(selectedServiceCall.beforePhotoCount) before • \(selectedServiceCall.afterPhotoCount) after")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                if selectedServiceCall.linkedInvoiceID == nil {
                                    Text("This job does not have a linked invoice yet. QuickBooks attachment sync may still require a manual entity ID.")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        if isAdminUser {
                            Picker("Attach To", selection: $selectedAttachEntityType) {
                                ForEach(QuickBooksAttachableEntityType.allCases, id: \.self) { type in
                                    Text(type.rawValue).tag(type)
                                }
                            }
                            TextField("QuickBooks Entity ID (optional)", text: $attachEntityID)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)

                            Button("Load QuickBooks IDs") {
                                loadAttachableTargets()
                            }
                            .disabled(isLoadingAttachTargets)
                        } else {
                            Text("QuickBooks receipt and bill sync is admin-only. Field users can upload receipts to company storage from this screen.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        if isLoadingAttachTargets {
                            ProgressView("Loading IDs...")
                                .tint(Color.brandGold)
                        }

                        if !attachTargetOptions.isEmpty {
                            Picker("Select Existing ID", selection: $selectedAttachTargetID) {
                                Text("Manual Entry").tag("")
                                ForEach(attachTargetOptions) { option in
                                    Text(option.label).tag(option.idValue)
                                }
                            }
                            .onChange(of: selectedAttachTargetID) { _, newValue in
                                if !newValue.isEmpty {
                                    attachEntityID = newValue
                                }
                            }
                        }

                        if let attachLookupMessage {
                            Text(attachLookupMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        if isAdminUser {
                            Button("Sync Receipts and Bills with QuickBooks") {
                                syncDocuments()
                            }
                            .tint(Color.brandGold)
                            .disabled(isSyncing || (receiptURL == nil && billURL == nil))
                        }

                        if isSyncing {
                            ProgressView("Syncing...")
                                .tint(Color.brandGold)
                        }
                    }
                    }

                    if selectedWorkspace == .recovery, isAdminUser {
                        Section(header: Text("Failed Upload Queue")
                            .font(.headline)
                            .foregroundColor(Color.brandGold)) {
                            if pendingUploads.isEmpty {
                                Text("No pending uploads.")
                                    .foregroundColor(.secondary)
                                    .italic()
                            } else {
                                Text("Queued: \(pendingUploads.count) • Due now: \(duePendingUploadsCount) • Terminal: \(terminalPendingUploadsCount)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Picker("View", selection: $queueFilter) {
                                    ForEach(QueueFilter.allCases) { filter in
                                        Text(filter.rawValue).tag(filter)
                                    }
                                }
                                .pickerStyle(.segmented)
                                Picker("Sort", selection: $queueSort) {
                                    ForEach(QueueSort.allCases) { sort in
                                        Text(sort.rawValue).tag(sort)
                                    }
                                }
                                .pickerStyle(.menu)
                                Text("Showing \(filteredPendingUploads.count) item(s)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)

                                ForEach(filteredPendingUploads) { pending in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(pending.displayName)
                                            .font(.subheadline)
                                        Text("Queued: \(pending.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        Text("Retries: \(pending.retryCount)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        if let entityTypeRaw = pending.entityTypeRaw, let entityID = pending.entityID {
                                            Text("Target: \(entityTypeRaw) \(entityID)")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        if let nextRetryAt = pending.nextRetryAt, nextRetryAt > Date() {
                                            Text("Next retry: \(nextRetryAt.formatted(date: .abbreviated, time: .shortened))")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        if pending.isTerminalFailure {
                                            Text("Status: Terminal failure (auto retry disabled)")
                                                .font(.caption2)
                                                .foregroundColor(.orange)
                                        }
                                        if let lastError = pending.lastError, !lastError.isEmpty {
                                            Text("Last error: \(lastError)")
                                                .font(.caption2)
                                                .foregroundColor(.red)
                                        }

                                        HStack {
                                            Button("Details") {
                                                selectedPendingUploadForDetail = pending
                                            }
                                            .buttonStyle(.bordered)
                                            .disabled(isSyncing)

                                            Button("Retry Now") {
                                                retryPendingUpload(pending, ignoreBackoff: true)
                                            }
                                            .buttonStyle(.bordered)
                                            .disabled(isSyncing)

                                            Button("Delete", role: .destructive) {
                                                pendingUploadForDeletion = pending
                                            }
                                            .buttonStyle(.bordered)
                                            .disabled(isSyncing)
                                        }
                                        .padding(.top, 4)
                                    }
                                }
                            }

                            Button("Retry Pending Uploads") {
                                retryPendingUploads()
                            }
                            .disabled(isSyncing || pendingUploads.isEmpty)

                            Button("Clear Queue", role: .destructive) {
                                showingClearQueueConfirmation = true
                            }
                            .disabled(isSyncing || pendingUploads.isEmpty)

                            Button("Purge Missing Files", role: .destructive) {
                                purgeMissingFileEntries()
                            }
                            .disabled(isSyncing || pendingUploads.isEmpty)
                        }
                    }

                    if selectedWorkspace == .documents {
                    Section(header: Text("Selected Files")
                        .font(.headline)
                        .foregroundColor(Color.brandGold)) {
                        if let receiptURL {
                            Text("Receipt: \(receiptURL.lastPathComponent)")
                                .foregroundColor(.secondary)
                        }
                        if isAdminUser, let billURL {
                            Text("Bill: \(billURL.lastPathComponent)")
                                .foregroundColor(.secondary)
                        }
                        if receiptURL == nil && (!isAdminUser || billURL == nil) {
                            Text("No files selected.")
                                .foregroundColor(.secondary)
                            .italic()
                        }
                    }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color.primaryBlack)
                .navigationTitle("Receipts & Bills")
                .foregroundColor(Color.brandGold)
            }
        }
        .fileImporter(isPresented: $showingReceiptPicker,
                      allowedContentTypes: [.image, .pdf, .plainText, .rtf]) { result in
            switch result {
            case .success(let url):
                do {
                    try importDocument(from: url, as: .receipt)
                } catch {
                    receiptURL = nil
                    receiptImage = nil
                    receiptImportMessage = "Failed to read file: \(error.localizedDescription)"
                }
            case .failure(let error):
                Self.logger.error("Receipt file import error: \(error.localizedDescription, privacy: .public)")
            }
        }
        .fileImporter(isPresented: $showingBillPicker,
                      allowedContentTypes: [.image, .pdf, .plainText, .rtf]) { result in
            switch result {
            case .success(let url):
                do {
                    try importDocument(from: url, as: .bill)
                } catch {
                    billURL = nil
                    billImage = nil
                    billImportMessage = "Failed to read file: \(error.localizedDescription)"
                }
            case .failure(let error):
                Self.logger.error("Bill file import error: \(error.localizedDescription, privacy: .public)")
            }
        }
        .sheet(isPresented: $showingReceiptCamera) {
            CameraImagePicker(sourceType: .camera) { image in
                handleCapturedReceiptImage(image)
            }
        }
        .alert("Camera Not Available", isPresented: $showCameraUnavailableAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This device/simulator does not provide camera capture.")
        }
        .confirmationDialog(
            "Delete queued upload?",
            isPresented: Binding(
                get: { pendingUploadForDeletion != nil },
                set: { if !$0 { pendingUploadForDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Queue Entry", role: .destructive) {
                if requireAdministrator(for: "Deleting QuickBooks retry records"),
                   let pendingUploadForDeletion {
                    removePendingUpload(pendingUploadForDeletion.id)
                }
                pendingUploadForDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                pendingUploadForDeletion = nil
            }
        } message: {
            Text("This removes the retry record for \(pendingUploadForDeletion?.displayName ?? "this file"). The source file is not deleted, but it will no longer retry automatically.")
        }
        .confirmationDialog(
            "Clear the failed upload queue?",
            isPresented: $showingClearQueueConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear \(pendingUploads.count) Queue Entries", role: .destructive) {
                if requireAdministrator(for: "Clearing the QuickBooks retry queue") {
                    pendingUploads = []
                    savePendingUploads()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every QuickBooks retry record. Source files are not deleted, but failed uploads will no longer retry automatically.")
        }
        .confirmationDialog(
            "Publish reviewed vendor bill?",
            isPresented: Binding(
                get: { quickBooksBillPendingPublication != nil },
                set: { if !$0 { quickBooksBillPendingPublication = nil } }
            ),
            titleVisibility: .visible,
            presenting: quickBooksBillPendingPublication
        ) { context in
            Button("Publish \(context.bill.totalAmount.formatted(.currency(code: "USD"))) to QuickBooks") {
                publishQuickBooksBill(context)
            }
            Button("Cancel", role: .cancel) {
                quickBooksBillPendingPublication = nil
            }
        } message: { context in
            Text("Vendor: \(context.order.vendorName)\nInvoice: \(context.bill.invoiceNumber)\nAP account: \(quickBooksAccountingConfiguration?.defaultAPAccountName ?? "Not configured")\n\nThis creates one QuickBooks Bill only after checking for a matching GunnAire marker. It does not pay the bill.")
        }
        .confirmationDialog(
            "Publish reviewed vendor credit?",
            isPresented: Binding(
                get: { quickBooksVendorCreditPendingPublication != nil },
                set: { if !$0 { quickBooksVendorCreditPendingPublication = nil } }
            ),
            titleVisibility: .visible,
            presenting: quickBooksVendorCreditPendingPublication
        ) { context in
            Button("Publish \(context.evidence.creditAmount.formatted(.currency(code: "USD"))) to QuickBooks") {
                publishQuickBooksVendorCredit(context)
            }
            Button("Cancel", role: .cancel) {
                quickBooksVendorCreditPendingPublication = nil
            }
        } message: { context in
            Text("Vendor: \(context.order.vendorName)\nCredit: \(context.evidence.reference)\nAP account: \(quickBooksAccountingConfiguration?.defaultAPAccountName ?? "Not configured")\n\nThis creates one QuickBooks Vendor Credit only after checking for a matching GunnAire marker. It does not apply the credit to a bill.")
        }
        .onChange(of: selectedAttachEntityType) { _, _ in
            attachTargetOptions = []
            selectedAttachTargetID = ""
            attachLookupMessage = nil
        }
        .onChange(of: selectedServiceCallID) { _, _ in
            applyLinkedServiceCallDefaults()
        }
        .onChange(of: isAdminUser) { _, newIsAdminUser in
            if !ReceiptsBillsWorkspace.available(
                isAdminUser: newIsAdminUser,
                canRecordWarrantyCredit: canRecordWarrantyCredit
            ).contains(selectedWorkspace) {
                selectedWorkspace = .documents
            }
            if newIsAdminUser {
                loadPendingUploads()
            } else {
                pendingUploads = []
                selectedPendingUploadForDetail = nil
                pendingUploadForDeletion = nil
            }
        }
        .onAppear {
            if !availableWorkspaces.contains(selectedWorkspace) {
                selectedWorkspace = .documents
            }
            if isAdminUser {
                loadPendingUploads()
            }
            applyLinkedServiceCallDefaults()
            refreshQuickBooksAccountingMappings()
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickBooksAuthenticationDidChange)) { _ in
            refreshQuickBooksAccountingMappings(force: true)
        }
        .sheet(item: $selectedPendingUploadForDetail) { pending in
            PendingUploadDetailSheet(
                pending: refreshPendingUploadDetails(for: pending),
                isSyncing: isSyncing,
                onRetryNow: {
                    guard requireAdministrator(for: "Retrying QuickBooks uploads") else { return }
                    retryPendingUpload(pending, ignoreBackoff: true)
                    if pendingUploads.contains(where: { $0.id == pending.id }) {
                        selectedPendingUploadForDetail = refreshPendingUploadDetails(for: pending)
                    } else {
                        selectedPendingUploadForDetail = nil
                    }
                },
                onDelete: {
                    if requireAdministrator(for: "Deleting QuickBooks retry records") {
                        pendingUploadForDeletion = refreshPendingUploadDetails(for: pending)
                    }
                    selectedPendingUploadForDetail = nil
                },
                onToggleTerminal: {
                    guard requireAdministrator(for: "Changing QuickBooks retry state") else { return }
                    setPendingUploadTerminalStatus(
                        id: pending.id,
                        isTerminal: !refreshPendingUploadDetails(for: pending).isTerminalFailure
                    )
                    selectedPendingUploadForDetail = refreshPendingUploadDetails(for: pending)
                },
                onClose: {
                    selectedPendingUploadForDetail = nil
                }
            )
        }
        .sheet(item: $purchaseOrderPendingConfirmation) { order in
            SupplierOrderConfirmationSheet(
                order: order,
                onConfirm: { channel, reference, location, lineCosts, shippingCost in
                    confirmPurchaseOrder(
                        order,
                        channel: channel,
                        reference: reference,
                        supplierLocation: location,
                        confirmedLineUnitCosts: lineCosts,
                        confirmedShippingCost: shippingCost
                    )
                },
                onConnectorConfirm: { connectorKind, location in
                    await confirmPurchaseOrderThroughConnector(
                        order,
                        connectorKind: connectorKind,
                        supplierLocation: location
                    )
                }
            )
            .tint(Color.brandGold)
        }
        .sheet(item: $purchaseOrderPendingReceipt) { order in
            let openLines = order.purchaseOrderLines.filter {
                order.remainingQuantity(for: $0.id) > 0.0001
            }
            let defaultDestinations = Dictionary(uniqueKeysWithValues: openLines.map { line in
                (
                    line.id,
                    PurchaseOrderReceiving.defaultDestination(
                        for: order,
                        lineID: line.id,
                        catalogItems: catalogItems
                    )
                )
            })
            let inventoryTrackedLineIDs = Set(openLines.compactMap { line in
                PurchaseOrderReceiving.matchedItem(
                    for: order,
                    lineID: line.id,
                    catalogItems: catalogItems
                )?.tracksInventory == true ? line.id : nil
            })
            PurchaseOrderReceiptSheet(
                order: order,
                defaultDestinations: defaultDestinations,
                inventoryTrackedLineIDs: inventoryTrackedLineIDs,
                onReceive: { lineID, quantity, destination, note, serialNumbers, manufacturer, modelNumber in
                    receivePurchaseOrder(
                        order,
                        lineID: lineID,
                        quantity: quantity,
                        destinationLocation: destination,
                        note: note,
                        serialNumbers: serialNumbers,
                        manufacturer: manufacturer,
                        modelNumber: modelNumber
                    )
                }
            )
            .tint(Color.brandGold)
        }
        .sheet(item: $purchaseOrderPendingAssetInstallation) { context in
            PurchaseOrderEquipmentInstallationSheet(
                context: context,
                onInstall: { equipmentType, name, location, installDate, warrantyExpiration in
                    installPurchaseOrderAsset(
                        context,
                        equipmentType: equipmentType,
                        name: name,
                        location: location,
                        installDate: installDate,
                        warrantyExpiration: warrantyExpiration
                    )
                }
            )
            .tint(Color.brandGold)
        }
        .sheet(item: $purchaseOrderPendingBill) { order in
            PurchaseOrderVendorBillSheet(
                order: order,
                initialDocumentName: billURL?.lastPathComponent,
                onRecord: {
                    invoiceNumber,
                    invoiceDate,
                    lineAllocations,
                    shippingCost,
                    taxAmount,
                    otherCharges,
                    sourceDocumentName,
                    quickBooksBillID,
                    note in
                    recordVendorBill(
                        on: order,
                        invoiceNumber: invoiceNumber,
                        invoiceDate: invoiceDate,
                        lineAllocations: lineAllocations,
                        shippingCost: shippingCost,
                        taxAmount: taxAmount,
                        otherCharges: otherCharges,
                        sourceDocumentName: sourceDocumentName,
                        quickBooksBillID: quickBooksBillID,
                        note: note
                    )
                }
            )
            .tint(Color.brandGold)
        }
        .sheet(item: $purchaseOrderPendingVendorReturn) { order in
            PurchaseOrderVendorReturnSheet(
                order: order,
                onCreate: { reference, sourceLocation, reason, allocations in
                    createVendorReturn(
                        on: order,
                        reference: reference,
                        sourceLocation: sourceLocation,
                        reason: reason,
                        lineAllocations: allocations
                    )
                }
            )
            .tint(Color.brandGold)
        }
        .sheet(item: $purchaseOrderPendingVendorReturnAction) { context in
            PurchaseOrderVendorReturnActionSheet(
                context: context,
                onConfirm: { note in
                    updateVendorReturn(context, note: note)
                }
            )
            .tint(Color.brandGold)
        }
        .sheet(item: $purchaseOrderPendingVendorCredit) { context in
            PurchaseOrderVendorCreditSheet(
                context: context,
                onRecord: {
                    reference,
                    creditDate,
                    creditAmount,
                    restockingFee,
                    taxCredit,
                    shippingCredit,
                    sourceDocumentName,
                    quickBooksVendorCreditID,
                    note in
                    recordVendorCredit(
                        context,
                        reference: reference,
                        creditDate: creditDate,
                        creditAmount: creditAmount,
                        restockingFee: restockingFee,
                        taxCredit: taxCredit,
                        shippingCredit: shippingCredit,
                        sourceDocumentName: sourceDocumentName,
                        quickBooksVendorCreditID: quickBooksVendorCreditID,
                        note: note
                    )
                }
            )
            .tint(Color.brandGold)
        }
        .sheet(item: $warrantyClaimsEquipment) { equipment in
            EquipmentWarrantyClaimsSheet(equipment: equipment)
                .tint(Color.brandGold)
        }
        .sheet(item: $inventoryCountItem) { item in
            InventoryCycleCountSheet(
                item: item,
                initialLocation: item.defaultInventoryLocation ?? "Warehouse",
                reservedQuantity: InventoryLedger.reservedQuantity(
                    for: item.id,
                    movements: inventoryMovements
                ),
                expectedQuantity: { location in
                    InventoryLedger.onHandQuantity(
                        for: item.id,
                        at: location,
                        movements: inventoryMovements
                    )
                },
                onSave: { location, count, reason in
                    reconcileInventoryCount(
                        for: item,
                        location: location,
                        countedQuantity: count,
                        reason: reason
                    )
                }
            )
            .tint(Color.brandGold)
        }
    }

    @ViewBuilder
    private var warrantyClaimsSection: some View {
        Section(header: Text("Warranty Claims")
            .font(.headline)
            .foregroundColor(Color.brandGold)) {
            Text("Move field requests through manufacturer submission, decision, replacement stock, vendor credit, and verified closeout without losing the originating job or equipment evidence.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if openWarrantyClaimRows.isEmpty {
                Label("No open warranty claims", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(openWarrantyClaimRows.prefix(12)) { row in
                    Button {
                        warrantyClaimsEquipment = row.equipment
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "checkmark.shield")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(row.equipment.customer?.name ?? "Customer") • \(row.equipment.name)")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text("\(row.claim.shortReference) • \(row.claim.failedPartName)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let attention = row.claim.openAttentionSummary {
                                    Text(attention)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.orange)
                                }
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("OpenWarrantyQueueClaim-\(row.claim.id.uuidString)")
                }
                if openWarrantyClaimRows.count > 12 {
                    Text("Showing the 12 oldest open claims. Resolve or close them to reveal the next requests.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var purchaseOrdersSection: some View {
        Section(header: Text("Purchase Orders")
            .font(.headline)
            .foregroundColor(Color.brandGold)) {
            Text("Create a job-linked purchase order before ordering. Mark receipt only after parts are verified; attach the vendor bill below for accounting.")
                .font(.caption)
                .foregroundColor(.secondary)

            Picker("Vendor", selection: $newPurchaseOrderVendorID) {
                Text("Choose vendor").tag(UUID?.none)
                ForEach(vendors) { vendor in
                    Text(vendor.name).tag(UUID?.some(vendor.id))
                }
            }

            Picker("Job", selection: $newPurchaseOrderServiceCallID) {
                Text("Stock / no job").tag(UUID?.none)
                ForEach(serviceCalls) { call in
                    Text("\(call.customer.name) • \(call.type.displayName)").tag(UUID?.some(call.id))
                }
            }

            Picker("Pricebook item", selection: $newPurchaseOrderItemID) {
                Text("Manual part").tag(UUID?.none)
                ForEach(catalogItems) { item in
                    Text(item.name).tag(UUID?.some(item.id))
                }
            }
            .onChange(of: newPurchaseOrderItemID) { _, _ in
                applyPurchaseOrderItemDefaults()
            }

            if let selectedPurchaseOrderItem {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedPurchaseOrderItem.vendorPartNumber ?? selectedPurchaseOrderItem.sku ?? "No supplier part number")
                    if let source = selectedPurchaseOrderItem.preferredVendorName, !source.isEmpty {
                        Text("Preferred supplier: \(source)")
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            TextField("Quantity", text: $newPurchaseOrderQuantity)
                .keyboardType(.decimalPad)
                .accessibilityIdentifier("PurchaseOrderDraftQuantity")
            TextField("Unit cost", text: $newPurchaseOrderUnitCost)
                .keyboardType(.decimalPad)
                .accessibilityIdentifier("PurchaseOrderDraftUnitCost")

            Toggle("Require equipment serials at receiving", isOn: $newPurchaseOrderSerialTrackingRequired)
                .accessibilityIdentifier("PurchaseOrderDraftSerialTracking")
            if newPurchaseOrderSerialTrackingRequired {
                Text("Use for furnaces, condensers, air handlers, and other serialized equipment. Receiving will require one unique serial per whole unit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                addPendingPurchaseOrderLine()
            } label: {
                Label(
                    newPurchaseOrderLines.isEmpty ? "Add Item to Order" : "Add Another Item",
                    systemImage: "plus.circle"
                )
            }
            .buttonStyle(.bordered)
            .disabled(pendingPurchaseOrderLine == nil)
            .accessibilityIdentifier("AddPurchaseOrderLine")

            if !newPurchaseOrderLines.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Order items")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text("\(newPurchaseOrderLines.count) line\(newPurchaseOrderLines.count == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(newPurchaseOrderLines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(line.quantity.formatted()) × \(line.itemName)")
                                    .font(.caption)
                                Text(line.merchandiseTotal.formatted(.currency(code: "USD")))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if line.serialTrackingRequired == true {
                                    Label("Serial tracked", systemImage: "barcode.viewfinder")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button(role: .destructive) {
                                newPurchaseOrderLines.removeAll { $0.id == line.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(line.itemName)")
                        }
                    }
                }
                .padding(.vertical, 4)
                .accessibilityIdentifier("PurchaseOrderDraftLines")
            }
            TextField("Shipping / freight", text: $newPurchaseOrderShippingCost)
                .keyboardType(.decimalPad)
            TextField("Order notes", text: $newPurchaseOrderNotes, axis: .vertical)
                .lineLimit(2...4)

            Button {
                createPurchaseOrder()
            } label: {
                Label("Create Purchase Order", systemImage: "cart.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.brandGold)
            .foregroundStyle(Color.primaryBlack)
            .disabled(selectedPurchaseOrderVendor == nil || !validPurchaseOrderDraft)

            if let purchaseOrderMessage {
                Text(purchaseOrderMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if activePurchaseOrders.isEmpty {
                Text("No open purchase orders.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(activePurchaseOrders.prefix(10)) { order in
                    purchaseOrderRow(order)
                }
            }

            if !recentReceivedPurchaseOrders.isEmpty {
                DisclosureGroup("Recent Receipts") {
                    ForEach(recentReceivedPurchaseOrders.prefix(10)) { order in
                        purchaseOrderRow(order)
                            .padding(.top, 6)
                    }
                }
                .font(.caption)
                .accessibilityIdentifier("RecentPurchaseOrderReceipts")
            }
        }
    }

    private var validPurchaseOrderDraft: Bool {
        !newPurchaseOrderLines.isEmpty || pendingPurchaseOrderLine != nil
    }

    private var pendingPurchaseOrderLine: PurchaseOrderLine? {
        guard let quantity = Double(newPurchaseOrderQuantity),
              quantity.isFinite,
              quantity > 0,
              let unitCost = Double(newPurchaseOrderUnitCost),
              unitCost.isFinite,
              unitCost >= 0 else { return nil }
        if newPurchaseOrderSerialTrackingRequired,
           abs(quantity - quantity.rounded()) > 0.0001 {
            return nil
        }
        let item = selectedPurchaseOrderItem
        return PurchaseOrderLine(
            id: UUID(),
            catalogItemID: item?.id,
            itemName: item?.name ?? "Manual part",
            itemSKU: item?.sku,
            vendorPartNumber: item?.vendorPartNumber,
            quantity: quantity,
            unitCost: unitCost,
            serialTrackingRequired: newPurchaseOrderSerialTrackingRequired ? true : nil
        )
    }

    @ViewBuilder
    private var inventorySection: some View {
        Section(header: Text("Stock & Replenishment")
            .font(.headline)
            .foregroundColor(Color.brandGold)) {
            Text("Record each physical stock change here. The ledger keeps the part, location, job, date, and user traceable; it never changes counts silently.")
                .font(.caption)
                .foregroundColor(.secondary)

            Picker("Pricebook item", selection: $selectedInventoryItemID) {
                Text("Choose item").tag(UUID?.none)
                ForEach(catalogItems) { item in
                    Text(item.name).tag(UUID?.some(item.id))
                }
            }
            .accessibilityIdentifier("InventoryItemPicker")
            .onChange(of: selectedInventoryItemID) { _, _ in
                applyInventoryItemDefaults()
            }

            if let item = selectedInventoryItem {
                Toggle("Track inventory for this item", isOn: Binding(
                    get: { item.tracksInventory },
                    set: { item.tracksInventory = $0 }
                ))

                if item.tracksInventory {
                    let onHand = InventoryLedger.onHandQuantity(for: item.id, movements: inventoryMovements)
                    let reserved = InventoryLedger.reservedQuantity(for: item.id, movements: inventoryMovements)
                    let available = InventoryLedger.availableQuantity(for: item.id, movements: inventoryMovements)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("On hand: \(onHand.formatted()) • Reserved: \(reserved.formatted()) • Available: \(available.formatted())")
                        if let reorderPoint = item.reorderPoint, reorderPoint > 0 {
                            Text("Reorder point: \(reorderPoint.formatted())")
                        }
                    }
                    .font(.caption)
                    .foregroundColor(available < 0 ? .red : .secondary)

                    TextField("Reorder point (optional)", value: Binding(
                        get: { item.reorderPoint },
                        set: { item.reorderPoint = $0 }
                    ), format: .number)
                    .keyboardType(.decimalPad)

                    Button {
                        inventoryCountItem = item
                    } label: {
                        Label("Count Inventory", systemImage: "checklist.checked")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brandGold)
                    .foregroundStyle(Color.primaryBlack)
                    .accessibilityIdentifier("StartInventoryCount")

                    DisclosureGroup(
                        "Record another stock movement",
                        isExpanded: $manualInventoryMovementExpanded
                    ) {
                        Picker("Movement", selection: $inventoryMovementType) {
                            ForEach(InventoryMovementType.manualEntryCases) { type in
                                Text(type.displayName).tag(type)
                            }
                        }

                        if inventoryMovementType.requiresSourceLocation {
                            TextField("From location", text: $inventorySourceLocation)
                        }
                        if inventoryMovementType.requiresDestinationLocation {
                            TextField(inventoryMovementType == .adjust ? "Location" : "To location", text: $inventoryDestinationLocation)
                        }
                        if inventoryMovementType.requiresJobLink {
                            Picker("Job", selection: $inventoryServiceCallID) {
                                Text("Choose job").tag(UUID?.none)
                                ForEach(serviceCalls) { call in
                                    Text("\(call.customer.name) • \(call.type.displayName)").tag(UUID?.some(call.id))
                                }
                            }
                        }
                        TextField(inventoryMovementType == .adjust ? "Adjustment (+/- quantity)" : "Quantity", text: $inventoryQuantity)
                            .keyboardType(.decimalPad)
                        TextField("Reason / notes", text: $inventoryNotes, axis: .vertical)
                            .lineLimit(2...3)

                        Button {
                            recordInventoryMovement()
                        } label: {
                            Label("Record Stock Movement", systemImage: "shippingbox.and.arrow.backward")
                        }
                        .buttonStyle(.bordered)
                    }

                    if let inventoryMessage {
                        Text(inventoryMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .accessibilityIdentifier("InventoryActionMessage")
                    }
                } else {
                    Text("Enable tracking before recording stock changes. Service-only pricebook items can stay untracked.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if !lowStockItems.isEmpty {
                Divider()
                Text("Replenishment attention")
                    .font(.subheadline.weight(.semibold))
                ForEach(lowStockItems.prefix(5)) { item in
                    let available = InventoryLedger.availableQuantity(for: item.id, movements: inventoryMovements)
                    Text("\(item.name): \(available.formatted()) available • reorder at \((item.reorderPoint ?? 0).formatted())")
                        .font(.caption)
                        .foregroundColor(available <= 0 ? .red : .orange)
                }
            }

            let recentMovements = Array(inventoryMovements.prefix(6))
            if !recentMovements.isEmpty {
                Divider()
                Text("Recent stock activity")
                    .font(.subheadline.weight(.semibold))
                ForEach(recentMovements) { movement in
                    VStack(alignment: .leading, spacing: 2) {
                        if let count = InventoryCycleCountSnapshot.decode(from: movement.notes) {
                            Text("Inventory count: \(movement.itemName)")
                            Text(count.summary)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(count.reason)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        } else {
                            Text("\(movement.type.displayName): \(movement.quantity.formatted()) × \(movement.itemName)")
                        }
                        Text(inventoryMovementDetail(movement))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func purchaseOrderRow(_ order: PurchaseOrder) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(order.number)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(order.status.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(purchaseOrderStatusTint(order.status))
            }
            Text(
                order.lineCount == 1
                    ? "\(order.quantity.formatted()) × \(order.itemName) • \(order.total.formatted(.currency(code: "USD")))"
                    : "\(order.lineCount) item lines • \(order.total.formatted(.currency(code: "USD")))"
            )
            .font(.caption)
            if order.lineCount > 1 {
                DisclosureGroup("Order items") {
                    ForEach(order.purchaseOrderLines) { line in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(line.quantity.formatted()) × \(line.itemName)")
                                .font(.caption.weight(.semibold))
                            Text(
                                "Received \(order.receivedQuantity(for: line.id).formatted()) • billed \(order.billedQuantity(for: line.id).formatted()) • \(line.merchandiseTotal.formatted(.currency(code: "USD")))"
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.caption)
                .accessibilityIdentifier("PurchaseOrderLines-\(order.id.uuidString)")
            }
            Text(order.vendorName)
                .font(.caption2)
                .foregroundColor(.secondary)
            if let job = order.serviceCallID.flatMap({ id in serviceCalls.first { $0.id == id } }) {
                Text("Job: \(job.customer.name) • \(job.type.displayName)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            if let receivedToLocation = order.receivedToLocation, !receivedToLocation.isEmpty {
                Text(order.purchaseOrderReceipts.count > 1 ? "Final receipt: \(receivedToLocation)" : "Received to: \(receivedToLocation)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            if let receivingSummary = order.receivingSummary {
                Label(
                    receivingSummary,
                    systemImage: order.hasPartialReceipt ? "shippingbox.and.arrow.backward" : "checkmark.circle.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(order.hasPartialReceipt ? .orange : .green)
                .accessibilityIdentifier("PurchaseOrderReceivingSummary-\(order.id.uuidString)")

                DisclosureGroup("Shipment history") {
                    ForEach(order.purchaseOrderReceipts) { receipt in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(receipt.summary)
                                .font(.caption.weight(.semibold))
                            Text("\(receipt.receivedAt.formatted(date: .abbreviated, time: .shortened)) • \(receipt.receivedByEmail)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            ForEach(receipt.serializedAssets ?? []) { asset in
                                VStack(alignment: .leading, spacing: 3) {
                                    Label(asset.displayName, systemImage: "barcode.viewfinder")
                                        .font(.caption2.weight(.semibold))
                                    if let installation = order.installation(for: asset.id),
                                       let equipment = equipmentProfiles.first(where: { $0.id == installation.customerEquipmentID }) {
                                        Label(
                                            "Installed for \(equipment.customer?.name ?? "customer") • \(installation.installedAt.formatted(date: .abbreviated, time: .omitted))",
                                            systemImage: "house.and.flag.fill"
                                        )
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                        .accessibilityIdentifier("InstalledPurchaseOrderAsset-\(asset.id.uuidString)")
                                    } else if let vendorReturn = order.vendorReturn(containing: asset.id) {
                                        Label(
                                            "Supplier return \(vendorReturn.reference) • \(vendorReturn.status.displayName)",
                                            systemImage: "arrow.uturn.backward.circle.fill"
                                        )
                                        .font(.caption2)
                                        .foregroundStyle(
                                            vendorReturn.status == .creditReceived ? .green : .orange
                                        )
                                        .accessibilityIdentifier("ReturnedPurchaseOrderAsset-\(asset.id.uuidString)")
                                    } else if let jobID = order.serviceCallID,
                                              let job = serviceCalls.first(where: { $0.id == jobID }) {
                                        Button("Add Customer System") {
                                            purchaseOrderPendingAssetInstallation = PurchaseOrderAssetInstallationContext(
                                                order: order,
                                                job: job,
                                                asset: asset,
                                                line: order.line(containing: asset.id)
                                            )
                                        }
                                        .buttonStyle(.bordered)
                                        .accessibilityIdentifier("InstallPurchaseOrderAsset-\(asset.id.uuidString)")
                                    }
                                }
                                .padding(.top, 2)
                            }
                            if let note = receipt.note {
                                Text(note)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if receipt.inventoryMovementID == nil {
                                Text("Procurement receipt only • inventory unchanged")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .contain)
                    }
                }
                .font(.caption)
            }
            if order.status == .requested {
                Text("Field restock request • review the supplier, quantity, and cost before creating an order.")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
            if let confirmation = order.supplierOrderConfirmation {
                VStack(alignment: .leading, spacing: 2) {
                    Text(order.supplierOrderConfirmationSummary ?? "Supplier order confirmed")
                        .font(.caption.weight(.semibold))
                    Text("Confirmed by \(confirmation.confirmedByEmail) • \(confirmation.confirmedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                    Text(
                        order.lineCount == 1
                            ? "Accepted cost: \(confirmation.confirmedUnitCost.formatted(.currency(code: "USD"))) each • freight \(confirmation.confirmedShippingCost.formatted(.currency(code: "USD")))"
                            : "Accepted pricing for \(order.lineCount) items • freight \(confirmation.confirmedShippingCost.formatted(.currency(code: "USD")))"
                    )
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("SupplierOrderEvidence-\(order.id.uuidString)")
            } else if order.status == .ordered {
                Text("Supplier confirmation evidence is required before receiving this legacy order.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                .accessibilityIdentifier("MissingSupplierOrderEvidence-\(order.id.uuidString)")
            }
            if !order.vendorBills.isEmpty || order.status == .received {
                let match = order.billMatch
                Label(match.summary, systemImage: billMatchIcon(match.state))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(billMatchTint(match.state))
                    .accessibilityIdentifier("PurchaseOrderBillMatch-\(order.id.uuidString)")

                if match.hasVariance {
                    Text("Keep this purchase order in accounting review until the supplier bill and accepted order are reconciled. GunnAire Ops has not changed QuickBooks.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                if !order.vendorBills.isEmpty {
                    DisclosureGroup("Vendor bill history") {
                        ForEach(order.vendorBills) { bill in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Invoice \(bill.invoiceNumber) • \(bill.totalAmount.formatted(.currency(code: "USD")))")
                                    .font(.caption.weight(.semibold))
                                Text("\(order.effectiveAllocations(for: bill).count) item line\(order.effectiveAllocations(for: bill).count == 1 ? "" : "s") • \(bill.invoiceDate.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                ForEach(order.effectiveAllocations(for: bill)) { allocation in
                                    Text("\(allocation.quantity.formatted()) × \(allocation.itemName) at \(allocation.unitCost.formatted(.currency(code: "USD")))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Text("Recorded by \(bill.recordedByEmail) • \(bill.recordedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if let sourceDocumentName = bill.sourceDocumentName {
                                    Text("File: \(sourceDocumentName)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if let quickBooksBillID = bill.quickBooksBillID {
                                    Text("QuickBooks Bill ID: \(quickBooksBillID)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    if let publisher = bill.quickBooksPublishedByEmail,
                                       let publishedAt = bill.quickBooksPublishedAt {
                                        Text("Published by \(publisher) • \(publishedAt.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.caption2)
                                            .foregroundStyle(.green)
                                    }
                                } else if match.state == .matched {
                                    Button {
                                        quickBooksBillPendingPublication = QuickBooksBillPublicationContext(
                                            order: order,
                                            bill: bill
                                        )
                                    } label: {
                                        Label(
                                            quickBooksPublishingKey == "bill:\(bill.id.uuidString)"
                                                ? "Publishing…"
                                                : "Review & Publish to QBO",
                                            systemImage: "arrow.up.doc.fill"
                                        )
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(
                                        quickBooksPublishingKey != nil ||
                                        quickBooksPublicationSetupIssue(for: order) != nil
                                    )
                                    .accessibilityIdentifier("PublishVendorBillToQBO-\(bill.id.uuidString)")
                                    if let setupIssue = quickBooksPublicationSetupIssue(for: order) {
                                        Text(setupIssue)
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                }
                                if let note = bill.note {
                                    Text(note)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .font(.caption)
                    .accessibilityIdentifier("PurchaseOrderBillHistory-\(order.id.uuidString)")
                }
            }
            if !order.vendorReturns.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        if expandedVendorReturnOrderIDs.contains(order.id) {
                            expandedVendorReturnOrderIDs.remove(order.id)
                        } else {
                            expandedVendorReturnOrderIDs.insert(order.id)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text("Supplier returns")
                            Spacer()
                            Text(order.vendorReturns.count.formatted())
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Image(
                                systemName: expandedVendorReturnOrderIDs.contains(order.id)
                                    ? "chevron.down"
                                    : "chevron.right"
                            )
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Supplier returns")
                    .accessibilityValue(
                        expandedVendorReturnOrderIDs.contains(order.id)
                            ? "Expanded"
                            : "Collapsed"
                    )
                    .accessibilityIdentifier("PurchaseOrderVendorReturns-\(order.id.uuidString)")

                    if expandedVendorReturnOrderIDs.contains(order.id) {
                        ForEach(order.vendorReturns) { vendorReturn in
                        let creditMatch = order.vendorCreditMatch(for: vendorReturn)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("RMA \(vendorReturn.reference)")
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Text(vendorReturn.status.displayName)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(vendorReturnTint(vendorReturn.status))
                            }
                            ForEach(vendorReturn.lineAllocations) { allocation in
                                Text("\(allocation.quantity.formatted()) × \(allocation.itemName)")
                                    .font(.caption2)
                                let serials = (allocation.serializedAssetIDs ?? []).compactMap { assetID in
                                    order.receivedSerializedAssets.first(where: { $0.id == assetID })?.serialNumber
                                }
                                if !serials.isEmpty {
                                    Text("Serials: \(serials.joined(separator: ", "))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text("\(vendorReturn.sourceLocation) • \(vendorReturn.reason)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if vendorReturn.status == .returned ||
                                vendorReturn.status == .creditReceived {
                                Label(
                                    creditMatch.summary,
                                    systemImage: creditMatch.hasVariance
                                        ? "exclamationmark.triangle.fill"
                                        : vendorReturn.status == .creditReceived
                                            ? "checkmark.seal.fill"
                                            : "clock.badge"
                                )
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(
                                    creditMatch.hasVariance
                                        ? .red
                                        : vendorReturn.status == .creditReceived ? .green : .orange
                                )
                                .accessibilityIdentifier("VendorReturnCreditMatch-\(vendorReturn.id.uuidString)")
                                if creditMatch.hasVariance {
                                    Text("Review the supplier credit before changing QuickBooks. GunnAire Ops has not created or changed a Vendor Credit.")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                            ForEach(vendorReturn.events) { event in
                                Text(
                                    "\(event.status.displayName) • \(event.recordedAt.formatted(date: .abbreviated, time: .shortened)) • \(event.recordedByEmail)"
                                )
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            if let credit = vendorReturn.creditEvidence {
                                Text("Credit \(credit.reference) • \(credit.creditAmount.formatted(.currency(code: "USD")))")
                                    .font(.caption2.weight(.semibold))
                                if let sourceDocumentName = credit.sourceDocumentName {
                                    Text("File: \(sourceDocumentName)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if let quickBooksVendorCreditID = credit.quickBooksVendorCreditID {
                                    Text("QuickBooks Vendor Credit ID: \(quickBooksVendorCreditID)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    if let publisher = credit.quickBooksPublishedByEmail,
                                       let publishedAt = credit.quickBooksPublishedAt {
                                        Text("Published by \(publisher) • \(publishedAt.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.caption2)
                                            .foregroundStyle(.green)
                                    }
                                } else if creditMatch.state == .matched {
                                    Button {
                                        quickBooksVendorCreditPendingPublication =
                                            QuickBooksVendorCreditPublicationContext(
                                                order: order,
                                                vendorReturn: vendorReturn,
                                                evidence: credit
                                            )
                                    } label: {
                                        Label(
                                            quickBooksPublishingKey == "credit:\(vendorReturn.id.uuidString)"
                                                ? "Publishing…"
                                                : "Review & Publish to QBO",
                                            systemImage: "arrow.uturn.backward.square.fill"
                                        )
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(
                                        quickBooksPublishingKey != nil ||
                                        quickBooksPublicationSetupIssue(for: order) != nil
                                    )
                                    .accessibilityIdentifier("PublishVendorCreditToQBO-\(vendorReturn.id.uuidString)")
                                    if let setupIssue = quickBooksPublicationSetupIssue(for: order) {
                                        Text(setupIssue)
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }
                            if vendorReturn.status == .pending ||
                                vendorReturn.status == .sent ||
                                vendorReturn.status == .returned {
                                Menu("Return Actions") {
                                    if vendorReturn.status == .pending {
                                        Button("Mark Sent") {
                                            purchaseOrderPendingVendorReturnAction =
                                                PurchaseOrderVendorReturnActionContext(
                                                    order: order,
                                                    vendorReturn: vendorReturn,
                                                    action: .markSent
                                                )
                                        }
                                    }
                                    if vendorReturn.status == .sent {
                                        Button("Mark Returned") {
                                            purchaseOrderPendingVendorReturnAction =
                                                PurchaseOrderVendorReturnActionContext(
                                                    order: order,
                                                    vendorReturn: vendorReturn,
                                                    action: .markReturned
                                                )
                                        }
                                    }
                                    if vendorReturn.status == .returned {
                                        Button("Record Vendor Credit") {
                                            purchaseOrderPendingVendorCredit =
                                                PurchaseOrderVendorCreditContext(
                                                    order: order,
                                                    vendorReturn: vendorReturn
                                                )
                                        }
                                    } else {
                                        Button("Cancel Return", role: .destructive) {
                                            purchaseOrderPendingVendorReturnAction =
                                                PurchaseOrderVendorReturnActionContext(
                                                    order: order,
                                                    vendorReturn: vendorReturn,
                                                    action: .cancel
                                                )
                                        }
                                    }
                                }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("VendorReturnActions-\(vendorReturn.id.uuidString)")
                            }
                        }
                        .padding(.vertical, 3)
                        .accessibilityElement(children: .contain)
                    }
                    }
                }
                .font(.caption)
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 138), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                if order.status == .requested {
                    Button("Prepare Draft") { preparePurchaseOrderRequest(order) }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.brandGold)
                        .foregroundStyle(Color.primaryBlack)
                        .accessibilityIdentifier("PrepareRestockRequest-\(order.id.uuidString)")
                    Button("Cancel", role: .destructive) { updatePurchaseOrder(order, to: .cancelled) }
                        .buttonStyle(.bordered)
                } else if order.status == .draft {
                    Button("Confirm Order") { purchaseOrderPendingConfirmation = order }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("ConfirmPurchaseOrder-\(order.id.uuidString)")
                    Button("Cancel", role: .destructive) { updatePurchaseOrder(order, to: .cancelled) }
                        .buttonStyle(.bordered)
                }
                if order.status == .ordered || order.status == .partiallyReceived {
                    if order.hasSupplierOrderConfirmation {
                        Button(order.hasPartialReceipt ? "Receive Balance" : "Receive Shipment") {
                            purchaseOrderPendingReceipt = order
                        }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                            .accessibilityIdentifier("ReceiveShipment-\(order.id.uuidString)")
                    } else {
                        Button("Add Order Evidence") { purchaseOrderPendingConfirmation = order }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.brandGold)
                            .foregroundStyle(Color.primaryBlack)
                            .accessibilityIdentifier("ConfirmPurchaseOrder-\(order.id.uuidString)")
                    }
                }
                if order.hasSupplierOrderConfirmation,
                   (order.status == .ordered ||
                    order.status == .partiallyReceived ||
                    order.status == .received) {
                    Button("Record Bill") {
                        purchaseOrderPendingBill = order
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("RecordVendorBill-\(order.id.uuidString)")
                }
                if (order.status == .partiallyReceived || order.status == .received),
                   order.hasReturnableVendorItems {
                    Button("Create Supplier Return") {
                        purchaseOrderPendingVendorReturn = order
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("CreateVendorReturn-\(order.id.uuidString)")
                }
                if order.status != .requested {
                    Button("Copy Order") {
                        UIPasteboard.general.string = order.supplierOrderSummary
                        purchaseOrderMessage = "Copied \(order.number). Paste it into the approved supplier portal or an email, then mark it ordered only after the supplier accepts it."
                    }
                    .buttonStyle(.bordered)
                    Button("Accounting") {
                        GunnAireAppIntentRouter.store(.quickBooks)
                    }
                    .buttonStyle(.bordered)
                    if let urlText = selectedPurchaseURL(for: order), let url = URL(string: urlText) {
                        Link("Open Supplier", destination: url)
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func billMatchTint(_ state: PurchaseOrderBillMatchState) -> Color {
        switch state {
        case .notRecorded, .inProgress, .awaitingReceipt: .orange
        case .quantityVariance, .costVariance: .red
        case .matched: .green
        }
    }

    private func billMatchIcon(_ state: PurchaseOrderBillMatchState) -> String {
        switch state {
        case .notRecorded: "doc.badge.plus"
        case .inProgress: "doc.text"
        case .awaitingReceipt: "shippingbox"
        case .quantityVariance, .costVariance: "exclamationmark.triangle.fill"
        case .matched: "checkmark.seal.fill"
        }
    }

    private func vendorReturnTint(_ status: PurchaseOrderVendorReturnStatus) -> Color {
        switch status {
        case .pending, .sent, .returned: .orange
        case .creditReceived: .green
        case .cancelled: .secondary
        }
    }

    private func purchaseOrderStatusTint(_ status: PurchaseOrderStatus) -> Color {
        switch status {
        case .requested: .orange
        case .draft: .secondary
        case .ordered: .orange
        case .partiallyReceived: .orange
        case .received: .green
        case .cancelled: .red
        }
    }

    private func selectedPurchaseURL(for order: PurchaseOrder) -> String? {
        catalogItems.first {
            $0.name == order.itemName && $0.vendorPartNumber == order.vendorPartNumber
        }?.purchaseURL
    }
}

private struct PurchaseOrderBillAllocationDraft: Identifiable {
    let id: UUID
    let itemName: String
    var quantityText: String
    var unitCostText: String
}

private struct PurchaseOrderVendorBillSheet: View {
    @Environment(\.dismiss) private var dismiss

    let order: PurchaseOrder
    let onRecord: (
        _ invoiceNumber: String,
        _ invoiceDate: Date,
        _ lineAllocations: [PurchaseOrderBillLineAllocation],
        _ shippingCost: Double,
        _ taxAmount: Double,
        _ otherCharges: Double,
        _ sourceDocumentName: String?,
        _ quickBooksBillID: String?,
        _ note: String?
    ) -> String?

    @State private var invoiceNumber = ""
    @State private var invoiceDate = Date()
    @State private var allocationDrafts: [PurchaseOrderBillAllocationDraft]
    @State private var shippingCostText: String
    @State private var taxAmountText = "0"
    @State private var otherChargesText = "0"
    @State private var sourceDocumentName: String
    @State private var quickBooksBillID = ""
    @State private var note = ""
    @State private var validationMessage: String?
    @FocusState private var focusedField: BillField?

    private enum BillField: Hashable {
        case invoiceNumber
        case quantity
        case unitCost
        case shipping
        case tax
        case other
        case document
        case qbo
        case note
    }

    init(
        order: PurchaseOrder,
        initialDocumentName: String?,
        onRecord: @escaping (
            _ invoiceNumber: String,
            _ invoiceDate: Date,
            _ lineAllocations: [PurchaseOrderBillLineAllocation],
            _ shippingCost: Double,
            _ taxAmount: Double,
            _ otherCharges: Double,
            _ sourceDocumentName: String?,
            _ quickBooksBillID: String?,
            _ note: String?
        ) -> String?
    ) {
        self.order = order
        self.onRecord = onRecord
        let match = order.billMatch
        let drafts = order.purchaseOrderLines.map { line in
            let billed = order.billedQuantity(for: line.id)
            let unbilledQuantity = max(line.quantity - billed, 0)
            let newlyReceivedQuantity = max(order.receivedQuantity(for: line.id) - billed, 0)
            let suggestedQuantity = newlyReceivedQuantity > 0.0001 ? newlyReceivedQuantity : unbilledQuantity
            return PurchaseOrderBillAllocationDraft(
                id: line.id,
                itemName: line.itemName,
                quantityText: suggestedQuantity.formatted(.number.precision(.fractionLength(0...3))),
                unitCostText: String(format: "%.2f", order.acceptedUnitCost(for: line.id))
            )
        }
        let suggestedQuantity = drafts.reduce(0) { $0 + (Double($1.quantityText) ?? 0) }
        let completesOrder = match.billedQuantity + suggestedQuantity >= order.orderedQuantity - 0.0001
        let remainingShipping = max(match.expectedShippingCost - match.billedShippingCost, 0)
        _allocationDrafts = State(initialValue: drafts)
        _shippingCostText = State(
            initialValue: String(format: "%.2f", completesOrder ? remainingShipping : 0)
        )
        _sourceDocumentName = State(
            initialValue: initialDocumentName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }

    private var parsedShippingCost: Double? { parsed(shippingCostText) }
    private var parsedTaxAmount: Double? { parsed(taxAmountText) }
    private var parsedOtherCharges: Double? { parsed(otherChargesText) }

    private var parsedLineAllocations: [PurchaseOrderBillLineAllocation]? {
        var allocations: [PurchaseOrderBillLineAllocation] = []
        for draft in allocationDrafts {
            guard let quantity = parsed(draft.quantityText),
                  quantity >= 0,
                  let unitCost = parsed(draft.unitCostText),
                  unitCost >= 0 else { return nil }
            if quantity > 0.0001 {
                allocations.append(
                    PurchaseOrderBillLineAllocation(
                        lineID: draft.id,
                        itemName: draft.itemName,
                        quantity: quantity,
                        unitCost: unitCost
                    )
                )
            }
        }
        return allocations
    }

    private var calculatedTotal: Double? {
        guard let parsedLineAllocations,
              let parsedShippingCost,
              let parsedTaxAmount,
              let parsedOtherCharges else { return nil }
        return parsedLineAllocations.reduce(0) { $0 + $1.merchandiseAmount } +
            parsedShippingCost + parsedTaxAmount + parsedOtherCharges
    }

    private var canRecord: Bool {
        guard !invoiceNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              invoiceNumber.count <= 80,
              let parsedLineAllocations,
              !parsedLineAllocations.isEmpty,
              let parsedShippingCost,
              parsedShippingCost >= 0,
              let parsedTaxAmount,
              parsedTaxAmount >= 0,
              let parsedOtherCharges,
              parsedOtherCharges >= 0 else { return false }
        return sourceDocumentName.count <= 180 &&
            quickBooksBillID.count <= 80 &&
            note.count <= 240
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Purchase Order") {
                    LabeledContent("PO", value: order.number)
                    LabeledContent("Supplier", value: order.vendorName)
                    LabeledContent(
                        "Ordered / received / billed",
                        value: "\(order.orderedQuantity.formatted()) / \(order.receivedQuantity.formatted()) / \(order.billMatch.billedQuantity.formatted())"
                    )
                }

                Section("Vendor Bill") {
                    TextField("Supplier invoice or bill number", text: $invoiceNumber)
                        .textInputAutocapitalization(.characters)
                        .focused($focusedField, equals: .invoiceNumber)
                        .accessibilityIdentifier("PurchaseOrderBillInvoiceNumber")

                    DatePicker("Invoice date", selection: $invoiceDate, in: ...Date(), displayedComponents: .date)
                        .accessibilityIdentifier("PurchaseOrderBillDate")

                    ForEach($allocationDrafts) { $draft in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(draft.itemName)
                                .font(.caption.weight(.semibold))
                            TextField("Quantity billed", text: $draft.quantityText)
                                .keyboardType(.decimalPad)
                                .focused($focusedField, equals: .quantity)
                                .accessibilityIdentifier(
                                    draft.id == allocationDrafts.first?.id
                                        ? "PurchaseOrderBillQuantity"
                                        : "PurchaseOrderBillQuantity-\(draft.id.uuidString)"
                                )
                            TextField("Unit cost", text: $draft.unitCostText)
                                .keyboardType(.decimalPad)
                                .focused($focusedField, equals: .unitCost)
                                .accessibilityIdentifier(
                                    draft.id == allocationDrafts.first?.id
                                        ? "PurchaseOrderBillUnitCost"
                                        : "PurchaseOrderBillUnitCost-\(draft.id.uuidString)"
                                )
                        }
                        .padding(.vertical, 2)
                    }

                    TextField("Freight / shipping", text: $shippingCostText)
                        .keyboardType(.decimalPad)
                        .focused($focusedField, equals: .shipping)
                        .accessibilityIdentifier("PurchaseOrderBillShipping")

                    TextField("Tax", text: $taxAmountText)
                        .keyboardType(.decimalPad)
                        .focused($focusedField, equals: .tax)
                        .accessibilityIdentifier("PurchaseOrderBillTax")

                    TextField("Other charges", text: $otherChargesText)
                        .keyboardType(.decimalPad)
                        .focused($focusedField, equals: .other)
                        .accessibilityIdentifier("PurchaseOrderBillOtherCharges")

                    if let calculatedTotal {
                        LabeledContent("Calculated bill total", value: calculatedTotal.formatted(.currency(code: "USD")))
                    }

                    if let confirmation = order.supplierOrderConfirmation {
                        Text("Supplier accepted the item pricing shown above and \(confirmation.confirmedShippingCost.formatted(.currency(code: "USD"))) total freight. Differences stay visible for accounting review.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Evidence Links") {
                    TextField("Selected bill filename (optional)", text: $sourceDocumentName)
                        .focused($focusedField, equals: .document)
                        .accessibilityIdentifier("PurchaseOrderBillDocumentName")

                    TextField("QuickBooks Bill ID (optional)", text: $quickBooksBillID)
                        .focused($focusedField, equals: .qbo)
                        .accessibilityIdentifier("PurchaseOrderBillQuickBooksID")

                    TextField("Packing, freight, or discrepancy note (optional)", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                        .focused($focusedField, equals: .note)
                        .accessibilityIdentifier("PurchaseOrderBillNote")

                    Label(
                        "This records local reconciliation evidence only. It does not create, approve, or change a QuickBooks Bill.",
                        systemImage: "lock.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Record Vendor Bill")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Record Bill") {
                        guard let parsedLineAllocations,
                              let parsedShippingCost,
                              let parsedTaxAmount,
                              let parsedOtherCharges else { return }
                        let normalizedDocument = sourceDocumentName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let normalizedQBO = quickBooksBillID.trimmingCharacters(in: .whitespacesAndNewlines)
                        let normalizedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let error = onRecord(
                            invoiceNumber,
                            invoiceDate,
                            parsedLineAllocations,
                            parsedShippingCost,
                            parsedTaxAmount,
                            parsedOtherCharges,
                            normalizedDocument.isEmpty ? nil : normalizedDocument,
                            normalizedQBO.isEmpty ? nil : normalizedQBO,
                            normalizedNote.isEmpty ? nil : normalizedNote
                        ) {
                            validationMessage = error
                        } else {
                            dismiss()
                        }
                    }
                    .disabled(!canRecord)
                    .accessibilityIdentifier("ConfirmPurchaseOrderBill")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                        .accessibilityLabel("Done Editing Vendor Bill")
                }
            }
        }
    }

    private func parsed(_ value: String) -> Double? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
        guard let amount = Double(normalized), amount.isFinite else { return nil }
        return amount
    }
}

private enum PurchaseOrderVendorReturnAction: String {
    case markSent
    case markReturned
    case cancel

    var title: String {
        switch self {
        case .markSent: "Mark Return Sent"
        case .markReturned: "Mark Return Complete"
        case .cancel: "Cancel Supplier Return"
        }
    }

    var buttonTitle: String {
        switch self {
        case .markSent: "Mark Sent"
        case .markReturned: "Mark Returned"
        case .cancel: "Cancel Return"
        }
    }
}

private struct PurchaseOrderVendorReturnActionContext: Identifiable {
    let id = UUID()
    let order: PurchaseOrder
    let vendorReturn: PurchaseOrderVendorReturn
    let action: PurchaseOrderVendorReturnAction
}

private struct PurchaseOrderVendorCreditContext: Identifiable {
    let id = UUID()
    let order: PurchaseOrder
    let vendorReturn: PurchaseOrderVendorReturn
}

private struct QuickBooksBillPublicationContext: Identifiable {
    var id: UUID { bill.id }
    let order: PurchaseOrder
    let bill: PurchaseOrderVendorBill
}

private struct QuickBooksVendorCreditPublicationContext: Identifiable {
    var id: UUID { vendorReturn.id }
    let order: PurchaseOrder
    let vendorReturn: PurchaseOrderVendorReturn
    let evidence: PurchaseOrderVendorCreditEvidence
}

private struct PurchaseOrderVendorReturnSheet: View {
    @Environment(\.dismiss) private var dismiss

    let order: PurchaseOrder
    let onCreate: (
        _ reference: String,
        _ sourceLocation: String,
        _ reason: String,
        _ lineAllocations: [PurchaseOrderVendorReturnLine]
    ) -> String?

    @State private var reference = ""
    @State private var sourceLocation: String
    @State private var reason = ""
    @State private var quantities: [UUID: String] = [:]
    @State private var selectedAssetIDs: Set<UUID> = []
    @State private var validationMessage: String?
    @FocusState private var isEditing: Bool

    init(
        order: PurchaseOrder,
        onCreate: @escaping (
            _ reference: String,
            _ sourceLocation: String,
            _ reason: String,
            _ lineAllocations: [PurchaseOrderVendorReturnLine]
        ) -> String?
    ) {
        self.order = order
        self.onCreate = onCreate
        let locations = Self.locations(for: order)
        let preferred = order.receivedToLocation.flatMap { lastLocation in
            locations.first {
                $0.caseInsensitiveCompare(lastLocation) == .orderedSame
            }
        }
        _sourceLocation = State(initialValue: preferred ?? locations.first ?? "Warehouse")
    }

    private static func locations(for order: PurchaseOrder) -> [String] {
        var unique: [String] = []
        for receipt in order.purchaseOrderReceipts {
            let location = receipt.destinationLocation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !location.isEmpty,
                  !unique.contains(where: {
                      $0.caseInsensitiveCompare(location) == .orderedSame
                  }) else {
                continue
            }
            unique.append(location)
        }
        return unique.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private var locations: [String] {
        Self.locations(for: order)
    }

    private var returnableLines: [PurchaseOrderLine] {
        order.purchaseOrderLines.filter {
            order.returnableQuantity(for: $0.id, at: sourceLocation) > 0.0001
        }
    }

    private func isSerialized(_ line: PurchaseOrderLine) -> Bool {
        line.serialTrackingRequired == true ||
            !order.receivedSerializedAssets(for: line.id).isEmpty
    }

    private func availableAssets(for line: PurchaseOrderLine) -> [PurchaseOrderReceivedAsset] {
        order.purchaseOrderReceipts
            .filter {
                let receiptLineID = $0.lineID ?? order.purchaseOrderLines.first?.id
                return receiptLineID == line.id &&
                    $0.destinationLocation.caseInsensitiveCompare(sourceLocation) == .orderedSame
            }
            .flatMap { $0.serializedAssets ?? [] }
            .filter {
                order.installation(for: $0.id) == nil &&
                    order.vendorReturn(containing: $0.id) == nil
            }
            .sorted {
                $0.serialNumber.localizedCaseInsensitiveCompare($1.serialNumber) == .orderedAscending
            }
    }

    private var allocations: [PurchaseOrderVendorReturnLine] {
        returnableLines.compactMap { line in
            if isSerialized(line) {
                let selected = availableAssets(for: line)
                    .filter { selectedAssetIDs.contains($0.id) }
                    .map(\.id)
                guard !selected.isEmpty else { return nil }
                return PurchaseOrderVendorReturnLine(
                    lineID: line.id,
                    itemName: line.itemName,
                    quantity: Double(selected.count),
                    serializedAssetIDs: selected
                )
            }
            let value = quantities[line.id]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let quantity = Double(value),
                  quantity.isFinite,
                  quantity > 0.0001,
                  quantity <= order.returnableQuantity(
                      for: line.id,
                      at: sourceLocation
                  ) + 0.0001 else {
                return nil
            }
            return PurchaseOrderVendorReturnLine(
                lineID: line.id,
                itemName: line.itemName,
                quantity: quantity,
                serializedAssetIDs: nil
            )
        }
    }

    private var canCreate: Bool {
        let normalizedReference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalizedReference.isEmpty &&
            normalizedReference.count <= 120 &&
            !normalizedReason.isEmpty &&
            normalizedReason.count <= 240 &&
            !sourceLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !allocations.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Supplier Return") {
                    LabeledContent("Purchase order", value: order.number)
                    LabeledContent("Supplier", value: order.vendorName)
                    TextField("RMA or supplier return reference", text: $reference)
                        .focused($isEditing)
                        .textInputAutocapitalization(.characters)
                        .accessibilityIdentifier("VendorReturnReference")
                    if locations.count > 1 {
                        Picker("Return from", selection: $sourceLocation) {
                            ForEach(locations, id: \.self) { location in
                                Text(location).tag(location)
                            }
                        }
                        .accessibilityIdentifier("VendorReturnSource")
                    } else {
                        LabeledContent("Return from", value: sourceLocation)
                            .accessibilityIdentifier("VendorReturnSource")
                    }
                    TextField("Reason for return", text: $reason, axis: .vertical)
                        .lineLimit(2...4)
                        .focused($isEditing)
                        .accessibilityIdentifier("VendorReturnReason")
                }

                Section("Received Items") {
                    if returnableLines.isEmpty {
                        Label(
                            "No uncommitted received items remain at this location.",
                            systemImage: "checkmark.circle"
                        )
                        .foregroundStyle(.secondary)
                    }
                    ForEach(returnableLines) { line in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(line.itemName)
                                .font(.subheadline.weight(.semibold))
                            Text(
                                "\(order.returnableQuantity(for: line.id, at: sourceLocation).formatted()) available to return"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            if isSerialized(line) {
                                let assets = availableAssets(for: line)
                                ForEach(assets) { asset in
                                    Toggle(
                                        asset.displayName,
                                        isOn: Binding(
                                            get: { selectedAssetIDs.contains(asset.id) },
                                            set: { selected in
                                                if selected {
                                                    selectedAssetIDs.insert(asset.id)
                                                } else {
                                                    selectedAssetIDs.remove(asset.id)
                                                }
                                            }
                                        )
                                    )
                                    .accessibilityIdentifier("VendorReturnAsset-\(asset.id.uuidString)")
                                }
                                if assets.isEmpty {
                                    Text("No uninstalled serial numbers are available at this location.")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            } else {
                                TextField(
                                    "Quantity to return",
                                    text: quantityBinding(for: line.id)
                                )
                                .keyboardType(.decimalPad)
                                .focused($isEditing)
                                .accessibilityIdentifier("VendorReturnLine-\(line.id.uuidString)")
                            }
                        }
                    }
                    if !returnableLines.isEmpty {
                        Button("Select All Returnable") {
                            selectAllReturnable()
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("SelectAllVendorReturnItems")
                    }
                }

                Section {
                    Label(
                        "Creating the return reserves these quantities and serial numbers. Stock is deducted only after you mark the material returned.",
                        systemImage: "arrow.uturn.backward.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Create Supplier Return")
            .onChange(of: sourceLocation) { _, _ in
                quantities = [:]
                selectedAssetIDs = []
                validationMessage = nil
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create Return") {
                        if let error = onCreate(
                            reference,
                            sourceLocation,
                            reason,
                            allocations
                        ) {
                            validationMessage = error
                        } else {
                            dismiss()
                        }
                    }
                    .disabled(!canCreate)
                    .accessibilityIdentifier("ConfirmVendorReturn")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isEditing = false }
                        .accessibilityLabel("Done Editing Supplier Return")
                }
            }
        }
    }

    private func quantityBinding(for lineID: UUID) -> Binding<String> {
        Binding(
            get: { quantities[lineID] ?? "" },
            set: { quantities[lineID] = $0 }
        )
    }

    private func selectAllReturnable() {
        for line in returnableLines {
            if isSerialized(line) {
                selectedAssetIDs.formUnion(availableAssets(for: line).map(\.id))
            } else {
                quantities[line.id] = order.returnableQuantity(
                    for: line.id,
                    at: sourceLocation
                ).formatted(.number.precision(.fractionLength(0...3)))
            }
        }
    }
}

private struct PurchaseOrderVendorReturnActionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let context: PurchaseOrderVendorReturnActionContext
    let onConfirm: (_ note: String?) -> String?

    @State private var note = ""
    @State private var validationMessage: String?
    @FocusState private var isEditing: Bool

    private var guidance: String {
        switch context.action {
        case .markSent:
            "Use this after the shipment leaves the truck, warehouse, or job site. Stock remains unchanged until the supplier has the returned material."
        case .markReturned:
            "This permanently records the return event and deducts tracked items from \(context.vendorReturn.sourceLocation). The transaction remains open until the supplier credit is recorded."
        case .cancel:
            "Cancel only while stock has not been returned. The committed quantities and serial numbers will become available again."
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Return") {
                    LabeledContent("Purchase order", value: context.order.number)
                    LabeledContent("RMA", value: context.vendorReturn.reference)
                    LabeledContent("Current status", value: context.vendorReturn.status.displayName)
                    Text(guidance)
                        .font(.caption)
                        .foregroundStyle(context.action == .markReturned ? .orange : .secondary)
                }
                Section("Audit Note") {
                    TextField("Carrier, tracking, branch receipt, or cancellation reason (optional)", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                        .focused($isEditing)
                        .accessibilityIdentifier("VendorReturnActionNote")
                }
                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle(context.action.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(context.action.buttonTitle) {
                        let normalized = note.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let error = onConfirm(normalized.isEmpty ? nil : normalized) {
                            validationMessage = error
                        } else {
                            dismiss()
                        }
                    }
                    .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).count > 240)
                    .tint(context.action == .cancel ? .red : Color.brandGold)
                    .accessibilityIdentifier("ConfirmVendorReturnAction")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isEditing = false }
                }
            }
        }
    }
}

private struct PurchaseOrderVendorCreditSheet: View {
    @Environment(\.dismiss) private var dismiss

    let context: PurchaseOrderVendorCreditContext
    let onRecord: (
        _ reference: String,
        _ creditDate: Date,
        _ creditAmount: Double,
        _ restockingFee: Double,
        _ taxCredit: Double,
        _ shippingCredit: Double,
        _ sourceDocumentName: String?,
        _ quickBooksVendorCreditID: String?,
        _ note: String?
    ) -> String?

    @State private var reference = ""
    @State private var creditDate = Date()
    @State private var creditAmount: String
    @State private var restockingFee = "0"
    @State private var taxCredit = "0"
    @State private var shippingCredit = "0"
    @State private var sourceDocumentName = ""
    @State private var quickBooksVendorCreditID = ""
    @State private var note = ""
    @State private var validationMessage: String?
    @FocusState private var isEditing: Bool

    init(
        context: PurchaseOrderVendorCreditContext,
        onRecord: @escaping (
            _ reference: String,
            _ creditDate: Date,
            _ creditAmount: Double,
            _ restockingFee: Double,
            _ taxCredit: Double,
            _ shippingCredit: Double,
            _ sourceDocumentName: String?,
            _ quickBooksVendorCreditID: String?,
            _ note: String?
        ) -> String?
    ) {
        self.context = context
        self.onRecord = onRecord
        let expected = context.order.vendorCreditMatch(
            for: context.vendorReturn
        ).merchandiseAmount
        _creditAmount = State(initialValue: String(format: "%.2f", expected))
    }

    private var parsedCreditAmount: Double? { parsed(creditAmount) }
    private var parsedRestockingFee: Double? { parsed(restockingFee) }
    private var parsedTaxCredit: Double? { parsed(taxCredit) }
    private var parsedShippingCredit: Double? { parsed(shippingCredit) }

    private var expectedCreditAmount: Double? {
        guard let fee = parsedRestockingFee,
              let tax = parsedTaxCredit,
              let shipping = parsedShippingCredit else {
            return nil
        }
        let merchandise = context.order.vendorCreditMatch(
            for: context.vendorReturn
        ).merchandiseAmount
        return max(merchandise + tax + shipping - fee, 0)
    }

    private var canRecord: Bool {
        let normalizedReference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedReference.isEmpty,
              normalizedReference.count <= 120,
              creditDate <= Date(),
              let credit = parsedCreditAmount,
              let fee = parsedRestockingFee,
              let tax = parsedTaxCredit,
              let shipping = parsedShippingCredit else {
            return false
        }
        return [credit, fee, tax, shipping].allSatisfy {
            $0.isFinite && $0 >= 0 && $0 <= 1_000_000_000
        } &&
            sourceDocumentName.trimmingCharacters(in: .whitespacesAndNewlines).count <= 180 &&
            quickBooksVendorCreditID.trimmingCharacters(in: .whitespacesAndNewlines).count <= 80 &&
            note.trimmingCharacters(in: .whitespacesAndNewlines).count <= 240
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Supplier Credit") {
                    LabeledContent("Purchase order", value: context.order.number)
                    LabeledContent("RMA", value: context.vendorReturn.reference)
                    TextField("Credit memo or vendor credit reference", text: $reference)
                        .focused($isEditing)
                        .textInputAutocapitalization(.characters)
                        .accessibilityIdentifier("VendorCreditReference")
                    DatePicker("Credit date", selection: $creditDate, in: ...Date(), displayedComponents: .date)
                        .accessibilityIdentifier("VendorCreditDate")
                }
                Section("Reconciliation") {
                    TextField("Credit amount", text: $creditAmount)
                        .keyboardType(.decimalPad)
                        .focused($isEditing)
                        .accessibilityIdentifier("VendorCreditAmount")
                    TextField("Restocking fee", text: $restockingFee)
                        .keyboardType(.decimalPad)
                        .focused($isEditing)
                        .accessibilityIdentifier("VendorCreditRestockingFee")
                    TextField("Tax credited", text: $taxCredit)
                        .keyboardType(.decimalPad)
                        .focused($isEditing)
                        .accessibilityIdentifier("VendorCreditTax")
                    TextField("Freight credited", text: $shippingCredit)
                        .keyboardType(.decimalPad)
                        .focused($isEditing)
                        .accessibilityIdentifier("VendorCreditShipping")
                    if let expectedCreditAmount {
                        let actual = parsedCreditAmount ?? 0
                        LabeledContent(
                            "Expected net credit",
                            value: expectedCreditAmount.formatted(.currency(code: "USD"))
                        )
                        LabeledContent(
                            "Variance",
                            value: (actual - expectedCreditAmount).formatted(.currency(code: "USD"))
                        )
                        .foregroundStyle(abs(actual - expectedCreditAmount) <= 0.01 ? .green : .orange)
                    }
                }
                Section("Accounting Evidence") {
                    TextField("Credit document filename (optional)", text: $sourceDocumentName)
                        .focused($isEditing)
                        .accessibilityIdentifier("VendorCreditDocument")
                    TextField("QuickBooks Vendor Credit ID (optional)", text: $quickBooksVendorCreditID)
                        .focused($isEditing)
                        .accessibilityIdentifier("VendorCreditQuickBooksID")
                    TextField("Reconciliation note (optional)", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                        .focused($isEditing)
                        .accessibilityIdentifier("VendorCreditNote")
                    Text("This records reviewed evidence only. It does not create or change a QuickBooks Vendor Credit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Record Vendor Credit")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Record Credit") {
                        guard let credit = parsedCreditAmount,
                              let fee = parsedRestockingFee,
                              let tax = parsedTaxCredit,
                              let shipping = parsedShippingCredit else {
                            return
                        }
                        let document = sourceDocumentName
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let quickBooksID = quickBooksVendorCreditID
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let normalizedNote = note
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if let error = onRecord(
                            reference,
                            creditDate,
                            credit,
                            fee,
                            tax,
                            shipping,
                            document.isEmpty ? nil : document,
                            quickBooksID.isEmpty ? nil : quickBooksID,
                            normalizedNote.isEmpty ? nil : normalizedNote
                        ) {
                            validationMessage = error
                        } else {
                            dismiss()
                        }
                    }
                    .disabled(!canRecord)
                    .accessibilityIdentifier("ConfirmVendorCredit")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isEditing = false }
                        .accessibilityLabel("Done Editing Vendor Credit")
                }
            }
        }
    }

    private func parsed(_ value: String) -> Double? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
        guard let amount = Double(normalized), amount.isFinite else { return nil }
        return amount
    }
}

private struct PurchaseOrderAssetInstallationContext: Identifiable {
    let order: PurchaseOrder
    let job: ServiceCall
    let asset: PurchaseOrderReceivedAsset
    let line: PurchaseOrderLine?

    var id: UUID { asset.id }
}

private struct PurchaseOrderEquipmentInstallationSheet: View {
    @Environment(\.dismiss) private var dismiss

    let context: PurchaseOrderAssetInstallationContext
    let onInstall: (
        _ equipmentType: HVACEquipmentType,
        _ name: String,
        _ location: String?,
        _ installDate: Date,
        _ warrantyExpiration: Date?
    ) -> String?

    @State private var equipmentType: HVACEquipmentType
    @State private var name: String
    @State private var location: String
    @State private var installDate = Date()
    @State private var includesWarranty = false
    @State private var warrantyExpiration = Calendar.current.date(byAdding: .year, value: 10, to: Date()) ?? Date()
    @State private var validationMessage: String?

    init(
        context: PurchaseOrderAssetInstallationContext,
        onInstall: @escaping (
            _ equipmentType: HVACEquipmentType,
            _ name: String,
            _ location: String?,
            _ installDate: Date,
            _ warrantyExpiration: Date?
        ) -> String?
    ) {
        self.context = context
        self.onInstall = onInstall
        let suggestedName = context.line?.itemName ?? "Installed HVAC System"
        _equipmentType = State(initialValue: Self.inferredEquipmentType(from: suggestedName))
        _name = State(initialValue: suggestedName)
        _location = State(initialValue: context.job.equipmentLocation ?? "")
    }

    private var canInstall: Bool {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLocation = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty,
              normalizedName.count <= 100,
              normalizedLocation.count <= 100 else { return false }
        return EquipmentLifecyclePolicy.snapshot(
            installDate: installDate,
            warrantyExpiration: includesWarranty ? warrantyExpiration : nil
        ).validationMessage == nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Job Handoff") {
                    LabeledContent("Customer", value: context.job.customer.name)
                    LabeledContent("Job", value: context.job.type.displayName)
                    LabeledContent("Purchase order", value: context.order.number)
                    Text("This creates a CloudKit-backed customer system and links the installation evidence to this job. Existing invoice lines can then select the installed system.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Received Asset") {
                    LabeledContent("Serial", value: context.asset.serialNumber)
                    if let manufacturer = context.asset.manufacturer {
                        LabeledContent("Manufacturer", value: manufacturer)
                    }
                    if let modelNumber = context.asset.modelNumber {
                        LabeledContent("Model", value: modelNumber)
                    }
                }

                Section("Installed System") {
                    Picker("Equipment type", selection: $equipmentType) {
                        ForEach(HVACEquipmentType.allCases) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .accessibilityIdentifier("PurchaseOrderInstallEquipmentType")
                    TextField("System name", text: $name)
                        .accessibilityIdentifier("PurchaseOrderInstallEquipmentName")
                    TextField("Indoor, outdoor, attic, mechanical room, etc.", text: $location)
                        .accessibilityIdentifier("PurchaseOrderInstallEquipmentLocation")
                    DatePicker("Installed", selection: $installDate, in: ...Date(), displayedComponents: .date)
                        .accessibilityIdentifier("PurchaseOrderInstallDate")
                    Toggle("Record warranty expiration", isOn: $includesWarranty)
                    if includesWarranty {
                        DatePicker(
                            "Warranty expires",
                            selection: $warrantyExpiration,
                            in: installDate...,
                            displayedComponents: .date
                        )
                    }
                }

                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Add Customer System")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add System") {
                        let normalizedLocation = location.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let error = onInstall(
                            equipmentType,
                            name,
                            normalizedLocation.isEmpty ? nil : normalizedLocation,
                            installDate,
                            includesWarranty ? warrantyExpiration : nil
                        ) {
                            validationMessage = error
                        } else {
                            dismiss()
                        }
                    }
                    .disabled(!canInstall)
                    .accessibilityIdentifier("ConfirmPurchaseOrderAssetInstallation")
                }
            }
        }
    }

    private static func inferredEquipmentType(from value: String) -> HVACEquipmentType {
        let value = value.lowercased()
        if value.contains("heat pump") { return .heatPump }
        if value.contains("furnace") { return .gasFurnace }
        if value.contains("air handler") { return .airHandler }
        if value.contains("package") || value.contains("rooftop") { return .packageUnit }
        if value.contains("mini") || value.contains("ductless") { return .miniSplit }
        if value.contains("boiler") { return .boiler }
        if value.contains("water heater") { return .waterHeater }
        if value.contains("vent") { return .ventilation }
        return .splitSystemAC
    }
}

private struct PurchaseOrderReceiptSheet: View {
    @Environment(\.dismiss) private var dismiss

    let order: PurchaseOrder
    let defaultDestinations: [UUID: String]
    let inventoryTrackedLineIDs: Set<UUID>
    let onReceive: (
        _ lineID: UUID,
        _ quantity: Double,
        _ destination: String,
        _ note: String?,
        _ serialNumbers: [String],
        _ manufacturer: String?,
        _ modelNumber: String?
    ) -> String?

    @State private var selectedLineID: UUID
    @State private var quantityText: String
    @State private var destination: String
    @State private var note = ""
    @State private var serialCaptureEnabled: Bool
    @State private var serialNumbersText = ""
    @State private var manufacturer = ""
    @State private var modelNumber = ""
    @State private var validationMessage: String?
    @FocusState private var focusedField: ReceiptField?

    private enum ReceiptField: Hashable {
        case quantity
        case destination
        case note
        case manufacturer
        case modelNumber
        case serialNumbers
    }

    init(
        order: PurchaseOrder,
        defaultDestinations: [UUID: String],
        inventoryTrackedLineIDs: Set<UUID>,
        onReceive: @escaping (
            _ lineID: UUID,
            _ quantity: Double,
            _ destination: String,
            _ note: String?,
            _ serialNumbers: [String],
            _ manufacturer: String?,
            _ modelNumber: String?
        ) -> String?
    ) {
        self.order = order
        self.defaultDestinations = defaultDestinations
        self.inventoryTrackedLineIDs = inventoryTrackedLineIDs
        self.onReceive = onReceive
        let initialLine = order.purchaseOrderLines.first(where: {
            order.remainingQuantity(for: $0.id) > 0.0001
        }) ?? order.purchaseOrderLines[0]
        _selectedLineID = State(initialValue: initialLine.id)
        _quantityText = State(
            initialValue: order.remainingQuantity(for: initialLine.id)
                .formatted(.number.precision(.fractionLength(0...3)))
        )
        _destination = State(initialValue: defaultDestinations[initialLine.id] ?? "Warehouse")
        _serialCaptureEnabled = State(initialValue: initialLine.serialTrackingRequired == true)
    }

    private var openLines: [PurchaseOrderLine] {
        order.purchaseOrderLines.filter { order.remainingQuantity(for: $0.id) > 0.0001 }
    }

    private var selectedLine: PurchaseOrderLine? {
        order.line(for: selectedLineID)
    }

    private var selectedRemainingQuantity: Double {
        order.remainingQuantity(for: selectedLineID)
    }

    private var tracksInventory: Bool {
        inventoryTrackedLineIDs.contains(selectedLineID)
    }

    private var parsedQuantity: Double? {
        Double(quantityText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var parsedSerialNumbers: [String] {
        serialNumbersText
            .components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: ",;")))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var selectedLineRequiresSerials: Bool {
        selectedLine?.serialTrackingRequired == true
    }

    private var serializedInputIsValid: Bool {
        guard serialCaptureEnabled else { return !selectedLineRequiresSerials }
        guard let parsedQuantity,
              abs(parsedQuantity - parsedQuantity.rounded()) <= 0.0001,
              parsedQuantity >= 1,
              parsedQuantity <= 100,
              parsedSerialNumbers.count == Int(parsedQuantity),
              manufacturer.trimmingCharacters(in: .whitespacesAndNewlines).count <= 100,
              modelNumber.trimmingCharacters(in: .whitespacesAndNewlines).count <= 100 else {
            return false
        }
        let serialKeys = parsedSerialNumbers.map(EquipmentCodeLookup.normalizedSerial)
        return parsedSerialNumbers.allSatisfy { $0.count <= 80 } &&
            serialKeys.allSatisfy { $0.count >= 4 } &&
            Set(serialKeys).count == serialKeys.count
    }

    private var canReceive: Bool {
        guard let parsedQuantity,
              parsedQuantity.isFinite,
              parsedQuantity > 0.0001,
              parsedQuantity <= selectedRemainingQuantity + 0.0001 else {
            return false
        }
        let normalizedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalizedDestination.isEmpty &&
            normalizedDestination.count <= 100 &&
            note.trimmingCharacters(in: .whitespacesAndNewlines).count <= 240 &&
            serializedInputIsValid
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Open Purchase Order") {
                    LabeledContent("PO", value: order.number)
                    LabeledContent("Supplier", value: order.vendorName)
                    if openLines.count > 1 {
                        Picker("Item", selection: $selectedLineID) {
                            ForEach(openLines) { line in
                                Text(line.itemName).tag(line.id)
                            }
                        }
                        .accessibilityIdentifier("PurchaseOrderReceiptLine")
                        .onChange(of: selectedLineID) { _, lineID in
                            quantityText = order.remainingQuantity(for: lineID)
                                .formatted(.number.precision(.fractionLength(0...3)))
                            destination = defaultDestinations[lineID] ?? "Warehouse"
                            serialCaptureEnabled = order.line(for: lineID)?.serialTrackingRequired == true
                            serialNumbersText = ""
                            manufacturer = ""
                            modelNumber = ""
                            validationMessage = nil
                        }
                    } else if let selectedLine {
                        LabeledContent("Item", value: selectedLine.itemName)
                    }
                    LabeledContent(
                        "Open quantity",
                        value: selectedRemainingQuantity.formatted(.number.precision(.fractionLength(0...3)))
                    )
                }

                Section("Shipment") {
                    TextField("Quantity received", text: $quantityText)
                        .keyboardType(.decimalPad)
                        .focused($focusedField, equals: .quantity)
                        .accessibilityIdentifier("PurchaseOrderReceiptQuantity")

                    TextField("Truck, warehouse, job, or direct-ship destination", text: $destination)
                        .focused($focusedField, equals: .destination)
                        .accessibilityIdentifier("PurchaseOrderReceiptDestination")

                    TextField("Packing slip or backorder note (optional)", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                        .focused($focusedField, equals: .note)
                        .accessibilityIdentifier("PurchaseOrderReceiptNote")

                    Label(
                        tracksInventory
                            ? "This shipment will add only the entered quantity to the inventory ledger at this destination."
                            : "This receipt will update the purchase order only; no inventory-tracked pricebook item matches it.",
                        systemImage: tracksInventory ? "shippingbox.fill" : "doc.text"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section("Equipment Identity") {
                    if selectedLineRequiresSerials {
                        Label("Serial tracking required for this item", systemImage: "barcode.viewfinder")
                            .font(.caption.weight(.semibold))
                            .accessibilityIdentifier("PurchaseOrderReceiptSerialRequired")
                    } else {
                        Toggle("Capture serialized equipment", isOn: $serialCaptureEnabled)
                            .accessibilityIdentifier("PurchaseOrderReceiptSerialTracking")
                    }

                    if serialCaptureEnabled {
                        TextField("Manufacturer (optional)", text: $manufacturer)
                            .focused($focusedField, equals: .manufacturer)
                            .accessibilityIdentifier("PurchaseOrderReceiptManufacturer")
                        TextField("Model number (optional)", text: $modelNumber)
                            .focused($focusedField, equals: .modelNumber)
                            .accessibilityIdentifier("PurchaseOrderReceiptModel")
                        TextField("One serial number per line", text: $serialNumbersText, axis: .vertical)
                            .lineLimit(3...6)
                            .textInputAutocapitalization(.characters)
                            .focused($focusedField, equals: .serialNumbers)
                            .accessibilityIdentifier("PurchaseOrderReceiptSerialNumbers")
                        Text("\(parsedSerialNumbers.count) of \(Int(parsedQuantity?.rounded() ?? 0)) serials entered")
                            .font(.caption)
                            .foregroundStyle(serializedInputIsValid ? .green : .secondary)
                            .accessibilityIdentifier("PurchaseOrderReceiptSerialCount")
                    } else {
                        Text("Leave this off for bulk parts and supplies. Turn it on for equipment that must retain warranty and installed-system identity.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Receive Shipment")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(selectedRemainingQuantity == parsedQuantity ? "Receive Item" : "Receive Partial") {
                        guard let parsedQuantity else { return }
                        let normalizedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let error = onReceive(
                            selectedLineID,
                            parsedQuantity,
                            destination,
                            normalizedNote.isEmpty ? nil : normalizedNote,
                            serialCaptureEnabled ? parsedSerialNumbers : [],
                            manufacturer.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
                            modelNumber.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
                        ) {
                            validationMessage = error
                        } else {
                            dismiss()
                        }
                    }
                    .disabled(!canReceive)
                    .accessibilityIdentifier("ConfirmPurchaseOrderReceipt")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                        .accessibilityLabel("Done Editing Shipment")
                }
            }
        }
    }
}

private struct SupplierOrderLineCostDraft: Identifiable {
    let id: UUID
    let itemName: String
    var unitCostText: String
}

private struct SupplierOrderConfirmationSheet: View {
    @Environment(\.dismiss) private var dismiss

    private enum ConfirmationField: Int, CaseIterable {
        case reference
        case supplierLocation
        case unitCost
        case shippingCost
    }

    let order: PurchaseOrder
    let onConfirm: (SupplierOrderChannel, String, String?, [PurchaseOrderLineUnitCost], Double) -> String?
    let onConnectorConfirm: @MainActor (SupplierConnectorKind, String?) async -> String?

    @State private var channel: SupplierOrderChannel = .supplierPortal
    @State private var reference = ""
    @State private var supplierLocation = ""
    @State private var lineCostDrafts: [SupplierOrderLineCostDraft]
    @State private var shippingCostText: String
    @State private var validationMessage: String?
    @State private var connectors: [SupplierConnectorReadiness] = []
    @State private var selectedConnectorKind: SupplierConnectorKind?
    @State private var connectorLocation = ""
    @State private var connectorMessage: String?
    @State private var isLoadingConnectors = false
    @State private var isSubmittingConnector = false
    @FocusState private var focusedField: ConfirmationField?

    init(
        order: PurchaseOrder,
        onConfirm: @escaping (SupplierOrderChannel, String, String?, [PurchaseOrderLineUnitCost], Double) -> String?,
        onConnectorConfirm: @escaping @MainActor (SupplierConnectorKind, String?) async -> String?
    ) {
        self.order = order
        self.onConfirm = onConfirm
        self.onConnectorConfirm = onConnectorConfirm
        _lineCostDrafts = State(
            initialValue: order.purchaseOrderLines.map {
                SupplierOrderLineCostDraft(
                    id: $0.id,
                    itemName: $0.itemName,
                    unitCostText: String(format: "%.2f", $0.unitCost)
                )
            }
        )
        _shippingCostText = State(initialValue: String(format: "%.2f", order.shippingCost))
    }

    private var parsedLineCosts: [PurchaseOrderLineUnitCost]? {
        var costs: [PurchaseOrderLineUnitCost] = []
        for draft in lineCostDrafts {
            guard let cost = parseAmount(draft.unitCostText), cost.isFinite, cost >= 0 else {
                return nil
            }
            costs.append(PurchaseOrderLineUnitCost(lineID: draft.id, unitCost: cost))
        }
        return costs
    }

    private var parsedShippingCost: Double? {
        parseAmount(shippingCostText)
    }

    private var canConfirm: Bool {
        reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false &&
        reference.count <= 120 &&
        supplierLocation.count <= 120 &&
        parsedLineCosts?.count == order.lineCount &&
        parsedShippingCost.map { $0.isFinite && $0 >= 0 } == true
    }

    private var matchingReadyConnectors: [SupplierConnectorReadiness] {
        SupplierConnectorSelectionPolicy.orderableConnectors(
            for: order.vendorName,
            from: connectors
        )
    }

    private var canSubmitConnector: Bool {
        selectedConnectorKind != nil &&
            !order.purchaseOrderLines.isEmpty &&
            order.purchaseOrderLines.allSatisfy {
                $0.itemSKU?.nilIfBlank != nil || $0.vendorPartNumber?.nilIfBlank != nil
            }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Purchase Order") {
                    LabeledContent("PO", value: order.number)
                    LabeledContent("Supplier", value: order.vendorName)
                    LabeledContent(
                        order.lineCount == 1 ? "Item" : "Items",
                        value: order.lineCount == 1
                            ? "\(order.quantity.formatted()) × \(order.itemName)"
                            : "\(order.lineCount) item lines"
                    )
                }

                if GunnAireBackendService.isConfigured {
                    Section("Approved Connector") {
                        if isLoadingConnectors {
                            HStack {
                                ProgressView()
                                Text("Checking server-approved supplier connections…")
                            }
                        } else if matchingReadyConnectors.isEmpty {
                            Label(
                                "No approved connector is active for \(order.vendorName). Continue with manual supplier confirmation below.",
                                systemImage: "link.badge.plus"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        } else {
                            Picker("Connector", selection: $selectedConnectorKind) {
                                ForEach(matchingReadyConnectors) { connector in
                                    Text(connector.displayName)
                                        .tag(Optional(connector.kind))
                                }
                            }
                            .accessibilityIdentifier("SupplierConnectorPicker")

                            TextField("Branch or supplier location", text: $connectorLocation)
                                .accessibilityIdentifier("SupplierConnectorLocation")

                            Button {
                                submitConnectorOrder()
                            } label: {
                                Label(
                                    isSubmittingConnector ? "Submitting Secure Order…" : "Submit Through Approved Connector",
                                    systemImage: "lock.shield"
                                )
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canSubmitConnector || isSubmittingConnector)
                            .accessibilityIdentifier("SubmitSupplierConnectorOrder")

                            Text("Contract v\(SupplierConnectorContract.currentVersion) submits and reconciles all \(order.lineCount) purchase-order line\(order.lineCount == 1 ? "" : "s") by stable line ID.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if order.purchaseOrderLines.contains(where: {
                                $0.itemSKU?.nilIfBlank == nil && $0.vendorPartNumber?.nilIfBlank == nil
                            }) {
                                Text("Add an internal SKU or supplier part number to every line before using a connector.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }

                        if !connectors.isEmpty {
                            DisclosureGroup("Provider readiness") {
                                ForEach(connectors) { connector in
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack {
                                            Text(connector.displayName)
                                            Spacer()
                                            Text(connector.statusLabel)
                                                .foregroundStyle(connector.isReady ? .green : .secondary)
                                        }
                                        .font(.caption.weight(.semibold))
                                        Text(connector.detail)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        if let urlText = connector.onboardingURL,
                                           let url = URL(string: urlText),
                                           !connector.isReady {
                                            Link("Supplier onboarding information", destination: url)
                                                .font(.caption2)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }

                        if let connectorMessage {
                            Label(connectorMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section("Supplier Acceptance") {
                    Picker("Channel", selection: $channel) {
                        ForEach(SupplierOrderChannel.manualCases) { channel in
                            Text(channel.displayName).tag(channel)
                        }
                    }
                    .accessibilityIdentifier("SupplierOrderChannel")

                    TextField("Supplier confirmation / order reference", text: $reference)
                        .textInputAutocapitalization(.characters)
                        .focused($focusedField, equals: .reference)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .supplierLocation }
                        .accessibilityIdentifier("SupplierOrderReference")

                    TextField("Branch or supplier location (optional)", text: $supplierLocation)
                        .focused($focusedField, equals: .supplierLocation)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .unitCost }
                        .accessibilityIdentifier("SupplierOrderLocation")

                    ForEach($lineCostDrafts) { $draft in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(draft.itemName)
                                .font(.caption.weight(.semibold))
                            TextField("Confirmed unit cost", text: $draft.unitCostText)
                                .keyboardType(.decimalPad)
                                .focused($focusedField, equals: .unitCost)
                                .accessibilityIdentifier(
                                    draft.id == lineCostDrafts.first?.id
                                        ? "SupplierOrderUnitCost"
                                        : "SupplierOrderUnitCost-\(draft.id.uuidString)"
                                )
                        }
                    }

                    TextField("Confirmed freight", text: $shippingCostText)
                        .keyboardType(.decimalPad)
                        .focused($focusedField, equals: .shippingCost)
                        .accessibilityIdentifier("SupplierOrderShippingCost")

                    Text("Record evidence only after the supplier accepts the order. This does not transmit anything or store supplier credentials.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle(order.status == .ordered ? "Add Order Evidence" : "Confirm Supplier Order")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Record Confirmation") {
                        guard let lineCosts = parsedLineCosts,
                              let shippingCost = parsedShippingCost else { return }
                        if let error = onConfirm(
                            channel,
                            reference,
                            supplierLocation,
                            lineCosts,
                            shippingCost
                        ) {
                            validationMessage = error
                        } else {
                            dismiss()
                        }
                    }
                    .disabled(!canConfirm)
                    .accessibilityIdentifier("ConfirmSupplierOrder")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Button {
                        moveFocus(by: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(!canMoveFocus(by: -1))
                    .accessibilityLabel("Previous Supplier Field")

                    Button {
                        moveFocus(by: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(!canMoveFocus(by: 1))
                    .accessibilityLabel("Next Supplier Field")

                    Spacer()

                    Button("Done") {
                        focusedField = nil
                    }
                    .accessibilityLabel("Done Editing Supplier Order")
                }
            }
            .task(id: order.id) {
                await loadConnectorReadiness()
            }
        }
    }

    private func canMoveFocus(by offset: Int) -> Bool {
        guard let focusedField,
              let index = ConfirmationField.allCases.firstIndex(of: focusedField) else {
            return false
        }
        return ConfirmationField.allCases.indices.contains(index + offset)
    }

    private func moveFocus(by offset: Int) {
        guard let focusedField,
              let index = ConfirmationField.allCases.firstIndex(of: focusedField),
              ConfirmationField.allCases.indices.contains(index + offset) else {
            return
        }
        self.focusedField = ConfirmationField.allCases[index + offset]
    }

    @MainActor
    private func loadConnectorReadiness() async {
        guard GunnAireBackendService.isConfigured else { return }
        isLoadingConnectors = true
        connectorMessage = nil
        do {
            connectors = try await GunnAireBackendService.fetchSupplierConnectors()
            selectedConnectorKind = SupplierConnectorSelectionPolicy.preferredConnectorKind(
                for: order.vendorName,
                from: connectors
            )
        } catch {
            connectors = []
            selectedConnectorKind = nil
            connectorMessage = "Connector readiness could not be loaded. Manual confirmation remains available. \(error.localizedDescription)"
        }
        isLoadingConnectors = false
    }

    private func submitConnectorOrder() {
        guard let selectedConnectorKind, canSubmitConnector else { return }
        isSubmittingConnector = true
        connectorMessage = nil
        Task { @MainActor in
            if let error = await onConnectorConfirm(
                selectedConnectorKind,
                connectorLocation.nilIfBlank
            ) {
                connectorMessage = error
                isSubmittingConnector = false
            } else {
                isSubmittingConnector = false
                dismiss()
            }
        }
    }

    private func parseAmount(_ value: String) -> Double? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
        return Double(normalized)
    }
}

private struct InventoryCycleCountSheet: View {
    @Environment(\.dismiss) private var dismiss

    let item: Item
    let reservedQuantity: Double
    let expectedQuantity: (String) -> Double
    let onSave: (String, Double, String) -> String?

    @State private var location: String
    @State private var countedQuantityText = ""
    @State private var reason = ""
    @State private var validationMessage: String?

    init(
        item: Item,
        initialLocation: String,
        reservedQuantity: Double,
        expectedQuantity: @escaping (String) -> Double,
        onSave: @escaping (String, Double, String) -> String?
    ) {
        self.item = item
        self.reservedQuantity = reservedQuantity
        self.expectedQuantity = expectedQuantity
        self.onSave = onSave
        _location = State(initialValue: initialLocation)
    }

    private var normalizedLocation: String {
        location
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }

    private var parsedCount: Double? {
        Double(countedQuantityText.replacingOccurrences(of: ",", with: ""))
    }

    private var ledgerQuantity: Double {
        expectedQuantity(normalizedLocation)
    }

    private var varianceQuantity: Double? {
        parsedCount.map { $0 - ledgerQuantity }
    }

    private var canSave: Bool {
        guard !normalizedLocation.isEmpty,
              normalizedLocation.count <= 100,
              let parsedCount,
              parsedCount.isFinite,
              parsedCount >= 0,
              parsedCount <= 1_000_000,
              reason.count <= 240 else { return false }
        return abs(parsedCount - ledgerQuantity) <= 0.0001 ||
            !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Item") {
                    LabeledContent("Pricebook item", value: item.name)
                    if let sku = item.sku, !sku.isEmpty {
                        LabeledContent("SKU", value: sku)
                    }
                }

                Section("Physical Count") {
                    TextField("Truck, warehouse, or stock location", text: $location)
                        .accessibilityIdentifier("InventoryCountLocation")
                    LabeledContent(
                        "Ledger quantity",
                        value: ledgerQuantity.formatted(.number.precision(.fractionLength(0...3)))
                    )
                    TextField("Counted quantity", text: $countedQuantityText)
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("InventoryCountQuantity")
                    if let varianceQuantity {
                        LabeledContent(
                            "Variance",
                            value: varianceQuantity.formatted(.number.precision(.fractionLength(0...3)).sign(strategy: .always()))
                        )
                        .foregroundStyle(abs(varianceQuantity) <= 0.0001 ? Color.secondary : Color.orange)
                    }
                }

                Section("Count Evidence") {
                    TextField("Variance reason or count note", text: $reason, axis: .vertical)
                        .lineLimit(2...4)
                        .accessibilityIdentifier("InventoryCountReason")
                    Text("A reason is required when the physical count differs from the ledger. The entry records the expected count, actual count, variance, date, and signed-in administrator.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Reservations") {
                    LabeledContent(
                        "Open reserved quantity",
                        value: reservedQuantity.formatted(.number.precision(.fractionLength(0...3)))
                    )
                    Text("The count reconciles physical stock only. Job reservations remain intact and continue to reduce available stock separately.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Count Inventory")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save Count") {
                        guard let parsedCount else { return }
                        if let error = onSave(location, parsedCount, reason) {
                            validationMessage = error
                        } else {
                            dismiss()
                        }
                    }
                    .disabled(!canSave)
                    .accessibilityIdentifier("SaveInventoryCount")
                }
            }
        }
    }
}

private extension ReceiptsAndBillsView {
    struct AttachTargetOption: Identifiable {
        let idValue: String
        let label: String
        var id: String { idValue }
    }

    struct PendingUploadDetailSheet: View {
        let pending: PendingUploadRecord
        let isSyncing: Bool
        let onRetryNow: () -> Void
        let onDelete: () -> Void
        let onToggleTerminal: () -> Void
        let onClose: () -> Void

        var body: some View {
            NavigationStack {
                Form {
                    Section("File") {
                        Text(pending.displayName)
                        Text(pending.filePath)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }

                    Section("Queue State") {
                        Text("Created: \(pending.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        Text("Retries: \(pending.retryCount)")
                        if let lastAttemptAt = pending.lastAttemptAt {
                            Text("Last attempt: \(lastAttemptAt.formatted(date: .abbreviated, time: .shortened))")
                        }
                        if let nextRetryAt = pending.nextRetryAt {
                            Text("Next retry: \(nextRetryAt.formatted(date: .abbreviated, time: .shortened))")
                        }
                        Text("Terminal failure: \(pending.isTerminalFailure ? "Yes" : "No")")
                            .foregroundColor(pending.isTerminalFailure ? .orange : .secondary)
                        if let error = pending.lastError, !error.isEmpty {
                            Text("Last error: \(error)")
                                .foregroundColor(.red)
                                .font(.caption)
                        }
                    }

                    if let entityType = pending.entityTypeRaw, let entityID = pending.entityID {
                        Section("Linked Entity") {
                            Text("Type: \(entityType)")
                            Text("ID: \(entityID)")
                        }
                    }

                    Section("Actions") {
                        Button("Retry Now") { onRetryNow() }
                            .disabled(isSyncing)
                        Button(pending.isTerminalFailure ? "Mark As Retryable" : "Mark As Terminal") { onToggleTerminal() }
                            .disabled(isSyncing)
                        Button("Delete Entry", role: .destructive) { onDelete() }
                            .disabled(isSyncing)
                    }
                }
                .navigationTitle("Queue Item")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { onClose() }
                    }
                }
            }
        }
    }

    enum DocumentType {
        case receipt
        case bill
    }

    @discardableResult
    func requireAdministrator(for action: String) -> Bool {
        guard isAdminUser else {
            selectedWorkspace = .documents
            syncMessage = "\(action) requires an active administrator account. No changes were made."
            return false
        }
        return true
    }

    @MainActor
    func uploadReceiptToBackend() async {
        guard let receiptURL else {
            backendUploadMessage = "Select a receipt first."
            return
        }
        guard GunnAireBackendService.isConfigured else {
            backendUploadMessage = "Shared company storage is not configured."
            return
        }

        isUploadingReceiptToBackend = true
        defer { isUploadingReceiptToBackend = false }

        do {
            let didStartAccessing = receiptURL.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    receiptURL.stopAccessingSecurityScopedResource()
                }
            }

            let data = try Data(contentsOf: receiptURL)
            let contentType = UTType(filenameExtension: receiptURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let response = try await GunnAireBackendService.uploadDocument(
                data: data,
                filename: receiptURL.lastPathComponent,
                contentType: contentType,
                kind: "receipt",
                serviceCallID: selectedServiceCallID,
                invoiceID: nil,
                estimateID: nil,
                customerEquipmentID: selectedServiceCall?.customerEquipmentID,
                equipmentName: selectedServiceCall?.equipmentSummary,
                customerName: selectedServiceCall?.customer.name
            )
            backendUploadMessage = "Receipt uploaded to company storage: \(response.filename)."
        } catch {
            backendUploadMessage = "Receipt upload failed: \(error.localizedDescription)"
        }
    }

    func importDocument(from url: URL, as type: DocumentType) throws {
        let data = try Data(contentsOf: url)
        let extensionName = url.pathExtension.lowercased()
        let image = UIImage(data: data)

        switch type {
        case .receipt:
            receiptImportMessage = nil
            receiptURL = url
            if let image {
                receiptImage = image
                receiptImportMessage = "Image selected: \(url.lastPathComponent)"
            } else if extensionName == "pdf" {
                receiptImage = nil
                receiptImportMessage = "PDF selected: \(url.lastPathComponent)"
            } else if ["txt", "rtf"].contains(extensionName) {
                receiptImage = nil
                receiptImportMessage = "Text document selected: \(url.lastPathComponent)"
            } else {
                receiptURL = nil
                receiptImage = nil
                receiptImportMessage = "Unsupported file type"
            }
        case .bill:
            billImportMessage = nil
            billURL = url
            if let image {
                billImage = image
                billImportMessage = "Image selected: \(url.lastPathComponent)"
            } else if extensionName == "pdf" {
                billImage = nil
                billImportMessage = "PDF selected: \(url.lastPathComponent)"
            } else if ["txt", "rtf"].contains(extensionName) {
                billImage = nil
                billImportMessage = "Text document selected: \(url.lastPathComponent)"
            } else {
                billURL = nil
                billImage = nil
                billImportMessage = "Unsupported file type"
            }
        }
    }

    func syncDocuments() {
        guard requireAdministrator(for: "QuickBooks document sync") else { return }
        let selectedFiles = [receiptURL, billURL].compactMap { $0 }
        guard !selectedFiles.isEmpty else {
            syncMessage = "Select at least one file before syncing."
            return
        }

        isSyncing = true
        syncMessage = nil

        let referenceID = attachEntityID.trimmingCharacters(in: .whitespacesAndNewlines)
        let entityType = referenceID.isEmpty ? nil : selectedAttachEntityType

        guard QuickBooksDataAPI.shared.isAuthenticated else {
            let queuedRecords = selectedFiles.map { url in
                PendingUploadRecord(
                    id: UUID(),
                    filePath: url.path,
                    displayName: url.lastPathComponent,
                    entityTypeRaw: entityType?.rawValue,
                    entityID: referenceID.isEmpty ? nil : referenceID,
                    createdAt: Date(),
                    retryCount: 0,
                    lastAttemptAt: nil,
                    nextRetryAt: Date(),
                    isTerminalFailure: false,
                    lastError: "QuickBooks was disconnected when this file was selected."
                )
            }
            appendPendingUploads(queuedRecords)
            isSyncing = false
            syncMessage = "QuickBooks is not connected. Queued \(queuedRecords.count) file(s) for live upload after reconnect."
            return
        }

        let group = DispatchGroup()
        var uploadedIDs: [String] = []
        var failures: [String] = []
        var failedPendingRecords: [PendingUploadRecord] = []
        let resultQueue = DispatchQueue(label: "com.gunnaire.receipts.sync-results")

        for url in selectedFiles {
            group.enter()
            QuickBooksDataAPI.shared.uploadDocument(
                fileURL: url,
                note: nil,
                attachToEntityType: entityType,
                attachToEntityID: referenceID.isEmpty ? nil : referenceID
            ) { result in
                switch result {
                case .success(let id):
                    resultQueue.sync { uploadedIDs.append(id) }
                case .failure(let error):
                    resultQueue.sync {
                        let message = "\(url.lastPathComponent): \(error.localizedDescription)"
                        failures.append(message)
                        failedPendingRecords.append(
                            PendingUploadRecord(
                                id: UUID(),
                                filePath: url.path,
                                displayName: url.lastPathComponent,
                                entityTypeRaw: entityType?.rawValue,
                                entityID: referenceID.isEmpty ? nil : referenceID,
                                createdAt: Date(),
                                retryCount: 0,
                                lastAttemptAt: nil,
                                nextRetryAt: Date(),
                                isTerminalFailure: false,
                                lastError: error.localizedDescription
                            )
                        )
                    }
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            isSyncing = false
            if failures.isEmpty {
                applyDocumentationProgress(forUploadedFileCount: uploadedIDs.count)
                syncMessage = "Upload complete. Synced \(uploadedIDs.count) file(s) to QuickBooks."
            } else {
                if uploadedIDs.count > 0 {
                    applyDocumentationProgress(forUploadedFileCount: uploadedIDs.count)
                }
                appendPendingUploads(failedPendingRecords)
                syncMessage = "Partial sync: \(uploadedIDs.count) uploaded, \(failures.count) failed.\n\(failures.joined(separator: "\n"))"
            }
        }
    }

    func retryPendingUploads() {
        guard requireAdministrator(for: "Retrying QuickBooks uploads") else { return }
        guard !pendingUploads.isEmpty else { return }
        guard QuickBooksDataAPI.shared.isAuthenticated else {
            syncMessage = "Connect QuickBooks before retrying queued uploads."
            return
        }

        isSyncing = true
        syncMessage = nil

        let group = DispatchGroup()
        let now = Date()
        var succeededCount = 0
        var remaining: [PendingUploadRecord] = []
        var deferredCount = 0
        let resultQueue = DispatchQueue(label: "com.gunnaire.receipts.retry-results")

        for pending in pendingUploads {
            if pending.isTerminalFailure {
                remaining.append(pending)
                continue
            }
            if let nextRetryAt = pending.nextRetryAt, nextRetryAt > now {
                deferredCount += 1
                remaining.append(pending)
                continue
            }

            group.enter()

            let fileURL = URL(fileURLWithPath: pending.filePath)
            let entityType = pending.entityTypeRaw.flatMap { QuickBooksAttachableEntityType(rawValue: $0) }

            guard FileManager.default.fileExists(atPath: pending.filePath) else {
                resultQueue.sync {
                    var updated = pending
                    updated.lastError = "File no longer exists at path."
                    updated.lastAttemptAt = Date()
                    updated.retryCount += 1
                    updated.nextRetryAt = Date().addingTimeInterval(backoffInterval(forRetryCount: updated.retryCount))
                    if updated.retryCount >= maxAutoRetryCount {
                        updated.isTerminalFailure = true
                        updated.nextRetryAt = nil
                    }
                    remaining.append(updated)
                }
                group.leave()
                continue
            }

            QuickBooksDataAPI.shared.uploadDocument(
                fileURL: fileURL,
                note: nil,
                attachToEntityType: entityType,
                attachToEntityID: pending.entityID
            ) { result in
                resultQueue.sync {
                    switch result {
                    case .success:
                        succeededCount += 1
                    case .failure(let error):
                        var updated = pending
                        updated.lastError = error.localizedDescription
                        updated.lastAttemptAt = Date()
                        updated.retryCount += 1
                        updated.nextRetryAt = Date().addingTimeInterval(backoffInterval(forRetryCount: updated.retryCount))
                        if updated.retryCount >= maxAutoRetryCount {
                            updated.isTerminalFailure = true
                            updated.nextRetryAt = nil
                        }
                        remaining.append(updated)
                    }
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            isSyncing = false
            pendingUploads = remaining
            sortPendingUploads()
            savePendingUploads()
            if remaining.isEmpty {
                syncMessage = "Retry complete. Uploaded \(succeededCount) queued file(s)."
            } else {
                let terminals = remaining.filter(\.isTerminalFailure).count
                syncMessage = "Retry complete. Uploaded \(succeededCount), deferred \(deferredCount), terminal \(terminals), still queued \(remaining.count)."
            }
        }
    }

    func retryPendingUpload(_ pending: PendingUploadRecord, ignoreBackoff: Bool) {
        guard requireAdministrator(for: "Retrying QuickBooks uploads") else { return }
        guard !isSyncing else { return }
        guard QuickBooksDataAPI.shared.isAuthenticated else {
            syncMessage = "Connect QuickBooks before retrying queued uploads."
            return
        }

        if !ignoreBackoff, let nextRetryAt = pending.nextRetryAt, nextRetryAt > Date() {
            syncMessage = "This upload is deferred until \(nextRetryAt.formatted(date: .abbreviated, time: .shortened))."
            return
        }

        isSyncing = true
        syncMessage = "Retrying \(pending.displayName)..."

        guard FileManager.default.fileExists(atPath: pending.filePath) else {
            var updated = pending
            updated.lastError = "File no longer exists at path."
            updated.lastAttemptAt = Date()
            updated.retryCount += 1
            updated.nextRetryAt = Date().addingTimeInterval(backoffInterval(forRetryCount: updated.retryCount))
            if updated.retryCount >= maxAutoRetryCount {
                updated.isTerminalFailure = true
                updated.nextRetryAt = nil
            }
            upsertPendingUpload(updated)
            isSyncing = false
            syncMessage = "Retry failed: missing file."
            return
        }

        let fileURL = URL(fileURLWithPath: pending.filePath)
        let entityType = pending.entityTypeRaw.flatMap { QuickBooksAttachableEntityType(rawValue: $0) }

        QuickBooksDataAPI.shared.uploadDocument(
            fileURL: fileURL,
            note: nil,
            attachToEntityType: entityType,
            attachToEntityID: pending.entityID
        ) { result in
            DispatchQueue.main.async {
                isSyncing = false
                switch result {
                case .success:
                    removePendingUpload(pending.id)
                    syncMessage = "Retry succeeded for \(pending.displayName)."
                case .failure(let error):
                    var updated = pending
                    updated.lastError = error.localizedDescription
                    updated.lastAttemptAt = Date()
                    updated.retryCount += 1
                    updated.nextRetryAt = Date().addingTimeInterval(backoffInterval(forRetryCount: updated.retryCount))
                    if updated.retryCount >= maxAutoRetryCount {
                        updated.isTerminalFailure = true
                        updated.nextRetryAt = nil
                    } else {
                        updated.isTerminalFailure = false
                    }
                    upsertPendingUpload(updated)
                    syncMessage = "Retry failed for \(pending.displayName): \(error.localizedDescription)"
                }
            }
        }
    }

    func backoffInterval(forRetryCount retryCount: Int) -> TimeInterval {
        // 30s, 60s, 120s... capped at 1 hour.
        let base: TimeInterval = 30
        let exponent = max(0, retryCount - 1)
        let multiplier = Double(1 << min(exponent, 20))
        let raw = base * multiplier
        return min(raw, 3600)
    }

    func appendPendingUploads(_ records: [PendingUploadRecord]) {
        guard !records.isEmpty else { return }
        for record in records {
            let alreadyQueued = pendingUploads.contains {
                $0.filePath == record.filePath &&
                $0.entityTypeRaw == record.entityTypeRaw &&
                $0.entityID == record.entityID
            }
            if !alreadyQueued {
                pendingUploads.append(record)
            }
        }
        sortPendingUploads()
        savePendingUploads()
    }

    func removePendingUpload(_ id: UUID) {
        pendingUploads.removeAll { $0.id == id }
        sortPendingUploads()
        savePendingUploads()
    }

    func upsertPendingUpload(_ updated: PendingUploadRecord) {
        if let index = pendingUploads.firstIndex(where: { $0.id == updated.id }) {
            pendingUploads[index] = updated
        } else {
            pendingUploads.append(updated)
        }
        sortPendingUploads()
        savePendingUploads()
    }

    func setPendingUploadTerminalStatus(id: UUID, isTerminal: Bool) {
        guard requireAdministrator(for: "Changing QuickBooks retry state") else { return }
        guard let index = pendingUploads.firstIndex(where: { $0.id == id }) else { return }
        pendingUploads[index].isTerminalFailure = isTerminal
        if isTerminal {
            pendingUploads[index].nextRetryAt = nil
        } else if pendingUploads[index].nextRetryAt == nil {
            pendingUploads[index].nextRetryAt = Date()
        }
        sortPendingUploads()
        savePendingUploads()
    }

    func refreshPendingUploadDetails(for pending: PendingUploadRecord) -> PendingUploadRecord {
        pendingUploads.first(where: { $0.id == pending.id }) ?? pending
    }

    func purgeMissingFileEntries() {
        guard requireAdministrator(for: "Purging QuickBooks retry records") else { return }
        let before = pendingUploads.count
        pendingUploads.removeAll { !FileManager.default.fileExists(atPath: $0.filePath) }
        sortPendingUploads()
        savePendingUploads()
        let removed = before - pendingUploads.count
        syncMessage = removed > 0 ? "Purged \(removed) queue item(s) with missing files." : "No missing-file queue entries to purge."
    }

    func sortPendingUploads() {
        pendingUploads.sort { lhs, rhs in
            if lhs.isTerminalFailure != rhs.isTerminalFailure {
                return !lhs.isTerminalFailure
            }
            let lhsNext = lhs.nextRetryAt ?? .distantPast
            let rhsNext = rhs.nextRetryAt ?? .distantPast
            if lhsNext != rhsNext {
                return lhsNext < rhsNext
            }
            return lhs.createdAt < rhs.createdAt
        }
    }

    func loadPendingUploads() {
        guard let data = UserDefaults.standard.data(forKey: pendingUploadsStorageKey) else {
            return
        }
        if let decoded = try? JSONDecoder().decode([PendingUploadRecord].self, from: data) {
            pendingUploads = decoded
            sortPendingUploads()
            return
        }
        if let legacy = try? JSONDecoder().decode([LegacyPendingUploadRecord].self, from: data) {
            pendingUploads = legacy.map {
                PendingUploadRecord(
                    id: $0.id,
                    filePath: $0.filePath,
                    displayName: $0.displayName,
                    entityTypeRaw: $0.entityTypeRaw,
                    entityID: $0.entityID,
                    createdAt: $0.createdAt,
                    retryCount: 0,
                    lastAttemptAt: nil,
                    nextRetryAt: Date(),
                    isTerminalFailure: false,
                    lastError: $0.lastError
                )
            }
            sortPendingUploads()
            savePendingUploads()
        }
    }

    func savePendingUploads() {
        guard let data = try? JSONEncoder().encode(pendingUploads) else { return }
        UserDefaults.standard.set(data, forKey: pendingUploadsStorageKey)
    }

    func currencyString(_ amount: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: amount)) ?? String(format: "$%.2f", amount)
    }

    func loadAttachableTargets() {
        guard requireAdministrator(for: "Loading QuickBooks attachment targets") else { return }
        isLoadingAttachTargets = true
        attachLookupMessage = nil
        attachTargetOptions = []
        selectedAttachTargetID = ""

        guard QuickBooksDataAPI.shared.isAuthenticated else {
            isLoadingAttachTargets = false
            attachLookupMessage = "Connect QuickBooks first to load existing IDs."
            return
        }

        switch selectedAttachEntityType {
        case .estimate:
            QuickBooksDataAPI.shared.fetchEstimates { result in
                DispatchQueue.main.async {
                    isLoadingAttachTargets = false
                    switch result {
                    case .success(let estimates):
                        attachTargetOptions = estimates.map {
                            AttachTargetOption(
                                idValue: $0.Id,
                                label: "Estimate \($0.Id) • \(currencyString($0.TotalAmt)) • \($0.TxnDate ?? "No date")"
                            )
                        }
                        attachLookupMessage = attachTargetOptions.isEmpty ? "No estimates found." : "Loaded \(attachTargetOptions.count) estimate ID(s)."
                    case .failure(let error):
                        attachLookupMessage = "Failed to load estimates: \(error.localizedDescription)"
                    }
                }
            }
        case .invoice:
            QuickBooksDataAPI.shared.fetchInvoices { result in
                DispatchQueue.main.async {
                    isLoadingAttachTargets = false
                    switch result {
                    case .success(let invoices):
                        attachTargetOptions = invoices.map {
                            AttachTargetOption(
                                idValue: $0.Id,
                                label: "Invoice \($0.Id) • \(currencyString($0.TotalAmt)) • \($0.TxnDate ?? "No date")"
                            )
                        }
                        attachLookupMessage = attachTargetOptions.isEmpty ? "No invoices found." : "Loaded \(attachTargetOptions.count) invoice ID(s)."
                    case .failure(let error):
                        attachLookupMessage = "Failed to load invoices: \(error.localizedDescription)"
                    }
                }
            }
        case .bill:
            QuickBooksDataAPI.shared.fetchBills { result in
                DispatchQueue.main.async {
                    isLoadingAttachTargets = false
                    switch result {
                    case .success(let bills):
                        attachTargetOptions = bills.map {
                            AttachTargetOption(
                                idValue: $0.Id,
                                label: "Bill \($0.Id) • \(currencyString($0.TotalAmt)) • \($0.TxnDate ?? "No date")"
                            )
                        }
                        attachLookupMessage = attachTargetOptions.isEmpty ? "No bills found." : "Loaded \(attachTargetOptions.count) bill ID(s)."
                    case .failure(let error):
                        attachLookupMessage = "Failed to load bills: \(error.localizedDescription)"
                    }
                }
            }
        case .payment:
            QuickBooksDataAPI.shared.fetchPayments { result in
                DispatchQueue.main.async {
                    isLoadingAttachTargets = false
                    switch result {
                    case .success(let payments):
                        attachTargetOptions = payments.map {
                            let customer = $0.CustomerRef?.name ?? $0.CustomerRef?.value ?? "Unknown"
                            return AttachTargetOption(
                                idValue: $0.Id,
                                label: "Payment \($0.Id) • \(customer) • \(currencyString($0.TotalAmt))"
                            )
                        }
                        attachLookupMessage = attachTargetOptions.isEmpty ? "No payments found." : "Loaded \(attachTargetOptions.count) payment ID(s)."
                    case .failure(let error):
                        attachLookupMessage = "Failed to load payments: \(error.localizedDescription)"
                    }
                }
            }
        case .salesReceipt:
            QuickBooksDataAPI.shared.fetchSalesReceipts { result in
                DispatchQueue.main.async {
                    isLoadingAttachTargets = false
                    switch result {
                    case .success(let salesReceipts):
                        attachTargetOptions = salesReceipts.map {
                            let customer = $0.CustomerRef?.displayName ?? "Walk-in customer"
                            return AttachTargetOption(
                                idValue: $0.Id,
                                label: "Sales Receipt \($0.Id) • \(customer) • \(currencyString($0.TotalAmt))"
                            )
                        }
                        attachLookupMessage = attachTargetOptions.isEmpty ? "No sales receipts found." : "Loaded \(attachTargetOptions.count) sales receipt ID(s)."
                    case .failure(let error):
                        attachLookupMessage = "Failed to load sales receipts: \(error.localizedDescription)"
                    }
                }
            }
        case .purchase:
            QuickBooksDataAPI.shared.fetchPurchases { result in
                DispatchQueue.main.async {
                    isLoadingAttachTargets = false
                    switch result {
                    case .success(let purchases):
                        attachTargetOptions = purchases.map {
                            let vendor = $0.EntityRef?.displayName ?? "Expense purchase"
                            return AttachTargetOption(
                                idValue: $0.Id,
                                label: "Purchase \($0.Id) • \(vendor) • \(currencyString($0.TotalAmt))"
                            )
                        }
                        attachLookupMessage = attachTargetOptions.isEmpty ? "No purchases found." : "Loaded \(attachTargetOptions.count) purchase ID(s)."
                    case .failure(let error):
                        attachLookupMessage = "Failed to load purchases: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    func handleCapturedReceiptImage(_ image: UIImage) {
        receiptImage = image
        do {
            let url = try persistImageToTemporaryFile(image: image, prefix: "receipt-camera")
            receiptURL = url
            receiptImportMessage = "Camera image captured: \(url.lastPathComponent)"
        } catch {
            receiptURL = nil
            receiptImportMessage = "Failed to save camera image: \(error.localizedDescription)"
        }
    }

    func persistImageToTemporaryFile(image: UIImage, prefix: String) throws -> URL {
        guard let data = image.jpegData(compressionQuality: 0.85) else {
            throw NSError(domain: "ReceiptsAndBills", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not encode JPEG data."])
        }
        let filename = "\(prefix)-\(UUID().uuidString).jpg"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }

    func applyLinkedServiceCallDefaults() {
        guard let selectedServiceCall else { return }
        if let linkedInvoiceID = selectedServiceCall.linkedInvoiceID,
           let invoice = invoices.first(where: { $0.id == linkedInvoiceID }),
           let quickBooksID = invoice.quickBooksID,
           !quickBooksID.isEmpty {
            selectedAttachEntityType = .invoice
            if attachEntityID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                attachEntityID = quickBooksID
            }
        } else if let linkedEstimateID = selectedServiceCall.linkedEstimateID,
                  let estimate = estimates.first(where: { $0.id == linkedEstimateID }),
                  let quickBooksID = estimate.quickBooksID,
                  !quickBooksID.isEmpty {
            selectedAttachEntityType = .invoice
            if attachEntityID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                attachEntityID = quickBooksID
            }
        }
    }

    func applyPurchaseOrderItemDefaults() {
        guard let item = selectedPurchaseOrderItem else { return }
        if let preferredVendorID = item.preferredVendorQuickBooksID,
           let vendor = vendors.first(where: { $0.quickBooksID == preferredVendorID }) {
            newPurchaseOrderVendorID = vendor.id
        } else if let preferredVendorName = item.preferredVendorName,
                  let vendor = vendors.first(where: { $0.name.caseInsensitiveCompare(preferredVendorName) == .orderedSame }) {
            newPurchaseOrderVendorID = vendor.id
        }
        if newPurchaseOrderUnitCost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let purchaseCost = item.purchaseCost {
            newPurchaseOrderUnitCost = String(format: "%.2f", purchaseCost)
        }
    }

    func applyInventoryItemDefaults() {
        guard let item = selectedInventoryItem else { return }
        let location = item.defaultInventoryLocation?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let location, !location.isEmpty {
            inventorySourceLocation = location
            inventoryDestinationLocation = location
        }
        inventoryMessage = nil
    }

    func reconcileInventoryCount(
        for item: Item,
        location: String,
        countedQuantity: Double,
        reason: String
    ) -> String? {
        do {
            let movement = try InventoryCycleCountPolicy.adjustment(
                for: item,
                location: location,
                countedQuantity: countedQuantity,
                reason: reason,
                movements: inventoryMovements,
                actorEmail: AppIdentity.currentEmail,
                isAdministrator: isAdminUser
            )
            let previousDefaultLocation = item.defaultInventoryLocation
            modelContext.insert(movement)
            item.defaultInventoryLocation = movement.destinationLocation
            do {
                try modelContext.save()
                let snapshot = InventoryCycleCountSnapshot.decode(from: movement.notes)
                inventoryMessage = "Saved inventory count for \(item.name). \(snapshot?.summary ?? "The stock ledger was reconciled.")"
                return nil
            } catch {
                modelContext.delete(movement)
                item.defaultInventoryLocation = previousDefaultLocation
                return "Could not save the inventory count: \(error.localizedDescription)"
            }
        } catch {
            return error.localizedDescription
        }
    }

    func recordInventoryMovement() {
        guard requireAdministrator(for: "Recording inventory movements") else { return }
        guard let item = selectedInventoryItem, item.tracksInventory else {
            inventoryMessage = "Choose a tracked pricebook item before recording stock."
            return
        }
        guard let quantity = Double(inventoryQuantity),
              inventoryMovementType == .adjust ? quantity != 0 : quantity > 0 else {
            inventoryMessage = inventoryMovementType == .adjust
                ? "Enter a non-zero signed adjustment quantity."
                : "Enter a quantity greater than zero."
            return
        }

        let source = inventorySourceLocation.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        let destination = inventoryDestinationLocation.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        if inventoryMovementType.requiresSourceLocation && source == nil {
            inventoryMessage = "Enter the source stock location."
            return
        }
        if inventoryMovementType.requiresDestinationLocation && destination == nil {
            inventoryMessage = "Enter the destination stock location."
            return
        }
        if inventoryMovementType == .transfer,
           source?.caseInsensitiveCompare(destination ?? "") == .orderedSame {
            inventoryMessage = "Choose different source and destination locations for a transfer."
            return
        }
        if inventoryMovementType.requiresJobLink && inventoryServiceCallID == nil {
            inventoryMessage = "Link reservations, releases, and consumption to the job they support."
            return
        }

        let movement = InventoryMovement(
            item: item,
            type: inventoryMovementType,
            quantity: quantity,
            sourceLocation: source,
            destinationLocation: destination,
            serviceCallID: inventoryServiceCallID,
            notes: inventoryNotes.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
            createdByEmail: AppIdentity.currentEmail
        )
        modelContext.insert(movement)
        item.defaultInventoryLocation = (destination ?? source) ?? item.defaultInventoryLocation
        do {
            try modelContext.save()
            inventoryMessage = "Recorded \(movement.type.displayName.lowercased()) for \(item.name)."
            inventoryQuantity = "1"
            inventoryNotes = ""
        } catch {
            inventoryMessage = "Could not save the stock movement: \(error.localizedDescription)"
        }
    }

    func inventoryMovementDetail(_ movement: InventoryMovement) -> String {
        let locationDetail: String
        switch movement.type {
        case .transfer:
            locationDetail = "\(movement.sourceLocation ?? "Unknown") → \(movement.destinationLocation ?? "Unknown")"
        case .receive, .returnToStock, .adjust:
            locationDetail = movement.destinationLocation ?? "No location"
        case .reserve, .release, .consume, .returnToVendor:
            locationDetail = movement.sourceLocation ?? "No location"
        }
        let jobDetail = movement.serviceCallID.flatMap { id in
            serviceCalls.first(where: { $0.id == id })?.customer.name
        }
        return [locationDetail, jobDetail, movement.createdAt.formatted(date: .abbreviated, time: .shortened)]
            .compactMap { $0 }
            .joined(separator: " • ")
    }

    func addPendingPurchaseOrderLine() {
        guard let line = pendingPurchaseOrderLine else {
            purchaseOrderMessage = "Choose a pricebook item and enter a valid quantity and unit cost."
            return
        }
        newPurchaseOrderLines.append(line)
        newPurchaseOrderItemID = nil
        newPurchaseOrderQuantity = "1"
        newPurchaseOrderUnitCost = ""
        newPurchaseOrderSerialTrackingRequired = false
        purchaseOrderMessage = "Added \(line.itemName). Add another item or create the purchase order."
    }

    func createPurchaseOrder() {
        guard requireAdministrator(for: "Creating purchase orders") else { return }
        guard let vendor = selectedPurchaseOrderVendor else {
            purchaseOrderMessage = "Choose a vendor before creating the purchase order."
            return
        }
        var lines = newPurchaseOrderLines
        if let pendingPurchaseOrderLine {
            lines.append(pendingPurchaseOrderLine)
        }
        guard let primaryLine = lines.first else {
            purchaseOrderMessage = "Add at least one item with a valid quantity and unit cost."
            return
        }
        let shipping = max(Double(newPurchaseOrderShippingCost) ?? 0, 0)
        let order = PurchaseOrder(
            vendorName: vendor.name,
            vendorQuickBooksID: vendor.quickBooksID,
            serviceCallID: newPurchaseOrderServiceCallID,
            itemName: primaryLine.itemName,
            itemSKU: primaryLine.itemSKU,
            vendorPartNumber: primaryLine.vendorPartNumber,
            quantity: primaryLine.quantity,
            unitCost: primaryLine.unitCost,
            shippingCost: shipping,
            notes: nonBlankPurchaseOrderNotes,
            createdByEmail: AppIdentity.currentEmail,
            lineItems: lines
        )
        modelContext.insert(order)
        do {
            try modelContext.save()
            purchaseOrderMessage = "Created \(order.number) with \(order.lineCount) item line\(order.lineCount == 1 ? "" : "s") as a draft. Review it, then confirm only after \(vendor.name) accepts it."
            newPurchaseOrderItemID = nil
            newPurchaseOrderQuantity = "1"
            newPurchaseOrderUnitCost = ""
            newPurchaseOrderSerialTrackingRequired = false
            newPurchaseOrderLines = []
            newPurchaseOrderShippingCost = ""
            newPurchaseOrderNotes = ""
        } catch {
            purchaseOrderMessage = "Could not save the purchase order: \(error.localizedDescription)"
        }
    }

    var nonBlankPurchaseOrderNotes: String? {
        let notes = newPurchaseOrderNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        return notes.isEmpty ? nil : notes
    }

    func updatePurchaseOrder(_ order: PurchaseOrder, to status: PurchaseOrderStatus) {
        guard requireAdministrator(for: "Updating purchase orders") else { return }
        order.status = status
        do {
            try modelContext.save()
            switch status {
            case .ordered:
                purchaseOrderMessage = "\(order.number) is marked ordered. Attach the supplier confirmation or bill to preserve the accounting trail."
            case .partiallyReceived:
                purchaseOrderMessage = "\(order.number) remains open until its backordered quantity is received."
            case .received:
                purchaseOrderMessage = "Use Receive Shipment so quantity, destination, actor, and stock movement stay linked."
            case .requested, .draft, .cancelled:
                purchaseOrderMessage = "Updated \(order.number)."
            }
        } catch {
            purchaseOrderMessage = "Could not update \(order.number): \(error.localizedDescription)"
        }
    }

    func confirmPurchaseOrder(
        _ order: PurchaseOrder,
        channel: SupplierOrderChannel,
        reference: String,
        supplierLocation: String?,
        confirmedLineUnitCosts: [PurchaseOrderLineUnitCost],
        confirmedShippingCost: Double
    ) -> String? {
        guard requireAdministrator(for: "Confirming supplier orders") else {
            return "An active administrator account is required."
        }
        let priorNotes = order.notes
        let priorUnitCost = order.unitCost
        let priorShippingCost = order.shippingCost
        let priorStatusRaw = order.statusRaw
        let priorOrderedAt = order.orderedAt
        let priorUpdatedAt = order.updatedAt
        let actorEmail = AppIdentity.currentEmail
        guard let primaryLineID = order.purchaseOrderLines.first?.id,
              let confirmedUnitCost = confirmedLineUnitCosts.first(where: { $0.lineID == primaryLineID })?.unitCost else {
            return "Enter an accepted unit cost for every purchase-order item."
        }
        do {
            try PurchaseOrderOrderingPolicy.confirmManualOrder(
                order,
                channel: channel,
                reference: reference,
                supplierLocation: supplierLocation,
                confirmedUnitCost: confirmedUnitCost,
                confirmedShippingCost: confirmedShippingCost,
                confirmedLineUnitCosts: confirmedLineUnitCosts,
                actorEmail: actorEmail,
                users: users
            )
            try modelContext.save()
            purchaseOrderMessage = "Confirmed \(order.number) through \(channel.displayName) with supplier reference \(order.supplierOrderConfirmation?.reference ?? reference). It is ready for receiving when the shipment arrives."
            return nil
        } catch {
            order.notes = priorNotes
            order.unitCost = priorUnitCost
            order.shippingCost = priorShippingCost
            order.statusRaw = priorStatusRaw
            order.orderedAt = priorOrderedAt
            order.updatedAt = priorUpdatedAt
            return error.localizedDescription
        }
    }

    @MainActor
    func confirmPurchaseOrderThroughConnector(
        _ order: PurchaseOrder,
        connectorKind: SupplierConnectorKind,
        supplierLocation: String?
    ) async -> String? {
        guard requireAdministrator(for: "Submitting supplier orders") else {
            return "An active administrator account is required."
        }
        let priorNotes = order.notes
        let priorUnitCost = order.unitCost
        let priorShippingCost = order.shippingCost
        let priorStatusRaw = order.statusRaw
        let priorOrderedAt = order.orderedAt
        let priorUpdatedAt = order.updatedAt
        let actorEmail = AppIdentity.currentEmail
        do {
            let acceptance = try await GunnAireBackendService.submitSupplierOrder(
                order,
                connectorKind: connectorKind,
                supplierLocation: supplierLocation
            )
            try PurchaseOrderOrderingPolicy.applyServerConnectorAcceptance(
                acceptance,
                to: order,
                actorEmail: actorEmail,
                users: users
            )
            try modelContext.save()
            purchaseOrderMessage = "Confirmed \(order.number) through \(connectorKind.displayName) with supplier reference \(acceptance.reference). It is ready for receiving when the shipment arrives."
            return nil
        } catch {
            // Restoring updatedAt preserves the same idempotency key on retry. If the
            // supplier accepted the first attempt, the backend can replay that exact
            // acknowledgement without transmitting a second order.
            order.notes = priorNotes
            order.unitCost = priorUnitCost
            order.shippingCost = priorShippingCost
            order.statusRaw = priorStatusRaw
            order.orderedAt = priorOrderedAt
            order.updatedAt = priorUpdatedAt
            return error.localizedDescription
        }
    }

    func preparePurchaseOrderRequest(_ order: PurchaseOrder) {
        guard requireAdministrator(for: "Preparing restock requests") else { return }
        let priorVendorName = order.vendorName
        let priorVendorQuickBooksID = order.vendorQuickBooksID
        let priorItemSKU = order.itemSKU
        let priorVendorPartNumber = order.vendorPartNumber
        let priorUnitCost = order.unitCost
        guard InventoryReplenishment.prepareDraft(order, catalogItems: catalogItems) else {
            purchaseOrderMessage = "Add a preferred supplier to \(order.itemName) in the pricebook before preparing \(order.number). The field request remains open."
            return
        }
        do {
            try modelContext.save()
            purchaseOrderMessage = "Prepared \(order.number) as a draft for \(order.vendorName). Review quantity and cost before marking it ordered."
        } catch {
            order.vendorName = priorVendorName
            order.vendorQuickBooksID = priorVendorQuickBooksID
            order.itemSKU = priorItemSKU
            order.vendorPartNumber = priorVendorPartNumber
            order.unitCost = priorUnitCost
            order.status = .requested
            purchaseOrderMessage = "Could not prepare \(order.number): \(error.localizedDescription)"
        }
    }

    func receivePurchaseOrder(
        _ order: PurchaseOrder,
        lineID: UUID,
        quantity: Double,
        destinationLocation: String,
        note: String?,
        serialNumbers: [String] = [],
        manufacturer: String? = nil,
        modelNumber: String? = nil
    ) -> String? {
        guard requireAdministrator(for: "Receiving purchase orders") else {
            return "An active administrator account is required."
        }
        let priorNotes = order.notes
        let priorStatusRaw = order.statusRaw
        let priorReceivedAt = order.receivedAt
        let priorReceivedToLocation = order.receivedToLocation
        let priorUpdatedAt = order.updatedAt
        var insertedMovement: InventoryMovement?
        do {
            let outcome = try PurchaseOrderReceiving.receiveShipment(
                order,
                lineID: lineID,
                quantity: quantity,
                destinationLocation: destinationLocation,
                note: note,
                serialNumbers: serialNumbers,
                manufacturer: manufacturer,
                modelNumber: modelNumber,
                catalogItems: catalogItems,
                actorEmail: AppIdentity.currentEmail
            )
            insertedMovement = outcome.inventoryMovement
            if let movement = outcome.inventoryMovement {
                modelContext.insert(movement)
            }
            try modelContext.save()

            let received = outcome.receipt.quantity.formatted(.number.precision(.fractionLength(0...3)))
            let receivedItemName = outcome.receipt.itemName ?? order.itemName
            if order.status == .received {
                purchaseOrderMessage = "Received the final \(received) of \(receivedItemName) into \(outcome.receipt.destinationLocation). \(order.number) is complete."
            } else {
                let remaining = order.remainingQuantity.formatted(.number.precision(.fractionLength(0...3)))
                purchaseOrderMessage = "Received \(received) of \(receivedItemName) into \(outcome.receipt.destinationLocation). \(remaining) total units remain open or backordered on \(order.number)."
            }
            if outcome.inventoryMovement == nil {
                purchaseOrderMessage? += " No tracked pricebook item matched, so inventory was not changed."
            }
            if outcome.receipt.serialCount > 0 {
                purchaseOrderMessage? += " Captured \(outcome.receipt.serialCount) serialized asset\(outcome.receipt.serialCount == 1 ? "" : "s") for customer-system handoff."
            }
            return nil
        } catch {
            if let insertedMovement {
                modelContext.delete(insertedMovement)
            }
            order.notes = priorNotes
            order.statusRaw = priorStatusRaw
            order.receivedAt = priorReceivedAt
            order.receivedToLocation = priorReceivedToLocation
            order.updatedAt = priorUpdatedAt
            return error.localizedDescription
        }
    }

    func installPurchaseOrderAsset(
        _ context: PurchaseOrderAssetInstallationContext,
        equipmentType: HVACEquipmentType,
        name: String,
        location: String?,
        installDate: Date,
        warrantyExpiration: Date?
    ) -> String? {
        guard requireAdministrator(for: "Adding received equipment to customer systems") else {
            return "An active administrator account is required."
        }
        let order = context.order
        let job = context.job
        let priorOrderNotes = order.notes
        let priorOrderUpdatedAt = order.updatedAt
        let priorJobState = (
            customerEquipmentID: job.customerEquipmentID,
            serviceLocationID: job.serviceLocationID,
            equipmentTypeRaw: job.equipmentTypeRaw,
            equipmentName: job.equipmentName,
            equipmentManufacturer: job.equipmentManufacturer,
            equipmentModel: job.equipmentModel,
            equipmentSerialNumber: job.equipmentSerialNumber,
            equipmentLocation: job.equipmentLocation,
            equipmentInstallDate: job.equipmentInstallDate,
            equipmentWarrantyExpiration: job.equipmentWarrantyExpiration,
            filterSize: job.filterSize,
            equipmentNotes: job.equipmentNotes
        )
        var insertedEquipment: CustomerEquipment?
        do {
            let equipment = try PurchaseOrderAssetInstallationPolicy.install(
                assetID: context.asset.id,
                from: order,
                on: job,
                equipmentType: equipmentType,
                name: name,
                location: location,
                installDate: installDate,
                warrantyExpiration: warrantyExpiration,
                existingEquipment: equipmentProfiles,
                actorEmail: AppIdentity.currentEmail,
                users: users
            )
            insertedEquipment = equipment
            modelContext.insert(equipment)
            try modelContext.save()
            purchaseOrderMessage = "Added \(equipment.name) • serial \(context.asset.serialNumber) to \(job.customer.name) and linked it to \(order.number) and the installation job."
            return nil
        } catch {
            if let insertedEquipment {
                modelContext.delete(insertedEquipment)
            }
            order.notes = priorOrderNotes
            order.updatedAt = priorOrderUpdatedAt
            job.customerEquipmentID = priorJobState.customerEquipmentID
            job.serviceLocationID = priorJobState.serviceLocationID
            job.equipmentTypeRaw = priorJobState.equipmentTypeRaw
            job.equipmentName = priorJobState.equipmentName
            job.equipmentManufacturer = priorJobState.equipmentManufacturer
            job.equipmentModel = priorJobState.equipmentModel
            job.equipmentSerialNumber = priorJobState.equipmentSerialNumber
            job.equipmentLocation = priorJobState.equipmentLocation
            job.equipmentInstallDate = priorJobState.equipmentInstallDate
            job.equipmentWarrantyExpiration = priorJobState.equipmentWarrantyExpiration
            job.filterSize = priorJobState.filterSize
            job.equipmentNotes = priorJobState.equipmentNotes
            return error.localizedDescription
        }
    }

    func recordVendorBill(
        on order: PurchaseOrder,
        invoiceNumber: String,
        invoiceDate: Date,
        lineAllocations: [PurchaseOrderBillLineAllocation],
        shippingCost: Double,
        taxAmount: Double,
        otherCharges: Double,
        sourceDocumentName: String?,
        quickBooksBillID: String?,
        note: String?
    ) -> String? {
        guard requireAdministrator(for: "Recording vendor bills") else {
            return "An active administrator account is required."
        }
        let priorNotes = order.notes
        let priorUpdatedAt = order.updatedAt
        do {
            let bill = try PurchaseOrderBillReconciliationPolicy.record(
                on: order,
                invoiceNumber: invoiceNumber,
                invoiceDate: invoiceDate,
                lineAllocations: lineAllocations,
                shippingCost: shippingCost,
                taxAmount: taxAmount,
                otherCharges: otherCharges,
                sourceDocumentName: sourceDocumentName,
                quickBooksBillID: quickBooksBillID,
                note: note,
                actorEmail: AppIdentity.currentEmail,
                users: users
            )
            try modelContext.save()
            let match = order.billMatch
            purchaseOrderMessage = "Recorded vendor invoice \(bill.invoiceNumber) on \(order.number). \(match.state.displayName): \(match.summary)."
            if match.hasVariance {
                purchaseOrderMessage? += " Review the supplier evidence before changing QuickBooks."
            }
            return nil
        } catch {
            order.notes = priorNotes
            order.updatedAt = priorUpdatedAt
            return error.localizedDescription
        }
    }

    func createVendorReturn(
        on order: PurchaseOrder,
        reference: String,
        sourceLocation: String,
        reason: String,
        lineAllocations: [PurchaseOrderVendorReturnLine]
    ) -> String? {
        guard requireAdministrator(for: "Creating supplier returns") else {
            return "An active administrator account is required."
        }
        let priorNotes = order.notes
        let priorUpdatedAt = order.updatedAt
        do {
            let vendorReturn = try PurchaseOrderVendorReturnPolicy.create(
                on: order,
                reference: reference,
                sourceLocation: sourceLocation,
                reason: reason,
                lineAllocations: lineAllocations,
                actorEmail: AppIdentity.currentEmail,
                users: users
            )
            try modelContext.save()
            purchaseOrderMessage = "Created supplier return \(vendorReturn.reference) on \(order.number). The quantities and serial numbers are reserved; stock will change only after the return is marked complete."
            return nil
        } catch {
            order.notes = priorNotes
            order.updatedAt = priorUpdatedAt
            return error.localizedDescription
        }
    }

    func updateVendorReturn(
        _ context: PurchaseOrderVendorReturnActionContext,
        note: String?
    ) -> String? {
        guard requireAdministrator(for: "Updating supplier returns") else {
            return "An active administrator account is required."
        }
        let order = context.order
        let priorNotes = order.notes
        let priorUpdatedAt = order.updatedAt
        var insertedMovements: [InventoryMovement] = []
        do {
            switch context.action {
            case .markSent:
                try PurchaseOrderVendorReturnPolicy.markSent(
                    returnID: context.vendorReturn.id,
                    on: order,
                    note: note,
                    actorEmail: AppIdentity.currentEmail,
                    users: users
                )
            case .markReturned:
                insertedMovements = try PurchaseOrderVendorReturnPolicy.markReturned(
                    returnID: context.vendorReturn.id,
                    on: order,
                    catalogItems: catalogItems,
                    inventoryMovements: inventoryMovements,
                    note: note,
                    actorEmail: AppIdentity.currentEmail,
                    users: users
                )
                insertedMovements.forEach(modelContext.insert)
            case .cancel:
                try PurchaseOrderVendorReturnPolicy.cancel(
                    returnID: context.vendorReturn.id,
                    on: order,
                    note: note,
                    actorEmail: AppIdentity.currentEmail,
                    users: users
                )
            }
            try modelContext.save()

            switch context.action {
            case .markSent:
                purchaseOrderMessage = "Marked supplier return \(context.vendorReturn.reference) sent. Stock remains unchanged until the supplier receives the material."
            case .markReturned:
                purchaseOrderMessage = "Completed supplier return \(context.vendorReturn.reference). \(insertedMovements.count) tracked stock movement\(insertedMovements.count == 1 ? "" : "s") now reverse the received inventory; record the vendor credit when it arrives."
                if insertedMovements.isEmpty {
                    purchaseOrderMessage? += " These were direct-ship or untracked items, so the inventory ledger was unchanged."
                }
            case .cancel:
                purchaseOrderMessage = "Cancelled supplier return \(context.vendorReturn.reference). Its quantities and serial numbers are available again."
            }
            return nil
        } catch {
            insertedMovements.forEach(modelContext.delete)
            order.notes = priorNotes
            order.updatedAt = priorUpdatedAt
            return error.localizedDescription
        }
    }

    func recordVendorCredit(
        _ context: PurchaseOrderVendorCreditContext,
        reference: String,
        creditDate: Date,
        creditAmount: Double,
        restockingFee: Double,
        taxCredit: Double,
        shippingCredit: Double,
        sourceDocumentName: String?,
        quickBooksVendorCreditID: String?,
        note: String?
    ) -> String? {
        guard requireAdministrator(for: "Recording vendor credits") else {
            return "An active administrator account is required."
        }
        let order = context.order
        let priorNotes = order.notes
        let priorUpdatedAt = order.updatedAt
        do {
            let evidence = try PurchaseOrderVendorReturnPolicy.recordCredit(
                returnID: context.vendorReturn.id,
                on: order,
                reference: reference,
                creditDate: creditDate,
                creditAmount: creditAmount,
                restockingFee: restockingFee,
                taxCredit: taxCredit,
                shippingCredit: shippingCredit,
                sourceDocumentName: sourceDocumentName,
                quickBooksVendorCreditID: quickBooksVendorCreditID,
                note: note,
                actorEmail: AppIdentity.currentEmail,
                users: users
            )
            try modelContext.save()
            guard let updatedReturn = order.vendorReturn(withID: context.vendorReturn.id) else {
                throw PurchaseOrderVendorReturnError.unableToStoreEvidence
            }
            let match = order.vendorCreditMatch(for: updatedReturn)
            purchaseOrderMessage = "Recorded supplier credit \(evidence.reference) for return \(updatedReturn.reference). \(match.state.displayName): \(match.summary)."
            if match.hasVariance {
                purchaseOrderMessage? += " Keep this purchase order in accounting review; GunnAire Ops has not changed QuickBooks."
            }
            return nil
        } catch {
            order.notes = priorNotes
            order.updatedAt = priorUpdatedAt
            return error.localizedDescription
        }
    }

    func refreshQuickBooksAccountingMappings(force: Bool = false) {
        guard quickBooksAPI.isAuthenticated else { return }
        Task { @MainActor in
            await accountingConfigurationStore.refresh(
                realmID: quickBooksAPI.realmID,
                environment: quickBooksAPI.currentEnvironment,
                force: force
            )
        }
    }

    func quickBooksPublicationSetupIssue(for order: PurchaseOrder) -> String? {
        guard quickBooksAPI.isAuthenticated else {
            return "Connect QuickBooks Accounting before publishing."
        }
        guard quickBooksAccountingConfiguration != nil else {
            return "Save the expense and Accounts Payable mappings for this QuickBooks company."
        }
        guard order.vendorQuickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return "Link this supplier to its exact QuickBooks Vendor before publishing."
        }
        return nil
    }

    func publishQuickBooksBill(_ context: QuickBooksBillPublicationContext) {
        quickBooksBillPendingPublication = nil
        let key = "bill:\(context.bill.id.uuidString)"
        guard quickBooksPublishingKey == nil else { return }
        quickBooksPublishingKey = key
        purchaseOrderMessage = "Checking QuickBooks for vendor bill \(context.bill.invoiceNumber)…"
        let priorNotes = context.order.notes
        let priorUpdatedAt = context.order.updatedAt
        Task { @MainActor in
            do {
                let result = try await QuickBooksVendorTransactionPublisher.publishBill(
                    context.bill,
                    on: context.order,
                    configuration: quickBooksAccountingConfiguration,
                    actorEmail: AppIdentity.currentEmail,
                    users: users
                )
                do {
                    try modelContext.save()
                } catch {
                    context.order.notes = priorNotes
                    context.order.updatedAt = priorUpdatedAt
                    throw QuickBooksVendorTransactionPublicationError.unableToStoreProviderLink
                }
                let verb = result.resolution == .created ? "Published" : "Recovered"
                purchaseOrderMessage = "\(verb) QuickBooks Bill \(result.providerID) for supplier invoice \(context.bill.invoiceNumber). The local purchase-order evidence now carries the provider link."
            } catch {
                context.order.notes = priorNotes
                context.order.updatedAt = priorUpdatedAt
                purchaseOrderMessage = "QuickBooks Bill publication needs attention: \(error.localizedDescription)"
            }
            quickBooksPublishingKey = nil
        }
    }

    func publishQuickBooksVendorCredit(_ context: QuickBooksVendorCreditPublicationContext) {
        quickBooksVendorCreditPendingPublication = nil
        let key = "credit:\(context.vendorReturn.id.uuidString)"
        guard quickBooksPublishingKey == nil else { return }
        quickBooksPublishingKey = key
        purchaseOrderMessage = "Checking QuickBooks for vendor credit \(context.evidence.reference)…"
        let priorNotes = context.order.notes
        let priorUpdatedAt = context.order.updatedAt
        Task { @MainActor in
            do {
                let result = try await QuickBooksVendorTransactionPublisher.publishVendorCredit(
                    for: context.vendorReturn,
                    on: context.order,
                    configuration: quickBooksAccountingConfiguration,
                    actorEmail: AppIdentity.currentEmail,
                    users: users
                )
                do {
                    try modelContext.save()
                } catch {
                    context.order.notes = priorNotes
                    context.order.updatedAt = priorUpdatedAt
                    throw QuickBooksVendorTransactionPublicationError.unableToStoreProviderLink
                }
                let verb = result.resolution == .created ? "Published" : "Recovered"
                purchaseOrderMessage = "\(verb) QuickBooks Vendor Credit \(result.providerID) for supplier credit \(context.evidence.reference). It remains unapplied until Accounting applies it in QuickBooks."
            } catch {
                context.order.notes = priorNotes
                context.order.updatedAt = priorUpdatedAt
                purchaseOrderMessage = "QuickBooks Vendor Credit publication needs attention: \(error.localizedDescription)"
            }
            quickBooksPublishingKey = nil
        }
    }

    func applyDocumentationProgress(forUploadedFileCount uploadedCount: Int) {
        guard uploadedCount > 0, let selectedServiceCall else { return }
        switch selectedJobDocumentStage {
        case .before:
            selectedServiceCall.beforePhotoCount += uploadedCount
        case .after:
            selectedServiceCall.afterPhotoCount += uploadedCount
        case .supporting:
            break
        }
        selectedServiceCall.documentationChecklist = true
        selectedServiceCall.documentationStartedAt = selectedServiceCall.documentationStartedAt ?? Date()
    }
}

enum ReceiptsBillsWorkspace: String, CaseIterable, Identifiable {
    case documents
    case purchasing
    case inventory
    case recovery

    var id: String { rawValue }

    static func available(
        isAdminUser: Bool,
        canRecordWarrantyCredit: Bool = false
    ) -> [ReceiptsBillsWorkspace] {
        if isAdminUser { return allCases }
        if canRecordWarrantyCredit { return [.documents, .purchasing] }
        return [.documents]
    }

    var label: String {
        switch self {
        case .documents: "Documents"
        case .purchasing: "Purchasing"
        case .inventory: "Inventory"
        case .recovery: "Recovery"
        }
    }

    var systemImage: String {
        switch self {
        case .documents: "doc.viewfinder"
        case .purchasing: "cart"
        case .inventory: "shippingbox"
        case .recovery: "arrow.triangle.2.circlepath"
        }
    }

    var guidance: String {
        switch self {
        case .documents:
            "Capture receipts and bills, link them to jobs, and attach approved files to QuickBooks."
        case .purchasing:
            "Create supplier orders, preserve job and vendor context, and receive approved purchases."
        case .inventory:
            "Review low stock and record traceable receipts, transfers, reservations, use, returns, or adjustments."
        case .recovery:
            "Resolve deferred or failed QuickBooks uploads without discarding unsynced document work."
        }
    }
}

private struct CameraImagePicker: UIViewControllerRepresentable {
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
        private let parent: CameraImagePicker

        init(_ parent: CameraImagePicker) {
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

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

#Preview {
    ReceiptsAndBillsView()
}
