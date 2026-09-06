import SwiftUI

struct MaintenanceAgreementOfferSubmission {
    let planName: String?
    let schedulePattern: String
    let nextDate: Date
    let termEndsOn: Date?
    let agreementPrice: Double?
    let billingInterval: MaintenanceAgreementBillingInterval
    let billingCatalogItemID: UUID?
    let billingAnchorDate: Date?
    let pricePerVisit: Double?
    let memberDiscountPercent: Double?
    let includedVisitsPerTerm: Int
    let autoRenews: Bool
    let termsSummary: String?
    let coveredEquipmentIDs: Set<UUID>
    let approval: MaintenanceAgreementApprovalSubmission?
}

struct MaintenanceAgreementApprovalSubmission {
    let customerName: String
    let method: EstimateApprovalMethod
    let reference: String?
    let signatureImageBase64: String?
}

struct MaintenanceAgreementOfferSheet: View {
    private static let defaultTermsSummary = "Includes scheduled preventive-maintenance visits and the covered services listed in this agreement. Repairs, replacement equipment, and excluded materials require separate customer approval."

    private enum Step {
        case terms
        case approval
    }

    @Environment(\.dismiss) private var dismiss

    let customer: Customer
    let equipmentProfiles: [CustomerEquipment]
    let billingItems: [Item]
    let renewalSource: RecurringMaintenanceContract?
    let onSubmit: (MaintenanceAgreementOfferSubmission) -> Void

    @State private var step: Step = .terms
    @State private var planName = "Comfort Membership"
    @State private var schedulePattern = "Every 6 months"
    @State private var nextDate = Calendar.current.date(byAdding: .month, value: 6, to: Date()) ?? Date()
    @State private var includesTerm = true
    @State private var termEndsOn = Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date()
    @State private var agreementPrice = ""
    @State private var billingInterval: MaintenanceAgreementBillingInterval = .annual
    @State private var selectedBillingCatalogItemID: UUID?
    @State private var firstBillingDate = Calendar.current.startOfDay(for: Date())
    @State private var pricePerVisit = ""
    @State private var memberDiscountPercent = ""
    @State private var includedVisitsPerTerm = 2
    @State private var autoRenews = true
    @State private var termsSummary = MaintenanceAgreementOfferSheet.defaultTermsSummary
    @State private var coveredEquipmentIDs: Set<UUID> = []
    @State private var approvalName = ""
    @State private var approvalMethod: EstimateApprovalMethod = .inPersonSignature
    @State private var approvalReference = ""
    @State private var signatureStrokes: [[CGPoint]] = []
    @State private var customerConfirmed = false
    @State private var validationMessage: String?

    init(
        customer: Customer,
        equipmentProfiles: [CustomerEquipment],
        billingItems: [Item],
        renewalSource: RecurringMaintenanceContract? = nil,
        onSubmit: @escaping (MaintenanceAgreementOfferSubmission) -> Void
    ) {
        self.customer = customer
        self.equipmentProfiles = equipmentProfiles
        self.billingItems = billingItems
        self.renewalSource = renewalSource
        self.onSubmit = onSubmit

        guard let renewalSource else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let proposedNextDate = renewalSource.nextDate >= today
            ? renewalSource.nextDate
            : (calendar.date(byAdding: .month, value: 1, to: today) ?? today)
        let renewalTermBase = max(max(renewalSource.termEndsOn ?? today, today), proposedNextDate)
        let proposedTermEnd = calendar.date(byAdding: .year, value: 1, to: renewalTermBase)
            ?? renewalTermBase

        _planName = State(initialValue: renewalSource.displayName)
        _schedulePattern = State(initialValue: renewalSource.schedulePattern)
        _nextDate = State(initialValue: proposedNextDate)
        _includesTerm = State(initialValue: renewalSource.termEndsOn != nil)
        _termEndsOn = State(initialValue: proposedTermEnd)
        _agreementPrice = State(initialValue: Self.decimalText(renewalSource.agreementPrice))
        _billingInterval = State(initialValue: renewalSource.billingInterval)
        _selectedBillingCatalogItemID = State(initialValue: renewalSource.billingCatalogItemID)
        _firstBillingDate = State(
            initialValue: renewalSource.billingAnchorDate
                ?? Calendar.current.startOfDay(for: Date())
        )
        _pricePerVisit = State(initialValue: Self.decimalText(renewalSource.pricePerVisit))
        _memberDiscountPercent = State(initialValue: Self.decimalText(renewalSource.memberDiscountPercent))
        _includedVisitsPerTerm = State(initialValue: max(1, renewalSource.includedVisitsPerTerm ?? 2))
        _autoRenews = State(initialValue: renewalSource.autoRenews)
        _termsSummary = State(initialValue: renewalSource.termsSummary ?? Self.defaultTermsSummary)
        _coveredEquipmentIDs = State(initialValue: renewalSource.coveredEquipmentIDs)
    }

    var body: some View {
        NavigationStack {
            Form {
                if step == .terms {
                    termsForm
                } else {
                    approvalForm
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    if step == .terms {
                        termsActionBar
                    } else {
                        approvalActionBar
                    }
                }
                .background(.regularMaterial)
            }
            .navigationTitle(step == .terms ? offerTitle : "Customer Approval")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(step == .terms ? "Cancel" : "Back") {
                        if step == .terms {
                            dismiss()
                        } else {
                            validationMessage = nil
                            step = .terms
                        }
                    }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 650)
    }

    @ViewBuilder
    private var termsForm: some View {
        if let renewalSource {
            Section("Renewal") {
                LabeledContent("Current agreement", value: renewalSource.displayName)
                Text("The current agreement remains active until this renewal is approved. Saving a draft never interrupts scheduled service.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        Section("Plan") {
            TextField("Plan name", text: $planName)
            TextField("Visit cadence", text: $schedulePattern)
            DatePicker("First / next visit", selection: $nextDate, displayedComponents: .date)
            Stepper("Included visits per term: \(includedVisitsPerTerm)", value: $includedVisitsPerTerm, in: 1...12)
        }

        Section("Term & Pricing") {
            Toggle("Set agreement term", isOn: $includesTerm)
            if includesTerm {
                DatePicker("Term ends", selection: $termEndsOn, in: nextDate..., displayedComponents: .date)
                Toggle("Auto-renew at term end", isOn: $autoRenews)
            }
            TextField("Agreement price (optional)", text: $agreementPrice)
                .keyboardType(.decimalPad)
            Picker("Billing interval", selection: $billingInterval) {
                ForEach(MaintenanceAgreementBillingInterval.allCases) { interval in
                    Text(interval.displayName).tag(interval)
                }
            }
            if billingConfigurationIsRequired {
                Picker("Billing item", selection: $selectedBillingCatalogItemID) {
                    Text("Select approved item").tag(UUID?.none)
                    ForEach(selectableBillingItems) { item in
                        Text(billingItemLabel(item)).tag(Optional(item.id))
                    }
                }
                .accessibilityIdentifier("AgreementBillingItemPicker")

                if billingInterval == .perVisit {
                    Text("Each completed maintenance visit releases one invoice at the approved per-visit agreement price.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    DatePicker(
                        "First billing date",
                        selection: $firstBillingDate,
                        displayedComponents: .date
                    )
                    .accessibilityIdentifier("AgreementFirstBillingDate")
                }

                Text("This internal pricebook item supplies the QuickBooks product/service mapping. The customer-approved agreement price remains locked on each invoice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if selectableBillingItems.isEmpty {
                    Label(
                        "No approved billing items are available. An administrator must create or approve a pricebook item before this paid agreement can be saved.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
            TextField("Member visit price (optional)", text: $pricePerVisit)
                .keyboardType(.decimalPad)
            TextField("Member repair discount % (optional)", text: $memberDiscountPercent)
                .keyboardType(.decimalPad)
        }

        if !equipmentProfiles.isEmpty {
            Section("Covered Equipment") {
                Text("Select every system covered by this agreement. Leave all unselected only when coverage will be documented in the terms.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(equipmentProfiles) { equipment in
                    Toggle(equipment.displayName, isOn: coveredEquipmentBinding(for: equipment.id))
                }
            }
        }

        Section("Terms") {
            TextEditor(text: $termsSummary)
                .frame(minHeight: 110)
            Text("Saving a draft does not schedule recurring work. The agreement becomes active only after customer approval is recorded.")
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

    @ViewBuilder
    private var approvalForm: some View {
        Section("Agreement Review") {
            LabeledContent("Customer", value: customer.name)
            LabeledContent("Plan", value: normalizedPlanName ?? "Maintenance Agreement")
            LabeledContent("Visits", value: "\(includedVisitsPerTerm) • \(normalizedSchedulePattern)")
            if let price = parsedAgreementPrice {
                LabeledContent("Price", value: price.formatted(.currency(code: "USD")) + " • " + billingInterval.displayName)
                if let billingItem = selectedBillingItem {
                    LabeledContent("Billing item", value: billingItem.name)
                }
                if billingInterval != .perVisit {
                    LabeledContent("First billing", value: firstBillingDate.formatted(date: .abbreviated, time: .omitted))
                }
            }
            if includesTerm {
                LabeledContent("Term ends", value: termEndsOn.formatted(date: .abbreviated, time: .omitted))
            }
        }

        Section("Approval Evidence") {
            TextField("Approving customer name", text: $approvalName)
            Picker("Approval method", selection: $approvalMethod) {
                ForEach(EstimateApprovalMethod.allCases) { method in
                    Text(method.displayName).tag(method)
                }
            }

            if approvalMethod.requiresSignature {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Customer signature")
                        .font(.subheadline)
                    SignaturePad(strokes: $signatureStrokes)
                        .frame(height: 180)
                    HStack {
                        Text(hasSignature ? "Signature captured." : "Signature required.")
                            .font(.caption)
                            .foregroundStyle(hasSignature ? .green : .secondary)
                        Spacer()
                        Button("Clear") { signatureStrokes = [] }
                            .font(.caption)
                    }
                }
            } else {
                TextField(approvalMethod.referencePrompt, text: $approvalReference, axis: .vertical)
                    .lineLimit(2...4)
            }

            Toggle("Customer reviewed and accepted these agreement terms", isOn: $customerConfirmed)
        }

        if let validationMessage {
            Section {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }

    }

    private var termsActionBar: some View {
        HStack(spacing: 12) {
            Button("Save Draft") {
                saveDraft()
            }
            .buttonStyle(.bordered)

            Spacer()

            Button("Review & Approve") {
                guard validateTerms() else { return }
                approvalName = approvalName.isEmpty ? customer.name : approvalName
                validationMessage = nil
                step = .approval
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.brandGold)
            .foregroundStyle(Color.primaryBlack)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var approvalActionBar: some View {
        Button("Activate Agreement") {
            activateAgreement()
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(.borderedProminent)
        .tint(Color.brandGold)
        .foregroundStyle(Color.primaryBlack)
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var normalizedPlanName: String? {
        planName.maintenanceAgreementNilIfBlank
    }

    private var offerTitle: String {
        renewalSource == nil ? "Create Service Agreement" : "Renew Service Agreement"
    }

    private var normalizedSchedulePattern: String {
        schedulePattern.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedAgreementPrice: Double? { parseMoney(agreementPrice) }
    private var billingConfigurationIsRequired: Bool {
        let entered = agreementPrice.trimmingCharacters(in: .whitespacesAndNewlines)
        return parsedAgreementPrice.map { $0 > 0.009 } ?? !entered.isEmpty
    }
    private var selectableBillingItems: [Item] {
        billingItems
            .filter { !$0.requiresPricebookReview && $0.isAvailableForNewWork }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    private var selectedBillingItem: Item? {
        guard let selectedBillingCatalogItemID else { return nil }
        return selectableBillingItems.first { $0.id == selectedBillingCatalogItemID }
    }
    private var parsedPricePerVisit: Double? { parseMoney(pricePerVisit) }
    private var parsedDiscount: Double? {
        let value = parseMoney(memberDiscountPercent)
        guard let value else { return nil }
        return min(value, 100)
    }

    private var hasSignature: Bool {
        !signatureStrokes.flatMap { $0 }.isEmpty
    }

    private func coveredEquipmentBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { coveredEquipmentIDs.contains(id) },
            set: { selected in
                if selected {
                    coveredEquipmentIDs.insert(id)
                } else {
                    coveredEquipmentIDs.remove(id)
                }
            }
        )
    }

    private func validateTerms() -> Bool {
        guard !normalizedSchedulePattern.isEmpty else {
            validationMessage = "Enter how often maintenance visits occur."
            return false
        }
        for (label, text) in [
            ("Agreement price", agreementPrice),
            ("Member visit price", pricePerVisit),
            ("Member discount", memberDiscountPercent)
        ] where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && parseMoney(text) == nil {
            validationMessage = "\(label) must be zero or a positive number."
            return false
        }
        if let discount = parseMoney(memberDiscountPercent), discount > 100 {
            validationMessage = "Member discount cannot exceed 100%."
            return false
        }
        if parsedAgreementPrice.map({ $0 > 0.009 }) == true,
           selectedBillingItem == nil {
            validationMessage = "Select an administrator-approved billing item for this paid agreement."
            return false
        }
        if includesTerm && termEndsOn < nextDate {
            validationMessage = "The agreement term cannot end before the first visit."
            return false
        }
        return true
    }

    private func saveDraft() {
        guard validateTerms() else { return }
        onSubmit(makeSubmission(approval: nil))
        dismiss()
    }

    private func activateAgreement() {
        guard validateTerms() else {
            step = .terms
            return
        }
        let normalizedName = approvalName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            validationMessage = "Enter the approving customer's name."
            return
        }
        guard customerConfirmed else {
            validationMessage = "Confirm that the customer reviewed and accepted the agreement."
            return
        }
        let signature = SignatureRenderer.image(from: signatureStrokes)?.pngData()?.base64EncodedString()
        if approvalMethod.requiresSignature && signature == nil {
            validationMessage = "Capture the customer's signature before activating the agreement."
            return
        }
        let reference = approvalReference.maintenanceAgreementNilIfBlank
        if !approvalMethod.requiresSignature && reference == nil {
            validationMessage = "Enter the approval reference before activating the agreement."
            return
        }

        onSubmit(
            makeSubmission(
                approval: MaintenanceAgreementApprovalSubmission(
                    customerName: normalizedName,
                    method: approvalMethod,
                    reference: reference,
                    signatureImageBase64: signature
                )
            )
        )
        dismiss()
    }

    private func makeSubmission(approval: MaintenanceAgreementApprovalSubmission?) -> MaintenanceAgreementOfferSubmission {
        MaintenanceAgreementOfferSubmission(
            planName: normalizedPlanName,
            schedulePattern: normalizedSchedulePattern,
            nextDate: nextDate,
            termEndsOn: includesTerm ? termEndsOn : nil,
            agreementPrice: parsedAgreementPrice,
            billingInterval: billingInterval,
            billingCatalogItemID: parsedAgreementPrice.map { $0 > 0.009 } == true
                ? selectedBillingCatalogItemID
                : nil,
            billingAnchorDate: parsedAgreementPrice.map { $0 > 0.009 } == true && billingInterval != .perVisit
                ? Calendar.current.startOfDay(for: firstBillingDate)
                : nil,
            pricePerVisit: parsedPricePerVisit,
            memberDiscountPercent: parsedDiscount,
            includedVisitsPerTerm: includedVisitsPerTerm,
            autoRenews: includesTerm && autoRenews,
            termsSummary: termsSummary.maintenanceAgreementNilIfBlank,
            coveredEquipmentIDs: coveredEquipmentIDs,
            approval: approval
        )
    }

    private func parseMoney(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")
        guard let value = Double(normalized), value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func decimalText(_ value: Double?) -> String {
        guard let value else { return "" }
        return value.formatted(.number.precision(.fractionLength(0...2)))
    }

    private func billingItemLabel(_ item: Item) -> String {
        "\(item.name) • \(item.unitPrice.formatted(.currency(code: "USD")))"
    }
}

struct MaintenanceAgreementApprovalSheet: View {
    @Environment(\.dismiss) private var dismiss

    let agreement: RecurringMaintenanceContract
    let onApprove: (MaintenanceAgreementApprovalSubmission) -> Void

    @State private var approvalName: String
    @State private var approvalMethod: EstimateApprovalMethod = .inPersonSignature
    @State private var approvalReference = ""
    @State private var signatureStrokes: [[CGPoint]] = []
    @State private var customerConfirmed = false
    @State private var validationMessage: String?

    init(
        agreement: RecurringMaintenanceContract,
        onApprove: @escaping (MaintenanceAgreementApprovalSubmission) -> Void
    ) {
        self.agreement = agreement
        self.onApprove = onApprove
        _approvalName = State(initialValue: agreement.customer.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Agreement Review") {
                    LabeledContent("Customer", value: agreement.customer.name)
                    LabeledContent("Plan", value: agreement.displayName)
                    LabeledContent("Visits", value: "\(agreement.includedVisitsPerTerm ?? 0) • \(agreement.schedulePattern)")
                    if let price = agreement.agreementPrice {
                        LabeledContent("Price", value: price.formatted(.currency(code: "USD")) + " • " + agreement.billingInterval.displayName)
                    }
                    if let termEndsOn = agreement.termEndsOn {
                        LabeledContent("Term ends", value: termEndsOn.formatted(date: .abbreviated, time: .omitted))
                    }
                }

                Section("Approval Evidence") {
                    TextField("Approving customer name", text: $approvalName)
                    Picker("Approval method", selection: $approvalMethod) {
                        ForEach(EstimateApprovalMethod.allCases) { method in
                            Text(method.displayName).tag(method)
                        }
                    }
                    if approvalMethod.requiresSignature {
                        SignaturePad(strokes: $signatureStrokes)
                            .frame(height: 180)
                        HStack {
                            Text(hasSignature ? "Signature captured." : "Customer signature required.")
                                .font(.caption)
                                .foregroundStyle(hasSignature ? .green : .secondary)
                            Spacer()
                            Button("Clear") { signatureStrokes = [] }
                                .font(.caption)
                        }
                    } else {
                        TextField(approvalMethod.referencePrompt, text: $approvalReference, axis: .vertical)
                            .lineLimit(2...4)
                    }
                    Toggle("Customer reviewed and accepted these agreement terms", isOn: $customerConfirmed)
                }

                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    Button("Activate Agreement") { approve() }
                        .frame(maxWidth: .infinity)
                        .buttonStyle(.borderedProminent)
                        .tint(Color.brandGold)
                        .foregroundStyle(Color.primaryBlack)
                }
            }
            .navigationTitle("Record Customer Approval")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .frame(minWidth: 540, minHeight: 610)
    }

    private var hasSignature: Bool {
        !signatureStrokes.flatMap { $0 }.isEmpty
    }

    private func approve() {
        let name = approvalName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            validationMessage = "Enter the approving customer's name."
            return
        }
        guard customerConfirmed else {
            validationMessage = "Confirm that the customer reviewed and accepted the agreement."
            return
        }
        let signature = SignatureRenderer.image(from: signatureStrokes)?.pngData()?.base64EncodedString()
        if approvalMethod.requiresSignature && signature == nil {
            validationMessage = "Capture the customer's signature before activating the agreement."
            return
        }
        let reference = approvalReference.maintenanceAgreementNilIfBlank
        if !approvalMethod.requiresSignature && reference == nil {
            validationMessage = "Enter the approval reference before activating the agreement."
            return
        }
        onApprove(
            MaintenanceAgreementApprovalSubmission(
                customerName: name,
                method: approvalMethod,
                reference: reference,
                signatureImageBase64: signature
            )
        )
        dismiss()
    }
}

private extension String {
    var maintenanceAgreementNilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
