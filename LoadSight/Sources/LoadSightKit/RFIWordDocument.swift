import Foundation

/// Editable review copy. Exporting neither transmits nor resolves the request.
public enum RFIWordDocument {
    public static func docx(_ project: ProjectDocument, rfiID: String, generatedAt: Date = Date()) throws -> Data {
        try require(generatedAt.timeIntervalSince1970.isFinite, "RFI generation time must be finite.")
        try project.validatePortableProject()
        let matches = (project.root["rfis"].array ?? []).filter { $0["id"].string == rfiID }
        try require(matches.count == 1, "Select one existing RFI to export.")
        let row = matches[0]
        var paragraphs: [(String, String)] = []
        func add(_ text: String, _ style: String = "Normal") { paragraphs.append((text, style)) }
        func value(_ entry: JSONValue) -> String {
            guard let text = entry.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Not recorded" }
            return text
        }
        func field(_ label: String, _ entry: JSONValue) { add(label + ": " + value(entry), "Metadata") }
        add("Request for information", "Title")
        add(project.name, "Subtitle")
        add("Review copy", "Emphasis")
        field("RFI", row["id"]); field("Subject", row["title"])
        add("Status: \(value(row["status"]))    Priority: \(value(row["priority"]))", "Metadata")
        field("Customer", project.root["inputs"]["customer"])
        add("To: \(value(row["to"]))    From: \(value(row["from"]))", "Metadata")
        add("Request date: \(value(row["date"]))    Required response date: \(value(row["requiredResponseDate"]))", "Metadata")
        add("Recorded by: \(value(row["updatedBy"]))    Last updated: \(value(row["updatedAt"]))", "Metadata")
        add("Question", "Heading1"); add(value(row["question"]))
        add("Drawing and specification source", "Heading1"); add(value(row["source"]))
        add("Scope cost and schedule impact", "Heading1"); add(value(row["impact"]))
        add("Suggested resolution", "Heading1"); add(value(row["suggestedResolution"]))
        add("Recorded response", "Heading1")
        add(value(row["response"]))
        field("Answered by", row["resolvedBy"]); field("Answer source", row["responseSource"])
        field("Answer date", row["resolvedDate"])
        add("An RFI response does not authorize a change in contract price or scope. Review affected quantities and commercial terms separately.")
        let links = row["itemIDs"].array ?? []
        if !links.isEmpty {
            add("Affected takeoff items", "Heading1")
            for link in links {
                if let item = project.items.first(where: { $0["id"] == link }) {
                    add(value(link) + " — " + value(item["description"] ?? .null))
                    let quantity = item["quantity"]?.number.map { String($0) } ?? "Unknown"
                    add("Quantity: \(quantity) \(value(item["unit"] ?? .null))\nSource: \(value(item["source"] ?? .null))")
                } else { add(value(link) + " — Item no longer present in the current takeoff") }
            }
        }
        let attachments = try project.attachments().flatMap { record in
            record.references.filter { $0.rfiID == rfiID }.map { (record.id, $0) }
        }
        if !attachments.isEmpty {
            add("Referenced attachments", "Heading1")
            add("The following files are referenced by this RFI. Their file contents are not embedded in this Word document.")
            for (id, reference) in attachments {
                add(reference.filename + "\nSource: " + reference.source + "\nRecorded by: " + reference.author)
                add("SHA256: " + id, "Small")
            }
        }
        add("Record basis", "Heading1")
        add("Exported " + generatedAt.ISO8601Format(), "Small")
        add("Project review fingerprint: " + (try project.qaFingerprint()), "Small")
        add("This copy reflects the saved project record at export time. Editing this Word document does not update the project or its recorded workflow.", "Small")
        let history = (project.root["rfiHistory"].array ?? []).filter { $0["rfiID"].string == rfiID }
        if !history.isEmpty {
            add("Recorded history", "HistoryHeading")
            for (index, event) in history.enumerated() {
                add("Change \(index + 1)", "Heading2")
                add("\(value(event["action"])) by \(value(event["author"])) on \(value(event["at"]))")
                field("Reason", event["reason"])
                // Both snapshots retain earlier answers when a resolved question is reopened.
                for key in ["before", "after"] where event[key] != .null {
                    add(key == "before" ? "Before this change" : "After this change", "Emphasis")
                    for (label, fieldName) in [("Status", "status"), ("Subject", "title"), ("Question", "question"), ("Source", "source"), ("Impact", "impact"), ("Response", "response"), ("Answered by", "resolvedBy"), ("Answer source", "responseSource")] {
                        field(label, event[key][fieldName])
                    }
                    for entry in RFICommunication.fields where event[key][entry.id] != .null {
                        field(entry.label, event[key][entry.id])
                    }
                }
            }
        }
        return try WordPackage.encode(paragraphs)
    }
}
