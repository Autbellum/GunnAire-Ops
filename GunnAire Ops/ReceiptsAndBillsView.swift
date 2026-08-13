import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import UIKit
import os

struct ReceiptsAndBillsView: View {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "GunnAireOps", category: "ReceiptsAndBills")

    private struct LegacyPendingUploadRecord: Codable {
        let id: UUID
        let filePath: String
        let displayName: String
        let entityTypeRaw: String?
        let entityID: String?
        let createdAt: Date
        let lastError: String?
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
    @ObservedObject private var googleAuth = GoogleAuthManager.shared

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
    @State private var queueFilter: QueueFilter = .all
    @State private var queueSort: QueueSort = .nextRetry
    @State private var isUploadingReceiptToBackend = false
    @State private var backendUploadMessage: String?

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
            email: googleAuth.signedInEmail ?? UserDefaults.standard.string(forKey: "SignedInGoogleEmail"),
            users: users
        )
    }

    var body: some View {
        ZStack {
            WatermarkBackground()
            NavigationStack {
                Form {
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
                        if let syncMessage {
                            Text(syncMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if isAdminUser {
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
                                                removePendingUpload(pending.id)
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
                                pendingUploads = []
                                savePendingUploads()
                            }
                            .disabled(isSyncing || pendingUploads.isEmpty)

                            Button("Purge Missing Files", role: .destructive) {
                                purgeMissingFileEntries()
                            }
                            .disabled(isSyncing || pendingUploads.isEmpty)
                        }
                    }

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
        .onChange(of: selectedAttachEntityType) { _, _ in
            attachTargetOptions = []
            selectedAttachTargetID = ""
            attachLookupMessage = nil
        }
        .onChange(of: selectedServiceCallID) { _, _ in
            applyLinkedServiceCallDefaults()
        }
        .onAppear {
            loadPendingUploads()
            applyLinkedServiceCallDefaults()
        }
        .sheet(item: $selectedPendingUploadForDetail) { pending in
            PendingUploadDetailSheet(
                pending: refreshPendingUploadDetails(for: pending),
                isSyncing: isSyncing,
                onRetryNow: {
                    retryPendingUpload(pending, ignoreBackoff: true)
                    if pendingUploads.contains(where: { $0.id == pending.id }) {
                        selectedPendingUploadForDetail = refreshPendingUploadDetails(for: pending)
                    } else {
                        selectedPendingUploadForDetail = nil
                    }
                },
                onDelete: {
                    removePendingUpload(pending.id)
                    selectedPendingUploadForDetail = nil
                },
                onToggleTerminal: {
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

#Preview {
    ReceiptsAndBillsView()
}
