import Foundation
import ReiCore
import ReiProtocol
import Testing

@Suite("Platform Service")
struct PlatformServiceTests {
    /// A group with one of each role plus a registered bot, which is what the
    /// permission rules need in order to say anything interesting.
    private struct Fixture {
        let store: ReiStore
        let platform: PlatformService
        let owner: User
        let admin: User
        let member: User
        let bot: User
        let group: Group
    }

    private func makeFixture() async throws -> Fixture {
        let store = try ReiStore()
        let owner = User(id: "10001", name: "Owner")
        let admin = User(id: "10002", name: "Admin")
        let member = User(id: "10003", name: "Member")
        let bot = User(id: "10004", name: "Bot")
        let group = Group(id: "500000001", name: "Test Group")

        for user in [owner, admin, member, bot] {
            try await store.save(user)
        }
        try await store.save(group)
        try await store.save(GroupMember(groupID: group.id, userID: owner.id, role: .owner))
        try await store.save(GroupMember(groupID: group.id, userID: admin.id, role: .admin))
        try await store.save(GroupMember(groupID: group.id, userID: member.id))
        try await store.save(GroupMember(groupID: group.id, userID: bot.id))

        let platform = PlatformService(store: store)
        await platform.registerBot(id: bot.id)
        return Fixture(
            store: store, platform: platform,
            owner: owner, admin: admin, member: member, bot: bot, group: group
        )
    }

    @discardableResult
    private func send(
        _ fixture: Fixture,
        from senderID: String,
        text: String = "hello"
    ) async throws -> Message {
        try await fixture.platform.sendMessage(
            scene: .group,
            peerID: fixture.group.id,
            senderID: senderID,
            selfID: fixture.bot.id,
            content: [.text(text)]
        )
    }

    /// Runs `action` and collects up to `count` events, giving up after `within`
    /// seconds.
    ///
    /// The wait is bounded because "no event at all" is the expected result for the
    /// suppression tests: an unbounded `for await` would hang the suite instead of
    /// failing it.
    private func collectEvents(
        from platform: PlatformService,
        count: Int = 1,
        within seconds: Double = 2,
        while action: () async throws -> Void
    ) async throws -> [DomainEvent] {
        let stream = await platform.events()
        let collector = Task { () -> [DomainEvent] in
            var received: [DomainEvent] = []
            // Cancelling a task suspended on an AsyncStream ends the iteration, so
            // the timeout below turns into an early return of whatever arrived.
            for await event in stream {
                received.append(event)
                if received.count >= count { break }
            }
            return received
        }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(seconds))
            collector.cancel()
        }

        try await action()
        let received = await collector.value
        timeout.cancel()
        return received
    }

    // MARK: - Mutes

    @Test("Muted members cannot send until unmuted")
    func mutedMemberCannotSend() async throws {
        let fixture = try await makeFixture()
        try await fixture.platform.muteMember(
            groupID: fixture.group.id,
            userID: fixture.member.id,
            operatorID: fixture.admin.id,
            duration: 600
        )

        await #expect(throws: PlatformError.self) {
            try await send(fixture, from: fixture.member.id)
        }

        // A zero duration lifts it.
        try await fixture.platform.muteMember(
            groupID: fixture.group.id,
            userID: fixture.member.id,
            operatorID: fixture.admin.id,
            duration: 0
        )
        let sent = try await send(fixture, from: fixture.member.id, text: "Unmuted")
        #expect(sent.content.plainText == "Unmuted")
    }

    @Test("Global mute blocks members but not admins or the owner")
    func wholeMuteSparesModerators() async throws {
        let fixture = try await makeFixture()
        try await fixture.platform.setWholeMute(
            groupID: fixture.group.id,
            operatorID: fixture.owner.id,
            muted: true
        )

        await #expect(throws: PlatformError.self) {
            try await send(fixture, from: fixture.member.id)
        }
        // Those who can lift a whole-group mute are not subject to it.
        _ = try await send(fixture, from: fixture.admin.id, text: "Admin can still speak")
        _ = try await send(fixture, from: fixture.owner.id, text: "Owner can still speak")
    }

    // MARK: - Recall permissions

    @Test("Senders can recall their own messages")
    func senderMayRecallOwnMessage() async throws {
        let fixture = try await makeFixture()
        let message = try await send(fixture, from: fixture.member.id)

        let recalled = try await fixture.platform.recallMessage(
            id: message.id,
            operatorID: fixture.member.id
        )
        #expect(recalled.isRecalled)
        #expect(recalled.recalledBy == fixture.member.id)
    }

    @Test("Admins can recall member messages")
    func adminMayRecallMemberMessage() async throws {
        let fixture = try await makeFixture()
        let message = try await send(fixture, from: fixture.member.id)

        let recalled = try await fixture.platform.recallMessage(
            id: message.id,
            operatorID: fixture.admin.id
        )
        #expect(recalled.recalledBy == fixture.admin.id)
    }

    @Test("Admins cannot recall owner or peer admin messages")
    func adminMayNotRecallPeerOrOwnerMessage() async throws {
        let fixture = try await makeFixture()
        let ownerMessage = try await send(fixture, from: fixture.owner.id)
        await #expect(throws: PlatformError.self) {
            try await fixture.platform.recallMessage(
                id: ownerMessage.id,
                operatorID: fixture.admin.id
            )
        }

        // Promote the bot so there are two peers of equal rank.
        try await fixture.platform.setAdmin(
            groupID: fixture.group.id,
            userID: fixture.bot.id,
            operatorID: fixture.owner.id,
            granted: true
        )
        let peerMessage = try await send(fixture, from: fixture.bot.id)
        await #expect(throws: PlatformError.self) {
            try await fixture.platform.recallMessage(
                id: peerMessage.id,
                operatorID: fixture.admin.id
            )
        }
    }

    @Test("Only the sender can recall a private message")
    func nobodyMayRecallAnotherPrivateMessage() async throws {
        let fixture = try await makeFixture()
        let message = try await fixture.platform.sendMessage(
            scene: .friend,
            peerID: fixture.member.id,
            senderID: fixture.member.id,
            selfID: fixture.bot.id,
            content: [.text("Private message")]
        )

        // Group rank grants no authority in a one-to-one conversation.
        await #expect(throws: PlatformError.self) {
            try await fixture.platform.recallMessage(id: message.id, operatorID: fixture.owner.id)
        }
        let recalled = try await fixture.platform.recallMessage(
            id: message.id,
            operatorID: fixture.member.id
        )
        #expect(recalled.isRecalled)
    }

    @Test("Private messages reject senders outside the two endpoints")
    func privateMessageRejectsThirdPartySender() async throws {
        let fixture = try await makeFixture()

        await #expect(throws: PlatformError.self) {
            try await fixture.platform.sendMessage(
                scene: .friend,
                peerID: fixture.member.id,
                senderID: fixture.owner.id,
                selfID: fixture.bot.id,
                content: [.text("Wrong conversation")]
            )
        }

        #expect(try await fixture.store.activeChats(selfID: fixture.bot.id).isEmpty)

        await #expect(throws: PlatformError.self) {
            try await fixture.platform.sendMessage(
                scene: .friend,
                peerID: fixture.bot.id,
                senderID: fixture.bot.id,
                selfID: fixture.bot.id,
                content: [.text("Self chat")]
            )
        }
    }

    // MARK: - Administration

    @Test("Only the owner can assign admins")
    func onlyOwnerMaySetAdmin() async throws {
        let fixture = try await makeFixture()

        await #expect(throws: PlatformError.self) {
            try await fixture.platform.setAdmin(
                groupID: fixture.group.id,
                userID: fixture.bot.id,
                operatorID: fixture.member.id,
                granted: true
            )
        }

        try await fixture.platform.setAdmin(
            groupID: fixture.group.id,
            userID: fixture.bot.id,
            operatorID: fixture.owner.id,
            granted: true
        )
        let promoted = try await fixture.store.member(groupID: fixture.group.id, userID: fixture.bot.id)
        #expect(promoted?.role == .admin)
    }

    @Test("Admins cannot remove peer admins or the owner")
    func adminMayNotKickPeerOrOwner() async throws {
        let fixture = try await makeFixture()
        try await fixture.platform.setAdmin(
            groupID: fixture.group.id,
            userID: fixture.bot.id,
            operatorID: fixture.owner.id,
            granted: true
        )

        await #expect(throws: PlatformError.self) {
            try await fixture.platform.removeMember(
                groupID: fixture.group.id,
                userID: fixture.bot.id,
                operatorID: fixture.admin.id,
                reason: .administrative
            )
        }
        await #expect(throws: PlatformError.self) {
            try await fixture.platform.removeMember(
                groupID: fixture.group.id,
                userID: fixture.owner.id,
                operatorID: fixture.admin.id,
                reason: .administrative
            )
        }
        // A plain member is fair game.
        try await fixture.platform.removeMember(
            groupID: fixture.group.id,
            userID: fixture.member.id,
            operatorID: fixture.admin.id,
            reason: .administrative
        )
        #expect(try await fixture.store.member(groupID: fixture.group.id, userID: fixture.member.id) == nil)
    }

    // MARK: - Self-echo suppression

    @Test("Disabling self-echo prevents the bot from receiving its own events")
    func selfEventsAreSuppressedByDefault() async throws {
        let fixture = try await makeFixture()
        #expect(await fixture.platform.echoesSelfEvents == false)

        let events = try await collectEvents(from: fixture.platform, within: 0.5) {
            // Bot is both sender and session owner, so this is its own activity.
            _ = try await fixture.platform.sendMessage(
                scene: .group,
                peerID: fixture.group.id,
                senderID: fixture.bot.id,
                selfID: fixture.bot.id,
                content: [.text("Sent by the bot")]
            )
        }
        // This is what stops a framework receiving its own sends back as incoming.
        #expect(events.isEmpty)
    }

    @Test("Enabling self-echo delivers the bot's own events")
    func selfEventsArriveWhenEchoIsOn() async throws {
        let fixture = try await makeFixture()
        await fixture.platform.setEchoesSelfEvents(true)
        #expect(await fixture.platform.echoesSelfEvents)

        let events = try await collectEvents(from: fixture.platform) {
            _ = try await fixture.platform.sendMessage(
                scene: .group,
                peerID: fixture.group.id,
                senderID: fixture.bot.id,
                selfID: fixture.bot.id,
                content: [.text("Sent by the bot")]
            )
        }
        #expect(events.count == 1)
        guard case .message(let message) = events.first?.payload else {
            Issue.record("Expected a message event")
            return
        }
        #expect(message.content.plainText == "Sent by the bot")
    }

    @Test("Events caused by other users still reach the bot")
    func othersEventsAlwaysArrive() async throws {
        let fixture = try await makeFixture()
        let events = try await collectEvents(from: fixture.platform) {
            try await send(fixture, from: fixture.member.id, text: "Sent by someone else")
        }
        #expect(events.count == 1)
        #expect(events.first?.selfID == fixture.bot.id)
    }

    // MARK: - Requests

    @Test("Approving a friend request creates both relationships and broadcasts friendAdded")
    func acceptingFriendRequestCreatesBothDirections() async throws {
        let fixture = try await makeFixture()
        let request = try await fixture.platform.requestFriend(
            requesterID: fixture.member.id,
            targetID: fixture.bot.id,
            comment: "Let's be friends"
        )

        let events = try await collectEvents(from: fixture.platform) {
            try await fixture.platform.resolveRequest(flag: request.flag, approve: true, remark: "Buddy")
        }

        guard case .friendAdded(let userID) = events.first?.payload else {
            Issue.record("Expected a friendAdded event")
            return
        }
        #expect(userID == fixture.member.id)

        // Directional rows, so each side keeps its own remark.
        let botSide = try await fixture.store.friendship(userID: fixture.bot.id, friendID: fixture.member.id)
        let memberSide = try await fixture.store.friendship(userID: fixture.member.id, friendID: fixture.bot.id)
        #expect(botSide?.remark == "Buddy")
        #expect(memberSide != nil)
    }

    @Test("Adding a friend directly creates both relationships and notifies both users")
    func directFriendshipCreationNotifiesBothSides() async throws {
        let fixture = try await makeFixture()

        let events = try await collectEvents(from: fixture.platform, count: 2) {
            try await fixture.platform.addFriendship(
                userID: fixture.bot.id,
                friendID: fixture.member.id
            )
        }

        #expect(
            try await fixture.store.friendship(
                userID: fixture.bot.id,
                friendID: fixture.member.id
            ) != nil)
        #expect(
            try await fixture.store.friendship(
                userID: fixture.member.id,
                friendID: fixture.bot.id
            ) != nil)
        #expect(Set(events.map(\.selfID)) == [fixture.bot.id, fixture.member.id])
    }

    @Test("Removing a friend deletes both relationships but preserves chat history")
    func removingFriendPreservesHistoryAndPublishesEvent() async throws {
        let fixture = try await makeFixture()
        try await fixture.platform.addFriendship(
            userID: fixture.bot.id,
            friendID: fixture.member.id
        )
        let chat = Chat(scene: .friend, peerID: fixture.member.id, selfID: fixture.bot.id)
        let message = try await fixture.store.append(
            Message(
                scene: chat.scene,
                peerID: chat.peerID,
                senderID: fixture.member.id,
                selfID: chat.selfID,
                content: [.text("History must be preserved")],
                direction: .outgoing
            )
        )

        let events = try await collectEvents(from: fixture.platform) {
            try await fixture.platform.removeFriend(
                userID: fixture.bot.id,
                friendID: fixture.member.id
            )
        }

        #expect(
            try await fixture.store.friendship(
                userID: fixture.bot.id,
                friendID: fixture.member.id
            ) == nil)
        #expect(
            try await fixture.store.friendship(
                userID: fixture.member.id,
                friendID: fixture.bot.id
            ) == nil)
        #expect(try await fixture.store.messages(in: chat).map(\.id) == [message.id])
        #expect(events.first?.selfID == fixture.bot.id)
        guard case .friendRemoved(let userID) = events.first?.payload else {
            Issue.record("Expected a friendRemoved event")
            return
        }
        #expect(userID == fixture.member.id)

        await #expect(throws: PlatformError.self) {
            try await fixture.platform.removeFriend(
                userID: fixture.bot.id,
                friendID: fixture.member.id
            )
        }
    }

    @Test("Approving a group join request adds the member and emits groupMemberAdded")
    func acceptingGroupJoinAddsMember() async throws {
        let fixture = try await makeFixture()
        let newcomer = User(id: "10005", name: "Newcomer")
        try await fixture.store.save(newcomer)
        // The bot approves, so it is the origin of the resulting join; self-echo has
        // to be on for the bot to observe an event it caused.
        await fixture.platform.setEchoesSelfEvents(true)

        let request = try await fixture.platform.requestJoinGroup(
            groupID: fixture.group.id,
            requesterID: newcomer.id,
            targetBotID: fixture.bot.id,
            comment: "Please let me join"
        )

        let events = try await collectEvents(from: fixture.platform) {
            try await fixture.platform.resolveRequest(flag: request.flag, approve: true)
        }

        guard case .groupMemberAdded(let change) = events.first?.payload else {
            Issue.record("Expected a groupMemberAdded event")
            return
        }
        #expect(change.userID == newcomer.id)
        #expect(change.groupID == fixture.group.id)
        #expect(change.reason == .administrative)
        #expect(try await fixture.store.member(groupID: fixture.group.id, userID: newcomer.id) != nil)
    }

    @Test("A resolved request cannot be resolved again")
    func resolvingTwiceIsRefused() async throws {
        let fixture = try await makeFixture()
        let request = try await fixture.platform.requestFriend(
            requesterID: fixture.member.id,
            targetID: fixture.bot.id
        )
        try await fixture.platform.resolveRequest(flag: request.flag, approve: false, reason: "No longer needed")

        await #expect(throws: PlatformError.self) {
            try await fixture.platform.resolveRequest(flag: request.flag, approve: true)
        }
    }

    @Test("A full group rejects new members")
    func fullGroupRefusesJoin() async throws {
        let store = try ReiStore()
        let first = User(id: "10001", name: "First")
        let second = User(id: "10002", name: "Second")
        let group = Group(id: "500000002", name: "Small Group", maxMemberCount: 1)
        try await store.save(first)
        try await store.save(second)
        try await store.save(group)

        let platform = PlatformService(store: store)
        try await platform.addMember(groupID: group.id, userID: first.id)

        await #expect(throws: PlatformError.self) {
            try await platform.addMember(groupID: group.id, userID: second.id)
        }
        #expect(try await store.memberCount(groupID: group.id) == 1)
    }

    @Test("A non-member cannot invite another user to the group")
    func nonMemberCannotInviteMember() async throws {
        let fixture = try await makeFixture()
        let outsider = User(id: "10005", name: "Outsider")
        let newcomer = User(id: "10006", name: "Newcomer")
        try await fixture.store.save(outsider)
        try await fixture.store.save(newcomer)

        await #expect(throws: PlatformError.self) {
            try await fixture.platform.addMember(
                groupID: fixture.group.id,
                userID: newcomer.id,
                operatorID: outsider.id,
                reason: .invited
            )
        }
        #expect(try await fixture.store.member(groupID: fixture.group.id, userID: newcomer.id) == nil)
    }
}
