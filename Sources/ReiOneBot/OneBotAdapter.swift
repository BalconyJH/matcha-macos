import Foundation
import ReiCore
import ReiProtocol

/// OneBot v11 and v12.
///
/// One class serves both versions: they share an action-dispatch model (a name plus
/// a parameter object, correlated by `echo`) and differ in vocabulary, which the
/// segment and event coders absorb. Where an action itself differs — v11's
/// `send_private_msg` versus v12's `send_message` — both names are registered and
/// route to the same implementation.
public final class OneBotProtocolImplementation: ProtocolImplementation, @unchecked Sendable {
    private static let implementationName = "rei"

    public static var identifier: String { "onebot" }
    public static var displayName: String { "OneBot" }
    public static var supportedTransports: Set<TransportMode> {
        [.webSocketServer, .webSocketClient]
    }

    public let version: OneBotVersion
    public let selfID: String

    // Visible module-wide so the action implementations in OneBotActions.swift can
    // reach them.
    let platform: PlatformService
    let context: OneBotContext
    let segmentCoder: OneBotSegmentCoder
    private let eventEncoder: OneBotEventEncoder

    public init(
        version: OneBotVersion,
        selfID: String,
        platform: PlatformService,
        assetResolver: AssetResolver
    ) {
        self.version = version
        self.selfID = selfID
        self.platform = platform
        context = OneBotContext(store: platform.store)
        let coder = OneBotSegmentCoder(version: version, assetResolver: assetResolver)
        segmentCoder = coder
        eventEncoder = OneBotEventEncoder(
            version: version,
            selfID: selfID,
            segmentCoder: coder,
            context: OneBotContext(store: platform.store)
        )
    }

    public var protocolDisplayName: String {
        version == .v11 ? "OneBot V11 Standard" : "OneBot V12 Standard"
    }

    public var webSocketClientHandshake: WebSocketClientHandshake {
        let userAgent = "Rei/\(ReiVersion.current)"
        switch version {
        case .v11:
            return WebSocketClientHandshake(
                defaultPath: version.noneBotReverseWebSocketPath,
                headers: [
                    ("X-Self-ID", selfID),
                    ("X-Client-Role", "Universal"),
                    ("User-Agent", userAgent),
                ]
            )
        case .v12:
            return WebSocketClientHandshake(
                defaultPath: version.noneBotReverseWebSocketPath,
                headers: [
                    ("User-Agent", userAgent)
                ],
                subprotocols: ["12.\(Self.implementationName)"]
            )
        }
    }

    // MARK: - Inbound actions

    public func handle(call: ProtocolCall) async -> ProtocolReply {
        // v11 lets a framework append `_async` to any action to say it does not want
        // to wait. Rei answers everything promptly, so the suffix is stripped and
        // the action handled normally.
        let name =
            version == .v11 && call.name.hasSuffix("_async")
            ? String(call.name.dropLast("_async".count))
            : call.name

        do {
            guard let handler = Self.actions[name] else {
                return unsupportedAction(name)
            }
            return try await handler(self, call)
        } catch let error as PlatformError {
            return failure(error)
        } catch {
            return ProtocolReply(
                retcode: version == .v11 ? 1000 : 20002,
                message: error.localizedDescription
            )
        }
    }

    /// The action table.
    ///
    /// Static so `get_supported_actions` can report exactly what is dispatchable —
    /// the table is its own manifest and cannot drift from what is implemented.
    static let actions: [String: @Sendable (OneBotProtocolImplementation, ProtocolCall) async throws -> ProtocolReply] =
        [
            // Sending
            "send_msg": { try await $0.sendMessage($1) },
            "send_private_msg": { try await $0.sendMessage($1, forcedScene: .friend) },
            "send_group_msg": { try await $0.sendMessage($1, forcedScene: .group) },
            "send_message": { try await $0.sendMessage($1) },

            // Recalling
            "delete_msg": { try await $0.deleteMessage($1) },
            "delete_message": { try await $0.deleteMessage($1) },
            "get_msg": { try await $0.getMessage($1) },
            "get_message": { try await $0.getMessage($1) },

            // Identity
            "get_login_info": { implementation, _ in await implementation.loginInfo() },
            "get_self_info": { implementation, _ in await implementation.loginInfo() },
            "get_stranger_info": { try await $0.userInfo($1) },
            "get_user_info": { try await $0.userInfo($1) },
            "get_friend_list": { implementation, _ in await implementation.friendList() },

            // Groups
            "get_group_info": { try await $0.groupInfo($1) },
            "get_group_list": { implementation, _ in await implementation.groupList() },
            "get_group_member_info": { try await $0.memberInfo($1) },
            "get_group_member_list": { try await $0.memberList($1) },
            "set_group_name": { try await $0.setGroupName($1) },
            "set_group_card": { try await $0.setGroupCard($1) },
            "set_group_special_title": { try await $0.setGroupTitle($1) },
            "set_group_admin": { try await $0.setGroupAdmin($1) },
            "set_group_ban": { try await $0.setGroupBan($1) },
            "set_group_whole_ban": { try await $0.setGroupWholeBan($1) },
            "set_group_kick": { try await $0.kickMember($1) },
            "set_group_leave": { try await $0.leaveGroup($1) },
            "leave_group": { try await $0.leaveGroup($1) },

            // Requests
            "set_friend_add_request": { try await $0.resolveRequest($1) },
            "set_group_add_request": { try await $0.resolveRequest($1) },

            // Capability and status
            "get_status": { implementation, _ in implementation.status() },
            "get_version_info": { implementation, _ in implementation.versionInfo() },
            "get_version": { implementation, _ in implementation.versionInfo() },
            "get_supported_actions": { implementation, _ in implementation.supportedActions() },
            "can_send_image": { _, _ in .success(["yes": true]) },
            "can_send_record": { _, _ in .success(["yes": true]) },
        ]

    // MARK: - Outbound events

    public func encode(event: DomainEvent) async -> [OutboundFrame] {
        // Only forward what is addressed to the persona this implementation represents.
        guard event.selfID == selfID else { return [] }
        // An empty result means this version has no representation for the event.
        return await eventEncoder.encode(event).map { OutboundFrame(payload: $0) }
    }

    public func handshakeFrames() async -> [OutboundFrame] {
        let time = Double(Int64(Date().timeIntervalSince1970))
        switch version {
        case .v11:
            return [
                OutboundFrame(payload: [
                    "time": .number(time),
                    "self_id": numericID(selfID),
                    "post_type": "meta_event",
                    "meta_event_type": "lifecycle",
                    "sub_type": "connect",
                ])
            ]
        case .v12:
            // v12 pairs the connect meta-event with an initial status snapshot.
            return [
                OutboundFrame(payload: [
                    "id": .string(IDGenerator.requestID()),
                    "time": .number(time),
                    "type": "meta",
                    "detail_type": "connect",
                    "sub_type": "",
                    "version": versionPayload(),
                ]),
                OutboundFrame(payload: [
                    "id": .string(IDGenerator.requestID()),
                    "time": .number(time),
                    "type": "meta",
                    "detail_type": "status_update",
                    "sub_type": "",
                    "status": statusPayload(),
                ]),
            ]
        }
    }

    public var heartbeatInterval: TimeInterval? { 15 }

    public func heartbeatFrame() async -> OutboundFrame? {
        let time = Double(Int64(Date().timeIntervalSince1970))
        switch version {
        case .v11:
            return OutboundFrame(payload: [
                "time": .number(time),
                "self_id": numericID(selfID),
                "post_type": "meta_event",
                "meta_event_type": "heartbeat",
                "status": statusPayload(),
                "interval": 15000,
            ])
        case .v12:
            return OutboundFrame(payload: [
                "id": .string(IDGenerator.requestID()),
                "time": .number(time),
                "type": "meta",
                "detail_type": "heartbeat",
                "sub_type": "",
                "interval": 15000,
                "status": statusPayload(),
            ])
        }
    }

    // MARK: - Envelope

    /// Wraps a reply in this version's response envelope.
    ///
    /// `status` is always derived from `retcode` rather than set independently, so the
    /// two cannot disagree.
    public func envelope(for reply: ProtocolReply, echo: JSONValue?) -> JSONValue {
        var payload: [String: JSONValue] = [
            "status": .string(reply.isSuccess ? "ok" : "failed"),
            "retcode": .number(Double(reply.retcode)),
            "data": reply.isSuccess ? reply.data : .null,
        ]
        switch version {
        case .v11:
            // v11 has no top-level message field, so failure text rides in `data`.
            if !reply.isSuccess, !reply.message.isEmpty {
                payload["data"] = ["message": .string(reply.message)]
            }
        case .v12:
            payload["message"] = .string(reply.message)
        }
        if let echo {
            payload["echo"] = echo
        }
        return .object(payload)
    }

    private func numericID(_ value: String) -> JSONValue {
        guard version.usesNumericIDs, let number = Int64(value) else { return .string(value) }
        return .number(Double(number))
    }

    private func versionPayload() -> JSONValue {
        switch version {
        case .v11:
            return [
                "app_name": "rei",
                "app_version": .string(ReiVersion.current),
                "protocol_version": "v11",
            ]
        case .v12:
            return [
                "impl": .string(Self.implementationName),
                "version": .string(ReiVersion.current),
                "onebot_version": "12",
            ]
        }
    }

    private func statusPayload() -> JSONValue {
        switch version {
        case .v11:
            return ["online": true, "good": true]
        case .v12:
            return [
                "good": true,
                "bots": [
                    [
                        "self": ["platform": "rei", "user_id": .string(selfID)],
                        "online": true,
                    ]
                ],
            ]
        }
    }
}

@available(*, deprecated, renamed: "OneBotProtocolImplementation")
public typealias OneBotAdapter = OneBotProtocolImplementation

/// The app version reported to peers.
public enum ReiVersion {
    public static let current = "0.1.0"
}
