import Foundation
import MatchaCore
import MatchaOneBot
import MatchaProtocol
import Testing

/// Media never touches the filesystem here: the resolver answers with predictable
/// identifiers so a segment assertion is about wire shape only.
private struct StubAssetResolver: AssetResolver {
    func reference(for asset: Asset, version: OneBotVersion) async -> AssetReference {
        AssetReference(identifier: "id-\(asset.id)", url: "http://127.0.0.1/assets/\(asset.id)")
    }

    func asset(forIdentifier identifier: String, kind: AssetKind) async -> Asset? {
        Asset(id: identifier, name: "\(identifier).\(kind.rawValue)", source: .inline)
    }

    func asset(forReference reference: String, url: String?, kind: AssetKind) async -> Asset? {
        Asset(
            id: "sha-\(kind.rawValue)",
            name: reference,
            source: url.map { Asset.Source.remote(url: $0) } ?? .local(path: reference)
        )
    }
}

/// `.number` versus `.string` is the whole point of several tests below, so the
/// JSON *case* is matched rather than the coerced value.
private func isNumber(_ value: JSONValue?) -> Bool {
    if case .some(.number) = value { return true }
    return false
}

private func isString(_ value: JSONValue?) -> Bool {
    if case .some(.string) = value { return true }
    return false
}

/// The `type` field of every segment in a wire segment array.
private func segmentTypes(_ segments: [JSONValue]) -> [String] {
    segments.compactMap { $0["type"]?.stringValue }
}

@Suite("OneBot Wire Format")
struct OneBotWireTests {
    /// A bot, a peer, and a group both belong to. The bot is an admin so it can
    /// exercise the moderation actions.
    private func makeFixture(_ version: OneBotVersion) async throws -> (
        store: MatchaStore,
        platform: PlatformService,
        adapter: OneBotProtocolImplementation,
        bot: User,
        alice: User,
        group: Group
    ) {
        let store = try MatchaStore()
        let bot = User(id: "10001", name: "Bot")
        let alice = User(id: "10002", name: "Alice", nickname: "Ally")
        let group = Group(id: "500000001", name: "Test Group")
        try await store.save(bot)
        try await store.save(alice)
        try await store.save(group)
        try await store.save(GroupMember(groupID: group.id, userID: bot.id, role: .admin))
        try await store.save(
            GroupMember(groupID: group.id, userID: alice.id, card: "Alice G.", title: "Veteran")
        )

        let platform = PlatformService(store: store)
        await platform.registerBot(id: bot.id)
        let adapter = OneBotProtocolImplementation(
            version: version,
            selfID: bot.id,
            platform: platform,
            assetResolver: StubAssetResolver()
        )
        return (store, platform, adapter, bot, alice, group)
    }

    private func groupMessageEvent(
        _ fixture: (
            store: MatchaStore, platform: PlatformService, adapter: OneBotProtocolImplementation,
            bot: User, alice: User, group: Group
        ),
        content: [MessageSegment] = [.text("Hello")]
    ) -> DomainEvent {
        DomainEvent(
            selfID: fixture.bot.id,
            payload: .message(
                Message(
                    id: "70000000001",
                    seq: 7,
                    scene: .group,
                    peerID: fixture.group.id,
                    senderID: fixture.alice.id,
                    selfID: fixture.bot.id,
                    content: content,
                    direction: .outgoing
                )
            )
        )
    }

    private func encodeOne(
        _ adapter: OneBotProtocolImplementation,
        _ event: DomainEvent
    ) async throws -> JSONValue {
        let frames = await adapter.encode(event: event)
        #expect(frames.count == 1)
        return try #require(frames.first?.payload)
    }

    private func coder(_ version: OneBotVersion) -> OneBotSegmentCoder {
        OneBotSegmentCoder(version: version, assetResolver: StubAssetResolver())
    }

    // MARK: - ID representation

    @Test("v11 encodes IDs as JSON numbers")
    func v11SendsNumericIDs() async throws {
        let fixture = try await makeFixture(.v11)
        let payload = try await encodeOne(fixture.adapter, groupMessageEvent(fixture))

        #expect(isNumber(payload["self_id"]))
        #expect(isNumber(payload["user_id"]))
        #expect(isNumber(payload["group_id"]))
        #expect(isNumber(payload["message_id"]))
        // The numeric form must still round-trip to the original digits.
        #expect(payload["self_id"]?.stringValue == fixture.bot.id)
        #expect(payload["group_id"]?.stringValue == fixture.group.id)
        #expect(payload["message_id"]?.stringValue == "70000000001")
    }

    @Test("v12 encodes IDs as JSON strings")
    func v12SendsStringIDs() async throws {
        let fixture = try await makeFixture(.v12)
        let payload = try await encodeOne(fixture.adapter, groupMessageEvent(fixture))

        #expect(isString(payload["self"]?["user_id"]))
        #expect(isString(payload["user_id"]))
        #expect(isString(payload["group_id"]))
        #expect(isString(payload["message_id"]))
        #expect(payload["user_id"]?.stringValue == fixture.alice.id)
    }

    // MARK: - Envelope shape

    @Test("v11 group message envelopes use post_type and a nested sender")
    func v11GroupEnvelope() async throws {
        let fixture = try await makeFixture(.v11)
        let payload = try await encodeOne(fixture.adapter, groupMessageEvent(fixture))

        #expect(payload["post_type"]?.stringValue == "message")
        #expect(payload["message_type"]?.stringValue == "group")
        #expect(payload["raw_message"]?.stringValue == "Hello")
        #expect(payload["font"]?.intValue == 0)
        // v11 has no `type`/`detail_type`; those are v12's spelling.
        #expect(payload["type"] == nil)
        #expect(payload["detail_type"] == nil)

        let sender = try #require(payload["sender"])
        #expect(sender["nickname"]?.stringValue == "Ally")
        #expect(sender["card"]?.stringValue == "Alice G.")
        #expect(sender["role"]?.stringValue == "member")
        #expect(sender["title"]?.stringValue == "Veteran")
    }

    @Test("v11 private message senders omit group-member fields")
    func v11PrivateSenderOmitsMembershipFields() async throws {
        let fixture = try await makeFixture(.v11)
        let event = DomainEvent(
            selfID: fixture.bot.id,
            payload: .message(
                Message(
                    scene: .friend,
                    peerID: fixture.alice.id,
                    senderID: fixture.alice.id,
                    selfID: fixture.bot.id,
                    content: [.text("Private message")],
                    direction: .outgoing
                )
            )
        )
        let payload = try await encodeOne(fixture.adapter, event)

        #expect(payload["message_type"]?.stringValue == "private")
        #expect(payload["group_id"] == nil)

        let sender = try #require(payload["sender"])
        #expect(sender["nickname"]?.stringValue == "Ally")
        // card/role/title are group facts; a private sender has none.
        #expect(sender["card"] == nil)
        #expect(sender["role"] == nil)
        #expect(sender["title"] == nil)
    }

    @Test("v12 envelopes use the type/detail_type/sub_type tuple and a self object")
    func v12Envelope() async throws {
        let fixture = try await makeFixture(.v12)
        let payload = try await encodeOne(fixture.adapter, groupMessageEvent(fixture))

        #expect(payload["type"]?.stringValue == "message")
        #expect(payload["detail_type"]?.stringValue == "group")
        #expect(payload["sub_type"]?.stringValue == "")
        #expect(payload["alt_message"]?.stringValue == "Hello")
        // Every v12 event carries its own top-level id.
        #expect(payload["id"]?.stringValue?.isEmpty == false)

        let selfObject = try #require(payload["self"])
        #expect(selfObject["platform"]?.stringValue == "matcha")
        #expect(selfObject["user_id"]?.stringValue == fixture.bot.id)

        // v12 keeps sender fields flat rather than nesting them.
        #expect(payload["sender"] == nil)
        #expect(payload["post_type"] == nil)
        #expect(payload["raw_message"] == nil)
    }

    // MARK: - sub_type divergence

    @Test("v11 degrades temporary chats to the other subtype")
    func v11TempSceneBecomesOther() async throws {
        let fixture = try await makeFixture(.v11)
        var expected: [ChatScene: String] = [.group: "normal", .friend: "friend", .temp: "other"]

        for scene in ChatScene.allCases {
            let event = DomainEvent(
                selfID: fixture.bot.id,
                payload: .message(
                    Message(
                        scene: scene,
                        peerID: scene == .group ? fixture.group.id : fixture.alice.id,
                        senderID: fixture.alice.id,
                        selfID: fixture.bot.id,
                        content: [.text("x")],
                        direction: .outgoing
                    )
                )
            )
            let payload = try await encodeOne(fixture.adapter, event)
            // v11 predates the temp sub-type, so `.temp` has to land somewhere; the
            // standard's catch-all is `other`.
            #expect(payload["sub_type"]?.stringValue == expected.removeValue(forKey: scene))
        }
        #expect(expected.isEmpty)
    }

    @Test("v11 member decrease distinguishes kick_me, kick, and leave")
    func v11MemberDecreaseSubTypes() async throws {
        let fixture = try await makeFixture(.v11)

        // The bot itself being removed is its own state in v11: a framework must be
        // able to tell "I was kicked" from "somebody else was".
        let kickedMe = DomainEvent(
            selfID: fixture.bot.id,
            payload: .groupMemberRemoved(
                .init(
                    groupID: fixture.group.id, userID: fixture.bot.id,
                    operatorID: fixture.alice.id, reason: .administrative
                )
            )
        )
        #expect(try await encodeOne(fixture.adapter, kickedMe)["sub_type"]?.stringValue == "kick_me")

        let kickedOther = DomainEvent(
            selfID: fixture.bot.id,
            payload: .groupMemberRemoved(
                .init(
                    groupID: fixture.group.id, userID: fixture.alice.id,
                    operatorID: fixture.bot.id, reason: .administrative
                )
            )
        )
        #expect(try await encodeOne(fixture.adapter, kickedOther)["sub_type"]?.stringValue == "kick")

        let left = DomainEvent(
            selfID: fixture.bot.id,
            payload: .groupMemberRemoved(
                .init(
                    groupID: fixture.group.id, userID: fixture.alice.id,
                    operatorID: fixture.alice.id, reason: .voluntary
                )
            )
        )
        #expect(try await encodeOne(fixture.adapter, left)["sub_type"]?.stringValue == "leave")
        #expect(
            try await encodeOne(fixture.adapter, left)["notice_type"]?.stringValue == "group_decrease"
        )
    }

    @Test("v12 member decrease supports only leave and kick")
    func v12MemberDecreaseSubTypes() async throws {
        let fixture = try await makeFixture(.v12)

        // No kick_me: v12 leaves "was that me?" to the framework comparing user_id
        // against its own self.user_id.
        let kickedMe = DomainEvent(
            selfID: fixture.bot.id,
            payload: .groupMemberRemoved(
                .init(
                    groupID: fixture.group.id, userID: fixture.bot.id,
                    operatorID: fixture.alice.id, reason: .administrative
                )
            )
        )
        let mePayload = try await encodeOne(fixture.adapter, kickedMe)
        #expect(mePayload["sub_type"]?.stringValue == "kick")
        #expect(mePayload["detail_type"]?.stringValue == "group_member_decrease")

        let left = DomainEvent(
            selfID: fixture.bot.id,
            payload: .groupMemberRemoved(
                .init(
                    groupID: fixture.group.id, userID: fixture.alice.id,
                    operatorID: fixture.alice.id, reason: .voluntary
                )
            )
        )
        #expect(try await encodeOne(fixture.adapter, left)["sub_type"]?.stringValue == "leave")
    }

    // MARK: - Mutes

    @Test("v11 represents whole-group mute with user_id 0 and the ban subtype")
    func v11WholeMuteTargetsUserZero() async throws {
        let fixture = try await makeFixture(.v11)
        let muted = DomainEvent(
            selfID: fixture.bot.id,
            // -1 is what `setWholeMute` publishes for "muted indefinitely".
            payload: .groupMuted(
                .init(groupID: fixture.group.id, userID: nil, operatorID: fixture.bot.id, muted: true)
            )
        )
        let payload = try await encodeOne(fixture.adapter, muted)

        #expect(payload["notice_type"]?.stringValue == "group_ban")
        // A whole-group mute has no individual target, so v11 reports user 0.
        #expect(payload["user_id"]?.intValue == 0)
        // Negative durations are clamped so the wire value stays sane.
        #expect(payload["duration"]?.intValue == 0)

        #expect(payload["sub_type"]?.stringValue == "ban")
    }

    @Test("v12 emits no mute notifications")
    func v12HasNoMuteNotice() async throws {
        let fixture = try await makeFixture(.v12)
        let muted = DomainEvent(
            selfID: fixture.bot.id,
            payload: .groupMuted(
                .init(
                    groupID: fixture.group.id, userID: fixture.alice.id,
                    operatorID: fixture.bot.id, muted: true, duration: 600
                )
            )
        )
        // v12 standardises no ban notice, and inventing one would be inventing protocol.
        #expect(await fixture.adapter.encode(event: muted).isEmpty)
    }

    // MARK: - Segments

    @Test("@everyone is at:all in v11 and mention_all in v12")
    func mentionEveryoneDiverges() async throws {
        let v11 = await coder(.v11).encode([.mention(userID: nil)])
        #expect(segmentTypes(v11) == ["at"])
        #expect(v11[0]["data"]?["qq"]?.stringValue == "all")

        let v12 = await coder(.v12).encode([.mention(userID: nil)])
        #expect(segmentTypes(v12) == ["mention_all"])
        #expect(v12[0]["data"]?["qq"] == nil)
    }

    @Test("mentioning a user is at/qq in v11 and mention/user_id in v12")
    func mentionUserDiverges() async throws {
        let v11 = await coder(.v11).encode([.mention(userID: "123")])
        #expect(segmentTypes(v11) == ["at"])
        #expect(v11[0]["data"]?["qq"]?.stringValue == "123")

        let v12 = await coder(.v12).encode([.mention(userID: "123")])
        #expect(segmentTypes(v12) == ["mention"])
        #expect(v12[0]["data"]?["user_id"]?.stringValue == "123")
    }

    @Test("voice messages use record in v11 and voice in v12")
    func recordBecomesVoiceInV12() async throws {
        let asset = Asset(id: "sha-voice", name: "hi.silk", source: .inline)

        let v11 = await coder(.v11).encode([.record(asset, duration: 3)])
        #expect(segmentTypes(v11) == ["record"])
        #expect(v11[0]["data"]?["file"]?.stringValue == "id-sha-voice")

        let v12 = await coder(.v12).encode([.record(asset, duration: 3)])
        #expect(segmentTypes(v12) == ["voice"])
        // v12 addresses media by an upload ID, never by path or URL.
        #expect(v12[0]["data"]?["file_id"]?.stringValue == "id-sha-voice")
        #expect(v12[0]["data"]?["file"] == nil)
    }

    @Test("reply references use id in v11 and message_id in v12")
    func replyKeyDiverges() async throws {
        let v11 = await coder(.v11).encode([.reply(messageID: "700001")])
        #expect(v11[0]["data"]?["id"]?.stringValue == "700001")
        #expect(v11[0]["data"]?["message_id"] == nil)

        let v12 = await coder(.v12).encode([.reply(messageID: "700001")])
        #expect(v12[0]["data"]?["message_id"]?.stringValue == "700001")
        #expect(v12[0]["data"]?["id"] == nil)
    }

    @Test("v12 drops face segments")
    func v12DropsFaceSegments() async throws {
        let content: [MessageSegment] = [.text("a"), .face(id: "12", name: "Pout"), .text("b")]

        let v11 = await coder(.v11).encode(content)
        #expect(segmentTypes(v11) == ["text", "face", "text"])

        // v12 standardises no face segment, so the count itself drops.
        let v12 = await coder(.v12).encode(content)
        #expect(v12.count == 2)
        #expect(segmentTypes(v12) == ["text", "text"])
    }

    @Test("v11 segment arrays decode back to domain message segments")
    func v11SegmentsRoundTrip() async throws {
        let coder = coder(.v11)
        let original: [MessageSegment] = [
            .reply(messageID: "700001"),
            .mention(userID: "10002"),
            .mention(userID: nil),
            .text("Look here"),
            .face(id: "12", name: nil),
        ]

        let decoded = await coder.decode(await coder.encode(original))
        #expect(decoded == original)
        #expect(decoded.plainText == "Look here")
        #expect(decoded.replyTarget == "700001")
        #expect(decoded.mentions == ["10002", nil])
    }

    // MARK: - Actions

    @Test("send_group_msg persists the message and returns message_id")
    func sendGroupMessageStoresAndReturnsID() async throws {
        let fixture = try await makeFixture(.v11)
        let reply = await fixture.adapter.handle(
            call: ProtocolCall(
                name: "send_group_msg",
                parameters: [
                    "group_id": .string(fixture.group.id),
                    "message": [["type": "text", "data": ["text": "From bot"]]],
                ]
            )
        )

        #expect(reply.retcode == 0)
        let messageID = try #require(reply.data["message_id"]?.stringValue)
        // v11 declares message_id as an integer.
        #expect(isNumber(reply.data["message_id"]))

        let stored = try #require(try await fixture.store.message(id: messageID))
        #expect(stored.content.plainText == "From bot")
        #expect(stored.peerID == fixture.group.id)
        #expect(stored.senderID == fixture.bot.id)
        // A message the bot sent is incoming from the operator's point of view.
        #expect(stored.direction == .incoming)
    }

    @Test("get_supported_actions includes send_msg")
    func supportedActionsIsItsOwnManifest() async throws {
        let fixture = try await makeFixture(.v12)
        let reply = await fixture.adapter.handle(
            call: ProtocolCall(name: "get_supported_actions", parameters: .object([:]))
        )

        let actions = try #require(reply.data.arrayValue).compactMap(\.stringValue)
        #expect(!actions.isEmpty)
        #expect(actions.contains("send_msg"))
        #expect(actions.contains("get_supported_actions"))
    }

    @Test("unknown actions return 1404 in v11 and 10002 in v12")
    func unknownActionRetcodes() async throws {
        let v11 = try await makeFixture(.v11)
        let v11Reply = await v11.adapter.handle(
            call: ProtocolCall(name: "definitely_not_an_action", parameters: .object([:]))
        )
        #expect(v11Reply.retcode == 1404)
        #expect(!v11Reply.isSuccess)

        let v12 = try await makeFixture(.v12)
        let v12Reply = await v12.adapter.handle(
            call: ProtocolCall(name: "definitely_not_an_action", parameters: .object([:]))
        )
        #expect(v12Reply.retcode == 10002)
    }

    @Test("v11 strips the _async suffix and still executes the action")
    func asyncSuffixIsStripped() async throws {
        let fixture = try await makeFixture(.v11)
        let reply = await fixture.adapter.handle(
            call: ProtocolCall(
                name: "send_msg_async",
                parameters: [
                    "group_id": .string(fixture.group.id),
                    "message": [["type": "text", "data": ["text": "Async"]]],
                ]
            )
        )

        // Matcha answers everything promptly, so `_async` is a naming detail only.
        #expect(reply.retcode == 0)
        #expect(reply.data["message_id"] != nil)
    }

    // MARK: - Reply envelope

    @Test("response-envelope status is derived from retcode and echo is preserved")
    func envelopeStatusFollowsRetcode() async throws {
        let fixture = try await makeFixture(.v11)

        let ok = fixture.adapter.envelope(for: .success(["a": 1]), echo: .string("call-1"))
        #expect(ok["status"]?.stringValue == "ok")
        #expect(ok["retcode"]?.intValue == 0)
        #expect(ok["echo"]?.stringValue == "call-1")

        let failed = fixture.adapter.envelope(
            for: ProtocolReply(retcode: 1404, message: "No such action"),
            echo: nil
        )
        #expect(failed["status"]?.stringValue == "failed")
        #expect(failed["echo"] == nil)
    }

    @Test("v11 puts failure text in data while v12 uses top-level message")
    func failureTextPlacementDiverges() async throws {
        let v11 = try await makeFixture(.v11)
        let v11Envelope = v11.adapter.envelope(
            for: ProtocolReply(retcode: 1404, message: "No such action"),
            echo: nil
        )
        // v11 defines no top-level message field, so the text rides in `data`.
        #expect(v11Envelope["data"]?["message"]?.stringValue == "No such action")
        #expect(v11Envelope["message"] == nil)

        let v12 = try await makeFixture(.v12)
        let v12Envelope = v12.adapter.envelope(
            for: ProtocolReply(retcode: 10002, message: "No such action"),
            echo: nil
        )
        #expect(v12Envelope["message"]?.stringValue == "No such action")
        #expect(v12Envelope["data"]?.isNull == true)
    }

    // MARK: - Addressing

    @Test("events for other bots are not forwarded")
    func eventsForAnotherBotAreNotForwarded() async throws {
        let fixture = try await makeFixture(.v11)
        let foreign = DomainEvent(
            selfID: "19999",
            payload: .message(
                Message(
                    scene: .group,
                    peerID: fixture.group.id,
                    senderID: fixture.alice.id,
                    selfID: "19999",
                    content: [.text("Not for me")],
                    direction: .outgoing
                )
            )
        )
        #expect(await fixture.adapter.encode(event: foreign).isEmpty)
        // The same event addressed to this adapter does produce a frame.
        #expect(await fixture.adapter.encode(event: groupMessageEvent(fixture)).count == 1)
    }
}
