import Foundation
import MatchaCore

/// Group administration.
///
/// Permission rules are enforced here rather than in any protocol implementation, so a framework
/// gets the same refusal whichever protocol it speaks — and discovers, as it would
/// in production, that it lacks the authority for an operation.
public extension PlatformService {
    /// Adds a member and announces the join.
    @discardableResult
    func addMember(
        groupID: String,
        userID: String,
        operatorID: String? = nil,
        reason: DomainEvent.GroupMemberChange.Reason = .voluntary
    ) async throws -> GroupMember {
        guard let group = try await store.group(id: groupID) else {
            throw PlatformError.groupNotFound(groupID)
        }
        guard try await store.user(id: userID) != nil else {
            throw PlatformError.userNotFound(userID)
        }
        if let operatorID,
           try await store.member(groupID: groupID, userID: operatorID) == nil
        {
            throw PlatformError.notAMember(groupID: groupID, userID: operatorID)
        }
        if try await store.member(groupID: groupID, userID: userID) != nil {
            throw PlatformError.alreadyExists("User \(userID) is already a member of group \(groupID)")
        }
        let count = try await store.memberCount(groupID: groupID)
        guard count < group.maxMemberCount else {
            throw PlatformError.notPermitted("The group has reached its member limit of \(group.maxMemberCount)")
        }

        let member = GroupMember(groupID: groupID, userID: userID)
        try await store.save(member)

        try await publishToGroupBots(
            groupID: groupID,
            payload: .groupMemberAdded(
                .init(groupID: groupID, userID: userID, operatorID: operatorID ?? userID, reason: reason)
            ),
            origin: operatorID
        )
        return member
    }

    /// Removes a member, either by their own choice or by an administrator.
    func removeMember(
        groupID: String,
        userID: String,
        operatorID: String,
        reason: DomainEvent.GroupMemberChange.Reason = .voluntary
    ) async throws {
        guard try await store.member(groupID: groupID, userID: userID) != nil else {
            throw PlatformError.notAMember(groupID: groupID, userID: userID)
        }
        if operatorID != userID {
            try await requireAuthority(over: userID, in: groupID, by: operatorID, action: "remove a member")
        }

        // Bots in the group must be told before the membership row disappears,
        // otherwise the departing member's own session would not receive it.
        try await publishToGroupBots(
            groupID: groupID,
            payload: .groupMemberRemoved(
                .init(groupID: groupID, userID: userID, operatorID: operatorID, reason: reason)
            ),
            origin: operatorID
        )
        try await store.removeMember(groupID: groupID, userID: userID)
    }

    /// Grants or revokes administrator status. Only the owner may do this.
    func setAdmin(groupID: String, userID: String, operatorID: String, granted: Bool) async throws {
        guard var member = try await store.member(groupID: groupID, userID: userID) else {
            throw PlatformError.notAMember(groupID: groupID, userID: userID)
        }
        guard let actor = try await store.member(groupID: groupID, userID: operatorID), actor.role == .owner else {
            throw PlatformError.notPermitted("Only the group owner can manage administrators")
        }
        guard member.role != .owner else {
            throw PlatformError.notPermitted("The group owner's role cannot be changed")
        }

        member.role = granted ? .admin : .member
        try await store.save(member)

        try await publishToGroupBots(
            groupID: groupID,
            payload: .groupAdminChanged(
                .init(groupID: groupID, userID: userID, operatorID: operatorID, granted: granted)
            ),
            origin: operatorID
        )
    }

    /// Mutes or unmutes one member. A zero duration lifts the mute.
    func muteMember(groupID: String, userID: String, operatorID: String, duration: TimeInterval) async throws {
        guard var member = try await store.member(groupID: groupID, userID: userID) else {
            throw PlatformError.notAMember(groupID: groupID, userID: userID)
        }
        try await requireAuthority(over: userID, in: groupID, by: operatorID, action: "mute a member")

        member.mutedUntil = duration > 0 ? Date().addingTimeInterval(duration) : nil
        try await store.save(member)

        try await publishToGroupBots(
            groupID: groupID,
            payload: .groupMuted(
                // A zero duration is how both protocols spell "unmute".
                .init(
                    groupID: groupID,
                    userID: userID,
                    operatorID: operatorID,
                    muted: duration > 0,
                    duration: duration
                )
            ),
            origin: operatorID
        )
    }

    /// Mutes or unmutes everyone.
    func setWholeMute(groupID: String, operatorID: String, muted: Bool) async throws {
        guard var group = try await store.group(id: groupID) else {
            throw PlatformError.groupNotFound(groupID)
        }
        guard let actor = try await store.member(groupID: groupID, userID: operatorID), actor.role > .member else {
            throw PlatformError.notPermitted("Administrator privileges are required to change group-wide mute")
        }

        group.wholeMuted = muted
        try await store.save(group)

        try await publishToGroupBots(
            groupID: groupID,
            payload: .groupMuted(
                .init(groupID: groupID, userID: nil, operatorID: operatorID, muted: muted)
            ),
            origin: operatorID
        )
    }

    /// Renames a group.
    func setGroupName(groupID: String, operatorID: String, name: String) async throws {
        guard var group = try await store.group(id: groupID) else {
            throw PlatformError.groupNotFound(groupID)
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PlatformError.invalidParameter("Group name cannot be empty")
        }
        guard let actor = try await store.member(groupID: groupID, userID: operatorID), actor.role > .member else {
            throw PlatformError.notPermitted("Administrator privileges are required to rename the group")
        }

        group.name = trimmed
        try await store.save(group)

        try await publishToGroupBots(
            groupID: groupID,
            payload: .groupNameChanged(groupID: groupID, operatorID: operatorID, name: trimmed),
            origin: operatorID
        )
    }

    /// Sets a member's group-specific display name.
    ///
    /// Members may edit their own; administrators may edit others'.
    func setMemberCard(groupID: String, userID: String, operatorID: String, card: String) async throws {
        guard var member = try await store.member(groupID: groupID, userID: userID) else {
            throw PlatformError.notAMember(groupID: groupID, userID: userID)
        }
        if operatorID != userID {
            try await requireAuthority(over: userID, in: groupID, by: operatorID, action: "edit a member card")
        }
        member.card = card
        try await store.save(member)
    }

    /// Sets a member's honorific. Owner only, as on the real platform.
    func setMemberTitle(groupID: String, userID: String, operatorID: String, title: String) async throws {
        guard var member = try await store.member(groupID: groupID, userID: userID) else {
            throw PlatformError.notAMember(groupID: groupID, userID: userID)
        }
        guard let actor = try await store.member(groupID: groupID, userID: operatorID), actor.role == .owner else {
            throw PlatformError.notPermitted("Only the group owner can set custom titles")
        }
        member.title = title
        try await store.save(member)
    }

    /// Sends a nudge ("poke").
    func poke(scene: ChatScene, peerID: String, senderID: String, targetID: String) async throws {
        if scene == .group {
            guard try await store.member(groupID: peerID, userID: targetID) != nil else {
                throw PlatformError.notAMember(groupID: peerID, userID: targetID)
            }
        }
        let payload = DomainEvent.Payload.poke(
            .init(scene: scene, peerID: peerID, senderID: senderID, targetID: targetID)
        )
        if scene == .group {
            try await publishToGroupBots(groupID: peerID, payload: payload, origin: senderID)
        } else {
            publish(DomainEvent(selfID: targetID, payload: payload), origin: senderID)
        }
    }

    /// Adds or removes a reaction on a message.
    func react(messageID: String, userID: String, reaction: String, added: Bool) async throws {
        guard let message = try await store.message(id: messageID) else {
            throw PlatformError.messageNotFound(messageID)
        }
        publish(
            DomainEvent(
                selfID: message.selfID,
                payload: .messageReaction(
                    .init(
                        messageID: messageID,
                        scene: message.scene,
                        peerID: message.peerID,
                        userID: userID,
                        reaction: reaction,
                        added: added
                    )
                )
            ),
            origin: userID
        )
    }

    // MARK: - Helpers

    /// Checks that `operatorID` outranks `targetID` in the group.
    private func requireAuthority(
        over targetID: String,
        in groupID: String,
        by operatorID: String,
        action: String
    ) async throws {
        guard let actor = try await store.member(groupID: groupID, userID: operatorID) else {
            throw PlatformError.notAMember(groupID: groupID, userID: operatorID)
        }
        guard actor.role > .member else {
            throw PlatformError.notPermitted("Administrator privileges are required to \(action)")
        }
        if let target = try await store.member(groupID: groupID, userID: targetID), target.role >= actor.role {
            throw PlatformError.notPermitted("Cannot \(action) when the target has an equal or higher role")
        }
    }
}
