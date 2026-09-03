import Foundation

/// Explicit `Codable` for message content.
///
/// The synthesized enum encoding would work, but stored content is a persistence
/// format — it has to stay readable and stable as cases are added. So each segment
/// encodes as a flat object with a `type` discriminator, which is also what makes
/// the raw-content inspector legible.
public extension MessageSegment {
    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case userID = "user_id"
        case id
        case name
        case asset
        case duration
        case messageID = "message_id"
        case nodes
        case originalType = "original_type"
        case payload
    }

    private enum Kind: String, Codable {
        case text, mention, face, image, record, video, file, reply, poke, forward, unsupported
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try container.decode(String.self, forKey: .type)

        guard let kind = Kind(rawValue: rawType) else {
            // Written by a newer build: keep it rather than fail the whole message.
            self = .unsupported(type: rawType, payload: .null)
            return
        }

        switch kind {
        case .text:
            self = .text(try container.decodeIfPresent(String.self, forKey: .text) ?? "")
        case .mention:
            self = .mention(userID: try container.decodeIfPresent(String.self, forKey: .userID))
        case .face:
            self = .face(
                id: try container.decode(String.self, forKey: .id),
                name: try container.decodeIfPresent(String.self, forKey: .name)
            )
        case .image:
            self = .image(try container.decode(Asset.self, forKey: .asset))
        case .record:
            self = .record(
                try container.decode(Asset.self, forKey: .asset),
                duration: try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
            )
        case .video:
            self = .video(try container.decode(Asset.self, forKey: .asset))
        case .file:
            self = .file(try container.decode(Asset.self, forKey: .asset))
        case .reply:
            self = .reply(messageID: try container.decode(String.self, forKey: .messageID))
        case .poke:
            self = .poke(userID: try container.decodeIfPresent(String.self, forKey: .userID))
        case .forward:
            self = .forward(
                id: try container.decodeIfPresent(String.self, forKey: .id) ?? "",
                nodes: try container.decodeIfPresent([ForwardNode].self, forKey: .nodes) ?? []
            )
        case .unsupported:
            self = .unsupported(
                type: try container.decodeIfPresent(String.self, forKey: .originalType) ?? "unknown",
                payload: try container.decodeIfPresent(JSONValue.self, forKey: .payload) ?? .null
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(text):
            try container.encode(Kind.text, forKey: .type)
            try container.encode(text, forKey: .text)
        case let .mention(userID):
            try container.encode(Kind.mention, forKey: .type)
            try container.encodeIfPresent(userID, forKey: .userID)
        case let .face(id, name):
            try container.encode(Kind.face, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(name, forKey: .name)
        case let .image(asset):
            try container.encode(Kind.image, forKey: .type)
            try container.encode(asset, forKey: .asset)
        case let .record(asset, duration):
            try container.encode(Kind.record, forKey: .type)
            try container.encode(asset, forKey: .asset)
            try container.encodeIfPresent(duration, forKey: .duration)
        case let .video(asset):
            try container.encode(Kind.video, forKey: .type)
            try container.encode(asset, forKey: .asset)
        case let .file(asset):
            try container.encode(Kind.file, forKey: .type)
            try container.encode(asset, forKey: .asset)
        case let .reply(messageID):
            try container.encode(Kind.reply, forKey: .type)
            try container.encode(messageID, forKey: .messageID)
        case let .poke(userID):
            try container.encode(Kind.poke, forKey: .type)
            try container.encodeIfPresent(userID, forKey: .userID)
        case let .forward(id, nodes):
            try container.encode(Kind.forward, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(nodes, forKey: .nodes)
        case let .unsupported(type, payload):
            try container.encode(Kind.unsupported, forKey: .type)
            try container.encode(type, forKey: .originalType)
            try container.encode(payload, forKey: .payload)
        }
    }
}

/// Flat `{kind, value}` encoding for an asset's origin, so the stored form does
/// not depend on Swift's synthesized enum layout.
public extension Asset.Source {
    private enum CodingKeys: String, CodingKey {
        case kind, value
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        let value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        switch kind {
        case "local": self = .local(path: value)
        case "remote": self = .remote(url: value)
        default: self = .inline
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .local(path):
            try container.encode("local", forKey: .kind)
            try container.encode(path, forKey: .value)
        case let .remote(url):
            try container.encode("remote", forKey: .kind)
            try container.encode(url, forKey: .value)
        case .inline:
            try container.encode("inline", forKey: .kind)
        }
    }
}
