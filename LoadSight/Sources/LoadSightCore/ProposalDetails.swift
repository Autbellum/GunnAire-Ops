import Foundation

public struct ProposalField: Identifiable, Sendable {
    public let id: String
    public let label: String
}
public enum ProposalDetails {
    public static let fields: [ProposalField] = [
        .init(id: "address", label: "Project address"),
        .init(id: "scopeOfWork", label: "Scope of work"),
        .init(id: "inclusions", label: "Inclusions"),
        .init(id: "exclusions", label: "Exclusions and trade boundaries"),
        .init(id: "assumptions", label: "Assumptions"),
        .init(id: "alternates", label: "Alternates and acceptance conditions"),
        .init(id: "bonds", label: "Bonds and related cost basis"),
        .init(id: "schedule", label: "Schedule and access constraints"),
        .init(id: "leadTimes", label: "Lead times and quote sources"),
        .init(id: "validity", label: "Proposal validity"),
        .init(id: "addendaBasis", label: "Accepted addenda and drawing basis"),
        .init(id: "attachments", label: "Attachment references")
    ]
    public static func missingFields(in project: ProjectDocument) -> [ProposalField] {
        fields.filter { (project.root["proposalDetails"][$0.id].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
public extension ProjectDocument {
    /// Narratives record supplied terms; they never modify calculated prices or trade quantities.
    mutating func updateProposalDetails(_ fields: [String: String], author: String, source: String) throws {
        try require(Set(fields.keys).isSubset(of: Set(ProposalDetails.fields.map(\.id))), "Unsupported proposal field.")
        try require(!author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Record the proposal author.")
        try require(!source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Record the source or reason for these proposal terms.")
        var details = root["proposalDetails"].object ?? [:]
        let before: JSONValue = .object(details)
        for (key, value) in fields { details[key] = .string(value) }
        let after: JSONValue = .object(details)
        guard before != after else { return }
        var object = root.object!, history = root["proposalHistory"].array ?? []
        history.append(.object(["id": .string(UUID().uuidString), "author": .string(author), "at": .string(Date().ISO8601Format()),
                                "source": .string(source), "before": before, "after": after]))
        object["proposalDetails"] = after; object["proposalHistory"] = .array(history)
        object["qa"] = .array(root["qa"].array!.map { entry in
            var gate = entry.object!; gate["status"] = .string("Open"); gate["reviewer"] = .string(""); gate["date"] = .string("")
            return .object(gate)
        })
        self = try ProjectDocument(data: JSONEncoder().encode(JSONValue.object(object)))
    }
}
