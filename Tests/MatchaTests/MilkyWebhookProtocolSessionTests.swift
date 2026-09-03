import Foundation
import MatchaCore
import MatchaMilky
import MatchaProtocol
import Testing

@testable import MatchaTransport

@Suite("Milky Protocol Service")
struct MilkyWebhookProtocolSessionTests {
    @Test("one service exposes API and fans the same event out to WebSocket and WebHooks")
    func servesAPIAndFansOutEvents() async throws {
        let firstReceiver = WebhookRequestRecorder(statuses: [204])
        let (firstServer, firstPort) = try await startHTTPServer { request in
            await firstReceiver.respond(to: request)
        }
        defer { firstServer.stop() }
        let secondReceiver = WebhookRequestRecorder(statuses: [204])
        let (secondServer, secondPort) = try await startHTTPServer { request in
            await secondReceiver.respond(to: request)
        }
        defer { secondServer.stop() }

        let fixture = try await makeFixture()
        let (session, apiPort) = try await startServiceSession(
            fixture: fixture,
            webhookURLs: [
                "http://127.0.0.1:\(firstPort)/milky/first",
                "http://127.0.0.1:\(secondPort)/milky/second",
            ],
            token: "secret"
        )
        let eventClient = WebSocketClient(
            configuration: .init(
                url: try #require(
                    URL(string: "ws://127.0.0.1:\(apiPort)/event?access_token=secret")
                ),
                reconnectInterval: nil
            )
        )

        do {
            #expect(await session.state == .ready(port: apiPort))
            #expect(await session.roundTripTime == .unsupported)

            let connected = Task {
                try await waitForWebSocketConnection(eventClient)
            }
            eventClient.start()
            let eventConnection = try await connected.value
            #expect(await session.state == .ready(port: apiPort))

            var request = URLRequest(
                url: try #require(
                    URL(string: "http://127.0.0.1:\(apiPort)/api/get_login_info")
                )
            )
            request.httpMethod = "POST"
            request.httpBody = Data("{}".utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")

            let (responseData, response) = try await URLSession.shared.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            let responsePayload = try JSONValue.decode(from: responseData)
            #expect(responsePayload["status"]?.stringValue == "ok")
            #expect(responsePayload["data"]?["uin"]?.stringValue == fixture.bot.id)

            let eventFrame = Task {
                try await waitForEventFrame(eventConnection)
            }
            try await publishPrivateMessage(fixture: fixture, text: "fan-out event")
            let firstDeliveries = try await waitForRequests(
                firstReceiver,
                count: 1,
                description: "the first Milky WebHook delivery"
            )
            let secondDeliveries = try await waitForRequests(
                secondReceiver,
                count: 1,
                description: "the second Milky WebHook delivery"
            )
            let firstRequest = try #require(firstDeliveries.first)
            let secondRequest = try #require(secondDeliveries.first)
            #expect(firstRequest.method == "POST")
            #expect(firstRequest.path == "/milky/first")
            #expect(firstRequest.headers["Content-Type"] == "application/json")
            #expect(firstRequest.headers.bearerToken == "secret")
            #expect(secondRequest.method == "POST")
            #expect(secondRequest.path == "/milky/second")
            #expect(secondRequest.headers.bearerToken == "secret")

            let receivedFrame = try await eventFrame.value
            let eventText = try #require(receivedFrame.textValue)
            let webSocketEvent = try JSONValue.decode(from: Data(eventText.utf8))
            let firstWebhookEvent = try JSONValue.decode(from: firstRequest.body)
            let secondWebhookEvent = try JSONValue.decode(from: secondRequest.body)
            #expect(firstWebhookEvent == webSocketEvent)
            #expect(secondWebhookEvent == webSocketEvent)
            #expect(webSocketEvent["self_id"]?.stringValue == fixture.bot.id)
            #expect(webSocketEvent["event_type"]?.stringValue == "message_receive")
            #expect(webSocketEvent["data"]?["message_scene"]?.stringValue == "friend")
            #expect(webSocketEvent["data"]?["peer_id"]?.stringValue == fixture.alice.id)
            #expect(webSocketEvent["data"]?["sender_id"]?.stringValue == fixture.alice.id)
            #expect(await session.state == .ready(port: apiPort))

            eventClient.stop()
            await session.stop()
            #expect(await session.state == .idle)
        } catch {
            eventClient.stop()
            await session.stop()
            throw error
        }
    }

    @Test("a failed WebHook delivery does not disable subsequent deliveries")
    func retriesAfterUnauthorizedResponse() async throws {
        let receiver = WebhookRequestRecorder(statuses: [401, 204])
        let (receiverServer, receiverPort) = try await startHTTPServer { request in
            await receiver.respond(to: request)
        }
        defer { receiverServer.stop() }

        let fixture = try await makeFixture()
        let (session, apiPort) = try await startServiceSession(
            fixture: fixture,
            webhookURLs: ["http://127.0.0.1:\(receiverPort)/milky/"],
            token: "secret"
        )

        do {
            try await publishPrivateMessage(fixture: fixture, text: "Rejected event")
            _ = try await waitForRequests(
                receiver,
                count: 1,
                description: "the rejected Milky WebHook delivery"
            )
            #expect(await session.state == .ready(port: apiPort))

            try await publishPrivateMessage(fixture: fixture, text: "Accepted event")
            let delivered = try await waitForRequests(
                receiver,
                count: 2,
                description: "the retried Milky WebHook delivery"
            )
            #expect(delivered.map(\.path) == ["/milky/", "/milky/"])
            let secondEvent = try JSONValue.decode(from: delivered[1].body)
            #expect(secondEvent["event_type"]?.stringValue == "message_receive")
            #expect(await session.state == .ready(port: apiPort))

            await session.stop()
        } catch {
            await session.stop()
            throw error
        }
    }

    @Test("an invalid WebHook URL fails before binding the API listener")
    func invalidURLLeavesNoListener() async throws {
        let fixture = try await makeFixture()
        var verifiedUnboundPort = false
        var lastBindError: (any Error)?

        for _ in 0..<20 where !verifiedUnboundPort {
            let port = UInt16.random(in: 30_000...60_000)
            let session = makeSession(
                fixture: fixture,
                apiPort: port,
                webhookURLs: ["not an absolute HTTP URL"],
                token: "secret"
            )

            do {
                try await session.start()
                Issue.record("Expected the invalid WebHook URL to reject startup")
                await session.stop()
                return
            } catch let error as TransportError {
                guard case .invalidURL(let value) = error else {
                    Issue.record("Expected invalidURL, got \(error)")
                    await session.stop()
                    return
                }
                #expect(value == "not an absolute HTTP URL")
                #expect(await session.state == .idle)
            }

            let probe = HTTPServer(port: port) { _ in .empty(status: 204) }
            do {
                try await probe.start()
                verifiedUnboundPort = true
                probe.stop()
            } catch {
                lastBindError = error
                probe.stop()
            }
        }

        if !verifiedUnboundPort {
            Issue.record(
                "Could not verify an unbound API port: \(lastBindError?.localizedDescription ?? "unknown error")"
            )
        }
    }

    @Test("an implementation without the Milky service capability is rejected before binding")
    func unsupportedImplementationLeavesNoListener() async throws {
        let store = try MatchaStore()
        let platform = PlatformService(store: store)
        var verifiedUnboundPort = false
        var lastBindError: (any Error)?

        for _ in 0..<20 where !verifiedUnboundPort {
            let port = UInt16.random(in: 30_000...60_000)
            let session = ProtocolSession(
                implementation: WebhookTestWebSocketOnlyImplementation(),
                platform: platform,
                settings: ConnectionSettings(
                    transport: .milkyService,
                    host: "127.0.0.1",
                    port: port,
                    milkyWebhookURLs: ["http://127.0.0.1:8080/milky/"]
                )
            )

            do {
                try await session.start()
                Issue.record("Expected the Milky service to be rejected by this implementation")
                await session.stop()
                return
            } catch let error as ProtocolSessionError {
                switch error {
                case .unsupportedTransport(let identifier, let transport):
                    #expect(identifier == WebhookTestWebSocketOnlyImplementation.identifier)
                    #expect(transport == .milkyService)
                }
                #expect(await session.state == .idle)
            }

            let probe = HTTPServer(port: port) { _ in .empty(status: 204) }
            do {
                try await probe.start()
                verifiedUnboundPort = true
                probe.stop()
            } catch {
                lastBindError = error
                probe.stop()
            }
        }

        if !verifiedUnboundPort {
            Issue.record(
                "Could not verify an unbound API port: \(lastBindError?.localizedDescription ?? "unknown error")"
            )
        }
    }

    @Test("legacy Milky modes migrate into one service with additive WebHooks")
    func connectionSettingsCompatibility() throws {
        let legacy = try JSONDecoder().decode(
            ConnectionSettings.self,
            from: Data(
                #"{"transport":"httpServer","host":"127.0.0.1","port":5700}"#.utf8
            )
        )
        #expect(legacy.transport == .milkyService)
        #expect(legacy.milkyWebhookURLs.isEmpty)
        let migratedPayload = try JSONValue.decode(from: JSONEncoder().encode(legacy))
        #expect(migratedPayload["transport"]?.stringValue == "milkyService")
        #expect(migratedPayload["milkyWebhookURLs"]?.arrayValue == [])

        let legacyWebSocket = try JSONDecoder().decode(
            ConnectionSettings.self,
            from: Data(#"{"transport":"milkyWebSocket","host":"127.0.0.1","port":5700}"#.utf8)
        )
        #expect(legacyWebSocket.transport == .milkyService)
        #expect(legacyWebSocket.milkyWebhookURLs.isEmpty)

        let legacyWebhook = try JSONDecoder().decode(
            ConnectionSettings.self,
            from: Data(
                #"{"transport":"milkyWebhook","host":"127.0.0.1","port":5700,"milkyWebhookURL":"https://legacy.example/milky/"}"#
                    .utf8
            )
        )
        #expect(legacyWebhook.transport == .milkyService)
        #expect(legacyWebhook.milkyWebhookURLs == ["https://legacy.example/milky/"])

        let service = ConnectionSettings(
            transport: .milkyService,
            host: "0.0.0.0",
            port: 6700,
            path: "/ignored",
            accessToken: "secret",
            milkyWebhookURLs: [
                "https://first.nonebot.example/milky/",
                "https://second.nonebot.example/milky/",
            ],
            autoReconnect: false,
            reconnectInterval: 7,
            postSelfEvents: true
        )
        let encoded = try JSONEncoder().encode(service)
        let roundTripped = try JSONDecoder().decode(ConnectionSettings.self, from: encoded)
        #expect(roundTripped == service)
        #expect(roundTripped.transport == .milkyService)
        #expect(
            roundTripped.milkyWebhookEndpoints?.map(\.absoluteString) == [
                "https://first.nonebot.example/milky/",
                "https://second.nonebot.example/milky/",
            ]
        )

        var invalidEndpoints = service
        invalidEndpoints.milkyWebhookURLs = ["https://valid.example/milky/", "http://:8080/milky/"]
        #expect(invalidEndpoints.milkyWebhookEndpoints == nil)
    }

    private func makeFixture() async throws -> WebhookFixture {
        let store = try MatchaStore()
        let bot = User(id: "10001", name: "Bot")
        let alice = User(id: "10002", name: "Alice")
        try await store.save(bot)
        try await store.save(alice)
        let platform = PlatformService(store: store)
        await platform.registerBot(id: bot.id)
        let implementation = MilkyProtocolImplementation(
            selfID: bot.id,
            platform: platform,
            assetResolver: WebhookTestAssetResolver()
        )
        return WebhookFixture(
            platform: platform,
            implementation: implementation,
            bot: bot,
            alice: alice
        )
    }

    private func publishPrivateMessage(fixture: WebhookFixture, text: String) async throws {
        try await fixture.platform.sendMessage(
            scene: .friend,
            peerID: fixture.alice.id,
            senderID: fixture.alice.id,
            selfID: fixture.bot.id,
            content: [.text(text)]
        )
    }

    private func makeSession(
        fixture: WebhookFixture,
        apiPort: UInt16,
        webhookURLs: [String],
        token: String
    ) -> ProtocolSession {
        ProtocolSession(
            implementation: fixture.implementation,
            platform: fixture.platform,
            settings: ConnectionSettings(
                transport: .milkyService,
                host: "127.0.0.1",
                port: apiPort,
                accessToken: token,
                milkyWebhookURLs: webhookURLs,
                autoReconnect: false
            )
        )
    }

    private func startServiceSession(
        fixture: WebhookFixture,
        webhookURLs: [String],
        token: String
    ) async throws -> (ProtocolSession, UInt16) {
        var lastError: (any Error)?
        for _ in 0..<20 {
            let port = UInt16.random(in: 30_000...60_000)
            let session = makeSession(
                fixture: fixture,
                apiPort: port,
                webhookURLs: webhookURLs,
                token: token
            )
            do {
                try await session.start()
                return (session, port)
            } catch {
                lastError = error
                await session.stop()
            }
        }
        throw lastError
            ?? TransportError.listenFailed(port: 0, underlying: "No available test port found")
    }

    private func startHTTPServer(
        handler: @escaping HTTPServer.Handler
    ) async throws -> (HTTPServer, UInt16) {
        var lastError: (any Error)?
        for _ in 0..<20 {
            let port = UInt16.random(in: 30_000...60_000)
            let server = HTTPServer(port: port, handler: handler)
            do {
                try await server.start()
                return (server, port)
            } catch {
                lastError = error
            }
        }
        throw lastError
            ?? TransportError.listenFailed(port: 0, underlying: "No available test port found")
    }

    private func waitForRequests(
        _ receiver: WebhookRequestRecorder,
        count: Int,
        description: String
    ) async throws -> [HTTPRequest] {
        for _ in 0..<300 {
            let requests = await receiver.requests
            if requests.count >= count { return requests }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TransportError.connectFailed("Timed out waiting for \(description)")
    }

    private func waitForWebSocketConnection(
        _ client: WebSocketClient
    ) async throws -> WebSocketConnection {
        try await withTimeout(waitingFor: "the Milky event consumer to connect") {
            for await update in client.updates {
                switch update {
                case .connected(let connection):
                    return connection
                case .failed(let error):
                    throw error
                case .reconnecting:
                    continue
                }
            }
            throw TransportError.cancelled
        }
    }

    private func waitForEventFrame(
        _ connection: WebSocketConnection
    ) async throws -> WebSocketFrame {
        try await withTimeout(waitingFor: "the Milky WebSocket event") {
            for await frame in connection.frames {
                return frame
            }
            throw TransportError.cancelled
        }
    }

    private func withTimeout<Value: Sendable>(
        waitingFor description: String,
        _ timeout: Duration = .seconds(3),
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TransportError.connectFailed("Timed out waiting for \(description)")
            }

            guard let value = try await group.next() else {
                throw TransportError.cancelled
            }
            group.cancelAll()
            return value
        }
    }
}

private struct WebhookFixture: Sendable {
    let platform: PlatformService
    let implementation: MilkyProtocolImplementation
    let bot: User
    let alice: User
}

private actor WebhookRequestRecorder {
    private(set) var requests: [HTTPRequest] = []
    private var statuses: [Int]

    init(statuses: [Int]) {
        self.statuses = statuses
    }

    func respond(to request: HTTPRequest) -> HTTPResponse {
        requests.append(request)
        let status = statuses.isEmpty ? 204 : statuses.removeFirst()
        return .empty(status: status)
    }
}

private struct WebhookTestAssetResolver: MilkyAssetResolving {
    func resource(for asset: Asset) async -> MilkyResource {
        MilkyResource(resourceID: asset.id, tempURL: "")
    }

    func ingest(uri: String, kind: MatchaMilky.AssetKind) async -> Asset? { nil }
    func displayName(for userID: String) async -> String { userID }
    func replyReference(messageID: String) async -> MilkyReplyReference? { nil }
    func messageID(forSeq seq: Int64) async -> String? { nil }
}

private final class WebhookTestWebSocketOnlyImplementation: ProtocolImplementation, @unchecked Sendable {
    static let identifier = "test.websocket-only"
    static let displayName = "WebSocket-only test implementation"
    static let supportedTransports: Set<TransportMode> = [.webSocketServer, .webSocketClient]

    let selfID = "10001"

    func handle(call: ProtocolCall) async -> ProtocolReply { .success() }
    func envelope(for reply: ProtocolReply, echo: JSONValue?) -> JSONValue { reply.data }
    func encode(event: DomainEvent) async -> [OutboundFrame] { [] }
}
