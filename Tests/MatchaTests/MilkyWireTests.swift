import Foundation
import Testing

import MatchaCore
import MatchaProtocol

// The segment coder and event encoder are internal to the module, so the wire-level
// assertions reach them through a testable import.
@testable import MatchaMilky

/// Deterministic stand-in for the real resolver: fixed dimensions and a predictable
/// temp URL, so an assertion about wire shape never depends on the filesystem.
private struct StubMilkyAssetResolver: MilkyAssetResolver {
    /// Replies resolve only for this ID, which lets a test cover both the found and
    /// the dropped branch.
    var replyTarget: (id: String, reference: MilkyReplyReference)?

    func resource(for asset: Asset) async -> MilkyResource {
        MilkyResource(
            resourceID: asset.id,
            tempURL: "http://127.0.0.1/assets/\(asset.id)",
            width: 640,
            height: 480
        )
    }

    func ingest(uri: String, kind: AssetKind) async -> Asset? {
        Asset(id: "sha-\(kind.rawValue)", name: uri, source: .remote(url: uri))
    }

    func displayName(for userID: String) async -> String { "User\(userID)" }

    func replyReference(messageID: String) async -> MilkyReplyReference? {
        guard let replyTarget, replyTarget.id == messageID else { return nil }
        return replyTarget.reference
    }

    func messageID(forSeq seq: Int64) async -> String? { "70000000\(seq)" }
}

private func isNumber(_ value: JSONValue?) -> Bool {
    if case .some(.number) = value { return true }
    return false
}

private func isIntegerNumber(_ value: JSONValue?) -> Bool {
    guard case let .some(.number(number)) = value else { return false }
    return number.isFinite && number.rounded(.towardZero) == number
}

private func segmentTypes(_ segments: [JSONValue]?) -> [String] {
    (segments ?? []).compactMap { $0["type"]?.stringValue }
}

@Suite("Milky Wire Format")
struct MilkyWireTests {
    private struct Fixture {
        let store: MatchaStore
        let platform: PlatformService
        let adapter: MilkyProtocolImplementation
        let bot: User
        let alice: User
        let group: Group
    }

    private func makeFixture(
        resolver: StubMilkyAssetResolver = StubMilkyAssetResolver()
    ) async throws -> Fixture {
        let store = try MatchaStore()
        let bot = User(id: "10001", name: "Bot")
        let alice = User(id: "10002", name: "Alice", nickname: "Ally")
        let group = Group(id: "500000001", name: "Test Group", intro: "Group description")
        try await store.save(bot)
        try await store.save(alice)
        try await store.save(group)
        try await store.save(GroupMember(groupID: group.id, userID: bot.id, role: .admin))
        try await store.save(
            GroupMember(groupID: group.id, userID: alice.id, card: "Ali", title: "Veteran")
        )
        try await store.save(Friendship(userID: bot.id, friendID: alice.id, remark: "Old friend"))

        let platform = PlatformService(store: store)
        await platform.registerBot(id: bot.id)
        let adapter = MilkyProtocolImplementation(
            selfID: bot.id,
            platform: platform,
            assetResolver: resolver
        )
        return Fixture(store: store, platform: platform, adapter: adapter, bot: bot, alice: alice, group: group)
    }

    private func message(
        _ fixture: Fixture,
        scene: ChatScene = .group,
        content: [MessageSegment] = [.text("Hello")]
    ) -> Message {
        Message(
            id: "70000000001",
            seq: 7,
            scene: scene,
            peerID: scene == .group ? fixture.group.id : fixture.alice.id,
            senderID: fixture.alice.id,
            selfID: fixture.bot.id,
            content: content,
            direction: .outgoing
        )
    }

    private func encodeOne(_ fixture: Fixture, _ event: DomainEvent) async throws -> JSONValue {
        let frames = await fixture.adapter.encode(event: event)
        #expect(frames.count == 1)
        return try #require(frames.first?.payload)
    }

    private func coder(_ resolver: StubMilkyAssetResolver = StubMilkyAssetResolver()) -> MilkySegmentCoder {
        MilkySegmentCoder(assetResolver: resolver)
    }

    // MARK: - Envelope

    @Test("Event envelopes contain time/self_id/event_type/data with numeric self_id")
    func eventEnvelopeShape() async throws {
        let fixture = try await makeFixture()
        let payload = try await encodeOne(
            fixture,
            DomainEvent(selfID: fixture.bot.id, payload: .message(message(fixture)))
        )

        #expect(isNumber(payload["time"]))
        #expect(isNumber(payload["self_id"]))
        #expect(payload["self_id"]?.stringValue == fixture.bot.id)
        // A single flat string, with none of OneBot's post_type/notice_type nesting.
        #expect(payload["event_type"]?.stringValue == "message_receive")
        #expect(payload["data"] != nil)
        #expect(payload["post_type"] == nil)
        #expect(payload["detail_type"] == nil)
    }

    @Test("message_receive.data is a flat IncomingMessage without nested data")
    func incomingMessageIsFlatInsideData() async throws {
        let fixture = try await makeFixture()
        let payload = try await encodeOne(
            fixture,
            DomainEvent(selfID: fixture.bot.id, payload: .message(message(fixture)))
        )
        let data = try #require(payload["data"])

        // Event bodies nest under `data`, but IncomingMessage itself is flat: these
        // three are siblings, not grandchildren.
        #expect(data["message_scene"]?.stringValue == "group")
        #expect(data["peer_id"]?.stringValue == fixture.group.id)
        #expect(data["segments"]?.arrayValue != nil)
        #expect(data["message_seq"]?.int64Value == 7)
        #expect(data["sender_id"]?.stringValue == fixture.alice.id)
        // The mistake this pins: a second `data` level inside the message body.
        #expect(data["data"] == nil)
    }

    @Test("Group messages embed complete group and group_member entities")
    func groupMessageEmbedsGroupAndMember() async throws {
        let fixture = try await makeFixture()
        let payload = try await encodeOne(
            fixture,
            DomainEvent(selfID: fixture.bot.id, payload: .message(message(fixture)))
        )
        let data = try #require(payload["data"])

        // Milky embeds whole entities so a framework needs no follow-up calls.
        let group = try #require(data["group"])
        #expect(group["group_name"]?.stringValue == "Test Group")
        #expect(group["member_count"]?.intValue == 2)
        #expect(group["max_member_count"]?.intValue == 200)
        #expect(group["description"]?.stringValue == "Group description")

        let member = try #require(data["group_member"])
        #expect(member["user_id"]?.stringValue == fixture.alice.id)
        #expect(member["card"]?.stringValue == "Ali")
        #expect(member["title"]?.stringValue == "Veteran")
        #expect(member["role"]?.stringValue == "member")
        // A member carries its own group_id, so it is self-describing.
        #expect(member["group_id"]?.stringValue == fixture.group.id)
        #expect(data["friend"] == nil)
    }

    @Test("All timestamps and durations are encoded as JSON integers")
    func timestampsAndDurationsAreIntegers() async throws {
        let reply = MilkyReplyReference(
            seq: 8,
            senderID: "10002",
            time: Date(timeIntervalSince1970: 2_222.75),
            content: [.text("Quoted message")]
        )
        let resolver = StubMilkyAssetResolver(replyTarget: ("reply", reply))
        let fixture = try await makeFixture(resolver: resolver)
        var fractionalMessage = message(fixture, content: [.reply(messageID: "reply")])
        fractionalMessage.time = Date(timeIntervalSince1970: 1_700.75)

        let payload = try await encodeOne(
            fixture,
            DomainEvent(selfID: fixture.bot.id, payload: .message(fractionalMessage))
        )
        let data = try #require(payload["data"])
        #expect(isIntegerNumber(payload["time"]))
        #expect(isIntegerNumber(data["time"]))
        #expect(data["time"]?.doubleValue == 1_700)
        #expect(isIntegerNumber(data["group"]?["created_time"]))
        #expect(isIntegerNumber(data["group_member"]?["join_time"]))
        #expect(isIntegerNumber(data["group_member"]?["last_sent_time"]))

        let replySegment = try #require(
            data["segments"]?.arrayValue?.first(where: { $0["type"]?.stringValue == "reply" })
        )
        #expect(isIntegerNumber(replySegment["data"]?["time"]))
        #expect(replySegment["data"]?["time"]?.doubleValue == 2_222)

        let record = Asset(id: "voice", name: "voice.amr", source: .inline)
        let recordSegment = try #require(
            await coder(resolver).encodeIncoming([.record(record, duration: 3.75)]).first
        )
        #expect(isIntegerNumber(recordSegment["data"]?["duration"]))
        #expect(recordSegment["data"]?["duration"]?.doubleValue == 3)

        let request = PendingRequest(
            kind: .friend,
            requesterID: fixture.alice.id,
            selfID: fixture.bot.id,
            time: Date(timeIntervalSince1970: 4_444.9)
        )
        let requestPayload = fixture.adapter.entityEncoder.friendRequest(request)
        #expect(isIntegerNumber(requestPayload["time"]))
        #expect(requestPayload["time"]?.doubleValue == 4_444)
    }

    @Test("Friend messages embed a friend entity")
    func friendMessageEmbedsFriend() async throws {
        let fixture = try await makeFixture()
        let payload = try await encodeOne(
            fixture,
            DomainEvent(selfID: fixture.bot.id, payload: .message(message(fixture, scene: .friend)))
        )
        let data = try #require(payload["data"])

        #expect(data["message_scene"]?.stringValue == "friend")
        let friend = try #require(data["friend"])
        #expect(friend["nickname"]?.stringValue == "Ally")
        #expect(friend["remark"]?.stringValue == "Old friend")
        #expect(friend["category"]?["category_id"]?.intValue == 0)
        #expect(friend["category"]?["category_name"]?.stringValue?.isEmpty == false)
        #expect(data["group"] == nil)
        #expect(data["group_member"] == nil)
    }

    // MARK: - Segment direction asymmetry

    @Test("Incoming images include resource_id and dimensions; outgoing images require only uri")
    func imageDirectionsAreAsymmetric() async throws {
        let coder = coder()
        let asset = Asset(id: "sha-img", name: "cat.png", mimeType: "image/png", source: .inline)

        // Incoming: what the framework receives, with everything needed to display it.
        let incoming = await coder.encodeIncoming([.image(asset)])
        #expect(segmentTypes(incoming) == ["image"])
        let data = try #require(incoming.first?["data"])
        #expect(data["resource_id"]?.stringValue == "sha-img")
        #expect(data["temp_url"]?.stringValue == "http://127.0.0.1/assets/sha-img")
        #expect(data["width"]?.intValue == 640)
        #expect(data["height"]?.intValue == 480)
        #expect(data["sub_type"]?.stringValue == "normal")
        // Outgoing's key is absent from the incoming form.
        #expect(data["uri"] == nil)

        // Outgoing: a single uri, which the resolver ingests.
        let outgoing = await coder.decodeOutgoing([
            ["type": "image", "data": ["uri": "https://example.com/cat.png"]],
        ])
        guard case let .image(ingested) = outgoing.first else {
            Issue.record("Expected an image segment to decode")
            return
        }
        #expect(ingested.source == .remote(url: "https://example.com/cat.png"))
        // Without a uri there is nothing to ingest, so the segment drops.
        #expect(await coder.decodeOutgoing([["type": "image", "data": ["resource_id": "sha-img"]]]).isEmpty)
    }

    @Test("mention_all represents @everyone and user mentions include name")
    func mentionSegments() async throws {
        let coder = coder()

        let all = await coder.encodeIncoming([.mention(userID: nil)])
        #expect(segmentTypes(all) == ["mention_all"])

        let one = await coder.encodeIncoming([.mention(userID: "10002")])
        #expect(segmentTypes(one) == ["mention"])
        let data = try #require(one.first?["data"])
        #expect(data["user_id"]?.stringValue == "10002")
        // Since 1.2 the name is carried inline, with no leading "@".
        #expect(data["name"]?.stringValue == "User10002")
    }

    @Test("Pokes do not produce message segments")
    func pokeProducesNoSegment() async throws {
        let coder = coder()
        // Nudges are events in Milky (friend_nudge/group_nudge), never segments, so
        // there is nothing to encode.
        #expect(await coder.encodeIncoming([.poke(userID: "10002")]).isEmpty)

        let mixed = await coder.encodeIncoming([.text("a"), .poke(userID: nil), .text("b")])
        #expect(segmentTypes(mixed) == ["text", "text"])
    }

    // MARK: - Mute split

    @Test("Mute events split into group_mute or group_whole_mute based on userID")
    func muteSplitsOnUserID() async throws {
        let fixture = try await makeFixture()

        let single = try await encodeOne(
            fixture,
            DomainEvent(
                selfID: fixture.bot.id,
                payload: .groupMuted(
                    .init(
                        groupID: fixture.group.id, userID: fixture.alice.id,
                        operatorID: fixture.bot.id, muted: true, duration: 600
                    )
                )
            )
        )
        #expect(single["event_type"]?.stringValue == "group_mute")
        #expect(single["data"]?["duration"]?.intValue == 600)
        #expect(single["data"]?["user_id"]?.stringValue == fixture.alice.id)
        #expect(single["data"]?["is_mute"] == nil)

        // The same payload with no user targets the whole group, which is a different
        // event type with a boolean instead of a duration.
        let whole = try await encodeOne(
            fixture,
            DomainEvent(
                selfID: fixture.bot.id,
                payload: .groupMuted(
                    .init(
                        groupID: fixture.group.id, userID: nil,
                        operatorID: fixture.bot.id, muted: true
                    )
                )
            )
        )
        #expect(whole["event_type"]?.stringValue == "group_whole_mute")
        #expect(whole["data"]?["duration"] == nil)
        #expect(whole["data"]?["user_id"] == nil)

        // `setWholeMute` publishes duration -1 to mean "muted indefinitely", but
        #expect(whole["data"]?["is_mute"]?.boolValue == true)

        // A zero duration genuinely lifts it, and that direction is correct.
        let lifted = try await encodeOne(
            fixture,
            DomainEvent(
                selfID: fixture.bot.id,
                payload: .groupMuted(
                    .init(groupID: fixture.group.id, userID: nil, operatorID: fixture.bot.id, muted: false)
                )
            )
        )
        #expect(lifted["data"]?["is_mute"]?.boolValue == false)
    }

    // MARK: - Events Milky cannot express

    @Test("Friend additions and removals have no Milky events and produce no frames")
    func friendChangesProduceNoFrames() async throws {
        let fixture = try await makeFixture()

        #expect(
            await fixture.adapter.encode(
                event: DomainEvent(selfID: fixture.bot.id, payload: .friendAdded(userID: fixture.alice.id))
            ).isEmpty
        )
        #expect(
            await fixture.adapter.encode(
                event: DomainEvent(selfID: fixture.bot.id, payload: .friendRemoved(userID: fixture.alice.id))
            ).isEmpty
        )
    }

    @Test("Events for other bots are not forwarded")
    func eventsForAnotherBotAreNotForwarded() async throws {
        let fixture = try await makeFixture()
        var foreign = message(fixture)
        foreign.selfID = "19999"
        #expect(
            await fixture.adapter.encode(
                event: DomainEvent(selfID: "19999", payload: .message(foreign))
            ).isEmpty
        )
    }

    // MARK: - No heartbeat, no handshake

    @Test("Milky emits neither heartbeat nor handshake frames")
    func noHeartbeatNoHandshake() async throws {
        let fixture = try await makeFixture()
        // A real difference from OneBot, which sends a lifecycle frame and a 15s
        // heartbeat. Inventing either here would be inventing protocol.
        #expect(fixture.adapter.heartbeatInterval == nil)
        #expect(await fixture.adapter.handshakeFrames().isEmpty)
        #expect(await fixture.adapter.heartbeatFrame() == nil)
    }

    // MARK: - Failures

    @Test("Failures use negative retcodes: -400 for invalid parameters and -404 otherwise")
    func failureRetcodesAreNegative() async throws {
        let fixture = try await makeFixture()

        let badParam = await fixture.adapter.handle(
            call: ProtocolCall(name: "send_group_message", parameters: .object([:]))
        )
        #expect(badParam.retcode == -400)
        #expect(!badParam.isSuccess)

        // The catch-all covers everything the protocol does not name separately.
        let missing = await fixture.adapter.handle(
            call: ProtocolCall(name: "get_group_info", parameters: ["group_id": "500999999"])
        )
        #expect(missing.retcode == -404)
    }

    @Test("Success responses include data and omit message")
    func successCarriesDataWithoutMessage() async throws {
        let fixture = try await makeFixture()
        let reply = await fixture.adapter.handle(
            call: ProtocolCall(
                name: "send_group_message",
                parameters: [
                    "group_id": .string(fixture.group.id),
                    "message": [["type": "text", "data": ["text": "From bot"]]],
                ]
            )
        )
        #expect(reply.retcode == 0)
        #expect(reply.data["message_seq"]?.int64Value == 1)
        #expect(isIntegerNumber(reply.data["time"]))

        let envelope = fixture.adapter.envelope(for: reply)
        #expect(envelope["status"]?.stringValue == "ok")
        #expect(envelope["retcode"]?.intValue == 0)
        #expect(envelope["data"] != nil)
        #expect(envelope["message"] == nil)

        let failedEnvelope = fixture.adapter.envelope(
            for: ProtocolReply(retcode: -400, message: "Invalid parameters")
        )
        #expect(failedEnvelope["status"]?.stringValue == "failed")
        #expect(failedEnvelope["message"]?.stringValue == "Invalid parameters")
        #expect(failedEnvelope["data"] == nil)
    }

    @Test("Unknown APIs return both retcode -404 and HTTP 404")
    func unknownAPIAlsoSetsHTTPStatus() async throws {
        let fixture = try await makeFixture()
        let reply = await fixture.adapter.handle(
            call: ProtocolCall(name: "definitely_not_an_api", parameters: .object([:]))
        )
        // A missing route is an HTTP-level fact in Milky, not just a retcode.
        #expect(reply.retcode == -404)
        #expect(reply.httpStatus == 404)
        // A known API that merely fails still answers 200.
        #expect(
            await fixture.adapter.handle(
                call: ProtocolCall(name: "send_group_message", parameters: .object([:]))
            ).httpStatus == 200
        )
    }

    @Test("Persisted forwarded messages round-trip from event IDs through the API")
    func persistedForwardedMessagesRoundTrip() async throws {
        let fixture = try await makeFixture()

        var alice = fixture.alice
        alice.avatar = "https://cdn.example.com/alice.png"
        try await fixture.store.save(alice)

        let sourceMessage = Message(
            id: "forward-source-message",
            seq: 41,
            scene: .group,
            peerID: fixture.group.id,
            senderID: fixture.alice.id,
            selfID: fixture.bot.id,
            content: [.text("Archived hello")],
            time: Date(timeIntervalSince1970: 1_700_000_100),
            direction: .outgoing
        )
        try await fixture.store.save(sourceMessage)

        let nestedID = "nested-forward"
        let nestedNodes = [
            MessageSegment.ForwardNode(
                id: "inline-nested-node",
                senderID: fixture.alice.id,
                senderName: "Alice nested",
                time: Date(timeIntervalSince1970: 1_700_000_300),
                content: [.text("Nested hello")]
            ),
        ]
        let forwardID = "persisted-forward"
        let nodes = [
            MessageSegment.ForwardNode(
                id: sourceMessage.id,
                senderID: fixture.alice.id,
                senderName: "Alice archived",
                time: sourceMessage.time,
                content: sourceMessage.content
            ),
            MessageSegment.ForwardNode(
                id: "inline-parent-node",
                senderID: fixture.bot.id,
                senderName: "Bot archive",
                time: Date(timeIntervalSince1970: 1_700_000_200),
                content: [.forward(id: nestedID, nodes: nestedNodes)]
            ),
        ]
        let persisted = message(
            fixture,
            content: [.text("Bundle: "), .forward(id: forwardID, nodes: nodes)]
        )
        try await fixture.store.save(persisted)

        let event = try await encodeOne(
            fixture,
            DomainEvent(selfID: fixture.bot.id, payload: .message(persisted))
        )
        let eventForward = try #require(
            event["data"]?["segments"]?.arrayValue?.first {
                $0["type"]?.stringValue == "forward"
            }
        )
        let emittedForwardID = try #require(eventForward["data"]?["forward_id"]?.stringValue)
        #expect(emittedForwardID == forwardID)

        // Recreate the implementation after persistence. Forward data is resolved
        // from the store, not from process-local state populated while encoding.
        let restartedAdapter = MilkyProtocolImplementation(
            selfID: fixture.bot.id,
            platform: fixture.platform,
            assetResolver: StubMilkyAssetResolver()
        )
        let reply = await restartedAdapter.handle(
            call: ProtocolCall(
                name: "get_forwarded_messages",
                parameters: ["forward_id": .string(emittedForwardID)]
            )
        )
        #expect(reply.retcode == 0)
        let messages = try #require(reply.data["messages"]?.arrayValue)
        #expect(messages.count == 2)

        let storedNode = try #require(messages.first)
        #expect(storedNode["message_seq"]?.int64Value == sourceMessage.seq)
        #expect(storedNode["sender_name"]?.stringValue == "Alice archived")
        #expect(storedNode["avatar_url"]?.stringValue == alice.avatar)
        #expect(storedNode["time"]?.int64Value == 1_700_000_100)
        #expect(isIntegerNumber(storedNode["time"]))
        #expect(storedNode["segments"]?[0]?["type"]?.stringValue == "text")
        #expect(storedNode["segments"]?[0]?["data"]?["text"]?.stringValue == "Archived hello")

        let inlineNode = try #require(messages.last)
        // Inline nodes have no source-conversation sequence; Milky's documented
        // unknown integer value is zero rather than an invented list position.
        #expect(inlineNode["message_seq"]?.int64Value == 0)
        #expect(inlineNode["sender_name"]?.stringValue == "Bot archive")
        #expect(inlineNode["avatar_url"]?.stringValue == "")
        #expect(inlineNode["time"]?.int64Value == 1_700_000_200)
        let nestedSegment = try #require(inlineNode["segments"]?[0])
        #expect(nestedSegment["type"]?.stringValue == "forward")
        #expect(nestedSegment["data"]?["forward_id"]?.stringValue == nestedID)

        let nestedReply = await restartedAdapter.handle(
            call: ProtocolCall(
                name: "get_forwarded_messages",
                parameters: ["forward_id": .string(nestedID)]
            )
        )
        #expect(nestedReply.retcode == 0)
        let nestedMessages = try #require(nestedReply.data["messages"]?.arrayValue)
        #expect(nestedMessages.count == 1)
        #expect(nestedMessages[0]["message_seq"]?.int64Value == 0)
        #expect(nestedMessages[0]["sender_name"]?.stringValue == "Alice nested")
        #expect(nestedMessages[0]["segments"]?[0]?["data"]?["text"]?.stringValue == "Nested hello")

        let missingID = await restartedAdapter.handle(
            call: ProtocolCall(name: "get_forwarded_messages", parameters: .object([:]))
        )
        #expect(missingID.retcode == -400)

        let unknownID = await restartedAdapter.handle(
            call: ProtocolCall(
                name: "get_forwarded_messages",
                parameters: ["forward_id": "not-persisted"]
            )
        )
        #expect(unknownID.retcode == -404)
    }

    // MARK: - Notification sequence

    @Test("Inviting the bot to a group does not masquerade as an invited_join_request notification")
    func botInvitationIsExcludedFromGroupNotifications() async throws {
        let fixture = try await makeFixture()
        let join = PendingRequest(
            flag: "join",
            kind: .groupJoin,
            requesterID: fixture.alice.id,
            groupID: fixture.group.id,
            selfID: fixture.bot.id
        )
        let invitation = PendingRequest(
            flag: "invitation",
            kind: .groupInvite,
            requesterID: fixture.alice.id,
            groupID: fixture.group.id,
            selfID: fixture.bot.id
        )
        try await fixture.store.save(join)
        try await fixture.store.save(invitation)

        let reply = await fixture.adapter.handle(
            call: ProtocolCall(name: "get_group_notifications", parameters: .object([:]))
        )
        let notifications = try #require(reply.data["notifications"]?.arrayValue)
        #expect(notifications.count == 1)
        #expect(notifications.first?["type"]?.stringValue == "join_request")
        #expect(notifications.first?["target_user_id"] == nil)

        let filtered = await fixture.adapter.handle(
            call: ProtocolCall(
                name: "get_group_notifications",
                parameters: ["is_filtered": true]
            )
        )
        #expect(filtered.data["notifications"]?.arrayValue?.isEmpty == true)

        let invitationSeq = MilkyEventEncoder.notificationSeq(for: invitation)
        let wrongRequestEndpoint = await fixture.adapter.handle(
            call: ProtocolCall(
                name: "accept_group_request",
                parameters: [
                    "notification_seq": .number(Double(invitationSeq)),
                    "notification_type": "join_request",
                    "group_id": .string(fixture.group.id),
                    "is_filtered": false,
                ]
            )
        )
        #expect(wrongRequestEndpoint.retcode == -404)

        let joinSeq = MilkyEventEncoder.notificationSeq(for: join)
        let wrongInvitationEndpoint = await fixture.adapter.handle(
            call: ProtocolCall(
                name: "accept_group_invitation",
                parameters: [
                    "invitation_seq": .number(Double(joinSeq)),
                    "group_id": .string(fixture.group.id),
                ]
            )
        )
        #expect(wrongInvitationEndpoint.retcode == -404)
        #expect(try await fixture.store.request(flag: join.flag)?.resolution == nil)
        #expect(try await fixture.store.request(flag: invitation.flag)?.resolution == nil)
    }

    @Test("notification_seq is stable per flag, differs across flags, and stays JS-safe")
    func notificationSeqIsStableAndBounded() async throws {
        let request = PendingRequest(kind: .groupJoin, requesterID: "10002", groupID: "500000001", selfID: "10001")
        let other = PendingRequest(kind: .groupJoin, requesterID: "10002", groupID: "500000001", selfID: "10001")

        let first = MilkyEventEncoder.notificationSeq(for: request)
        #expect(first == MilkyEventEncoder.notificationSeq(for: request))
        #expect(first != MilkyEventEncoder.notificationSeq(for: other))
        // Milky specifies notification_seq inside the JS-safe integer range.
        #expect(first > 0)
        #expect(first < 9_007_199_254_740_992)
    }
}
