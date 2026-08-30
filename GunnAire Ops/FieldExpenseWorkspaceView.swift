import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct FieldExpenseWorkspaceView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FieldExpenseClaim.expenseDate, order: .reverse) private var claims: [FieldExpenseClaim]
    @Query(sort: \ServiceCall.scheduledDate, order: .reverse) private var serviceCalls: [ServiceCall]
    @Query(sort: \Technician.name, order: .forward) private var technicians: [Technician]
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]
    @Query(sort: \ServiceDocumentAttachment.createdAt, order: .reverse) private var attachments: [ServiceDocumentAttachment]

    @State private var selectedLane: FieldExpenseLane = .myClaims
    @State private var showingNewClaim = false
    @State private var selectedClaim: FieldExpenseClaim?

    private var currentEmail: String { AppAccess.normalizedEmail(AppIdentity.currentEmail) }
    private var currentRole: AppUserRole? { AppAccess.activeRole(email: currentEmail, users: users) }
    private var canSubmit: Bool { AppAccess.canSubmitFieldExpenses(email: currentEmail, users: users) }
    private var canReview: Bool { AppAccess.canReviewFieldExpenses(email: currentEmail, users: users) }

    private var availableLanes: [FieldExpenseLane] {
        var lanes: [FieldExpenseLane] = []
        if canSubmit { lanes.append(.myClaims) }
        if canReview { lanes.append(.review) }
        return lanes.isEmpty ? [.myClaims] : lanes
    }

    private var myClaims: [FieldExpenseClaim] {
        claims.filter { AppAccess.normalizedEmail($0.claimantEmail) == currentEmail }
    }

    private var reviewClaims: [FieldExpenseClaim] {
        claims.filter { $0.needsOfficeReview || $0.needsReimbursement }
    }

    private var displayedClaims: [FieldExpenseClaim] {
        switch selectedLane {
        case .myClaims: myClaims
        case .review: reviewClaims
        }
    }

    private var submittedCount: Int { claims.filter(\.needsOfficeReview).count }
    private var reimbursementTotal: Double {
        claims.filter(\.needsReimbursement).reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        List {
            if availableLanes.count > 1 {
                Section("Expense Workspace") {
                    Picker("Expense Workspace", selection: $selectedLane) {
                        ForEach(availableLanes) { lane in
                            Text(lane.displayName).tag(lane)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("FieldExpenseLanePicker")
                    Text(selectedLane.guidance)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if selectedLane == .review && canReview {
                Section("Review Queue") {
                    HStack(spacing: 12) {
                        expenseMetric("\(submittedCount)", label: "to review", tint: submittedCount == 0 ? .secondary : .orange)
                        expenseMetric(reimbursementTotal.formatted(.currency(code: "USD")), label: "to reimburse", tint: reimbursementTotal == 0 ? .secondary : .green)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Expense review: \(submittedCount) claims to review, \(reimbursementTotal.formatted(.currency(code: "USD"))) approved for reimbursement")

                    Text("Approval records an internal job cost. Reimbursement is separate and requires the payroll, check, or accounting reference actually used. No action here posts to QuickBooks or runs payroll.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(selectedLane == .review ? "Needs Action" : "My Claims") {
                if displayedClaims.isEmpty {
                    ContentUnavailableView(
                        selectedLane == .review ? "No Expense Exceptions" : "No Expense Claims",
                        systemImage: selectedLane == .review ? "checkmark.circle" : "receipt",
                        description: Text(selectedLane == .review
                            ? "Submitted claims and approved reimbursements will appear here."
                            : "Add a job expense or mileage claim without leaving Time Clock.")
                    )
                } else {
                    ForEach(displayedClaims) { claim in
                        Button {
                            selectedClaim = claim
                        } label: {
                            fieldExpenseRow(claim)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("FieldExpenseClaim-\(claim.id.uuidString)")
                    }
                }
            }

            if selectedLane == .myClaims && canSubmit {
                Section {
                    Button {
                        showingNewClaim = true
                    } label: {
                        Label("Add Expense or Mileage", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brandGold)
                    .foregroundStyle(Color.primaryBlack)
                    .accessibilityIdentifier("AddFieldExpense")

                    Text("Use inventory and purchase orders for customer materials. This lane is for travel, permits, small tools, and other field costs so job profitability is not double counted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Expenses & Mileage")
        .onAppear(perform: normalizeLane)
        .onChange(of: currentRole) { _, _ in normalizeLane() }
        .sheet(isPresented: $showingNewClaim) {
            FieldExpenseClaimEditor(
                initialServiceCall: nil,
                existingClaim: nil,
                serviceCalls: serviceCalls,
                technicians: technicians,
                users: users
            )
        }
        .sheet(item: $selectedClaim) { claim in
            FieldExpenseClaimDetailView(
                claim: claim,
                receiptAttachment: attachments.first { $0.id == claim.receiptAttachmentID },
                serviceCalls: serviceCalls,
                technicians: technicians,
                users: users
            )
        }
    }

    private func normalizeLane() {
        guard !availableLanes.contains(selectedLane) else { return }
        selectedLane = availableLanes.first ?? .myClaims
    }

    private func expenseMetric(_ value: String, label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.headline)
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func fieldExpenseRow(_ claim: FieldExpenseClaim) -> some View {
        HStack(spacing: 12) {
            Image(systemName: claim.claimType.systemImage)
                .font(.title3)
                .foregroundStyle(Color.brandGold)
                .frame(width: 34, height: 34)
                .background(Color.brandGold.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(claim.claimType == .mileage ? claim.businessPurpose : claim.merchant)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(claim.amount, format: .currency(code: "USD"))
                        .font(.subheadline.weight(.semibold))
                }
                HStack {
                    Text(claim.customerName ?? "General business")
                        .lineLimit(1)
                    Spacer()
                    Label(claim.status.displayName, systemImage: claim.status.systemImage)
                        .foregroundStyle(statusColor(claim.status))
                }
                .font(.caption)
                Text("\(claim.expenseDate.formatted(date: .abbreviated, time: .omitted)) • \(claim.claimantName.isEmpty ? claim.claimantEmail : claim.claimantName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private enum FieldExpenseLane: String, Identifiable {
    case myClaims
    case review

    var id: String { rawValue }
    var displayName: String { self == .myClaims ? "My Claims" : "Review" }
    var guidance: String {
        self == .myClaims
            ? "Capture receipt-backed costs and mileage, then follow the office decision."
            : "Resolve submitted claims first, then record only reimbursements that actually occurred."
    }
}

struct FieldExpenseClaimEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let initialServiceCall: ServiceCall?
    let existingClaim: FieldExpenseClaim?
    let serviceCalls: [ServiceCall]
    let technicians: [Technician]
    let users: [AppUser]

    @State private var claimType: FieldExpenseClaimType = .expense
    @State private var category: FieldExpenseCategory = .parkingToll
    @State private var expenseDate = Date()
    @State private var selectedServiceCallID: UUID?
    @State private var merchant = ""
    @State private var businessPurpose = ""
    @State private var amount = ""
    @State private var mileageMiles = ""
    @State private var mileageRate = ""
    @State private var mileageOrigin = ""
    @State private var mileageDestination = ""
    @State private var reimbursable = true
    @State private var importedFileURL: URL?
    @State private var showingFileImporter = false
    @State private var errorMessage: String?

    private var currentEmail: String { AppAccess.normalizedEmail(AppIdentity.currentEmail) }
    private var currentRole: AppUserRole? { AppAccess.activeRole(email: currentEmail, users: users) }
    private var claimantName: String {
        let matches = technicians.filter { AppAccess.normalizedEmail($0.contactInfo) == currentEmail }
        return matches.count == 1 ? matches[0].name : AppAccess.inferredDisplayName(fromEmail: currentEmail)
    }
    private var visibleCallIDs: Set<UUID> {
        AppAccess.visibleServiceCallIDs(
            email: currentEmail,
            users: users,
            serviceCalls: serviceCalls,
            technicians: technicians
        )
    }
    private var selectableCalls: [ServiceCall] {
        serviceCalls
            .filter {
                visibleCallIDs.contains($0.id)
                    && ($0.status != .cancelled || $0.id == existingClaim?.serviceCallID)
            }
            .prefix(50)
            .map { $0 }
    }
    private var selectedServiceCall: ServiceCall? {
        guard let selectedServiceCallID else { return nil }
        return serviceCalls.first { $0.id == selectedServiceCallID }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Claim") {
                    Picker("Type", selection: $claimType) {
                        ForEach(FieldExpenseClaimType.allCases) { type in
                            Label(type.displayName, systemImage: type.systemImage).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("FieldExpenseType")
                    DatePicker("Date", selection: $expenseDate, in: ...Date(), displayedComponents: .date)
                    Picker("Job", selection: $selectedServiceCallID) {
                        Text("General business").tag(UUID?.none)
                        ForEach(selectableCalls) { call in
                            Text("\(call.customer.name) • \(call.type.displayName) • \(call.scheduledDate.formatted(date: .abbreviated, time: .omitted))")
                                .tag(UUID?.some(call.id))
                        }
                    }
                    .accessibilityIdentifier("FieldExpenseJob")
                    .disabled(existingClaim != nil)
                    Text(existingClaim != nil
                        ? "The original job link is retained during corrections to preserve cost attribution and the approval audit."
                        : selectedServiceCallID == nil
                            ? "General claims stay outside job profitability. Link the exact job whenever the cost belongs to customer work."
                            : "This claim will be included in the linked job's cost only after office approval.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if claimType == .expense {
                    Section("Expense Details") {
                        Picker("Category", selection: $category) {
                            ForEach(FieldExpenseCategory.allCases.filter { $0 != .mileage }) { category in
                                Text(category.displayName).tag(category)
                            }
                        }
                        TextField("Merchant or payee", text: $merchant)
                            .accessibilityIdentifier("FieldExpenseMerchant")
                        TextField("Amount", text: $amount)
                            .keyboardType(.decimalPad)
                            .accessibilityIdentifier("FieldExpenseAmount")
                    }
                } else {
                    Section("Mileage") {
                        TextField("Starting point", text: $mileageOrigin)
                            .accessibilityIdentifier("FieldMileageOrigin")
                        TextField("Destination", text: $mileageDestination)
                            .accessibilityIdentifier("FieldMileageDestination")
                        TextField("Miles", text: $mileageMiles)
                            .keyboardType(.decimalPad)
                            .accessibilityIdentifier("FieldMileageMiles")
                        TextField("Rate per mile", text: $mileageRate)
                            .keyboardType(.decimalPad)
                            .accessibilityIdentifier("FieldMileageRate")
                        if let miles = Double(mileageMiles), let rate = Double(mileageRate), miles > 0, rate > 0 {
                            Text("Calculated reimbursement: \(FieldExpenseClaimPolicy.roundCurrency(miles * rate).formatted(.currency(code: "USD")))")
                                .font(.caption.weight(.semibold))
                        }
                        Text("Enter the business route in plain language. The app does not collect passive GPS history or precise location telemetry.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Business Purpose") {
                    TextField("Why was this cost necessary?", text: $businessPurpose, axis: .vertical)
                        .lineLimit(2...5)
                        .accessibilityIdentifier("FieldExpensePurpose")
                    Toggle("Employee paid; reimbursement needed", isOn: $reimbursable)
                    Text(reimbursable
                        ? "Accounting records reimbursement separately after payment actually occurs."
                        : "Use this for a company card or other company-paid cost. Approval still adds the job cost.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Receipt") {
                    Button {
                        showingFileImporter = true
                    } label: {
                        Label(importedFileURL?.lastPathComponent ?? existingReceiptLabel, systemImage: "paperclip")
                    }
                    if importedFileURL != nil {
                        Button("Remove Selected File", role: .destructive) { importedFileURL = nil }
                    }
                    Text("A receipt is required before office approval for expenses of $25 or more. Mileage is exempt. Files are copied into GunnAire's app storage and remain available for sync recovery.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle(existingClaim == nil ? "New Expense Claim" : "Correct Expense Claim")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existingClaim == nil ? "Submit" : "Resubmit") { save() }
                        .accessibilityIdentifier("SubmitFieldExpense")
                }
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.image, .pdf],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls): importedFileURL = urls.first
                case .failure(let error): errorMessage = error.localizedDescription
                }
            }
            .onAppear(perform: loadExistingValues)
        }
    }

    private var existingReceiptLabel: String {
        existingClaim?.receiptAttachmentID == nil ? "Choose Receipt" : "Keep Existing Receipt"
    }

    private func loadExistingValues() {
        guard let existingClaim else {
            selectedServiceCallID = initialServiceCall?.id
            return
        }
        claimType = existingClaim.claimType
        category = existingClaim.category
        expenseDate = existingClaim.expenseDate
        selectedServiceCallID = existingClaim.serviceCallID
        merchant = existingClaim.claimType == .expense ? existingClaim.merchant : ""
        businessPurpose = existingClaim.businessPurpose
        amount = existingClaim.claimType == .expense ? editableNumber(existingClaim.amount) : ""
        mileageMiles = existingClaim.mileageMiles.map(editableNumber) ?? ""
        mileageRate = existingClaim.mileageRatePerMile.map(editableNumber) ?? ""
        mileageOrigin = existingClaim.mileageOrigin ?? ""
        mileageDestination = existingClaim.mileageDestination ?? ""
        reimbursable = existingClaim.reimbursable
    }

    private func save() {
        errorMessage = nil
        var storedAttachment: ServiceDocumentAttachment?
        do {
            guard AppAccess.canSubmitFieldExpenses(email: currentEmail, users: users) else {
                throw FieldExpenseClaimError.unauthorized
            }
            if let selectedServiceCall, !visibleCallIDs.contains(selectedServiceCall.id) {
                throw FieldExpenseClaimError.jobAccessChanged
            }
            if let existingClaim {
                guard existingClaim.status == .correctionRequested,
                      AppAccess.normalizedEmail(existingClaim.claimantEmail) == currentEmail else {
                    throw FieldExpenseClaimError.unauthorized
                }
                var receiptID = existingClaim.receiptAttachmentID
                if let importedFileURL {
                    let attachment = try FieldExpenseAttachmentStore.makeAttachment(
                        sourceURL: importedFileURL,
                        claimID: existingClaim.id,
                        serviceCall: selectedServiceCall
                    )
                    storedAttachment = attachment
                    modelContext.insert(attachment)
                    receiptID = attachment.id
                }
                try existingClaim.resubmit(
                    claimType: claimType,
                    category: category,
                    expenseDate: expenseDate,
                    merchant: merchant,
                    businessPurpose: businessPurpose,
                    amount: Double(amount),
                    mileageMiles: Double(mileageMiles),
                    mileageRatePerMile: Double(mileageRate),
                    mileageOrigin: mileageOrigin,
                    mileageDestination: mileageDestination,
                    reimbursable: reimbursable,
                    receiptAttachmentID: receiptID,
                    actorEmail: currentEmail
                )
            } else {
                let claimID = UUID()
                var receiptID: UUID?
                if let importedFileURL {
                    let attachment = try FieldExpenseAttachmentStore.makeAttachment(
                        sourceURL: importedFileURL,
                        claimID: claimID,
                        serviceCall: selectedServiceCall
                    )
                    storedAttachment = attachment
                    modelContext.insert(attachment)
                    receiptID = attachment.id
                }
                let claim = try FieldExpenseClaimPolicy.makeClaim(
                    id: claimID,
                    serviceCall: selectedServiceCall,
                    claimantEmail: currentEmail,
                    claimantName: claimantName,
                    claimType: claimType,
                    category: category,
                    expenseDate: expenseDate,
                    merchant: merchant,
                    businessPurpose: businessPurpose,
                    amount: Double(amount),
                    mileageMiles: Double(mileageMiles),
                    mileageRatePerMile: Double(mileageRate),
                    mileageOrigin: mileageOrigin,
                    mileageDestination: mileageDestination,
                    reimbursable: reimbursable,
                    receiptAttachmentID: receiptID
                )
                modelContext.insert(claim)
                if let selectedServiceCall {
                    ServiceCallActivity.record(
                        for: selectedServiceCall,
                        action: "Field expense submitted",
                        detail: "\(claim.category.displayName) • \(claim.amount.formatted(.currency(code: "USD"))) • claim \(claim.claimReference)",
                        actorEmail: currentEmail,
                        in: modelContext
                    )
                }
            }
            try modelContext.save()
            dismiss()
        } catch {
            if let storedAttachment {
                modelContext.delete(storedAttachment)
                try? FileManager.default.removeItem(at: storedAttachment.localFileURL)
            }
            errorMessage = error.localizedDescription
        }
    }

    private func editableNumber(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...3)).grouping(.never))
    }
}

private struct FieldExpenseClaimDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let claim: FieldExpenseClaim
    let receiptAttachment: ServiceDocumentAttachment?
    let serviceCalls: [ServiceCall]
    let technicians: [Technician]
    let users: [AppUser]

    @State private var showingReview = false
    @State private var showingReimbursement = false
    @State private var showingCorrection = false
    @State private var previewFile: FieldExpensePreviewFile?
    @State private var message: String?

    private var currentEmail: String { AppAccess.normalizedEmail(AppIdentity.currentEmail) }
    private var currentRole: AppUserRole? { AppAccess.activeRole(email: currentEmail, users: users) }
    private var canReview: Bool { AppAccess.canReviewFieldExpenses(email: currentEmail, users: users) }
    private var isClaimant: Bool { AppAccess.normalizedEmail(claim.claimantEmail) == currentEmail }
    private var masksActorIdentityForScreenshots: Bool {
        ProcessInfo.processInfo.arguments.contains(AppStoreScreenshotPrivacyPolicy.fixtureArgument)
    }
    private var linkedServiceCall: ServiceCall? {
        guard let id = claim.serviceCallID else { return nil }
        return serviceCalls.first { $0.id == id }
    }
    private var receiptIsAvailable: Bool {
        guard let receiptAttachment else { return false }
        return FileManager.default.fileExists(atPath: receiptAttachment.localFilePath) || receiptAttachment.backendDocumentID != nil
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Claim \(claim.claimReference)") {
                    valueRow("Status", claim.status.displayName)
                    valueRow("Claimant", claim.claimantName.isEmpty ? claim.claimantEmail : claim.claimantName)
                    valueRow("Type", claim.claimType.displayName)
                    valueRow("Category", claim.category.displayName)
                    valueRow("Date", claim.expenseDate.formatted(date: .long, time: .omitted))
                    valueRow("Amount", claim.amount.formatted(.currency(code: "USD")))
                    valueRow("Payment", claim.reimbursable ? "Employee paid" : "Company paid")
                }

                if canReview && claim.status == .submitted {
                    Section {
                        Button("Review Claim") { showingReview = true }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("ReviewFieldExpense")
                        if let issue = claim.approvalIssue(hasReceipt: receiptIsAvailable) {
                            Label(issue.localizedDescription, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                if canReview && claim.needsReimbursement {
                    Section {
                        Button("Record Reimbursement") { showingReimbursement = true }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                            .accessibilityIdentifier("ReimburseFieldExpense")
                    }
                }

                if isClaimant && claim.status == .correctionRequested {
                    Section {
                        Button("Correct & Resubmit") { showingCorrection = true }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("CorrectFieldExpense")
                    }
                }

                if claim.status == .reimbursed {
                    Section("Reimbursement") {
                        valueRow("Reference", claim.reimbursementReference ?? "Not recorded")
                        if let actor = claim.reimbursedByEmail, let date = claim.reimbursedAt {
                            Text("\(displayActor(actor)) • \(date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Business Context") {
                    valueRow("Job", claim.customerName ?? "General business")
                    if let summary = claim.jobSummary { valueRow("Work", summary) }
                    if claim.claimType == .expense { valueRow("Merchant", claim.merchant) }
                    if let miles = claim.mileageMiles, let rate = claim.mileageRatePerMile {
                        valueRow("Mileage", "\(miles.formatted(.number.precision(.fractionLength(0...2)))) mi × \(rate.formatted(.currency(code: "USD")))/mi")
                    }
                    if let origin = claim.mileageOrigin, let destination = claim.mileageDestination {
                        valueRow("Route", "\(origin) → \(destination)")
                    }
                    Text(claim.businessPurpose)
                }

                Section("Receipt") {
                    if let receiptAttachment {
                        Button {
                            guard FileManager.default.fileExists(atPath: receiptAttachment.localFilePath) else {
                                message = receiptAttachment.backendDocumentID == nil
                                    ? "This receipt is still syncing or is unavailable on this device."
                                    : "The company copy exists, but this device does not have a local preview."
                                return
                            }
                            previewFile = FieldExpensePreviewFile(url: receiptAttachment.localFileURL)
                        } label: {
                            Label(receiptAttachment.displayName, systemImage: "doc.text")
                        }
                    } else {
                        Text(claim.requiresReceiptForApproval ? "Receipt required before approval." : "No receipt attached.")
                            .foregroundStyle(claim.requiresReceiptForApproval ? .orange : .secondary)
                    }
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                }

                if let reviewNote = claim.reviewNote, !reviewNote.isEmpty {
                    Section("Review") {
                        Text(reviewNote)
                        if let reviewer = claim.reviewedByEmail, let reviewedAt = claim.reviewedAt {
                            Text("\(displayActor(reviewer)) • \(reviewedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("History") {
                    ForEach(claim.auditEvents.reversed()) { event in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(event.action.displayName)
                                .font(.subheadline.weight(.semibold))
                            Text(event.detail)
                                .font(.caption)
                            Text("\(displayActor(event.actorEmail)) • \(event.occurredAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .navigationTitle("Expense Claim")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showingReview) {
                FieldExpenseReviewSheet(claim: claim, hasReceipt: receiptIsAvailable)
            }
            .sheet(isPresented: $showingReimbursement) {
                FieldExpenseReimbursementSheet(claim: claim)
            }
            .sheet(isPresented: $showingCorrection) {
                FieldExpenseClaimEditor(
                    initialServiceCall: linkedServiceCall,
                    existingClaim: claim,
                    serviceCalls: serviceCalls,
                    technicians: technicians,
                    users: users
                )
            }
            .sheet(item: $previewFile) { file in
                AttachmentPreviewScreen(url: file.url)
            }
        }
    }

    private func valueRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
    }

    private func displayActor(_ email: String) -> String {
        masksActorIdentityForScreenshots ? "GunnAire team member" : email
    }
}

private enum FieldExpenseReviewDecision: String, CaseIterable, Identifiable {
    case approve
    case requestCorrection
    case reject

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .approve: "Approve"
        case .requestCorrection: "Request Correction"
        case .reject: "Reject"
        }
    }
}

private struct FieldExpenseReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]

    let claim: FieldExpenseClaim
    let hasReceipt: Bool
    @State private var decision: FieldExpenseReviewDecision = .approve
    @State private var note = ""
    @State private var errorMessage: String?

    private var currentEmail: String { AppAccess.normalizedEmail(AppIdentity.currentEmail) }
    private var currentRole: AppUserRole? { AppAccess.activeRole(email: currentEmail, users: users) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Decision") {
                    Picker("Decision", selection: $decision) {
                        ForEach(FieldExpenseReviewDecision.allCases) { decision in
                            Text(decision.displayName).tag(decision)
                        }
                    }
                    .accessibilityIdentifier("FieldExpenseReviewDecision")
                    TextField(decision == .approve ? "Review note (optional)" : "Reason (required)", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                        .accessibilityIdentifier("FieldExpenseReviewNote")
                }
                Section("Boundary") {
                    Text(decision == .approve
                        ? "Approval adds this cost to internal reporting. It does not post to QuickBooks or reimburse the employee."
                        : "The claimant keeps the original audit history and will see this reason.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if decision == .approve, let issue = claim.approvalIssue(hasReceipt: hasReceipt) {
                        Label(issue.localizedDescription, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
            }
            .navigationTitle("Review Claim")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Record") { save() }
                        .accessibilityIdentifier("SaveFieldExpenseReview")
                }
            }
        }
    }

    private func save() {
        do {
            guard let currentRole else { throw FieldExpenseClaimError.unauthorized }
            switch decision {
            case .approve:
                try claim.approve(
                    reviewerEmail: currentEmail,
                    reviewerRole: currentRole,
                    note: note,
                    hasReceipt: hasReceipt
                )
            case .requestCorrection:
                try claim.requestCorrection(note: note, reviewerEmail: currentEmail, reviewerRole: currentRole)
            case .reject:
                try claim.reject(note: note, reviewerEmail: currentEmail, reviewerRole: currentRole)
            }
            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct FieldExpenseReimbursementSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]

    let claim: FieldExpenseClaim
    @State private var reference = ""
    @State private var errorMessage: String?

    private var currentEmail: String { AppAccess.normalizedEmail(AppIdentity.currentEmail) }
    private var currentRole: AppUserRole? { AppAccess.activeRole(email: currentEmail, users: users) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Actual Payment") {
                    Text(claim.amount, format: .currency(code: "USD"))
                        .font(.title3.weight(.semibold))
                    TextField("Payroll, check, or accounting reference", text: $reference)
                        .accessibilityIdentifier("FieldExpenseReimbursementReference")
                    Text("Record this only after the employee was reimbursed outside the app. GunnAire Ops stores the evidence but does not send money or infer payment from approval.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
            }
            .navigationTitle("Record Reimbursement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Record") { save() }
                        .accessibilityIdentifier("SaveFieldExpenseReimbursement")
                }
            }
        }
    }

    private func save() {
        do {
            guard let currentRole else { throw FieldExpenseClaimError.unauthorized }
            try claim.markReimbursed(reference: reference, actorEmail: currentEmail, actorRole: currentRole)
            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

enum FieldExpenseAttachmentStore {
    private static let maximumFileSize = 25 * 1_024 * 1_024

    static func makeAttachment(
        sourceURL: URL,
        claimID: UUID,
        serviceCall: ServiceCall?
    ) throws -> ServiceDocumentAttachment {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }
        let resourceValues = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard resourceValues.isRegularFile != false else { throw FieldExpenseAttachmentError.invalidFile }
        if let size = resourceValues.fileSize, size > maximumFileSize {
            throw FieldExpenseAttachmentError.fileTooLarge
        }
        let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        guard !data.isEmpty else { throw FieldExpenseAttachmentError.invalidFile }
        guard data.count <= maximumFileSize else { throw FieldExpenseAttachmentError.fileTooLarge }

        let documentsURL = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folderURL = documentsURL.appendingPathComponent("GunnAire Expense Receipts", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let safeName = sanitizedFilename(sourceURL.lastPathComponent)
        let destination = folderURL.appendingPathComponent("\(claimID.uuidString)-\(UUID().uuidString)-\(safeName)")
        try data.write(to: destination, options: .atomic)
        let contentType = UTType(filenameExtension: sourceURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return ServiceDocumentAttachment(
            customer: nil,
            serviceCallID: serviceCall?.id,
            expenseClaimID: claimID,
            kind: .expenseReceipt,
            displayName: safeName,
            caption: "Internal field expense receipt • claim \(String(claimID.uuidString.prefix(8)).uppercased())",
            localFilePath: destination.path,
            contentType: contentType,
            fileSizeBytes: data.count,
            sharedCompanySyncStatus: GunnAireBackendService.isConfigured ? "needs_attention" : nil,
            sharedCompanySyncDetail: GunnAireBackendService.isConfigured
                ? "Waiting for shared company storage upload."
                : "Shared company storage is not configured for this build."
        )
    }

    private static func sanitizedFilename(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._- "))
        let sanitized = String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "expense-receipt" : String(sanitized.prefix(160))
    }
}

enum FieldExpenseAttachmentError: LocalizedError {
    case invalidFile
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidFile: "Choose a non-empty image or PDF receipt."
        case .fileTooLarge: "Choose a receipt no larger than 25 MB."
        }
    }
}

private struct FieldExpensePreviewFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private func statusColor(_ status: FieldExpenseClaimStatus) -> Color {
    switch status {
    case .submitted: .orange
    case .correctionRequested: .orange
    case .approved: .blue
    case .rejected: .red
    case .reimbursed: .green
    }
}

private extension FieldExpenseAuditAction {
    var displayName: String {
        switch self {
        case .submitted: "Submitted"
        case .correctionRequested: "Correction requested"
        case .resubmitted: "Resubmitted"
        case .approved: "Approved"
        case .rejected: "Rejected"
        case .reimbursed: "Reimbursed"
        }
    }
}
