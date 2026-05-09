struct QuickBooksFaultError: Codable {
    let Message: String
    let Detail: String

    private enum CodingKeys: String, CodingKey {
        case Message, Detail, message, detail
    }

    init(Message: String, Detail: String) {
        self.Message = Message
        self.Detail = Detail
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let upperMessage = try container.decodeIfPresent(String.self, forKey: .Message)
        let lowerMessage = try container.decodeIfPresent(String.self, forKey: .message)
        let upperDetail = try container.decodeIfPresent(String.self, forKey: .Detail)
        let lowerDetail = try container.decodeIfPresent(String.self, forKey: .detail)
        self.Message = upperMessage ?? lowerMessage ?? "Unknown"
        self.Detail = upperDetail ?? lowerDetail ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Message, forKey: .Message)
        try container.encode(Detail, forKey: .Detail)
    }
}

