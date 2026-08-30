import Foundation

@MainActor
protocol QuickBooksVendorTransactionTransport {
    var isAuthenticated: Bool { get }
    var realmID: String? { get }
    var currentEnvironment: String { get }

    func loadBills() async throws -> [QuickBooksBill]
    func postBill(_ bill: QuickBooksBillCreate, requestID: String) async throws -> QuickBooksBill
    func loadVendorCredits() async throws -> [QuickBooksVendorCredit]
    func postVendorCredit(
        _ vendorCredit: QuickBooksVendorCreditCreate,
        requestID: String
    ) async throws -> QuickBooksVendorCredit
}

extension QuickBooksDataAPI: QuickBooksVendorTransactionTransport {
    func loadBills() async throws -> [QuickBooksBill] {
        try await withCheckedThrowingContinuation { continuation in
            fetchBills { continuation.resume(with: $0) }
        }
    }

    func postBill(_ bill: QuickBooksBillCreate, requestID: String) async throws -> QuickBooksBill {
        try await withCheckedThrowingContinuation { continuation in
            createBill(bill, requestID: requestID) { continuation.resume(with: $0) }
        }
    }

    func loadVendorCredits() async throws -> [QuickBooksVendorCredit] {
        try await withCheckedThrowingContinuation { continuation in
            fetchVendorCredits { continuation.resume(with: $0) }
        }
    }

    func postVendorCredit(
        _ vendorCredit: QuickBooksVendorCreditCreate,
        requestID: String
    ) async throws -> QuickBooksVendorCredit {
        try await withCheckedThrowingContinuation { continuation in
            createVendorCredit(vendorCredit, requestID: requestID) { continuation.resume(with: $0) }
        }
    }
}

enum QuickBooksVendorTransactionPublicationError: LocalizedError, Equatable {
    case unauthorized
    case disconnected
    case accountingMappingsUnavailable
    case invalidAccountsPayableMapping
    case vendorMappingRequired
    case billNotFound
    case billNotMatched
    case vendorCreditNotFound
    case vendorCreditNotMatched
    case alreadyLinked(providerID: String)
    case invalidAmount
    case duplicateProviderMarkers
    case providerRecordMismatch
    case unableToStoreProviderLink

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            "Only an administrator can publish supplier bills or vendor credits to QuickBooks."
        case .disconnected:
            "Connect QuickBooks Accounting before publishing this supplier transaction."
        case .accountingMappingsUnavailable:
            "Open QuickBooks Management → Overview → Accounting Mappings and save the expense and Accounts Payable accounts for this company."
        case .invalidAccountsPayableMapping:
            "The configured liability account is not an Accounts Payable account. Review Accounting Mappings before publishing."
        case .vendorMappingRequired:
            "Link this supplier to its exact QuickBooks Vendor before publishing."
        case .billNotFound:
            "This vendor bill is no longer present on the purchase order. Refresh before publishing."
        case .billNotMatched:
            "Resolve the purchase-order receipt, quantity, and cost variances before publishing this bill."
        case .vendorCreditNotFound:
            "This vendor credit evidence is no longer present on the supplier return. Refresh before publishing."
        case .vendorCreditNotMatched:
            "Resolve the supplier credit variance before publishing a QuickBooks Vendor Credit."
        case .alreadyLinked(let providerID):
            "This transaction is already linked to QuickBooks ID \(providerID)."
        case .invalidAmount:
            "The reviewed supplier transaction must have a finite amount greater than zero."
        case .duplicateProviderMarkers:
            "More than one QuickBooks transaction contains this GunnAire marker. Do not create another; reconcile the duplicates in QuickBooks."
        case .providerRecordMismatch:
            "A QuickBooks transaction has this GunnAire marker but its vendor, AP account, date, reference, or amount does not match the reviewed local evidence. Reconcile it before retrying."
        case .unableToStoreProviderLink:
            "QuickBooks confirmed the transaction, but the local provider link could not be stored. Retry to recover the existing QuickBooks transaction; do not create it manually."
        }
    }
}

struct QuickBooksVendorTransactionPublicationResult: Equatable {
    enum Resolution: String, Equatable {
        case created
        case recovered
    }

    let providerID: String
    let resolution: Resolution
}

@MainActor
enum QuickBooksVendorTransactionPublisher {
    static func billMarker(_ billID: UUID) -> String {
        "[GunnAire Bill:\(billID.uuidString.lowercased())]"
    }

    static func vendorCreditMarker(_ vendorReturnID: UUID) -> String {
        "[GunnAire VendorCredit:\(vendorReturnID.uuidString.lowercased())]"
    }

    static func publishBill(
        _ bill: PurchaseOrderVendorBill,
        on order: PurchaseOrder,
        configuration: BackendQuickBooksAccountingConfiguration?,
        actorEmail: String?,
        users: [AppUser],
        transport: (any QuickBooksVendorTransactionTransport)? = nil,
        publishedAt: Date = Date()
    ) async throws -> QuickBooksVendorTransactionPublicationResult {
        let transport = transport ?? QuickBooksDataAPI.shared
        let context = try validatedContext(
            order: order,
            configuration: configuration,
            actorEmail: actorEmail,
            users: users,
            transport: transport
        )
        guard let currentBill = order.vendorBills.first(where: { $0.id == bill.id }) else {
            throw QuickBooksVendorTransactionPublicationError.billNotFound
        }
        let existingProviderID = normalized(currentBill.quickBooksBillID)
        if !existingProviderID.isEmpty {
            throw QuickBooksVendorTransactionPublicationError.alreadyLinked(providerID: existingProviderID)
        }
        guard order.billMatch.state == .matched else {
            throw QuickBooksVendorTransactionPublicationError.billNotMatched
        }
        try requireValidAmount(currentBill.totalAmount)

        let marker = billMarker(currentBill.id)
        let payload = billPayload(
            currentBill,
            order: order,
            vendorID: context.vendorID,
            configuration: context.configuration,
            marker: marker
        )
        if let recovered = try recoveredBill(
            from: try await transport.loadBills(),
            marker: marker,
            expected: payload
        ) {
            try linkBill(
                currentBill,
                providerID: recovered.Id,
                order: order,
                actorEmail: context.actorEmail,
                publishedAt: publishedAt
            )
            return QuickBooksVendorTransactionPublicationResult(
                providerID: recovered.Id,
                resolution: .recovered
            )
        }

        do {
            let created = try await transport.postBill(payload, requestID: currentBill.id.uuidString.lowercased())
            try validate(created, marker: marker, expected: payload)
            try linkBill(
                currentBill,
                providerID: created.Id,
                order: order,
                actorEmail: context.actorEmail,
                publishedAt: publishedAt
            )
            return QuickBooksVendorTransactionPublicationResult(
                providerID: created.Id,
                resolution: .created
            )
        } catch {
            do {
                if let recovered = try recoveredBill(
                    from: try await transport.loadBills(),
                    marker: marker,
                    expected: payload
                ) {
                    try linkBill(
                        currentBill,
                        providerID: recovered.Id,
                        order: order,
                        actorEmail: context.actorEmail,
                        publishedAt: publishedAt
                    )
                    return QuickBooksVendorTransactionPublicationResult(
                        providerID: recovered.Id,
                        resolution: .recovered
                    )
                }
            } catch let recoveryError as QuickBooksVendorTransactionPublicationError {
                throw recoveryError
            } catch {
                // Preserve the original create error when the reconciliation
                // read itself is unavailable and cannot establish a result.
            }
            throw error
        }
    }

    static func publishVendorCredit(
        for vendorReturn: PurchaseOrderVendorReturn,
        on order: PurchaseOrder,
        configuration: BackendQuickBooksAccountingConfiguration?,
        actorEmail: String?,
        users: [AppUser],
        transport: (any QuickBooksVendorTransactionTransport)? = nil,
        publishedAt: Date = Date()
    ) async throws -> QuickBooksVendorTransactionPublicationResult {
        let transport = transport ?? QuickBooksDataAPI.shared
        let context = try validatedContext(
            order: order,
            configuration: configuration,
            actorEmail: actorEmail,
            users: users,
            transport: transport
        )
        guard let currentReturn = order.vendorReturn(withID: vendorReturn.id),
              let evidence = currentReturn.creditEvidence else {
            throw QuickBooksVendorTransactionPublicationError.vendorCreditNotFound
        }
        let existingProviderID = normalized(evidence.quickBooksVendorCreditID)
        if !existingProviderID.isEmpty {
            throw QuickBooksVendorTransactionPublicationError.alreadyLinked(providerID: existingProviderID)
        }
        guard currentReturn.status == .creditReceived,
              order.vendorCreditMatch(for: currentReturn).state == .matched else {
            throw QuickBooksVendorTransactionPublicationError.vendorCreditNotMatched
        }
        try requireValidAmount(evidence.creditAmount)

        let marker = vendorCreditMarker(currentReturn.id)
        let payload = vendorCreditPayload(
            evidence,
            vendorReturn: currentReturn,
            order: order,
            vendorID: context.vendorID,
            configuration: context.configuration,
            marker: marker
        )
        if let recovered = try recoveredVendorCredit(
            from: try await transport.loadVendorCredits(),
            marker: marker,
            expected: payload
        ) {
            try linkVendorCredit(
                currentReturn,
                evidence: evidence,
                providerID: recovered.Id,
                order: order,
                actorEmail: context.actorEmail,
                publishedAt: publishedAt
            )
            return QuickBooksVendorTransactionPublicationResult(
                providerID: recovered.Id,
                resolution: .recovered
            )
        }

        do {
            let created = try await transport.postVendorCredit(
                payload,
                requestID: currentReturn.id.uuidString.lowercased()
            )
            try validate(created, marker: marker, expected: payload)
            try linkVendorCredit(
                currentReturn,
                evidence: evidence,
                providerID: created.Id,
                order: order,
                actorEmail: context.actorEmail,
                publishedAt: publishedAt
            )
            return QuickBooksVendorTransactionPublicationResult(
                providerID: created.Id,
                resolution: .created
            )
        } catch {
            do {
                if let recovered = try recoveredVendorCredit(
                    from: try await transport.loadVendorCredits(),
                    marker: marker,
                    expected: payload
                ) {
                    try linkVendorCredit(
                        currentReturn,
                        evidence: evidence,
                        providerID: recovered.Id,
                        order: order,
                        actorEmail: context.actorEmail,
                        publishedAt: publishedAt
                    )
                    return QuickBooksVendorTransactionPublicationResult(
                        providerID: recovered.Id,
                        resolution: .recovered
                    )
                }
            } catch let recoveryError as QuickBooksVendorTransactionPublicationError {
                throw recoveryError
            } catch {
                // Preserve the original create error when the reconciliation
                // read itself is unavailable and cannot establish a result.
            }
            throw error
        }
    }

    static func billPayload(
        _ bill: PurchaseOrderVendorBill,
        order: PurchaseOrder,
        vendorID: String,
        configuration: BackendQuickBooksAccountingConfiguration,
        marker: String? = nil
    ) -> QuickBooksBillCreate {
        let marker = marker ?? billMarker(bill.id)
        var lines = order.effectiveAllocations(for: bill).compactMap { allocation -> QuickBooksBillLine? in
            let amount = allocation.merchandiseAmount
            guard amount > 0.0001 else { return nil }
            return QuickBooksBillLine(
                amount: amount,
                description: "\(allocation.quantity.formatted()) × \(allocation.itemName)",
                accountRef: configuration.expenseAccountReference
            )
        }
        let charges: [(String, Double)] = [
            ("Freight", bill.shippingCost),
            ("Tax", bill.taxAmount),
            ("Other supplier charges", bill.otherCharges),
        ]
        lines.append(contentsOf: charges.compactMap { description, amount in
            guard amount > 0.0001 else { return nil }
            return QuickBooksBillLine(
                amount: amount,
                description: description,
                accountRef: configuration.expenseAccountReference
            )
        })
        return QuickBooksBillCreate(
            VendorRef: QuickBooksReference(value: vendorID, name: order.vendorName),
            APAccountRef: configuration.accountsPayableReference,
            Line: lines,
            TxnDate: QuickBooksDateOnly.string(from: bill.invoiceDate),
            DocNumber: providerDocumentNumber(bill.invoiceNumber),
            PrivateNote: joinedNote(
                marker: marker,
                details: [
                    "GunnAire purchase order \(order.number)",
                    bill.note,
                    bill.sourceDocumentName.map { "Source document: \($0)" },
                    "Reviewed locally by \(bill.recordedByEmail)",
                ]
            )
        )
    }

    static func vendorCreditPayload(
        _ evidence: PurchaseOrderVendorCreditEvidence,
        vendorReturn: PurchaseOrderVendorReturn,
        order: PurchaseOrder,
        vendorID: String,
        configuration: BackendQuickBooksAccountingConfiguration,
        marker: String? = nil
    ) -> QuickBooksVendorCreditCreate {
        let marker = marker ?? vendorCreditMarker(vendorReturn.id)
        let breakdown = "Returned merchandise, credit \(evidence.creditAmount.formatted(.currency(code: "USD"))); restocking fee \(evidence.restockingFee.formatted(.currency(code: "USD"))); tax credit \(evidence.taxCredit.formatted(.currency(code: "USD"))); freight credit \(evidence.shippingCredit.formatted(.currency(code: "USD")))"
        return QuickBooksVendorCreditCreate(
            VendorRef: QuickBooksReference(value: vendorID, name: order.vendorName),
            APAccountRef: configuration.accountsPayableReference,
            Line: [
                QuickBooksBillLine(
                    amount: evidence.creditAmount,
                    description: breakdown,
                    accountRef: configuration.expenseAccountReference
                )
            ],
            TxnDate: QuickBooksDateOnly.string(from: evidence.creditDate),
            DocNumber: providerDocumentNumber(evidence.reference),
            PrivateNote: joinedNote(
                marker: marker,
                details: [
                    "GunnAire purchase order \(order.number) • supplier return \(vendorReturn.reference)",
                    evidence.note,
                    evidence.sourceDocumentName.map { "Source document: \($0)" },
                    "Reviewed locally by \(evidence.recordedByEmail)",
                ]
            )
        )
    }

    private struct PublicationContext {
        let configuration: BackendQuickBooksAccountingConfiguration
        let vendorID: String
        let actorEmail: String
    }

    private static func validatedContext(
        order: PurchaseOrder,
        configuration: BackendQuickBooksAccountingConfiguration?,
        actorEmail: String?,
        users: [AppUser],
        transport: any QuickBooksVendorTransactionTransport
    ) throws -> PublicationContext {
        guard AppAccess.isAdmin(email: actorEmail, users: users) else {
            throw QuickBooksVendorTransactionPublicationError.unauthorized
        }
        guard transport.isAuthenticated, transport.realmID != nil else {
            throw QuickBooksVendorTransactionPublicationError.disconnected
        }
        guard let configuration,
              configuration.isComplete,
              configuration.matches(
                realmID: transport.realmID,
                environment: transport.currentEnvironment
              ) else {
            throw QuickBooksVendorTransactionPublicationError.accountingMappingsUnavailable
        }
        guard configuration.defaultAPAccountType.caseInsensitiveCompare("Accounts Payable") == .orderedSame else {
            throw QuickBooksVendorTransactionPublicationError.invalidAccountsPayableMapping
        }
        let vendorID = normalized(order.vendorQuickBooksID)
        guard !vendorID.isEmpty else {
            throw QuickBooksVendorTransactionPublicationError.vendorMappingRequired
        }
        return PublicationContext(
            configuration: configuration,
            vendorID: vendorID,
            actorEmail: AppAccess.normalizedEmail(actorEmail)
        )
    }

    private static func recoveredBill(
        from bills: [QuickBooksBill],
        marker: String,
        expected: QuickBooksBillCreate
    ) throws -> QuickBooksBill? {
        let matches = bills.filter { containsMarker($0.PrivateNote, marker: marker) }
        guard matches.count <= 1 else {
            throw QuickBooksVendorTransactionPublicationError.duplicateProviderMarkers
        }
        guard let match = matches.first else { return nil }
        try validate(match, marker: marker, expected: expected)
        return match
    }

    private static func recoveredVendorCredit(
        from vendorCredits: [QuickBooksVendorCredit],
        marker: String,
        expected: QuickBooksVendorCreditCreate
    ) throws -> QuickBooksVendorCredit? {
        let matches = vendorCredits.filter { containsMarker($0.PrivateNote, marker: marker) }
        guard matches.count <= 1 else {
            throw QuickBooksVendorTransactionPublicationError.duplicateProviderMarkers
        }
        guard let match = matches.first else { return nil }
        try validate(match, marker: marker, expected: expected)
        return match
    }

    private static func validate(
        _ bill: QuickBooksBill,
        marker: String,
        expected: QuickBooksBillCreate
    ) throws {
        guard containsMarker(bill.PrivateNote, marker: marker),
              normalized(bill.VendorRef.value) == normalized(expected.VendorRef.value),
              normalized(bill.APAccountRef?.value) == normalized(expected.APAccountRef.value),
              bill.TxnDate == expected.TxnDate,
              normalized(bill.DocNumber) == normalized(expected.DocNumber),
              abs(bill.TotalAmt - expected.Line.reduce(0) { $0 + $1.Amount }) <= 0.01 else {
            throw QuickBooksVendorTransactionPublicationError.providerRecordMismatch
        }
    }

    private static func validate(
        _ vendorCredit: QuickBooksVendorCredit,
        marker: String,
        expected: QuickBooksVendorCreditCreate
    ) throws {
        guard containsMarker(vendorCredit.PrivateNote, marker: marker),
              normalized(vendorCredit.VendorRef.value) == normalized(expected.VendorRef.value),
              normalized(vendorCredit.APAccountRef?.value) == normalized(expected.APAccountRef.value),
              vendorCredit.TxnDate == expected.TxnDate,
              normalized(vendorCredit.DocNumber) == normalized(expected.DocNumber),
              abs(vendorCredit.TotalAmt - expected.Line.reduce(0) { $0 + $1.Amount }) <= 0.01 else {
            throw QuickBooksVendorTransactionPublicationError.providerRecordMismatch
        }
    }

    private static func linkBill(
        _ bill: PurchaseOrderVendorBill,
        providerID: String,
        order: PurchaseOrder,
        actorEmail: String,
        publishedAt: Date
    ) throws {
        let providerID = normalized(providerID)
        guard !providerID.isEmpty, providerID.count <= 80,
              order.replaceVendorBill(
                bill.linkingQuickBooksBill(
                    id: providerID,
                    actorEmail: actorEmail,
                    publishedAt: publishedAt
                )
              ) else {
            throw QuickBooksVendorTransactionPublicationError.unableToStoreProviderLink
        }
        order.updatedAt = publishedAt
    }

    private static func linkVendorCredit(
        _ vendorReturn: PurchaseOrderVendorReturn,
        evidence: PurchaseOrderVendorCreditEvidence,
        providerID: String,
        order: PurchaseOrder,
        actorEmail: String,
        publishedAt: Date
    ) throws {
        let providerID = normalized(providerID)
        guard !providerID.isEmpty, providerID.count <= 80 else {
            throw QuickBooksVendorTransactionPublicationError.unableToStoreProviderLink
        }
        let linkedEvidence = evidence.linkingQuickBooksVendorCredit(
            id: providerID,
            actorEmail: actorEmail,
            publishedAt: publishedAt
        )
        let linkedReturn = vendorReturn.replacing(creditEvidence: .some(linkedEvidence))
        guard order.replaceVendorReturn(linkedReturn) else {
            throw QuickBooksVendorTransactionPublicationError.unableToStoreProviderLink
        }
        order.updatedAt = publishedAt
    }

    private static func containsMarker(_ note: String?, marker: String) -> Bool {
        note?.components(separatedBy: .newlines).contains(marker) == true
    }

    private static func requireValidAmount(_ amount: Double) throws {
        guard amount.isFinite, amount > 0.0001, amount <= 1_000_000_000 else {
            throw QuickBooksVendorTransactionPublicationError.invalidAmount
        }
    }

    private static func providerDocumentNumber(_ value: String) -> String? {
        let value = normalized(value)
        guard !value.isEmpty else { return nil }
        return String(value.prefix(21))
    }

    private static func joinedNote(marker: String, details: [String?]) -> String {
        let lines = [marker] + details.compactMap { value -> String? in
            let value = normalized(value)
            return value.isEmpty ? nil : value
        }
        return String(lines.joined(separator: "\n").prefix(4_000))
    }

    private static func normalized(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
