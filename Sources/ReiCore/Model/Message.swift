import Foundation

/// A message in a conversation.
///
/// Direction matters for simulation: messages the operator sends become events
/// pushed to the connected bot framework, while messages the framework sends via
/// an action become incoming ones displayed in the UI.
public struct Message: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    /// Sequence number within the chat. OneBot v11 exposes this to peers as
    /// `message_seq` and Milky orders history by it.
    public var seq: Int64
    public var scene: ChatScene
    /// Group ID for group scenes, peer user ID otherwise.
    public var peerID: String
    public var senderID: String
    /// Whose session this belongs to — the persona or bot at this end.
    public var selfID: String
    public var content: [MessageSegment]
    public var time: Date
    public var direction: Direction
    /// Set once the message is recalled; peers must then treat it as gone.
    public var recalledAt: Date?
    /// Who recalled it, when that differs from the sender (an admin, say).
    public var recalledBy: String?

    public enum Direction: String, Hashable, Sendable, Codable {
        /// Authored in Rei by the operator, pushed to the bot as an event.
        case outgoing
        /// Sent by the bot framework through a send-message action.
        case incoming
    }

    public var isRecalled: Bool { recalledAt != nil }

    /// The chat this message belongs to.
    public var chat: Chat { Chat(scene: scene, peerID: peerID, selfID: selfID) }

    public init(
        id: String = IDGenerator.messageID(),
        seq: Int64 = 0,
        scene: ChatScene,
        peerID: String,
        senderID: String,
        selfID: String,
        content: [MessageSegment],
        time: Date = .now,
        direction: Direction,
        recalledAt: Date? = nil,
        recalledBy: String? = nil
    ) {
        self.id = id
        self.seq = seq
        self.scene = scene
        self.peerID = peerID
        self.senderID = senderID
        self.selfID = selfID
        self.content = content
        self.time = time
        self.direction = direction
        self.recalledAt = recalledAt
        self.recalledBy = recalledBy
    }
}

/// A pending friend or group request awaiting the peer's decision.
///
/// The bot framework approves or rejects these by quoting the `flag`.
public struct PendingRequest: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    /// Opaque token the peer echoes back to act on this request.
    public var flag: String
    public var kind: Kind
    public var requesterID: String
    /// Target group for group-scoped requests.
    public var groupID: String?
    public var selfID: String
    public var comment: String
    public var time: Date
    public var resolution: Resolution?

    public enum Kind: String, Hashable, Sendable, Codable {
        case friend
        /// Someone asking to join a group.
        case groupJoin
        /// Someone inviting the bot into a group.
        case groupInvite
    }

    public enum Resolution: Hashable, Sendable {
        case accepted
        case rejected(reason: String)
    }

    public init(
        id: String = IDGenerator.requestID(),
        flag: String = IDGenerator.flag(),
        kind: Kind,
        requesterID: String,
        groupID: String? = nil,
        selfID: String,
        comment: String = "",
        time: Date = .now,
        resolution: Resolution? = nil
    ) {
        self.id = id
        self.flag = flag
        self.kind = kind
        self.requesterID = requesterID
        self.groupID = groupID
        self.selfID = selfID
        self.comment = comment
        self.time = time
        self.resolution = resolution
    }
}
