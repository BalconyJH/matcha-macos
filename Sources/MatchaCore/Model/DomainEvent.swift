import Foundation

/// Something that happened in the simulated platform.
///
/// This is the pivot of the whole design. Operator actions in the UI and side
/// effects of protocol actions both land here, and every protocol implementation
/// translates the same `DomainEvent` into its own wire event. Adding a protocol
/// means writing one translation, not touching the UI; adding a UI gesture means
/// emitting one event, not touching any protocol.
///
/// Deliberately *not* a union of OneBot's and Milky's event sets: it carries what
/// the simulation knows, and each implementation drops what its protocol cannot express.
public struct DomainEvent: Identifiable, Hashable, Sendable {
    public var id: String
    public var time: Date
    /// Which persona/bot this event is addressed to. An implementation only forwards
    /// events whose `selfID` matches the bot it has logged in as.
    public var selfID: String
    public var payload: Payload

    public init(
        id: String = IDGenerator.requestID(),
        time: Date = .now,
        selfID: String,
        payload: Payload
    ) {
        self.id = id
        self.time = time
        self.selfID = selfID
        self.payload = payload
    }

    public enum Payload: Hashable, Sendable {
        // MARK: Messages

        case message(Message)
        case messageRecalled(MessageRecalled)

        // MARK: Group membership

        case groupMemberAdded(GroupMemberChange)
        case groupMemberRemoved(GroupMemberChange)
        case groupAdminChanged(GroupAdminChange)
        case groupMuted(GroupMute)
        case groupNameChanged(groupID: String, operatorID: String, name: String)

        // MARK: Friends

        case friendAdded(userID: String)
        case friendRemoved(userID: String)

        // MARK: Requests

        case requestReceived(PendingRequest)

        // MARK: Interactions

        case poke(Poke)
        /// A reaction (emoji "like") added to or removed from a message.
        case messageReaction(MessageReaction)
        case groupFileUploaded(GroupFileUpload)

        // MARK: Lifecycle

        /// The protocol implementation finished handshaking with a peer.
        case connected
        /// The peer went away.
        case disconnected
    }

    // MARK: - Payload details

    public struct MessageRecalled: Hashable, Sendable {
        public var messageID: String
        public var scene: ChatScene
        public var peerID: String
        public var senderID: String
        /// Who performed the recall; equals `senderID` for a self-recall.
        public var operatorID: String

        public init(messageID: String, scene: ChatScene, peerID: String, senderID: String, operatorID: String) {
            self.messageID = messageID
            self.scene = scene
            self.peerID = peerID
            self.senderID = senderID
            self.operatorID = operatorID
        }
    }

    public struct GroupMemberChange: Hashable, Sendable {
        public var groupID: String
        public var userID: String
        /// Who did it: the inviter, the admin who kicked, or `userID` for a
        /// voluntary join/leave.
        public var operatorID: String
        public var reason: Reason

        public enum Reason: String, Hashable, Sendable {
            /// Joined or left on their own.
            case voluntary
            /// Added or removed by someone else.
            case administrative
            /// Brought in by an invite.
            case invited
        }

        public init(groupID: String, userID: String, operatorID: String, reason: Reason) {
            self.groupID = groupID
            self.userID = userID
            self.operatorID = operatorID
            self.reason = reason
        }
    }

    public struct GroupAdminChange: Hashable, Sendable {
        public var groupID: String
        public var userID: String
        public var operatorID: String
        /// `true` when granting, `false` when revoking.
        public var granted: Bool

        public init(groupID: String, userID: String, operatorID: String, granted: Bool) {
            self.groupID = groupID
            self.userID = userID
            self.operatorID = operatorID
            self.granted = granted
        }
    }

    public struct GroupMute: Hashable, Sendable {
        public var groupID: String
        /// `nil` targets the whole group.
        public var userID: String?
        public var operatorID: String
        /// Whether the mute is being applied or removed.
        ///
        /// Explicit rather than inferred from `duration`, because a whole-group mute
        /// has no duration at all: deriving the state from the number meant an
        /// indefinite mute had to pick a sentinel, and any sentinel outside the
        /// positive range read as an unmute.
        public var muted: Bool
        /// How long the mute lasts. Zero means indefinite, which is always the case
        /// for a whole-group mute, and is meaningless when `muted` is false.
        public var duration: TimeInterval

        public init(groupID: String, userID: String?, operatorID: String, muted: Bool, duration: TimeInterval = 0) {
            self.groupID = groupID
            self.userID = userID
            self.operatorID = operatorID
            self.muted = muted
            self.duration = max(duration, 0)
        }
    }

    public struct Poke: Hashable, Sendable {
        public var scene: ChatScene
        public var peerID: String
        public var senderID: String
        public var targetID: String

        public init(scene: ChatScene, peerID: String, senderID: String, targetID: String) {
            self.scene = scene
            self.peerID = peerID
            self.senderID = senderID
            self.targetID = targetID
        }
    }

    public struct MessageReaction: Hashable, Sendable {
        public var messageID: String
        public var scene: ChatScene
        public var peerID: String
        public var userID: String
        /// Face/emoji identifier.
        public var reaction: String
        /// `true` when added, `false` when removed.
        public var added: Bool

        public init(
            messageID: String,
            scene: ChatScene,
            peerID: String,
            userID: String,
            reaction: String,
            added: Bool
        ) {
            self.messageID = messageID
            self.scene = scene
            self.peerID = peerID
            self.userID = userID
            self.reaction = reaction
            self.added = added
        }
    }

    public struct GroupFileUpload: Hashable, Sendable {
        public var groupID: String
        public var userID: String
        public var asset: Asset

        public init(groupID: String, userID: String, asset: Asset) {
            self.groupID = groupID
            self.userID = userID
            self.asset = asset
        }
    }
}
