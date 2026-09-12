import Foundation

public struct RFIDraft: Sendable {
    public var title: String
    public var question: String
    public var source: String
    public var impact: String
    public var priority: String
    public var itemIDs: [String]
    public var communication: RFICommunication?
    public init(title: String, question: String, source: String, impact: String, priority: String = "Normal", itemIDs: [String] = [], communication: RFICommunication? = nil) {
        self.title = title; self.question = question; self.source = source; self.impact = impact
        self.priority = priority; self.itemIDs = itemIDs
        self.communication = communication
    }
}

public extension ProjectDocument {
    /// Creates or corrects an open question. Resolved questions must be explicitly reopened first.
    @discardableResult
    mutating func saveRFI(id: String? = nil, draft: RFIDraft, author: String) throws -> String {
        for (name, value) in [("title", draft.title), ("question", draft.question), ("drawing source", draft.source), ("impact", draft.impact)] {
            try require(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "RFI \(name) is required.")
        }
        try require(["Normal", "High", "Urgent"].contains(draft.priority), "Unknown RFI priority.")
        let known = Set(items.compactMap { $0["id"]?.string })
        try require(Set(draft.itemIDs).count == draft.itemIDs.count && draft.itemIDs.allSatisfy { known.contains($0) }, "RFI links must identify existing, unique takeoff items.")
        let identity = id ?? "RFI-" + UUID().uuidString
        var row: [String: JSONValue]
        if let id {
            row = try rfiRecord(id)
            try require(row["status"]?.string == "Open", "Reopen this RFI before changing its question.")
        } else {
            row = ["id": .string(identity), "status": .string("Open"), "response": .string(""), "resolvedBy": .string(""), "resolvedDate": .string("")]
        }
        row.merge(["title": .string(draft.title), "question": .string(draft.question), "source": .string(draft.source),
                   "impact": .string(draft.impact), "priority": .string(draft.priority), "itemIDs": .array(draft.itemIDs.map(JSONValue.string))]) { _, new in new }
        if let communication = draft.communication {
            try communication.validate()
            row.merge(communication.values.mapValues(JSONValue.string)) { _, new in new }
            row["communicationVersion"] = .number(1)
        }
        try commitRFI(row, action: id == nil ? "created" : "edited", author: author, reason: "Question and scope recorded")
        return identity
    }

    mutating func resolveRFI(id: String, response: String, responseSource: String, respondent: String, author: String) throws {
        var row = try rfiRecord(id)
        try require(row["status"]?.string == "Open", "Only an open RFI can be resolved.")
        for (name, value) in [("response", response), ("response source", responseSource), ("respondent", respondent)] {
            try require(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Record the RFI \(name).")
        }
        row["status"] = .string("Resolved"); row["response"] = .string(response)
        row["responseSource"] = .string(responseSource); row["resolvedBy"] = .string(respondent)
        row["resolvedDate"] = .string(Date().ISO8601Format())
        try commitRFI(row, action: "resolved", author: author, reason: responseSource)
    }

    mutating func reopenRFI(id: String, reason: String, author: String) throws {
        var row = try rfiRecord(id)
        try require(row["status"]?.string == "Resolved", "Only a resolved RFI can be reopened.")
        try require(!reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Explain why this RFI is being reopened.")
        row["status"] = .string("Open")
        // Previous answers remain in history; clear the current answer to avoid stale resolution.
        for key in ["response", "responseSource", "resolvedBy", "resolvedDate"] { row[key] = .string("") }
        try commitRFI(row, action: "reopened", author: author, reason: reason)
    }

    private func rfiRecord(_ id: String) throws -> [String: JSONValue] {
        guard let row = root["rfis"].array?.first(where: { $0["id"].string == id })?.object else { throw LoadSightError.invalid("RFI not found: \(id)") }
        return row
    }

    private mutating func commitRFI(_ newRow: [String: JSONValue], action: String, author: String, reason: String) throws {
        try require(!author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Record who is saving this RFI change.")
        var row = newRow
        if row["itemIDs"] == nil { row["itemIDs"] = .array([]) }
        let id = row["id"]!.string!, now = Date().ISO8601Format()
        row["workflowVersion"] = .number(1); row["updatedBy"] = .string(author); row["updatedAt"] = .string(now)
        var rows = root["rfis"].array!, object = root.object!, history = root["rfiHistory"].array ?? []
        let index = rows.firstIndex { $0["id"].string == id }
        let before = index.map { rows[$0] } ?? .null
        if let index { rows[index] = .object(row) } else { rows.append(.object(row)) }
        history.append(.object(["id": .string(UUID().uuidString), "rfiID": .string(id), "action": .string(action),
                                "author": .string(author), "at": .string(now), "reason": .string(reason), "before": before, "after": .object(row)]))
        object["rfis"] = .array(rows); object["rfiHistory"] = .array(history)
        object["qa"] = .array(root["qa"].array!.map { entry in
            var gate = entry.object!; gate["status"] = .string("Open"); gate["reviewer"] = .string(""); gate["date"] = .string("")
            return .object(gate)
        })
        self = try ProjectDocument(data: JSONEncoder().encode(JSONValue.object(object)))
    }

    func validateRFIWorkflow() throws {
        let history = root["rfiHistory"]
        if history != .null { try require(history.array != nil, "Invalid RFI history.") }
        for row in root["rfis"].array ?? [] where row["workflowVersion"] != .null {
            try require(row["workflowVersion"].number == 1, "Unsupported RFI workflow version.")
            if row["communicationVersion"] != .null {
                try require(row["communicationVersion"].number == 1, "Unsupported RFI communication version.")
                for field in RFICommunication.fields { try require(row[field.id].string != nil, "Missing RFI \(field.label) text.") }
                try RFICommunication(to: row["to"].string!, from: row["from"].string!, date: row["date"].string!, requiredResponseDate: row["requiredResponseDate"].string!, suggestedResolution: row["suggestedResolution"].string!).validate()
            }
            for key in ["title", "question", "source", "impact", "updatedBy", "updatedAt"] {
                try require(!(row[key].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Missing RFI \(key).")
            }
            try require(["Open", "Resolved"].contains(row["status"].string ?? ""), "Invalid RFI lifecycle.")
            if row["status"].string == "Resolved" {
                for key in ["response", "responseSource", "resolvedBy", "resolvedDate"] {
                    try require(!(row[key].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Resolved RFI requires \(key).")
                }
            }
            // Links remain as historical identities if a drawing action later removes a takeoff row.
            guard let links = row["itemIDs"].array else { throw LoadSightError.invalid("Missing RFI item links.") }
            try require(links.allSatisfy { $0.string != nil } && Set(links.compactMap(\.string)).count == links.count, "Invalid RFI item links.")
            let latest = history.array?.last { $0["rfiID"] == row["id"] }
            try require(latest?["after"] == row, "RFI differs from its saved history.")
        }
    }
}
