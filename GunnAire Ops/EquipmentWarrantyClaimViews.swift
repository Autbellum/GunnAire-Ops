import SwiftUI
import SwiftData

struct EquipmentWarrantyClaimsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AppUser.email, order: .forward) private var users: [AppUser]
    @Query(sort: \ServiceCall.scheduledDate, order: .reverse) private var serviceCalls: [ServiceCall]
    @Query(sort: \ServiceDocumentAttachment.createdAt, order: .reverse) private var attachments: [ServiceDocumentAttachment]
    @Query(sort: \PurchaseOrder.updatedAt, order: .reverse) private var purchaseOrders: [PurchaseOrder]
    @Query(sort: \Item.name, order: .forward) private var catalogItems: [Item]

    let equipment: CustomerEquipment
    let originatingServiceCall: ServiceCall?
    let restrictToOriginatingJob: Bool

    @State private var expandedClaimIDs: Set<UUID> = []
    @State private var showingRequestSheet = false
    @State private var claimPendingSubmission: EquipmentWarrantyClaim?
    @State private var claimPendingDecision: EquipmentWarrantyClaim?
    @State private var claimPendingReplacement: EquipmentWarrantyClaim?
    @State private var claimPendingCredit: EquipmentWarrantyClaim?
    @State private var claimPendingCancellation: EquipmentWarrantyClaim?
    @State private var cancellationReason = ""
    @State private var actionMessage: String?

    init(
        equipment: CustomerEquipment,
        originatingServiceCall: ServiceCall? = nil,
        restrictToOriginatingJob: Bool = false
    ) {
        self.equipment = equipment
        self.originatingServiceCall = originatingServiceCall
        self.restrictToOriginatingJob = restrictToOriginatingJob
    }

    private var actorEmail: String? { AppIdentity.currentEmail }

    private var visibleClaims: [EquipmentWarrantyClaim] {
        guard restrictToOriginatingJob, let originatingServiceCall else {
            return equipment.warrantyClaims
        }
        return equipment.warrantyClaims.filter { $0.originatingServiceCallID == originatingServiceCall.id }
    }

    private var openClaims: [EquipmentWarrantyClaim] {
        visibleClaims.filter { $0.status.isOpen }
    }

    private var closedClaims: [EquipmentWarrantyClaim] {
        visibleClaims.filter { !$0.status.isOpen }
    }

    private var relevantPurchaseOrders: [PurchaseOrder] {
        let customerCallIDs = Set(serviceCalls.compactMap { call in
            call.customer.id == equipment.customer?.id ? call.id : nil
        })
        return purchaseOrders.filter { order in
            guard let serviceCallID = order.serviceCallID else { return false }
            return customerCallIDs.contains(serviceCallID)
        }
    }

    private var canRequest: Bool {
        guard AppAccess.canPerformWarrantyClaimAction(.request, email: actorEmail, users: users) else {
            return false
        }
        guard let originatingServiceCall else { return true }
        return AppAccess.canAccessServiceCall(
            originatingServiceCall,
            email: actorEmail,
            users: users,
            serviceCalls: serviceCalls
        )
    }

    private var canViewFinancials: Bool {
        AppAccess.canViewFinancialManagement(email: actorEmail, users: users)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Installed System") {
                    Text(equipment.displayName)
                        .font(.headline)
                    if let originatingServiceCall {
                        Text("Job: \(originatingServiceCall.type.displayName) • \(originatingServiceCall.scheduledDate.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Claims keep manufacturer evidence, the original job/order, replacement stock, and vendor-credit recovery together. They do not create an accounting credit without staff review.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let actionMessage {
                    Section("Action Status") {
                        Text(actionMessage)
                            .font(.caption)
                            .foregroundStyle(actionMessage.localizedCaseInsensitiveContains("failed") ? .orange : .secondary)
                            .accessibilityIdentifier("WarrantyClaimActionMessage")
                    }
                }

                Section("Open Claims") {
                    if openClaims.isEmpty {
                        Text("No open warranty claims for this system\(restrictToOriginatingJob ? " and job" : "").")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(openClaims) { claim in
                            claimRow(claim)
                        }
                    }

                    if canRequest {
                        Button {
                            showingRequestSheet = true
                        } label: {
                            Label("Request Warranty Claim", systemImage: "shield.lefthalf.filled.badge.checkmark")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.brandGold)
                        .foregroundStyle(Color.primaryBlack)
                        .accessibilityIdentifier("RequestWarrantyClaimButton")
                    }
                }

                if !closedClaims.isEmpty {
                    Section("Claim History") {
                        ForEach(closedClaims) { claim in
                            claimRow(claim)
                        }
                    }
                }
            }
            .navigationTitle("Warranty Claims")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(Color.brandGold)
        .sheet(isPresented: $showingRequestSheet) {
            EquipmentWarrantyClaimRequestSheet(
                equipment: equipment,
                originatingServiceCall: originatingServiceCall,
                attachments: EquipmentWarrantyClaimPolicy.eligibleEvidenceAttachments(
                    for: equipment,
                    originatingServiceCallID: originatingServiceCall?.id,
                    attachments: attachments
                ),
                purchaseOrders: relevantPurchaseOrders
            ) { submission in
                requestClaim(submission)
            }
            .tint(Color.brandGold)
        }
        .sheet(item: $claimPendingSubmission) { claim in
            EquipmentWarrantyClaimSubmissionSheet(
                claim: claim,
                eligibleAttachments: EquipmentWarrantyClaimPolicy.eligibleEvidenceAttachments(
                    for: equipment,
                    originatingServiceCallID: claim.originatingServiceCallID,
                    attachments: attachments
                )
            ) { claimNumber, evidenceIDs in
                submitClaim(claim, claimNumber: claimNumber, evidenceIDs: evidenceIDs)
            }
            .tint(Color.brandGold)
        }
        .sheet(item: $claimPendingDecision) { claim in
            EquipmentWarrantyClaimDecisionSheet(claim: claim) { approved, resolution, denial, partCredit, laborCredit in
                recordDecision(
                    claim,
                    approved: approved,
                    resolution: resolution,
                    denialReason: denial,
                    expectedPartCreditCents: partCredit,
                    expectedLaborCreditCents: laborCredit
                )
            }
            .tint(Color.brandGold)
        }
        .sheet(item: $claimPendingReplacement) { claim in
            EquipmentWarrantyReplacementReceiptSheet(
                claim: claim,
                catalogItems: catalogItems.filter(\.tracksInventory)
            ) { itemID, location, partNumber, serialNumber in
                recordReplacementReceipt(
                    claim,
                    catalogItemID: itemID,
                    location: location,
                    partNumber: partNumber,
                    serialNumber: serialNumber
                )
            }
            .tint(Color.brandGold)
        }
        .sheet(item: $claimPendingCredit) { claim in
            EquipmentWarrantyCreditReceiptSheet(claim: claim) { partCredit, laborCredit, reference, quickBooksID in
                recordCredit(
                    claim,
                    partCreditCents: partCredit,
                    laborCreditCents: laborCredit,
                    reference: reference,
                    quickBooksVendorCreditID: quickBooksID
                )
            }
            .tint(Color.brandGold)
        }
        .alert(
            "Cancel Warranty Claim",
            isPresented: Binding(
                get: { claimPendingCancellation != nil },
                set: { isPresented in
                    if !isPresented {
                        claimPendingCancellation = nil
                        cancellationReason = ""
                    }
                }
            )
        ) {
            TextField("Cancellation reason", text: $cancellationReason)
            Button("Cancel Claim", role: .destructive) {
                if let claim = claimPendingCancellation {
                    cancelClaim(claim, reason: cancellationReason)
                }
                claimPendingCancellation = nil
                cancellationReason = ""
            }
            Button("Keep Claim", role: .cancel) {}
        } message: {
            Text("The request and its history remain preserved, but the claim will leave the active recovery queue.")
        }
    }

    @ViewBuilder
    private func claimRow(_ claim: EquipmentWarrantyClaim) -> some View {
        let isExpanded = expandedClaimIDs.contains(claim.id)
        VStack(alignment: .leading, spacing: 7) {
            Button {
                if isExpanded {
                    expandedClaimIDs.remove(claim.id)
                } else {
                    expandedClaimIDs.insert(claim.id)
                }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: claimStatusSystemImage(claim.status))
                        .foregroundStyle(claimStatusColor(claim.status))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(claim.shortReference)
                            .font(.subheadline.weight(.semibold))
                        Text("\(claim.quantity.formatted(.number.precision(.fractionLength(0...3)))) × \(claim.failedPartName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let attention = claim.openAttentionSummary {
                            Text(attention)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(claim.status.displayName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(claimStatusColor(claim.status))
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(claim.shortReference), \(claim.status.displayName), \(claim.failedPartName). \(isExpanded ? "Collapse" : "Expand")")
            .accessibilityIdentifier("WarrantyClaim-\(claim.id.uuidString)")

            if isExpanded {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Manufacturer: \(claim.manufacturer)")
                    Text("Equipment serial: \(claim.equipmentSerialNumberSnapshot)")
                    if let distributorName = claim.distributorName {
                        Text("Distributor: \(distributorName)")
                    }
                    if let partNumber = claim.failedPartNumber {
                        Text("Failed part number: \(partNumber)")
                    }
                    Text("Issue: \(claim.issueDescription)")
                    Text("Evidence: \(claim.evidenceAttachmentIDs.count) file\(claim.evidenceAttachmentIDs.count == 1 ? "" : "s")")
                    if let resolution = claim.resolution {
                        Text("Resolution: \(resolution.displayName)")
                    }
                    if let denialReason = claim.denialReason {
                        Text("Denial: \(denialReason)")
                            .foregroundStyle(.orange)
                    }
                    if claim.replacementReceivedAt != nil {
                        Text("Replacement received: \(claim.replacementPartName ?? "Recorded part")")
                            .foregroundStyle(.green)
                    }
                    if canViewFinancials, claim.creditReceivedAt != nil {
                        Text("Credit received: \(currency(cents: claim.totalActualCreditCents)) • \(claim.vendorCreditReference ?? "No reference")")
                            .foregroundStyle(.green)
                    }
                    if let latestEvent = claim.events.sorted(by: { $0.occurredAt > $1.occurredAt }).first {
                        Text("Last update: \(latestEvent.occurredAt.formatted(date: .abbreviated, time: .shortened)) • \(latestEvent.actorEmail)")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption2)
                .frame(maxWidth: .infinity, alignment: .leading)

                claimActions(claim)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func claimActions(_ claim: EquipmentWarrantyClaim) -> some View {
        let canSubmit = claim.status == .requested && canPerform(.submit)
        let canDecide = claim.status == .submitted && canPerform(.recordDecision)
        let canReceive = claim.status == .approved && claim.resolution?.requiresReplacement == true && claim.replacementReceivedAt == nil && canPerform(.receiveReplacement)
        let canCredit = claim.status == .approved && claim.resolution?.requiresCredit == true && claim.creditReceivedAt == nil && canPerform(.recordCredit)
        let canClose = claim.status == .approved && claim.isRecoveryComplete && canPerform(.close)
        let canCancel = claim.status.isOpen && canPerform(.cancel)

        if canSubmit || canDecide || canReceive || canCredit || canClose || canCancel {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    claimActionButtons(
                        claim,
                        canSubmit: canSubmit,
                        canDecide: canDecide,
                        canReceive: canReceive,
                        canCredit: canCredit,
                        canClose: canClose,
                        canCancel: canCancel
                    )
                }
                VStack(alignment: .leading, spacing: 8) {
                    claimActionButtons(
                        claim,
                        canSubmit: canSubmit,
                        canDecide: canDecide,
                        canReceive: canReceive,
                        canCredit: canCredit,
                        canClose: canClose,
                        canCancel: canCancel
                    )
                }
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func claimActionButtons(
        _ claim: EquipmentWarrantyClaim,
        canSubmit: Bool,
        canDecide: Bool,
        canReceive: Bool,
        canCredit: Bool,
        canClose: Bool,
        canCancel: Bool
    ) -> some View {
        if canSubmit {
            Button("Submit") { claimPendingSubmission = claim }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("SubmitWarrantyClaim-\(claim.id.uuidString)")
        }
        if canDecide {
            Button("Record Decision") { claimPendingDecision = claim }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("DecideWarrantyClaim-\(claim.id.uuidString)")
        }
        if canReceive {
            Button("Receive Replacement") { claimPendingReplacement = claim }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("ReceiveWarrantyReplacement-\(claim.id.uuidString)")
        }
        if canCredit {
            Button("Record Credit") { claimPendingCredit = claim }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("RecordWarrantyCredit-\(claim.id.uuidString)")
        }
        if canClose {
            Button("Close Claim") { closeClaim(claim) }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("CloseWarrantyClaim-\(claim.id.uuidString)")
        }
        if canCancel {
            Menu {
                Button("Cancel Claim", role: .destructive) {
                    claimPendingCancellation = claim
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .buttonStyle(.bordered)
        }
    }

    private func canPerform(_ action: AppAccess.WarrantyClaimAction) -> Bool {
        AppAccess.canPerformWarrantyClaimAction(action, email: actorEmail, users: users)
    }

    private func requestClaim(_ submission: EquipmentWarrantyClaimRequest) {
        guard canRequest else {
            actionMessage = "Warranty claim access changed. Reopen an assigned job or use an approved office account."
            return
        }
        do {
            var validatedSubmission = submission
            if !submission.evidenceAttachmentIDs.isEmpty {
                let ids = try EquipmentWarrantyClaimPolicy.validatedEvidenceIDs(
                    submission.evidenceAttachmentIDs,
                    for: equipment,
                    originatingServiceCallID: submission.originatingServiceCallID,
                    attachments: attachments
                )
                validatedSubmission = .init(
                    manufacturer: submission.manufacturer,
                    distributorName: submission.distributorName,
                    equipmentSerialNumber: submission.equipmentSerialNumber,
                    issueDescription: submission.issueDescription,
                    failedPartName: submission.failedPartName,
                    failedPartNumber: submission.failedPartNumber,
                    failedPartSerialNumber: submission.failedPartSerialNumber,
                    quantity: submission.quantity,
                    originatingServiceCallID: submission.originatingServiceCallID,
                    originalPurchaseOrderID: submission.originalPurchaseOrderID,
                    originalPurchaseOrderLineID: submission.originalPurchaseOrderLineID,
                    evidenceAttachmentIDs: ids
                )
            }
            let claim = try EquipmentWarrantyClaimPolicy.request(
                for: equipment,
                submission: validatedSubmission,
                actorEmail: actorEmail
            )
            equipment.upsertWarrantyClaim(claim)
            if let originatingServiceCall {
                ServiceCallActivity.record(
                    for: originatingServiceCall,
                    action: "Warranty claim requested",
                    detail: "\(claim.quantity.formatted(.number.precision(.fractionLength(0...3)))) × \(claim.failedPartName) • request \(String(claim.id.uuidString.prefix(8)).uppercased())",
                    actorEmail: actorEmail,
                    in: modelContext
                )
            }
            try modelContext.save()
            showingRequestSheet = false
            expandedClaimIDs.insert(claim.id)
            actionMessage = "Saved warranty request for \(claim.failedPartName). Office submission is next."
        } catch {
            actionMessage = "Warranty request failed: \(error.localizedDescription)"
        }
    }

    private func submitClaim(_ selected: EquipmentWarrantyClaim, claimNumber: String, evidenceIDs: [UUID]) {
        guard canPerform(.submit), var claim = freshClaim(selected.id) else {
            actionMessage = "Warranty submission access changed or the claim is no longer available."
            return
        }
        do {
            let validatedIDs = try EquipmentWarrantyClaimPolicy.validatedEvidenceIDs(
                evidenceIDs,
                for: equipment,
                originatingServiceCallID: claim.originatingServiceCallID,
                attachments: attachments
            )
            try claim.submit(
                claimNumber: claimNumber,
                evidenceAttachmentIDs: validatedIDs,
                actorEmail: actorEmail
            )
            try persist(claim)
            claimPendingSubmission = nil
            actionMessage = "Submitted warranty claim \(claim.shortReference)."
        } catch {
            actionMessage = "Warranty submission failed: \(error.localizedDescription)"
        }
    }

    private func recordDecision(
        _ selected: EquipmentWarrantyClaim,
        approved: Bool,
        resolution: EquipmentWarrantyResolution?,
        denialReason: String?,
        expectedPartCreditCents: Int?,
        expectedLaborCreditCents: Int?
    ) {
        guard canPerform(.recordDecision), var claim = freshClaim(selected.id) else {
            actionMessage = "Warranty decision access changed or the claim is no longer available."
            return
        }
        do {
            try claim.recordDecision(
                approved: approved,
                resolution: resolution,
                denialReason: denialReason,
                expectedPartCreditCents: expectedPartCreditCents,
                expectedLaborCreditCents: expectedLaborCreditCents,
                actorEmail: actorEmail
            )
            try persist(claim)
            claimPendingDecision = nil
            actionMessage = approved
                ? "Recorded approval for \(claim.shortReference)."
                : "Recorded denial for \(claim.shortReference)."
        } catch {
            actionMessage = "Warranty decision failed: \(error.localizedDescription)"
        }
    }

    private func recordReplacementReceipt(
        _ selected: EquipmentWarrantyClaim,
        catalogItemID: UUID,
        location: String,
        partNumber: String?,
        serialNumber: String?
    ) {
        guard canPerform(.receiveReplacement),
              var claim = freshClaim(selected.id),
              let item = catalogItems.first(where: { $0.id == catalogItemID && $0.tracksInventory }) else {
            actionMessage = "Select an inventory-tracked pricebook item with current warranty access."
            return
        }
        let normalizedLocation = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLocation.isEmpty else {
            actionMessage = "Enter the warehouse, truck, or other receiving location."
            return
        }
        let movement = InventoryMovement(
            item: item,
            type: .receive,
            quantity: claim.quantity,
            destinationLocation: normalizedLocation,
            serviceCallID: claim.originatingServiceCallID,
            notes: "[WarrantyClaim:\(claim.id.uuidString)] Replacement received for \(claim.shortReference).",
            createdByEmail: actorEmail
        )
        do {
            try claim.recordReplacementReceipt(
                catalogItemID: item.id,
                partName: item.name,
                partNumber: partNumber ?? item.vendorPartNumber ?? item.sku,
                serialNumber: serialNumber,
                inventoryMovementID: movement.id,
                actorEmail: actorEmail
            )
            modelContext.insert(movement)
            equipment.upsertWarrantyClaim(claim)
            try modelContext.save()
            claimPendingReplacement = nil
            actionMessage = "Received \(item.name) into \(normalizedLocation) and linked the stock movement to \(claim.shortReference)."
        } catch {
            modelContext.rollback()
            actionMessage = "Replacement receipt failed: \(error.localizedDescription)"
        }
    }

    private func recordCredit(
        _ selected: EquipmentWarrantyClaim,
        partCreditCents: Int,
        laborCreditCents: Int,
        reference: String,
        quickBooksVendorCreditID: String?
    ) {
        guard canPerform(.recordCredit), var claim = freshClaim(selected.id) else {
            actionMessage = "Warranty credit access changed or the claim is no longer available."
            return
        }
        do {
            try claim.recordCredit(
                partCreditCents: partCreditCents,
                laborCreditCents: laborCreditCents,
                reference: reference,
                quickBooksVendorCreditID: quickBooksVendorCreditID,
                actorEmail: actorEmail
            )
            try persist(claim)
            claimPendingCredit = nil
            actionMessage = "Recorded \(currency(cents: claim.totalActualCreditCents)) of warranty recovery for \(claim.shortReference)."
        } catch {
            actionMessage = "Warranty credit failed: \(error.localizedDescription)"
        }
    }

    private func closeClaim(_ selected: EquipmentWarrantyClaim) {
        guard canPerform(.close), var claim = freshClaim(selected.id) else {
            actionMessage = "Warranty closeout access changed or the claim is no longer available."
            return
        }
        do {
            try claim.close(actorEmail: actorEmail)
            try persist(claim)
            actionMessage = "Closed \(claim.shortReference) with recovery evidence preserved."
        } catch {
            actionMessage = "Warranty closeout failed: \(error.localizedDescription)"
        }
    }

    private func cancelClaim(_ selected: EquipmentWarrantyClaim, reason: String) {
        guard canPerform(.cancel), var claim = freshClaim(selected.id) else {
            actionMessage = "Warranty cancellation access changed or the claim is no longer available."
            return
        }
        do {
            try claim.cancel(reason: reason, actorEmail: actorEmail)
            try persist(claim)
            actionMessage = "Cancelled \(claim.shortReference); its evidence remains in claim history."
        } catch {
            actionMessage = "Warranty cancellation failed: \(error.localizedDescription)"
        }
    }

    private func freshClaim(_ id: UUID) -> EquipmentWarrantyClaim? {
        equipment.warrantyClaims.first { $0.id == id }
    }

    private func persist(_ claim: EquipmentWarrantyClaim) throws {
        equipment.upsertWarrantyClaim(claim)
        try modelContext.save()
    }

    private func currency(cents: Int) -> String {
        (Double(cents) / 100).formatted(.currency(code: "USD"))
    }

    private func claimStatusSystemImage(_ status: EquipmentWarrantyClaimStatus) -> String {
        switch status {
        case .requested: "tray.and.arrow.up"
        case .submitted: "paperplane"
        case .approved: "checkmark.shield"
        case .denied: "xmark.shield"
        case .closed: "checkmark.circle.fill"
        case .cancelled: "slash.circle"
        }
    }

    private func claimStatusColor(_ status: EquipmentWarrantyClaimStatus) -> Color {
        switch status {
        case .requested, .submitted: .orange
        case .approved: .blue
        case .denied: .red
        case .closed: .green
        case .cancelled: .secondary
        }
    }
}

private struct EquipmentWarrantyClaimRequestSheet: View {
    @Environment(\.dismiss) private var dismiss

    let equipment: CustomerEquipment
    let originatingServiceCall: ServiceCall?
    let attachments: [ServiceDocumentAttachment]
    let purchaseOrders: [PurchaseOrder]
    let onSave: (EquipmentWarrantyClaimRequest) -> Void

    @State private var manufacturer: String
    @State private var distributorName = ""
    @State private var equipmentSerial: String
    @State private var issueDescription = ""
    @State private var failedPartName = ""
    @State private var failedPartNumber = ""
    @State private var failedPartSerial = ""
    @State private var quantity = "1"
    @State private var selectedEvidenceIDs: Set<UUID> = []
    @State private var selectedPurchaseOrderID: UUID?
    @State private var selectedPurchaseOrderLineID: UUID?

    init(
        equipment: CustomerEquipment,
        originatingServiceCall: ServiceCall?,
        attachments: [ServiceDocumentAttachment],
        purchaseOrders: [PurchaseOrder],
        onSave: @escaping (EquipmentWarrantyClaimRequest) -> Void
    ) {
        self.equipment = equipment
        self.originatingServiceCall = originatingServiceCall
        self.attachments = attachments
        self.purchaseOrders = purchaseOrders
        self.onSave = onSave
        _manufacturer = State(initialValue: equipment.manufacturer ?? originatingServiceCall?.equipmentManufacturer ?? "")
        _equipmentSerial = State(initialValue: equipment.serialNumber ?? originatingServiceCall?.equipmentSerialNumber ?? "")
    }

    private var selectedPurchaseOrder: PurchaseOrder? {
        guard let selectedPurchaseOrderID else { return nil }
        return purchaseOrders.first { $0.id == selectedPurchaseOrderID }
    }

    private var parsedQuantity: Double? {
        guard let value = Double(quantity), value.isFinite, value >= 1, value <= 1_000 else { return nil }
        return value
    }

    private var canSave: Bool {
        !manufacturer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !equipmentSerial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !issueDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !failedPartName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            parsedQuantity != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Installed System") {
                    Text(equipment.displayName)
                        .font(.headline)
                    TextField("Manufacturer", text: $manufacturer)
                        .accessibilityIdentifier("WarrantyManufacturer")
                    TextField("Equipment serial", text: $equipmentSerial)
                        .textInputAutocapitalization(.characters)
                        .accessibilityIdentifier("WarrantyEquipmentSerial")
                    TextField("Distributor / supplier (optional)", text: $distributorName)
                }

                Section("Failure") {
                    TextField("Failed part or component", text: $failedPartName)
                        .accessibilityIdentifier("WarrantyFailedPart")
                    TextField("Part number (optional)", text: $failedPartNumber)
                        .textInputAutocapitalization(.characters)
                    TextField("Part serial (optional)", text: $failedPartSerial)
                        .textInputAutocapitalization(.characters)
                    TextField("Quantity", text: $quantity)
                        .keyboardType(.decimalPad)
                    TextField("Failure and diagnostic finding", text: $issueDescription, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("WarrantyIssueDescription")
                }

                if !purchaseOrders.isEmpty {
                    Section("Original Purchase (Optional)") {
                        Picker("Purchase order", selection: $selectedPurchaseOrderID) {
                            Text("Not linked").tag(UUID?.none)
                            ForEach(purchaseOrders) { order in
                                Text("\(order.number) • \(order.vendorName)").tag(UUID?.some(order.id))
                            }
                        }
                        .onChange(of: selectedPurchaseOrderID) { _, _ in
                            selectedPurchaseOrderLineID = nil
                        }
                        if let selectedPurchaseOrder {
                            Picker("Order line", selection: $selectedPurchaseOrderLineID) {
                                Text("Not linked").tag(UUID?.none)
                                ForEach(selectedPurchaseOrder.purchaseOrderLines) { line in
                                    Text(line.itemName).tag(UUID?.some(line.id))
                                }
                            }
                        }
                    }
                }

                Section("Evidence") {
                    if attachments.isEmpty {
                        Text("No job or equipment files are available yet. The request can be saved now, but office submission requires at least one linked evidence file.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text("Select diagnostic photos, the data plate, or other files that already belong to this job or installed system.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(attachments) { attachment in
                            Toggle(isOn: Binding(
                                get: { selectedEvidenceIDs.contains(attachment.id) },
                                set: { selected in
                                    if selected { selectedEvidenceIDs.insert(attachment.id) }
                                    else { selectedEvidenceIDs.remove(attachment.id) }
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(attachment.displayName)
                                    Text(attachment.kind.label)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section {
                    Text("Saving creates an internal request. Dispatch/Admin still confirms the manufacturer submission and claim number.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Request Warranty Claim")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save Request") {
                        guard let parsedQuantity else { return }
                        onSave(.init(
                            manufacturer: manufacturer,
                            distributorName: distributorName,
                            equipmentSerialNumber: equipmentSerial,
                            issueDescription: issueDescription,
                            failedPartName: failedPartName,
                            failedPartNumber: failedPartNumber,
                            failedPartSerialNumber: failedPartSerial,
                            quantity: parsedQuantity,
                            originatingServiceCallID: originatingServiceCall?.id,
                            originalPurchaseOrderID: selectedPurchaseOrderID,
                            originalPurchaseOrderLineID: selectedPurchaseOrderLineID,
                            evidenceAttachmentIDs: Array(selectedEvidenceIDs)
                        ))
                    }
                    .disabled(!canSave)
                    .accessibilityIdentifier("SaveWarrantyRequest")
                }
            }
        }
    }
}

private struct EquipmentWarrantyClaimSubmissionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let claim: EquipmentWarrantyClaim
    let eligibleAttachments: [ServiceDocumentAttachment]
    let onSubmit: (String, [UUID]) -> Void

    @State private var claimNumber = ""
    @State private var selectedEvidenceIDs: Set<UUID>

    init(
        claim: EquipmentWarrantyClaim,
        eligibleAttachments: [ServiceDocumentAttachment],
        onSubmit: @escaping (String, [UUID]) -> Void
    ) {
        self.claim = claim
        self.eligibleAttachments = eligibleAttachments
        self.onSubmit = onSubmit
        _claimNumber = State(initialValue: claim.claimNumber ?? "")
        _selectedEvidenceIDs = State(initialValue: Set(claim.evidenceAttachmentIDs))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Submission") {
                    Text(claim.failedPartName)
                        .font(.headline)
                    TextField("Claim number or confirmation", text: $claimNumber)
                        .textInputAutocapitalization(.characters)
                        .accessibilityIdentifier("WarrantyClaimNumber")
                }
                Section("Required Evidence") {
                    if eligibleAttachments.isEmpty {
                        Text("Add and link a diagnostic, data-plate, or Warranty Evidence file before submitting.")
                            .foregroundStyle(.orange)
                    } else {
                        ForEach(eligibleAttachments) { attachment in
                            Toggle(isOn: Binding(
                                get: { selectedEvidenceIDs.contains(attachment.id) },
                                set: { selected in
                                    if selected { selectedEvidenceIDs.insert(attachment.id) }
                                    else { selectedEvidenceIDs.remove(attachment.id) }
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(attachment.displayName)
                                    Text(attachment.kind.label)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Submit Warranty Claim")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Record Submission") {
                        onSubmit(claimNumber, Array(selectedEvidenceIDs))
                    }
                    .disabled(
                        claimNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            selectedEvidenceIDs.isEmpty
                    )
                    .accessibilityIdentifier("ConfirmWarrantySubmission")
                }
            }
        }
    }
}

private struct EquipmentWarrantyClaimDecisionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let claim: EquipmentWarrantyClaim
    let onRecord: (Bool, EquipmentWarrantyResolution?, String?, Int?, Int?) -> Void

    @State private var approved = true
    @State private var resolution: EquipmentWarrantyResolution = .replacement
    @State private var denialReason = ""
    @State private var expectedPartCredit = ""
    @State private var expectedLaborCredit = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Manufacturer Decision") {
                    Picker("Decision", selection: $approved) {
                        Text("Approved").tag(true)
                        Text("Denied").tag(false)
                    }
                    .pickerStyle(.segmented)
                    if approved {
                        Picker("Resolution", selection: $resolution) {
                            ForEach(EquipmentWarrantyResolution.allCases) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                        TextField("Expected part credit (optional)", text: $expectedPartCredit)
                            .keyboardType(.decimalPad)
                        TextField("Expected labor credit (optional)", text: $expectedLaborCredit)
                            .keyboardType(.decimalPad)
                    } else {
                        TextField("Denial reason", text: $denialReason, axis: .vertical)
                            .lineLimit(2...5)
                            .accessibilityIdentifier("WarrantyDenialReason")
                    }
                }
                Section {
                    Text("Expected amounts are planning values. Accounting records the actual credit only after a vendor memo or reimbursement is received.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Warranty Decision")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save Decision") {
                        onRecord(
                            approved,
                            approved ? resolution : nil,
                            approved ? nil : denialReason,
                            cents(from: expectedPartCredit),
                            cents(from: expectedLaborCredit)
                        )
                    }
                    .disabled(!approved && denialReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("SaveWarrantyDecision")
                }
            }
        }
    }

    private func cents(from text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let amount = Decimal(string: trimmed), amount >= 0 else { return nil }
        return NSDecimalNumber(decimal: amount * 100).intValue
    }
}

private struct EquipmentWarrantyReplacementReceiptSheet: View {
    @Environment(\.dismiss) private var dismiss
    let claim: EquipmentWarrantyClaim
    let catalogItems: [Item]
    let onReceive: (UUID, String, String?, String?) -> Void

    @State private var selectedItemID: UUID?
    @State private var location = "Warehouse"
    @State private var partNumber = ""
    @State private var serialNumber = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Replacement Stock") {
                    Picker("Pricebook item", selection: $selectedItemID) {
                        Text("Choose inventory item").tag(UUID?.none)
                        ForEach(catalogItems) { item in
                            Text(item.name).tag(UUID?.some(item.id))
                        }
                    }
                    .accessibilityIdentifier("WarrantyReplacementItem")
                    TextField("Receiving location", text: $location)
                    TextField("Replacement part number (optional)", text: $partNumber)
                        .textInputAutocapitalization(.characters)
                    TextField("Replacement serial (optional)", text: $serialNumber)
                        .textInputAutocapitalization(.characters)
                }
                Section {
                    Text("This records \(claim.quantity.formatted(.number.precision(.fractionLength(0...3)))) unit\(claim.quantity == 1 ? "" : "s") in the physical stock ledger and links that immutable movement to the claim. The selected pricebook item remains in the normal QuickBooks item-sync queue.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Receive Replacement")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Record Receipt") {
                        guard let selectedItemID else { return }
                        onReceive(selectedItemID, location, partNumber.warrantyNilIfBlank, serialNumber.warrantyNilIfBlank)
                    }
                    .disabled(selectedItemID == nil || location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("SaveWarrantyReplacementReceipt")
                }
            }
        }
    }
}

private struct EquipmentWarrantyCreditReceiptSheet: View {
    @Environment(\.dismiss) private var dismiss
    let claim: EquipmentWarrantyClaim
    let onRecord: (Int, Int, String, String?) -> Void

    @State private var partCredit: String
    @State private var laborCredit: String
    @State private var reference = ""
    @State private var quickBooksVendorCreditID = ""

    init(
        claim: EquipmentWarrantyClaim,
        onRecord: @escaping (Int, Int, String, String?) -> Void
    ) {
        self.claim = claim
        self.onRecord = onRecord
        _partCredit = State(initialValue: claim.expectedPartCreditCents.map { String(format: "%.2f", Double($0) / 100) } ?? "")
        _laborCredit = State(initialValue: claim.expectedLaborCreditCents.map { String(format: "%.2f", Double($0) / 100) } ?? "")
    }

    private var partCreditCents: Int? { cents(from: partCredit) }
    private var laborCreditCents: Int? { cents(from: laborCredit) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Received Credit") {
                    TextField("Part/vendor credit", text: $partCredit)
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("WarrantyPartCredit")
                    TextField("Labor credit", text: $laborCredit)
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("WarrantyLaborCredit")
                    TextField("Vendor credit memo / reimbursement reference", text: $reference)
                        .textInputAutocapitalization(.characters)
                        .accessibilityIdentifier("WarrantyCreditReference")
                    TextField("QuickBooks vendor credit ID (optional)", text: $quickBooksVendorCreditID)
                        .textInputAutocapitalization(.never)
                }
                Section {
                    Text("Record only a received vendor memo or reimbursement. The QuickBooks ID is reconciliation evidence; this screen never creates or changes a QuickBooks vendor credit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Record Warranty Credit")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Record Credit") {
                        onRecord(
                            partCreditCents ?? 0,
                            laborCreditCents ?? 0,
                            reference,
                            quickBooksVendorCreditID.warrantyNilIfBlank
                        )
                    }
                    .disabled(
                        reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            ((partCreditCents ?? 0) + (laborCreditCents ?? 0) <= 0)
                    )
                    .accessibilityIdentifier("SaveWarrantyCredit")
                }
            }
        }
    }

    private func cents(from text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let amount = Decimal(string: trimmed), amount >= 0 else { return nil }
        return NSDecimalNumber(decimal: amount * 100).intValue
    }
}

private extension String {
    var warrantyNilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
