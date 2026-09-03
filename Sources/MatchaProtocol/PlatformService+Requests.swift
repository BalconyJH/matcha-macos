import Foundation
import MatchaCore

/// Friend and group requests.
///
/// A request is raised here, delivered to the framework as an event, and later
/// resolved when the framework calls the matching action. The `flag` is the token
/// that ties those two moments together.
public extension PlatformService {
    /// Someone asks to add a persona as a friend.
    @discardableResult
    func requestFriend(requesterID: String, targetID: String, comment: String = "") async throws -> PendingRequest {
        guard try await store.user(id: requesterID) != nil else {
            throw PlatformError.userNotFound(requesterID)
        }
        guard try await store.user(id: targetID) != nil else {
            throw PlatformError.userNotFound(targetID)
        }
        if try await store.friendship(userID: targetID, friendID: requesterID) != nil {
            throw PlatformError.alreadyExists("The users are already friends")
        }

        let request = PendingRequest(
            kind: .friend,
            requesterID: requesterID,
            selfID: targetID,
            comment: comment
        )
        try await store.save(request)
        publish(DomainEvent(selfID: targetID, payload: .requestReceived(request)), origin: requesterID)
        return request
    }

    /// Someone asks to join a group.
    @discardableResult
    func requestJoinGroup(
        groupID: String,
        requesterID: String,
        targetBotID: String,
        comment: String = ""
    ) async throws -> PendingRequest {
        guard try await store.group(id: groupID) != nil else {
            throw PlatformError.groupNotFound(groupID)
        }
        if try await store.member(groupID: groupID, userID: requesterID) != nil {
            throw PlatformError.alreadyExists("The user is already in the group")
        }

        let request = PendingRequest(
            kind: .groupJoin,
            requesterID: requesterID,
            groupID: groupID,
            selfID: targetBotID,
            comment: comment
        )
        try await store.save(request)
        publish(DomainEvent(selfID: targetBotID, payload: .requestReceived(request)), origin: requesterID)
        return request
    }

    /// Someone invites a bot into a group.
    @discardableResult
    func inviteToGroup(
        groupID: String,
        inviterID: String,
        inviteeID: String,
        comment: String = ""
    ) async throws -> PendingRequest {
        guard try await store.group(id: groupID) != nil else {
            throw PlatformError.groupNotFound(groupID)
        }
        let request = PendingRequest(
            kind: .groupInvite,
            requesterID: inviterID,
            groupID: groupID,
            selfID: inviteeID,
            comment: comment
        )
        try await store.save(request)
        publish(DomainEvent(selfID: inviteeID, payload: .requestReceived(request)), origin: inviterID)
        return request
    }

    /// Resolves a request the way the framework asked.
    ///
    /// Accepting has side effects — a friendship is recorded or a member joins — and
    /// those produce their own events, exactly as a real platform would.
    func resolveRequest(
        flag: String,
        approve: Bool,
        reason: String = "",
        remark: String = ""
    ) async throws {
        guard let request = try await store.request(flag: flag) else {
            throw PlatformError.requestNotFound(flag)
        }
        guard request.resolution == nil else {
            throw PlatformError.notPermitted("This request has already been resolved")
        }

        _ = try await store.resolve(
            requestID: request.id,
            as: approve ? .accepted : .rejected(reason: reason)
        )

        guard approve else { return }

        switch request.kind {
        case .friend:
            // Friendships are directional so each side keeps its own remark.
            try await store.save(
                Friendship(userID: request.selfID, friendID: request.requesterID, remark: remark)
            )
            try await store.save(
                Friendship(userID: request.requesterID, friendID: request.selfID)
            )
            publish(
                DomainEvent(selfID: request.selfID, payload: .friendAdded(userID: request.requesterID))
            )

        case .groupJoin:
            guard let groupID = request.groupID else {
                throw PlatformError.invalidParameter("The group join request is missing a group ID")
            }
            try await addMember(
                groupID: groupID,
                userID: request.requesterID,
                operatorID: request.selfID,
                reason: .administrative
            )

        case .groupInvite:
            guard let groupID = request.groupID else {
                throw PlatformError.invalidParameter("The group invitation is missing a group ID")
            }
            // The invitee joins; the inviter is the operator.
            try await addMember(
                groupID: groupID,
                userID: request.selfID,
                operatorID: request.requesterID,
                reason: .invited
            )
        }
    }

    /// Removes a friendship in both directions and announces it.
    func removeFriend(userID: String, friendID: String) async throws {
        guard try await store.friendship(userID: userID, friendID: friendID) != nil else {
            throw PlatformError.notPermitted("The users are not friends")
        }
        try await store.removeFriendship(userID: userID, friendID: friendID)
        publish(DomainEvent(selfID: userID, payload: .friendRemoved(userID: friendID)))
    }

    /// Records a friendship directly, skipping the request round-trip. Used when the
    /// operator wires up personas in the UI.
    func addFriendship(userID: String, friendID: String, remark: String = "") async throws {
        guard try await store.user(id: userID) != nil else {
            throw PlatformError.userNotFound(userID)
        }
        guard try await store.user(id: friendID) != nil else {
            throw PlatformError.userNotFound(friendID)
        }
        try await store.save(Friendship(userID: userID, friendID: friendID, remark: remark))
        try await store.save(Friendship(userID: friendID, friendID: userID))
        publish(DomainEvent(selfID: userID, payload: .friendAdded(userID: friendID)))
        publish(DomainEvent(selfID: friendID, payload: .friendAdded(userID: userID)))
    }

    /// Announces a file upload into a group.
    func uploadGroupFile(groupID: String, userID: String, asset: Asset) async throws {
        guard try await store.member(groupID: groupID, userID: userID) != nil else {
            throw PlatformError.notAMember(groupID: groupID, userID: userID)
        }
        try await store.save(asset)
        try await publishToGroupBots(
            groupID: groupID,
            payload: .groupFileUploaded(.init(groupID: groupID, userID: userID, asset: asset)),
            origin: userID
        )
    }
}
