import Foundation

/// Only documented optional fields accept both an omitted key and JSON null.
/// All other keys, enum payloads, numbers and duplicate-key checks stay closed.
enum StaffOwnerFieldEditWire {
    static func decode<T: Codable>(_ type: T.Type, from bytes: Data,
                                   maximum: Int = StaffOwnerFieldEditTransport.maximumResponseBytes) throws -> T {
        try StaffWorkspacePublicationContract.validateJSON(bytes, maximum: maximum)
        let value = try JSONDecoder().decode(type, from: bytes)
        let original = try normalize(JSONSerialization.jsonObject(with: bytes), type: type)
        let encoded = try normalize(JSONSerialization.jsonObject(with: StaffWorkspacePublicationContract.encode(value)), type: type)
        guard try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys]) ==
                JSONSerialization.data(withJSONObject: encoded, options: [.sortedKeys]) else { throw StaffReplicaSourceSyncError.invalid }
        return value
    }
    private static func omitNull(_ names: [String], in value: inout [String: Any]) {
        for name in names where value[name] is NSNull { value.removeValue(forKey: name) }
    }
    private static func application(_ raw: Any) -> Any {
        guard var value = raw as? [String: Any] else { return raw }
        omitNull(["publishedAt"], in: &value)
        return value
    }
    private static func edit(_ raw: Any) -> Any {
        guard var value = raw as? [String: Any] else { return raw }
        omitNull(["current", "application", "resolution"], in: &value)
        if let receipt = value["application"] { value["application"] = application(receipt) }
        return value
    }
    private static func normalize<T>(_ raw: Any, type: T.Type) throws -> Any {
        if type == StaffOwnerFieldEdit.self { return edit(raw) }
        if type == StaffOwnerFieldEditApplication.self { return application(raw) }
        if type == StaffOwnerFieldEditResolution.self || type == StaffOwnerFieldObservationReceipt.self { return raw }
        guard var value = raw as? [String: Any] else { throw StaffReplicaSourceSyncError.invalid }
        if type == StaffOwnerFieldEditPage.self {
            omitNull(["nextCursor"], in: &value)
        } else if type == StaffOwnerFieldEditJournal.self {
            omitNull(["after", "lastAttempted", "keepOffice", "observations"], in: &value)
            if var pending = value["pending"] as? [String: Any] {
                for (id, rawItem) in pending {
                    guard var item = rawItem as? [String: Any] else { continue }
                    omitNull(["application"], in: &item)
                    if let original = item["edit"] { item["edit"] = edit(original) }
                    if let receipt = item["application"] { item["application"] = application(receipt) }
                    pending[id] = item
                }
                value["pending"] = pending
            }
            for key in ["keepOffice", "observations"] {
              if var pending = value[key] as? [String: Any] {
                for (id, rawItem) in pending {
                    guard var item = rawItem as? [String: Any] else { continue }
                    if let original = item["edit"] { item["edit"] = edit(original) }
                    pending[id] = item
                }
                value[key] = pending
              }
            }
        } else { throw StaffReplicaSourceSyncError.invalid }
        return value
    }
}
