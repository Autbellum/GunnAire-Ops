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

        var customersByQBID = Dictionary(uniqueKeysWithValues: existingCustomers.compactMap { customer in
            customer.quickBooksID.map { ($0, customer) }
        })
        var customersByName = Dictionary(uniqueKeysWithValues: existingCustomers.map { (normalized($0.name), $0) })

        var itemsByQBID = Dictionary(uniqueKeysWithValues: existingItems.compactMap { item in
            item.quickBooksID.map { ($0, item) }
        })
        var itemsByName = Dictionary(uniqueKeysWithValues: existingItems.map { (normalized($0.name), $0) })

        var vendorsByQBID = Dictionary(uniqueKeysWithValues: existingVendors.compactMap { vendor in
            vendor.quickBooksID.map { ($0, vendor) }
        })
        var vendorsByName = Dictionary(uniqueKeysWithValues: existingVendors.map { (normalized($0.name), $0) })

        var invoicesByQBID = Dictionary(uniqueKeysWithValues: existingInvoices.compactMap { invoice in
            invoice.quickBooksID.map { ($0, invoice) }
        })
        var estimatesByQBID = Dictionary(uniqueKeysWithValues: existingEstimates.compactMap { estimate in
            estimate.quickBooksID.map { ($0, estimate) }
        })
        var paymentsByQBID = Dictionary(uniqueKeysWithValues: existingPayments.compactMap { payment in
            payment.quickBooksID.map { ($0, payment) }
        })

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
            item.unitPrice = quickBooksItem.UnitPrice ?? item.unitPrice
            item.itemDescription = quickBooksItem.Description
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
            estimatesByQBID[quickBooksEstimate.Id] = estimate
        }

        for quickBooksInvoice in invoices {
            let customer = resolveCustomer(ref: quickBooksInvoice.CustomerRef, cacheByQBID: &customersByQBID, cacheByName: &customersByName, modelContext: modelContext)
            let invoice = invoicesByQBID[quickBooksInvoice.Id]
                ?? Invoice(customer: customer)
            if invoice.modelContext == nil {
                modelContext.insert(invoice)
            }
            invoice.quickBooksID = quickBooksInvoice.Id
            invoice.customer = customer
            invoice.amount = quickBooksInvoice.TotalAmt
            invoice.lineItemSummary = quickBooksInvoice.DocNumber ?? "QuickBooks Invoice"
            invoice.notes = quickBooksInvoice.PrivateNote
            invoice.createdAt = parseQuickBooksDate(quickBooksInvoice.TxnDate) ?? invoice.createdAt
            let balance = quickBooksInvoice.Balance ?? quickBooksInvoice.TotalAmt
            if balance <= 0 {
                invoice.status = "paid"
            } else if balance < quickBooksInvoice.TotalAmt {
                invoice.status = "partial"
            } else {
                invoice.status = "unpaid"
            }
            invoicesByQBID[quickBooksInvoice.Id] = invoice
        }

        for quickBooksPayment in payments {
            guard let linkedInvoiceID = quickBooksPayment.Line?
                .flatMap(\.LinkedTxn)
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
        }

        try? modelContext.save()
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

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
