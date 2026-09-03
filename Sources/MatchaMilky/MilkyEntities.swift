import Foundation
import MatchaCore
import MatchaProtocol

/// Entity encoding for Milky.
///
/// Milky embeds whole entities in its events — a group message carries the complete
/// `GroupEntity` *and* `GroupMemberEntity` — rather than the partial `sender` object
/// OneBot sends. That means a framework needs far fewer follow-up calls, but it also
/// means Matcha must hold coherent group state to emit even one message event.
struct MilkyEntityEncoder: Sendable {
    let store: MatchaStore

    /// `FriendEntity`.
    func friend(_ user: User, remark: String = "") async -> JSONValue {
        [
            "user_id": Self.uin(user.id),
            "nickname": .string(user.displayName),
            "sex": .string(user.sex.rawValue),
            "qid": .string(""),
            "remark": .string(remark),
            // Milky nests the category object rather than referencing it by ID.
            "category": [
                "category_id": 0,
                "category_name": "My Friends",
            ],
        ]
    }

    /// `GroupEntity`.
    func group(_ group: Group) async -> JSONValue {
        let memberCount = (try? await store.memberCount(groupID: group.id)) ?? 0
        return [
            "group_id": Self.uin(group.id),
            "group_name": .string(group.name),
            "member_count": .number(Double(memberCount)),
            "max_member_count": .number(Double(group.maxMemberCount)),
            "remark": .string(""),
            "created_time": Self.timestamp(group.createdAt),
            "description": .string(group.intro),
            "question": .string(""),
            "announcement": .string(""),
        ]
    }

    /// `GroupMemberEntity`. Carries `group_id`, so a member is self-describing.
    func groupMember(_ member: GroupMember, user: User?) -> JSONValue {
        var payload: [String: JSONValue] = [
            "user_id": Self.uin(member.userID),
            "nickname": .string(user?.displayName ?? member.userID),
            "sex": .string(user?.sex.rawValue ?? "unknown"),
            "group_id": Self.uin(member.groupID),
            "card": .string(member.card),
            "title": .string(member.title),
            // Group level, not the QQ account level.
            "level": 1,
            "role": .string(member.role.rawValue),
            "join_time": Self.timestamp(member.joinedAt),
            "last_sent_time": member.lastSentAt.map(Self.timestamp) ?? 0,
        ]
        if let mutedUntil = member.mutedUntil, mutedUntil > .now {
            payload["shut_up_end_time"] = Self.timestamp(mutedUntil)
        }
        return .object(payload)
    }

    /// `IncomingMessage`.
    ///
    /// A *flat* union: `message_scene` sits beside `peer_id` and `segments` with no
    /// nesting. Milky's events and segments nest their payload under `data`, but
    /// messages and notifications do not — mixing the two conventions up is an easy
    /// mistake, so this returns the flat form and callers place it directly.
    func incomingMessage(_ message: Message, segments: [JSONValue]) async -> JSONValue {
        var payload: [String: JSONValue] = [
            "message_scene": .string(message.scene.rawValue),
            "peer_id": Self.uin(message.peerID),
            "message_seq": .number(Double(message.seq)),
            "sender_id": Self.uin(message.senderID),
            "time": Self.timestamp(message.time),
            "segments": .array(segments),
        ]

        switch message.scene {
        case .friend:
            if let user = try? await store.user(id: message.peerID) {
                let remark = (try? await store.friendship(userID: message.selfID, friendID: message.peerID))?.remark
                payload["friend"] = await friend(user, remark: remark ?? "")
            }
        case .group:
            if let group = try? await store.group(id: message.peerID) {
                payload["group"] = await self.group(group)
            }
            if let member = try? await store.member(groupID: message.peerID, userID: message.senderID) {
                let user = try? await store.user(id: message.senderID)
                payload["group_member"] = groupMember(member, user: user)
            }
        case .temp:
            // `group` is optional for temp messages; Matcha does not track which
            // group a temp conversation began in.
            break
        }
        return .object(payload)
    }

    /// `FriendRequest`.
    func friendRequest(_ request: PendingRequest) -> JSONValue {
        [
            "time": Self.timestamp(request.time),
            "initiator_id": Self.uin(request.requesterID),
            // Milky keys accept/reject by this string UID, not by a numeric flag.
            "initiator_uid": .string(request.flag),
            "target_user_id": Self.uin(request.selfID),
            "target_user_uid": .string(request.selfID),
            "state": .string(Self.requestState(request)),
            "comment": .string(request.comment),
            "via": .string("matcha"),
            "is_filtered": false,
        ]
    }

    /// `GroupNotification`. Also a flat union, discriminated on `type`.
    func groupNotification(_ request: PendingRequest, seq: Int64) -> JSONValue {
        [
            // Matcha currently models join requests and invitations addressed to the
            // bot, but not "a member invited another member". Only the former belongs
            // to this notification API; bot invitations use `group_invitation` events.
            "type": "join_request",
            "group_id": Self.uin(request.groupID ?? "0"),
            "notification_seq": .number(Double(seq)),
            "is_filtered": false,
            "initiator_id": Self.uin(request.requesterID),
            "state": .string(Self.requestState(request)),
            "operator_id": .null,
            "comment": .string(request.comment),
        ]
    }

    private static func requestState(_ request: PendingRequest) -> String {
        switch request.resolution {
        case .none: return "pending"
        case .accepted: return "accepted"
        case .rejected: return "rejected"
        }
    }

    /// Milky types account and group numbers as integers in 10001…4294967295.
    static func uin(_ value: String) -> JSONValue {
        guard let number = Int64(value) else { return .string(value) }
        return .number(Double(number))
    }

    /// Milky timestamps and durations are JSON integers, even though Foundation uses
    /// floating-point seconds. Emitting a fractional number makes Pydantic reject the
    /// entire event or API response.
    static func timestamp(_ date: Date) -> JSONValue {
        .number(Double(Int64(date.timeIntervalSince1970)))
    }

    static func seconds(_ interval: TimeInterval) -> JSONValue {
        .number(Double(Int64(interval)))
    }
}
