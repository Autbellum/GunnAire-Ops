import Foundation

public extension ProjectDocument {
    func changeOrderReview() throws -> JSONValue {
        try validatePortableProject()
        return .array(try changeOrderReadSnapshot().map { entry in
            .object(["editFingerprint": .string(entry.editFingerprint),
                     "history": .array(entry.history), "record": entry.rawRecord,
                     "review": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(entry.record.draft.review()))])
        })
    }
}
