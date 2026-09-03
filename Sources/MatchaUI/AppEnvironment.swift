import Foundation
import MatchaCore
import MatchaLogging
import MatchaMilky
import MatchaOneBot
import MatchaProtocol
import Observation

/// The app's live state.
///
/// One `@Observable` object the whole window reads from. It owns the store, the
/// platform service, and whichever protocol session is currently running, and it
/// bridges the async streams those publish into properties SwiftUI can observe.
@Observable
@MainActor
public final class AppEnvironment {
    public let store: MatchaStore
    public let platform: PlatformService
    public let appLog: AppLog

    /// Personas the operator has created.
    public var users: [User] = []
    public var groups: [Group] = []
    /// Conversations with traffic, most recent first.
    public var conversations: [ConversationSummary] = []
    /// Messages in the selected conversation, oldest first.
    public var messages: [Message] = []
    public var pendingRequests: [PendingRequest] = []
    /// Friend relationships owned by the current bot account.
    public var friendships: [Friendship] = []
    var friendshipsAreLoaded = false

    /// Which persona the operator is speaking as.
    public internal(set) var activeUserID: String?
    /// Which persona the bot framework logs in as.
    public internal(set) var botUserID: String?
    public var selectedChat: Chat?

    /// Connection configuration, persisted between launches.
    public var settings = ConnectionSettings()
    public var selectedProtocol: ProtocolChoice = .oneBotV11

    public var sessionState: SessionState = .idle
    public var roundTripTimeState: RoundTripTimeState = .unavailable
    /// The configuration captured by the current session. Settings can be edited
    /// while a connection is live, so status UI must not describe the old session
    /// using newly selected values.
    public private(set) var activeProtocolChoice: ProtocolChoice?
    public private(set) var activeTransportMode: TransportMode?
    /// Bot identity captured by the live protocol implementation and its handshake.
    public private(set) var activeBotUserID: User.ID?
    /// Rolling record of what crossed the wire, newest first, for the inspector.
    public var traffic: [TrafficEntry] = []
    public var lastError: String?

    private var session: ProtocolSession?
    private var observationTasks: [Task<Void, Never>] = []
    private var conversationObservation: Task<Void, Never>?
    private var requestObservation: Task<Void, Never>?
    private var friendshipObservation: Task<Void, Never>?
    private var chatObservation: Task<Void, Never>?
    private var memberObservation: Task<Void, Never>?
    private var sessionObservationTasks: [Task<Void, Never>] = []
    private let mediaService: MediaService
    private let defaults: UserDefaults
    private var connectionGeneration: UInt64 = 0
    private var connectionRequested = false
    private var botIdentityGeneration: UInt64 = 0
    private var botIdentityTransitionCount = 0

    private var isChangingBotIdentity: Bool { botIdentityTransitionCount > 0 }

    public init(
        store: MatchaStore,
        assetStore: AssetStore,
        appLog: AppLog,
        defaults: UserDefaults = .standard
    ) {
        self.store = store
        self.appLog = appLog
        self.defaults = defaults
        platform = PlatformService(store: store)
        mediaService = MediaService(assetStore: assetStore, store: store)
        let protocolChoice = SettingsStorage.loadProtocol(defaults: defaults)
        var connectionSettings = SettingsStorage.load(defaults: defaults)
        let needsMigration = SettingsStorage.needsConnectionSettingsMigration(defaults: defaults)
        // Version 0 used `/` as the implicit path regardless of transport. Migrate it
        // once to the version-1 empty sentinel; after this, `/` is always an explicit
        // operator choice and is never rewritten.
        if needsMigration,
            connectionSettings.path.trimmingCharacters(in: .whitespacesAndNewlines) == "/"
        {
            connectionSettings.path = ""
        }
        if connectionSettings.transport == .webSocketClient {
            connectionSettings.path = protocolChoice.resolvingWebSocketClientPath(
                connectionSettings.path
            )
        }
        if needsMigration {
            do {
                try SettingsStorage.save(connectionSettings, defaults: defaults)
                appLog.record(.operationCompleted(.migrateSettings))
            } catch {
                appLog.record(
                    .operationReturnedError(
                        operation: .migrateSettings,
                        failure: AppLogFailure(error)
                    )
                )
            }
        }
        settings = connectionSettings
        selectedProtocol = protocolChoice
        activeUserID = SettingsStorage.loadActiveUserID(defaults: defaults)
        botUserID = SettingsStorage.loadBotUserID(defaults: defaults)
        appLog.record(.operationCompleted(.loadSettings))
        startObserving()
    }

    /// Convenience initializer using the standard on-disk locations.
    public static func standard(appLog: AppLog) throws -> AppEnvironment {
        AppEnvironment(
            store: try MatchaStore.defaultLocation(),
            assetStore: try AssetStore.defaultLocation(),
            appLog: appLog
        )
    }

    // MARK: - Observation

    /// Mirrors the store's live queries into observable properties.
    private func startObserving() {
        observationTasks.append(
            observe(store.observeUsers()) { [weak self] value in
                guard let self else { return }
                users = value
                // Adopt sensible defaults the first time personas appear, so a new
                // install is usable without visiting settings.
                let userIDs = Set(value.map(\.id))
                if activeUserID.map({ userIDs.contains($0) }) != true {
                    updateActiveUser(value.first?.id, recordSelection: false)
                }

                if botUserID.map({ userIDs.contains($0) }) != true {
                    _ = await transitionBotUser(
                        to: value.count > 1 ? value.last?.id : nil,
                        recordSelection: false
                    )
                } else {
                    await syncBotRegistration()
                }
            })
        observationTasks.append(
            observe(store.observeGroups()) { [weak self] value in
                self?.groups = value
            })
        refreshConversations()
    }

    /// Restarts the conversation and request queries against the current bot.
    private func refreshConversations() {
        conversationObservation?.cancel()
        requestObservation?.cancel()
        friendshipObservation?.cancel()
        conversations = []
        pendingRequests = []
        friendships = []
        friendshipsAreLoaded = false

        guard let botUserID else {
            conversationObservation = nil
            requestObservation = nil
            friendshipObservation = nil
            return
        }
        conversationObservation = observe(store.observeConversations(selfID: botUserID)) { [weak self] value in
            self?.conversations = value
        }
        requestObservation = observe(store.observePendingRequests(selfID: botUserID)) { [weak self] value in
            self?.pendingRequests = value
        }
        friendshipObservation = observe(store.observeFriendships(userID: botUserID)) { [weak self] value in
            guard let self else { return }
            friendships = value
            friendshipsAreLoaded = true
        }
    }

    /// Watches the selected conversation. Replaces any previous watch, since only
    /// one chat is visible at a time.
    public func selectChat(_ chat: Chat?) {
        let selectionChanged = selectedChat != chat
        selectedChat = chat
        chatObservation?.cancel()
        memberObservation?.cancel()
        messages = []
        guard let chat else {
            if selectionChanged {
                appLog.record(.operationCompleted(.closeChat))
            }
            return
        }
        if selectionChanged {
            appLog.record(.operationCompleted(.selectChat))
        }
        chatObservation = observe(store.observeMessages(in: chat)) { [weak self] value in
            self?.messages = value
        }
        if chat.scene == .group {
            memberObservation = observe(store.observeMembers(groupID: chat.peerID)) { [weak self] value in
                self?.replaceMembers(value.map(\.member), in: chat.peerID)
            }
        }
    }

    /// Drives one live query, applying each new value on the main actor.
    ///
    /// The observation sequences throw, and a failure means the query itself is dead
    /// rather than that one value was missed, so the error is surfaced and the loop
    /// ends instead of retrying.
    ///
    /// Typed to the store's concrete observation stream rather than any
    /// `AsyncSequence`, because a generic iterator may carry its own actor isolation
    /// and the compiler then cannot prove the loop is safe to run here.
    private func observe<Value: Sendable>(
        _ sequence: StoreObservation<Value>,
        apply: @escaping @MainActor (Value) async -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            do {
                for try await value in sequence {
                    await apply(value)
                }
            } catch is CancellationError {
                // Expected when a chat is deselected or the app shuts down.
            } catch {
                guard let self else { return }
                recordStoreObservationFailure(error)
                lastError = error.localizedDescription
            }
        }
    }

    private func syncBotRegistration() async {
        await platform.setRegisteredBot(id: botUserID)
        await platform.setEchoesSelfEvents(settings.postSelfEvents)
    }

    // MARK: - Personas

    public func createUser(name: String, nickname: String = "", sex: User.Sex = .unknown) async {
        await performReportingFailure(.createPersona) {
            try await self.store.save(User(name: name, nickname: nickname, sex: sex))
        }
    }

    public func createGroup(name: String, ownerID: String) async {
        await performReportingFailure(.createGroup) {
            let group = Group(name: name)
            try await self.store.save(group)
            try await self.store.save(GroupMember(groupID: group.id, userID: ownerID, role: .owner))
            // A group with only an owner cannot receive bot traffic, so the bot joins
            // too. That matches how the tool is actually used.
            if let botUserID = self.botUserID, botUserID != ownerID {
                try await self.store.save(GroupMember(groupID: group.id, userID: botUserID))
            }
        }
    }

    /// Removes a simulated group and every record owned by it.
    public func deleteGroup(_ groupID: Group.ID) async throws {
        try await performThrowing(.deleteGroup) {
            guard try await self.store.group(id: groupID) != nil else {
                throw PlatformError.groupNotFound(groupID)
            }
            try await self.store.deleteGroup(id: groupID)
            self.replaceMembers([], in: groupID)
            if self.selectedChat?.scene == .group, self.selectedChat?.peerID == groupID {
                self.selectChat(nil)
            }
        }
    }

    /// Removes the friendship belonging to the current bot without deleting history.
    public func removeFriend(_ friendID: User.ID) async throws {
        try await performThrowing(.removeFriend) {
            guard let botUserID = self.botUserID else {
                throw PlatformError.notPermitted("Select a bot account first")
            }
            try await self.platform.removeFriend(userID: botUserID, friendID: friendID)
        }
    }

    /// Deletes only the locally stored transcript for one bot-scoped conversation.
    public func clearMessageHistory(in chat: Chat) async throws {
        try await performThrowing(.clearMessageHistory) {
            try await self.store.deleteMessages(in: chat)
        }
    }

    public func setActiveUser(_ id: String) {
        updateActiveUser(id, recordSelection: true)
    }

    private func updateActiveUser(_ id: String?, recordSelection: Bool) {
        guard activeUserID != id else { return }
        activeUserID = id
        if let selectedChat, selectedChat.scene.isPrivate,
            id.flatMap({ selectedChat.counterpartID(for: $0) }) == nil
        {
            selectChat(nil)
        }
        if recordSelection {
            appLog.record(.operationCompleted(.selectActivePersona))
        }
    }

    @discardableResult
    public func setBotUser(_ id: String) async -> Bool {
        await transitionBotUser(to: id, recordSelection: true)
    }

    private func transitionBotUser(
        to id: String?,
        recordSelection: Bool
    ) async -> Bool {
        guard botUserID != id else {
            await syncBotRegistration()
            return true
        }

        botIdentityGeneration &+= 1
        let generation = botIdentityGeneration
        botIdentityTransitionCount += 1
        let shouldRestartSession = connectionRequested
        defer { botIdentityTransitionCount -= 1 }

        if session != nil {
            await suspendCurrentSession()
        }
        guard generation == botIdentityGeneration else { return false }

        botUserID = id
        selectChat(nil)
        refreshConversations()
        if recordSelection {
            appLog.record(.operationCompleted(.selectBotPersona))
        }
        await syncBotRegistration()
        guard generation == botIdentityGeneration else { return false }

        if shouldRestartSession, connectionRequested, id != nil {
            return await startConnection()
        }
        return true
    }

    /// IDs of users related to the current bot account as friends.
    public var friendUserIDs: Set<User.ID> {
        Set(friendships.map(\.friendID))
    }

    public var addableFriendUsers: [User] {
        guard friendshipsAreLoaded else { return [] }
        return users.filter { user in
            guard let chat = privateChat(with: user.id) else { return false }
            return !isFriend(chat.peerID)
        }
    }

    public func isFriend(_ userID: User.ID) -> Bool {
        friendUserIDs.contains(userID)
    }

    /// Directly wires an existing simulated user to the bot account as a friend.
    public func addFriend(_ userID: User.ID) async throws {
        try await performThrowing(.addFriend) {
            guard let botUserID = self.botUserID else {
                throw PlatformError.notPermitted("Select a bot account first")
            }
            guard userID != botUserID else {
                throw PlatformError.notPermitted("The bot account cannot add itself as a friend")
            }
            try await self.platform.addFriendship(userID: botUserID, friendID: userID)
        }
    }

    @discardableResult
    public func addFriend(with targetID: User.ID) async throws -> Chat {
        guard let chat = privateChat(with: targetID) else {
            throw PlatformError.notPermitted(
                "A friendship can only be created between the current identity and the bot"
            )
        }
        try await addFriend(chat.peerID)
        return Chat(scene: .friend, peerID: chat.peerID, selfID: chat.selfID)
    }

    /// Invites an existing simulated user into a group as the active persona.
    public func addGroupMember(_ userID: User.ID, to groupID: Group.ID) async throws {
        try await performThrowing(.addGroupMember) {
            guard let activeUserID = self.activeUserID else {
                throw PlatformError.notPermitted("Select a sending identity first")
            }
            try await self.platform.addMember(
                groupID: groupID,
                userID: userID,
                operatorID: activeUserID,
                reason: .invited
            )
        }
        _ = try await groupMembers(in: groupID)
    }

    /// Removes a member from a group as the active persona.
    public func removeGroupMember(_ userID: User.ID, from groupID: Group.ID) async throws {
        try await performThrowing(.removeGroupMember) {
            guard let activeUserID = self.activeUserID else {
                throw PlatformError.notPermitted("Select a sending identity first")
            }
            try await self.platform.removeMember(
                groupID: groupID,
                userID: userID,
                operatorID: activeUserID,
                reason: .administrative
            )
        }
        _ = try await groupMembers(in: groupID)
    }

    // MARK: - Sending

    /// Sends what the operator typed into the selected conversation.
    public func sendText(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = await send(content: [.text(trimmed)])
    }

    @discardableResult
    public func send(content: [MessageSegment]) async -> Bool {
        guard let chat = selectedChat, let activeUserID, let botUserID else { return false }
        guard chat.selfID == botUserID else {
            lastError = "The selected conversation belongs to a different bot account"
            return false
        }
        return await send(content: content, in: chat, as: activeUserID)
    }

    @discardableResult
    public func send(
        content: [MessageSegment],
        in chat: Chat,
        as senderID: User.ID
    ) async -> Bool {
        do {
            try await performThrowing(.sendMessage) {
                guard !self.isChangingBotIdentity else {
                    throw PlatformError.notPermitted(
                        "Wait for the bot account change to finish reconnecting"
                    )
                }
                guard chat.selfID == self.botUserID else {
                    throw PlatformError.notPermitted(
                        "The selected conversation belongs to a different bot account"
                    )
                }
                if self.session != nil {
                    guard self.sessionState.acceptsOperatorEvents else {
                        throw PlatformError.notPermitted(
                            "Wait for the protocol service or bot framework connection before sending"
                        )
                    }
                } else if case .failed = self.sessionState {
                    throw PlatformError.notPermitted(
                        "Reconnect the bot framework before sending"
                    )
                }
                if let activeBotUserID = self.activeBotUserID,
                    activeBotUserID != chat.selfID
                {
                    throw PlatformError.notPermitted(
                        "The live connection belongs to a different bot account; reconnect first"
                    )
                }
                try await self.platform.sendMessage(
                    scene: chat.scene,
                    peerID: chat.peerID,
                    senderID: senderID,
                    selfID: chat.selfID,
                    content: content
                )
            }
            lastError = nil
            return true
        } catch is CancellationError {
            return false
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    var canSubmitMessages: Bool {
        guard !isChangingBotIdentity else { return false }
        if session != nil {
            return sessionState.acceptsOperatorEvents
        }
        if case .failed = sessionState { return false }
        return true
    }

    public func recall(_ message: Message) async {
        guard let activeUserID else { return }
        await performReportingFailure(.recallMessage) {
            try await self.platform.recallMessage(id: message.id, operatorID: activeUserID)
        }
    }

    public func resolveRequest(_ request: PendingRequest, approve: Bool) async {
        await performReportingFailure(approve ? .approveRequest : .rejectRequest) {
            try await self.platform.resolveRequest(flag: request.flag, approve: approve)
        }
    }

    /// Resolves a user-facing private-chat target to the bot-scoped storage key.
    ///
    /// The current identity and target must be the two endpoints, and one endpoint
    /// must be the configured bot. Conversations between two non-bot personas are
    /// not representable by the protocol session and are deliberately rejected.
    func privateChat(with targetID: User.ID) -> Chat? {
        guard friendshipsAreLoaded,
            let activeUserID, let botUserID,
            targetID != activeUserID,
            users.contains(where: { $0.id == activeUserID }),
            users.contains(where: { $0.id == targetID })
        else {
            return nil
        }

        let peerID: User.ID
        if activeUserID == botUserID {
            peerID = targetID
        } else if targetID == botUserID {
            peerID = activeUserID
        } else {
            return nil
        }

        let scene: ChatScene = isFriend(peerID) ? .friend : .temp
        return Chat(scene: scene, peerID: peerID, selfID: botUserID)
    }

    func openPrivateChat(with targetID: User.ID) {
        guard let chat = privateChat(with: targetID) else { return }
        selectChat(chat)
    }

    /// The peer presented to the active identity rather than the bot-scoped peer
    /// used by persistence and protocol adapters.
    func displayedPeerID(for chat: Chat) -> User.ID? {
        guard chat.scene.isPrivate, let activeUserID else { return nil }
        return chat.counterpartID(for: activeUserID)
    }

    func conversationTitle(for chat: Chat) -> String {
        if chat.scene == .group {
            return groups.first { $0.id == chat.peerID }?.name ?? chat.peerID
        }
        guard let peerID = displayedPeerID(for: chat) else { return chat.peerID }
        return displayName(for: peerID, in: nil)
    }

    func conversationAvatar(for chat: Chat) -> String? {
        if chat.scene == .group {
            return groups.first { $0.id == chat.peerID }?.avatar
        }
        guard let peerID = displayedPeerID(for: chat) else { return nil }
        return users.first { $0.id == peerID }?.avatar
    }

    func conversationPreview(for summary: ConversationSummary) -> String {
        guard !summary.lastMessage.isRecalled else { return "[Recalled]" }
        return summary.lastMessage.content
            .map { segment -> String in
                if case .mention(let userID) = segment {
                    guard let userID else { return "@everyone" }
                    return "@\(displayName(for: userID, in: summary.chat))"
                }
                return segment.textPreview
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    func mentionableUsers(in chat: Chat) -> [User] {
        guard chat.scene == .group else { return [] }
        let memberIDs = Set(
            members.keys
                .filter { $0.groupID == chat.peerID }
                .map(\.userID)
        )
        return
            users
            .filter { memberIDs.contains($0.id) && $0.id != activeUserID }
            .sorted {
                let lhs = displayName(for: $0.id, in: chat)
                let rhs = displayName(for: $1.id, in: chat)
                let comparison = lhs.localizedStandardCompare(rhs)
                return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
            }
    }

    // MARK: - Connection

    /// Starts the configured protocol session, replacing any running one.
    @discardableResult
    public func connect() async -> Bool {
        connectionRequested = true
        return await startConnection()
    }

    private func startConnection() async -> Bool {
        connectionGeneration &+= 1
        let generation = connectionGeneration
        await stopCurrentSession()
        guard generation == connectionGeneration, connectionRequested else { return false }

        guard let botUserID else {
            appLog.record(.connectionRejected(.missingBotAccount))
            lastError = "Select a bot account first"
            return false
        }
        await syncBotRegistration()
        guard generation == connectionGeneration,
            connectionRequested,
            self.botUserID == botUserID
        else {
            return false
        }

        let protocolChoice = selectedProtocol
        let connectionSettings = settings
        activeProtocolChoice = protocolChoice
        activeTransportMode = connectionSettings.transport
        activeBotUserID = botUserID

        let implementation: any ProtocolImplementation

        switch protocolChoice {
        case .oneBotV11, .oneBotV12:
            let oneBot = OneBotProtocolImplementation(
                version: protocolChoice == .oneBotV11 ? .v11 : .v12,
                selfID: botUserID,
                platform: platform,
                assetResolver: OneBotAssetResolver(media: mediaService)
            )
            implementation = oneBot
        case .milky:
            let milky = MilkyProtocolImplementation(
                selfID: botUserID,
                platform: platform,
                assetResolver: MilkyAssetResolverImpl(media: mediaService, store: store)
            )
            implementation = milky
        }

        appLog.record(
            .connectionRequested(
                protocolKind: protocolChoice.appLogProtocol,
                transportKind: connectionSettings.transport.appLogTransport,
                port: connectionSettings.port
            )
        )
        let session = ProtocolSession(
            implementation: implementation,
            platform: platform,
            settings: connectionSettings
        )
        self.session = session

        sessionObservationTasks = [
            Task { [weak self] in
                for await state in await session.stateUpdates() {
                    guard let self,
                        isCurrent(session, generation: generation)
                    else { return }
                    sessionState = state
                    recordSessionState(state)
                }
            },
            Task { [weak self] in
                for await value in await session.roundTripTimeUpdates() {
                    guard let self,
                        isCurrent(session, generation: generation)
                    else { return }
                    roundTripTimeState = value
                }
            },
            Task { [weak self] in
                for await entry in await session.trafficLog() {
                    guard let self,
                        isCurrent(session, generation: generation)
                    else { return }
                    traffic.insert(entry, at: 0)
                    // The inspector is a debugging aid, not an archive.
                    if traffic.count > 500 { traffic.removeLast(traffic.count - 500) }
                }
            },
            Task { [weak self] in
                for await diagnostic in await session.diagnostics() {
                    guard let self,
                        isCurrent(session, generation: generation)
                    else { return }
                    switch diagnostic {
                    case .outboundEventDeliveryFailed:
                        appLog.record(.sessionEventDeliveryFailed)
                    }
                }
            },
        ]

        do {
            try await session.start()
            guard isCurrent(session, generation: generation) else {
                await session.stop()
                return false
            }
            await mediaService.setBaseURL(
                host: connectionSettings.host,
                port: connectionSettings.port
            )
            guard isCurrent(session, generation: generation) else {
                await session.stop()
                return false
            }
            lastError = nil
            return true
        } catch {
            guard isCurrent(session, generation: generation) else {
                await session.stop()
                return false
            }
            for task in sessionObservationTasks { task.cancel() }
            sessionObservationTasks.removeAll()
            await session.stop()
            guard isCurrent(session, generation: generation) else { return false }
            self.session = nil
            roundTripTimeState = .unavailable
            activeProtocolChoice = nil
            activeTransportMode = nil
            activeBotUserID = nil
            appLog.record(.sessionStartFailed(AppLogFailure(error)))
            lastError = error.localizedDescription
            sessionState = .failed(error.localizedDescription)
            return false
        }
    }

    public func disconnect() async {
        connectionRequested = false
        await suspendCurrentSession()
    }

    private func suspendCurrentSession() async {
        connectionGeneration &+= 1
        await stopCurrentSession()
    }

    private func stopCurrentSession() async {
        let currentSession = session
        let tasks = sessionObservationTasks
        sessionObservationTasks.removeAll()
        for task in tasks { task.cancel() }

        if let currentSession {
            await currentSession.stop()
            guard session === currentSession else { return }
            appLog.record(.sessionStopped)
        } else if session != nil {
            return
        }

        session = nil
        sessionState = .idle
        roundTripTimeState = .unavailable
        activeProtocolChoice = nil
        activeTransportMode = nil
        activeBotUserID = nil
    }

    private func isCurrent(_ candidate: ProtocolSession, generation: UInt64) -> Bool {
        connectionGeneration == generation && session === candidate
    }

    @discardableResult
    public func saveSettings() -> Bool {
        do {
            try SettingsStorage.save(settings, defaults: defaults)
            SettingsStorage.saveProtocol(selectedProtocol, defaults: defaults)
            SettingsStorage.saveIdentities(
                activeUserID: activeUserID,
                botUserID: botUserID,
                defaults: defaults
            )
            Task { await platform.setEchoesSelfEvents(settings.postSelfEvents) }
            appLog.record(.operationCompleted(.saveSettings))
            return true
        } catch {
            recordOperationFailure(.saveSettings, error)
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: - Helpers

    /// Runs an app operation whose error is presented by the shared app alert.
    private func performReportingFailure(
        _ operation: AppLogOperation,
        _ body: @escaping () async throws -> Void
    ) async {
        do {
            try await body()
            lastError = nil
            appLog.record(.operationCompleted(operation))
        } catch is CancellationError {
            // Cancellation is control flow when a view or observation ends.
        } catch {
            recordOperationFailure(operation, error)
            lastError = error.localizedDescription
        }
    }

    /// Runs an app operation whose caller owns its local error presentation.
    private func performThrowing<Value>(
        _ operation: AppLogOperation,
        _ body: @escaping () async throws -> Value
    ) async throws -> Value {
        do {
            let value = try await body()
            appLog.record(.operationCompleted(operation))
            return value
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            recordOperationFailure(operation, error)
            throw error
        }
    }

    func reportAttachmentSelectionFailure(_ error: any Error) {
        let nsError = error as NSError
        guard
            !(nsError.domain == NSCocoaErrorDomain
                && nsError.code == CocoaError.Code.userCancelled.rawValue)
        else { return }
        recordOperationFailure(.chooseAttachments, error)
        lastError = error.localizedDescription
    }

    func reportAttachmentSelectionCompleted() {
        appLog.record(.operationCompleted(.chooseAttachments))
    }

    private func recordOperationFailure(_ operation: AppLogOperation, _ error: any Error) {
        guard !(error is CancellationError) else { return }
        appLog.record(
            .operationReturnedError(
                operation: operation,
                failure: AppLogFailure(error)
            )
        )
    }

    private func recordStoreObservationFailure(_ error: any Error) {
        guard !(error is CancellationError) else { return }
        appLog.record(.storeObservationFailed(AppLogFailure(error)))
    }

    private func recordSessionState(_ state: SessionState) {
        switch state {
        case .idle:
            break
        case .listening(let port):
            appLog.record(.sessionListening(port: port))
        case .ready(let port):
            appLog.record(.sessionReady(port: port))
        case .connecting:
            appLog.record(.sessionConnecting)
        case .connected:
            appLog.record(.sessionConnected)
        case .failed:
            appLog.record(.sessionFailed)
        }
    }

    /// Display name for a peer, resolving group cards where relevant.
    public func displayName(for userID: String, in chat: Chat?) -> String {
        if let chat, chat.scene == .group {
            // The card is per-group, so it wins over the global nickname.
            if let card = members[MemberKey(groupID: chat.peerID, userID: userID)]?.card, !card.isEmpty {
                return card
            }
        }
        return users.first { $0.id == userID }?.displayName ?? userID
    }

    /// A member's role, for the owner and admin badges.
    public func role(of userID: String, in groupID: String) -> GroupMember.Role? {
        members[MemberKey(groupID: groupID, userID: userID)]?.role
    }

    /// Preflight for the group-management UI; PlatformService remains the final
    /// permission boundary when the operation runs.
    public func canRemoveGroupMember(_ member: GroupMember, from groupID: Group.ID) -> Bool {
        guard let activeUserID, activeUserID != member.userID,
            let actor = members[MemberKey(groupID: groupID, userID: activeUserID)]
        else { return false }
        return actor.role > .member && actor.role > member.role
    }

    /// Roster of the open group, keyed for lookup while rendering the transcript.
    public var members: [MemberKey: GroupMember] = [:]

    public struct MemberKey: Hashable, Sendable {
        public var groupID: String
        public var userID: String

        public init(groupID: String, userID: String) {
            self.groupID = groupID
            self.userID = userID
        }
    }

    /// Copies a file the operator dropped or picked into the asset store.
    ///
    /// Returns the stored asset, whose ID is the hash of its contents, so the same
    /// file attached twice is stored once.
    public func ingestAttachment(at url: URL) async -> Asset? {
        do {
            guard
                let asset = try await mediaService.ingest(
                    reference: url.path,
                    suggestedName: url.lastPathComponent
                )
            else {
                appLog.record(.attachmentImportUnavailable)
                return nil
            }
            appLog.record(.operationCompleted(.importAttachment))
            return asset
        } catch {
            recordOperationFailure(.importAttachment, error)
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Loads one quoted message without leaking its identifier into diagnostics.
    public func quotedMessage(id: Message.ID) async -> Message? {
        do {
            return try await store.message(id: id)
        } catch {
            recordOperationFailure(.loadQuotedMessage, error)
            return nil
        }
    }

    /// Loads the member roster for a group so cards and roles can be shown.
    public func loadMembers(groupID: String) async {
        do {
            _ = try await groupMembers(in: groupID)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Fetches and atomically replaces one group's cached roster.
    @discardableResult
    public func groupMembers(in groupID: Group.ID) async throws -> [GroupMember] {
        try await performThrowing(.loadGroupMembers) {
            try await self.fetchGroupMembers(in: groupID)
        }
    }

    private func fetchGroupMembers(in groupID: Group.ID) async throws -> [GroupMember] {
        let roster = try await store.members(groupID: groupID)
        replaceMembers(roster, in: groupID)
        return roster
    }

    private func replaceMembers(_ roster: [GroupMember], in groupID: Group.ID) {
        members = members.filter { $0.key.groupID != groupID }
        for member in roster {
            members[MemberKey(groupID: groupID, userID: member.userID)] = member
        }
    }
}

extension ProtocolChoice {
    fileprivate var appLogProtocol: AppLogProtocol {
        switch self {
        case .oneBotV11:
            .oneBotV11
        case .oneBotV12:
            .oneBotV12
        case .milky:
            .milky
        }
    }
}

extension TransportMode {
    fileprivate var appLogTransport: AppLogTransport {
        switch self {
        case .webSocketServer:
            .webSocketServer
        case .webSocketClient:
            .webSocketClient
        case .milkyService:
            .milkyService
        }
    }
}

/// Which protocol the operator has selected.
public enum ProtocolChoice: String, Codable, Sendable, CaseIterable, Identifiable {
    case oneBotV11
    case oneBotV12
    case milky

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .oneBotV11: return "OneBot Protocol V11"
        case .oneBotV12: return "OneBot Protocol V12"
        case .milky: return "Milky Protocol V1.3"
        }
    }

    /// Compact label for constrained status surfaces such as the window toolbar.
    public var shortDisplayName: String {
        switch self {
        case .oneBotV11: return "OneBot V11"
        case .oneBotV12: return "OneBot V12"
        case .milky: return "Milky 1.3"
        }
    }

    /// Transports this protocol can actually use.
    public var supportedTransports: [TransportMode] {
        switch self {
        case .oneBotV11, .oneBotV12:
            return [.webSocketServer, .webSocketClient]
        case .milky:
            return [.milkyService]
        }
    }

    /// The canonical NoneBot route used when Matcha initiates a reverse WebSocket.
    public var webSocketClientDefaultPath: String? {
        switch self {
        case .oneBotV11:
            return OneBotVersion.v11.noneBotReverseWebSocketPath
        case .oneBotV12:
            return OneBotVersion.v12.noneBotReverseWebSocketPath
        case .milky:
            return nil
        }
    }

    /// Replaces legacy or other-version NoneBot routes with this protocol's canonical
    /// route while preserving genuinely custom application endpoints.
    func resolvingWebSocketClientPath(_ configuredPath: String) -> String {
        guard let recommendedPath = webSocketClientDefaultPath else { return configuredPath }
        let trimmedPath = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.knownNoneBotWebSocketPaths.contains(trimmedPath)
            ? recommendedPath
            : configuredPath
    }

    private static let knownNoneBotWebSocketPaths: Set<String> = [
        "/onebot/v11",
        "/onebot/v11/",
        "/onebot/v11/ws",
        "/onebot/v11/ws/",
        "/onebot/v12",
        "/onebot/v12/",
        "/onebot/v12/ws",
        "/onebot/v12/ws/",
    ]
}

extension SessionState {
    /// An operator event can be accepted once a connectionless protocol service is
    /// serving or a bidirectional framework socket is connected.
    fileprivate var acceptsOperatorEvents: Bool {
        switch self {
        case .ready, .connected:
            true
        case .idle, .listening, .connecting, .failed:
            false
        }
    }
}

/// Settings persistence.
///
/// `UserDefaults` rather than a file: this is a handful of small values, and the
/// system already handles atomic writes and per-user separation.
enum SettingsStorage {
    private static let settingsKey = "matcha.connection.settings"
    private static let protocolKey = "matcha.connection.protocol"
    private static let activeUserKey = "matcha.persona.active-user"
    private static let botUserKey = "matcha.persona.bot-user"
    private static let settingsSchemaVersionKey = "matcha.connection.settings.schema-version"
    private static let currentSettingsSchemaVersion = 1

    static func needsConnectionSettingsMigration(
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.integer(forKey: settingsSchemaVersionKey) < currentSettingsSchemaVersion
    }

    static func load(defaults: UserDefaults = .standard) -> ConnectionSettings {
        guard let data = defaults.data(forKey: settingsKey),
            let decoded = try? JSONDecoder().decode(ConnectionSettings.self, from: data)
        else { return ConnectionSettings() }
        return decoded
    }

    static func save(
        _ settings: ConnectionSettings,
        defaults: UserDefaults = .standard
    ) throws {
        let data = try JSONEncoder().encode(settings)
        defaults.set(data, forKey: settingsKey)
        defaults.set(currentSettingsSchemaVersion, forKey: settingsSchemaVersionKey)
    }

    static func loadProtocol(defaults: UserDefaults = .standard) -> ProtocolChoice {
        guard let raw = defaults.string(forKey: protocolKey),
            let choice = ProtocolChoice(rawValue: raw)
        else { return .oneBotV11 }
        return choice
    }

    static func saveProtocol(
        _ choice: ProtocolChoice,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(choice.rawValue, forKey: protocolKey)
    }

    static func loadActiveUserID(defaults: UserDefaults = .standard) -> User.ID? {
        defaults.string(forKey: activeUserKey)
    }

    static func loadBotUserID(defaults: UserDefaults = .standard) -> User.ID? {
        defaults.string(forKey: botUserKey)
    }

    static func saveIdentities(
        activeUserID: User.ID?,
        botUserID: User.ID?,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(activeUserID, forKey: activeUserKey)
        defaults.set(botUserID, forKey: botUserKey)
    }
}
