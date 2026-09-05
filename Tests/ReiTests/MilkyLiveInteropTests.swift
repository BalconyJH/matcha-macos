import Foundation
import ReiCore
import ReiMilky
import ReiProtocol
import Testing

/// Opt-in black-box coverage against a real nonebot-adapter-milky process.
///
/// The ordinary suite leaves the environment variables unset and returns without
/// opening a port. A local interoperability run supplies the receiver URL, Rei
/// API port, shared token, and simulated bot ID explicitly.
@Suite("Milky Live Interoperability")
struct MilkyLiveInteropTests {
    @Test(
        "a real NoneBot consumer receives an event and calls Rei API to echo it",
        .enabled(if: ProcessInfo.processInfo.environment["REI_LIVE_MILKY_WEBHOOK_URL"] != nil)
    )
    func realNoneBotEchoRoundTrip() async throws {
        let environment = ProcessInfo.processInfo.environment
        let keys = [
            "REI_LIVE_MILKY_WEBHOOK_URL",
            "REI_LIVE_MILKY_API_PORT",
            "REI_LIVE_MILKY_TOKEN",
            "REI_LIVE_MILKY_SELF_ID",
        ]
        guard keys.contains(where: { environment[$0] != nil }) else { return }

        let webhookURL = try #require(environment[keys[0]])
        let portText = try #require(environment[keys[1]])
        let token = try #require(environment[keys[2]])
        let selfID = try #require(environment[keys[3]])
        let port = try #require(UInt16(portText))

        let store = try ReiStore()
        let bot = User(id: selfID, name: "LiveBot")
        let sender = User(id: "10002", name: "LiveUser")
        try await store.save(bot)
        try await store.save(sender)
        try await store.save(
            Friendship(userID: bot.id, friendID: sender.id)
        )

        let platform = PlatformService(store: store)
        await platform.registerBot(id: bot.id)
        let implementation = MilkyProtocolImplementation(
            selfID: bot.id,
            platform: platform,
            assetResolver: LiveMilkyAssetResolver()
        )
        let session = ProtocolSession(
            implementation: implementation,
            platform: platform,
            settings: ConnectionSettings(
                transport: .milkyService,
                host: "127.0.0.1",
                port: port,
                accessToken: token,
                milkyWebhookURLs: [webhookURL],
                autoReconnect: false
            )
        )

        do {
            try await session.start()
            #expect(await session.state == .ready(port: port))

            try await platform.sendMessage(
                scene: .friend,
                peerID: sender.id,
                senderID: sender.id,
                selfID: bot.id,
                content: [.text("/echo live-milky-probe")]
            )

            let chat = Chat(scene: .friend, peerID: sender.id, selfID: bot.id)
            let response = try await waitForEcho(in: chat, store: store, senderID: bot.id)
            #expect(response.content.plainText == "live-milky-probe")
            #expect(await session.state == .ready(port: port))
            await session.stop()
        } catch {
            await session.stop()
            throw error
        }
    }

    @Test(
        "a real NoneBot WebSocket consumer discovers the bot and echoes through Rei API",
        .enabled(
            if: ProcessInfo.processInfo.environment["REI_LIVE_MILKY_EXPECT_WEBSOCKET"] == "1"
        )
    )
    func realNoneBotWebSocketRoundTrip() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["REI_LIVE_MILKY_EXPECT_WEBSOCKET"] == "1" else { return }
        let portText = try #require(environment["REI_LIVE_MILKY_API_PORT"])
        let token = try #require(environment["REI_LIVE_MILKY_TOKEN"])
        let selfID = try #require(environment["REI_LIVE_MILKY_SELF_ID"])
        let port = try #require(UInt16(portText))

        let store = try ReiStore()
        let bot = User(id: selfID, name: "LiveBot")
        let sender = User(id: "10002", name: "LiveUser")
        try await store.save(bot)
        try await store.save(sender)
        try await store.save(Friendship(userID: bot.id, friendID: sender.id))

        let platform = PlatformService(store: store)
        await platform.registerBot(id: bot.id)
        let implementation = MilkyProtocolImplementation(
            selfID: bot.id,
            platform: platform,
            assetResolver: LiveMilkyAssetResolver()
        )
        let session = ProtocolSession(
            implementation: implementation,
            platform: platform,
            settings: ConnectionSettings(
                transport: .milkyService,
                host: "127.0.0.1",
                port: port,
                accessToken: token,
                autoReconnect: false
            )
        )
        let traffic = await session.trafficLog()
        let login = Task {
            for await entry in traffic
            where
                entry.direction == .inboundCall && entry.summary == "get_login_info"
            {
                return
            }
            throw LiveInteropError.sessionEnded
        }

        do {
            try await session.start()
            #expect(await session.state == .ready(port: port))
            try await withTimeout(waitingFor: "NoneBot get_login_info") {
                try await login.value
            }

            try await platform.sendMessage(
                scene: .friend,
                peerID: sender.id,
                senderID: sender.id,
                selfID: bot.id,
                content: [.text("/echo live-milky-probe")]
            )

            let chat = Chat(scene: .friend, peerID: sender.id, selfID: bot.id)
            let response = try await waitForEcho(in: chat, store: store, senderID: bot.id)
            #expect(response.content.plainText == "live-milky-probe")
            #expect(await session.state == .ready(port: port))
            await session.stop()
        } catch {
            login.cancel()
            await session.stop()
            throw error
        }
    }

    private func waitForEcho(
        in chat: Chat,
        store: ReiStore,
        senderID: User.ID
    ) async throws -> Message {
        for _ in 0..<500 {
            if let response = try await store.messages(in: chat).last(where: {
                $0.senderID == senderID && $0.content.plainText == "live-milky-probe"
            }) {
                return response
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw LiveInteropError.echoTimedOut
    }

    private func withTimeout<Value: Sendable>(
        waitingFor description: String,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                try await Task.sleep(for: .seconds(6))
                throw LiveInteropError.timedOut(description)
            }
            guard let value = try await group.next() else {
                throw LiveInteropError.sessionEnded
            }
            group.cancelAll()
            return value
        }
    }
}

private enum LiveInteropError: Error {
    case echoTimedOut
    case sessionEnded
    case timedOut(String)
}

private struct LiveMilkyAssetResolver: MilkyAssetResolving {
    func resource(for asset: Asset) async -> MilkyResource {
        MilkyResource(resourceID: asset.id, tempURL: "")
    }

    func ingest(uri: String, kind: ReiMilky.AssetKind) async -> Asset? { nil }
    func displayName(for userID: String) async -> String { userID }
    func replyReference(messageID: String) async -> MilkyReplyReference? { nil }
    func messageID(forSeq seq: Int64) async -> String? { nil }
}
