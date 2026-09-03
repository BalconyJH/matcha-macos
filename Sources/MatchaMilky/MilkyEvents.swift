import Foundation
import MatchaCore
import MatchaProtocol

/// Event translation for Milky.
///
/// The taxonomy is flat: one `event_type` with 21 values, no `post_type`/`notice_type`
/// nesting and no separate notice or request categories — `friend_request` and
/// `group_member_increase` are peers of `message_receive`. The envelope nests the
/// body under `data`.
///
/// Milky defines no meta events at all: no heartbeat, no lifecycle, no connect. The
/// only lifecycle-adjacent type is `bot_offline`, so a framework expecting a periodic
/// heartbeat will not get one, and none should be sent.
struct MilkyEventEncoder: Sendable {
    let selfID: String
    let segmentCoder: MilkySegmentCoder
    let entityEncoder: MilkyEntityEncoder

    func encode(_ event: DomainEvent) async -> [JSONValue] {
        let time = Int64(event.time.timeIntervalSince1970)

        switch event.payload {
        case .message(let message):
            let segments = await segmentCoder.encodeIncoming(message.content)
            // `message_receive`'s data *is* the IncomingMessage, flat — there is no
            // second `data` level here.
            let body = await entityEncoder.incomingMessage(message, segments: segments)
            return [envelope(time: time, type: "message_receive", data: body)]

        case .messageRecalled(let recall):
            // Milky addresses the recalled message by its per-chat sequence, so the
            // stored message has to be resolved to learn it.
            guard let stored = try? await entityEncoder.store.message(id: recall.messageID) else {
                return []
            }
            let recalledSeq = stored.seq
            return [
                envelope(
                    time: time, type: "message_recall",
                    data: [
                        "message_scene": .string(recall.scene.rawValue),
                        "peer_id": MilkyEntityEncoder.uin(recall.peerID),
                        "message_seq": .number(Double(recalledSeq)),
                        "sender_id": MilkyEntityEncoder.uin(recall.senderID),
                        "operator_id": MilkyEntityEncoder.uin(recall.operatorID),
                        "display_suffix": .string(
                            recall.operatorID == recall.senderID ? "recalled a message" : "recalled a member's message"
                        ),
                    ])
            ]

        case .groupMemberAdded(let change):
            var data: [String: JSONValue] = [
                "group_id": MilkyEntityEncoder.uin(change.groupID),
                "user_id": MilkyEntityEncoder.uin(change.userID),
            ]
            switch change.reason {
            case .invited:
                data["invitor_id"] = MilkyEntityEncoder.uin(change.operatorID)
            case .administrative:
                data["operator_id"] = MilkyEntityEncoder.uin(change.operatorID)
            case .voluntary:
                break
            }
            return [envelope(time: time, type: "group_member_increase", data: .object(data))]

        case .groupMemberRemoved(let change):
            var data: [String: JSONValue] = [
                "group_id": MilkyEntityEncoder.uin(change.groupID),
                "user_id": MilkyEntityEncoder.uin(change.userID),
            ]
            if change.reason != .voluntary {
                data["operator_id"] = MilkyEntityEncoder.uin(change.operatorID)
            }
            return [envelope(time: time, type: "group_member_decrease", data: .object(data))]

        case .groupAdminChanged(let change):
            return [
                envelope(
                    time: time, type: "group_admin_change",
                    data: [
                        "group_id": MilkyEntityEncoder.uin(change.groupID),
                        "user_id": MilkyEntityEncoder.uin(change.userID),
                        "operator_id": MilkyEntityEncoder.uin(change.operatorID),
                        "is_set": .bool(change.granted),
                    ])
            ]

        case .groupMuted(let mute):
            // Milky separates per-member mutes from whole-group ones.
            if let userID = mute.userID {
                return [
                    envelope(
                        time: time, type: "group_mute",
                        data: [
                            "group_id": MilkyEntityEncoder.uin(mute.groupID),
                            "user_id": MilkyEntityEncoder.uin(userID),
                            "operator_id": MilkyEntityEncoder.uin(mute.operatorID),
                            "duration": MilkyEntityEncoder.seconds(max(mute.duration, 0)),
                        ])
                ]
            }
            return [
                envelope(
                    time: time, type: "group_whole_mute",
                    data: [
                        "group_id": MilkyEntityEncoder.uin(mute.groupID),
                        "operator_id": MilkyEntityEncoder.uin(mute.operatorID),
                        "is_mute": .bool(mute.muted),
                    ])
            ]

        case .groupNameChanged(let groupID, let operatorID, let name):
            return [
                envelope(
                    time: time, type: "group_name_change",
                    data: [
                        "group_id": MilkyEntityEncoder.uin(groupID),
                        "new_group_name": .string(name),
                        "operator_id": MilkyEntityEncoder.uin(operatorID),
                    ])
            ]

        case .friendAdded, .friendRemoved:
            // Milky has no friend increase/decrease event.
            return []

        case .requestReceived(let request):
            return [encodeRequest(request, time: time)]

        case .poke(let poke):
            if poke.scene == .group {
                return [
                    envelope(
                        time: time, type: "group_nudge",
                        data: [
                            "group_id": MilkyEntityEncoder.uin(poke.peerID),
                            "sender_id": MilkyEntityEncoder.uin(poke.senderID),
                            "receiver_id": MilkyEntityEncoder.uin(poke.targetID),
                            "display_action": .string("nudged"),
                            "display_suffix": .string(""),
                            "display_action_img_url": .string(""),
                        ])
                ]
            }
            return [
                envelope(
                    time: time, type: "friend_nudge",
                    data: [
                        "user_id": MilkyEntityEncoder.uin(poke.peerID),
                        "is_self_send": .bool(poke.senderID == selfID),
                        "is_self_receive": .bool(poke.targetID == selfID),
                        "display_action": .string("nudged"),
                        "display_suffix": .string(""),
                        "display_action_img_url": .string(""),
                    ])
            ]

        case .messageReaction(let reaction):
            // Group-only in Milky.
            guard reaction.scene == .group,
                let message = try? await entityEncoder.store.message(id: reaction.messageID)
            else { return [] }
            return [
                envelope(
                    time: time, type: "group_message_reaction",
                    data: [
                        "group_id": MilkyEntityEncoder.uin(reaction.peerID),
                        "user_id": MilkyEntityEncoder.uin(reaction.userID),
                        "message_seq": .number(Double(message.seq)),
                        "face_id": .string(reaction.reaction),
                        "reaction_type": "face",
                        "is_add": .bool(reaction.added),
                    ])
            ]

        case .groupFileUploaded(let upload):
            return [
                envelope(
                    time: time, type: "group_file_upload",
                    data: [
                        "group_id": MilkyEntityEncoder.uin(upload.groupID),
                        "user_id": MilkyEntityEncoder.uin(upload.userID),
                        "file_id": .string(upload.asset.id),
                        "file_name": .string(upload.asset.name),
                        "file_size": .number(Double(upload.asset.byteCount)),
                    ])
            ]

        case .connected:
            // Milky defines no connect event.
            return []

        case .disconnected:
            return [
                envelope(
                    time: time, type: "bot_offline",
                    data: [
                        "reason": .string("Connection closed")
                    ])
            ]
        }
    }

    private func encodeRequest(_ request: PendingRequest, time: Int64) -> JSONValue {
        switch request.kind {
        case .friend:
            return envelope(
                time: time, type: "friend_request",
                data: [
                    "initiator_id": MilkyEntityEncoder.uin(request.requesterID),
                    // The flag doubles as Milky's string UID, which is what
                    // accept/reject take.
                    "initiator_uid": .string(request.flag),
                    "comment": .string(request.comment),
                    "via": .string("matcha"),
                ])

        case .groupJoin:
            return envelope(
                time: time, type: "group_join_request",
                data: [
                    "group_id": MilkyEntityEncoder.uin(request.groupID ?? "0"),
                    "notification_seq": .number(Double(Self.notificationSeq(for: request))),
                    "is_filtered": false,
                    "initiator_id": MilkyEntityEncoder.uin(request.requesterID),
                    "comment": .string(request.comment),
                ])

        case .groupInvite:
            // Milky distinguishes "invite me into a group" (`group_invitation`) from
            // "someone was invited and needs approval" (`group_invited_join_request`).
            // A request addressed to the bot itself is the former.
            return envelope(
                time: time, type: "group_invitation",
                data: [
                    "group_id": MilkyEntityEncoder.uin(request.groupID ?? "0"),
                    "invitation_seq": .number(Double(Self.notificationSeq(for: request))),
                    "initiator_id": MilkyEntityEncoder.uin(request.requesterID),
                ])
        }
    }

    /// A stable numeric sequence for a request.
    ///
    /// Milky addresses notifications by `notification_seq`, an integer, while Matcha
    /// keys requests by an opaque flag. Hashing the flag gives a stable positive
    /// number that survives a restart, and `MilkyProtocolImplementation` maps it back.
    static func notificationSeq(for request: PendingRequest) -> Int64 {
        var hash: UInt64 = 5381
        for byte in request.flag.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        // Keep it inside the JS-safe integer range Milky specifies.
        return Int64(hash % 9_007_199_254_740_991)
    }

    /// The event envelope: `time`, `self_id`, `event_type`, and a nested `data`.
    private func envelope(time: Int64, type: String, data: JSONValue) -> JSONValue {
        [
            "time": .number(Double(time)),
            "self_id": MilkyEntityEncoder.uin(selfID),
            "event_type": .string(type),
            "data": data,
        ]
    }
}
