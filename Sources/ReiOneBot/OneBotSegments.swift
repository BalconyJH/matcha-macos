import Foundation
import ReiCore
import ReiProtocol

/// Segment translation for OneBot.
///
/// v11 and v12 share the `[{type, data}]` envelope but disagree on almost every
/// member: v11 mirrors QQ's own vocabulary (`at`, `record`, `face`) and addresses
/// files by path or URL, while v12 is a deliberately minimal set (`mention`,
/// `voice`) that addresses files by an ID from a prior upload.
///
/// Conversion is not required to be lossless in either direction. A protocol that
/// cannot express a segment drops it, and one that has no matching concept maps to
/// the closest available — recorded here rather than hidden, so the behaviour is
/// legible when a message does not arrive looking the way it was sent.
public enum OneBotVersion: String, Sendable, CaseIterable {
    case v11
    case v12

    /// v11 sends IDs as JSON numbers, v12 as strings.
    var usesNumericIDs: Bool { self == .v11 }

    /// Canonical reverse WebSocket route exposed by NoneBot's OneBot adapter.
    public var noneBotReverseWebSocketPath: String {
        switch self {
        case .v11: return "/onebot/v11/ws"
        case .v12: return "/onebot/v12/ws"
        }
    }
}

public struct OneBotSegmentCoder: Sendable {
    public let version: OneBotVersion
    /// Resolves an asset into the addressing form this protocol version wants.
    public let assetResolver: AssetResolver

    public init(version: OneBotVersion, assetResolver: AssetResolver) {
        self.version = version
        self.assetResolver = assetResolver
    }

    // MARK: - Outbound: domain -> wire

    /// Encodes content for an outgoing event.
    public func encode(_ content: [MessageSegment]) async -> [JSONValue] {
        var result: [JSONValue] = []
        for segment in content {
            if let encoded = await encode(segment) {
                result.append(encoded)
            }
        }
        return result
    }

    private func encode(_ segment: MessageSegment) async -> JSONValue? {
        switch segment {
        case .text(let text):
            return Self.segment("text", ["text": .string(text)])

        case .mention(let userID):
            switch version {
            case .v11:
                // v11 folds "@everyone" into the same segment with a sentinel value.
                return Self.segment("at", ["qq": .string(userID ?? "all")])
            case .v12:
                guard let userID else { return Self.segment("mention_all", [:]) }
                return Self.segment("mention", ["user_id": .string(userID)])
            }

        case .face(let id, _):
            // v12 has no face segment; dropping it loses less than inventing one.
            guard version == .v11 else { return nil }
            return Self.segment("face", ["id": .string(id)])

        case .image(let asset):
            let file = await assetResolver.reference(for: asset, version: version)
            switch version {
            case .v11:
                return Self.segment("image", ["file": .string(file.identifier), "url": .string(file.url)])
            case .v12:
                return Self.segment("image", ["file_id": .string(file.identifier)])
            }

        case .record(let asset, _):
            let file = await assetResolver.reference(for: asset, version: version)
            switch version {
            case .v11:
                return Self.segment("record", ["file": .string(file.identifier), "url": .string(file.url)])
            case .v12:
                return Self.segment("voice", ["file_id": .string(file.identifier)])
            }

        case .video(let asset):
            let file = await assetResolver.reference(for: asset, version: version)
            switch version {
            case .v11:
                return Self.segment("video", ["file": .string(file.identifier), "url": .string(file.url)])
            case .v12:
                return Self.segment("video", ["file_id": .string(file.identifier)])
            }

        case .file(let asset):
            let file = await assetResolver.reference(for: asset, version: version)
            switch version {
            case .v11:
                // v11 has no file segment; name it in text so the message still reads.
                return Self.segment("text", ["text": .string("[File: \(asset.name)]")])
            case .v12:
                return Self.segment("file", ["file_id": .string(file.identifier)])
            }

        case .reply(let messageID):
            switch version {
            case .v11:
                return Self.segment("reply", ["id": .string(messageID)])
            case .v12:
                return Self.segment("reply", ["message_id": .string(messageID)])
            }

        case .poke(let userID):
            guard version == .v11 else { return nil }
            return Self.segment("poke", ["type": "1", "id": .string(userID ?? "0")])

        case .forward(let id, _):
            guard version == .v11 else { return nil }
            return Self.segment("forward", ["id": .string(id)])

        case .unsupported(let type, let payload):
            // Pass through anything a peer sent us that we did not model, so a
            // round-trip does not silently drop it.
            if let object = payload.objectValue, object["type"] != nil {
                return payload
            }
            return Self.segment(type, payload.objectValue ?? [:])
        }
    }

    // MARK: - Inbound: wire -> domain

    /// Decodes segments received from the framework.
    public func decode(_ segments: [JSONValue]) async -> [MessageSegment] {
        var result: [MessageSegment] = []
        for raw in segments {
            if let decoded = await decode(raw) {
                result.append(decoded)
            }
        }
        return result
    }

    private func decode(_ raw: JSONValue) async -> MessageSegment? {
        guard let type = raw["type"]?.stringValue else { return nil }
        let data = raw["data"] ?? .object([:])

        switch type {
        case "text":
            return .text(data["text"]?.stringValue ?? "")

        case "at":
            let target = data["qq"]?.stringValue
            return .mention(userID: target == "all" ? nil : target)

        case "mention":
            return .mention(userID: data["user_id"]?.stringValue)

        case "mention_all":
            return .mention(userID: nil)

        case "face":
            guard let id = data["id"]?.stringValue else { return nil }
            return .face(id: id, name: nil)

        case "image":
            guard let asset = await resolveInboundAsset(data, kind: .image) else { return nil }
            return .image(asset)

        case "record", "voice":
            guard let asset = await resolveInboundAsset(data, kind: .record) else { return nil }
            return .record(asset, duration: data["duration"]?.doubleValue)

        case "video":
            guard let asset = await resolveInboundAsset(data, kind: .video) else { return nil }
            return .video(asset)

        case "file":
            guard let asset = await resolveInboundAsset(data, kind: .file) else { return nil }
            return .file(asset)

        case "reply":
            // v11 keys this `id`, v12 `message_id`.
            guard let id = (data["id"] ?? data["message_id"])?.stringValue else { return nil }
            return .reply(messageID: id)

        case "poke":
            return .poke(userID: data["id"]?.stringValue)

        case "forward":
            return .forward(id: data["id"]?.stringValue ?? "", nodes: [])

        default:
            return .unsupported(type: type, payload: raw)
        }
    }

    private func resolveInboundAsset(_ data: JSONValue, kind: AssetKind) async -> Asset? {
        // v11 supplies a path, URL, or base64 payload under `file`; v12 supplies an
        // ID that an earlier upload action returned.
        if let fileID = data["file_id"]?.stringValue {
            return await assetResolver.asset(forIdentifier: fileID, kind: kind)
        }
        guard let reference = data["file"]?.stringValue else { return nil }
        return await assetResolver.asset(
            forReference: reference,
            url: data["url"]?.stringValue,
            kind: kind
        )
    }

    // MARK: - Helpers

    private static func segment(_ type: String, _ data: [String: JSONValue]) -> JSONValue {
        ["type": .string(type), "data": .object(data)]
    }
}

/// What a media segment carries, for naming and MIME guessing.
public enum AssetKind: String, Sendable {
    case image, record, video, file
}

/// Turns assets into wire references and back.
///
/// Media arrives in whatever form the framework chose and must be served back in
/// whatever form the asking protocol wants, so this indirection keeps that
/// negotiation out of the segment coders.
public protocol AssetResolver: Sendable {
    /// How to address a stored asset in an outgoing segment.
    func reference(for asset: Asset, version: OneBotVersion) async -> AssetReference

    /// Resolves an ID from a previous upload.
    func asset(forIdentifier identifier: String, kind: AssetKind) async -> Asset?

    /// Ingests a path, URL, or `base64://` payload, storing the bytes if needed.
    func asset(forReference reference: String, url: String?, kind: AssetKind) async -> Asset?
}

/// An asset as a peer should see it.
public struct AssetReference: Sendable {
    /// File ID, path, or `base64://` payload, depending on the protocol.
    public var identifier: String
    /// HTTP URL served by Rei's asset server.
    public var url: String

    public init(identifier: String, url: String) {
        self.identifier = identifier
        self.url = url
    }
}
