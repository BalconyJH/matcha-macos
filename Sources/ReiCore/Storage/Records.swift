import Foundation

enum StorePersistenceError: Error, LocalizedError, Sendable {
    case invalidRawValue(type: String, value: String)
    case missingUser(String)
    case missingGroup(String)

    var errorDescription: String? {
        switch self {
        case .invalidRawValue(let type, let value):
            return "Invalid \(type) value in the database: \(value)"
        case .missingUser(let id):
            return "Cannot write a record that references a missing user: \(id)"
        case .missingGroup(let id):
            return "Cannot write a record that references a missing group: \(id)"
        }
    }
}

/// Length-prefixed components avoid the delimiter collisions of a naive joined key.
enum StorageIdentity {
    static func groupMember(groupID: String, userID: String) -> String {
        composite(namespace: "group-member", components: [groupID, userID])
    }

    static func friendship(userID: String, friendID: String) -> String {
        composite(namespace: "friendship", components: [userID, friendID])
    }

    private static func composite(namespace: String, components: [String]) -> String {
        ([namespace] + components)
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
    }
}

enum PersistenceCodec {
    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        try JSONDecoder().decode(type, from: data)
    }
}

// MARK: - User

extension UserRecord {
    static func make(from user: User) -> UserRecord {
        UserRecord(
            id: user.id,
            name: user.name,
            nickname: user.nickname,
            avatar: user.avatar,
            sex: user.sex.rawValue,
            age: user.age,
            sign: user.sign,
            createdAt: user.createdAt
        )
    }

    func update(from user: User) {
        name = user.name
        nickname = user.nickname
        avatar = user.avatar
        sex = user.sex.rawValue
        age = user.age
        sign = user.sign
        createdAt = user.createdAt
    }

    func domainValue() throws -> User {
        guard let sex = User.Sex(rawValue: sex) else {
            throw StorePersistenceError.invalidRawValue(type: "User.Sex", value: self.sex)
        }
        return User(
            id: id,
            name: name,
            nickname: nickname,
            avatar: avatar,
            sex: sex,
            age: age,
            sign: sign,
            createdAt: createdAt
        )
    }
}

// MARK: - Group

extension GroupRecord {
    static func make(from group: Group) -> GroupRecord {
        GroupRecord(
            id: group.id,
            name: group.name,
            avatar: group.avatar,
            intro: group.intro,
            level: group.level,
            maxMemberCount: group.maxMemberCount,
            wholeMuted: group.wholeMuted,
            createdAt: group.createdAt
        )
    }

    func update(from group: Group) {
        name = group.name
        avatar = group.avatar
        intro = group.intro
        level = group.level
        maxMemberCount = group.maxMemberCount
        wholeMuted = group.wholeMuted
        createdAt = group.createdAt
    }

    func domainValue() -> Group {
        Group(
            id: id,
            name: name,
            avatar: avatar,
            intro: intro,
            level: level,
            maxMemberCount: maxMemberCount,
            wholeMuted: wholeMuted,
            createdAt: createdAt
        )
    }
}

// MARK: - Group member

extension GroupMemberRecord {
    static func make(from member: GroupMember) -> GroupMemberRecord {
        GroupMemberRecord(
            id: StorageIdentity.groupMember(groupID: member.groupID, userID: member.userID),
            groupID: member.groupID,
            userID: member.userID,
            card: member.card,
            role: member.role.rawValue,
            title: member.title,
            joinedAt: member.joinedAt,
            lastSentAt: member.lastSentAt,
            mutedUntil: member.mutedUntil
        )
    }

    func update(from member: GroupMember) {
        groupID = member.groupID
        userID = member.userID
        card = member.card
        role = member.role.rawValue
        title = member.title
        joinedAt = member.joinedAt
        lastSentAt = member.lastSentAt
        mutedUntil = member.mutedUntil
    }

    func domainValue() throws -> GroupMember {
        guard let role = GroupMember.Role(rawValue: role) else {
            throw StorePersistenceError.invalidRawValue(type: "GroupMember.Role", value: self.role)
        }
        return GroupMember(
            groupID: groupID,
            userID: userID,
            card: card,
            role: role,
            title: title,
            joinedAt: joinedAt,
            lastSentAt: lastSentAt,
            mutedUntil: mutedUntil
        )
    }
}

// MARK: - Friendship

extension FriendshipRecord {
    static func make(from friendship: Friendship) -> FriendshipRecord {
        FriendshipRecord(
            id: StorageIdentity.friendship(userID: friendship.userID, friendID: friendship.friendID),
            userID: friendship.userID,
            friendID: friendship.friendID,
            remark: friendship.remark,
            createdAt: friendship.createdAt
        )
    }

    func update(from friendship: Friendship) {
        userID = friendship.userID
        friendID = friendship.friendID
        remark = friendship.remark
        createdAt = friendship.createdAt
    }

    func domainValue() -> Friendship {
        Friendship(userID: userID, friendID: friendID, remark: remark, createdAt: createdAt)
    }
}

// MARK: - Message

extension MessageRecord {
    static func make(from message: Message) throws -> MessageRecord {
        try MessageRecord(
            id: message.id,
            seq: message.seq,
            scene: message.scene.rawValue,
            peerID: message.peerID,
            senderID: message.senderID,
            selfID: message.selfID,
            content: PersistenceCodec.encode(message.content),
            time: message.time,
            direction: message.direction.rawValue,
            recalledAt: message.recalledAt,
            recalledBy: message.recalledBy
        )
    }

    func update(from message: Message) throws {
        seq = message.seq
        scene = message.scene.rawValue
        peerID = message.peerID
        senderID = message.senderID
        selfID = message.selfID
        content = try PersistenceCodec.encode(message.content)
        time = message.time
        direction = message.direction.rawValue
        recalledAt = message.recalledAt
        recalledBy = message.recalledBy
    }

    func domainValue() throws -> Message {
        guard let scene = ChatScene(rawValue: scene) else {
            throw StorePersistenceError.invalidRawValue(type: "ChatScene", value: self.scene)
        }
        guard let direction = Message.Direction(rawValue: direction) else {
            throw StorePersistenceError.invalidRawValue(type: "Message.Direction", value: self.direction)
        }
        return try Message(
            id: id,
            seq: seq,
            scene: scene,
            peerID: peerID,
            senderID: senderID,
            selfID: selfID,
            content: PersistenceCodec.decode([MessageSegment].self, from: content),
            time: time,
            direction: direction,
            recalledAt: recalledAt,
            recalledBy: recalledBy
        )
    }
}

// MARK: - Pending request

extension PendingRequestRecord {
    static func make(from request: PendingRequest) throws -> PendingRequestRecord {
        let resolution = try request.resolution.map { try PersistenceCodec.encode($0) }
        return PendingRequestRecord(
            id: request.id,
            flag: request.flag,
            kind: request.kind.rawValue,
            requesterID: request.requesterID,
            groupID: request.groupID,
            selfID: request.selfID,
            comment: request.comment,
            time: request.time,
            resolution: resolution
        )
    }

    func update(from request: PendingRequest) throws {
        flag = request.flag
        kind = request.kind.rawValue
        requesterID = request.requesterID
        groupID = request.groupID
        selfID = request.selfID
        comment = request.comment
        time = request.time
        resolution = try request.resolution.map { try PersistenceCodec.encode($0) }
    }

    func domainValue() throws -> PendingRequest {
        guard let kind = PendingRequest.Kind(rawValue: kind) else {
            throw StorePersistenceError.invalidRawValue(type: "PendingRequest.Kind", value: self.kind)
        }
        return try PendingRequest(
            id: id,
            flag: flag,
            kind: kind,
            requesterID: requesterID,
            groupID: groupID,
            selfID: selfID,
            comment: comment,
            time: time,
            resolution: resolution.map { try PersistenceCodec.decode(PendingRequest.Resolution.self, from: $0) }
        )
    }
}

// MARK: - Asset

extension AssetRecord {
    static func make(from asset: Asset) throws -> AssetRecord {
        try AssetRecord(
            id: asset.id,
            name: asset.name,
            mimeType: asset.mimeType,
            byteCount: asset.byteCount,
            source: PersistenceCodec.encode(asset.source)
        )
    }

    func update(from asset: Asset) throws {
        name = asset.name
        mimeType = asset.mimeType
        byteCount = asset.byteCount
        source = try PersistenceCodec.encode(asset.source)
    }

    func domainValue() throws -> Asset {
        try Asset(
            id: id,
            name: name,
            mimeType: mimeType,
            byteCount: byteCount,
            source: PersistenceCodec.decode(Asset.Source.self, from: source)
        )
    }
}

// MARK: - Stable resolution coding

extension PendingRequest.Resolution: Codable {
    private enum CodingKeys: String, CodingKey { case state, reason }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .state) {
        case "accepted":
            self = .accepted
        default:
            self = .rejected(reason: try container.decodeIfPresent(String.self, forKey: .reason) ?? "")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .accepted:
            try container.encode("accepted", forKey: .state)
        case .rejected(let reason):
            try container.encode("rejected", forKey: .state)
            try container.encode(reason, forKey: .reason)
        }
    }
}
