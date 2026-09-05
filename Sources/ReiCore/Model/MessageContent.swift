import Foundation

/// One piece of a message.
///
/// This is the neutral vocabulary: OneBot's `[{type, data}]` segments and
/// Milky's own segment list both convert to and from these cases. Anything a
/// protocol supports that Rei has no concept of arrives as `.unsupported`,
/// which keeps the raw payload intact for display and for echoing back.
public enum MessageSegment: Hashable, Sendable, Codable {
    case text(String)
    /// A mention. `nil` target means "@everyone".
    case mention(userID: String?)
    case face(id: String, name: String?)
    case image(Asset)
    case record(Asset, duration: TimeInterval?)
    case video(Asset)
    case file(Asset)
    /// A quoted reply to an earlier message.
    case reply(messageID: String)
    /// A nudge/poke aimed at a user.
    case poke(userID: String?)
    /// A merged-forward bundle of previously sent messages.
    case forward(id: String, nodes: [ForwardNode])
    /// A segment this build does not model, kept verbatim.
    case unsupported(type: String, payload: JSONValue)

    /// A single message inside a merged-forward bundle.
    public struct ForwardNode: Hashable, Sendable, Identifiable, Codable {
        public var id: String
        public var senderID: String
        public var senderName: String
        public var time: Date
        public var content: [MessageSegment]

        public init(
            id: String = IDGenerator.messageID(),
            senderID: String,
            senderName: String,
            time: Date = .now,
            content: [MessageSegment]
        ) {
            self.id = id
            self.senderID = senderID
            self.senderName = senderName
            self.time = time
            self.content = content
        }
    }
}

/// A binary attachment.
///
/// Media reaches Rei in whatever form the peer chose — a local path, an HTTP
/// URL, base64 bytes, or a token from an earlier upload — and must be servable
/// back in whatever form the *asking* peer wants. The stored form is normalized
/// to a content-addressed file in the asset store; `source` records where it
/// came from so the UI can explain it.
public struct Asset: Hashable, Sendable, Identifiable, Codable {
    /// SHA-256 of the contents, and the asset store's filename.
    public var id: String
    /// Original filename, when the peer supplied one.
    public var name: String
    public var mimeType: String?
    public var byteCount: Int
    public var source: Source

    public enum Source: Hashable, Sendable, Codable {
        case local(path: String)
        case remote(url: String)
        /// Bytes arrived inline; already written to the asset store.
        case inline
    }

    public init(id: String, name: String, mimeType: String? = nil, byteCount: Int = 0, source: Source) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.source = source
    }
}

// MARK: - Plain text projection

extension MessageSegment {
    /// How the segment reads when a message is flattened to a single line, for
    /// sidebar previews and notifications.
    public var textPreview: String {
        switch self {
        case .text(let t): return t
        case .mention(let userID): return userID == nil ? "@everyone" : "@\(userID!)"
        case .face(_, let name): return name.map { "[\($0)]" } ?? "[Emoji]"
        case .image: return "[Image]"
        case .record: return "[Voice]"
        case .video: return "[Video]"
        case .file(let asset): return "[File: \(asset.name)]"
        case .reply: return ""
        case .poke: return "[Nudge]"
        case .forward: return "[Forwarded messages]"
        case .unsupported(let type, _): return "[\(type)]"
        }
    }
}

extension [MessageSegment] {
    /// Flattened one-line form.
    public var textPreview: String {
        map(\.textPreview).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The concatenated plain text only, ignoring every non-text segment. This is
    /// what a bot framework's command matcher usually looks at.
    public var plainText: String {
        compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
    }

    /// The message this one quotes, if any.
    public var replyTarget: String? {
        for segment in self {
            if case .reply(let id) = segment { return id }
        }
        return nil
    }

    /// Users mentioned, in order. `nil` entries mean "@everyone".
    public var mentions: [String?] {
        compactMap { if case .mention(let id) = $0 { return .some(id) } else { return nil } }
    }
}
