import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor struct ProjectProgressAllocationTests {
    private func bundle() throws -> (CatalogLineItemSnapshot, [Item]) {
        let items = try CatalogBundleFixture.makeCatalog()
        return (try CatalogBundlePolicy.resolve(root: items[3], catalog: items, scope: CatalogBundleFixture.scope), items)
    }
    private func json(_ source: [CatalogLineItemSnapshot], discount: AuthorizedDocumentDiscount? = nil) throws -> String {
        try #require(CatalogLineItemSnapshot.encoded(snapshots: source, documentDiscount: discount))
    }
    private func net(_ json: String) throws -> Double {
        try #require(BillingDocumentDiscountPolicy.netSubtotal(snapshotJSON: json))
    }
    private func verifyConservation(_ source: [CatalogLineItemSnapshot], documents: [String]) throws {
        let allocated = documents.map { CatalogLineItemSnapshot.decoded(from: $0) }
        for root in source {
            let copies = allocated.flatMap { $0 }.filter { $0.catalogItemID == root.catalogItemID }
            let quantitySum = try copies.reduce(Decimal.zero) { result, line in
                result + (try #require(QuickBooksSalesLineContract.decimal(line.quantity, places: 5)))
            }
            #expect(quantitySum == QuickBooksSalesLineContract.decimal(root.quantity, places: 5))
            if let bundle = root.bundle {
                for member in bundle.members {
                    let members = copies.flatMap { $0.bundle?.members ?? [] }.filter { $0.id == member.id }
                    let sum = try members.reduce(Decimal.zero) { result, copy in
                        #expect(copy.tracksInventory == member.tracksInventory)
                        #expect(copy.line.replacingQuantity(with: member.line.quantity) == member.line)
                        return result + (try #require(QuickBooksSalesLineContract.decimal(copy.line.quantity, places: 5)))
                    }
                    #expect(sum == QuickBooksSalesLineContract.decimal(member.line.quantity, places: 5))
                    #expect(members.reduce(0) { $0 + Int64(($1.line.extendedAmount * 100).rounded()) }
                        == Int64((member.line.extendedAmount * 100).rounded()))
                }
                #expect(copies.allSatisfy { $0.bundle?.scope == bundle.scope && $0.bundle?.printGroupedItems == bundle.printGroupedItems })
            } else {
                #expect(copies.allSatisfy { $0.replacingQuantity(with: root.quantity) == root })
            }
        }
    }

    @Test func repeatedBundleMembersProduceRealGroupInvoicesAndConserveWholePlan() throws {
        let (source, items) = try bundle()
        let targets = [56.7, 94.5, 37.8]
        let documents = try ProjectProgressAllocation.documents(from: json([source]), targetAmounts: targets)
        #expect(try documents.map(net) == targets)
        try verifyConservation([source], documents: documents)
        for (index, document) in documents.enumerated() {
            let lines = try QuickBooksDocumentLinePublication.lines(snapshotJSON: document,
                expectedSubtotal: targets[index], catalogItems: items)
            #expect(lines.count == 1 && lines[0].DetailType == "GroupLineDetail")
            #expect(lines[0].Amount == 0 && lines[0].GroupLineDetail?.Line.count == 2)
            #expect(lines[0].GroupLineDetail?.Quantity == [0.3, 0.5, 0.2][index])
            #expect(QuickBooksSalesLineContract.double(try QuickBooksSalesLineContract.totals(lines).net) == targets[index])
        }
    }

    @Test func editedComponentQuantitiesPricesEquipmentAndHiddenDisplaySurviveEveryStage() throws {
        let (original, items) = try bundle()
        let equipment = CatalogLineEquipmentSnapshot(equipmentID: UUID(), name: "Upstairs heat pump",
            manufacturer: "Lennox", modelNumber: "Saved", serialNumber: "SAVED-ONLY", location: "Roof")
        let admin = AppUser(email: "office@example.invalid", role: .admin)
        let edited = try CatalogBundlePolicy.editSale(CatalogBundlePolicy.equipment(original, equipment),
            memberID: original.bundle!.members[1].id, quantity: 1.25, price: 81.875, taxable: true,
            reason: "Approved project price", actorEmail: admin.email, users: [admin])
        let detail = try #require(edited.bundle)
        let source = edited.replacingBundle(.init(scope: detail.scope, printGroupedItems: false, members: detail.members))
        let targets = ProjectBillingPolicy.allocatedAmounts(total: source.extendedAmount, percentages: [30, 50, 20])
        let documents = try ProjectProgressAllocation.documents(from: json([source]), targetAmounts: targets)
        try verifyConservation([source], documents: documents)
        for (index, document) in documents.enumerated() {
            let root = try #require(CatalogLineItemSnapshot.decoded(from: document).first)
            #expect(!root.customerSummary.contains("Saved diagnostic labor"))
            #expect(root.servicedEquipment == equipment && root.soldLeaves.allSatisfy { $0.servicedEquipment == equipment })
            let lines = try QuickBooksDocumentLinePublication.lines(snapshotJSON: document, expectedSubtotal: targets[index], catalogItems: items)
            #expect(try QuickBooksSalesLineContract.totals(lines).taxable)
        }
    }

    @Test func bundleDiscountCentsAndAuthorizationAreAllocatedOnceAcrossSevenStages() throws {
        let (source, items) = try bundle()
        let discount = AuthorizedDocumentDiscount(kind: .fixedAmount, value: 10.01,
            grossSubtotalAtAuthorization: 189, reason: "Approved incentive",
            authorizedByEmail: "office@example.invalid", authorizedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let targets = ProjectBillingPolicy.allocatedAmounts(total: 178.99, percentages: Array(repeating: 1, count: 7))
        let documents = try ProjectProgressAllocation.documents(from: json([source], discount: discount), targetAmounts: targets)
        try verifyConservation([source], documents: documents)
        var discountCents: Int64 = 0
        for (index, document) in documents.enumerated() {
            let saved = try #require(CatalogLineItemSnapshot.documentDiscount(from: document))
            #expect(saved.reason == discount.reason && saved.authorizedAt == discount.authorizedAt)
            #expect(saved.authorizedByEmail == discount.authorizedByEmail && saved.kind == .fixedAmount)
            discountCents += try #require(ProjectProgressAllocation.exactCents(saved.value))
            let lines = try QuickBooksDocumentLinePublication.lines(snapshotJSON: document, expectedSubtotal: targets[index], catalogItems: items)
            #expect(QuickBooksSalesLineContract.double(try QuickBooksSalesLineContract.totals(lines).net) == targets[index])
        }
        #expect(discountCents == 1_001)
    }

    @Test func fractionalAndFreeRowsConserveQuantitiesWithoutZeroQuantityProviderLines() throws {
        let (bundle, items) = try bundle()
        let free = Item(quickBooksID: "FREE", name: "Included handoff", unitPrice: 0)
        let fractional = Item(quickBooksID: "FRACTION", name: "Fractional part", unitPrice: 12.375)
        let source = [bundle, CatalogLineItemSnapshot(item: free, quantity: 0.00001), CatalogLineItemSnapshot(item: fractional, quantity: 1.25)]
        let targets = ProjectBillingPolicy.allocatedAmounts(total: 204.47, percentages: [33.33, 33.33, 33.34])
        let documents = try ProjectProgressAllocation.documents(from: json(source), targetAmounts: targets)
        try verifyConservation(source, documents: documents)
        for (index, document) in documents.enumerated() {
            let lines = try QuickBooksDocumentLinePublication.lines(snapshotJSON: document,
                expectedSubtotal: targets[index], catalogItems: items + [free, fractional])
            #expect(QuickBooksSalesLineContract.double(try QuickBooksSalesLineContract.totals(lines).net) == targets[index])
        }
    }

    @Test func unrepresentableSingleItemSplitDoesNotInventPriceOrFraction() throws {
        let item = Item(quickBooksID: "EXPENSIVE", name: "Equipment", unitPrice: 10_000)
        let source = try json([CatalogLineItemSnapshot(item: item)])
        #expect(throws: ProjectBillingValidationError.allocationPrecision("Equipment")) {
            try ProjectProgressAllocation.documents(from: source, targetAmounts: [3_333.33, 6_666.67])
        }
        #expect(item.unitPrice == 10_000)
        #expect(try ProjectProgressAllocation.documents(from: source, targetAmounts: [3_000, 5_000, 2_000]).map(net) == [3_000, 5_000, 2_000])
    }

    @Test func malformedOverallocatedAndConflictingSnapshotsCannotBecomeInvoices() throws {
        let (source, _) = try bundle()
        for targets in [[190.0], [56.7, 94.5, 37.81], [0, 189], [.infinity], [.nan], [56.700001, 132.299999]] {
            #expect(throws: (any Error).self) { try ProjectProgressAllocation.documents(from: json([source]), targetAmounts: targets) }
        }
        #expect(throws: (any Error).self) { try ProjectProgressAllocation.documents(from: json([source, source]), targetAmounts: [189, 189]) }
        #expect(throws: (any Error).self) { try ProjectProgressAllocation.documents(from: "{bad", targetAmounts: [1, 1]) }
        let bundle = source.bundle!
        let duplicate = source.replacingBundle(bundle.replacingMembers([bundle.members[0], bundle.members[0]]))
        #expect(throws: CatalogBundleError.invalidMembers) { try ProjectProgressAllocation.documents(from: json([duplicate]), targetAmounts: [56.7, 132.3]) }
    }

    private func plan(taxed: Bool = false) throws -> (Estimate, [ProjectMilestone], [Item]) {
        let (source, items) = try bundle()
        let estimate = Estimate(customer: Customer(name: "Project customer"), catalogSnapshotJSON: try json([source]),
            amount: taxed ? 202.23 : 189, status: "accepted", customerApprovedByName: "Customer",
            customerApprovedAt: Date(), customerApprovalMethodRaw: EstimateApprovalMethod.email.rawValue,
            customerApprovalReference: "APPROVAL-ORIGINAL", customerApprovalRecordedByEmail: "office@example.invalid")
        if taxed { estimate.salesTaxAmount = 13.23 }
        let milestones = try ProjectBillingPolicy.makeMilestones(drafts: ProjectBillingPolicy.defaultDrafts(startingAt: Date()),
            projectServiceCallID: UUID(), estimate: estimate, createdByEmail: "office@example.invalid")
        return (estimate, milestones, items)
    }

    @Test func actualIssuanceReconcilesTheOriginalInvoiceBeforeAnotherStage() throws {
        let (estimate, plan, _) = try plan()
        let first = try ProjectBillingPolicy.progressDocumentSnapshotJSON(for: plan[0], estimate: estimate, milestones: plan, invoices: [])
        let invoice = Invoice(serviceCallID: plan[0].projectServiceCallID, customer: estimate.customer,
            catalogSnapshotJSON: first, amount: plan[0].plannedAmount, projectMilestoneID: plan[0].id, projectMilestoneSequence: 0)
        #expect(plan[0].markInvoiced(invoiceID: invoice.id))
        let second = try ProjectBillingPolicy.progressDocumentSnapshotJSON(for: plan[1], estimate: estimate, milestones: plan, invoices: [invoice])
        #expect(try net(second) == 94.5)
        #expect(throws: ProjectBillingValidationError.issuedAllocationChanged) {
            try ProjectBillingPolicy.progressDocumentSnapshotJSON(for: plan[1], estimate: estimate, milestones: plan, invoices: [])
        }
        invoice.catalogSnapshotJSON = estimate.catalogSnapshotJSON
        #expect(throws: ProjectBillingValidationError.issuedAllocationChanged) {
            try ProjectBillingPolicy.progressDocumentSnapshotJSON(for: plan[1], estimate: estimate, milestones: plan, invoices: [invoice])
        }
        #expect(invoice.catalogSnapshotJSON == estimate.catalogSnapshotJSON)
    }

    @Test func taxIsNotResoldAsContractScopeAndChangedPlanCannotHideBehindSameTotal() throws {
        let (estimate, plan, _) = try plan(taxed: true)
        #expect(plan.map(\.plannedAmount) == [56.7, 94.5, 37.8])
        try ProjectBillingPolicy.validatePersistedPlan(plan, contractAmount: 189)
        let invoice = try ProjectBillingPolicy.progressDocumentSnapshotJSON(for: plan[0], estimate: estimate, milestones: plan, invoices: [])
        #expect(try net(invoice) == 56.7)
        plan[0].plannedAmount += 1; plan[1].plannedAmount -= 1
        #expect(throws: ProjectBillingValidationError.invalidPersistedPlan) {
            try ProjectBillingPolicy.progressDocumentSnapshotJSON(for: plan[0], estimate: estimate, milestones: plan, invoices: [])
        }
    }

    @Test func ambiguousOrOrphanMilestoneInvoiceRequiresReviewWithoutAnotherCreate() throws {
        let (estimate, plan, _) = try plan()
        let orphan = Invoice(serviceCallID: plan[0].projectServiceCallID, customer: estimate.customer,
            amount: 1, projectMilestoneID: UUID(), projectMilestoneSequence: 0)
        #expect(throws: ProjectBillingValidationError.issuedAllocationChanged) {
            try ProjectBillingPolicy.progressDocumentSnapshotJSON(for: plan[0], estimate: estimate, milestones: plan, invoices: [orphan])
        }
        plan[1].sequence = 0
        #expect(throws: ProjectBillingValidationError.invalidPersistedPlan) { try ProjectBillingPolicy.validatePersistedPlan(plan, contractAmount: 189) }
    }

    @Test func materialsRemainTheWholeApprovedJobAndTaxDoesNotInflateProgress() throws {
        let (estimate, plan, items) = try plan()
        let call = ServiceCall(id: plan[0].projectServiceCallID, type: .install, scheduledDate: Date(),
            customer: estimate.customer, linkedEstimateID: estimate.id)
        items[2].tracksInventory = true
        let document = try ProjectBillingPolicy.progressDocumentSnapshotJSON(for: plan[0], estimate: estimate, milestones: plan, invoices: [])
        let invoice = Invoice(serviceCallID: call.id, customer: estimate.customer, catalogSnapshotJSON: document,
            amount: 60.67, projectMilestoneID: plan[0].id, projectMilestoneSequence: 0)
        invoice.salesTaxAmount = 3.97
        _ = plan[0].markInvoiced(invoiceID: invoice.id)
        let requirements = JobMaterialCloseoutPolicy.requirements(for: call, invoice: invoice,
            estimates: [estimate], projectMilestones: plan, items: items, movements: [])
        #expect(requirements.count == 1 && requirements[0].quantity == 2)
        let summary = ProjectBillingPolicy.summary(milestones: plan, invoices: [invoice],
            payments: [Payment(invoice: invoice, amount: 60.67)])
        #expect(summary.invoicedAmount == 56.7 && summary.paidAmount == 56.7)
        #expect(abs(summary.remainingToInvoice - 132.3) < 0.000001)
        _ = try ProjectBillingPolicy.progressDocumentSnapshotJSON(for: plan[1], estimate: estimate, milestones: plan, invoices: [invoice])
        invoice.customer = nil // CloudKit relationship has not arrived yet.
        #expect(throws: ProjectBillingValidationError.issuedAllocationChanged) {
            try ProjectBillingPolicy.progressDocumentSnapshotJSON(for: plan[1], estimate: estimate, milestones: plan, invoices: [invoice])
        }
    }

    @Test func allStagesCanBeIssuedOutOfOrderWithoutChangingTheirSavedAllocation() throws {
        let (estimate, plan, _) = try plan()
        var invoices: [Invoice] = []
        for stage in [2, 0, 1] {
            let document = try ProjectBillingPolicy.progressDocumentSnapshotJSON(for: plan[stage], estimate: estimate, milestones: plan, invoices: invoices)
            let invoice = Invoice(serviceCallID: plan[stage].projectServiceCallID, customer: estimate.customer,
                catalogSnapshotJSON: document, amount: plan[stage].plannedAmount,
                projectMilestoneID: plan[stage].id, projectMilestoneSequence: stage)
            _ = plan[stage].markInvoiced(invoiceID: invoice.id)
            invoices.append(invoice)
        }
        #expect(invoices.reduce(0) { $0 + Int64(($1.amount * 100).rounded()) } == 18_900)
        try verifyConservation(estimate.catalogLineSnapshots, documents: invoices.compactMap(\.catalogSnapshotJSON))
    }

    @Test func reviewedTaxAddressesTravelWithEachAllocationAndRejectAnotherProperty() throws {
        let (estimate, plan, _) = try plan()
        estimate.serviceLocationID = UUID()
        estimate.siteAddress = "10 Main Street, Charlotte, NC 28202"
        let address = BillingPublicationAddress(Line1: "10 Main Street", City: "Charlotte",
            CountrySubDivisionCode: "NC", PostalCode: "28202")
        let context = try BillingTaxAddressContext(scope: .init(customerID: estimate.customer.id,
            serviceLocationID: estimate.serviceLocationID, siteAddress: estimate.siteAddress), service: address, origin: address)
        estimate.catalogSnapshotJSON = try BillingTaxAddressContext.attaching(context, to: #require(estimate.catalogSnapshotJSON))
        for milestone in plan {
            let document = try ProjectBillingPolicy.progressDocumentSnapshotJSON(for: milestone, estimate: estimate, milestones: plan, invoices: [])
            #expect(BillingTaxAddressContext.read(document) == context)
            let invoice = Invoice(serviceCallID: milestone.projectServiceCallID, serviceLocationID: estimate.serviceLocationID,
                siteAddress: estimate.siteAddress, customer: estimate.customer, catalogSnapshotJSON: document,
                amount: milestone.plannedAmount, projectMilestoneID: milestone.id, projectMilestoneSequence: milestone.sequence)
            #expect(try BillingTaxAddressContext.forPublication(.invoice(invoice)) == context)
            invoice.serviceLocationID = UUID()
            #expect(throws: BillingTaxAddressError.changed) { try BillingTaxAddressContext.forPublication(.invoice(invoice)) }
        }
    }

    @Test func priorTaxedInvoiceUsesExactMoneyFieldsNotBinarySubtractionArtifacts() throws {
        let item = Item(quickBooksID: "SMALL", name: "Small part", unitPrice: 0.3)
        let estimate = Estimate(customer: Customer(name: "Customer"), catalogSnapshotJSON: try json([CatalogLineItemSnapshot(item: item)]),
            amount: 0.3, status: "accepted", customerApprovedByName: "Customer", customerApprovedAt: Date(),
            customerApprovalMethodRaw: EstimateApprovalMethod.email.rawValue, customerApprovalReference: "SMALL-APPROVAL",
            customerApprovalRecordedByEmail: "office@example.invalid")
        let plan = try ProjectBillingPolicy.makeMilestones(drafts: ProjectBillingPolicy.defaultDrafts(startingAt: Date()),
            projectServiceCallID: UUID(), estimate: estimate, createdByEmail: "office@example.invalid")
        let first = try ProjectBillingPolicy.progressDocumentSnapshotJSON(for: plan[0], estimate: estimate, milestones: plan, invoices: [])
        let invoice = Invoice(serviceCallID: plan[0].projectServiceCallID, customer: estimate.customer,
            catalogSnapshotJSON: first, amount: 0.1, projectMilestoneID: plan[0].id, projectMilestoneSequence: 0)
        invoice.salesTaxAmount = 0.01
        _ = plan[0].markInvoiced(invoiceID: invoice.id)
        #expect(invoice.subtotalAmount != 0.09) // 0.09000000000000001, not corrupted cents.
        let next = try ProjectBillingPolicy.progressDocumentSnapshotJSON(for: plan[1], estimate: estimate, milestones: plan, invoices: [invoice])
        #expect(try net(next) == 0.15)
        invoice.amount = 0.100001
        #expect(throws: ProjectBillingValidationError.issuedAllocationChanged) {
            try ProjectBillingPolicy.progressDocumentSnapshotJSON(for: plan[1], estimate: estimate, milestones: plan, invoices: [invoice])
        }
    }
}
