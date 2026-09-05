import Foundation
import ReiCore
import ReiProtocol

/// Milky 1.3.
///
/// Structurally unlike OneBot in three ways that shape this implementation:
///
/// - The action name is the URL path (`POST /api/:api`), so there is no `action`
///   field and no `echo` — calls are plain HTTP request/response. The WebSocket at
///   `/event` is push-only.
/// - A message is identified by `(message_scene, peer_id, message_seq)` rather than a
///   standalone ID, and recall is split into per-scene endpoints.
/// - Return codes are negative and few: `0`, `-400`, `-403`, `-404`, with `-404` the
///   explicit catch-all.
public final class MilkyProtocolImplementation: ProtocolImplementation, @unchecked Sendable {
    public static var identifier: String { "milky" }
    public static var displayName: String { "Milky 1.3" }
    /// Milky always exposes its HTTP API; event delivery is selected independently.
    public static var supportedTransports: Set<TransportMode> {
        [.milkyService]
    }

    /// The version string reported by `get_impl_info`.
    public static let milkyVersion = "1.3"

    public let selfID: String

    let platform: PlatformService
    let entityEncoder: MilkyEntityEncoder
    let segmentCoder: MilkySegmentCoder
    private let eventEncoder: MilkyEventEncoder

    public init(selfID: String, platform: PlatformService, assetResolver: any MilkyAssetResolving) {
        self.selfID = selfID
        self.platform = platform
        let entities = MilkyEntityEncoder(store: platform.store)
        entityEncoder = entities
        let coder = MilkySegmentCoder(assetResolver: assetResolver)
        segmentCoder = coder
        eventEncoder = MilkyEventEncoder(
            selfID: selfID,
            segmentCoder: coder,
            entityEncoder: entities
        )
    }

    // MARK: - Inbound

    public func handle(call: ProtocolCall) async -> ProtocolReply {
        do {
            guard let handler = Self.apis[call.name] else {
                // Milky answers an unknown route with HTTP 404, not a retcode.
                return ProtocolReply(
                    retcode: -404,
                    message: "Requested API does not exist: \(call.name)",
                    httpStatus: 404
                )
            }
            return try await handler(self, call)
        } catch let error as PlatformError {
            return failure(error)
        } catch {
            return ProtocolReply(retcode: -404, message: error.localizedDescription)
        }
    }

    /// The API table, keyed by the path segment after `/api/`.
    static let apis: [String: @Sendable (MilkyProtocolImplementation, ProtocolCall) async throws -> ProtocolReply] = [
        // System
        "get_login_info": { implementation, _ in await implementation.getLoginInfo() },
        "get_impl_info": { implementation, _ in implementation.getImplInfo() },
        "get_user_profile": { try await $0.getUserProfile($1) },
        "get_friend_list": { implementation, _ in await implementation.getFriendList() },
        "get_friend_info": { try await $0.getFriendInfo($1) },
        "get_group_list": { implementation, _ in await implementation.getGroupList() },
        "get_group_info": { try await $0.getGroupInfo($1) },
        "get_group_member_list": { try await $0.getGroupMemberList($1) },
        "get_group_member_info": { try await $0.getGroupMemberInfo($1) },
        "get_cookies": { _, _ in .success(["cookies": .string("")]) },
        "get_csrf_token": { _, _ in .success(["csrf_token": .string("")]) },

        // Messages
        "send_private_message": { try await $0.sendMessage($1, scene: .friend) },
        "send_group_message": { try await $0.sendMessage($1, scene: .group) },
        "recall_private_message": { try await $0.recallMessage($1, scene: .friend) },
        "recall_group_message": { try await $0.recallMessage($1, scene: .group) },
        "get_message": { try await $0.getMessage($1) },
        "get_history_messages": { try await $0.getHistoryMessages($1) },
        "get_resource_temp_url": { try await $0.getResourceTempURL($1) },
        "get_forwarded_messages": { try await $0.getForwardedMessages($1) },
        "mark_message_as_read": { _, _ in .success() },

        // Friends
        "send_friend_nudge": { try await $0.sendFriendNudge($1) },
        "send_profile_like": { _, _ in .success() },
        "delete_friend": { try await $0.deleteFriend($1) },
        "get_friend_requests": { try await $0.getFriendRequests($1) },
        "accept_friend_request": { try await $0.resolveFriendRequest($1, approve: true) },
        "reject_friend_request": { try await $0.resolveFriendRequest($1, approve: false) },

        // Groups
        "set_group_name": { try await $0.setGroupName($1) },
        "set_group_member_card": { try await $0.setGroupMemberCard($1) },
        "set_group_member_special_title": { try await $0.setGroupMemberTitle($1) },
        "set_group_member_admin": { try await $0.setGroupMemberAdmin($1) },
        "set_group_member_mute": { try await $0.setGroupMemberMute($1) },
        "set_group_whole_mute": { try await $0.setGroupWholeMute($1) },
        "kick_group_member": { try await $0.kickGroupMember($1) },
        "quit_group": { try await $0.quitGroup($1) },
        "send_group_nudge": { try await $0.sendGroupNudge($1) },
        "send_group_message_reaction": { try await $0.sendGroupMessageReaction($1) },
        "get_group_notifications": { try await $0.getGroupNotifications($1) },
        "accept_group_request": { try await $0.resolveGroupRequest($1, approve: true) },
        "reject_group_request": { try await $0.resolveGroupRequest($1, approve: false) },
        "accept_group_invitation": { try await $0.resolveGroupInvitation($1, approve: true) },
        "reject_group_invitation": { try await $0.resolveGroupInvitation($1, approve: false) },
    ]

    // MARK: - Outbound

    public func encode(event: DomainEvent) async -> [OutboundFrame] {
        guard event.selfID == selfID else { return [] }
        return await eventEncoder.encode(event).map { payload in
            // SSE streams name their events; the WebSocket transport ignores this.
            OutboundFrame(payload: payload, eventName: "milky_event")
        }
    }

    /// Milky defines no connect or lifecycle event, so nothing is sent on connect.
    public func handshakeFrames() async -> [OutboundFrame] { [] }

    /// Milky has no heartbeat. Sending one would be inventing protocol.
    public var heartbeatInterval: TimeInterval? { nil }

    // MARK: - Envelope

    /// Wraps a reply in Milky's response envelope.
    ///
    /// `status` derives from `retcode`, and `message` appears only on failure —
    /// successful responses carry `data`, which is `{}` for APIs with no output.
    public func envelope(for reply: ProtocolReply) -> JSONValue {
        if reply.isSuccess {
            return [
                "status": "ok",
                "retcode": 0,
                "data": reply.data,
            ]
        }
        return [
            "status": "failed",
            "retcode": .number(Double(reply.retcode)),
            "message": .string(reply.message),
        ]
    }

    public func envelope(for reply: ProtocolReply, echo: JSONValue?) -> JSONValue {
        envelope(for: reply)
    }

    /// Maps a platform refusal to Milky's small negative retcode set.
    func failure(_ error: PlatformError) -> ProtocolReply {
        let retcode: Int
        switch error {
        case .invalidParameter:
            retcode = -400
        // Everything else is the documented catch-all, whose meaning the protocol
        // side is free to define.
        case .userNotFound, .groupNotFound, .messageNotFound, .requestNotFound,
            .notAMember, .muted, .wholeGroupMuted, .notPermitted, .alreadyExists:
            retcode = -404
        }
        return ProtocolReply(retcode: retcode, message: error.localizedDescription)
    }

    func invalidParameter(_ detail: String) -> ProtocolReply {
        ProtocolReply(retcode: -400, message: detail)
    }
}

@available(*, deprecated, renamed: "MilkyProtocolImplementation")
public typealias MilkyAdapter = MilkyProtocolImplementation

/// The asset and cross-reference lookups Milky needs.
///
/// An alias rather than a refining protocol: the app has to be able to name this
/// type to construct an implementation, and a public protocol cannot refine an internal
/// one.
public typealias MilkyAssetResolving = MilkyAssetResolver
