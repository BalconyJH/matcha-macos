import Foundation
import ReiCore
import ReiProtocol

/// Read access to platform state for the OneBot adapters.
///
/// Kept separate from `PlatformService` because encoding an event needs to look
/// entities up but must never mutate — the split keeps that guarantee in the type
/// rather than in a convention.
public struct OneBotContext: Sendable {
    let store: ReiStore

    public init(store: ReiStore) {
        self.store = store
    }

    /// Who sent a message, as OneBot v11 reports it inside `sender`.
    func senderInfo(userID: String, groupID: String?) async -> SenderInfo {
        let user = try? await store.user(id: userID)
        var info = SenderInfo(
            userID: userID,
            nickname: user?.displayName ?? userID,
            sex: user?.sex.rawValue ?? "unknown",
            age: user?.age ?? 0
        )
        guard let groupID, let member = try? await store.member(groupID: groupID, userID: userID) else {
            return info
        }
        info.card = member.card
        info.role = member.role.rawValue
        info.title = member.title
        return info
    }

    /// A user as `get_stranger_info` and friends report them.
    func userInfo(userID: String) async -> JSONValue? {
        guard let user = try? await store.user(id: userID) else { return nil }
        return [
            "user_id": .string(user.id),
            "nickname": .string(user.displayName),
            "sex": .string(user.sex.rawValue),
            "age": .number(Double(user.age ?? 0)),
        ]
    }

    /// A group as `get_group_info` reports it.
    func groupInfo(groupID: String) async -> JSONValue? {
        guard let group = try? await store.group(id: groupID) else { return nil }
        let memberCount = (try? await store.memberCount(groupID: groupID)) ?? 0
        return [
            "group_id": .string(group.id),
            "group_name": .string(group.name),
            "member_count": .number(Double(memberCount)),
            "max_member_count": .number(Double(group.maxMemberCount)),
        ]
    }

    /// A member as `get_group_member_info` reports it.
    func memberInfo(groupID: String, userID: String) async -> JSONValue? {
        guard let member = try? await store.member(groupID: groupID, userID: userID) else { return nil }
        let user = try? await store.user(id: userID)
        return [
            "group_id": .string(groupID),
            "user_id": .string(userID),
            "nickname": .string(user?.displayName ?? userID),
            "card": .string(member.card),
            "sex": .string(user?.sex.rawValue ?? "unknown"),
            "age": .number(Double(user?.age ?? 0)),
            "join_time": .number(member.joinedAt.timeIntervalSince1970),
            "last_sent_time": .number(member.lastSentAt?.timeIntervalSince1970 ?? 0),
            "role": .string(member.role.rawValue),
            "title": .string(member.title),
            "shut_up_timestamp": .number(member.mutedUntil?.timeIntervalSince1970 ?? 0),
        ]
    }
}

/// The sender fields OneBot v11 nests inside a message event.
struct SenderInfo: Sendable {
    var userID: String
    var nickname: String
    var sex: String
    var age: Int
    var card: String = ""
    var role: String = ""
    var title: String = ""

    func asV11JSON(usesNumericIDs: Bool) -> JSONValue {
        var payload: [String: JSONValue] = [
            "user_id": usesNumericIDs ? .number(Double(Int64(userID) ?? 0)) : .string(userID),
            "nickname": .string(nickname),
            "sex": .string(sex),
            "age": .number(Double(age)),
        ]
        // Group senders carry the extra membership fields.
        if !role.isEmpty {
            payload["card"] = .string(card)
            payload["role"] = .string(role)
            payload["title"] = .string(title)
        }
        return .object(payload)
    }
}
