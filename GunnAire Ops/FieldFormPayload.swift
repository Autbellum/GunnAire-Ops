import Foundation

/// Bounded, duplicate-key-aware JSON for saved field evidence. Foundation's
/// object decoding alone can discard duplicate keys before validation sees them.
/// This parser never rewrites the stored string or coerces numbers into booleans.
indirect enum FieldFormJSON {
    case object([String: FieldFormJSON]), array([FieldFormJSON])
    case string(String), number(String), flag(Bool), null

    enum Invalid: Error { case payload }

    static func parse(_ text: String, maximumNodes: Int = 20_000) throws -> Self {
        guard text.utf8.count <= 1_048_576, (1...100_000).contains(maximumNodes) else { throw Invalid.payload }
        var reader = Reader(bytes: Array(text.utf8), maximumNodes: maximumNodes)
        let result = try reader.value(depth: 0)
        reader.whitespace()
        guard reader.index == reader.bytes.count else { throw Invalid.payload }
        return result
    }

    func object(keys: Set<String>) throws -> [String: Self] {
        guard case .object(let fields) = self, Set(fields.keys) == keys else { throw Invalid.payload }
        return fields
    }
    func array() throws -> [Self] {
        guard case .array(let values) = self else { throw Invalid.payload }; return values
    }
    func string() throws -> String {
        guard case .string(let value) = self, !value.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw Invalid.payload
        }
        return value
    }
    func flag() throws -> Bool {
        guard case .flag(let value) = self else { throw Invalid.payload }; return value
    }

    private struct Reader {
        let bytes: [UInt8]
        let maximumNodes: Int
        var index = 0
        var nodes = 0
        var current: UInt8? { index < bytes.count ? bytes[index] : nil }

        mutating func whitespace() {
            while let byte = current, [9, 10, 13, 32].contains(byte) { index += 1 }
        }
        mutating func take(_ byte: UInt8) throws {
            guard current == byte else { throw Invalid.payload }; index += 1
        }
        mutating func value(depth: Int) throws -> FieldFormJSON {
            nodes += 1
            guard depth <= 16, nodes <= maximumNodes else { throw Invalid.payload }
            whitespace()
            switch current {
            case 123:
                index += 1; whitespace()
                var fields: [String: FieldFormJSON] = [:]
                if current == 125 { index += 1; return .object(fields) }
                while true {
                    whitespace()
                    let key = try quoted()
                    guard fields[key] == nil else { throw Invalid.payload }
                    whitespace(); try take(58)
                    fields[key] = try value(depth: depth + 1)
                    whitespace()
                    if current == 125 { index += 1; return .object(fields) }
                    try take(44)
                }
            case 91:
                index += 1; whitespace()
                var values: [FieldFormJSON] = []
                if current == 93 { index += 1; return .array(values) }
                while true {
                    values.append(try value(depth: depth + 1)); whitespace()
                    if current == 93 { index += 1; return .array(values) }
                    try take(44)
                }
            case 34: return .string(try quoted())
            case 116: try literal("true"); return .flag(true)
            case 102: try literal("false"); return .flag(false)
            case 110: try literal("null"); return .null
            default:
                let start = index
                while let byte = current, ![9, 10, 13, 32, 44, 93, 125].contains(byte) { index += 1 }
                let token = String(decoding: bytes[start..<index], as: UTF8.self)
                guard token.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#,
                                  options: .regularExpression) != nil else { throw Invalid.payload }
                return .number(token)
            }
        }
        mutating func literal(_ text: String) throws {
            for byte in text.utf8 { try take(byte) }
        }
        mutating func quoted() throws -> String {
            let start = index
            try take(34)
            while let byte = current {
                index += 1
                if byte == 34 {
                    return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
                }
                if byte == 92 {
                    guard current != nil else { throw Invalid.payload }
                    index += 1
                }
            }
            throw Invalid.payload
        }
    }
}

enum FieldFormPayload {
    typealias Invalid = FieldFormJSON.Invalid
    struct Assignment {
        let serviceTypes: Set<ServiceCallType>
        let required: Bool
        let isLegacy: Bool
    }
    nonisolated struct Snapshot: Codable, Sendable {
        let version: Int
        let rows: [FieldFormAnswerRow]
        let questions: [FieldFormQuestion]?
    }
    enum Response {
        case snapshot(Snapshot), legacy([UUID: String])

        var answers: [UUID: String] {
            switch self {
            case .snapshot(let snapshot):
                // The decoder rejects duplicate UUIDs before this point.
                return Dictionary(uniqueKeysWithValues: snapshot.rows.map { ($0.questionID, $0.answer) })
            case .legacy(let answers): return answers
            }
        }
    }

    static func questions(_ text: String) throws -> [FieldFormQuestion] {
        try questions(FieldFormJSON.parse(text))
    }
    private static func questions(_ json: FieldFormJSON) throws -> [FieldFormQuestion] {
        var seen = Set<UUID>()
        return try json.array().map { value in
            let fields = try value.object(keys: ["id", "label", "kind", "required", "choices"])
            guard let id = UUID(uuidString: try fields["id"]!.string()), seen.insert(id).inserted,
                  let kind = FieldFormQuestionKind(rawValue: try fields["kind"]!.string()) else { throw Invalid.payload }
            let label = try fields["label"]!.string()
            guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Invalid.payload }
            let choices = try fields["choices"]!.array().map { try $0.string() }
            if kind == .choice {
                guard choices.count >= 2,
                      FieldFormTemplatePolicy.normalizedChoices(choices).count == choices.count else { throw Invalid.payload }
            } else if !choices.isEmpty { throw Invalid.payload }
            return FieldFormQuestion(id: id, label: label, kind: kind,
                                     required: try fields["required"]!.flag(), choices: choices)
        }
    }

    static func assignment(_ text: String?) throws -> Assignment {
        guard let text else { return Assignment(serviceTypes: [], required: false, isLegacy: true) }
        let json = try FieldFormJSON.parse(text)
        let raw: [FieldFormJSON]
        let required: Bool
        let legacy: Bool
        if case .array(let values) = json {
            raw = values; required = false; legacy = true
        } else {
            let fields = try json.object(keys: ["version", "serviceTypes", "requiredForCloseout"])
            guard case .number("1") = fields["version"]! else { throw Invalid.payload }
            raw = try fields["serviceTypes"]!.array()
            required = try fields["requiredForCloseout"]!.flag(); legacy = false
        }
        var types = Set<ServiceCallType>()
        for value in raw {
            guard let type = ServiceCallType(rawValue: try value.string()), types.insert(type).inserted else {
                throw Invalid.payload
            }
        }
        return Assignment(serviceTypes: types, required: required, isLegacy: legacy)
    }

    static func response(_ text: String) throws -> Response {
        let json = try FieldFormJSON.parse(text)
        if case .array(let values) = json {
            // JSONEncoder's historical [UUID: String] format is an alternating
            // key/value array, not a string-keyed JSON object.
            guard values.count.isMultiple(of: 2) else { throw Invalid.payload }
            var answers: [UUID: String] = [:]
            for index in stride(from: 0, to: values.count, by: 2) {
                guard let id = UUID(uuidString: try values[index].string()), answers[id] == nil else { throw Invalid.payload }
                answers[id] = try values[index + 1].string()
            }
            return .legacy(answers)
        }
        if case .object(let fields) = json, fields.isEmpty { return .legacy([:]) }
        guard case .object(let raw) = json else { throw Invalid.payload }
        let version: Int
        let capturedQuestions: [FieldFormQuestion]?
        switch raw["version"] {
        case .number("1")?:
            _ = try json.object(keys: ["version", "rows"])
            version = 1; capturedQuestions = nil
        case .number("2")?:
            _ = try json.object(keys: ["version", "rows", "questions"])
            version = 2; capturedQuestions = try questions(raw["questions"]!)
        default: throw Invalid.payload
        }
        var seen = Set<UUID>()
        let rows = try raw["rows"]!.array().map { value -> FieldFormAnswerRow in
            let fields = try value.object(keys: ["questionID", "label", "kind", "required", "answer"])
            guard let id = UUID(uuidString: try fields["questionID"]!.string()), seen.insert(id).inserted,
                  let kind = FieldFormQuestionKind(rawValue: try fields["kind"]!.string()) else { throw Invalid.payload }
            let label = try fields["label"]!.string()
            let answer = try fields["answer"]!.string()
            guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  kind != .toggle || ["", "true", "false"].contains(answer) else { throw Invalid.payload }
            return FieldFormAnswerRow(questionID: id, label: label, kind: kind,
                                      required: try fields["required"]!.flag(), answer: answer)
        }
        let result = Response.snapshot(Snapshot(version: version, rows: rows, questions: capturedQuestions))
        if let capturedQuestions { try validate(result, against: capturedQuestions) }
        return result
    }

    /// Structural/history validation is distinct from completion: unfinished
    /// records remain representable, but cannot satisfy required closeout checks.
    static func validate(_ response: Response, against questions: [FieldFormQuestion]) throws {
        let answers = response.answers
        guard Set(answers.keys).isSubset(of: Set(questions.map(\.id))) else { throw Invalid.payload }
        if case .snapshot(let snapshot) = response {
            guard snapshot.rows.count == questions.count else { throw Invalid.payload }
            for (row, question) in zip(snapshot.rows, questions) {
                guard row.questionID == question.id, row.label == question.label,
                      row.kind == question.kind, row.required == question.required else { throw Invalid.payload }
            }
            if let captured = snapshot.questions, captured != questions { throw Invalid.payload }
        }
        for question in questions {
            let answer = answers[question.id] ?? ""
            if question.kind == .toggle, !["", "true", "false"].contains(answer) { throw Invalid.payload }
            if question.kind == .choice, !answer.isEmpty, !question.choices.contains(answer) { throw Invalid.payload }
        }
    }
}
