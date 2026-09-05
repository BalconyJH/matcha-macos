import Foundation
import ReiCore
import ReiProtocol

/// Event translation for OneBot.
///
/// The two versions describe the same happenings with different taxonomies:
///
/// - v11 nests `post_type` → `message_type`/`notice_type`/`request_type` → `sub_type`,
///   sends IDs as JSON numbers, and carries a `sender` object inside message events.
/// - v12 uses a `type`/`detail_type`/`sub_type` triple, sends IDs as strings, keeps
///   fields flat, and identifies the bot through a `self` object.
///
/// Neither is the base case, so both are written out in full rather than one being
/// derived from the other.
struct OneBotEventEncoder: Sendable {
    let version: OneBotVersion
    let selfID: String
    let segmentCoder: OneBotSegmentCoder
    let context: OneBotContext

    /// Encodes a domain event, or returns an empty array when this version has no
    /// representation for it.
    func encode(_ event: DomainEvent) async -> [JSONValue] {
        let time = Int64(event.time.timeIntervalSince1970)

        switch event.payload {
        case .message(let message):
            guard let payload = await encodeMessage(message, time: time) else { return [] }
            return [payload]

        case .messageRecalled(let recall):
            guard let payload = encodeRecall(recall, time: time) else { return [] }
            return [payload]

        case .groupMemberAdded(let change):
            return [encodeMemberChange(change, time: time, joined: true)]

        case .groupMemberRemoved(let change):
            return [encodeMemberChange(change, time: time, joined: false)]

        case .groupAdminChanged(let change):
            guard let payload = encodeAdminChange(change, time: time) else { return [] }
            return [payload]

        case .groupMuted(let mute):
            guard let payload = encodeMute(mute, time: time) else { return [] }
            return [payload]

        case .groupNameChanged:
            // Neither version standardises a group-rename notice.
            return []

        case .friendAdded(let userID):
            guard version == .v12 else { return [] }
            return [
                base(time: time, type: "notice", detailType: "friend_increase")
                    .merging(["user_id": .string(userID)])
            ]

        case .friendRemoved(let userID):
            guard version == .v12 else { return [] }
            return [
                base(time: time, type: "notice", detailType: "friend_decrease")
                    .merging(["user_id": .string(userID)])
            ]

        case .requestReceived(let request):
            guard let payload = encodeRequest(request, time: time) else { return [] }
            return [payload]

        case .poke(let poke):
            guard version == .v11 else { return [] }
            return [encodePoke(poke, time: time)]

        case .messageReaction:
            // A v11 extension in practice, not in either standard.
            return []

        case .groupFileUploaded(let upload):
            guard version == .v11 else { return [] }
            return [
                base(time: time, type: "notice", detailType: "group_upload")
                    .merging([
                        "group_id": id(upload.groupID),
                        "user_id": id(upload.userID),
                        "file": [
                            "id": .string(upload.asset.id),
                            "name": .string(upload.asset.name),
                            "size": .number(Double(upload.asset.byteCount)),
                            "busid": 0,
                        ],
                    ])
            ]

        case .connected, .disconnected:
            // Lifecycle frames come from `handshakeFrames`, which knows the
            // connection state; a domain event is not the right source for them.
            return []
        }
    }

    // MARK: - Messages

    private func encodeMessage(_ message: Message, time: Int64) async -> JSONValue? {
        let segments = await segmentCoder.encode(message.content)
        let plainText = message.content.textPreview

        switch version {
        case .v11:
            var payload: [String: JSONValue] = [
                "time": .number(Double(time)),
                "self_id": id(selfID),
                "post_type": "message",
                "message_type": message.scene == .group ? "group" : "private",
                // v11 has no `temp` sub-type for private messages; it calls it `other`.
                "sub_type": .string(v11SubType(for: message.scene)),
                "message_id": id(message.id),
                "user_id": id(message.senderID),
                "message": .array(segments),
                "raw_message": .string(plainText),
                "font": 0,
            ]

            let sender = await context.senderInfo(
                userID: message.senderID,
                groupID: message.scene == .group ? message.peerID : nil
            )
            payload["sender"] = sender.asV11JSON(usesNumericIDs: version.usesNumericIDs)

            if message.scene == .group {
                payload["group_id"] = id(message.peerID)
                payload["anonymous"] = .null
            }
            return .object(payload)

        case .v12:
            var payload: [String: JSONValue] = [
                "id": .string(message.id),
                "time": .number(Double(time)),
                "type": "message",
                "detail_type": message.scene == .group ? "group" : "private",
                "sub_type": "",
                "self": selfObject(),
                "message_id": .string(message.id),
                "user_id": .string(message.senderID),
                "message": .array(segments),
                "alt_message": .string(plainText),
            ]
            if message.scene == .group {
                payload["group_id"] = .string(message.peerID)
            }
            return .object(payload)
        }
    }

    private func v11SubType(for scene: ChatScene) -> String {
        switch scene {
        case .group: return "normal"
        case .friend: return "friend"
        case .temp: return "other"
        }
    }

    // MARK: - Notices

    private func encodeRecall(_ recall: DomainEvent.MessageRecalled, time: Int64) -> JSONValue? {
        switch version {
        case .v11:
            if recall.scene == .group {
                return base(time: time, type: "notice", detailType: "group_recall")
                    .merging([
                        "group_id": id(recall.peerID),
                        "user_id": id(recall.senderID),
                        "operator_id": id(recall.operatorID),
                        "message_id": id(recall.messageID),
                    ])
            }
            return base(time: time, type: "notice", detailType: "friend_recall")
                .merging([
                    "user_id": id(recall.senderID),
                    "message_id": id(recall.messageID),
                ])

        case .v12:
            let detailType = recall.scene == .group ? "group_message_delete" : "private_message_delete"
            var payload: [String: JSONValue] = [
                "message_id": .string(recall.messageID),
                "user_id": .string(recall.senderID),
                "operator_id": .string(recall.operatorID),
            ]
            if recall.scene == .group {
                payload["group_id"] = .string(recall.peerID)
                // v12 distinguishes a self-recall from an administrative one.
                payload["sub_type"] = recall.operatorID == recall.senderID ? "recall" : "delete"
            }
            return base(time: time, type: "notice", detailType: detailType).merging(payload)
        }
    }

    private func encodeMemberChange(
        _ change: DomainEvent.GroupMemberChange,
        time: Int64,
        joined: Bool
    ) -> JSONValue {
        switch version {
        case .v11:
            let subType: String
            if joined {
                subType = change.reason == .invited ? "invite" : "approve"
            } else if change.reason == .voluntary {
                subType = "leave"
            } else {
                // v11 has a distinct state for "the bot itself was kicked".
                subType = change.userID == selfID ? "kick_me" : "kick"
            }
            return base(
                time: time,
                type: "notice",
                detailType: joined ? "group_increase" : "group_decrease"
            )
            .merging([
                "sub_type": .string(subType),
                "group_id": id(change.groupID),
                "operator_id": id(change.operatorID),
                "user_id": id(change.userID),
            ])

        case .v12:
            let subType: String
            if joined {
                subType = change.reason == .voluntary ? "join" : "invite"
            } else {
                subType = change.reason == .voluntary ? "leave" : "kick"
            }
            return base(
                time: time,
                type: "notice",
                detailType: joined ? "group_member_increase" : "group_member_decrease"
            )
            .merging([
                "sub_type": .string(subType),
                "group_id": .string(change.groupID),
                "user_id": .string(change.userID),
                "operator_id": .string(change.operatorID),
            ])
        }
    }

    private func encodeAdminChange(_ change: DomainEvent.GroupAdminChange, time: Int64) -> JSONValue? {
        // v12 does not standardise an admin-change notice.
        guard version == .v11 else { return nil }
        return base(time: time, type: "notice", detailType: "group_admin")
            .merging([
                "sub_type": .string(change.granted ? "set" : "unset"),
                "group_id": id(change.groupID),
                "user_id": id(change.userID),
            ])
    }

    private func encodeMute(_ mute: DomainEvent.GroupMute, time: Int64) -> JSONValue? {
        guard version == .v11 else { return nil }
        return base(time: time, type: "notice", detailType: "group_ban")
            .merging([
                "sub_type": .string(mute.muted ? "ban" : "lift_ban"),
                "group_id": id(mute.groupID),
                // A whole-group mute reports user 0 as the target.
                "user_id": id(mute.userID ?? "0"),
                "operator_id": id(mute.operatorID),
                "duration": .number(max(mute.duration, 0)),
            ])
    }

    private func encodePoke(_ poke: DomainEvent.Poke, time: Int64) -> JSONValue {
        var payload: [String: JSONValue] = [
            "sub_type": "poke",
            "user_id": id(poke.senderID),
            "target_id": id(poke.targetID),
        ]
        if poke.scene == .group {
            payload["group_id"] = id(poke.peerID)
        }
        // Both group and private pokes are `notice.notify` in v11; the presence of
        // group_id is what distinguishes them.
        return base(time: time, type: "notice", detailType: "notify").merging(payload)
    }

    // MARK: - Requests

    private func encodeRequest(_ request: PendingRequest, time: Int64) -> JSONValue? {
        switch version {
        case .v11:
            switch request.kind {
            case .friend:
                return base(time: time, type: "request", detailType: "friend")
                    .merging([
                        "user_id": id(request.requesterID),
                        "comment": .string(request.comment),
                        "flag": .string(request.flag),
                    ])
            case .groupJoin, .groupInvite:
                return base(time: time, type: "request", detailType: "group")
                    .merging([
                        "sub_type": .string(request.kind == .groupJoin ? "add" : "invite"),
                        "group_id": id(request.groupID ?? "0"),
                        "user_id": id(request.requesterID),
                        "comment": .string(request.comment),
                        "flag": .string(request.flag),
                    ])
            }

        case .v12:
            // v12 leaves request events to implementation extensions, so this is
            // Rei's own shape, named to avoid colliding with a future standard one.
            return base(time: time, type: "request", detailType: "rei.\(request.kind.rawValue)")
                .merging([
                    "user_id": .string(request.requesterID),
                    "group_id": request.groupID.map { .string($0) } ?? .null,
                    "comment": .string(request.comment),
                    "flag": .string(request.flag),
                ])
        }
    }

    // MARK: - Envelope helpers

    /// The fields common to every event of a version.
    private func base(time: Int64, type: String, detailType: String) -> JSONValue {
        switch version {
        case .v11:
            let typeKey = type == "message" ? "message_type" : "\(type)_type"
            return .object([
                "time": .number(Double(time)),
                "self_id": id(selfID),
                "post_type": .string(type),
                typeKey: .string(detailType),
            ])
        case .v12:
            return .object([
                "id": .string(IDGenerator.requestID()),
                "time": .number(Double(time)),
                "type": .string(type),
                "detail_type": .string(detailType),
                "sub_type": "",
                "self": selfObject(),
            ])
        }
    }

    private func selfObject() -> JSONValue {
        ["platform": "rei", "user_id": .string(selfID)]
    }

    /// Encodes an ID the way this version expects it: a number for v11, a string
    /// for v12.
    private func id(_ value: String) -> JSONValue {
        guard version.usesNumericIDs, let number = Int64(value) else { return .string(value) }
        return .number(Double(number))
    }
}

extension JSONValue {
    /// Adds members to an object, overwriting on conflict.
    func merging(_ members: [String: JSONValue]) -> JSONValue {
        guard case .object(let existing) = self else { return .object(members) }
        return .object(existing.merging(members) { _, new in new })
    }
}
