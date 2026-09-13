import Foundation
import CryptoKit

/// A recorded local Ops snapshot, never an authenticated billing instruction.
public struct OpsCustomerSnapshot: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let address: String
    public init(id: UUID, name: String, address: String) { self.id = id; self.name = name; self.address = address }
}
public struct OpsJobSnapshot: Codable, Equatable, Sendable {
    public let id: UUID
    public let customerID: UUID
    public let title: String
    public let siteAddress: String
    public let serviceLocationID: UUID?
    private enum CodingKeys: String, CodingKey { case id, customerID, title, siteAddress, serviceLocationID }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(customerID, forKey: .customerID)
        try c.encode(title, forKey: .title); try c.encode(siteAddress, forKey: .siteAddress)
        try c.encode(serviceLocationID, forKey: .serviceLocationID)
    }
    public init(id: UUID, customerID: UUID, title: String, siteAddress: String, serviceLocationID: UUID?) {
        self.id = id; self.customerID = customerID; self.title = title; self.siteAddress = siteAddress; self.serviceLocationID = serviceLocationID
    }
}
public struct OpsProjectContext: Codable, Equatable, Sendable, Identifiable {
    public let version: Int
    public let customer: OpsCustomerSnapshot
    public let job: OpsJobSnapshot?
    public var id: String { customer.id.uuidString + "/" + (job?.id.uuidString ?? "customer") }
    private enum CodingKeys: String, CodingKey { case version, customer, job }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version); try c.encode(customer, forKey: .customer)
        try c.encode(job, forKey: .job)
    }
    public init(customer: OpsCustomerSnapshot, job: OpsJobSnapshot? = nil) { version = 1; self.customer = customer; self.job = job }
    public func validate() throws {
        try require(version == 1, "Unsupported Ops context version.")
        try require(!customer.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Ops customer name is required.")
        if let job { try require(job.customerID == customer.id, "The selected Ops job belongs to another customer.") }
    }
}
public struct OpsContextRevision: Codable, Identifiable, Sendable {
    public let id: UUID
    public let author: String
    public let recordedAt: String
    public let reason: String
    public let before: JSONValue
    public let after: JSONValue
    public func context(before useBefore: Bool) throws -> OpsProjectContext? { try decodeOpsContext(useBefore ? before : after) }
}
private func decodeOpsContext(_ value: JSONValue) throws -> OpsProjectContext? {
    if value == .null { return nil }
    let context = try JSONDecoder().decode(OpsProjectContext.self, from: JSONEncoder().encode(value))
    try context.validate()
    return context
}
public extension ProjectDocument {
    func opsContext() throws -> OpsProjectContext? { try decodeOpsContext(root["opsContext"]) }
    func opsContextHistory() throws -> [OpsContextRevision] {
        let raw = root["opsContextHistory"]
        if raw == .null {
            try require(root["opsContext"] == .null, "Ops context requires its recorded link history.")
            return []
        }
        let history = try JSONDecoder().decode([OpsContextRevision].self, from: JSONEncoder().encode(raw))
        try require(Set(history.map(\.id)).count == history.count, "Duplicate Ops link revision IDs.")
        var previous = JSONValue.null
        for revision in history {
            try require(!revision.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !revision.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Ops linking requires a recorded author and reason.")
            try require(ISO8601DateFormatter().date(from: revision.recordedAt) != nil, "Invalid Ops link revision date.")
            _ = try revision.context(before: true); _ = try revision.context(before: false)
            try require(revision.before == previous, "Ops link history has a broken snapshot chain.")
            previous = revision.after
        }
        try require(root["opsContext"] == previous, "Current Ops context differs from its recorded history.")
        return history
    }
    func opsContextEditFingerprint() throws -> String {
        let history = try opsContextHistory()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let value = JSONValue.object(["context": root["opsContext"], "lastRevision": history.last.map { .string($0.id.uuidString) } ?? .null])
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }
    /// Changes project context only; prices, proposal customer and external records are untouched.
    mutating func updateOpsContext(_ context: OpsProjectContext?, expectedFingerprint: String, author: String, reason: String) throws {
        try require(expectedFingerprint == opsContextEditFingerprint(), "The Ops link changed. Reopen its current context before saving; your selection was not applied.")
        try context?.validate()
        try require(context != nil || root["opsContext"] != .null, "There is no Ops link to remove.")
        let after = try context.map { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode($0)) } ?? .null
        let revision = OpsContextRevision(id: UUID(), author: author, recordedAt: Date().ISO8601Format(), reason: reason, before: root["opsContext"], after: after)
        var object = root.object!, history = root["opsContextHistory"].array ?? []
        history.append(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(revision)))
        object["opsContext"] = after; object["opsContextHistory"] = .array(history)
        object["qa"] = .array(root["qa"].array!.map { row in
            var gate = row.object!; gate["status"] = .string("Open"); gate["reviewer"] = .string(""); gate["date"] = .string(""); return .object(gate)
        })
        self = try ProjectDocument(data: JSONEncoder().encode(JSONValue.object(object)))
    }
}
