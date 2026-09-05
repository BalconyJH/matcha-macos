import Foundation
import ReiCore
import ReiProtocol

/// The API implementations, keyed into `MilkyProtocolImplementation.apis` by path segment.
///
/// Read-only calls consult the store; anything that mutates goes through
/// `PlatformService`, so a framework's call produces the same events an operator's
/// click would. Milky's own shapes — compound message identity, entity-valued
/// results, integer sequence numbers standing in for opaque tokens — are translated
/// here and nowhere else.
extension MilkyProtocolImplementation {
    // MARK: - System

    func getLoginInfo() async -> ProtocolReply {
        let user = try? await platform.store.user(id: selfID)
        return .success([
            "uin": MilkyEntityEncoder.uin(selfID),
            "nickname": .string(user?.displayName ?? selfID),
        ])
    }

    func getImplInfo() -> ProtocolReply {
        .success([
            "impl_name": "rei",
            "impl_version": "0.1.0",
            // Rei simulates the platform rather than driving a real QQ client, so
            // there is no client build to report. `qq_protocol_type` has a closed set
            // of values though, and "macos" is the honest one.
            "qq_protocol_version": .string(""),
            "qq_protocol_type": "macos",
            "milky_version": .string(Self.milkyVersion),
        ])
    }

    func getUserProfile(_ call: ProtocolCall) async throws -> ProtocolReply {
        guard let userID = call.id("user_id") else {
            return invalidParameter("Missing user_id")
        }
        guard let user = try await platform.store.user(id: userID) else {
            throw PlatformError.userNotFound(userID)
        }
        let remark = try await platform.store.friendship(userID: selfID, friendID: userID)?.remark

        return .success([
            "nickname": .string(user.displayName),
            "age": .number(Double(user.age ?? 0)),
            "sex": .string(user.sex.rawValue),
            "remark": .string(remark ?? ""),
            "bio": .string(user.sign),
            // A QQ ID, account level, and location fields have no counterpart in a
            // locally authored persona, so they go out empty rather than invented.
            "qid": .string(""),
            "level": 0,
            "country": .string(""),
            "city": .string(""),
            "school": .string(""),
        ])
    }

    func getFriendList() async -> ProtocolReply {
        let friends = (try? await platform.store.friends(of: selfID)) ?? []
        var payload: [JSONValue] = []
        for entry in friends {
            payload.append(await entityEncoder.friend(entry.user, remark: entry.friendship.remark))
        }
        return .success(["friends": .array(payload)])
    }

    func getFriendInfo(_ call: ProtocolCall) async throws -> ProtocolReply {
        guard let userID = call.id("user_id") else {
            return invalidParameter("Missing user_id")
        }
        guard let user = try await platform.store.user(id: userID) else {
            throw PlatformError.userNotFound(userID)
        }
        let remark = try await platform.store.friendship(userID: selfID, friendID: userID)?.remark
        return .success(["friend": await entityEncoder.friend(user, remark: remark ?? "")])
    }

    func getGroupList() async -> ProtocolReply {
        // Milky lists the groups the logged-in account is in. With the bot in none of
        // them, every group is listed instead, the same allowance `publishToGroupBots`
        // makes so a framework watching a group it never joined is not left blind.
        var groups = (try? await platform.store.groups(containing: selfID)) ?? []
        if groups.isEmpty {
            groups = (try? await platform.store.allGroups()) ?? []
        }
        var payload: [JSONValue] = []
        for group in groups {
            payload.append(await entityEncoder.group(group))
        }
        return .success(["groups": .array(payload)])
    }

    func getGroupInfo(_ call: ProtocolCall) async throws -> ProtocolReply {
        guard let groupID = call.id("group_id") else {
            return invalidParameter("Missing group_id")
        }
        guard let group = try await platform.store.group(id: groupID) else {
            throw PlatformError.groupNotFound(groupID)
        }
        return .success(["group": await entityEncoder.group(group)])
    }

    func getGroupMemberList(_ call: ProtocolCall) async throws -> ProtocolReply {
        guard let groupID = call.id("group_id") else {
            return invalidParameter("Missing group_id")
        }
        guard try await platform.store.group(id: groupID) != nil else {
            throw PlatformError.groupNotFound(groupID)
        }
        let members = try await platform.store.members(groupID: groupID)
        var payload: [JSONValue] = []
        for member in members {
            let user = try await platform.store.user(id: member.userID)
            payload.append(entityEncoder.groupMember(member, user: user))
        }
        return .success(["members": .array(payload)])
    }

    func getGroupMemberInfo(_ call: ProtocolCall) async throws -> ProtocolReply {
        guard let groupID = call.id("group_id"), let userID = call.id("user_id") else {
            return invalidParameter("Missing group_id or user_id")
        }
        guard let member = try await platform.store.member(groupID: groupID, userID: userID) else {
            throw PlatformError.notAMember(groupID: groupID, userID: userID)
        }
        let user = try await platform.store.user(id: userID)
        return .success(["member": entityEncoder.groupMember(member, user: user)])
    }

    // MARK: - Messages

    /// `send_private_message` and `send_group_message`.
    ///
    /// One implementation for both because the scene comes from the route, not from a
    /// parameter: the peer key is the only thing that differs.
    func sendMessage(_ call: ProtocolCall, scene: ChatScene) async throws -> ProtocolReply {
        guard let peerID = call.id(scene == .group ? "group_id" : "user_id") else {
            return invalidParameter(scene == .group ? "Missing group_id" : "Missing user_id")
        }
        guard let raw = call.array("message") else {
            return invalidParameter("Missing message")
        }
        let content = await segmentCoder.decodeOutgoing(raw)
        guard !content.isEmpty else {
            return invalidParameter("Message content is empty")
        }

        let message = try await platform.sendMessage(
            scene: scene,
            peerID: peerID,
            senderID: selfID,
            selfID: selfID,
            content: content
        )
        return .success([
            "message_seq": .number(Double(message.seq)),
            "time": MilkyEntityEncoder.timestamp(message.time),
        ])
    }

    /// `recall_private_message` and `recall_group_message`.
    ///
    /// Milky names a message by `(scene, peer, seq)`, so the row has to be found
    /// before `PlatformService`, which keys on the message ID, can act on it.
    func recallMessage(_ call: ProtocolCall, scene: ChatScene) async throws -> ProtocolReply {
        guard let peerID = call.id(scene == .group ? "group_id" : "user_id") else {
            return invalidParameter(scene == .group ? "Missing group_id" : "Missing user_id")
        }
        guard let seq = call.int64("message_seq") else {
            return invalidParameter("Missing message_seq")
        }
        guard
            let message = try await platform.store.message(
                scene: scene,
                peerID: peerID,
                seq: seq,
                selfID: selfID
            )
        else {
            throw PlatformError.messageNotFound("\(scene.rawValue):\(peerID):\(seq)")
        }

        try await platform.recallMessage(id: message.id, operatorID: selfID)
        return .success()
    }

    func getMessage(_ call: ProtocolCall) async throws -> ProtocolReply {
        guard let scene = messageScene(call) else {
            return invalidParameter("Missing or invalid message_scene")
        }
        guard let peerID = call.id("peer_id") else {
            return invalidParameter("Missing peer_id")
        }
        guard let seq = call.int64("message_seq") else {
            return invalidParameter("Missing message_seq")
        }
        guard
            let message = try await platform.store.message(
                scene: scene,
                peerID: peerID,
                seq: seq,
                selfID: selfID
            )
        else {
            throw PlatformError.messageNotFound("\(scene.rawValue):\(peerID):\(seq)")
        }

        let segments = await segmentCoder.encodeIncoming(message.content)
        return .success(["message": await entityEncoder.incomingMessage(message, segments: segments)])
    }

    func getHistoryMessages(_ call: ProtocolCall) async throws -> ProtocolReply {
        guard let scene = messageScene(call) else {
            return invalidParameter("Missing or invalid message_scene")
        }
        guard let peerID = call.id("peer_id") else {
            return invalidParameter("Missing peer_id")
        }
        // The spec caps a page at 30 and defaults to 20; a larger request is clamped
        // rather than refused.
        let limit = min(max(call.int("limit") ?? 20, 1), 30)
        let history = try await platform.store.history(
            scene: scene,
            peerID: peerID,
            selfID: selfID,
            startSeq: call.int64("start_message_seq"),
            limit: limit
        )

        var payload: [JSONValue] = []
        for message in history {
            let segments = await segmentCoder.encodeIncoming(message.content)
            payload.append(await entityEncoder.incomingMessage(message, segments: segments))
        }

        var data: [String: JSONValue] = ["messages": .array(payload)]
        // `next_message_seq` is where a framework would resume paging backwards, so it
        // belongs only when something older than this page exists. Sequences are dense
        // from 1, so the oldest returned one being above 1 is that test. The field is
        // optional in Milky; emitting a fabricated sentinel on the final page would
        // make consumers loop forever.
        if let oldest = history.first?.seq, oldest > 1 {
            data["next_message_seq"] = .number(Double(oldest - 1))
        }
        return .success(.object(data))
    }

    func getResourceTempURL(_ call: ProtocolCall) async throws -> ProtocolReply {
        guard let resourceID = call.id("resource_id") else {
            return invalidParameter("Missing resource_id")
        }
        guard let asset = try await platform.store.asset(id: resourceID) else {
            // No platform error names a missing asset, and Milky's retcode set is too
            // small to care: this is the catch-all -404 either way.
            throw PlatformError.notPermitted("Resource not found: \(resourceID)")
        }

        // The protocol implementation does not know the host and port the transport bound to, so it
        // cannot mint an HTTP URL. A reference the asset already carries is the honest
        // answer; for bytes that only ever existed inline, the `rei-asset://` form
        // the rest of the app uses for local references is returned instead.
        let url: String
        switch asset.source {
        case .remote(let remote): url = remote
        case .local(let path): url = URL(fileURLWithPath: path).absoluteString
        case .inline: url = "rei-asset://\(asset.id)"
        }
        return .success(["url": .string(url)])
    }

    func getForwardedMessages(_ call: ProtocolCall) async throws -> ProtocolReply {
        guard let forwardID = call.string("forward_id"), !forwardID.isEmpty else {
            return invalidParameter("Missing forward_id")
        }
        guard let nodes = try await platform.store.forwardNodes(id: forwardID, selfID: selfID) else {
            throw PlatformError.messageNotFound("forward:\(forwardID)")
        }

        var messages: [JSONValue] = []
        for node in nodes {
            let storedMessage = try? await platform.store.message(id: node.id)
            let sourceSequence = storedMessage?.selfID == selfID ? storedMessage?.seq : nil
            let sender = try? await platform.store.user(id: node.senderID)
            messages.append([
                // Milky defines this as the source-conversation sequence. Inline
                // OutgoingForwardedMessage nodes do not carry one, so use the
                // protocol's unknown integer value rather than inventing a position.
                // A node whose ID references a stored message keeps its real sequence.
                "message_seq": .number(Double(sourceSequence ?? 0)),
                "sender_name": .string(node.senderName),
                "avatar_url": .string(Self.forwardAvatarURL(sender?.avatar)),
                "time": MilkyEntityEncoder.timestamp(node.time),
                "segments": .array(await segmentCoder.encodeIncoming(node.content)),
            ])
        }
        return .success(["messages": .array(messages)])
    }

    private static func forwardAvatarURL(_ value: String?) -> String {
        guard let value,
            let url = URL(string: value),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else { return "" }
        return url.absoluteString
    }

    // MARK: - Friends

    func sendFriendNudge(_ call: ProtocolCall) async throws -> ProtocolReply {
        guard let userID = call.id("user_id") else {
            return invalidParameter("Missing user_id")
        }
        // `is_self` nudges the bot's own avatar in that friend's chat, so the target is
        // the bot rather than the friend while the conversation stays the same.
        let isSelf = call.bool("is_self") ?? false
        try await platform.poke(
            scene: .friend,
            peerID: userID,
            senderID: selfID,
            targetID: isSelf ? selfID : userID
        )
        return .success()
    }

    func deleteFriend(_ call: ProtocolCall) async throws -> ProtocolReply {
        guard let userID = call.id("user_id") else {
            return invalidParameter("Missing user_id")
        }
        try await platform.removeFriend(userID: selfID, friendID: userID)
        return .success()
    }

    func getFriendRequests(_ call: ProtocolCall) async throws -> ProtocolReply {
        let limit = max(call.int("limit") ?? 20, 1)
        let requests = try await platform.store.pendingRequests(selfID: selfID, kind: .friend)
        let payload = requests.prefix(limit).map { entityEncoder.friendRequest($0) }
        return .success(["requests": .array(payload)])
    }

    /// `accept_friend_request` and `reject_friend_request`.
    ///
    /// Keyed by `initiator_uid`, which `MilkyEntityEncoder.friendRequest` emits from
    /// the request's flag, so it maps straight back to a stored request.
    func resolveFriendRequest(_ call: ProtocolCall, approve: Bool) async throws -> ProtocolReply {
        guard let flag = call.string("initiator_uid") else {
            return invalidParameter("Missing initiator_uid")
        }
        try await platform.resolveRequest(
            flag: flag,
            approve: approve,
            reason: call.string("reason") ?? ""
        )
        return .success()
    }

    // MARK: - Groups

    func setGroupName(_ call: ProtocolCall) async throws -> ProtocolReply {
        guard let groupID = call.id("group_id") else {
            return invalidParameter("Missing group_id")
        }
        guard let name = call.string("new_group_name") else {
            return invalidParameter("Missing new_group_name")
        }
        try await platform.setGroupName(groupID: groupID, operatorID: selfID, name: name)
        return .success()
    }

    func setGroupMemberCard(_ call: ProtocolCall) async throws -> ProtocolReply {
        guard let groupID = call.id("group_id"), let userID = call.id("user_id") else {
            return invalidParameter("Missing group_id or user_id")
        }
        try await platform.setMemberCard(
            groupID: groupID,
            userID: userID,
            operatorID: selfID,
            card: call.string("card") ?? ""
        )
        return .success()
    }

    func setGroupMemberTitle(_ call: ProtocolCall) async throws -> ProtocolReply {
        guard let groupID = call.id("group_id"), let userID = call.id("user_id") else {
            return invalidParameter("Missing group_id or user_id")
        }
        try await platform.setMemberTitle(
            groupID: groupID,
            userID: userID,
            operatorID: selfID,
            title: call.string("special_title") ?? ""
        )
        return .success()
    }

    func setGroupMemberAdmin(_ call: ProtocolCall) async throws -> ProtocolReply {
        guard let groupID = call.id("group_id"), let userID = call.id("user_id") else {
            return invalidParameter("Missing group_id or user_id")
        }
        try await platform.setAdmin(
            groupID: groupID,
            userID: userID,
            operatorID: selfID,
            granted: call.bool("is_set") ?? true
        )
        return .success()
    }

    func setGroupMemberMute(_ call: ProtocolCall) async throws -> ProtocolReply {
        guard let groupID = call.id("group_id"), let userID = call.id("user_id") else {
            return invalidParameter("Missing group_id or user_id")
        }
        // Milky spells out the duration in seconds with zero meaning "unmute", which
        // `muteMember` already reads the same way.
        try await platform.muteMember(
            groupID: groupID,
            userID: userID,
            operatorID: selfID,
            duration: TimeInterval(call.int("duration") ?? 0)
        )
        return .success()
    }

    func setGroupWholeMute(_ call: ProtocolCall) async throws -> ProtocolReply {
        guard let groupID = call.id("group_id") else {
            return invalidParameter("Missing group_id")
        }
        try await platform.setWholeMute(
            groupID: groupID,
            operatorID: selfID,
            muted: call.bool("is_mute") ?? true
        )
        return .success()
    }

    func kickGroupMember(_ call: ProtocolCall) async throws -> ProtocolReply {
        guard let groupID = call.id("group_id"), let userID = call.id("user_id") else {
            return invalidParameter("Missing group_id or user_id")
        }
        // `reject_add_request` blocklists the member against rejoining. Rei keeps no
        // per-group blocklist, so the flag is read and discarded rather than refused.
        _ = call.bool("reject_add_request")
        try await platform.removeMember(
            groupID: groupID,
            userID: userID,
            operatorID: selfID,
            reason: .administrative
        )
        return .success()
    }

    func quitGroup(_ call: ProtocolCall) async throws -> ProtocolReply {
        guard let groupID = call.id("group_id") else {
            return invalidParameter("Missing group_id")
        }
        try await platform.removeMember(
            groupID: groupID,
            userID: selfID,
            operatorID: selfID,
            reason: .voluntary
        )
        return .success()
    }

    func sendGroupNudge(_ call: ProtocolCall) async throws -> ProtocolReply {
        guard let groupID = call.id("group_id"), let userID = call.id("user_id") else {
            return invalidParameter("Missing group_id or user_id")
        }
        try await platform.poke(scene: .group, peerID: groupID, senderID: selfID, targetID: userID)
        return .success()
    }

    func sendGroupMessageReaction(_ call: ProtocolCall) async throws -> ProtocolReply {
        guard let groupID = call.id("group_id") else {
            return invalidParameter("Missing group_id")
        }
        guard let seq = call.int64("message_seq") else {
            return invalidParameter("Missing message_seq")
        }
        guard let reaction = call.string("reaction") else {
            return invalidParameter("Missing reaction")
        }
        guard
            let message = try await platform.store.message(
                scene: .group,
                peerID: groupID,
                seq: seq,
                selfID: selfID
            )
        else {
            throw PlatformError.messageNotFound("group:\(groupID):\(seq)")
        }

        // `reaction_type` splits QQ faces from emoji, a distinction the domain model
        // does not draw: a reaction is just its identifier here.
        _ = call.string("reaction_type")
        try await platform.react(
            messageID: message.id,
            userID: selfID,
            reaction: reaction,
            added: call.bool("is_add") ?? true
        )
        return .success()
    }

    func getGroupNotifications(_ call: ProtocolCall) async throws -> ProtocolReply {
        let limit = max(call.int("limit") ?? 20, 1)
        // Invitations addressed to the bot have their own `group_invitation` event
        // and invitation APIs. They are not `GroupNotification` values.
        let requests =
            call.bool("is_filtered") == true
            ? []
            : try await platform.store.pendingRequests(
                selfID: selfID,
                kind: .groupJoin
            )
        // Descending by sequence, which the spec asks for and which is unrelated to
        // arrival order because the sequence is derived from the flag.
        var numbered =
            requests
            .map { (request: $0, seq: MilkyEventEncoder.notificationSeq(for: $0)) }
            .sorted { $0.seq > $1.seq }
        if let start = call.int64("start_notification_seq") {
            numbered = numbered.filter { $0.seq <= start }
        }

        let page = numbered.prefix(limit)
        var data: [String: JSONValue] = [
            "notifications": .array(page.map { entityEncoder.groupNotification($0.request, seq: $0.seq) })
        ]
        // Optional by protocol: absence means this is the final page.
        if numbered.count > page.count, let last = page.last {
            data["next_notification_seq"] = .number(Double(last.seq - 1))
        }
        return .success(.object(data))
    }

    /// `accept_group_request` and `reject_group_request`.
    func resolveGroupRequest(_ call: ProtocolCall, approve: Bool) async throws -> ProtocolReply {
        guard let seq = call.int64("notification_seq") else {
            return invalidParameter("Missing notification_seq")
        }
        guard let groupID = call.id("group_id") else {
            return invalidParameter("Missing group_id")
        }
        guard call.string("notification_type") == "join_request" else {
            return invalidParameter("Only join_request notifications are supported")
        }
        guard call.bool("is_filtered") != true else {
            throw PlatformError.requestNotFound(String(seq))
        }
        guard
            let request = try await groupRequest(
                seq: seq,
                kind: .groupJoin,
                groupID: groupID
            )
        else {
            throw PlatformError.requestNotFound(String(seq))
        }
        try await platform.resolveRequest(
            flag: request.flag,
            approve: approve,
            reason: call.string("reason") ?? ""
        )
        return .success()
    }

    /// `accept_group_invitation` and `reject_group_invitation`, which quote
    /// `invitation_seq` where the notification APIs quote `notification_seq`.
    func resolveGroupInvitation(_ call: ProtocolCall, approve: Bool) async throws -> ProtocolReply {
        guard let seq = call.int64("invitation_seq") else {
            return invalidParameter("Missing invitation_seq")
        }
        guard let groupID = call.id("group_id") else {
            return invalidParameter("Missing group_id")
        }
        guard
            let request = try await groupRequest(
                seq: seq,
                kind: .groupInvite,
                groupID: groupID
            )
        else {
            throw PlatformError.requestNotFound(String(seq))
        }
        try await platform.resolveRequest(flag: request.flag, approve: approve)
        return .success()
    }

    // MARK: - Helpers

    /// Finds the request a Milky sequence number refers to.
    ///
    /// The sequence is a hash of the flag, so it cannot be inverted arithmetically:
    /// the pending requests are re-hashed and matched instead. That keeps the mapping
    /// stable across restarts without storing a second key.
    private func groupRequest(
        seq: Int64,
        kind: PendingRequest.Kind,
        groupID: String
    ) async throws -> PendingRequest? {
        try await platform.store.pendingRequests(selfID: selfID, kind: kind).first {
            $0.groupID == groupID && MilkyEventEncoder.notificationSeq(for: $0) == seq
        }
    }

    /// Reads Milky's `message_scene` discriminator.
    private func messageScene(_ call: ProtocolCall) -> ChatScene? {
        call.string("message_scene").flatMap(ChatScene.init(rawValue:))
    }
}
