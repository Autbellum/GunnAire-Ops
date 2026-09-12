// ProjectBillingViews.swift
// Compact project-billing components kept separate from the primary billing workspace.

import SwiftUI

/// Review the durable issued record, never an empty or repriced editable
/// selection. Catalog refresh/archival cannot change what was billed.
struct ProjectProgressInvoiceReview: View {
    let invoice: Invoice

    var body: some View {
        LabeledContent("Customer", value: invoice.customer?.name ?? "Customer is syncing")
        LabeledContent("Milestone", value: invoice.projectMilestoneTitle ?? "Project invoice")
        ForEach(Array(invoice.catalogLineSnapshots.enumerated()), id: \.offset) { index, line in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(line.name)
                    Spacer()
                    Text(line.extendedAmount, format: .currency(code: "USD"))
                }
                Text("Billed quantity: \(line.quantity.formatted(.number.precision(.fractionLength(0...5))))")
                    .font(.caption).foregroundStyle(.secondary)
                if let bundle = line.bundle {
                    DisclosureGroup("Included Items (\(bundle.members.count))") {
                        ForEach(Array(bundle.members.enumerated()), id: \.offset) { position, member in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(member.line.name)
                                    Spacer()
                                    Text(member.line.extendedAmount, format: .currency(code: "USD"))
                                }
                                Text("\(member.line.quantity.formatted(.number.precision(.fractionLength(0...5)))) × \(QuickBooksSalesLineContract.unitPriceLabel(member.line.unitPrice))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("ProjectMilestoneMember-\(index)-\(position)")
                        }
                    }
                    .disclosureGroupStyle(CatalogBundleDisclosureStyle())
                }
            }
        }
        if let discount = invoice.documentDiscount {
            LabeledContent("Discount", value: invoice.documentDiscountAmount.formatted(.currency(code: "USD")))
            Text(discount.reason).font(.caption).foregroundStyle(.secondary)
        }
        LabeledContent("Subtotal", value: invoice.subtotalAmount.formatted(.currency(code: "USD")))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Milestone subtotal")
            .accessibilityValue(invoice.subtotalAmount.formatted(.currency(code: "USD")))
            .accessibilityIdentifier("ProjectMilestoneSavedSubtotal")
        if invoice.salesTaxAmount > 0 {
            LabeledContent("Sales tax", value: invoice.salesTaxAmount.formatted(.currency(code: "USD")))
        }
        LabeledContent("Invoice total", value: invoice.amount.formatted(.currency(code: "USD")))
        LabeledContent("Due date", value: invoice.effectiveDueDate().formatted(date: .abbreviated, time: .omitted))
        Label("Approved milestone allocation. Items and prices are locked.", systemImage: "lock")
            .font(.caption).foregroundStyle(.secondary)
            .accessibilityIdentifier("ProjectMilestoneAllocationLocked")
        if invoice.quickBooksSyncState != "synced" {
            Text("QuickBooks publication is pending. Open Billing Review to continue.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ProjectBillingSummaryCard: View {
    let summary: ProjectBillingSummary
    let issuedMilestoneCount: Int
    let canViewFinancials: Bool
    let canIssueProgressInvoices: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Project progress", systemImage: "building.2")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(summary.billedFraction, format: .percent.precision(.fractionLength(0...1)))
                    .font(.subheadline.weight(.semibold))
            }
            ProgressView(value: summary.billedFraction)
                .tint(Color.brandGold)
            if canViewFinancials {
                Text(financialSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(issuedMilestoneCount) of \(summary.milestoneCount) billing stages issued")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if summary.readyToBillCount > 0, canIssueProgressInvoices {
                Label(readyForBillingLabel, systemImage: "doc.badge.plus")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ProjectBillingSummary")
    }

    private var financialSummary: String {
        let invoiced = summary.invoicedAmount.formatted(.currency(code: "USD"))
        let paid = summary.paidAmount.formatted(.currency(code: "USD"))
        let remaining = summary.remainingToInvoice.formatted(.currency(code: "USD"))
        return "\(invoiced) invoiced • \(paid) paid • \(remaining) remaining"
    }

    private var readyForBillingLabel: String {
        let noun = summary.readyToBillCount == 1 ? "milestone" : "milestones"
        return "\(summary.readyToBillCount) \(noun) ready for billing review"
    }
}

struct ProjectMilestoneCard: View {
    let milestone: ProjectMilestone
    let state: ProjectMilestoneDisplayState
    let scheduledVisit: ServiceCall?
    let linkedInvoice: Invoice?
    let billingEstimate: Estimate?
    let canViewFinancials: Bool
    let canSchedule: Bool
    let canComplete: Bool
    let canIssueInvoice: Bool
    let onSchedule: () -> Void
    let onComplete: () -> Void
    let onCreateInvoice: () -> Void
    let onReviewInvoice: (Invoice) -> Void
    let onOpenVisit: (ServiceCall) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            milestoneHeader
            Text("Billing trigger: \(milestone.billingTrigger.displayName)")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let completedAt = milestone.completedAt {
                Text(completionLabel(completedAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let scheduledVisit {
                scheduledVisitRow(scheduledVisit)
            }

            actionButtons
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private var milestoneHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: state.systemImage)
                .foregroundStyle(stateColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(milestone.sequence + 1). \(milestone.title)")
                    .font(.subheadline.weight(.semibold))
                Text("\(state.label) • planned \(milestone.plannedDate.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let detail = milestone.milestoneDescription, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(milestone.billingPercent.formatted(.number.precision(.fractionLength(0...2))))%")
                    .font(.caption.weight(.semibold))
                if canViewFinancials {
                    Text(milestone.plannedAmount, format: .currency(code: "USD"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func scheduledVisitRow(_ visit: ServiceCall) -> some View {
        HStack {
            Text("Visit: \(visit.scheduledDate.formatted(date: .abbreviated, time: .shortened)) • \(jobStatusLabel(visit.status))")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Open Visit") { onOpenVisit(visit) }
                .font(.caption)
                .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 8) {
            if shouldOfferScheduling {
                Button("Schedule Visit", action: onSchedule)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("ScheduleProjectMilestone-\(milestone.id.uuidString)")
            }

            if shouldOfferCompletion {
                Button("Mark Complete", action: onComplete)
                    .buttonStyle(.bordered)
                    .disabled(completionBlockedByVisit)
                    .accessibilityIdentifier("CompleteProjectMilestone-\(milestone.id.uuidString)")
            }

            if isReadyForInvoice {
                Button("Create Progress Invoice", action: onCreateInvoice)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brandGold)
                    .foregroundStyle(Color.primaryBlack)
                    .accessibilityIdentifier("CreateProgressInvoice-\(milestone.id.uuidString)")
            }

            if let linkedInvoice {
                Button("Review Invoice") { onReviewInvoice(linkedInvoice) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("ReviewProgressInvoice-\(milestone.id.uuidString)")
            }
        }
    }

    private var shouldOfferScheduling: Bool {
        milestone.billingTrigger == .milestoneCompletion
            && milestone.scheduledVisitID == nil
            && milestone.invoiceID == nil
            && canSchedule
    }

    private var shouldOfferCompletion: Bool {
        milestone.billingTrigger == .milestoneCompletion
            && milestone.completedAt == nil
            && milestone.invoiceID == nil
            && canComplete
    }

    private var completionBlockedByVisit: Bool {
        scheduledVisit.map { $0.status != .completed && $0.status != .invoiced } ?? false
    }

    private var isReadyForInvoice: Bool {
        guard canIssueInvoice, let billingEstimate else { return false }
        return ProjectBillingPolicy.canInvoice(
            milestone,
            estimate: billingEstimate,
            scheduledVisit: scheduledVisit
        )
    }

    private var stateColor: Color {
        switch state {
        case .paid: .green
        case .readyForBilling: .orange
        case .invoiced: .blue
        case .scheduled: Color.brandGold
        case .planned: .secondary
        }
    }

    private func completionLabel(_ completedAt: Date) -> String {
        let actor = milestone.completedByEmail ?? "approved staff"
        return "Completed \(completedAt.formatted(date: .abbreviated, time: .shortened)) by \(actor)"
    }

    private func jobStatusLabel(_ status: JobStatus) -> String {
        switch status {
        case .scheduled: "Scheduled"
        case .inProgress: "In progress"
        case .completed: "Completed"
        case .invoiced: "Invoiced"
        case .cancelled: "Cancelled"
        }
    }
}

struct ProjectBillingPlanSetupSheet: View {
    @Environment(\.dismiss) private var dismiss

    let contractAmount: Double
    let snapshotJSON: String?
    let onSave: ([ProjectMilestonePlanDraft]) -> Void
    @State private var drafts: [ProjectMilestonePlanDraft]

    init(
        contractAmount: Double,
        snapshotJSON: String?,
        initialDate: Date,
        onSave: @escaping ([ProjectMilestonePlanDraft]) -> Void
    ) {
        self.contractAmount = contractAmount
        self.snapshotJSON = snapshotJSON
        self.onSave = onSave
        _drafts = State(initialValue: ProjectBillingPolicy.defaultDrafts(startingAt: initialDate))
    }

    private var totalPercent: Double {
        drafts.reduce(0) { $0 + $1.billingPercent }
    }

    private var validationMessage: String? {
        do {
            try ProjectBillingPolicy.validate(drafts: drafts, contractAmount: contractAmount)
            _ = try ProjectProgressAllocation.documents(from: snapshotJSON,
                targetAmounts: ProjectBillingPolicy.allocatedAmounts(total: contractAmount, percentages: drafts.map(\.billingPercent)))
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Approved Contract") {
                    LabeledContent("Contract before tax", value: contractAmount.formatted(.currency(code: "USD")))
                    LabeledContent("Allocated", value: "\(totalPercent.formatted(.number.precision(.fractionLength(0...2))))%")
                    Text("Each stage uses the approved items and prices, including bundle components and discounts. Sales tax is calculated on each invoice.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach($drafts) { $draft in
                    Section(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Milestone" : draft.title) {
                        TextField("Milestone title", text: $draft.title)
                        TextField("Scope / completion detail", text: $draft.milestoneDescription, axis: .vertical)
                            .lineLimit(2...4)
                        TextField("Billing percent", value: $draft.billingPercent, format: .number)
                            .catalogNumericKeyboard()
                        DatePicker("Planned date", selection: $draft.plannedDate, displayedComponents: [.date])
                        Picker("Billing trigger", selection: $draft.billingTrigger) {
                            ForEach(ProjectBillingTrigger.allCases) { trigger in
                                Text(trigger.displayName).tag(trigger)
                            }
                        }
                        if drafts.count > 2 {
                            Button("Remove Milestone", role: .destructive) {
                                let milestoneID = draft.id
                                drafts.removeAll { $0.id == milestoneID }
                            }
                        }
                    }
                }

                Section {
                    Button(action: appendMilestone) {
                        Label("Add Milestone", systemImage: "plus.circle")
                    }
                    .disabled(drafts.count >= 8)

                    if let validationMessage {
                        Label(validationMessage, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Project Billing Plan")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create Plan") {
                        onSave(drafts)
                    }
                    .disabled(validationMessage != nil)
                    .accessibilityIdentifier("ConfirmProjectBillingPlan")
                }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled()
    }

    private func appendMilestone() {
        let fallback = Date().addingTimeInterval(86_400)
        let priorDate = drafts.last?.plannedDate ?? Date()
        let nextDate = Calendar.current.date(byAdding: .day, value: 1, to: priorDate) ?? fallback
        drafts.append(ProjectMilestonePlanDraft(
            title: "Additional Milestone",
            billingPercent: 0,
            plannedDate: nextDate,
            billingTrigger: .milestoneCompletion
        ))
    }
}

struct ProjectMilestoneSchedulingSheet: View {
    @Environment(\.dismiss) private var dismiss

    let milestone: ProjectMilestone
    let onSchedule: (Date, TimeInterval) -> Void
    @State private var scheduledDate: Date
    @State private var durationHours: Double = 8

    init(milestone: ProjectMilestone, onSchedule: @escaping (Date, TimeInterval) -> Void) {
        self.milestone = milestone
        self.onSchedule = onSchedule
        let earliest = Date().addingTimeInterval(15 * 60)
        _scheduledDate = State(initialValue: max(milestone.plannedDate, earliest))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Milestone") {
                    Text(milestone.title)
                        .font(.headline)
                    Text(milestone.milestoneDescription ?? "Create a crew visit for this project stage.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Crew Time") {
                    DatePicker(
                        "Start",
                        selection: $scheduledDate,
                        in: Date()...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    Stepper(value: $durationHours, in: 1...12, step: 0.5) {
                        LabeledContent("Duration", value: "\(durationHours.formatted(.number.precision(.fractionLength(0...1)))) hours")
                    }
                    Text("The visit inherits the parent project's customer, property, equipment, lead technician, and crew. Dispatch can adjust those details from the scheduled visit afterward.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Schedule Milestone")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Schedule") {
                        onSchedule(scheduledDate, durationHours * 3_600)
                        dismiss()
                    }
                    .disabled(scheduledDate <= Date())
                    .accessibilityIdentifier("ConfirmProjectMilestoneSchedule")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
