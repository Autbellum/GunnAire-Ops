import Foundation

enum BusinessSuiteSeverity: Int, Comparable {
    case stable = 0
    case notice = 1
    case warning = 2
    case critical = 3

    static func < (lhs: BusinessSuiteSeverity, rhs: BusinessSuiteSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum BusinessSuiteDestination: Equatable {
    case commandCenter
    case schedule(UUID?)
    case documentation(UUID?)
    case collectPayment(UUID)
    case customer(UUID)
    case customers
    case payments
    case sync
    case quickBooks
    case estimates
    case invoices
    case timeClock
}

enum BusinessSuiteWorkstreamKind: String, CaseIterable {
    case dispatch
    case documentation
    case revenue
    case pricebook
    case agreements
    case fieldTeam
    case integrations
    case accounts
}

struct BusinessSuiteWorkstream: Identifiable, Equatable {
    let id: BusinessSuiteWorkstreamKind
    let title: String
    let value: String
    let status: String
    let detail: String
    let systemImage: String
    let score: Int
    let severity: BusinessSuiteSeverity
    let destination: BusinessSuiteDestination
}

struct BusinessSuiteAction: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let value: String
    let systemImage: String
    let severity: BusinessSuiteSeverity
    let destination: BusinessSuiteDestination
}

struct BusinessSuiteSnapshot: Equatable {
    let generatedAt: Date
    let healthScore: Int
    let healthLabel: String
    let healthDetail: String
    let monthInvoiceTotal: Double
    let monthPaymentTotal: Double
    let openReceivablesTotal: Double
    let estimatePipelineTotal: Double
    let averageGrossMargin: Double
    let readyToBillCount: Int
    let openWorkCount: Int
    let customerRiskCount: Int
    let syncAttentionCount: Int
    let pricebookAttentionCount: Int
    let catalogItemCount: Int
    let fieldCoverage: Double
    let workstreams: [BusinessSuiteWorkstream]
    let actions: [BusinessSuiteAction]
}

enum BusinessSuiteIntelligence {
    static func snapshot(
        customers: [Customer],
        serviceCalls: [ServiceCall],
        technicians: [Technician],
        contracts: [RecurringMaintenanceContract],
        estimates: [Estimate],
        invoices: [Invoice],
        payments: [Payment],
        timeEntries: [TimeEntry],
        items: [Item] = [],
        vendors: [Vendor] = [],
        googleConnected: Bool,
        quickBooksConnected: Bool,
        onsitePaymentsReady: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> BusinessSuiteSnapshot {
        let customerSnapshots = CustomerIntelligence.snapshots(
            customers: customers,
            serviceCalls: serviceCalls,
            invoices: invoices,
            estimates: estimates,
            payments: payments,
            contracts: contracts,
            now: now,
            calendar: calendar
        )

        let activeCalls = serviceCalls.filter { $0.status != .cancelled && $0.status != .completed }
        let startOfToday = calendar.startOfDay(for: now)
        let dispatchWindowEnd = calendar.date(byAdding: .day, value: 3, to: startOfToday) ?? now
        let sevenDaysAhead = calendar.date(byAdding: .day, value: 7, to: now) ?? now
        let overdueInvoiceCutoff = calendar.date(byAdding: .day, value: -7, to: now) ?? now

        let upcomingCalls = serviceCalls.filter {
            $0.status != .cancelled &&
            $0.scheduledDate >= now &&
            $0.scheduledDate <= sevenDaysAhead
        }
        let dispatchWindowCalls = activeCalls.filter {
            $0.scheduledDate >= startOfToday && $0.scheduledDate < dispatchWindowEnd
        }
        let unassignedUpcomingCalls = upcomingCalls.filter { $0.assignedTechnician == nil }
        let pastStartCalls = activeCalls.filter { $0.scheduledDate < now && $0.status == .scheduled }
        let missingAddressCalls = dispatchWindowCalls.filter {
            let address = ($0.siteAddress ?? $0.customer.address)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return address?.isEmpty != false
        }

        let readyToBillCalls = serviceCalls.filter(\.isReadyToCreateBillingDocument)
        let documentationInProgressCalls = serviceCalls.filter {
            $0.documentationStartedAt != nil && $0.documentationCompletedAt == nil
        }
        let invoicesAwaitingCloseout = invoices.filter {
            $0.finalizedAt == nil || CustomerIntelligence.outstandingBalance(for: $0, payments: payments) > 0
        }

        let openInvoiceBalances = invoices.compactMap { invoice -> (invoice: Invoice, balance: Double)? in
            let balance = CustomerIntelligence.outstandingBalance(for: invoice, payments: payments)
            guard balance > 0 else { return nil }
            return (invoice, balance)
        }
        let overdueInvoices = openInvoiceBalances.filter { $0.invoice.createdAt <= overdueInvoiceCutoff }
        let openReceivablesTotal = openInvoiceBalances.reduce(0) { $0 + $1.balance }

        let openEstimates = estimates.filter(isOpenEstimate)
        let estimatePipelineTotal = openEstimates.reduce(0) { $0 + $1.amount }
        let acceptedEstimateCalls = serviceCalls.filter { call in
            guard let linkedEstimateID = call.linkedEstimateID,
                  let estimate = estimates.first(where: { $0.id == linkedEstimateID }) else {
                return false
            }
            return estimate.status.caseInsensitiveCompare("accepted") == .orderedSame &&
            call.linkedInvoiceID == nil &&
            call.status != .cancelled
        }

        let activeContracts = contracts.filter(\.active)
        let maintenanceAlerts = activeContracts.filter {
            $0.isOverdue || $0.isUpcoming || $0.needsReminder
        }

        let paymentSyncAttention = payments.filter(\.needsQuickBooksAttention)
        let calendarLinkGaps = googleConnected ? dispatchWindowCalls.filter { call in
            if call.googleEventID?.isEmpty != false {
                return true
            }
            guard call.assignedTechnician != nil else { return false }
            return ServiceCalendarRouting.hasStaleAssignedCalendarRoute(
                calendarID: call.googleCalendarID,
                technician: call.assignedTechnician
            )
        }.count : 0
        let quickBooksDocumentGaps = quickBooksConnected ? quickBooksGapCount(estimates: estimates, invoices: invoices) : 0
        let catalogItems = items.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let unpricedCatalogItems = catalogItems.filter { $0.unitPrice <= 0 }
        let missingCostItems = catalogItems.filter { item in
            item.unitPrice > 0 && (item.purchaseCost == nil || (item.purchaseCost ?? 0) <= 0)
        }
        let lowMarginItems = catalogItems.filter { item in
            guard item.unitPrice > 0, let purchaseCost = item.purchaseCost, purchaseCost > 0 else { return false }
            return grossMargin(for: item) < 0.35
        }
        let unlinkedCatalogItems = quickBooksConnected ? catalogItems.filter { $0.quickBooksID?.isEmpty != false } : []
        let vendorCoverageGap = vendors.isEmpty && catalogItems.contains { ($0.purchaseCost ?? 0) > 0 }
        let pricebookAttentionCount =
            unpricedCatalogItems.count +
            missingCostItems.count +
            lowMarginItems.count +
            unlinkedCatalogItems.count +
            (vendorCoverageGap ? 1 : 0)
        let marginSamples = catalogItems.compactMap { item -> Double? in
            guard item.unitPrice > 0, let purchaseCost = item.purchaseCost, purchaseCost >= 0 else { return nil }
            return grossMargin(for: item)
        }
        let averageGrossMargin = marginSamples.isEmpty ? 0 : marginSamples.reduce(0, +) / Double(marginSamples.count)

        let openTimeEntries = timeEntries.filter(\.isOpen)
        let clockedInTechnicianCount = technicians.filter { technician in
            openTimeEntries.contains { entry in
                AppAccess.normalizedEmail(entry.userEmail) == AppAccess.normalizedEmail(technician.contactInfo)
            }
        }.count
        let fieldCoverage = technicians.isEmpty ? (upcomingCalls.isEmpty ? 1 : 0) : Double(clockedInTechnicianCount) / Double(technicians.count)

        let monthInvoiceTotal = invoices
            .filter { calendar.isDate($0.createdAt, equalTo: now, toGranularity: .month) }
            .reduce(0) { $0 + $1.amount }
        let monthPaymentTotal = payments
            .filter { calendar.isDate($0.date, equalTo: now, toGranularity: .month) }
            .reduce(0) { $0 + $1.amount }

        let accountScore = customerSnapshots.isEmpty ? 100 : average(customerSnapshots.map(\.healthScore))
        let dispatchScore = score(
            unassignedUpcomingCalls.count * 14 +
            pastStartCalls.count * 10 +
            missingAddressCalls.count * 8 +
            calendarLinkGaps * 5 +
            (googleConnected ? 0 : 8)
        )
        let documentationScore = score(
            readyToBillCalls.count * 10 +
            documentationInProgressCalls.count * 5 +
            invoicesAwaitingCloseout.count * 4 +
            acceptedEstimateCalls.count * 6
        )
        let revenueScore = score(
            overdueInvoices.count * 18 +
            Int(openReceivablesTotal / 750) * 4 +
            max(0, readyToBillCalls.count - 1) * 5 +
            (onsitePaymentsReady ? 0 : min(12, openInvoiceBalances.count * 3))
        )
        let pricebookScore = score(
            (catalogItems.isEmpty && (!customers.isEmpty || !serviceCalls.isEmpty) ? 12 : 0) +
            unpricedCatalogItems.count * 18 +
            lowMarginItems.count * 12 +
            missingCostItems.count * 6 +
            unlinkedCatalogItems.count * 4 +
            (vendorCoverageGap ? 8 : 0)
        )
        let agreementsScore = score(
            maintenanceAlerts.count * 12 +
            (activeContracts.isEmpty && !customers.isEmpty ? 6 : 0)
        )
        let fieldScore = score(
            unassignedUpcomingCalls.count * 9 +
            max(0, upcomingCalls.count - technicians.count * 4) * 4 +
            (technicians.isEmpty && !upcomingCalls.isEmpty ? 20 : 0)
        )
        let integrationScore = score(
            (googleConnected ? 0 : 18) +
            (quickBooksConnected ? 0 : 24) +
            paymentSyncAttention.count * 12 +
            calendarLinkGaps * 4 +
            quickBooksDocumentGaps * 3
        )

        let overallScore = weightedAverage([
            (accountScore, 0.16),
            (dispatchScore, 0.16),
            (documentationScore, 0.14),
            (revenueScore, 0.18),
            (pricebookScore, 0.10),
            (agreementsScore, 0.09),
            (fieldScore, 0.07),
            (integrationScore, 0.10)
        ])

        let workstreams = [
            BusinessSuiteWorkstream(
                id: .dispatch,
                title: "Dispatch",
                value: "\(dispatchWindowCalls.count)",
                status: statusLabel(for: dispatchScore),
                detail: "\(unassignedUpcomingCalls.count) unassigned, \(pastStartCalls.count) past start",
                systemImage: "location.north.line",
                score: dispatchScore,
                severity: severity(for: dispatchScore),
                destination: .schedule(unassignedUpcomingCalls.first?.id)
            ),
            BusinessSuiteWorkstream(
                id: .documentation,
                title: "Documentation",
                value: "\(readyToBillCalls.count)",
                status: statusLabel(for: documentationScore),
                detail: "\(documentationInProgressCalls.count) active, \(invoicesAwaitingCloseout.count) closeout",
                systemImage: "doc.text.viewfinder",
                score: documentationScore,
                severity: severity(for: documentationScore),
                destination: .documentation(readyToBillCalls.first?.id ?? documentationInProgressCalls.first?.id)
            ),
            BusinessSuiteWorkstream(
                id: .revenue,
                title: "Revenue",
                value: currency(openReceivablesTotal),
                status: statusLabel(for: revenueScore),
                detail: "\(overdueInvoices.count) overdue, \(openEstimates.count) estimates",
                systemImage: "chart.line.uptrend.xyaxis",
                score: revenueScore,
                severity: severity(for: revenueScore),
                destination: overdueInvoices.first.map { .collectPayment($0.invoice.id) } ?? .invoices
            ),
            BusinessSuiteWorkstream(
                id: .pricebook,
                title: "Pricebook",
                value: catalogItems.isEmpty ? "0 items" : percent(averageGrossMargin),
                status: statusLabel(for: pricebookScore),
                detail: pricebookDetail(
                    catalogItemCount: catalogItems.count,
                    unpricedCount: unpricedCatalogItems.count,
                    lowMarginCount: lowMarginItems.count,
                    missingCostCount: missingCostItems.count
                ),
                systemImage: "tag.circle",
                score: pricebookScore,
                severity: severity(for: pricebookScore),
                destination: .quickBooks
            ),
            BusinessSuiteWorkstream(
                id: .agreements,
                title: "Agreements",
                value: "\(activeContracts.count)",
                status: statusLabel(for: agreementsScore),
                detail: "\(maintenanceAlerts.count) reminders, \(contracts.count) total",
                systemImage: "repeat.circle",
                score: agreementsScore,
                severity: severity(for: agreementsScore),
                destination: maintenanceAlerts.first.map { .customer($0.customer.id) } ?? .customers
            ),
            BusinessSuiteWorkstream(
                id: .fieldTeam,
                title: "Field Team",
                value: percent(fieldCoverage),
                status: statusLabel(for: fieldScore),
                detail: "\(clockedInTechnicianCount) clocked in, \(upcomingCalls.count) this week",
                systemImage: "person.2.badge.gearshape",
                score: fieldScore,
                severity: severity(for: fieldScore),
                destination: .timeClock
            ),
            BusinessSuiteWorkstream(
                id: .integrations,
                title: "Integrations",
                value: "\(paymentSyncAttention.count + calendarLinkGaps + quickBooksDocumentGaps)",
                status: statusLabel(for: integrationScore),
                detail: "\(calendarLinkGaps) calendar, \(quickBooksDocumentGaps) QuickBooks gaps",
                systemImage: "point.3.connected.trianglepath.dotted",
                score: integrationScore,
                severity: severity(for: integrationScore),
                destination: paymentSyncAttention.isEmpty ? .sync : .payments
            ),
            BusinessSuiteWorkstream(
                id: .accounts,
                title: "Accounts",
                value: "\(customerSnapshots.filter(\.hasRisk).count)",
                status: statusLabel(for: accountScore),
                detail: "\(customers.count) customers, \(customerSnapshots.filter(\.hasOpenWork).count) active",
                systemImage: "person.crop.rectangle.stack",
                score: accountScore,
                severity: severity(for: accountScore),
                destination: customerSnapshots.first.map { .customer($0.customer.id) } ?? .commandCenter
            )
        ]

        return BusinessSuiteSnapshot(
            generatedAt: now,
            healthScore: overallScore,
            healthLabel: statusLabel(for: overallScore),
            healthDetail: healthDetail(
                score: overallScore,
                readyToBillCount: readyToBillCalls.count,
                openReceivablesTotal: openReceivablesTotal,
                syncAttentionCount: paymentSyncAttention.count + calendarLinkGaps + quickBooksDocumentGaps
            ),
            monthInvoiceTotal: monthInvoiceTotal,
            monthPaymentTotal: monthPaymentTotal,
            openReceivablesTotal: openReceivablesTotal,
            estimatePipelineTotal: estimatePipelineTotal,
            averageGrossMargin: averageGrossMargin,
            readyToBillCount: readyToBillCalls.count,
            openWorkCount: activeCalls.count,
            customerRiskCount: customerSnapshots.filter(\.hasRisk).count,
            syncAttentionCount: paymentSyncAttention.count + calendarLinkGaps + quickBooksDocumentGaps,
            pricebookAttentionCount: pricebookAttentionCount,
            catalogItemCount: catalogItems.count,
            fieldCoverage: fieldCoverage,
            workstreams: workstreams,
            actions: actions(
                customerSnapshots: customerSnapshots,
                overdueInvoices: overdueInvoices,
                openInvoiceBalances: openInvoiceBalances,
                readyToBillCalls: readyToBillCalls,
                unassignedUpcomingCalls: unassignedUpcomingCalls,
                acceptedEstimateCalls: acceptedEstimateCalls,
                maintenanceAlerts: maintenanceAlerts,
                paymentSyncAttention: paymentSyncAttention,
                unpricedCatalogItems: unpricedCatalogItems,
                lowMarginItems: lowMarginItems,
                missingCostItems: missingCostItems,
                unlinkedCatalogItems: unlinkedCatalogItems,
                vendorCoverageGap: vendorCoverageGap,
                averageGrossMargin: averageGrossMargin,
                googleConnected: googleConnected,
                quickBooksConnected: quickBooksConnected,
                calendarLinkGaps: calendarLinkGaps,
                quickBooksDocumentGaps: quickBooksDocumentGaps
            )
        )
    }

    private static func actions(
        customerSnapshots: [CustomerIntelligenceSnapshot],
        overdueInvoices: [(invoice: Invoice, balance: Double)],
        openInvoiceBalances: [(invoice: Invoice, balance: Double)],
        readyToBillCalls: [ServiceCall],
        unassignedUpcomingCalls: [ServiceCall],
        acceptedEstimateCalls: [ServiceCall],
        maintenanceAlerts: [RecurringMaintenanceContract],
        paymentSyncAttention: [Payment],
        unpricedCatalogItems: [Item],
        lowMarginItems: [Item],
        missingCostItems: [Item],
        unlinkedCatalogItems: [Item],
        vendorCoverageGap: Bool,
        averageGrossMargin: Double,
        googleConnected: Bool,
        quickBooksConnected: Bool,
        calendarLinkGaps: Int,
        quickBooksDocumentGaps: Int
    ) -> [BusinessSuiteAction] {
        var actions: [BusinessSuiteAction] = []

        if let overdue = overdueInvoices.sorted(by: { $0.balance > $1.balance }).first {
            actions.append(
                BusinessSuiteAction(
                    id: "collect-overdue-\(overdue.invoice.id.uuidString)",
                    title: "Collect overdue balance",
                    detail: overdue.invoice.customer.name,
                    value: currency(overdue.balance),
                    systemImage: "creditcard.trianglebadge.exclamationmark",
                    severity: .critical,
                    destination: .collectPayment(overdue.invoice.id)
                )
            )
        } else if let open = openInvoiceBalances.sorted(by: { $0.balance > $1.balance }).first {
            actions.append(
                BusinessSuiteAction(
                    id: "collect-open-\(open.invoice.id.uuidString)",
                    title: "Collect open balance",
                    detail: open.invoice.customer.name,
                    value: currency(open.balance),
                    systemImage: "creditcard",
                    severity: .warning,
                    destination: .collectPayment(open.invoice.id)
                )
            )
        }

        if let call = readyToBillCalls.sorted(by: { $0.scheduledDate > $1.scheduledDate }).first {
            actions.append(
                BusinessSuiteAction(
                    id: "ready-to-bill-\(call.id.uuidString)",
                    title: "Build billing document",
                    detail: "\(call.customer.name) - \(call.type.displayName)",
                    value: "Ready",
                    systemImage: "doc.badge.plus",
                    severity: .warning,
                    destination: .documentation(call.id)
                )
            )
        }

        if let call = unassignedUpcomingCalls.sorted(by: { $0.scheduledDate < $1.scheduledDate }).first {
            actions.append(
                BusinessSuiteAction(
                    id: "assign-\(call.id.uuidString)",
                    title: "Assign field technician",
                    detail: "\(call.customer.name) - \(call.scheduledDate.formatted(date: .abbreviated, time: .shortened))",
                    value: call.type.displayName,
                    systemImage: "person.crop.circle.badge.plus",
                    severity: .warning,
                    destination: .schedule(call.id)
                )
            )
        }

        if let call = acceptedEstimateCalls.sorted(by: { $0.scheduledDate < $1.scheduledDate }).first {
            actions.append(
                BusinessSuiteAction(
                    id: "accepted-estimate-\(call.id.uuidString)",
                    title: "Move approved work forward",
                    detail: call.customer.name,
                    value: "Accepted",
                    systemImage: "checkmark.seal",
                    severity: .notice,
                    destination: .schedule(call.id)
                )
            )
        }

        if let payment = paymentSyncAttention.sorted(by: { $0.date > $1.date }).first {
            actions.append(
                BusinessSuiteAction(
                    id: "payment-sync-\(payment.id.uuidString)",
                    title: "Review payment sync",
                    detail: payment.invoice.customer.name,
                    value: currency(payment.amount),
                    systemImage: "arrow.triangle.2.circlepath.circle",
                    severity: .warning,
                    destination: .payments
                )
            )
        }

        if let item = unpricedCatalogItems.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }).first {
            actions.append(
                BusinessSuiteAction(
                    id: "pricebook-unpriced-\(item.id.uuidString)",
                    title: "Set catalog price",
                    detail: item.name,
                    value: "No price",
                    systemImage: "tag.slash",
                    severity: .critical,
                    destination: .quickBooks
                )
            )
        } else if let item = lowMarginItems.sorted(by: { grossMargin(for: $0) < grossMargin(for: $1) }).first {
            actions.append(
                BusinessSuiteAction(
                    id: "pricebook-margin-\(item.id.uuidString)",
                    title: "Review low-margin item",
                    detail: item.name,
                    value: percent(grossMargin(for: item)),
                    systemImage: "chart.line.downtrend.xyaxis",
                    severity: .warning,
                    destination: .quickBooks
                )
            )
        } else if let item = missingCostItems.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }).first {
            actions.append(
                BusinessSuiteAction(
                    id: "pricebook-cost-\(item.id.uuidString)",
                    title: "Add item cost",
                    detail: item.name,
                    value: "Cost gap",
                    systemImage: "tag.circle",
                    severity: .notice,
                    destination: .quickBooks
                )
            )
        } else if let item = unlinkedCatalogItems.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }).first {
            actions.append(
                BusinessSuiteAction(
                    id: "pricebook-sync-\(item.id.uuidString)",
                    title: "Sync catalog item",
                    detail: item.name,
                    value: "QB link",
                    systemImage: "arrow.triangle.2.circlepath",
                    severity: .notice,
                    destination: .quickBooks
                )
            )
        } else if vendorCoverageGap {
            actions.append(
                BusinessSuiteAction(
                    id: "pricebook-vendor-coverage",
                    title: "Add vendor coverage",
                    detail: "Catalog has job cost data but no vendors loaded.",
                    value: percent(averageGrossMargin),
                    systemImage: "building.2.crop.circle",
                    severity: .notice,
                    destination: .quickBooks
                )
            )
        }

        if let contract = maintenanceAlerts.sorted(by: { $0.nextDate < $1.nextDate }).first {
            actions.append(
                BusinessSuiteAction(
                    id: "agreement-\(contract.id.uuidString)",
                    title: contract.isOverdue ? "Schedule overdue agreement" : "Prepare maintenance visit",
                    detail: "\(contract.customer.name) - \(contract.schedulePattern)",
                    value: contract.nextDate.formatted(date: .abbreviated, time: .omitted),
                    systemImage: "wrench.and.screwdriver",
                    severity: contract.isOverdue ? .warning : .notice,
                    destination: .customer(contract.customer.id)
                )
            )
        }

        if !googleConnected || !quickBooksConnected || calendarLinkGaps > 0 || quickBooksDocumentGaps > 0 {
            actions.append(
                BusinessSuiteAction(
                    id: "integration-readiness",
                    title: "Tighten sync coverage",
                    detail: integrationDetail(
                        googleConnected: googleConnected,
                        quickBooksConnected: quickBooksConnected,
                        calendarLinkGaps: calendarLinkGaps,
                        quickBooksDocumentGaps: quickBooksDocumentGaps
                    ),
                    value: "\(calendarLinkGaps + quickBooksDocumentGaps)",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    severity: (!googleConnected || !quickBooksConnected) ? .warning : .notice,
                    destination: .sync
                )
            )
        }

        if let account = customerSnapshots.first(where: { $0.healthScore < 70 || $0.missingContactDetailCount > 0 }) {
            actions.append(
                BusinessSuiteAction(
                    id: "account-\(account.customer.id.uuidString)",
                    title: account.healthScore < 70 ? "Stabilize account" : "Complete customer profile",
                    detail: account.customer.name,
                    value: "\(account.healthScore)",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    severity: account.healthScore < 70 ? .warning : .notice,
                    destination: .customer(account.customer.id)
                )
            )
        }

        return actions
            .sorted {
                if $0.severity != $1.severity { return $0.severity > $1.severity }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            .prefix(8)
            .map { $0 }
    }

    private static func quickBooksGapCount(estimates: [Estimate], invoices: [Invoice]) -> Int {
        estimates.filter { isOpenEstimate($0) && $0.quickBooksID?.isEmpty != false }.count +
        invoices.filter {
            CustomerIntelligence.outstandingBalance(for: $0, payments: []) > 0 && $0.quickBooksID?.isEmpty != false
        }.count
    }

    private nonisolated static func isOpenEstimate(_ estimate: Estimate) -> Bool {
        let status = estimate.status.lowercased()
        return status != "rejected" && status != "invoiced"
    }

    private static func average(_ scores: [Int]) -> Int {
        guard !scores.isEmpty else { return 100 }
        return scores.reduce(0, +) / scores.count
    }

    private static func weightedAverage(_ values: [(score: Int, weight: Double)]) -> Int {
        let totalWeight = values.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else { return 100 }
        let value = values.reduce(0) { $0 + Double($1.score) * $1.weight } / totalWeight
        return clamp(Int(value.rounded()))
    }

    private static func score(_ penalty: Int) -> Int {
        clamp(100 - min(85, penalty))
    }

    private static func clamp(_ score: Int) -> Int {
        min(100, max(0, score))
    }

    private static func severity(for score: Int) -> BusinessSuiteSeverity {
        switch score {
        case 85...100:
            return .stable
        case 70..<85:
            return .notice
        case 50..<70:
            return .warning
        default:
            return .critical
        }
    }

    private static func statusLabel(for score: Int) -> String {
        switch score {
        case 85...100:
            return "Synchronized"
        case 70..<85:
            return "Stable"
        case 50..<70:
            return "Needs Review"
        default:
            return "At Risk"
        }
    }

    private static func healthDetail(
        score: Int,
        readyToBillCount: Int,
        openReceivablesTotal: Double,
        syncAttentionCount: Int
    ) -> String {
        if score >= 85 {
            return "Operations, cash, field work, and integrations are moving together."
        }
        if openReceivablesTotal > 0 {
            return "\(currency(openReceivablesTotal)) receivables should be watched."
        }
        if readyToBillCount > 0 {
            return "\(readyToBillCount) completed job\(readyToBillCount == 1 ? "" : "s") can move to billing."
        }
        if syncAttentionCount > 0 {
            return "\(syncAttentionCount) sync item\(syncAttentionCount == 1 ? "" : "s") need review."
        }
        return "Review the highlighted workstreams to keep the suite synchronized."
    }

    private static func integrationDetail(
        googleConnected: Bool,
        quickBooksConnected: Bool,
        calendarLinkGaps: Int,
        quickBooksDocumentGaps: Int
    ) -> String {
        var details: [String] = []
        if !googleConnected { details.append("Connect Google") }
        if !quickBooksConnected { details.append("Connect QuickBooks") }
        if calendarLinkGaps > 0 { details.append("\(calendarLinkGaps) calendar gaps") }
        if quickBooksDocumentGaps > 0 { details.append("\(quickBooksDocumentGaps) QuickBooks gaps") }
        return details.isEmpty ? "All connected systems are current." : details.joined(separator: ", ")
    }

    private static func pricebookDetail(
        catalogItemCount: Int,
        unpricedCount: Int,
        lowMarginCount: Int,
        missingCostCount: Int
    ) -> String {
        if catalogItemCount == 0 {
            return "Build a sellable catalog for field proposals."
        }
        let gaps = unpricedCount + lowMarginCount + missingCostCount
        return "\(catalogItemCount) items, \(gaps) pricing gaps"
    }

    private static func grossMargin(for item: Item) -> Double {
        guard item.unitPrice > 0 else { return 0 }
        let purchaseCost = item.purchaseCost ?? 0
        return max(0, min(1, (item.unitPrice - purchaseCost) / item.unitPrice))
    }

    private static func currency(_ value: Double) -> String {
        value.formatted(.currency(code: "USD"))
    }

    private static func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }
}
