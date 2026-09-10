import Foundation
import Testing
@testable import GunnAire_Ops

@MainActor struct StaffWorkspaceBillingProjectionTests {
    typealias P = StaffWorkspaceBillingProjection
    typealias R = StaffWorkspaceModelRecord
    typealias C = StaffWorkspaceModelCodecs
    let fixture = CloudKitStaffSharingTests()
    var scope: StaffReplicaSourceScope {
        .init(backendOrigin: "https://fixture.example.invalid", actorEmail: "owner@example.invalid",
              binding: fixture.workspace.bindings[0], storeUUID: "a1000000-0000-4000-8000-000000000099")
    }
    func plan(_ role: AppUserRole = .fieldTechnician, changes: [String: Any] = [:]) throws -> CloudKitStaffSharePlan {
        try fixture.plan(["memberRole": role.rawValue, "projectionPolicy": CloudKitStaffSharePlan.policy(for: role.rawValue)!]
            .merging(changes) { _, new in new })
    }
    func row(_ kind: String, _ records: [R]) throws -> R { try #require(records.first { $0.kind == kind }) }
    func replace(_ record: R, _ values: [String: StaffWorkspaceValue]) -> R {
        .init(version: record.version, kind: record.kind, id: record.id, fields: record.fields.merging(values) { _, next in next })
    }
    func replace(_ records: [R], _ kind: String, _ values: [String: StaffWorkspaceValue]) -> [R] {
        records.map { $0.kind == kind ? replace($0, values) : $0 }
    }
    func source(_ records: [R], scope otherScope: StaffReplicaSourceScope? = nil) -> StaffWorkspaceSourceJournal {
        .init(version: 1, scope: otherScope ?? scope,
              records: records.sorted { StaffWorkspaceHistory.key($0) < StaffWorkspaceHistory.key($1) }, cursor: nil, deletionKeys: [])
    }
    func base() throws -> [R] {
        var records = try StaffWorkspaceFullModelTests().encodedFixtures()
        records = replace(records, "technician", ["contactInfo": .text(fixture.member.email)])
        return replace(records, "invoice", ["serviceCallID": .identifier(try row("job", records).id)])
    }
    func prepare(_ records: [R], role: AppUserRole = .fieldTechnician, changes: [String: Any] = [:], sequence: Int = 1) throws -> P {
        try P.prepare(source: source(records), expectedScope: scope, plan: plan(role, changes: changes),
                      workspace: fixture.workspace, sourceSequence: sequence, now: fixture.now)
    }
    func saved(_ projection: P, kind: String = "invoice") throws -> P.SavedCatalog {
        let document = try #require(projection.documents.first { $0.kind == kind })
        guard case .saved(let value) = document.catalog else { throw P.Failure.invalid }
        return value
    }
    func sale(_ records: [R], lines: [CatalogLineItemSnapshot], kind: String = "invoice",
              discount: AuthorizedDocumentDiscount? = nil, tax: Double = 0) throws -> [R] {
        let gross = lines.reduce(0) { $0 + $1.extendedAmount }
        let discountAmount = try discount.map { try #require($0.amount(for: gross)) } ?? 0
        let json = try #require(CatalogLineItemSnapshot.encoded(snapshots: lines, documentDiscount: discount))
        return replace(records, kind, ["catalogSnapshotJSON": .text(json), "amount": .number(gross - discountAmount + tax), "salesTaxAmount": .number(tax)])
    }
    func item(_ records: [R], cost: Double? = 19.375) throws -> Item {
        Item(id: try row("item", records).id, quickBooksID: "QB-HISTORICAL-ITEM", name: "Sold valve", unitPrice: 25,
             purchaseCost: cost, isTaxable: true, itemDescription: "Valve replacement", sku: "VALVE-1")
    }

    @Test func everyOriginalInvoiceAndEstimateFieldHasAnExplicitDisclosureDisposition() throws {
        try P.validateCoverage()
        let records = try base()
        let result = try prepare(records, role: .admin)
        #expect(result.documents.count == 2)
        for document in result.documents {
            let original = try row(document.kind, records)
            #expect(Set(document.fields.keys).isDisjoint(with: document.unavailableFields.keys))
            #expect(Set(document.fields.keys).union(document.unavailableFields.keys).union(["catalogSnapshotJSON"]) == Set(original.fields.keys))
            for (name, value) in document.fields { #expect(value == original.fields[name]) }
            #expect(document.catalog == .notRecorded)
        }
    }

    @Test func fiveRolesMatchCurrentInvoiceAndEstimatePermissionsWithoutLocalUserRoleGrants() throws {
        let records = try base()
        let expectations: [(AppUserRole, Set<String>)] = [(.admin, ["invoice", "estimate"]), (.accounting, ["invoice"]),
            (.dispatcher, ["estimate"]), (.fieldTechnician, ["invoice"]), (.standard, [])]
        for (role, kinds) in expectations {
            let result = try prepare(records, role: role)
            #expect(Set(result.documents.map(\.kind)) == kinds)
            #expect(result.projectionPolicy == CloudKitStaffSharePlan.policy(for: role.rawValue))
        }
        let forgedLocal = replace(records, "user", ["roleRawValue": .text("Admin")])
        #expect(try prepare(forgedLocal, role: .standard).documents.isEmpty)
    }

    @Test func technicianGetsOnlyAssignedInvoicesNotOtherInvoicesForTheSameCustomer() throws {
        let records = try base(), original = try row("invoice", records)
        let unassigned = R(version: 1, kind: "invoice", id: UUID(), fields: original.fields.merging(["serviceCallID": .null]) { _, next in next })
        let result = try prepare(records + [unassigned])
        #expect(result.documents.map(\.id) == [original.id])
        #expect(try prepare(records + [unassigned], role: .accounting).documents.count == 2)
    }

    @Test func originalCrewAssignmentGrantsTheSameInvoiceAsLeadAssignment() throws {
        let original = try base(), own = try row("technician", original)
        let other = Technician(name: "Another lead", contactInfo: "different@example.invalid")
        let json = String(decoding: try JSONEncoder().encode([own.id]), as: UTF8.self)
        let records = replace(original, "job", ["assignedTechnician": .identifier(other.id), "additionalTechnicianIDsJSON": .text(json)]) + [try C.technician.encode(other)]
        #expect(try prepare(records).documents.count == 1)
        let noAssignment = replace(records, "job", ["additionalTechnicianIDsJSON": .null])
        #expect(try prepare(noAssignment).documents.isEmpty)
    }

    @Test func missingOrDuplicateTechnicianIdentityCannotBecomeAnEmptySuccessOrBroaderGrant() throws {
        let records = try base(), own = try row("technician", records)
        #expect(throws: P.Failure.identity) { try prepare(replace(records, "technician", ["contactInfo": .null])) }
        let duplicate = R(version: 1, kind: "technician", id: UUID(), fields: own.fields)
        #expect(throws: P.Failure.identity) { try prepare(records + [duplicate]) }
        let changedCase = replace(records, "technician", ["contactInfo": .text("  " + fixture.member.email.uppercased() + "  ")])
        #expect(try prepare(changedCase).documents.count == 1)
    }

    @Test func noPlanRoleOrSequenceFallbackCanUnlockRevokedPendingOrForeignWork() throws {
        let records = try base()
        let changes: [[String: Any]] = [["businessAccessEligible": false], ["reviewRequired": true],
            ["cloudKitRevocationRequired": true], ["state": "invited", "revision": 3, "businessAccessEligible": false],
            ["state": "revoked", "revision": 5, "businessAccessEligible": false], ["companyID": UUID().uuidString],
            ["replicaID": UUID().uuidString], ["environment": "production"], ["projectionPolicy": "admin-operations-v1"],
            ["memberRevision": "invalid"], ["memberRole": "Owner"]]
        for change in changes { #expect(throws: (any Error).self) { try prepare(records, changes: change) } }
        for sequence in [0, -1, 2_147_483_647] { #expect(throws: P.Failure.access) { try prepare(records, sequence: sequence) } }
    }

    @Test func originalEncryptedJournalScopeCannotBeRelabeledAsAnotherCompanyOrOwnerStore() throws {
        let records = try base()
        let other = StaffReplicaSourceScope(backendOrigin: scope.backendOrigin, actorEmail: scope.actorEmail,
                                           binding: scope.binding, storeUUID: UUID().uuidString)
        #expect(throws: (any Error).self) {
            try P.prepare(source: source(records, scope: other), expectedScope: scope, plan: plan(),
                          workspace: fixture.workspace, sourceSequence: 1, now: fixture.now)
        }
    }

    @Test func malformedHiddenSourceRecordsAndBrokenCustomerLinksStillFailTheWholePreparation() throws {
        let records = try base()
        let broken = replace(records, "invoice", ["customer": .identifier(UUID())])
        #expect(throws: (any Error).self) { try prepare(broken, role: .standard) }
        let unknown = replace(records, "technician", ["newPrivateField": .text("must be classified")])
        #expect(throws: (any Error).self) { try prepare(unknown, role: .accounting) }
        #expect(throws: (any Error).self) { try prepare(records + [records[0]]) }
    }

    @Test func recordedCostsAreVisibleOnlyToFinancialRolesWithoutAHiddenValueOrPresenceOracle() throws {
        let base = try base()
        let withCost = try sale(base, lines: [.init(item: item(base), quantity: 2)])
        let withoutCost = try sale(base, lines: [.init(item: item(base, cost: nil), quantity: 2)])
        let field = try saved(prepare(withCost))
        #expect(field.lines[0].purchaseCost == .restricted)
        #expect(field.lines[0].quickBooksItemID == .restricted)
        #expect(try saved(prepare(withoutCost)).lines[0].purchaseCost == .restricted)
        for role in [AppUserRole.admin, .accounting] {
            #expect(try saved(prepare(withCost, role: role)).lines[0].purchaseCost == .recorded(19.375))
            #expect(try saved(prepare(withoutCost, role: role)).lines[0].purchaseCost == .notRecorded)
            #expect(try saved(prepare(withCost, role: role)).lines[0].quickBooksItemID == .recorded("QB-HISTORICAL-ITEM"))
        }
        let zero = try sale(base, lines: [.init(item: item(base, cost: 0))])
        #expect(try saved(prepare(zero, role: .accounting)).lines[0].purchaseCost == .recorded(0))
    }

    @Test func historicalPricesQuantityDiscountApprovalAndEquipmentSurviveWithoutUsingCurrentCatalogValues() throws {
        let base = try base(), originalItem = try item(base)
        let adjustment = AuthorizedLinePriceAdjustment(pricebookUnitPrice: 25, unitPrice: 20, reason: "Approved service adjustment",
            authorizedByEmail: "historical.owner@example.invalid", authorizedAt: fixture.now)
        let equipment = CatalogLineEquipmentSnapshot(equipmentID: try row("equipment", base).id, name: "Sold system", serialNumber: "ORIGINAL-123")
        let line = CatalogLineItemSnapshot(item: originalItem, quantity: 2.5, priceAdjustment: adjustment, servicedEquipment: equipment)
        let discount = AuthorizedDocumentDiscount(kind: .percentage, value: 10, grossSubtotalAtAuthorization: 50,
            reason: "Service plan discount", authorizedByEmail: "historical.owner@example.invalid", authorizedAt: fixture.now)
        var records = try sale(base, lines: [line], discount: discount, tax: 3.15)
        records = replace(records, "item", ["name": .text("Current name changed"), "unitPrice": .number(999), "purchaseCost": .number(998)])
        let projected = try saved(prepare(records)), sold = try #require(projected.lines.first)
        #expect(sold.name == "Sold valve" && sold.unitPrice == 20 && sold.pricebookUnitPrice == 25)
        #expect(sold.quantity == 2.5 && sold.extendedAmount == 50)
        #expect(sold.priceAdjustmentReason == adjustment.reason && sold.priceAdjustmentAuthorizedByEmail == adjustment.authorizedByEmail)
        #expect(sold.priceAdjustmentAuthorizedAt == adjustment.authorizedAt && sold.servicedEquipment == equipment)
        #expect(projected.discount == discount)
        #expect(try prepare(records).documents[0].fields["amount"] == .number(48.15))
        #expect(try prepare(records).documents[0].fields["salesTaxAmount"] == .number(3.15))
    }

    @Test func assemblyComponentCostsAreRestrictedRecursivelyButPhysicalPartsRemainUsable() throws {
        var records = try base()
        let root = try item(records), part = Item(name: "Assembly part", unitPrice: 7, purchaseCost: 3.125)
        records.append(try C.item.encode(part))
        let assembly = CatalogLineAssemblySnapshot(assemblyItemID: root.id, name: "Original repair package", revision: 3,
            presentation: .flatRate, components: [.init(itemID: part.id, name: part.name, sku: "P-1", quantity: 2, purchaseCost: part.purchaseCost, tracksInventory: true)])
        let source = try sale(records, lines: [.init(item: root, quantity: 1, assembly: assembly)])
        let field = try #require(saved(prepare(source)).lines[0].assembly)
        #expect(field.assemblyItemID == assembly.assemblyItemID && field.revision == 3)
        #expect(field.components[0].itemID == part.id && field.components[0].quantity == 2 && field.components[0].tracksInventory)
        #expect(field.components[0].purchaseCost == .restricted)
        let financial = try #require(saved(prepare(source, role: .accounting)).lines[0].assembly)
        #expect(financial.components[0].purchaseCost == .recorded(3.125))
        #expect(try saved(prepare(source)).lines[0].purchaseCost == .restricted)
    }

    @Test func bundleMemberIDsOrderRepeatedItemsAndAlreadyExtendedQuantitiesSurviveWithoutDoubleMultiplication() throws {
        var records = try base()
        let root = Item(id: try row("item", records).id, quickBooksID: "BUNDLE", name: "Sold bundle", itemType: .group, unitPrice: 0)
        let child = Item(quickBooksID: "MEMBER", name: "Repeat valve", unitPrice: 25, purchaseCost: 9.375)
        records.append(try C.item.encode(child))
        let ids = [UUID(), UUID()]
        let original = CatalogBundleSnapshot(scope: .init(companyID: fixture.companyID, realmID: "ORIGINAL-REALM", environment: "sandbox"),
            printGroupedItems: false, members: [.init(id: ids[0], line: .init(item: child, quantity: 6), tracksInventory: true),
                .init(id: ids[1], line: .init(item: child, quantity: 3), tracksInventory: true)])
        let line = CatalogLineItemSnapshot(item: root, quantity: 3, bundle: original)
        let recordsWithSale = try sale(records, lines: [line])
        let fieldLine = try saved(prepare(recordsWithSale)).lines[0], bundle = try #require(fieldLine.bundle)
        #expect(fieldLine.quantity == 3 && fieldLine.extendedAmount == 225)
        #expect(bundle.members.map(\.id) == ids && bundle.members.map(\.line.quantity) == [6, 3])
        #expect(bundle.members.map(\.line.catalogItemID) == [child.id, child.id])
        #expect(bundle.members.allSatisfy { $0.line.purchaseCost == .restricted && $0.line.quickBooksItemID == .restricted })
        #expect(bundle.scope == .restricted && !bundle.printGroupedItems)
        let accounting = try #require(saved(prepare(recordsWithSale, role: .accounting)).lines[0].bundle)
        #expect(accounting.scope == .recorded(original.scope))
        #expect(accounting.members[0].line.purchaseCost == .recorded(9.375))
        let foreign = line.replacingBundle(.init(scope: .init(companyID: UUID(), realmID: "OTHER", environment: "sandbox"),
            printGroupedItems: false, members: original.members))
        let foreignRecords = try sale(records, lines: [foreign])
        #expect(throws: P.Failure.scope) { try prepare(foreignRecords) }
        #expect(throws: P.Failure.scope) { try prepare(foreignRecords, role: .standard) }
        #expect(throws: P.Failure.scope) { try prepare(foreignRecords, role: .dispatcher) }
    }

    @Test func changingOnlyPrivateCostOrItsPresenceDoesNotChangeFieldDisclosureBytes() throws {
        let base = try base(), records = try sale(base, lines: [.init(item: item(base))])
        let originalJSON = try String.fromStaffValue(row("invoice", records).fields["catalogSnapshotJSON"]!)
        let original = try StaffWorkspacePublicationContract.encode(prepare(records))
        for changedJSON in [originalJSON.replacingOccurrences(of: "\"purchaseCost\":19.375", with: "\"purchaseCost\":1"),
                            originalJSON.replacingOccurrences(of: "\"purchaseCost\":19.375", with: "\"purchaseCost\":null")] {
            #expect(changedJSON != originalJSON)
            let changed = replace(records, "invoice", ["catalogSnapshotJSON": .text(changedJSON)])
            #expect(try StaffWorkspacePublicationContract.encode(prepare(changed)) == original)
        }
    }

    @Test func dispatchGetsUsableEstimateLinesButNeitherCostNorProviderMappings() throws {
        let base = try base(), records = try sale(base, lines: [.init(item: item(base), quantity: 1.25)], kind: "estimate")
        let projection = try prepare(records, role: .dispatcher), catalog = try saved(projection, kind: "estimate")
        #expect(catalog.lines[0].quantity == 1.25 && catalog.lines[0].extendedAmount == 31.25)
        #expect(catalog.lines[0].purchaseCost == .restricted && catalog.lines[0].quickBooksItemID == .restricted)
        #expect(projection.documents[0].unavailableFields["quickBooksID"] == .roleRestricted)
    }

    @Test func providerDiagnosticsAndOpaqueReviewReceiptsAreNeverSmuggledThroughDocumentFields() throws {
        let records = try replace(base(), "invoice", ["quickBooksSyncDetail": .text("PRIVATE-DIAGNOSTIC"),
            "quickBooksPaymentReviewJSON": .text("PRIVATE-PAYMENT-REVIEW"), "milestoneDraftReceiptJSON": .text("PRIVATE-DRAFT-RECEIPT")])
        for role in [AppUserRole.admin, .accounting, .fieldTechnician] {
            let projection = try prepare(records, role: role)
            let text = String(decoding: try StaffWorkspacePublicationContract.encode(projection), as: UTF8.self)
            #expect(!text.contains("PRIVATE-"))
            #expect(projection.documents.first { $0.kind == "invoice" }?.unavailableFields["quickBooksSyncDetail"] == .serviceOnly)
        }
    }

    @Test func malformedNestedJSONUnknownKeysChangedTotalsAndUnapprovedPricesAreNotRepairedOrSilentlyDropped() throws {
        let base = try base(), valid = try sale(base, lines: [.init(item: item(base))])
        let invoice = try row("invoice", valid), json = try String.fromStaffValue(invoice.fields["catalogSnapshotJSON"]!)
        let invalid = ["{", json.replacingOccurrences(of: "\"purchaseCost\":", with: "\"unknownPrivateCost\":123,\"purchaseCost\":"),
                       json.replacingOccurrences(of: "\"quantity\":1", with: "\"quantity\":null")]
        for text in invalid {
            let changed = replace(valid, "invoice", ["catalogSnapshotJSON": .text(text)])
            #expect(throws: (any Error).self) { try prepare(changed) }
        }
        #expect(throws: (any Error).self) { try prepare(replace(valid, "invoice", ["amount": .number(500)])) }
        let noApproval = json.replacingOccurrences(of: "\"unitPrice\":25", with: "\"unitPrice\":20")
        #expect(throws: (any Error).self) { try prepare(replace(valid, "invoice", ["catalogSnapshotJSON": .text(noApproval)])) }
    }

    @Test func strictOwnerVerificationRejectsCostInjectionUnknownFieldsDuplicateKeysAndChangedBindings() throws {
        let base = try base(), records = try sale(base, lines: [.init(item: item(base))])
        let original = try prepare(records), data = try StaffWorkspacePublicationContract.encode(original)
        func verify(_ bytes: Data, sequence: Int = 1, currentPlan: CloudKitStaffSharePlan? = nil) throws -> P {
            try P.verify(bytes, source: source(records), expectedScope: scope, plan: currentPlan ?? plan(),
                         workspace: fixture.workspace, sourceSequence: sequence, now: fixture.now)
        }
        #expect(try verify(data) == original)
        let text = String(decoding: data, as: UTF8.self)
        let attacks = [text.replacingOccurrences(of: "\"purchaseCost\":{\"restricted\":{}}", with: "\"purchaseCost\":{\"recorded\":{\"_0\":0}}"),
            text.replacingOccurrences(of: "\"purchaseCost\":", with: "\"ownerCost\":123,\"purchaseCost\":"),
            "{\"schema\":\"staff-billing-view-v1\"," + text.dropFirst(),
            text.replacingOccurrences(of: "\"sourceSequence\":1", with: "\"sourceSequence\":2")]
        for changed in attacks {
            #expect(changed != text)
            #expect(throws: (any Error).self) { try verify(Data(changed.utf8)) }
        }
        #expect(throws: (any Error).self) { try verify(data, sequence: 2) }
        let changedRole = try plan(.accounting)
        #expect(throws: (any Error).self) { try verify(data, currentPlan: changedRole) }
        let changedMember = try plan(changes: ["memberRevision": String(repeating: "b", count: 64)])
        #expect(throws: (any Error).self) { try verify(data, currentPlan: changedMember) }
    }

    @Test func originalSourceIsUnchangedAndBillingViewCannotDecodeAsOwnerRecords() throws {
        let base = try base(), records = try sale(base, lines: [.init(item: item(base))])
        let before = try StaffWorkspacePublicationContract.encode(source(records))
        let projection = try prepare(records), after = try StaffWorkspacePublicationContract.encode(source(records))
        #expect(before == after)
        let data = try StaffWorkspacePublicationContract.encode(projection)
        #expect(throws: (any Error).self) { try StaffWorkspaceModelRecord.decode(data) }
        #expect(projection.schema != StaffWorkspacePublicationContract.schema)
        #expect(projection.sourceSequence == 1 && projection.membershipID == fixture.shareID)
    }
}
