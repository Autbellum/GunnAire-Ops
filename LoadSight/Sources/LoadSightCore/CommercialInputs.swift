import Foundation

public extension ProjectDocument {
    static var commercialNumericKeys: [String] { ["laborRate", "markupPct", "taxAllowance", "jobCosts", "contingency"] }

    /// Saves partial commercial inputs. Null remains unknown; zero is an explicit value.
    mutating func updateCommercialInputs(name: String, estimator: String, fields: [String: JSONValue], basis: String, author: String) throws {
        let allowed = Set(Self.commercialNumericKeys + ["customer", "proposalTerms"])
        try require(Set(fields.keys).isSubset(of: allowed), "Unsupported commercial input.")
        try require(!author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Record who changed the estimate assumptions.")
        try require(!basis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Record the source or reason for these commercial assumptions.")
        for key in ["customer", "proposalTerms"] where fields[key] != nil {
            try require(fields[key]?.string != nil, "\(key) must be text.")
        }
        var object = root.object!, inputs = root["inputs"].object!
        let before: JSONValue = .object(["name": root["name"], "reviewer": root["reviewer"], "inputs": root["inputs"]])
        inputs.merge(fields) { _, new in new }
        object["inputs"] = .object(inputs); object["name"] = .string(name); object["reviewer"] = .string(estimator)
        let after: JSONValue = .object(["name": .string(name), "reviewer": .string(estimator), "inputs": .object(inputs)])
        if before == after { return }
        var history = root["commercialHistory"].array ?? []
        history.append(.object(["id": .string(UUID().uuidString), "author": .string(author), "at": .string(Date().ISO8601Format()),
                                "basis": .string(basis), "before": before, "after": after]))
        object["commercialHistory"] = .array(history)
        object["qa"] = .array(root["qa"].array!.map { entry in
            var gate = entry.object!; gate["status"] = .string("Open"); gate["reviewer"] = .string(""); gate["date"] = .string("")
            return .object(gate)
        })
        self = try ProjectDocument(data: JSONEncoder().encode(JSONValue.object(object)))
    }
}
