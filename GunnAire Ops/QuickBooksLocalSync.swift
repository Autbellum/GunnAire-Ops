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
        into modelContext: ModelContext,
        catalogHistory: QuickBooksCatalogHistoryBatch? = nil,
        saveSnapshot: (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        // The shared-history import owns one synchronous save. Never roll back
        // an unrelated editor's unsaved work, or let autosave persist half a
        // projection and its receipt after an error.
        if let catalogHistory {
            try catalogHistory.validate(records: items)
            guard !modelContext.hasChanges else {
                throw QuickBooksCatalogImportError.unsavedEdits
            }
        }
        let wasAutosaveEnabled = modelContext.autosaveEnabled
        var snapshotSaved = false
        var catalogRollbacks: [() -> Void] = []
        if catalogHistory != nil { modelContext.autosaveEnabled = false }
        defer {
            if catalogHistory != nil {
                if !snapshotSaved {
                    for restore in catalogRollbacks { restore() }
                    modelContext.processPendingChanges()
                    modelContext.rollback()
                }
                modelContext.autosaveEnabled = wasAutosaveEnabled
            }
        }
        let existingCustomers = try modelContext.fetch(FetchDescriptor<Customer>())
        let existingItems = try modelContext.fetch(FetchDescriptor<Item>())
        if catalogHistory != nil {
            catalogRollbacks = existingItems.map { QuickBooksCatalogApplicationReceipt.captureRollback($0) }
        }
        let existingEstimates = try modelContext.fetch(FetchDescriptor<Estimate>())
        let existingInvoices = try modelContext.fetch(FetchDescriptor<Invoice>())
        let existingPayments = try modelContext.fetch(FetchDescriptor<Payment>())
        let existingVendors = try modelContext.fetch(FetchDescriptor<Vendor>())
        let itemUUIDConflicts = QuickBooksBillingIdentity.conflictingKeys(existingItems) { $0.id.uuidString }
        let unlinkedItems = existingItems.filter {
            $0.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        }
        let unlinkedItemsByName = Dictionary(grouping: unlinkedItems) { normalized($0.name) }
        let unlinkedItemsBySKU = Dictionary(grouping: unlinkedItems) { normalized($0.sku ?? "") }
        let remoteInvoiceConflicts = QuickBooksBillingIdentity.conflictingKeys(invoices) { $0.Id }
        let remoteEstimateConflicts = QuickBooksBillingIdentity.conflictingKeys(estimates) { $0.Id }
        let remoteInvoiceLineageConflicts = QuickBooksBillingIdentity.conflictingKeys(invoices) {
            QuickBooksInvoiceLineage.localInvoiceID(from: $0.PrivateNote)?.uuidString
        }
        let remoteEstimateLineageConflicts = QuickBooksBillingIdentity.conflictingKeys(estimates) {
            QuickBooksEstimateLineage.localEstimateID(from: $0.PrivateNote)?.uuidString
        }
        var reviewReasons: Set<String> = []
        let customerConflicts = QuickBooksBillingIdentity.conflictingKeys(existingCustomers) {
            QuickBooksBillingIdentity.identifier($0.quickBooksID)
        }
        var customersByQBID = QuickBooksBillingIdentity.uniqueCache(existingCustomers) {
            QuickBooksBillingIdentity.identifier($0.quickBooksID)
        }

        let itemMappingConflicts = QuickBooksCatalogMappingIntegrity.conflicts(in: existingItems)
        let conflictedItemIDs = Set(itemMappingConflicts.map(\.id))
        QuickBooksCatalogMappingIntegrity.markConflictsForReview(in: existingItems)

        var itemsByQBID: [String: Item] = [:]
        for item in existingItems {
            if let quickBooksID = item.quickBooksID?.nilIfEmpty {
                let normalizedID = QuickBooksCatalogMappingIntegrity.normalizedIdentifier(quickBooksID)
                guard !conflictedItemIDs.contains(normalizedID) else { continue }
                itemsByQBID[normalizedID] = item
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

        let invoiceConflicts = QuickBooksBillingIdentity.conflictingKeys(existingInvoices) {
            QuickBooksBillingIdentity.identifier($0.quickBooksID)
        }
        let invoiceUUIDConflicts = QuickBooksBillingIdentity.conflictingKeys(existingInvoices) { $0.id.uuidString }
        let estimateConflicts = QuickBooksBillingIdentity.conflictingKeys(existingEstimates) {
            QuickBooksBillingIdentity.identifier($0.quickBooksID)
        }
        let estimateUUIDConflicts = QuickBooksBillingIdentity.conflictingKeys(existingEstimates) { $0.id.uuidString }
        let conflictedInvoices = existingInvoices.filter {
            invoiceConflicts.contains(QuickBooksBillingIdentity.identifier($0.quickBooksID) ?? "") ||
            invoiceUUIDConflicts.contains($0.id.uuidString)
        }
        QuickBooksBillingIdentity.markForReview(conflictedInvoices)
        if !conflictedInvoices.isEmpty { reviewReasons.insert("Multiple local invoice records claim one billing identity.") }
        if !estimateConflicts.isEmpty || !estimateUUIDConflicts.isEmpty {
            reviewReasons.insert("Multiple local estimate records claim one billing identity.")
        }
        var invoicesByQBID = QuickBooksBillingIdentity.uniqueCache(existingInvoices.filter {
            !invoiceUUIDConflicts.contains($0.id.uuidString)
        }) { QuickBooksBillingIdentity.identifier($0.quickBooksID) }
        var estimatesByQBID = QuickBooksBillingIdentity.uniqueCache(existingEstimates.filter {
            !estimateUUIDConflicts.contains($0.id.uuidString)
        }) { QuickBooksBillingIdentity.identifier($0.quickBooksID) }
        let keyedPayments = existingPayments.compactMap { payment -> (String, Payment)? in
            guard let paymentID = QuickBooksBillingIdentity.identifier(payment.quickBooksID),
                  let invoiceID = QuickBooksBillingIdentity.identifier(payment.invoice?.quickBooksID) else { return nil }
            return (paymentSyncKey(paymentID: paymentID, invoiceID: invoiceID), payment)
        }
        let paymentGroups = Dictionary(grouping: keyedPayments, by: { $0.0 })
        let conflictingPaymentKeys = Set(paymentGroups.filter { $0.value.count > 1 }.keys)
        var paymentsBySyncKey = paymentGroups.filter { $0.value.count == 1 }.mapValues { $0[0].1 }
        let remotePaymentConflicts = QuickBooksBillingIdentity.conflictingKeys(payments) { $0.Id }

        for quickBooksCustomer in customers {
            guard !customerConflicts.contains(quickBooksCustomer.Id) else {
                reviewReasons.insert("Multiple local customers claim one QuickBooks customer.")
                continue
            }
            let customer = customersByQBID[quickBooksCustomer.Id]
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

        }

        for quickBooksItem in items {
            let normalizedQuickBooksID = QuickBooksCatalogMappingIntegrity.normalizedIdentifier(quickBooksItem.Id)
            // Never select an arbitrary local owner or create a third record
            // when this QBO identity is already ambiguous. The conflict stays
            // local and visible until an administrator chooses the owner.
            guard !conflictedItemIDs.contains(normalizedQuickBooksID) else {
                if catalogHistory != nil {
                    reviewReasons.insert("Multiple local items claim one QuickBooks item. Administrator mapping review is required.")
                }
                continue
            }
            if let catalogHistory {
                let version = try catalogHistory.version(for: quickBooksItem)
                let linked = itemsByQBID[normalizedQuickBooksID]
                // Names and SKUs are useful review candidates, never proof of
                // identity. Do not silently link a field proposal or create a
                // duplicate beside an unresolved candidate.
                if linked == nil {
                    let skuKey = normalized(quickBooksItem.Sku ?? "")
                    let candidates = (unlinkedItemsByName[normalized(quickBooksItem.Name)] ?? []) +
                        (skuKey.isEmpty ? [] : (unlinkedItemsBySKU[skuKey] ?? []))
                    if !candidates.isEmpty {
                        for candidate in candidates {
                            candidate.quickBooksSyncDetail = "A possible QuickBooks match needs administrator review before linking. Your local item is unchanged."
                        }
                        reviewReasons.insert("Possible catalog matches need administrator review before linking.")
                        continue
                    }
                }
                let item = linked ?? Item(name: quickBooksItem.Name, unitPrice: quickBooksItem.UnitPrice ?? 0)
                guard !itemUUIDConflicts.contains(item.id.uuidString),
                      item.quickBooksID == nil || item.quickBooksID == quickBooksItem.Id else {
                    reviewReasons.insert("An item's local UUID or QuickBooks mapping is ambiguous. Local values were preserved.")
                    continue
                }
                if let reason = QuickBooksCatalogApplicationReceipt.reviewReason(for: item, incoming: version, record: quickBooksItem) {
                    item.quickBooksSyncDetail = reason
                    if !item.requiresPricebookReview && !item.hasPendingQuickBooksCatalogUpdate {
                        item.quickBooksSyncStatus = "needs_review"
                    }
                    reviewReasons.insert(reason)
                    continue
                }
                if item.modelContext == nil { modelContext.insert(item) }
                try QuickBooksCatalogApplicationReceipt.apply(quickBooksItem, version: version, to: item)
                itemsByQBID[normalizedQuickBooksID] = item
                continue
            }
            let item = itemsByQBID[normalizedQuickBooksID]
                ?? Item.matchingLocalCatalogItem(
                    in: existingItems,
                    quickBooksID: quickBooksItem.Id,
                    name: quickBooksItem.Name,
                    sku: quickBooksItem.Sku
                )
                ?? Item(name: quickBooksItem.Name, unitPrice: quickBooksItem.UnitPrice ?? 0)
            if item.modelContext == nil {
                modelContext.insert(item)
            }
            if item.requiresPricebookReview {
                // A provider match may establish the accounting identity, but
                // it is not administrator approval. Preserve every field value
                // and the original author so a background refresh cannot turn
                // a technician draft into a reusable company pricebook item.
                item.quickBooksID = quickBooksItem.Id
                item.quickBooksSyncStatus = "needs_review"
                item.quickBooksSyncDetail = "A matching QuickBooks item was found. Administrator pricebook review is still required before this draft becomes reusable."
                item.quickBooksLastSyncedAt = Date()
                itemsByQBID[normalizedQuickBooksID] = item
                continue
            }
            if item.hasPendingQuickBooksCatalogUpdate,
               !QuickBooksCatalogReconciliation.differences(
                    localItem: item,
                    remoteItem: quickBooksItem
               ).isEmpty {
                // An administrator deliberately staged these local changes.
                // Keep them intact until the QBO console shows the live diff
                // and the administrator chooses a direction.
                itemsByQBID[normalizedQuickBooksID] = item
                continue
            }
            QuickBooksCatalogSnapshotApplication.apply(quickBooksItem, to: item)
            itemsByQBID[normalizedQuickBooksID] = item
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
            guard QuickBooksBillingIdentity.identifier(quickBooksEstimate.CustomerRef.value) != nil,
                  !customerConflicts.contains(quickBooksEstimate.CustomerRef.value),
                  !estimateConflicts.contains(quickBooksEstimate.Id),
                  !remoteEstimateConflicts.contains(quickBooksEstimate.Id),
                  !remoteEstimateLineageConflicts.contains(QuickBooksEstimateLineage.localEstimateID(from: quickBooksEstimate.PrivateNote)?.uuidString ?? "") else {
                reviewReasons.insert("An estimate has an ambiguous customer or QuickBooks mapping.")
                continue
            }
            let customer = resolveCustomer(ref: quickBooksEstimate.CustomerRef, cacheByQBID: &customersByQBID, modelContext: modelContext)
            let lineageID = QuickBooksEstimateLineage.localEstimateID(from: quickBooksEstimate.PrivateNote)
            let candidates = existingEstimates.filter {
                QuickBooksBillingIdentity.identifier($0.quickBooksID) == quickBooksEstimate.Id ||
                (lineageID != nil && $0.id == lineageID)
            }
            guard candidates.count <= 1,
                  candidates.allSatisfy({
                      !estimateUUIDConflicts.contains($0.id.uuidString) &&
                      QuickBooksBillingIdentity.customerMatches($0.customer, reference: quickBooksEstimate.CustomerRef) &&
                      (QuickBooksBillingIdentity.identifier($0.quickBooksID) == nil || QuickBooksBillingIdentity.identifier($0.quickBooksID) == quickBooksEstimate.Id) &&
                      (lineageID == nil || $0.id == lineageID)
                  }) else {
                reviewReasons.insert("An estimate's customer, local UUID, or QuickBooks ID disagrees.")
                continue
            }
            let existingEstimate = candidates.first ?? estimatesByQBID[quickBooksEstimate.Id]
            let estimate = existingEstimate ?? Estimate(id: lineageID ?? UUID(), customer: customer)
            let isNewQuickBooksImport = existingEstimate == nil
            if estimate.modelContext == nil {
                modelContext.insert(estimate)
            }
            estimate.quickBooksID = quickBooksEstimate.Id
            estimate.customer = customer
            _ = estimate.applyQuickBooksTaxResult(
                total: quickBooksEstimate.TotalAmt,
                reportedTax: quickBooksEstimate.TxnTaxDetail?.TotalTax
            )
            if isNewQuickBooksImport {
                estimate.lineItemSummary = quickBooksEstimate.DocNumber ?? "QuickBooks Estimate"
                estimate.notes = quickBooksEstimate.DocNumber
                estimate.status = "pending"
                estimate.createdAt = parseQuickBooksDate(quickBooksEstimate.TxnDate) ?? estimate.createdAt
                estimate.proposalGroupID = QuickBooksEstimateLineage.proposalGroupID(from: quickBooksEstimate.PrivateNote)
                estimate.proposalOption = QuickBooksEstimateLineage.proposalOption(from: quickBooksEstimate.PrivateNote)?.rawValue
                estimate.proposalIsRecommended = QuickBooksEstimateLineage.isRecommendedOption(from: quickBooksEstimate.PrivateNote)
            }
            if estimate.siteAddress?.nilIfEmpty == nil {
                estimate.siteAddress = quickBooksEstimate.ShipAddr?.Line1
            }
            estimatesByQBID[quickBooksEstimate.Id] = estimate
        }

        var refreshedInvoiceQuickBooksIDs: Set<String> = []
        for quickBooksInvoice in invoices {
            guard QuickBooksBillingIdentity.identifier(quickBooksInvoice.CustomerRef.value) != nil,
                  !customerConflicts.contains(quickBooksInvoice.CustomerRef.value),
                  !invoiceConflicts.contains(quickBooksInvoice.Id),
                  !remoteInvoiceConflicts.contains(quickBooksInvoice.Id),
                  !remoteInvoiceLineageConflicts.contains(QuickBooksInvoiceLineage.localInvoiceID(from: quickBooksInvoice.PrivateNote)?.uuidString ?? "") else {
                QuickBooksBillingIdentity.markForReview(existingInvoices.filter {
                    QuickBooksBillingIdentity.identifier($0.quickBooksID) == quickBooksInvoice.Id ||
                    $0.id == QuickBooksInvoiceLineage.localInvoiceID(from: quickBooksInvoice.PrivateNote)
                })
                invoicesByQBID.removeValue(forKey: quickBooksInvoice.Id)
                reviewReasons.insert("An invoice has an ambiguous customer or QuickBooks mapping.")
                continue
            }
            let customer = resolveCustomer(ref: quickBooksInvoice.CustomerRef, cacheByQBID: &customersByQBID, modelContext: modelContext)
            let lineageID = QuickBooksInvoiceLineage.localInvoiceID(from: quickBooksInvoice.PrivateNote)
            let candidates = existingInvoices.filter {
                QuickBooksBillingIdentity.identifier($0.quickBooksID) == quickBooksInvoice.Id ||
                (lineageID != nil && $0.id == lineageID)
            }
            guard candidates.count <= 1,
                  candidates.allSatisfy({
                      !invoiceUUIDConflicts.contains($0.id.uuidString) &&
                      QuickBooksBillingIdentity.customerMatches($0.customer, reference: quickBooksInvoice.CustomerRef) &&
                      (QuickBooksBillingIdentity.identifier($0.quickBooksID) == nil || QuickBooksBillingIdentity.identifier($0.quickBooksID) == quickBooksInvoice.Id) &&
                      (lineageID == nil || $0.id == lineageID)
                  }) else {
                QuickBooksBillingIdentity.markForReview(candidates)
                invoicesByQBID.removeValue(forKey: quickBooksInvoice.Id)
                reviewReasons.insert("An invoice's customer, local UUID, or QuickBooks ID disagrees.")
                continue
            }
            let existingInvoice = candidates.first ?? invoicesByQBID[quickBooksInvoice.Id]
            guard quickBooksInvoice.TotalAmt.isFinite, quickBooksInvoice.TotalAmt >= 0 else {
                if let existingInvoice { QuickBooksBalanceReconciliation.markForRefresh(existingInvoice) }
                reviewReasons.insert("An invoice response has an invalid total; its saved financial values were preserved.")
                continue
            }
            let invoice = existingInvoice ?? Invoice(id: lineageID ?? UUID(), customer: customer)
            let isNewQuickBooksImport = existingInvoice == nil
            if invoice.modelContext == nil {
                modelContext.insert(invoice)
            }
            invoice.quickBooksID = quickBooksInvoice.Id
            invoice.customer = customer
            let taxIssue = invoice.applyQuickBooksTaxResult(
                total: quickBooksInvoice.TotalAmt,
                reportedTax: quickBooksInvoice.TxnTaxDetail?.TotalTax
            )
            invoice.quickBooksSyncStatus = taxIssue == nil ? "synced" : "needs_attention"
            invoice.quickBooksSyncDetail = taxIssue
            if isNewQuickBooksImport {
                invoice.lineItemSummary = quickBooksInvoice.DocNumber ?? "QuickBooks Invoice"
                invoice.notes = quickBooksInvoice.PrivateNote
                invoice.createdAt = parseQuickBooksDate(quickBooksInvoice.TxnDate) ?? invoice.createdAt
            } else if invoice.notes?.nilIfEmpty == nil {
                invoice.notes = quickBooksInvoice.PrivateNote
            }
            if let importedDueDate = parseQuickBooksDate(quickBooksInvoice.DueDate) {
                invoice.dueDate = importedDueDate
            }
            if invoice.siteAddress?.nilIfEmpty == nil {
                invoice.siteAddress = quickBooksInvoice.ShipAddr?.Line1
            }
            if QuickBooksBalanceReconciliation.apply(quickBooksInvoice, to: invoice) {
                refreshedInvoiceQuickBooksIDs.insert(quickBooksInvoice.Id)
            } else {
                reviewReasons.insert("An invoice response did not include a valid accounting balance. Refresh QuickBooks before collecting.")
            }
            invoicesByQBID[quickBooksInvoice.Id] = invoice
        }

        for key in conflictingPaymentKeys {
            let records = paymentGroups[key, default: []].map { $0.1 }
            QuickBooksBillingIdentity.markForReview(records.compactMap(\.invoice))
            for payment in records {
                payment.quickBooksAccountingSyncStatus = "needs_attention"
                payment.quickBooksAccountingSyncDetail = "Multiple saved payments claim the same QuickBooks invoice allocation. No payment history was changed."
            }
            reviewReasons.insert("Multiple saved payments claim one QuickBooks allocation.")
        }
        var invoicesAffectedByImportedPayments: [UUID: Invoice] = [:]
        for quickBooksPayment in payments {
            guard !remotePaymentConflicts.contains(quickBooksPayment.Id) else {
                let linkedIDs = Set(QuickBooksPaymentAllocation.amountsByInvoiceID(for: quickBooksPayment).keys)
                let related = invoicesByQBID.filter { linkedIDs.contains($0.key) }.map { $0.value }
                QuickBooksBillingIdentity.markForReview(related)
                reviewReasons.insert("The payment snapshot repeats a QuickBooks payment identity; no repeated payment was imported.")
                continue
            }
            for (linkedInvoiceID, appliedAmount) in QuickBooksPaymentAllocation
                .amountsByInvoiceID(for: quickBooksPayment)
                .sorted(by: { $0.key < $1.key }) {
                guard appliedAmount > 0.009,
                      let invoice = invoicesByQBID[linkedInvoiceID] else { continue }
                guard invoice.quickBooksIdentityReviewMessage == nil,
                      QuickBooksBillingIdentity.customerMatches(invoice.customer, reference: quickBooksPayment.CustomerRef) else {
                    reviewReasons.insert("A payment's customer does not match its linked invoice.")
                    continue
                }
                let key = paymentSyncKey(
                    paymentID: quickBooksPayment.Id,
                    invoiceID: linkedInvoiceID
                )
                let existingPayment = paymentsBySyncKey[key]
                if let existingPayment, existingPayment.hasNativeCollectionEvidence,
                   abs(existingPayment.amount - appliedAmount) > 0.009 {
                    existingPayment.quickBooksAccountingSyncStatus = "needs_attention"
                    existingPayment.quickBooksAccountingSyncDetail = "QuickBooks allocation differs from the original collected amount. Review the payment without changing capture history."
                    QuickBooksBillingIdentity.markForReview([invoice])
                    reviewReasons.insert("An accounting payment amount differs from its original capture.")
                    continue
                }
                let payment = existingPayment
                    ?? Payment(
                        invoice: invoice,
                        amount: appliedAmount,
                        method: defaultImportedPaymentMethod(for: quickBooksPayment)
                    )
                if payment.modelContext == nil {
                    modelContext.insert(payment)
                }
                payment.quickBooksID = quickBooksPayment.Id
                payment.invoice = invoice
                if !payment.hasNativeCollectionEvidence {
                    payment.amount = appliedAmount
                    payment.date = parseQuickBooksDate(quickBooksPayment.TxnDate) ?? payment.date
                }
                payment.method = resolvedImportedPaymentMethod(existing: payment, quickBooksPayment: quickBooksPayment)
                if payment.notes?.nilIfEmpty == nil {
                    payment.notes = quickBooksPayment.PrivateNote
                }
                if payment.authorizationReference?.nilIfEmpty == nil {
                    payment.authorizationReference = quickBooksPayment.PaymentRefNum
                }
                if let processor = resolvedImportedProcessor(existing: payment) {
                    payment.processor = processor
                }
                paymentsBySyncKey[key] = payment
                invoicesAffectedByImportedPayments[invoice.id] = invoice
            }
        }

        for invoice in invoicesAffectedByImportedPayments.values {
            guard let quickBooksID = invoice.quickBooksID?.nilIfEmpty,
                  !refreshedInvoiceQuickBooksIDs.contains(quickBooksID) else {
                continue
            }
            QuickBooksBalanceReconciliation.markForRefresh(invoice)
            reviewReasons.insert("Payments refreshed without a current invoice balance. Refresh QuickBooks to finish reconciliation.")
        }

        let reconciledEstimates = try modelContext.fetch(FetchDescriptor<Estimate>()).filter {
            !estimateUUIDConflicts.contains($0.id.uuidString) &&
            !estimateConflicts.contains(QuickBooksBillingIdentity.identifier($0.quickBooksID) ?? "")
        }
        let reconciledInvoices = try modelContext.fetch(FetchDescriptor<Invoice>()).filter {
            $0.quickBooksIdentityReviewMessage == nil
        }
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
            payments: try modelContext.fetch(FetchDescriptor<Payment>()),
            attachments: reconciledAttachments
        )
        try saveSnapshot(modelContext)
        snapshotSaved = true
        if !reviewReasons.isEmpty {
            throw QuickBooksBillingImportReview(reasons: reviewReasons.sorted())
        }
        let syncedEstimates = try modelContext.fetch(FetchDescriptor<Estimate>())
        let syncedInvoices = try modelContext.fetch(FetchDescriptor<Invoice>())
        let syncedServiceCalls = try modelContext.fetch(FetchDescriptor<ServiceCall>())
        let serviceAttachments = try modelContext.fetch(FetchDescriptor<ServiceDocumentAttachment>())
        QuickBooksInvoiceAttachmentSync.syncPendingServiceReports(
            estimates: syncedEstimates,
            invoices: syncedInvoices,
            serviceCalls: syncedServiceCalls,
            payments: try modelContext.fetch(FetchDescriptor<Payment>()),
            attachments: serviceAttachments,
            modelContext: modelContext
        )
    }

    private static func resolveCustomer(
        ref: QuickBooksReference,
        cacheByQBID: inout [String: Customer],
        modelContext: ModelContext
    ) -> Customer {
        if let existing = cacheByQBID[ref.value], !ref.value.isEmpty { return existing }
        let customer = Customer(
            quickBooksID: QuickBooksBillingIdentity.identifier(ref.value),
            name: ref.displayName
        )
        modelContext.insert(customer)
        if !ref.value.isEmpty { cacheByQBID[ref.value] = customer }
        return customer
    }

    private static func reconcileBillingServiceCallLinks(
        estimates: [Estimate],
        invoices: [Invoice],
        serviceCalls: [ServiceCall]
    ) {
        let estimatesByID = Dictionary(grouping: estimates, by: \.id).filter { $0.value.count == 1 }.mapValues { $0[0] }
        let invoicesByID = Dictionary(grouping: invoices, by: \.id).filter { $0.value.count == 1 }.mapValues { $0[0] }
        let serviceCallsByID = Dictionary(grouping: serviceCalls, by: \.id).filter { $0.value.count == 1 }.mapValues { $0[0] }

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
                estimate.serviceLocationID = estimate.serviceLocationID ?? call.serviceLocationID
                estimate.siteAddress = estimate.siteAddress ?? call.siteAddress
            }
            if let linkedInvoiceID = call.linkedInvoiceID,
               let invoice = invoicesByID[linkedInvoiceID],
               sameCustomer(call.customer, invoice.customer),
               invoice.serviceCallID == nil {
                invoice.serviceCallID = call.id
                invoice.serviceLocationID = invoice.serviceLocationID ?? call.serviceLocationID
                invoice.siteAddress = invoice.siteAddress ?? call.siteAddress
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

    private static func sameCustomer(_ lhs: Customer?, _ rhs: Customer?) -> Bool {
        QuickBooksBillingIdentity.sameCustomer(lhs, rhs)
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func paymentSyncKey(paymentID: String, invoiceID: String) -> String {
        "\(paymentID)\u{1f}\(invoiceID)"
    }

    private static func defaultImportedPaymentMethod(for quickBooksPayment: QuickBooksPayment) -> String {
        if isQuickBooksCardPayment(quickBooksPayment) {
            return "card"
        }
        if isQuickBooksACHPayment(quickBooksPayment) {
            return "ach"
        }
        let method = quickBooksPayment.PaymentMethodRef?.name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if method == "check" || method == "cheque" { return "check" }
        if method == "cash" { return "cash" }
        return "quickbooks"
    }

    private static func resolvedImportedPaymentMethod(existing payment: Payment, quickBooksPayment: QuickBooksPayment) -> String {
        // A processor/charge ID can describe card OR ACH. The original rail
        // determines settlement and refund behavior and must not be relabeled.
        if payment.hasNativeCollectionEvidence, payment.backendCollectionMethod != nil {
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
        return methodName.contains("ach") || methodName.contains("bank") || methodName.contains("echeck")
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
