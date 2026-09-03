import Foundation
import MatchaCore
import MatchaProtocol

/// Segment translation for Milky.
///
/// Milky splits its vocabulary by direction, which OneBot does not: `IncomingSegment`
/// has 14 cases carrying `resource_id` plus a `temp_url` and dimensions, while
/// `OutgoingSegment` has 9 and addresses media by a single `uri` accepting
/// `file://`, `http(s)://`, or `base64://`. Several incoming kinds — `file`, `xml`,
/// `markdown`, `market_face` — have no outgoing form at all.
///
/// The asymmetry runs the other way for forwards: incoming is a `forward_id` to
/// resolve later, outgoing is the full message list inline. Encoding is therefore
/// two distinct functions rather than one with a flag, because they are genuinely
/// different mappings.
struct MilkySegmentCoder: Sendable {
    let assetResolver: MilkyAssetResolver

    // MARK: - Outbound: domain -> IncomingSegment
    //
    // Named for Milky's perspective: what Matcha sends is what the framework
    // *receives*, so an event's segments use the incoming vocabulary.

    func encodeIncoming(_ content: [MessageSegment]) async -> [JSONValue] {
        var result: [JSONValue] = []
        for segment in content {
            if let encoded = await encodeIncoming(segment) {
                result.append(encoded)
            }
        }
        return result
    }

    private func encodeIncoming(_ segment: MessageSegment) async -> JSONValue? {
        switch segment {
        case let .text(text):
            return Self.segment("text", ["text": .string(text)])

        case let .mention(userID):
            guard let userID else { return Self.segment("mention_all", [:]) }
            let name = await assetResolver.displayName(for: userID)
            return Self.segment("mention", [
                "user_id": uin(userID),
                // Since 1.2, with the leading "@" stripped.
                "name": .string(name),
            ])

        case let .face(id, _):
            return Self.segment("face", ["face_id": .string(id), "is_large": false])

        case let .image(asset):
            let resource = await assetResolver.resource(for: asset)
            return Self.segment("image", [
                "resource_id": .string(resource.resourceID),
                "temp_url": .string(resource.tempURL),
                "width": .number(Double(resource.width ?? 0)),
                "height": .number(Double(resource.height ?? 0)),
                "summary": .string(asset.name),
                "sub_type": "normal",
            ])

        case let .record(asset, duration):
            let resource = await assetResolver.resource(for: asset)
            return Self.segment("record", [
                "resource_id": .string(resource.resourceID),
                "temp_url": .string(resource.tempURL),
                "duration": MilkyEntityEncoder.seconds(duration ?? 0),
            ])

        case let .video(asset):
            let resource = await assetResolver.resource(for: asset)
            return Self.segment("video", [
                "resource_id": .string(resource.resourceID),
                "temp_url": .string(resource.tempURL),
                "width": .number(Double(resource.width ?? 0)),
                "height": .number(Double(resource.height ?? 0)),
                "duration": 0,
            ])

        case let .file(asset):
            return Self.segment("file", [
                "file_id": .string(asset.id),
                "file_name": .string(asset.name),
                "file_size": .number(Double(asset.byteCount)),
            ])

        case let .reply(messageID):
            // Milky keys replies by sequence, not by message ID, so the referenced
            // message has to be looked up.
            guard let reference = await assetResolver.replyReference(messageID: messageID) else {
                return nil
            }
            return Self.segment("reply", [
                "message_seq": .number(Double(reference.seq)),
                "sender_id": uin(reference.senderID),
                "time": MilkyEntityEncoder.timestamp(reference.time),
                "segments": .array(await encodeIncoming(reference.content)),
            ])

        case .poke:
            // Nudges are events in Milky (`friend_nudge`/`group_nudge`), never
            // segments.
            return nil

        case let .forward(id, nodes):
            return Self.segment("forward", [
                "forward_id": .string(id),
                "title": "Forwarded messages",
                "preview": .array(nodes.prefix(4).map { node in
                    .string("\(node.senderName): \(node.content.textPreview)")
                }),
                "summary": .string("View \(nodes.count) forwarded messages"),
            ])

        case let .unsupported(type, payload):
            // The spec tells clients to downgrade unknown segments to text, so
            // sending one they may not know is safe, but a readable placeholder is
            // more useful than a type name they will render verbatim.
            _ = payload
            return Self.segment("text", ["text": .string("[\(type)]")])
        }
    }

    // MARK: - Inbound: OutgoingSegment -> domain

    func decodeOutgoing(_ segments: [JSONValue]) async -> [MessageSegment] {
        var result: [MessageSegment] = []
        for raw in segments {
            if let decoded = await decodeOutgoing(raw) {
                result.append(decoded)
            }
        }
        return result
    }

    private func decodeOutgoing(_ raw: JSONValue) async -> MessageSegment? {
        guard let type = raw["type"]?.stringValue else { return nil }
        let data = raw["data"] ?? .object([:])

        switch type {
        case "text":
            return .text(data["text"]?.stringValue ?? "")

        case "mention":
            return .mention(userID: data["user_id"]?.stringValue)

        case "mention_all":
            return .mention(userID: nil)

        case "face":
            guard let id = data["face_id"]?.stringValue else { return nil }
            return .face(id: id, name: nil)

        case "image":
            guard let asset = await ingest(data, kind: .image) else { return nil }
            return .image(asset)

        case "record":
            guard let asset = await ingest(data, kind: .record) else { return nil }
            return .record(asset, duration: nil)

        case "video":
            guard let asset = await ingest(data, kind: .video) else { return nil }
            return .video(asset)

        case "reply":
            // The framework quotes a sequence number; resolve it to a message ID.
            guard let seq = data["message_seq"]?.int64Value else { return nil }
            guard let messageID = await assetResolver.messageID(forSeq: seq) else { return nil }
            return .reply(messageID: messageID)

        case "forward":
            return await decodeForward(data)

        case "light_app":
            return .unsupported(type: "light_app", payload: data)

        default:
            return .unsupported(type: type, payload: raw)
        }
    }

    /// Outgoing forwards arrive inline, so the nodes are built directly rather than
    /// stored behind an ID.
    private func decodeForward(_ data: JSONValue) async -> MessageSegment? {
        guard let messages = data["messages"]?.arrayValue else { return nil }
        var nodes: [MessageSegment.ForwardNode] = []
        for entry in messages {
            guard let senderID = entry["user_id"]?.stringValue else { continue }
            let time = entry["time"]?.doubleValue
            nodes.append(
                MessageSegment.ForwardNode(
                    senderID: senderID,
                    senderName: entry["sender_name"]?.stringValue ?? senderID,
                    time: time.map { Date(timeIntervalSince1970: $0) } ?? .now,
                    content: await decodeOutgoing(entry["segments"]?.arrayValue ?? [])
                )
            )
        }
        return .forward(id: IDGenerator.messageID(), nodes: nodes)
    }

    private func ingest(_ data: JSONValue, kind: AssetKind) async -> Asset? {
        guard let uri = data["uri"]?.stringValue else { return nil }
        return await assetResolver.ingest(uri: uri, kind: kind)
    }

    // MARK: - Helpers

    private static func segment(_ type: String, _ data: [String: JSONValue]) -> JSONValue {
        ["type": .string(type), "data": .object(data)]
    }

    /// Milky types account and group numbers as integers in the range
    /// 10001…4294967295, so IDs go on the wire as numbers.
    private func uin(_ value: String) -> JSONValue {
        guard let number = Int64(value) else { return .string(value) }
        return .number(Double(number))
    }
}

/// What a media segment carries.
public enum AssetKind: String, Sendable {
    case image, record, video, file
}

/// Resolves media and cross-references for the Milky protocol implementation.
public protocol MilkyAssetResolver: Sendable {
    /// A stored asset as Milky's incoming media fields describe it.
    func resource(for asset: Asset) async -> MilkyResource

    /// Ingests an outgoing `uri` — `file://`, `http(s)://`, or `base64://`.
    func ingest(uri: String, kind: AssetKind) async -> Asset?

    /// The display name to put in a mention segment.
    func displayName(for userID: String) async -> String

    /// Details of a quoted message, for building a reply segment.
    func replyReference(messageID: String) async -> MilkyReplyReference?

    /// Maps a sequence number back to a message ID.
    func messageID(forSeq seq: Int64) async -> String?
}

/// An asset as Milky's incoming segments describe it.
public struct MilkyResource: Sendable {
    public var resourceID: String
    public var tempURL: String
    public var width: Int?
    public var height: Int?

    public init(resourceID: String, tempURL: String, width: Int? = nil, height: Int? = nil) {
        self.resourceID = resourceID
        self.tempURL = tempURL
        self.width = width
        self.height = height
    }
}

/// The parts of a quoted message a Milky reply segment carries.
public struct MilkyReplyReference: Sendable {
    public var seq: Int64
    public var senderID: String
    public var time: Date
    public var content: [MessageSegment]

    public init(seq: Int64, senderID: String, time: Date, content: [MessageSegment]) {
        self.seq = seq
        self.senderID = senderID
        self.time = time
        self.content = content
    }
}
