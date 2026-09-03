import Foundation
import MatchaCore
import MatchaProtocol

/// Media and cross-reference lookups for the Milky protocol implementation.
///
/// An actor because one of its jobs needs memory. Milky identifies a message by
/// `(message_scene, peer_id, message_seq)`, but `messageID(forSeq:)` is handed only
/// the sequence number, so resolving it requires knowing which conversation the call
/// belongs to. That context is accumulated here rather than guessed. See
/// `messageID(forSeq:)` for exactly how far the resolution goes and where it stops.
///
/// `AssetKind` in this file is `MatchaMilky`'s own. `MatchaOneBot` declares a type of
/// the same name, and the two are unrelated; this module does not import that one.
public actor MilkyAssetResolverImpl: MilkyAssetResolver {
    /// The conversation a sequence number should be read against.
    private struct Conversation: Hashable {
        var scene: ChatScene
        var peerID: String
        var selfID: String

        var chat: Chat { Chat(scene: scene, peerID: peerID, selfID: selfID) }
    }

    private let media: MediaService
    private let store: MatchaStore

    /// The conversation the implementation last declared, which wins over anything inferred.
    private var declared: Conversation?
    /// Conversations seen while encoding outbound events, newest first. A framework
    /// almost always quotes a message it was just told about, so recency is a good
    /// ordering for candidates.
    private var observed: [Conversation] = []
    /// How many conversations to remember. Enough to cover a debugging session's worth
    /// of open chats without turning an unbounded log into a lookup table.
    private static let observedLimit = 16

    public init(media: MediaService, store: MatchaStore) {
        self.media = media
        self.store = store
    }

    // MARK: - Conversation context

    /// Declares which conversation subsequent sequence numbers refer to.
    ///
    /// Milky's own API calls carry `message_scene` and `peer_id`, so the implementation
    /// handling one of those already knows the answer that `messageID(forSeq:)` has to
    /// infer. Calling this before decoding removes the ambiguity outright.
    public func setConversationContext(scene: ChatScene, peerID: String, selfID: String) {
        declared = Conversation(scene: scene, peerID: peerID, selfID: selfID)
    }

    public func clearConversationContext() {
        declared = nil
    }

    /// Records a conversation seen in passing, so an inferred lookup has candidates.
    public func note(message: Message) {
        remember(Conversation(scene: message.scene, peerID: message.peerID, selfID: message.selfID))
    }

    private func remember(_ conversation: Conversation) {
        observed.removeAll { $0 == conversation }
        observed.insert(conversation, at: 0)
        if observed.count > Self.observedLimit {
            observed.removeLast(observed.count - Self.observedLimit)
        }
    }

    // MARK: - Media

    public func resource(for asset: Asset) async -> MilkyResource {
        // Dimensions are only meaningful for images, and `MediaService` returns nil for
        // anything else, so video segments go out with the zeros the coder substitutes.
        let size = await media.pixelSize(of: asset)
        return MilkyResource(
            resourceID: asset.id,
            tempURL: await media.url(for: asset),
            width: size?.width,
            height: size?.height
        )
    }

    public func ingest(uri: String, kind: AssetKind) async -> Asset? {
        try? await media.ingest(
            reference: uri,
            suggestedName: Self.fallbackName(for: kind)
        )
    }

    /// A filename for content that arrived with none, so the MIME guess has something
    /// to work from.
    private static func fallbackName(for kind: AssetKind) -> String {
        switch kind {
        case .image: return "image.png"
        case .record: return "record.silk"
        case .video: return "video.mp4"
        case .file: return "file.bin"
        }
    }

    // MARK: - Names

    /// The name for a mention segment.
    ///
    /// Milky 1.2 changed this field to exclude the `@`, so any leading marker is
    /// stripped rather than passed through. A client that adds its own would otherwise
    /// render `@@name`.
    public func displayName(for userID: String) async -> String {
        guard let user = (try? await store.user(id: userID)) ?? nil else { return userID }
        let name = user.displayName.trimmingCharacters(in: .whitespaces)
        let stripped = name.hasPrefix("@") ? String(name.dropFirst()) : name
        return stripped.isEmpty ? userID : stripped
    }

    // MARK: - Replies

    public func replyReference(messageID: String) async -> MilkyReplyReference? {
        guard let message = (try? await store.message(id: messageID)) ?? nil else { return nil }
        // Encoding a reply proves this conversation is live, which is the cheapest
        // moment to learn context that `messageID(forSeq:)` will need going the other
        // way.
        note(message: message)
        return MilkyReplyReference(
            seq: message.seq,
            senderID: message.senderID,
            time: message.time,
            content: message.content
        )
    }

    /// Resolves a sequence number back to a message ID.
    ///
    /// **This lookup is ambiguous by construction.** Sequence numbers are per
    /// conversation and restart at 1 in each, so `seq: 3` names a different message in
    /// every open chat. The protocol's own reply segment carries only `message_seq`,
    /// with the scene and peer implied by the request that contained it, and this
    /// signature does not receive them. Resolution therefore proceeds in order of how
    /// much is actually known:
    ///
    /// 1. The conversation declared via `setConversationContext`, which is
    ///    exact and the path to prefer.
    /// 2. Failing that, conversations observed while encoding outbound events, and
    ///    only when exactly one of them holds that sequence number.
    ///
    /// When two remembered conversations both have the sequence, this returns `nil`.
    /// Picking the most recent would be a coin flip presented as an answer, and a
    /// reply attached to the wrong message is worse than a reply with no quote: the
    /// framework author would have no way to tell the guess from a real match.
    public func messageID(forSeq seq: Int64) async -> String? {
        if let declared,
            let message =
                (try? await store.message(
                    scene: declared.scene,
                    peerID: declared.peerID,
                    seq: seq,
                    selfID: declared.selfID
                )) ?? nil
        {
            return message.id
        }

        var matches: [Message] = []
        for candidate in observed {
            guard
                let message =
                    (try? await store.message(
                        scene: candidate.scene,
                        peerID: candidate.peerID,
                        seq: seq,
                        selfID: candidate.selfID
                    )) ?? nil
            else { continue }
            matches.append(message)
            // Two conversations answering to the same sequence is precisely the
            // ambiguous case; stop rather than keep collecting.
            if matches.count > 1 { return nil }
        }
        return matches.first?.id
    }
}
