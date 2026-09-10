import Foundation

public enum LoadSightError: Error, LocalizedError, Equatable, Sendable {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { message } else { nil } }
}

public enum InputOrigin: String, Codable, Sendable {
    case extracted, userProvided, codeDefault, engineeringAssumption, rfiRequired
}

public struct Evidence: Codable, Equatable, Sendable {
    public var origin: InputOrigin
    public var source: String
    public var confidence: Double
    public var reviewer: String?
    public init(origin: InputOrigin, source: String, confidence: Double, reviewer: String? = nil) throws {
        try require(!source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Evidence source is required.")
        try require(confidence.isFinite && (0...1).contains(confidence), "Confidence must be between zero and one.")
        self.origin = origin; self.source = source; self.confidence = confidence; self.reviewer = reviewer
    }
}

public func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw LoadSightError.invalid(message) }
}

public func nonnegative(_ values: Double...) throws {
    try require(values.allSatisfy { $0.isFinite && $0 >= 0 }, "Inputs must be finite and nonnegative.")
}

/// Lossless JSON tree keeps legacy evidence, drawings, and extensions during edits.
public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public var object: [String: JSONValue]? { if case .object(let v) = self { v } else { nil } }
    public var array: [JSONValue]? { if case .array(let v) = self { v } else { nil } }
    public var string: String? { if case .string(let v) = self { v } else { nil } }
    public var number: Double? { if case .number(let v) = self { v } else { nil } }
    public subscript(_ key: String) -> JSONValue { object?[key] ?? .null }
}

public struct ProjectDocument: Sendable {
    public private(set) var root: JSONValue
    public var name: String { root["name"].string ?? "" }
    public var items: [[String: JSONValue]] { (root["items"].array ?? []).compactMap(\.object) }
    public init(data: Data) throws {
        root = try JSONDecoder().decode(JSONValue.self, from: data)
        try validate()
    }
    public func data() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(root)
    }
    public func validate() throws {
        try require(root["schemaVersion"].number == 1, "Unsupported project schema; expected version 1.")
        try require(!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Project name is required.")
        for key in ["items", "devices", "rfis", "qa", "requirements", "sheets", "zones", "measurements", "markers"] {
            guard let rows = root[key].array else { throw LoadSightError.invalid("Missing project array: \(key)") }
            try require(rows.allSatisfy { $0.object != nil }, "\(key) contains a non-object row.")
            if ["items", "rfis", "qa", "devices", "requirements"].contains(key) {
                let ids = rows.compactMap { $0["id"].string }
                try require(ids.count == rows.count && ids.allSatisfy { !$0.isEmpty } && Set(ids).count == ids.count, "Missing or duplicate IDs in \(key).")
            }
        }
        try require(root["inputs"].object != nil, "Project pricing inputs are missing.")
        if root["proposalDetails"] != .null {
            try require(root["proposalDetails"].object != nil, "Invalid proposal details.")
            for field in ProposalDetails.fields where root["proposalDetails"][field.id] != .null {
                try require(root["proposalDetails"][field.id].string != nil, "Proposal \(field.id) must be text.")
            }
        }
        try validateRFIWorkflow()
        _ = try changeOrders()
        _ = try changeOrderHistory()
        _ = try opsContextHistory()
        _ = try attachments()
        for item in items {
            for key in ["quantity", "materialUnit", "laborHoursUnit", "subcontractUnit", "otherUnit", "wastePct"] {
                if let v = item[key], v != .null {
                    guard let n = v.number else { throw LoadSightError.invalid("\(key) must be numeric or null.") }
                    try nonnegative(n)
                }
            }
            try require(["Base", "Allowance", "Hold", "Excluded"].contains(item["scope"]?.string ?? ""), "Unknown scope for takeoff item.")
        }
        for key in ["laborRate", "markupPct", "taxAllowance", "jobCosts", "contingency"] {
            let v = root["inputs"][key]
            if v != .null {
                guard let n = v.number else { throw LoadSightError.invalid("\(key) must be numeric or null.") }
                try nonnegative(n)
            }
        }
    }
    /// Validate a replacement before publishing any edit to the working document.
    public mutating func replace(_ key: String, with value: JSONValue) throws {
        guard var object = root.object else { throw LoadSightError.invalid("Invalid project root.") }
        object[key] = value
        let candidate = try ProjectDocument(data: JSONEncoder().encode(JSONValue.object(object)))
        self = candidate
    }
    public mutating func updateItem(id: String, fields: [String: JSONValue]) throws {
        var rows = root["items"].array ?? []
        guard let index = rows.firstIndex(where: { $0["id"].string == id }), var row = rows[index].object else {
            throw LoadSightError.invalid("Takeoff item not found: \(id)")
        }
        try require(fields["id"] == nil, "A physical record identity cannot be edited.")
        if row["nativeMarkupID"] != nil {
            for key in ["nativeMarkupID", "quantity", "unit", "source", "basis", "lifecycle", "description", "category"] {
                if let value = fields[key] {
                    try require(value == row[key], "Change drawing-derived \(key) through its source markup, not the estimate row.")
                }
            }
        }
        row.merge(fields) { _, new in new }; rows[index] = .object(row)
        var object = root.object!
        object["items"] = .array(rows)
        object["qa"] = .array((root["qa"].array ?? []).map { entry in
            var gate = entry.object!; gate["status"] = .string("Open"); gate["reviewer"] = .string(""); gate["date"] = .string("")
            return .object(gate)
        })
        self = try ProjectDocument(data: JSONEncoder().encode(JSONValue.object(object)))
    }
}
