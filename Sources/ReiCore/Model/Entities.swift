import Foundation

/// A person: either one of the operator's personas or the bot itself.
///
/// Rei simulates the *platform*, so every participant is authored locally.
/// One user is marked as the bot the framework under test logs in as.
public struct User: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var nickname: String
    /// Absolute path or `rei-asset://` reference to the avatar image.
    public var avatar: String?
    public var sex: Sex
    public var age: Int?
    public var sign: String
    public var createdAt: Date

    public enum Sex: String, Codable, CaseIterable, Sendable {
        case male, female, unknown
    }

    public init(
        id: String = IDGenerator.userID(),
        name: String,
        nickname: String = "",
        avatar: String? = nil,
        sex: Sex = .unknown,
        age: Int? = nil,
        sign: String = "",
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.nickname = nickname.isEmpty ? name : nickname
        self.avatar = avatar
        self.sex = sex
        self.age = age
        self.sign = sign
        self.createdAt = createdAt
    }

    /// What a peer should display: the group card, else the nickname, else the name.
    public var displayName: String { nickname.isEmpty ? name : nickname }
}

/// A group chat.
public struct Group: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var avatar: String?
    public var intro: String
    public var level: Int
    public var maxMemberCount: Int
    /// `true` while the whole group is muted.
    public var wholeMuted: Bool
    public var createdAt: Date

    public init(
        id: String = IDGenerator.groupID(),
        name: String,
        avatar: String? = nil,
        intro: String = "",
        level: Int = 1,
        maxMemberCount: Int = 200,
        wholeMuted: Bool = false,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.avatar = avatar
        self.intro = intro
        self.level = level
        self.maxMemberCount = maxMemberCount
        self.wholeMuted = wholeMuted
        self.createdAt = createdAt
    }
}

/// A user's membership in a group: the per-group facts that differ from the
/// user's global profile.
public struct GroupMember: Hashable, Codable, Sendable, Identifiable {
    public var groupID: String
    public var userID: String
    /// Group-specific display name; empty means fall back to the user's nickname.
    public var card: String
    public var role: Role
    /// Honorific shown beside the name.
    public var title: String
    public var joinedAt: Date
    public var lastSentAt: Date?
    /// When the member's mute expires; `nil` when not muted.
    public var mutedUntil: Date?

    public enum Role: String, Codable, CaseIterable, Sendable, Comparable {
        case owner, admin, member

        /// Ordered by authority so permission checks read naturally.
        private var rank: Int {
            switch self {
            case .owner: return 2
            case .admin: return 1
            case .member: return 0
            }
        }

        public static func < (lhs: Role, rhs: Role) -> Bool { lhs.rank < rhs.rank }
    }

    public var id: String { "\(groupID):\(userID)" }

    public var isMuted: Bool {
        guard let mutedUntil else { return false }
        return mutedUntil > .now
    }

    public init(
        groupID: String,
        userID: String,
        card: String = "",
        role: Role = .member,
        title: String = "",
        joinedAt: Date = .now,
        lastSentAt: Date? = nil,
        mutedUntil: Date? = nil
    ) {
        self.groupID = groupID
        self.userID = userID
        self.card = card
        self.role = role
        self.title = title
        self.joinedAt = joinedAt
        self.lastSentAt = lastSentAt
        self.mutedUntil = mutedUntil
    }
}

/// A friend relation between the operator's persona and another user.
public struct Friendship: Hashable, Codable, Sendable, Identifiable {
    public var userID: String
    public var friendID: String
    /// Local alias for the friend.
    public var remark: String
    public var createdAt: Date

    public var id: String { "\(userID):\(friendID)" }

    public init(userID: String, friendID: String, remark: String = "", createdAt: Date = .now) {
        self.userID = userID
        self.friendID = friendID
        self.remark = remark
        self.createdAt = createdAt
    }
}

/// Where a conversation happens.
///
/// Both supported protocols distinguish one-to-one from group traffic and label
/// it differently (`message_type`, `detail_type`, `message_scene`); this is the
/// neutral form they each map from.
public enum ChatScene: String, Codable, Hashable, Sendable, CaseIterable {
    case friend
    case group
    /// A one-to-one conversation with someone met in a group, not a friend.
    case temp

    public var isPrivate: Bool { self != .group }
}

/// A conversation the UI lists in the sidebar.
public struct Chat: Identifiable, Hashable, Codable, Sendable {
    public var scene: ChatScene
    /// The peer: a user ID for private scenes, a group ID for group scenes.
    public var peerID: String
    /// The protocol account whose session owns this conversation.
    ///
    /// Private chats are stored from this account's perspective, even when the
    /// operator is currently acting as `peerID` in the UI.
    public var selfID: String

    public var id: String { "\(scene.rawValue):\(selfID):\(peerID)" }

    public init(scene: ChatScene, peerID: String, selfID: String) {
        self.scene = scene
        self.peerID = peerID
        self.selfID = selfID
    }

    /// The other participant in a private chat, relative to one of its endpoints.
    ///
    /// Group chats have no single counterpart. A third user is not a participant
    /// and therefore cannot reinterpret or send into this conversation.
    public func counterpartID(for participantID: String) -> String? {
        guard scene.isPrivate, selfID != peerID else { return nil }
        if participantID == selfID { return peerID }
        if participantID == peerID { return selfID }
        return nil
    }
}
