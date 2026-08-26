import Foundation
import SwiftData

@MainActor
enum QuickBooksLocalSync {
    static func importSnapshot(
        customers: [QuickBooksCustomer],
        items: [QuickBooksItem],
        estimates: [QuickBooksEstimate],
        invoices: [QuickBooksInvoice],
        payments: [QuickBooksPayment],
        vendors: [QuickBooksVendor],
        into modelContext: ModelContext
    ) throws {
        let existingCustomers = try modelContext.fetch(FetchDescriptor<Customer>())
        let existingItems = try modelContext.fetch(FetchDescriptor<Item>())
        let existingEstimates = try modelContext.fetch(FetchDescriptor<Estimate>())
        let existingInvoices = try modelContext.fetch(FetchDescriptor<Invoice>())
        let existingPayments = try modelContext.fetch(FetchDescriptor<Payment>())
        let existingVendors = try modelContext.fetch(FetchDescriptor<Vendor>())
        let existingServiceCalls = try modelContext.fetch(FetchDescriptor<ServiceCall>())
        let existingAttachments = try modelContext.fetch(FetchDescriptor<ServiceDocumentAttachment>())

        var customersByQBID: [String: Customer] = [:]
        var customersByName: [String: Customer] = [:]
        for customer in existingCustomers {
            if let quickBooksID = customer.quickBooksID?.nilIfEmpty {
                customersByQBID[quickBooksID] = customersByQBID[quickBooksID] ?? customer
            }
            let nameKey = normalized(customer.name)
            if !nameKey.isEmpty {
                customersByName[nameKey] = customersByName[nameKey] ?? customer
            }
        }

        var itemsByQBID: [String: Item] = [:]
        var itemsByName: [String: Item] = [:]
        for item in existingItems {
            if let quickBooksID = item.quickBooksID?.nilIfEmpty {
                itemsByQBID[quickBooksID] = itemsByQBID[quickBooksID] ?? item
            }
            let nameKey = normalized(item.name)
            if !nameKey.isEmpty {
                itemsByName[nameKey] = itemsByName[nameKey] ?? item
            }
        }

        var vendorsByQBID: [String: Vendor] = [:]
        var vendorsByName: [String: Vendor] = [:]
        for vendor in existingVendors {
            if let quickBooksID = vendor.quickBooksID?.nilIfEmpty {
                vendorsByQBID[quickBooksID] = vendorsByQBID[quickBooksID] ?? vendor
            }
            let nameKey = normalized(vendor.name)
            if !nameKey.isEmpty {
                vendorsByName[nameKey] = vendorsByName[nameKey] ?? vendor
            }
        }

        var invoicesByQBID: [String: Invoice] = [:]
        for invoice in existingInvoices {
            guard let quickBooksID = invoice.quickBooksID?.nilIfEmpty else { continue }
            if let existing = invoicesByQBID[quickBooksID], existing !== invoice {
                mergeInvoice(existing, withDuplicate: invoice, payments: existingPayments, serviceCalls: existingServiceCalls, attachments: existingAttachments, modelContext: modelContext)
            } else {
                invoicesByQBID[quickBooksID] = invoice
            }
        }
        var estimatesByQBID: [String: Estimate] = [:]
        for estimate in existingEstimates {
            guard let quickBooksID = estimate.quickBooksID?.nilIfEmpty else { continue }
            if let existing = estimatesByQBID[quickBooksID], existing !== estimate {
                mergeEstimate(existing, withDuplicate: estimate, serviceCalls: existingServiceCalls, modelContext: modelContext)
            } else {
                estimatesByQBID[quickBooksID] = estimate
            }
        }
        var paymentsByQBID: [String: Payment] = [:]
        for payment in existingPayments {
            guard let quickBooksID = payment.quickBooksID?.nilIfEmpty else { continue }
            paymentsByQBID[quickBooksID] = paymentsByQBID[quickBooksID] ?? payment
        }
        let importedPaymentTotalsByInvoiceID = paymentTotalsByInvoiceID(from: payments)

        for quickBooksCustomer in customers {
            let customer = customersByQBID[quickBooksCustomer.Id]
                ?? customersByName[normalized(quickBooksCustomer.DisplayName)]
                ?? Customer(name: quickBooksCustomer.DisplayName)
            if customer.modelContext == nil {
                modelContext.insert(customer)
            }
            customer.quickBooksID = quickBooksCustomer.Id
            customer.name = quickBooksCustomer.DisplayName
            customer.email = quickBooksCustomer.PrimaryEmailAddr?.Address
            customer.phone = quickBooksCustomer.PrimaryPhone?.FreeFormNumber
            customer.address = quickBooksCustomer.BillAddr?.Line1
            customersByQBID[quickBooksCustomer.Id] = customer
            customersByName[normalized(customer.name)] = customer
        }

        for quickBooksItem in items {
            let item = itemsByQBID[quickBooksItem.Id]
                ?? itemsByName[normalized(quickBooksItem.Name)]
                ?? Item(name: quickBooksItem.Name, unitPrice: quickBooksItem.UnitPrice ?? 0)
            if item.modelContext == nil {
                modelContext.insert(item)
            }
            item.quickBooksID = quickBooksItem.Id
            item.name = quickBooksItem.Name
            item.itemTypeRawValue = quickBooksItem.ItemType ?? item.itemTypeRawValue
            item.unitPrice = quickBooksItem.UnitPrice ?? item.unitPrice
            item.purchaseCost = quickBooksItem.PurchaseCost ?? item.purchaseCost
            item.isTaxable = quickBooksItem.Taxable ?? item.isTaxable
            item.itemDescription = quickBooksItem.Description
            item.sku = quickBooksItem.Sku ?? item.sku
            item.purchaseDescription = quickBooksItem.PurchaseDesc ?? item.purchaseDescription
            item.preferredVendorName = quickBooksItem.PrefVendorRef?.name ?? item.preferredVendorName
            item.preferredVendorQuickBooksID = quickBooksItem.PrefVendorRef?.value ?? item.preferredVendorQuickBooksID
            itemsByQBID[quickBooksItem.Id] = item
            itemsByName[normalized(item.name)] = item
        }

        for quickBooksVendor in vendors {
            let vendor = vendorsByQBID[quickBooksVendor.Id]
                ?? vendorsByName[normalized(quickBooksVendor.DisplayName)]
                ?? Vendor(name: quickBooksVendor.DisplayName)
            if vendor.modelContext == nil {
                modelContext.insert(vendor)
            }
            vendor.quickBooksID = quickBooksVendor.Id
            vendor.name = quickBooksVendor.DisplayName
            vendor.contactInfo = [quickBooksVendor.PrimaryEmailAddr?.Address, quickBooksVendor.PrimaryPhone?.FreeFormNumber]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " • ")
                .nilIfEmpty
            vendorsByQBID[quickBooksVendor.Id] = vendor
            vendorsByName[normalized(vendor.name)] = vendor
        }

        for quickBooksEstimate in estimates {
            let customer = resolveCustomer(ref: quickBooksEstimate.CustomerRef, cacheByQBID: &customersByQBID, cacheByName: &customersByName, modelContext: modelContext)
            let estimate = estimatesByQBID[quickBooksEstimate.Id]
                ?? matchingUnlinkedEstimate(for: quickBooksEstimate, customer: customer, in: existingEstimates)
                ?? Estimate(customer: customer)
            if estimate.modelContext == nil {
                modelContext.insert(estimate)
            }
            estimate.quickBooksID = quickBooksEstimate.Id
            estimate.customer = customer
            estimate.amount = quickBooksEstimate.TotalAmt
            estimate.lineItemSummary = quickBooksEstimate.DocNumber ?? "QuickBooks Estimate"
            estimate.notes = quickBooksEstimate.DocNumber
            estimate.status = "pending"
            estimate.createdAt = parseQuickBooksDate(quickBooksEstimate.TxnDate) ?? estimate.createdAt
            if estimate.serviceCallID == nil,
               let serviceCall = matchingServiceCall(
                   for: quickBooksEstimate,
                   importedEstimate: estimate,
                   customer: customer,
                   serviceCalls: existingServiceCalls,
                   estimates: existingEstimates
               ) {
                estimate.serviceCallID = serviceCall.id
                if serviceCall.linkedEstimateID == nil {
                    serviceCall.linkedEstimateID = estimate.id
                }
            }
            estimatesByQBID[quickBooksEstimate.Id] = estimate
            for duplicate in existingEstimates where duplicate !== estimate && isDuplicateEstimate(duplicate, of: quickBooksEstimate, customer: customer) {
                mergeEstimate(estimate, withDuplicate: duplicate, serviceCalls: existingServiceCalls, modelContext: modelContext)
            }
        }

        var refreshedInvoiceQuickBooksIDs: Set<String> = []
        for quickBooksInvoice in invoices {
            let customer = resolveCustomer(ref: quickBooksInvoice.CustomerRef, cacheByQBID: &customersByQBID, cacheByName: &customersByName, modelContext: modelContext)
            let invoice = invoicesByQBID[quickBooksInvoice.Id]
                ?? matchingUnlinkedInvoice(for: quickBooksInvoice, customer: customer, in: existingInvoices)
                ?? Invoice(customer: customer)
            if invoice.modelContext == nil {
                modelContext.insert(invoice)
            }
            invoice.quickBooksID = quickBooksInvoice.Id
            invoice.quickBooksSyncStatus = "synced"
            invoice.quickBooksSyncDetail = nil
            invoice.quickBooksLastSyncedAt = Date()
            invoice.customer = customer
            invoice.amount = quickBooksInvoice.TotalAmt
            invoice.lineItemSummary = quickBooksInvoice.DocNumber ?? "QuickBooks Invoice"
            invoice.notes = quickBooksInvoice.PrivateNote
            invoice.createdAt = parseQuickBooksDate(quickBooksInvoice.TxnDate) ?? invoice.createdAt
            let balance = quickBooksInvoice.Balance
                ?? max(quickBooksInvoice.TotalAmt - (importedPaymentTotalsByInvoiceID[quickBooksInvoice.Id] ?? 0), 0)
            invoice.quickBooksBalanceDue = balance
            if balance <= 0.009 {
                invoice.status = "paid"
            } else if balance < quickBooksInvoice.TotalAmt - 0.009 {
                invoice.status = "partial"
            } else {
                invoice.status = "unpaid"
            }
            if invoice.serviceCallID == nil,
               let serviceCall = matchingServiceCall(
                   for: quickBooksInvoice,
                   importedInvoice: invoice,
                   customer: customer,
                   serviceCalls: existingServiceCalls,
                   estimates: existingEstimates,
                   invoices: existingInvoices
               ) {
                invoice.serviceCallID = serviceCall.id
                if serviceCall.linkedInvoiceID == nil {
                    serviceCall.linkedInvoiceID = invoice.id
                }
                if serviceCall.status != .cancelled {
                    serviceCall.status = .invoiced
                }
            }
            invoicesByQBID[quickBooksInvoice.Id] = invoice
            refreshedInvoiceQuickBooksIDs.insert(quickBooksInvoice.Id)
            for duplicate in existingInvoices where duplicate !== invoice && isDuplicateInvoice(duplicate, of: quickBooksInvoice, customer: customer) {
                mergeInvoice(invoice, withDuplicate: duplicate, payments: existingPayments, serviceCalls: existingServiceCalls, attachments: existingAttachments, modelContext: modelContext)
            }
        }

        var invoicesAffectedByImportedPayments: [UUID: Invoice] = [:]
        for quickBooksPayment in payments {
            let linkedTransactions = quickBooksPayment.Line?
                .flatMap { $0.LinkedTxn ?? [] } ?? []
            guard let linkedInvoiceID = linkedTransactions
                .first(where: { $0.TxnType.caseInsensitiveCompare("Invoice") == .orderedSame })?.TxnId,
                  let invoice = invoicesByQBID[linkedInvoiceID] else {
                continue
            }
            let existingPayment = paymentsByQBID[quickBooksPayment.Id]
            let payment = existingPayment
                ?? Payment(
                    invoice: invoice,
                    amount: quickBooksPayment.TotalAmt,
                    method: defaultImportedPaymentMethod(for: quickBooksPayment)
                )
            if payment.modelContext == nil {
                modelContext.insert(payment)
            }
            payment.quickBooksID = quickBooksPayment.Id
            payment.invoice = invoice
            payment.amount = quickBooksPayment.TotalAmt
            payment.method = resolvedImportedPaymentMethod(existing: payment, quickBooksPayment: quickBooksPayment)
            payment.date = parseQuickBooksDate(quickBooksPayment.TxnDate) ?? payment.date
            if payment.notes?.nilIfEmpty == nil {
                payment.notes = quickBooksPayment.PrivateNote
            }
            if payment.authorizationReference?.nilIfEmpty == nil {
                payment.authorizationReference = quickBooksPayment.PaymentRefNum
            }
            if let processor = resolvedImportedProcessor(existing: payment) {
                payment.processor = processor
            }
            paymentsByQBID[quickBooksPayment.Id] = payment
            invoicesAffectedByImportedPayments[invoice.id] = invoice
        }

        for invoice in invoicesAffectedByImportedPayments.values {
            guard let quickBooksID = invoice.quickBooksID?.nilIfEmpty,
                  !refreshedInvoiceQuickBooksIDs.contains(quickBooksID) else {
                continue
            }
            let invoicePayments = paymentsByQBID.values.filter { $0.invoice.id == invoice.id }
            invoice.quickBooksBalanceDue = localOutstandingBalance(for: invoice, payments: invoicePayments)
            invoice.status = Invoice.resolvedStatus(for: invoice, payments: invoicePayments)
        }

        let reconciledEstimates = try modelContext.fetch(FetchDescriptor<Estimate>())
        let reconciledInvoices = try modelContext.fetch(FetchDescriptor<Invoice>())
        let reconciledServiceCalls = try modelContext.fetch(FetchDescriptor<ServiceCall>())
        let reconciledAttachments = try modelContext.fetch(FetchDescriptor<ServiceDocumentAttachment>())
        reconcileBillingServiceCallLinks(
            estimates: reconciledEstimates,
            invoices: reconciledInvoices,
            serviceCalls: reconciledServiceCalls
        )
        QuickBooksInvoiceAttachmentSync.linkServiceCallAttachmentsToBillingDocuments(
            estimates: reconciledEstimates,
            invoices: reconciledInvoices,
            serviceCalls: reconciledServiceCalls,
            attachments: reconciledAttachments
        )
        try? modelContext.save()
        let syncedEstimates = try modelContext.fetch(FetchDescriptor<Estimate>())
        let syncedInvoices = try modelContext.fetch(FetchDescriptor<Invoice>())
        let syncedServiceCalls = try modelContext.fetch(FetchDescriptor<ServiceCall>())
        let serviceAttachments = try modelContext.fetch(FetchDescriptor<ServiceDocumentAttachment>())
        QuickBooksInvoiceAttachmentSync.syncPendingServiceReports(
            estimates: syncedEstimates,
            invoices: syncedInvoices,
            serviceCalls: syncedServiceCalls,
            attachments: serviceAttachments,
            modelContext: modelContext
        )
    }

    private static func resolveCustomer(
        ref: QuickBooksReference,
        cacheByQBID: inout [String: Customer],
        cacheByName: inout [String: Customer],
        modelContext: ModelContext
    ) -> Customer {
        if let existing = cacheByQBID[ref.value], !ref.value.isEmpty {
            return existing
        }
        if let name = ref.name, let existing = cacheByName[normalized(name)] {
            if existing.quickBooksID == nil, !ref.value.isEmpty {
                existing.quickBooksID = ref.value
                cacheByQBID[ref.value] = existing
            }
            return existing
        }
        let customer = Customer(
            quickBooksID: ref.value.isEmpty ? nil : ref.value,
            name: ref.displayName
        )
        modelContext.insert(customer)
        if !ref.value.isEmpty {
            cacheByQBID[ref.value] = customer
        }
        cacheByName[normalized(customer.name)] = customer
        return customer
    }

    private static func matchingUnlinkedEstimate(
        for quickBooksEstimate: QuickBooksEstimate,
        customer: Customer,
        in estimates: [Estimate]
    ) -> Estimate? {
        estimates.first { estimate in
            estimate.quickBooksID?.nilIfEmpty == nil &&
            isDuplicateEstimate(estimate, of: quickBooksEstimate, customer: customer)
        }
    }

    private static func matchingUnlinkedInvoice(
        for quickBooksInvoice: QuickBooksInvoice,
        customer: Customer,
        in invoices: [Invoice]
    ) -> Invoice? {
        invoices.first { invoice in
            invoice.quickBooksID?.nilIfEmpty == nil &&
            isDuplicateInvoice(invoice, of: quickBooksInvoice, customer: customer)
        }
    }

    private static func isDuplicateEstimate(_ estimate: Estimate, of quickBooksEstimate: QuickBooksEstimate, customer: Customer) -> Bool {
        guard estimate.quickBooksID?.nilIfEmpty == nil || estimate.quickBooksID == quickBooksEstimate.Id || estimate.quickBooksID == quickBooksEstimate.DocNumber else {
            return false
        }
        return sameCustomer(estimate.customer, customer) &&
            amountsMatch(estimate.amount, quickBooksEstimate.TotalAmt) &&
            documentReferenceMatches(localSummary: estimate.lineItemSummary, localNotes: estimate.notes, quickBooksDocumentNumber: quickBooksEstimate.DocNumber, localDate: estimate.createdAt, quickBooksDate: quickBooksEstimate.TxnDate)
    }

    private static func isDuplicateInvoice(_ invoice: Invoice, of quickBooksInvoice: QuickBooksInvoice, customer: Customer) -> Bool {
        guard invoice.quickBooksID?.nilIfEmpty == nil || invoice.quickBooksID == quickBooksInvoice.Id || invoice.quickBooksID == quickBooksInvoice.DocNumber else {
            return false
        }
        return sameCustomer(invoice.customer, customer) &&
            amountsMatch(invoice.amount, quickBooksInvoice.TotalAmt) &&
            documentReferenceMatches(localSummary: invoice.lineItemSummary, localNotes: invoice.notes, quickBooksDocumentNumber: quickBooksInvoice.DocNumber, localDate: invoice.createdAt, quickBooksDate: quickBooksInvoice.TxnDate)
    }

    private static func matchingServiceCall(
        for quickBooksInvoice: QuickBooksInvoice,
        importedInvoice: Invoice,
        customer: Customer,
        serviceCalls: [ServiceCall],
        estimates: [Estimate],
        invoices: [Invoice]
    ) -> ServiceCall? {
        guard let invoiceDate = parseQuickBooksDate(quickBooksInvoice.TxnDate) else { return nil }
        let eligibleCalls = serviceCalls.filter { call in
            sameCustomer(call.customer, customer) &&
                (call.linkedInvoiceID == nil || call.linkedInvoiceID == importedInvoice.id) &&
                abs(call.scheduledDate.timeIntervalSince(invoiceDate)) <= 3 * 24 * 60 * 60
        }
        let scored = eligibleCalls.compactMap { call -> (call: ServiceCall, score: Int)? in
            var score = 0
            if Calendar.current.isDate(call.scheduledDate, inSameDayAs: invoiceDate) {
                score += 3
            } else {
                score += 1
            }
            if let linkedEstimateID = call.linkedEstimateID,
               let estimate = estimates.first(where: { $0.id == linkedEstimateID }),
               amountsMatch(estimate.amount, quickBooksInvoice.TotalAmt) {
                score += 3
            }
            if invoices.contains(where: { invoice in
                invoice.serviceCallID == call.id && amountsMatch(invoice.amount, quickBooksInvoice.TotalAmt)
            }) {
                score += 2
            }
            if call.linkedInvoiceID == nil {
                score += 1
            }
            return score >= 4 ? (call, score) : nil
        }
        let ranked = scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let lhsDistance = abs(lhs.call.scheduledDate.timeIntervalSince(invoiceDate))
            let rhsDistance = abs(rhs.call.scheduledDate.timeIntervalSince(invoiceDate))
            return lhsDistance < rhsDistance
        }
        guard let best = ranked.first else { return nil }
        if ranked.dropFirst().first?.score == best.score {
            return nil
        }
        return best.call
    }

    private static func matchingServiceCall(
        for quickBooksEstimate: QuickBooksEstimate,
        importedEstimate: Estimate,
        customer: Customer,
        serviceCalls: [ServiceCall],
        estimates: [Estimate]
    ) -> ServiceCall? {
        guard let estimateDate = parseQuickBooksDate(quickBooksEstimate.TxnDate) else { return nil }
        let eligibleCalls = serviceCalls.filter { call in
            sameCustomer(call.customer, customer) &&
                (call.linkedEstimateID == nil || call.linkedEstimateID == importedEstimate.id) &&
                abs(call.scheduledDate.timeIntervalSince(estimateDate)) <= 3 * 24 * 60 * 60
        }
        let scored = eligibleCalls.compactMap { call -> (call: ServiceCall, score: Int)? in
            var score = 0
            if Calendar.current.isDate(call.scheduledDate, inSameDayAs: estimateDate) {
                score += 3
            } else {
                score += 1
            }
            if estimates.contains(where: { estimate in
                estimate.serviceCallID == call.id && amountsMatch(estimate.amount, quickBooksEstimate.TotalAmt)
            }) {
                score += 2
            }
            if call.linkedEstimateID == nil {
                score += 1
            }
            return score >= 4 ? (call, score) : nil
        }
        let ranked = scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let lhsDistance = abs(lhs.call.scheduledDate.timeIntervalSince(estimateDate))
            let rhsDistance = abs(rhs.call.scheduledDate.timeIntervalSince(estimateDate))
            return lhsDistance < rhsDistance
        }
        guard let best = ranked.first else { return nil }
        if ranked.dropFirst().first?.score == best.score {
            return nil
        }
        return best.call
    }

    private static func mergeEstimate(_ estimate: Estimate, withDuplicate duplicate: Estimate, serviceCalls: [ServiceCall], modelContext: ModelContext) {
        if estimate.serviceCallID == nil {
            estimate.serviceCallID = duplicate.serviceCallID
        }
        if estimate.notes?.nilIfEmpty == nil {
            estimate.notes = duplicate.notes
        }
        if estimate.lineItemSummary.nilIfEmpty == nil {
            estimate.lineItemSummary = duplicate.lineItemSummary
        }
        for call in serviceCalls where call.linkedEstimateID == duplicate.id {
            call.linkedEstimateID = estimate.id
        }
        modelContext.delete(duplicate)
    }

    private static func mergeInvoice(
        _ invoice: Invoice,
        withDuplicate duplicate: Invoice,
        payments: [Payment],
        serviceCalls: [ServiceCall],
        attachments: [ServiceDocumentAttachment],
        modelContext: ModelContext
    ) {
        if invoice.serviceCallID == nil {
            invoice.serviceCallID = duplicate.serviceCallID
        }
        if invoice.notes?.nilIfEmpty == nil {
            invoice.notes = duplicate.notes
        }
        if invoice.lineItemSummary.nilIfEmpty == nil {
            invoice.lineItemSummary = duplicate.lineItemSummary
        }
        if invoice.quickBooksBalanceDue == nil {
            invoice.quickBooksBalanceDue = duplicate.quickBooksBalanceDue
        }
        invoice.status = Invoice.mostResolvedStatus(invoice.status, duplicate.status)
        invoice.customerSignatureName = invoice.customerSignatureName ?? duplicate.customerSignatureName
        invoice.customerSignatureImageBase64 = invoice.customerSignatureImageBase64 ?? duplicate.customerSignatureImageBase64
        invoice.customerSignedAt = invoice.customerSignedAt ?? duplicate.customerSignedAt
        invoice.completionNotes = invoice.completionNotes ?? duplicate.completionNotes
        invoice.finalizedAt = invoice.finalizedAt ?? duplicate.finalizedAt
        for payment in payments where payment.invoice.id == duplicate.id {
            payment.invoice = invoice
        }
        for call in serviceCalls where call.linkedInvoiceID == duplicate.id {
            call.linkedInvoiceID = invoice.id
        }
        for attachment in attachments where attachment.invoiceID == duplicate.id {
            attachment.invoiceID = invoice.id
        }
        modelContext.delete(duplicate)
    }

    private static func reconcileBillingServiceCallLinks(
        estimates: [Estimate],
        invoices: [Invoice],
        serviceCalls: [ServiceCall]
    ) {
        let estimatesByID = Dictionary(estimates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let invoicesByID = Dictionary(invoices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let serviceCallsByID = Dictionary(serviceCalls.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for estimate in estimates {
            if let serviceCallID = estimate.serviceCallID,
               let call = serviceCallsByID[serviceCallID],
               sameCustomer(call.customer, estimate.customer),
               isMissingOrStaleLinkedEstimate(call.linkedEstimateID, estimatesByID: estimatesByID) {
                call.linkedEstimateID = estimate.id
            }
        }

        for invoice in invoices {
            if let serviceCallID = invoice.serviceCallID,
               let call = serviceCallsByID[serviceCallID],
               sameCustomer(call.customer, invoice.customer),
               isMissingOrStaleLinkedInvoice(call.linkedInvoiceID, invoicesByID: invoicesByID) {
                call.linkedInvoiceID = invoice.id
                if call.status != .cancelled {
                    call.status = .invoiced
                }
            }
        }

        for call in serviceCalls {
            if let linkedEstimateID = call.linkedEstimateID,
               let estimate = estimatesByID[linkedEstimateID],
               sameCustomer(call.customer, estimate.customer),
               estimate.serviceCallID == nil {
                estimate.serviceCallID = call.id
            }
            if let linkedInvoiceID = call.linkedInvoiceID,
               let invoice = invoicesByID[linkedInvoiceID],
               sameCustomer(call.customer, invoice.customer),
               invoice.serviceCallID == nil {
                invoice.serviceCallID = call.id
            }
        }
    }

    private static func isMissingOrStaleLinkedEstimate(_ estimateID: UUID?, estimatesByID: [UUID: Estimate]) -> Bool {
        guard let estimateID else { return true }
        return estimatesByID[estimateID] == nil
    }

    private static func isMissingOrStaleLinkedInvoice(_ invoiceID: UUID?, invoicesByID: [UUID: Invoice]) -> Bool {
        guard let invoiceID else { return true }
        return invoicesByID[invoiceID] == nil
    }

    private static func sameCustomer(_ lhs: Customer, _ rhs: Customer) -> Bool {
        if let lhsID = lhs.quickBooksID?.nilIfEmpty,
           let rhsID = rhs.quickBooksID?.nilIfEmpty {
            return lhsID == rhsID
        }
        return normalized(lhs.name) == normalized(rhs.name)
    }

    private static func amountsMatch(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) <= 0.01
    }

    private static func localOutstandingBalance(for invoice: Invoice, payments: [Payment]) -> Double {
        let netPaid = payments
            .filter { $0.invoice.id == invoice.id }
            .reduce(0) { partial, payment in
                partial + (payment.isRefund ? -payment.amount : payment.amount)
            }
        return max(invoice.amount - netPaid, 0)
    }

    private static func documentReferenceMatches(
        localSummary: String,
        localNotes: String?,
        quickBooksDocumentNumber: String?,
        localDate: Date,
        quickBooksDate: String?
    ) -> Bool {
        if let quickBooksDocumentNumber = quickBooksDocumentNumber?.nilIfEmpty {
            let normalizedDocumentNumber = normalized(quickBooksDocumentNumber)
            if normalized(localSummary).contains(normalizedDocumentNumber) ||
                normalized(localNotes ?? "").contains(normalizedDocumentNumber) {
                return true
            }
        }
        guard let quickBooksDate = parseQuickBooksDate(quickBooksDate) else {
            return true
        }
        return abs(localDate.timeIntervalSince(quickBooksDate)) <= 7 * 24 * 60 * 60
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func paymentTotalsByInvoiceID(from payments: [QuickBooksPayment]) -> [String: Double] {
        var totals: [String: Double] = [:]
        for payment in payments {
            for line in payment.Line ?? [] {
                let invoiceIDs = (line.LinkedTxn ?? [])
                    .filter { $0.TxnType.caseInsensitiveCompare("Invoice") == .orderedSame }
                    .map(\.TxnId)
                guard !invoiceIDs.isEmpty else { continue }
                let amount = invoiceIDs.count == 1 ? line.Amount : line.Amount / Double(invoiceIDs.count)
                for invoiceID in invoiceIDs {
                    totals[invoiceID, default: 0] += amount
                }
            }
        }
        return totals
    }

    private static func defaultImportedPaymentMethod(for quickBooksPayment: QuickBooksPayment) -> String {
        if isQuickBooksCardPayment(quickBooksPayment) {
            return "card"
        }
        if isQuickBooksACHPayment(quickBooksPayment) {
            return "ach"
        }
        return "quickbooks"
    }

    private static func resolvedImportedPaymentMethod(existing payment: Payment, quickBooksPayment: QuickBooksPayment) -> String {
        if let processor = payment.processor,
           processor == OnsitePaymentProcessor.quickBooksPayments.rawValue || payment.quickBooksChargeID?.nilIfEmpty != nil {
            return "card"
        }

        if payment.method == "card" || payment.method.hasPrefix("card ") {
            return payment.method
        }
        if payment.method == "ach" || payment.method.hasPrefix("ach ") {
            return payment.method
        }

        return defaultImportedPaymentMethod(for: quickBooksPayment)
    }

    private static func resolvedImportedProcessor(existing payment: Payment) -> String? {
        if let processor = payment.processor?.nilIfEmpty {
            return processor
        }
        if payment.quickBooksChargeID?.nilIfEmpty != nil {
            return OnsitePaymentProcessor.quickBooksPayments.rawValue
        }
        return nil
    }

    private static func isQuickBooksCardPayment(_ quickBooksPayment: QuickBooksPayment) -> Bool {
        if quickBooksPayment.CreditCardPayment != nil {
            return true
        }

        guard let methodName = quickBooksPayment.PaymentMethodRef?.name?.lowercased() else {
            return false
        }
        return methodName.contains("card") || methodName.contains("visa") || methodName.contains("mastercard") || methodName.contains("amex")
    }

    private static func isQuickBooksACHPayment(_ quickBooksPayment: QuickBooksPayment) -> Bool {
        guard let methodName = quickBooksPayment.PaymentMethodRef?.name?.lowercased() else {
            return false
        }
        return methodName.contains("ach") || methodName.contains("bank") || methodName.contains("echeck") || methodName.contains("check")
    }

    private static func parseQuickBooksDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        if let date = formatter.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }
}

private extension String {
    var nilIfEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
