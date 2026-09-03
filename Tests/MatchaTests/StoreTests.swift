import Foundation
import Testing

@testable import MatchaCore

@Suite("Storage")
struct StoreTests {
    /// A store seeded with two users and a group they both belong to.
    private func makeFixture() async throws -> (store: MatchaStore, alice: User, bob: User, group: Group) {
        let store = try MatchaStore()
        let alice = User(id: "10001", name: "Alice")
        let bob = User(id: "10002", name: "Bob")
        let group = Group(id: "50001", name: "Test Group")
        try await store.save(alice)
        try await store.save(bob)
        try await store.save(group)
        try await store.save(GroupMember(groupID: group.id, userID: alice.id, role: .owner))
        try await store.save(GroupMember(groupID: group.id, userID: bob.id))
        return (store, alice, bob, group)
    }

    @Test("Users can be saved and loaded")
    func userRoundTrip() async throws {
        let store = try MatchaStore()
        let user = User(id: "10001", name: "Alice", nickname: "Aliçe", sex: .female, age: 20)
        try await store.save(user)

        let loaded = try await store.user(id: "10001")
        #expect(loaded?.name == "Alice")
        #expect(loaded?.nickname == "Aliçe")
        #expect(loaded?.sex == .female)
        #expect(loaded?.age == 20)
    }

    @Test("Observations emit the initial value and refresh after relevant writes")
    func observationEmitsInitialAndUpdatedValues() async throws {
        let store = try MatchaStore()
        let observation = store.observeUsers()
        var iterator = observation.makeAsyncIterator()

        let initial = try #require(try await iterator.next())
        #expect(initial.isEmpty)

        let user = User(id: "10001", name: "Alice")
        try await store.save(user)
        // An unrelated write must not replace the pending user refresh in the
        // observation's newest-one signal buffer.
        try await store.save(Asset(id: "asset", name: "asset.bin", source: .inline))

        let updated = try #require(try await iterator.next())
        #expect(updated.map(\.id) == [user.id])
    }

    @Test("Message segments survive JSON storage unchanged")
    func messageContentRoundTrip() async throws {
        let fixture = try await makeFixture()
        let asset = Asset(id: "sha256abc", name: "cat.png", mimeType: "image/png", byteCount: 1024, source: .inline)

        let content: [MessageSegment] = [
            .reply(messageID: "700001"),
            .mention(userID: fixture.bob.id),
            .text("See this image 🍵"),
            .image(asset),
            .face(id: "12", name: "Pout"),
            .unsupported(type: "market_face", payload: ["key": "abc"]),
        ]

        let stored = try await fixture.store.append(
            Message(
                scene: .group,
                peerID: fixture.group.id,
                senderID: fixture.alice.id,
                selfID: fixture.bob.id,
                content: content,
                direction: .outgoing
            )
        )

        let loaded = try await fixture.store.message(id: stored.id)
        #expect(loaded?.content == content)
        #expect(loaded?.content.plainText == "See this image 🍵")
        #expect(loaded?.content.replyTarget == "700001")
        #expect(loaded?.content.mentions == [fixture.bob.id])
    }

    @Test("Sequence numbers increment densely within each conversation")
    func sequenceNumbersAreDensePerChat() async throws {
        let fixture = try await makeFixture()
        let groupChat = Chat(scene: .group, peerID: fixture.group.id, selfID: fixture.bob.id)
        let privateChat = Chat(scene: .friend, peerID: fixture.alice.id, selfID: fixture.bob.id)

        for index in 1...3 {
            let stored = try await fixture.store.append(
                Message(
                    scene: .group,
                    peerID: groupChat.peerID,
                    senderID: fixture.alice.id,
                    selfID: fixture.bob.id,
                    content: [.text("Group message \(index)")],
                    direction: .outgoing
                )
            )
            #expect(stored.seq == Int64(index))
        }

        // A different conversation numbers independently.
        let firstPrivate = try await fixture.store.append(
            Message(
                scene: .friend,
                peerID: privateChat.peerID,
                senderID: fixture.alice.id,
                selfID: fixture.bob.id,
                content: [.text("Private message")],
                direction: .outgoing
            )
        )
        #expect(firstPrivate.seq == 1)

        let groupMessages = try await fixture.store.messages(in: groupChat)
        #expect(groupMessages.map(\.seq) == [1, 2, 3])
        #expect(groupMessages.first?.content.plainText == "Group message 1")
        #expect(try await fixture.store.messages(in: groupChat, limit: 0).isEmpty)
    }

    @Test("Messages can be looked up by sequence for Milky")
    func lookupBySequence() async throws {
        let fixture = try await makeFixture()
        let stored = try await fixture.store.append(
            Message(
                scene: .group,
                peerID: fixture.group.id,
                senderID: fixture.alice.id,
                selfID: fixture.bob.id,
                content: [.text("hello")],
                direction: .outgoing
            )
        )

        let found = try await fixture.store.message(
            scene: .group,
            peerID: fixture.group.id,
            seq: stored.seq,
            selfID: fixture.bob.id
        )
        #expect(found?.id == stored.id)

        let missing = try await fixture.store.message(
            scene: .group,
            peerID: fixture.group.id,
            seq: 9999,
            selfID: fixture.bob.id
        )
        #expect(missing == nil)
    }

    @Test("History pagination moves backward")
    func historyPaging() async throws {
        let fixture = try await makeFixture()
        for index in 1...10 {
            _ = try await fixture.store.append(
                Message(
                    scene: .group,
                    peerID: fixture.group.id,
                    senderID: fixture.alice.id,
                    selfID: fixture.bob.id,
                    content: [.text("Message \(index)")],
                    direction: .outgoing
                )
            )
        }

        let latest = try await fixture.store.history(
            scene: .group, peerID: fixture.group.id, selfID: fixture.bob.id, startSeq: nil, limit: 4
        )
        #expect(latest.map(\.seq) == [7, 8, 9, 10])

        // Page backwards from just before the previous page.
        let earlier = try await fixture.store.history(
            scene: .group, peerID: fixture.group.id, selfID: fixture.bob.id, startSeq: 6, limit: 4
        )
        #expect(earlier.map(\.seq) == [3, 4, 5, 6])
    }

    @Test("Recall records the operator")
    func recallMarksOperator() async throws {
        let fixture = try await makeFixture()
        let stored = try await fixture.store.append(
            Message(
                scene: .group,
                peerID: fixture.group.id,
                senderID: fixture.bob.id,
                selfID: fixture.bob.id,
                content: [.text("Recall me")],
                direction: .incoming
            )
        )

        let recalled = try await fixture.store.recallMessage(id: stored.id, by: fixture.alice.id)
        #expect(recalled?.isRecalled == true)
        #expect(recalled?.recalledBy == fixture.alice.id)
        #expect(try await fixture.store.message(id: stored.id)?.isRecalled == true)
    }

    @Test("Clearing chat history deletes only the target conversation and refreshes observations")
    func clearingMessageHistoryIsScopedAndObserved() async throws {
        let fixture = try await makeFixture()
        let target = Chat(scene: .group, peerID: fixture.group.id, selfID: fixture.bob.id)
        let otherAccount = Chat(scene: .group, peerID: fixture.group.id, selfID: fixture.alice.id)
        let privateChat = Chat(scene: .friend, peerID: fixture.alice.id, selfID: fixture.bob.id)

        let targetMessage = try await fixture.store.append(
            Message(
                scene: target.scene,
                peerID: target.peerID,
                senderID: fixture.alice.id,
                selfID: target.selfID,
                content: [.text("Clear me")],
                direction: .outgoing
            )
        )
        let otherAccountMessage = try await fixture.store.append(
            Message(
                scene: otherAccount.scene,
                peerID: otherAccount.peerID,
                senderID: fixture.bob.id,
                selfID: otherAccount.selfID,
                content: [.text("Other account")],
                direction: .outgoing
            )
        )
        let privateMessage = try await fixture.store.append(
            Message(
                scene: privateChat.scene,
                peerID: privateChat.peerID,
                senderID: fixture.alice.id,
                selfID: privateChat.selfID,
                content: [.text("Keep me")],
                direction: .outgoing
            )
        )

        var messageUpdates = fixture.store.observeMessages(in: target).makeAsyncIterator()
        var conversationUpdates = fixture.store.observeConversations(
            selfID: fixture.bob.id
        ).makeAsyncIterator()
        #expect(try await messageUpdates.next()?.map(\.id) == [targetMessage.id])
        #expect(try await conversationUpdates.next()?.count == 2)

        try await fixture.store.deleteMessages(in: target)

        #expect(try await messageUpdates.next()?.isEmpty == true)
        let conversations = try #require(try await conversationUpdates.next())
        #expect(conversations.map(\.chat) == [privateChat])
        #expect(try await fixture.store.messages(in: otherAccount).map(\.id) == [otherAccountMessage.id])
        #expect(try await fixture.store.messages(in: privateChat).map(\.id) == [privateMessage.id])

        let restarted = try await fixture.store.append(
            Message(
                scene: target.scene,
                peerID: target.peerID,
                senderID: fixture.alice.id,
                selfID: target.selfID,
                content: [.text("Start over")],
                direction: .outgoing
            )
        )
        #expect(restarted.seq == 1)
    }

    @Test("Removing a friendship is bidirectional")
    func friendshipRemovalIsBidirectional() async throws {
        let fixture = try await makeFixture()
        try await fixture.store.save(Friendship(userID: fixture.alice.id, friendID: fixture.bob.id, remark: "Bobby"))
        try await fixture.store.save(Friendship(userID: fixture.bob.id, friendID: fixture.alice.id))

        #expect(try await fixture.store.friendships(userID: fixture.alice.id).count == 1)
        #expect(try await fixture.store.friendships(userID: fixture.bob.id).count == 1)

        try await fixture.store.removeFriendship(userID: fixture.alice.id, friendID: fixture.bob.id)
        #expect(try await fixture.store.friendships(userID: fixture.alice.id).isEmpty)
        #expect(try await fixture.store.friendships(userID: fixture.bob.id).isEmpty)
    }

    @Test("Friendship observations refresh after additions and removals")
    func friendshipObservationTracksMutations() async throws {
        let fixture = try await makeFixture()
        let observation = fixture.store.observeFriendships(userID: fixture.alice.id)
        var iterator = observation.makeAsyncIterator()

        #expect(try await iterator.next()?.isEmpty == true)

        try await fixture.store.save(
            Friendship(userID: fixture.alice.id, friendID: fixture.bob.id)
        )
        let added = try #require(try await iterator.next())
        #expect(added.map(\.friendID) == [fixture.bob.id])

        try await fixture.store.removeFriendship(
            userID: fixture.alice.id,
            friendID: fixture.bob.id
        )
        #expect(try await iterator.next()?.isEmpty == true)
    }

    @Test("Requests can be found and resolved by flag")
    func requestsResolveByFlag() async throws {
        let fixture = try await makeFixture()
        let request = PendingRequest(
            kind: .groupJoin,
            requesterID: fixture.alice.id,
            groupID: fixture.group.id,
            selfID: fixture.bob.id,
            comment: "Please let me join"
        )
        try await fixture.store.save(request)

        let found = try await fixture.store.request(flag: request.flag)
        #expect(found?.id == request.id)
        #expect(found?.comment == "Please let me join")
        #expect(try await fixture.store.pendingRequests(selfID: fixture.bob.id).count == 1)

        let resolved = try await fixture.store.resolve(requestID: request.id, as: .rejected(reason: "Group is full"))
        #expect(resolved?.resolution == .rejected(reason: "Group is full"))
        // Resolved requests drop out of the pending list.
        #expect(try await fixture.store.pendingRequests(selfID: fixture.bob.id).isEmpty)
    }

    @Test("Membership queries relate members and groups")
    func membershipQueries() async throws {
        let fixture = try await makeFixture()
        #expect(try await fixture.store.memberCount(groupID: fixture.group.id) == 2)

        let aliceGroups = try await fixture.store.groups(containing: fixture.alice.id)
        #expect(aliceGroups.map(\.id) == [fixture.group.id])

        let owner = try await fixture.store.member(groupID: fixture.group.id, userID: fixture.alice.id)
        #expect(owner?.role == .owner)
        #expect(owner?.role ?? .member > .member)

        try await fixture.store.removeMember(groupID: fixture.group.id, userID: fixture.bob.id)
        #expect(try await fixture.store.memberCount(groupID: fixture.group.id) == 1)
    }

    @Test("Deleting a group cascades to related entities and refreshes all observations")
    func deletingGroupCascadesAndRefreshesObservations() async throws {
        let fixture = try await makeFixture()
        let otherGroup = Group(id: "50002", name: "Retained Group")
        try await fixture.store.save(otherGroup)
        try await fixture.store.save(
            GroupMember(groupID: otherGroup.id, userID: fixture.bob.id, role: .owner)
        )

        let targetForBob = Chat(scene: .group, peerID: fixture.group.id, selfID: fixture.bob.id)
        let targetForAlice = Chat(scene: .group, peerID: fixture.group.id, selfID: fixture.alice.id)
        let retainedChat = Chat(scene: .group, peerID: otherGroup.id, selfID: fixture.bob.id)
        _ = try await fixture.store.append(
            Message(
                scene: .group,
                peerID: fixture.group.id,
                senderID: fixture.alice.id,
                selfID: fixture.bob.id,
                content: [.text("Bob's view")],
                direction: .outgoing
            )
        )
        _ = try await fixture.store.append(
            Message(
                scene: .group,
                peerID: fixture.group.id,
                senderID: fixture.bob.id,
                selfID: fixture.alice.id,
                content: [.text("Alice's view")],
                direction: .outgoing
            )
        )
        let retainedMessage = try await fixture.store.append(
            Message(
                scene: .group,
                peerID: otherGroup.id,
                senderID: fixture.bob.id,
                selfID: fixture.bob.id,
                content: [.text("Must not be deleted")],
                direction: .incoming
            )
        )
        let targetRequest = PendingRequest(
            kind: .groupJoin,
            requesterID: fixture.alice.id,
            groupID: fixture.group.id,
            selfID: fixture.bob.id
        )
        let retainedRequest = PendingRequest(
            kind: .groupJoin,
            requesterID: fixture.alice.id,
            groupID: otherGroup.id,
            selfID: fixture.bob.id
        )
        try await fixture.store.save(targetRequest)
        try await fixture.store.save(retainedRequest)

        var groupUpdates = fixture.store.observeGroups().makeAsyncIterator()
        var memberUpdates = fixture.store.observeMembers(
            groupID: fixture.group.id
        ).makeAsyncIterator()
        var messageUpdates = fixture.store.observeMessages(in: targetForBob).makeAsyncIterator()
        var requestUpdates = fixture.store.observePendingRequests(
            selfID: fixture.bob.id
        ).makeAsyncIterator()
        var conversationUpdates = fixture.store.observeConversations(
            selfID: fixture.bob.id
        ).makeAsyncIterator()
        _ = try await groupUpdates.next()
        _ = try await memberUpdates.next()
        _ = try await messageUpdates.next()
        _ = try await requestUpdates.next()
        _ = try await conversationUpdates.next()

        try await fixture.store.deleteGroup(id: fixture.group.id)

        #expect(try await fixture.store.group(id: fixture.group.id) == nil)
        #expect(try await fixture.store.members(groupID: fixture.group.id).isEmpty)
        #expect(try await fixture.store.messages(in: targetForBob).isEmpty)
        #expect(try await fixture.store.messages(in: targetForAlice).isEmpty)
        #expect(try await fixture.store.request(id: targetRequest.id) == nil)
        #expect(try await fixture.store.group(id: otherGroup.id) != nil)
        #expect(try await fixture.store.messages(in: retainedChat).map(\.id) == [retainedMessage.id])
        #expect(try await fixture.store.request(id: retainedRequest.id) != nil)

        #expect(try await groupUpdates.next()?.map(\.id) == [otherGroup.id])
        #expect(try await memberUpdates.next()?.isEmpty == true)
        #expect(try await messageUpdates.next()?.isEmpty == true)
        #expect(try await requestUpdates.next()?.map(\.id) == [retainedRequest.id])
        #expect(try await conversationUpdates.next()?.map(\.chat) == [retainedChat])
    }

    @Test("Conversation list is ordered by most recent activity")
    func conversationListOrdering() async throws {
        let fixture = try await makeFixture()
        _ = try await fixture.store.append(
            Message(
                scene: .group, peerID: fixture.group.id, senderID: fixture.alice.id,
                selfID: fixture.bob.id, content: [.text("Group message")], time: Date(timeIntervalSince1970: 1000),
                direction: .outgoing
            )
        )
        _ = try await fixture.store.append(
            Message(
                scene: .group, peerID: fixture.group.id, senderID: fixture.alice.id,
                selfID: fixture.bob.id, content: [.text("Last group sequence")], time: Date(timeIntervalSince1970: 500),
                direction: .outgoing
            )
        )
        _ = try await fixture.store.append(
            Message(
                scene: .friend, peerID: fixture.alice.id, senderID: fixture.alice.id,
                selfID: fixture.bob.id, content: [.text("Private message")], time: Date(timeIntervalSince1970: 2000),
                direction: .outgoing
            )
        )

        let chats = try await fixture.store.activeChats(selfID: fixture.bob.id)
        #expect(chats.count == 2)
        #expect(chats.first?.chat.scene == .friend)
        #expect(chats.first?.lastMessage.content.plainText == "Private message")
        #expect(chats.last?.lastMessage.content.plainText == "Last group sequence")
    }
}
