import Foundation
import MatchaCore
import MatchaProtocol

/// The action implementations.
///
/// Read-only actions consult the store; anything that mutates goes through
/// `PlatformService`, so a framework's action produces the same events an operator's
/// click would.
extension OneBotProtocolImplementation {
    // MARK: - Messaging

    func sendMessage(_ call: ProtocolCall, forcedScene: ChatScene? = nil) async throws -> ProtocolReply {
        let scene = try resolveScene(call, forced: forcedScene)
        guard let peerID = peerID(from: call, scene: scene) else {
            return invalidParameter(scene == .group ? "Missing group_id" : "Missing user_id")
        }

        let content = try await decodeContent(from: call)
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

        switch version {
        case .v11:
            // v11 declares message_id as an integer.
            return .success(["message_id": numeric(message.id)])
        case .v12:
            return .success([
                "message_id": .string(message.id),
                "time": .number(message.time.timeIntervalSince1970),
            ])
        }
    }

    func deleteMessage(_ call: ProtocolCall) async throws -> ProtocolReply {
        guard let messageID = call.id("message_id") else {
            return invalidParameter("Missing message_id")
        }
        try await platform.recallMessage(id: messageID, operatorID: selfID)
        return .success()
    }

    func getMessage(_ call: ProtocolCall) async throws -> ProtocolReply {
        guard let messageID = call.id("message_id") else {
            return invalidParameter("Missing message_id")
        }
        guard let message = try await platform.store.message(id: messageID) else {
            throw PlatformError.messageNotFound(messageID)
        }

        let segments = await segmentCoder.encode(message.content)
        let sender = await context.senderInfo(
            userID: message.senderID,
            groupID: message.scene == .group ? message.peerID : nil
        )

        switch version {
        case .v11:
            return .success([
                "time": .number(message.time.timeIntervalSince1970),
                "message_type": .string(message.scene == .group ? "group" : "private"),
                "message_id": numeric(message.id),
                "real_id": numeric(message.id),
                "sender": sender.asV11JSON(usesNumericIDs: true),
                "message": .array(segments),
            ])
        case .v12:
            var payload: [String: JSONValue] = [
                "message_id": .string(message.id),
                "time": .number(message.time.timeIntervalSince1970),
                "message_type": .string(message.scene == .group ? "group" : "private"),
                "user_id": .string(message.senderID),
                "message": .array(segments),
                "alt_message": .string(message.content.textPreview),
            ]
            if message.scene == .group {
                payload["group_id"] = .string(message.peerID)
            }
            return .success(.object(payload))
        }
    }

    // MARK: - Identity

    func loginInfo() async -> ProtocolReply {
        let user = try? await platform.store.user(id: selfID)
        let nickname = user?.displayName ?? selfID
        switch version {
        case .v11:
            return .success(["user_id": numeric(selfID), "nickname": .string(nickname)])
        case .v12:
            return .success([
                "user_id": .string(selfID),
                "user_name": .string(nickname),
                "user_displayname": .string(nickname),
            ])
        }
    }

    func userInfo(_ call: ProtocolCall) async throws -> ProtocolReply {
        guard let userID = call.id("user_id") else {
            return invalidParameter("Missing user_id")
        }
        guard var info = await context.userInfo(userID: userID) else {
            throw PlatformError.userNotFound(userID)
        }
        if version == .v11 {
            info = info.merging(["user_id": numeric(userID)])
        }
        return .success(info)
    }

    func friendList() async -> ProtocolReply {
        let friends = (try? await platform.store.friends(of: selfID)) ?? []
        let payload = friends.map { entry -> JSONValue in
            switch version {
            case .v11:
                return [
                    "user_id": numeric(entry.user.id),
                    "nickname": .string(entry.user.displayName),
                    "remark": .string(entry.friendship.remark),
                ]
            case .v12:
                return [
                    "user_id": .string(entry.user.id),
                    "user_name": .string(entry.user.displayName),
                    "user_displayname": .string(entry.friendship.remark),
                    "user_remark": .string(entry.friendship.remark),
                ]
            }
        }
        return .success(.array(payload))
    }

    // MARK: - Groups

    func groupInfo(_ call: ProtocolCall) async throws -> ProtocolReply {
        guard let groupID = call.id("group_id") else {
            return invalidParameter("Missing group_id")
        }
        guard var info = await context.groupInfo(groupID: groupID) else {
            throw PlatformError.groupNotFound(groupID)
        }
        if version == .v11 {
            info = info.merging(["group_id": numeric(groupID)])
        }
        return .success(info)
    }

    func groupList() async -> ProtocolReply {
        let groups = (try? await platform.store.allGroups()) ?? []
        var payload: [JSONValue] = []
        for group in groups {
            guard var info = await context.groupInfo(groupID: group.id) else { continue }
            if version == .v11 {
                info = info.merging(["group_id": numeric(group.id)])
            }
            payload.append(info)
        }
        return .success(.array(payload))
    }

    func memberInfo(_ call: ProtocolCall) async throws -> ProtocolReply {
        guard let groupID = call.id("group_id"), let userID = call.id("user_id") else {
            return invalidParameter("Missing group_id or user_id")
        }
        guard var info = await context.memberInfo(groupID: groupID, userID: userID) else {
            throw PlatformError.notAMember(groupID: groupID, userID: userID)
        }
        if version == .v11 {
            info = info.merging(["group_id": numeric(groupID), "user_id": numeric(userID)])
        }
        return .success(info)
    }

    func memberList(_ call: ProtocolCall) async throws -> ProtocolReply {
        guard let groupID = call.id("group_id") else {
            return invalidParameter("Missing group_id")
        }
        guard try await platform.store.group(id: groupID) != nil else {
            throw PlatformError.groupNotFound(groupID)
        }
        let members = try await platform.store.members(groupID: groupID)
        var payload: [JSONValue] = []
        for member in members {
            guard var info = await context.memberInfo(groupID: groupID, userID: member.userID) else { continue }
            if version == .v11 {
                info = info.merging(["group_id": numeric(groupID), "user_id": numeric(member.userID)])
            }
            payload.append(info)
        }
        return .success(.array(payload))
    }

    func setGroupName(_ call: ProtocolCall) async throws -> ProtocolReply {
        guard let groupID = call.id("group_id") else {
            return invalidParameter("Missing group_id")
        }
        guard let name = call.string("group_name") else {
            return invalidParameter("Missing group_name")
        }
        try await platform.setGroupName(groupID: groupID, operatorID: selfID, name: name)
        return .success()
    }

    func setGroupCard(_ call: ProtocolCall) async throws -> ProtocolReply {
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

    func setGroupTitle(_ call: ProtocolCall) async throws -> ProtocolReply {
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

    func setGroupAdmin(_ call: ProtocolCall) async throws -> ProtocolReply {
        guard let groupID = call.id("group_id"), let userID = call.id("user_id") else {
            return invalidParameter("Missing group_id or user_id")
        }
        try await platform.setAdmin(
            groupID: groupID,
            userID: userID,
            operatorID: selfID,
            granted: call.bool("enable") ?? true
        )
        return .success()
    }

    func setGroupBan(_ call: ProtocolCall) async throws -> ProtocolReply {
        guard let groupID = call.id("group_id"), let userID = call.id("user_id") else {
            return invalidParameter("Missing group_id or user_id")
        }
        // v11 documents the default as 30 minutes.
        let duration = TimeInterval(call.int("duration") ?? 1800)
        try await platform.muteMember(
            groupID: groupID,
            userID: userID,
            operatorID: selfID,
            duration: duration
        )
        return .success()
    }

    func setGroupWholeBan(_ call: ProtocolCall) async throws -> ProtocolReply {
        guard let groupID = call.id("group_id") else {
            return invalidParameter("Missing group_id")
        }
        try await platform.setWholeMute(
            groupID: groupID,
            operatorID: selfID,
            muted: call.bool("enable") ?? true
        )
        return .success()
    }

    func kickMember(_ call: ProtocolCall) async throws -> ProtocolReply {
        guard let groupID = call.id("group_id"), let userID = call.id("user_id") else {
            return invalidParameter("Missing group_id or user_id")
        }
        try await platform.removeMember(
            groupID: groupID,
            userID: userID,
            operatorID: selfID,
            reason: .administrative
        )
        return .success()
    }

    func leaveGroup(_ call: ProtocolCall) async throws -> ProtocolReply {
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

    // MARK: - Requests

    func resolveRequest(_ call: ProtocolCall) async throws -> ProtocolReply {
        guard let flag = call.string("flag") else {
            return invalidParameter("Missing flag")
        }
        try await platform.resolveRequest(
            flag: flag,
            approve: call.bool("approve") ?? true,
            reason: call.string("reason") ?? "",
            remark: call.string("remark") ?? ""
        )
        return .success()
    }

    // MARK: - Capability

    func status() -> ProtocolReply {
        switch version {
        case .v11:
            return .success(["online": true, "good": true])
        case .v12:
            return .success([
                "good": true,
                "bots": [["self": ["platform": "matcha", "user_id": .string(selfID)], "online": true]],
            ])
        }
    }

    func versionInfo() -> ProtocolReply {
        switch version {
        case .v11:
            return .success([
                "app_name": "matcha",
                "app_version": .string(MatchaVersion.current),
                "protocol_version": "v11",
            ])
        case .v12:
            return .success([
                "impl": "matcha",
                "version": .string(MatchaVersion.current),
                "onebot_version": "12",
            ])
        }
    }

    func supportedActions() -> ProtocolReply {
        .success(.array(Self.actions.keys.sorted().map { .string($0) }))
    }

    // MARK: - Shared helpers

    /// Works out which conversation an action targets.
    private func resolveScene(_ call: ProtocolCall, forced: ChatScene?) throws -> ChatScene {
        if let forced { return forced }
        // v11 names it message_type, v12 detail_type; both may be omitted, in which
        // case the presence of group_id decides.
        let declared = call.string("message_type") ?? call.string("detail_type")
        switch declared {
        case "group": return .group
        case "private": return .friend
        default:
            return call.id("group_id") != nil ? .group : .friend
        }
    }

    private func peerID(from call: ProtocolCall, scene: ChatScene) -> String? {
        scene == .group ? call.id("group_id") : call.id("user_id")
    }

    /// Reads the `message` parameter, accepting either the array form or v11's
    /// legacy plain-string form.
    private func decodeContent(from call: ProtocolCall) async throws -> [MessageSegment] {
        guard let raw = call.parameters["message"] else {
            throw PlatformError.invalidParameter("Missing message")
        }
        if let segments = raw.arrayValue {
            return await segmentCoder.decode(segments)
        }
        if let text = raw.stringValue {
            // A bare string is a v11 convenience; CQ-code parsing is deliberately not
            // implemented, so it is taken as literal text.
            return [.text(text)]
        }
        throw PlatformError.invalidParameter("message must be an array or string")
    }

    func numeric(_ value: String) -> JSONValue {
        guard let number = Int64(value) else { return .string(value) }
        return .number(Double(number))
    }

    func invalidParameter(_ detail: String) -> ProtocolReply {
        ProtocolReply(retcode: version == .v11 ? 1400 : 10003, message: detail)
    }

    func unsupportedAction(_ name: String) -> ProtocolReply {
        ProtocolReply(
            retcode: version == .v11 ? 1404 : 10002,
            message: "Unsupported action: \(name)"
        )
    }

    /// Maps a platform refusal to this version's return code.
    func failure(_ error: PlatformError) -> ProtocolReply {
        let retcode: Int
        switch error {
        case .userNotFound, .groupNotFound, .messageNotFound, .requestNotFound, .notAMember:
            retcode = version == .v11 ? 1404 : 1404
        case .invalidParameter:
            retcode = version == .v11 ? 1400 : 10003
        case .notPermitted, .muted, .wholeGroupMuted:
            retcode = version == .v11 ? 1403 : 34000
        case .alreadyExists:
            retcode = version == .v11 ? 1400 : 10003
        }
        return ProtocolReply(retcode: retcode, message: error.localizedDescription)
    }
}
