import Foundation

/// A statement is a financial projection, not the display list's heuristic
/// deduplication. Only durable invoice/payment identities can collapse records.
@MainActor
enum CustomerAccountStatementPolicy {
    static func snapshot(customer: Customer, invoices: [Invoice], payments: [Payment],
                         asOf: Date?, calendar: Calendar, now: Date) -> CustomerAccountStatementSnapshot {
        let cutoff = asOf ?? now
        let isHistorical = asOf != nil
        let statementDay = calendar.startOfDay(for: cutoff)
        var issues: [String] = []
        func review(_ message: String) {
            if !issues.contains(message) { issues.append(message) }
        }
        if isHistorical {
            // Neither mutable Invoice fields nor a latest QBO balance are an
            // as-of accounting ledger. Preserve a dated diagnostic projection,
            // but never export/email it as verified historical customer debt.
            review("Historical statements need dated invoice and accounting history. Open a previously saved statement, or obtain a dated statement from QuickBooks.")
        }
        if cutoff > now {
            review("The statement cutoff cannot be in the future.")
        }
        let eligible = invoices.filter {
            $0.customer?.id == customer.id && $0.createdAt <= cutoff
        }
        if QuickBooksBillingIdentity.hasAmbiguousMapping(eligible.map { ($0.id, $0.customer?.id, $0.quickBooksID) }) {
            review("Distinct local invoices claim the same accounting identity. Review their QuickBooks mappings before creating a statement.")
        }
        let groups = Dictionary(grouping: eligible, by: invoiceKey)
        let localIdentityGroups = Dictionary(grouping: eligible, by: \.id)
        if localIdentityGroups.values.contains(where: { Set($0.map(invoiceKey)).count > 1 }) {
            review("An invoice identity has conflicting accounting links. Reconcile those records before creating a statement.")
        }
        var entries: [CustomerAccountStatementInvoiceEntry] = []

        for key in groups.keys.sorted() {
            guard let replicas = groups[key],
                  let invoice = replicas.sorted(by: { $0.id.uuidString < $1.id.uuidString }).first else { continue }
            if replicas.contains(where: { !sameInvoice($0, invoice, historical: isHistorical) }) {
                review("Duplicate invoice records disagree. Reconcile those records before creating a statement.")
            }
            guard let invoiceCents = cents(invoice.amount, allowsZero: true) else {
                review("An invoice has an invalid amount. Review it before creating a statement.")
                continue
            }
            if !isHistorical, let message = invoice.paymentCollectionBlockedMessage {
                review(message)
            }
            let replicaIDs = Set(replicas.map(\.id))
            var uniquePayments: [Payment] = []
            var indexes: [String: Int] = [:]
            for payment in payments.filter({
                $0.invoice?.customer?.id == customer.id &&
                $0.date <= cutoff &&
                $0.invoice.map { replicaIDs.contains($0.id) } == true
            }).sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                guard cents(payment.amount, allowsZero: false) != nil else {
                    review("A payment or refund has an invalid amount. Reconcile it before creating a statement.")
                    continue
                }
                let keys = paymentKeys(payment)
                let matches = Set(keys.compactMap { indexes[$0] })
                if let index = matches.first {
                    let retained = uniquePayments[index]
                    if matches.count != 1 || !samePayment(retained, payment) {
                        review("Duplicate payment records disagree. Reconcile those records before creating a statement.")
                    }
                    for alias in keys { indexes[alias] = index }
                } else {
                    for alias in keys { indexes[alias] = uniquePayments.count }
                    uniquePayments.append(payment)
                }
            }
            var netCents: Int64 = 0
            var amountOverflow = false
            for payment in uniquePayments {
                let delta = (payment.isRefund ? -1 : 1) * (cents(payment.amount, allowsZero: false) ?? 0)
                let next = netCents.addingReportingOverflow(delta)
                if next.overflow { amountOverflow = true; break }
                netCents = next.partialValue
            }
            let difference = invoiceCents.subtractingReportingOverflow(netCents)
            guard !amountOverflow && !difference.overflow else {
                review("The recorded payment totals exceed the supported numeric range. Reconcile those records before creating a statement.")
                continue
            }
            let localBalance = max(difference.partialValue, 0)
            let qboID = normalized(invoice.quickBooksID)
            var balanceCents = localBalance
            var usesAccountingBalance = false
            if !isHistorical, qboID != nil {
                if let rawBalance = invoice.quickBooksBalanceDue,
                   let savedBalance = cents(rawBalance, allowsZero: true),
                   invoice.quickBooksLastSyncedAt.map({ $0 <= cutoff }) ?? true {
                    balanceCents = savedBalance
                    usesAccountingBalance = true
                } else {
                    review("A linked invoice needs a valid saved QuickBooks balance. Sync and review it before creating a statement.")
                }
            } else if !isHistorical && invoice.normalizedStatus == "paid" && localBalance > 0 {
                review("An invoice is marked paid without matching recorded payments. Reconcile it before creating a statement.")
            }
            if !isHistorical && ["void", "voided", "cancelled", "canceled", "deleted"].contains(invoice.normalizedStatus) {
                review("An invoice has an unresolved cancellation or void status. Reconcile it before creating a statement.")
            }
            guard balanceCents > 0 else { continue }
            let due = invoice.effectiveDueDate(calendar: calendar)
            let delta = calendar.dateComponents([.day], from: statementDay, to: due).day ?? 0
            let daysPastDue = max(-delta, 0)
            let bucket: CustomerAccountStatementAgingBucket
            switch daysPastDue {
            case 0: bucket = .current
            case 1...30: bucket = .days1To30
            case 31...60: bucket = .days31To60
            case 61...90: bucket = .days61To90
            default: bucket = .days91Plus
            }
            let dueStatus: String
            if delta < 0 { dueStatus = "Overdue by \(-delta) day\(delta == -1 ? "" : "s")" }
            else if delta == 0 { dueStatus = "Due today" }
            else { dueStatus = "Due in \(delta) day\(delta == 1 ? "" : "s")" }
            entries.append(CustomerAccountStatementInvoiceEntry(
                invoiceID: invoice.id,
                reference: String(invoice.id.uuidString.prefix(8)).uppercased(),
                quickBooksReference: qboID,
                quickBooksBalanceUpdatedAt: usesAccountingBalance ? invoice.quickBooksLastSyncedAt : nil,
                issuedAt: invoice.createdAt, dueAt: due, workType: invoice.workType,
                serviceAddress: normalized(invoice.siteAddress), invoiceTotal: Double(invoiceCents) / 100,
                balanceDue: Double(balanceCents) / 100, netRecordedPayments: Double(netCents) / 100,
                dueStatus: dueStatus, daysPastDue: daysPastDue, agingBucket: bucket,
                paymentActivity: uniquePayments.sorted {
                    $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date
                }.map {
                    CustomerAccountStatementPaymentEntry(date: $0.date, amount: $0.amount,
                        isRefund: $0.isRefund, method: $0.methodSummary,
                        isSettlementPending: $0.isProviderSettlementPending)
                },
                usesQuickBooksBalance: usesAccountingBalance
            ))
        }
        return CustomerAccountStatementSnapshot(customerID: customer.id, asOf: cutoff,
            entries: entries.sorted {
                if $0.dueAt != $1.dueAt { return $0.dueAt < $1.dueAt }
                if $0.issuedAt != $1.issuedAt { return $0.issuedAt < $1.issuedAt }
                return $0.invoiceID.uuidString < $1.invoiceID.uuidString
            }, preparedAt: now, calendar: calendar,
            isHistoricalProjection: isHistorical, reviewMessages: issues)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func invoiceKey(_ invoice: Invoice) -> String {
        // Provider IDs are opaque and case-sensitive. Never group customers by
        // name, invoices by amount/day, or different progress draws by one job.
        normalized(invoice.quickBooksID).map { "qbo:" + $0 } ?? "local:" + invoice.id.uuidString
    }

    private static func sameInvoice(_ lhs: Invoice, _ rhs: Invoice, historical: Bool) -> Bool {
        lhs.amount == rhs.amount && lhs.createdAt == rhs.createdAt && lhs.dueDate == rhs.dueDate &&
        lhs.workType == rhs.workType && lhs.siteAddress == rhs.siteAddress &&
        lhs.salesTaxAmount == rhs.salesTaxAmount &&
        lhs.taxCalculationStatusRawValue == rhs.taxCalculationStatusRawValue &&
        (historical || (lhs.quickBooksBalanceDue == rhs.quickBooksBalanceDue &&
                       lhs.normalizedStatus == rhs.normalizedStatus))
    }

    private static func paymentKeys(_ payment: Payment) -> [String] {
        var keys = ["local:" + payment.id.uuidString]
        if let id = payment.collectionAttemptID { keys.append("attempt:" + id.uuidString) }
        if payment.isRefund {
            if let id = normalized(payment.quickBooksRefundReceiptID) { keys.append("refund-receipt:" + id) }
            // A refund's charge ID can refer to the original charge. Two partial
            // refunds against that charge are not duplicate refund events.
        } else {
            if let id = normalized(payment.quickBooksID) { keys.append("accounting:" + id) }
            if let id = normalized(payment.quickBooksChargeID) { keys.append("charge:" + id) }
        }
        return keys
    }

    private static func samePayment(_ lhs: Payment, _ rhs: Payment) -> Bool {
        lhs.amount == rhs.amount && lhs.date == rhs.date && lhs.isRefund == rhs.isRefund &&
        lhs.refundedPaymentID == rhs.refundedPaymentID &&
        lhs.methodSummary == rhs.methodSummary &&
        lhs.isProviderSettlementPending == rhs.isProviderSettlementPending &&
        [ (lhs.quickBooksID, rhs.quickBooksID),
          (lhs.quickBooksChargeID, rhs.quickBooksChargeID),
          (lhs.quickBooksRefundReceiptID, rhs.quickBooksRefundReceiptID)
        ].allSatisfy { pair in
            guard let left = normalized(pair.0), let right = normalized(pair.1) else { return true }
            return left == right
        }
    }

    private static func cents(_ value: Double, allowsZero: Bool) -> Int64? {
        // A reporting amount is not a card/ACH dispatch limit. Keep cents
        // within Double's exact-integer range before converting to Int64.
        guard value.isFinite, value >= (allowsZero ? 0 : 0.01),
              value * 100 <= 9_007_199_254_740_991,
              abs(value * 100 - (value * 100).rounded()) < 0.000001 else { return nil }
        return Int64((value * 100).rounded())
    }
}
