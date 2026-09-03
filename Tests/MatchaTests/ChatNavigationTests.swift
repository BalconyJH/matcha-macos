import Foundation
import Testing

import MatchaCore
@testable import MatchaLogging
@testable import MatchaUI

@Suite("Chat Navigation", .serialized)
@MainActor
struct ChatNavigationTests {
    @Test("A private chat resolves the counterpart relative to either endpoint")
    func privateChatCounterpart() {
        let chat = Chat(scene: .friend, peerID: "user", selfID: "bot")

        #expect(chat.counterpartID(for: "user") == "bot")
        #expect(chat.counterpartID(for: "bot") == "user")
        #expect(chat.counterpartID(for: "third-party") == nil)
        #expect(Chat(scene: .friend, peerID: "bot", selfID: "bot")
            .counterpartID(for: "bot") == nil)
        #expect(Chat(scene: .group, peerID: "group", selfID: "bot")
            .counterpartID(for: "bot") == nil)
        #expect(
            ComposerDraftKey(chat: chat, senderID: "user")
                != ComposerDraftKey(chat: chat, senderID: "bot")
        )
    }

    @Test("Clicking the bot opens its canonical chat but presents the bot as the peer")
    func clickingBotMessageStartsConversationWithBot() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let user = User(id: "user", name: "User")
        let bot = User(id: "bot", name: "TestBot")
        fixture.environment.users = [user, bot]
        fixture.environment.activeUserID = user.id
        fixture.environment.botUserID = bot.id
        fixture.environment.friendshipsAreLoaded = true

        let chat = try #require(fixture.environment.privateChat(with: bot.id))
        #expect(chat == Chat(scene: .temp, peerID: user.id, selfID: bot.id))
        #expect(fixture.environment.displayedPeerID(for: chat) == bot.id)
        #expect(fixture.environment.conversationTitle(for: chat) == bot.displayName)

        fixture.environment.openPrivateChat(with: bot.id)
        #expect(fixture.environment.selectedChat == chat)
    }

    @Test("Private-chat routing rejects self and conversations without the bot")
    func privateChatTargetsMustBeRepresentable() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let user = User(id: "user", name: "User")
        let bot = User(id: "bot", name: "TestBot")
        let other = User(id: "other", name: "Other")
        fixture.environment.users = [user, bot, other]
        fixture.environment.activeUserID = user.id
        fixture.environment.botUserID = bot.id
        fixture.environment.friendshipsAreLoaded = true

        #expect(fixture.environment.privateChat(with: user.id) == nil)
        #expect(fixture.environment.privateChat(with: other.id) == nil)

        fixture.environment.activeUserID = bot.id
        #expect(
            fixture.environment.privateChat(with: other.id)
                == Chat(scene: .temp, peerID: other.id, selfID: bot.id)
        )
    }

    @Test("Changing identity closes a private chat the new identity does not belong to")
    func changingIdentityClosesIncompatiblePrivateChat() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let user = User(id: "user", name: "User")
        let bot = User(id: "bot", name: "TestBot")
        let other = User(id: "other", name: "Other")
        fixture.environment.users = [user, bot, other]
        fixture.environment.activeUserID = user.id
        fixture.environment.botUserID = bot.id
        fixture.environment.friendshipsAreLoaded = true
        fixture.environment.selectChat(
            Chat(scene: .friend, peerID: user.id, selfID: bot.id)
        )

        fixture.environment.setActiveUser(other.id)

        #expect(fixture.environment.selectedChat == nil)
    }

    @Test("Changing the configured bot replaces its platform registration")
    func changingBotReplacesRegistration() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let firstBot = User(
            id: "first-bot",
            name: "First Bot",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let secondBot = User(
            id: "second-bot",
            name: "Second Bot",
            createdAt: Date(timeIntervalSince1970: 2)
        )
        try await fixture.environment.store.save(firstBot)
        try await fixture.environment.store.save(secondBot)

        for _ in 0 ..< 100 where fixture.environment.users.count < 2 {
            await Task.yield()
        }
        #expect(fixture.environment.botUserID == secondBot.id)

        await fixture.environment.setBotUser(firstBot.id)
        #expect(await fixture.environment.platform.bots == [firstBot.id])

        await fixture.environment.setBotUser(secondBot.id)
        #expect(await fixture.environment.platform.bots == [secondBot.id])
    }

    @Test("Persona role assignments persist independently of connection settings")
    func personaAssignmentsPersist() throws {
        let defaultsName = "dev.matcha.tests.persona-settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        SettingsStorage.saveIdentities(
            activeUserID: "user",
            botUserID: "bot",
            defaults: defaults
        )

        #expect(SettingsStorage.loadActiveUserID(defaults: defaults) == "user")
        #expect(SettingsStorage.loadBotUserID(defaults: defaults) == "bot")
    }

    @Test("A submitted message keeps the chat and sender captured at submission")
    func sendUsesCapturedDestination() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let user = User(
            id: "user",
            name: "User",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let other = User(
            id: "other",
            name: "Other",
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let bot = User(
            id: "bot",
            name: "TestBot",
            createdAt: Date(timeIntervalSince1970: 3)
        )
        for participant in [user, other, bot] {
            try await fixture.environment.store.save(participant)
        }
        for _ in 0 ..< 100 where fixture.environment.users.count < 3 {
            await Task.yield()
        }

        fixture.environment.setActiveUser(user.id)
        await fixture.environment.setBotUser(bot.id)
        let submittedChat = Chat(scene: .temp, peerID: user.id, selfID: bot.id)
        fixture.environment.selectChat(submittedChat)

        fixture.environment.setActiveUser(other.id)
        let didSend = await fixture.environment.send(
            content: [.text("captured")],
            in: submittedChat,
            as: user.id
        )

        #expect(didSend)
        let messages = try await fixture.environment.store.messages(in: submittedChat)
        #expect(messages.map(\.senderID) == [user.id])
        #expect(messages.map(\.content.plainText) == ["captured"])
    }

    @Test("Group mentions build semantic segments for roster members")
    func groupMentionDraft() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let user = User(id: "user", name: "User")
        let bot = User(id: "bot", name: "TestBot")
        let member = User(id: "member", name: "Member")
        let outsider = User(id: "outsider", name: "Outsider")
        let chat = Chat(scene: .group, peerID: "group", selfID: bot.id)
        fixture.environment.users = [user, bot, member, outsider]
        fixture.environment.activeUserID = user.id
        for participant in [user, bot, member] {
            fixture.environment.members[
                .init(groupID: chat.peerID, userID: participant.id)
            ] = GroupMember(groupID: chat.peerID, userID: participant.id)
        }

        #expect(fixture.environment.mentionableUsers(in: chat).map(\.id) == [member.id, bot.id])
        #expect(
            fixture.environment.mentionableUsers(
                in: Chat(scene: .friend, peerID: user.id, selfID: bot.id)
            ).isEmpty
        )

        var draft = ComposerDraft()
        let addedBot = draft.addMention(userID: bot.id)
        let addedBotAgain = draft.addMention(userID: bot.id)
        #expect(addedBot)
        #expect(!addedBotAgain)
        draft.text = "  hello  "

        #expect(
            draft.messageContent() == [
                .mention(userID: bot.id),
                .text("hello"),
            ]
        )

        let addedEveryone = draft.addMention(userID: nil)
        #expect(addedEveryone)
        #expect(draft.messageContent() == [.mention(userID: nil), .text("hello")])

        let replacedEveryone = draft.addMention(userID: bot.id)
        #expect(replacedEveryone)
        #expect(
            draft.messageContent(allowedMentionUserIDs: [member.id]) == [.text("hello")]
        )
        draft.removeInvalidMentions(validUserIDs: [member.id])
        #expect(draft.mentions.isEmpty)

        var operationalDraft = ComposerDraft()
        operationalDraft.attachmentImportCount = 1
        #expect(!operationalDraft.isEmpty)
        operationalDraft.attachmentImportCount = 0
        operationalDraft.isSending = true
        #expect(!operationalDraft.isEmpty)

        let message = Message(
            scene: .group,
            peerID: chat.peerID,
            senderID: user.id,
            selfID: bot.id,
            content: [.mention(userID: bot.id), .text("hello")],
            direction: .outgoing
        )
        let summary = ConversationSummary(
            chat: chat,
            title: "Group",
            avatar: nil,
            lastMessage: message
        )
        #expect(fixture.environment.conversationPreview(for: summary) == "@TestBot hello")
    }

    private func makeFixture() throws -> ChatNavigationFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Matcha-ChatNavigationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let log = AppLog(directory: root, emitUnifiedLog: false)
        let defaultsName = "dev.matcha.tests.chat-navigation.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: defaultsName) else {
            throw CocoaError(.fileReadUnknown)
        }
        let environment = AppEnvironment(
            store: try MatchaStore(),
            assetStore: try AssetStore(
                directory: root.appendingPathComponent("Assets", isDirectory: true)
            ),
            appLog: log,
            defaults: defaults
        )
        return ChatNavigationFixture(
            root: root,
            defaultsName: defaultsName,
            defaults: defaults,
            environment: environment
        )
    }
}

@MainActor
private struct ChatNavigationFixture {
    let root: URL
    let defaultsName: String
    let defaults: UserDefaults
    let environment: AppEnvironment

    func remove() {
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
    }
}
