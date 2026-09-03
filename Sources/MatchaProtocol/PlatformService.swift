import Foundation
import MatchaCore

/// The simulated platform's behaviour.
///
/// Every state change goes through here, whether a person clicked Send in the
/// window or a bot framework called `send_group_message`. That is the load-bearing
/// property of the design: because both paths converge, a connected framework
/// cannot distinguish activity it caused from activity the operator caused, which
/// is exactly what makes the simulation faithful.
///
/// Each method mutates the store and then publishes a `DomainEvent`. Adapters
/// subscribe to that stream; they never write state themselves.
public actor PlatformService {
    /// The store is itself `Sendable` and internally serialized, so reads need not
    /// hop through this actor — only mutation and event publication do.
    public nonisolated let store: MatchaStore
    private var subscribers: [String: AsyncStream<DomainEvent>.Continuation] = [:]
    /// Personas the operator has marked as bots, keyed by ID. Events are addressed
    /// to these.
    private var registeredBots: Set<String> = []
    /// When false, activity a bot itself initiated is not echoed back to it.
    public private(set) var echoesSelfEvents = false

    public init(store: MatchaStore) {
        self.store = store
    }

    // MARK: - Event distribution

    /// Subscribes to domain events. The returned stream ends when `cancel` runs.
    public func events() -> AsyncStream<DomainEvent> {
        let token = IDGenerator.requestID()
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            subscribers[token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(token) }
            }
        }
    }

    private func removeSubscriber(_ token: String) {
        subscribers[token] = nil
    }

    public func setEchoesSelfEvents(_ enabled: Bool) {
        echoesSelfEvents = enabled
    }

    public func registerBot(id: String) {
        registeredBots.insert(id)
    }

    public func unregisterBot(id: String) {
        registeredBots.remove(id)
    }

    /// Replaces the desktop app's single configured bot registration atomically.
    ///
    /// Tests and embedders may still use `registerBot` for multi-bot simulations;
    /// the app must not accumulate stale registrations when its login changes.
    public func setRegisteredBot(id: String?) {
        registeredBots = id.map { [$0] } ?? []
    }

    /// Publishes an event to every subscriber.
    ///
    /// `origin` is who caused it. When that is the bot itself and self-echo is off,
    /// the event is suppressed so a framework does not receive its own send back as
    /// an incoming message.
    func publish(_ event: DomainEvent, origin: String? = nil) {
        if let origin, origin == event.selfID, !echoesSelfEvents {
            return
        }
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    /// Publishes a group event once per bot in that group.
    ///
    /// Group notices are addressed to a specific `selfID`, so a group containing
    /// several registered bots produces one event each — matching what those bots
    /// would independently observe on the real platform.
    func publishToGroupBots(
        groupID: String,
        payload: DomainEvent.Payload,
        origin: String?
    ) async throws {
        let members = try await store.members(groupID: groupID)
        let botsInGroup = members.map(\.userID).filter { registeredBots.contains($0) }

        // With no bot in the group, still emit for any registered bot so a
        // framework watching a group it has not "joined" is not silently ignored.
        let recipients = botsInGroup.isEmpty ? Array(registeredBots) : botsInGroup
        for selfID in recipients {
            publish(DomainEvent(selfID: selfID, payload: payload), origin: origin)
        }
    }

    /// The personas currently marked as bots.
    public var bots: Set<String> { registeredBots }

    // MARK: - Messaging

    /// Sends a message and announces it.
    ///
    /// `senderID` is who is speaking and `selfID` whose session it belongs to; for a
    /// message the operator types those differ, and for one a bot sends they match.
    @discardableResult
    public func sendMessage(
        scene: ChatScene,
        peerID: String,
        senderID: String,
        selfID: String,
        content: [MessageSegment]
    ) async throws -> Message {
        try await validateCanSend(
            scene: scene,
            peerID: peerID,
            senderID: senderID,
            selfID: selfID
        )

        let message = Message(
            scene: scene,
            peerID: peerID,
            senderID: senderID,
            selfID: selfID,
            content: content,
            direction: senderID == selfID ? .incoming : .outgoing
        )
        let stored = try await store.append(message)

        // Group activity updates the member's last-spoken time.
        if scene == .group, var member = try await store.member(groupID: peerID, userID: senderID) {
            member.lastSentAt = stored.time
            try await store.save(member)
        }

        publish(DomainEvent(time: stored.time, selfID: selfID, payload: .message(stored)), origin: senderID)
        return stored
    }

    /// Rejects a send that the simulated platform would not allow.
    ///
    /// Enforcing mutes and membership is the point of a mock platform: a framework
    /// should be able to discover that it is muted the same way it would in
    /// production.
    private func validateCanSend(
        scene: ChatScene,
        peerID: String,
        senderID: String,
        selfID: String
    ) async throws {
        switch scene {
        case .group:
            guard let group = try await store.group(id: peerID) else {
                throw PlatformError.groupNotFound(peerID)
            }
            guard let member = try await store.member(groupID: peerID, userID: senderID) else {
                throw PlatformError.notAMember(groupID: peerID, userID: senderID)
            }
            if member.isMuted {
                throw PlatformError.muted(until: member.mutedUntil ?? .now)
            }
            // Whole-group mutes do not apply to those who can lift them.
            if group.wholeMuted, member.role == .member {
                throw PlatformError.wholeGroupMuted(groupID: peerID)
            }
        case .friend, .temp:
            guard try await store.user(id: peerID) != nil else {
                throw PlatformError.userNotFound(peerID)
            }
            guard selfID != peerID else {
                throw PlatformError.notPermitted(
                    "A private conversation must have two distinct participants"
                )
            }
            guard senderID == selfID || senderID == peerID else {
                throw PlatformError.notPermitted(
                    "A private message sender must be one of the conversation participants"
                )
            }
        }
    }

    /// Recalls a message, if the operator is allowed to.
    @discardableResult
    public func recallMessage(id: String, operatorID: String) async throws -> Message {
        guard let existing = try await store.message(id: id) else {
            throw PlatformError.messageNotFound(id)
        }
        try await validateCanRecall(existing, operatorID: operatorID)

        guard let recalled = try await store.recallMessage(id: id, by: operatorID) else {
            throw PlatformError.messageNotFound(id)
        }

        publish(
            DomainEvent(
                selfID: recalled.selfID,
                payload: .messageRecalled(
                    .init(
                        messageID: recalled.id,
                        scene: recalled.scene,
                        peerID: recalled.peerID,
                        senderID: recalled.senderID,
                        operatorID: operatorID
                    )
                )
            ),
            origin: operatorID
        )
        return recalled
    }

    private func validateCanRecall(_ message: Message, operatorID: String) async throws {
        if message.senderID == operatorID { return }
        guard message.scene == .group else {
            throw PlatformError.notPermitted("You can only recall private messages that you sent")
        }
        // In a group, admins may recall others' messages, but not an owner's or a
        // peer admin's.
        guard let actor = try await store.member(groupID: message.peerID, userID: operatorID),
            actor.role > .member
        else {
            throw PlatformError.notPermitted("Administrator privileges are required to recall another user's message")
        }
        if let sender = try await store.member(groupID: message.peerID, userID: message.senderID),
            sender.role >= actor.role
        {
            throw PlatformError.notPermitted("Cannot recall a message from a member with an equal or higher role")
        }
    }
}

/// Why the simulated platform refused an operation.
///
/// Each protocol implementation maps these to its own return codes; the reasons themselves are
/// protocol-neutral.
public enum PlatformError: Error, LocalizedError, Sendable {
    case userNotFound(String)
    case groupNotFound(String)
    case messageNotFound(String)
    case requestNotFound(String)
    case notAMember(groupID: String, userID: String)
    case muted(until: Date)
    case wholeGroupMuted(groupID: String)
    case notPermitted(String)
    case invalidParameter(String)
    case alreadyExists(String)

    public var errorDescription: String? {
        switch self {
        case .userNotFound(let id):
            return "User not found: \(id)"
        case .groupNotFound(let id):
            return "Group not found: \(id)"
        case .messageNotFound(let id):
            return "Message not found: \(id)"
        case .requestNotFound(let id):
            return "Request not found: \(id)"
        case .notAMember(let groupID, let userID):
            return "User \(userID) is not a member of group \(groupID)"
        case .muted(let until):
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            return "Muted until \(formatter.string(from: until))"
        case .wholeGroupMuted(let groupID):
            return "Group \(groupID) has group-wide mute enabled"
        case .notPermitted(let reason):
            return reason
        case .invalidParameter(let detail):
            return "Invalid parameter: \(detail)"
        case .alreadyExists(let detail):
            return "Already exists: \(detail)"
        }
    }
}
