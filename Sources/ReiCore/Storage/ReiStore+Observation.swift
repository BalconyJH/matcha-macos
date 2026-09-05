import Foundation

/// A live store query that emits its initial value and then refreshes after relevant
/// committed writes. The concrete persistence engine stays out of the public API.
public typealias StoreObservation<Value: Sendable> = AsyncThrowingStream<Value, any Error>

extension ReiStore {
    public func observeUsers() -> StoreObservation<[User]> {
        observation(for: .users) { [self] in try await allUsers() }
    }

    public func observeGroups() -> StoreObservation<[Group]> {
        observation(for: .groups) { [self] in try await allGroups() }
    }

    public func observeMessages(in chat: Chat, limit: Int = 200) -> StoreObservation<[Message]> {
        observation(for: .messages) { [self] in try await messages(in: chat, limit: limit) }
    }

    public func observeMembers(groupID: String) -> StoreObservation<[(member: GroupMember, user: User)]> {
        observation(for: .members) { [executor] in
            try await executor.memberRoster(groupID: groupID)
        }
    }

    public func observeFriendships(userID: String) -> StoreObservation<[Friendship]> {
        observation(for: .friendships) { [self] in
            try await friendships(userID: userID)
        }
    }

    public func observePendingRequests(selfID: String) -> StoreObservation<[PendingRequest]> {
        observation(for: .requests) { [self] in try await pendingRequests(selfID: selfID) }
    }

    public func observeConversations(selfID: String) -> StoreObservation<[ConversationSummary]> {
        observation(for: .conversations) { [executor] in
            try await executor.conversationSummaries(selfID: selfID)
        }
    }

    private func observation<Value: Sendable>(
        for interests: StoreChange,
        fetch: @escaping @Sendable () async throws -> Value
    ) -> StoreObservation<Value> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { [executor] continuation in
            let task = Task {
                do {
                    let changes = await executor.changes(matching: interests)
                    for await _ in changes {
                        try Task.checkCancellation()
                        continuation.yield(try await fetch())
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension StoreExecutor {
    func memberRoster(groupID: String) throws -> [(member: GroupMember, user: User)] {
        let records = try members(groupID: groupID)
        return try records.compactMap { member in
            guard let user = try userRecord(id: member.userID)?.domainValue() else { return nil }
            return (member, user)
        }
    }

    func conversationSummaries(selfID: String) throws -> [ConversationSummary] {
        try activeChats(selfID: selfID).map { chat, lastMessage in
            let title: String
            let avatar: String?
            switch chat.scene {
            case .group:
                let group = try groupRecord(id: chat.peerID)?.domainValue()
                title = group?.name ?? chat.peerID
                avatar = group?.avatar
            case .friend, .temp:
                let user = try userRecord(id: chat.peerID)?.domainValue()
                title = user?.displayName ?? chat.peerID
                avatar = user?.avatar
            }
            return ConversationSummary(
                chat: chat,
                title: title,
                avatar: avatar,
                lastMessage: lastMessage
            )
        }
    }
}

/// A row in the conversation sidebar.
public struct ConversationSummary: Identifiable, Hashable, Sendable {
    public var chat: Chat
    public var title: String
    public var avatar: String?
    public var lastMessage: Message

    public var id: String { chat.id }

    public var preview: String {
        lastMessage.isRecalled ? "[Recalled]" : lastMessage.content.textPreview
    }

    public init(chat: Chat, title: String, avatar: String?, lastMessage: Message) {
        self.chat = chat
        self.title = title
        self.avatar = avatar
        self.lastMessage = lastMessage
    }
}
