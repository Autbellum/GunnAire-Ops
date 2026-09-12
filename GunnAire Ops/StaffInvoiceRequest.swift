import Foundation

/// Original shared invoice identity. This never grants authority to an owner Invoice model.
struct StaffInvoiceOrigin: Codable, Equatable {
    let companyID: String
    let environment: String
    let replicaID: String
    let selectionID: String
    let sourceSequence: Int
    let contentSHA256: String
    let invoiceID: String
    let invoiceRevision: Int
    let customerID: String
    let jobID: String?

    enum CodingKeys: String, CodingKey {
        case companyID, environment, replicaID, selectionID, sourceSequence, contentSHA256
        case invoiceID, invoiceRevision, customerID, jobID
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(companyID, forKey: .companyID); try c.encode(environment, forKey: .environment)
        try c.encode(replicaID, forKey: .replicaID); try c.encode(selectionID, forKey: .selectionID)
        try c.encode(sourceSequence, forKey: .sourceSequence); try c.encode(contentSHA256, forKey: .contentSHA256)
        try c.encode(invoiceID, forKey: .invoiceID); try c.encode(invoiceRevision, forKey: .invoiceRevision)
        try c.encode(customerID, forKey: .customerID); try c.encode(jobID, forKey: .jobID)
    }
    func validate() throws {
        guard [companyID, replicaID, selectionID, invoiceID, customerID].allSatisfy(CloudKitStaffSetupPolicy.canonicalID),
              jobID == nil || CloudKitStaffSetupPolicy.canonicalID(jobID!),
              ["development", "production"].contains(environment),
              (1..<2_147_483_647).contains(sourceSequence), (1..<2_147_483_647).contains(invoiceRevision),
              JobBillingAssignmentSnapshot.validConnectionRevision(contentSHA256) else { throw StaffReplicaDeliveryError.invalid }
    }
}

struct StaffInvoiceLine: Codable, Equatable {
    var kind: String
    var itemID: String
    var itemRevision: Int
    var itemType: String
    var name: String
    var description: String?
    var sku: String?
    var unitPrice: Double
    var quantity: Double
    var isTaxable: Bool
    var equipmentID: String?

    enum CodingKeys: String, CodingKey { case kind, itemID, itemRevision, itemType, name, description, sku, unitPrice, quantity, isTaxable, equipmentID }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind); try c.encode(itemID, forKey: .itemID)
        try c.encode(itemRevision, forKey: .itemRevision); try c.encode(itemType, forKey: .itemType)
        try c.encode(name, forKey: .name); try c.encode(description, forKey: .description)
        try c.encode(sku, forKey: .sku); try c.encode(unitPrice, forKey: .unitPrice)
        try c.encode(quantity, forKey: .quantity); try c.encode(isTaxable, forKey: .isTaxable)
        try c.encode(equipmentID, forKey: .equipmentID)
    }
    static func text(_ value: String, maximum: Int, normalized: Bool = true) -> Bool {
        value.utf8.count <= maximum && !value.contains("\0") &&
            (!normalized || (!value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
    func validate() throws {
        guard ["catalog", "new"].contains(kind), CloudKitStaffSetupPolicy.canonicalID(itemID),
              equipmentID == nil || CloudKitStaffSetupPolicy.canonicalID(equipmentID!),
              (kind == "new" ? itemRevision == 0 && ["Service", "NonInventory"].contains(itemType) :
                (1..<2_147_483_647).contains(itemRevision) && ["Service", "NonInventory", "Inventory", "Group"].contains(itemType)),
              Self.text(name, maximum: 200, normalized: kind == "new"), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              description.map({ Self.text($0, maximum: 2000, normalized: kind == "new") }) ?? true,
              sku.map({ Self.text($0, maximum: 100, normalized: kind == "new") }) ?? true,
              let quantity = QuickBooksSalesLineContract.decimal(quantity, places: 5, maximum: 999_999), quantity > 0,
              let price = QuickBooksSalesLineContract.decimal(unitPrice, places: 5),
              quantity * price <= Decimal(99_999_999_999 as Int64) else { throw StaffReplicaDeliveryError.invalid }
    }
    var unitPriceSubtotal: Decimal? {
        guard itemType != "Group", (try? validate()) != nil,
              let q = QuickBooksSalesLineContract.decimal(quantity, places: 5),
              let p = QuickBooksSalesLineContract.decimal(unitPrice, places: 5) else { return nil }
        return QuickBooksSalesLineContract.rounded(q * p)
    }
}

/// Codable is flattened to the existing server contract. Explicit nulls are mandatory.
struct StaffInvoiceRequest: Codable, Equatable {
    static let schema = "staff-invoice-line-request-v1"
    let schema: String
    let origin: StaffInvoiceOrigin
    let commandID: String
    let line: StaffInvoiceLine
    let reason: String
    enum CodingKeys: String, CodingKey { case schema, commandID, line, reason }
    init(origin: StaffInvoiceOrigin, commandID: String, line: StaffInvoiceLine, reason: String) {
        schema = Self.schema; self.origin = origin; self.commandID = commandID; self.line = line; self.reason = reason
    }
    init(from decoder: Decoder) throws {
        origin = try StaffInvoiceOrigin(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(String.self, forKey: .schema); commandID = try c.decode(String.self, forKey: .commandID)
        line = try c.decode(StaffInvoiceLine.self, forKey: .line); reason = try c.decode(String.self, forKey: .reason)
    }
    func encode(to encoder: Encoder) throws {
        try origin.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema); try c.encode(commandID, forKey: .commandID)
        try c.encode(line, forKey: .line); try c.encode(reason, forKey: .reason)
    }
    func validate() throws {
        try origin.validate(); try line.validate()
        guard schema == Self.schema, CloudKitStaffSetupPolicy.canonicalID(commandID),
              StaffInvoiceLine.text(reason, maximum: 2000),
              try StaffInvoiceHTTPPolicy.asciiWireBytes(self) <= 16_384 else { throw StaffReplicaDeliveryError.invalid }
    }
}

struct StaffInvoiceReceipt: Codable, Equatable {
    let schema: String
    let request: StaffInvoiceRequest
    let actorEmail: String
    let shareID: String
    let createdAt: String
    let state: String
    let officeReviewRequired: Bool
    let qboPublished: Bool
    let lineSubtotal: String?
    enum CodingKeys: String, CodingKey { case schema, request, actorEmail, shareID, createdAt, state, officeReviewRequired, qboPublished, lineSubtotal }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema); try c.encode(request, forKey: .request)
        try c.encode(actorEmail, forKey: .actorEmail); try c.encode(shareID, forKey: .shareID)
        try c.encode(createdAt, forKey: .createdAt); try c.encode(state, forKey: .state)
        try c.encode(officeReviewRequired, forKey: .officeReviewRequired); try c.encode(qboPublished, forKey: .qboPublished)
        try c.encode(lineSubtotal, forKey: .lineSubtotal)
    }
    func validate(request original: StaffInvoiceRequest, email: String, plan: UUID) throws {
        try original.validate()
        guard request == original, schema == StaffInvoiceRequest.schema, actorEmail == email,
              shareID == plan.uuidString.lowercased(), state == "recorded", officeReviewRequired, !qboPublished,
              createdAt.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil else {
            throw StaffReplicaDeliveryError.invalid
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: createdAt)
        if date == nil { formatter.formatOptions = [.withInternetDateTime]; date = formatter.date(from: createdAt) }
        guard date != nil else { throw StaffReplicaDeliveryError.invalid }
        if let expected = original.line.unitPriceSubtotal {
            guard let lineSubtotal, lineSubtotal.range(of: #"^(?:0|[1-9]\d*)\.\d{2}$"#, options: .regularExpression) != nil,
                  Decimal(string: lineSubtotal, locale: Locale(identifier: "en_US_POSIX")) == expected else { throw StaffReplicaDeliveryError.invalid }
        } else if lineSubtotal != nil { throw StaffReplicaDeliveryError.invalid }
    }
}

enum StaffInvoiceHTTPPolicy {
    /// Python's ensure_ascii wire limit counts a non-ASCII UTF-16 unit as six bytes.
    static func asciiWireBytes<T: Encodable>(_ value: T) throws -> Int {
        let data = try StaffWorkspacePublicationContract.encode(value)
        guard let text = String(data: data, encoding: .utf8) else { throw StaffReplicaDeliveryError.invalid }
        return text.utf16.reduce(0) { $0 + ($1 < 127 ? 1 : 6) }
    }
    static func path(plan: UUID, request: StaffInvoiceRequest) -> String {
        CloudKitStaffSetupPolicy.base + "/" + plan.uuidString.lowercased() + "/full-selections/" + request.origin.selectionID + "/content/invoice-line-requests"
    }
    static func allows(path: String, method: String, body: Data?) -> Bool {
        guard method == "POST", let body, body.count <= 16_384,
              let url = URLComponents(string: path), url.scheme == nil, url.host == nil, url.fragment == nil,
              url.query == nil, url.path == url.percentEncodedPath else { return false }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 9, Array(parts.prefix(4)) == ["", "api", "workspace", "staff-shares"],
              CloudKitStaffSetupPolicy.canonicalID(parts[4]), parts[5] == "full-selections",
              parts[7] == "content", parts[8] == "invoice-line-requests",
              let request = try? StaffWorkspacePublicationContract.decode(StaffInvoiceRequest.self, from: body, maximum: 16_384),
              request.origin.selectionID == parts[6], (try? request.validate()) != nil else { return false }
        return true
    }
}
