import Foundation
import Testing

import MatchaCore
@testable import MatchaLogging
import MatchaMilky
import MatchaOneBot
import MatchaProtocol
@testable import MatchaTransport
@testable import MatchaUI

@Suite("WebSocket Transport")
struct WebSocketTransportTests {
    @Test("the client reaches ready and bidirectional ping measures RTT")
    func clientConnectsAndMeasuresRoundTripTime() async throws {
        let (server, port) = try await startServer()
        let client = WebSocketClient(
            configuration: .init(
                url: try #require(URL(string: "ws://127.0.0.1:\(port)/")),
                reconnectInterval: nil
            )
        )
        defer {
            client.stop()
            server.stop()
        }

        let accepted = Task {
            try await withTimeout(waitingFor: "the server to accept a connection") {
                for await connection in server.connections {
                    return connection
                }
                throw TransportError.cancelled
            }
        }
        let connected = Task {
            try await withTimeout(waitingFor: "the client to reach ready") {
                for await update in client.updates {
                    switch update {
                    case let .connected(connection):
                        return connection
                    case let .failed(error):
                        throw error
                    case .reconnecting:
                        continue
                    }
                }
                throw TransportError.cancelled
            }
        }

        client.start()
        let clientConnection = try await connected.value
        let serverConnection = try await accepted.value

        let clientRTT = try await clientConnection.measureRoundTripTime(timeout: .seconds(2))
        let serverRTT = try await serverConnection.measureRoundTripTime(timeout: .seconds(2))

        #expect(clientRTT > .zero)
        #expect(serverRTT > .zero)
    }

    @Test("a reverse-connection protocol session publishes real RTT samples")
    func protocolSessionPublishesRoundTripTime() async throws {
        let (server, port) = try await startServer()
        defer { server.stop() }

        let store = try MatchaStore()
        let platform = PlatformService(store: store)
        let session = ProtocolSession(
            implementation: ProbeAdapter(),
            platform: platform,
            settings: ConnectionSettings(
                transport: .webSocketClient,
                host: "127.0.0.1",
                port: port,
                autoReconnect: false
            )
        )
        let updates = await session.roundTripTimeUpdates()
        let measurement = Task {
            try await withTimeout(waitingFor: "the protocol session to publish RTT") {
                for await update in updates {
                    if case let .measured(duration) = update {
                        return duration
                    }
                }
                throw TransportError.cancelled
            }
        }

        do {
            try await session.start()
            let duration = try await measurement.value
            #expect(duration > .zero)
            await session.stop()
        } catch {
            await session.stop()
            throw error
        }
    }

    @Test(
        "changing the bot identity restarts an active session with the new login",
        arguments: OneBotVersion.allCases
    )
    @MainActor
    func changingBotIdentityRestartsActiveSessionWithNewSelfID(
        _ version: OneBotVersion
    ) async throws {
        let handshakes = HandshakeHistory()
        let (server, port) = try await startServer { _, headers in
            handshakes.record(headers)
            return .accept
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Matcha-BotIdentityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let store = try MatchaStore()
        let activeUser = User(
            id: "10001",
            name: "User",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let oldBot = User(
            id: "10002",
            name: "Old Bot",
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let newBot = User(
            id: "10003",
            name: "New Bot",
            createdAt: Date(timeIntervalSince1970: 3)
        )
        for user in [activeUser, oldBot, newBot] {
            try await store.save(user)
        }
        let group = Group(id: "50001", name: "Test Group")
        try await store.save(group)
        for user in [activeUser, oldBot, newBot] {
            try await store.save(GroupMember(groupID: group.id, userID: user.id))
        }
        let defaultsName = "dev.matcha.tests.bot-identity.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))

        let environment = AppEnvironment(
            store: store,
            assetStore: try AssetStore(
                directory: root.appendingPathComponent("Assets", isDirectory: true)
            ),
            appLog: AppLog(directory: root, emitUnifiedLog: false),
            defaults: defaults
        )
        let acceptedConnections = Task {
            try await withTimeout(waitingFor: "both bot-identity connections") {
                var connections: [WebSocketConnection] = []
                for await connection in server.connections {
                    connections.append(connection)
                    if connections.count == 2 { return connections }
                }
                throw TransportError.cancelled
            }
        }

        do {
            for _ in 0 ..< 300 where environment.users.count < 3 {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(environment.users.count == 3)

            environment.setActiveUser(activeUser.id)
            await environment.setBotUser(oldBot.id)
            environment.selectedProtocol = version == .v11 ? .oneBotV11 : .oneBotV12
            environment.settings = ConnectionSettings(
                transport: .webSocketClient,
                host: "127.0.0.1",
                port: port,
                autoReconnect: false
            )
            await environment.connect()

            for _ in 0 ..< 300 where !environment.sessionState.isConnected {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(environment.sessionState.isConnected)

            await environment.setBotUser(newBot.id)
            let connections = try await acceptedConnections.value
            #expect(connections[0].id != connections[1].id)
            for _ in 0 ..< 300 where handshakes.snapshot().count < 2 {
                try await Task.sleep(for: .milliseconds(10))
            }
            let capturedHeaders = handshakes.snapshot()
            #expect(capturedHeaders.count == 2)
            if version == .v11 {
                #expect(capturedHeaders.first?["X-Self-ID"] == oldBot.id)
                #expect(capturedHeaders.last?["X-Self-ID"] == newBot.id)
            } else {
                #expect(capturedHeaders.first?["Sec-WebSocket-Protocol"] == "12.matcha")
                #expect(capturedHeaders.last?["Sec-WebSocket-Protocol"] == "12.matcha")
            }
            #expect(await environment.platform.bots == [newBot.id])

            let oldFrames = try await withTimeout(waitingFor: "the old bot connection to close") {
                var frames: [WebSocketFrame] = []
                for await frame in connections[0].frames {
                    frames.append(frame)
                }
                return frames
            }
            let oldHandshakePayloads = try oldFrames.compactMap { frame -> JSONValue? in
                guard let text = frame.textValue else { return nil }
                return try JSONValue.decode(from: Data(text.utf8))
            }
            switch version {
            case .v11:
                #expect(oldHandshakePayloads.first?["self_id"]?.stringValue == oldBot.id)
            case .v12:
                let status = try #require(
                    oldHandshakePayloads.first {
                        $0["detail_type"]?.stringValue == "status_update"
                    }
                )
                #expect(status["status"]?["bots"]?[0]?["self"]?["user_id"]?.stringValue == oldBot.id)
            }

            let outboundMessage = Task {
                try await withTimeout(waitingFor: "a message from the new bot session") {
                    for await frame in connections[1].frames {
                        guard let text = frame.textValue,
                              let payload = try? JSONValue.decode(from: Data(text.utf8)),
                              payload["post_type"]?.stringValue == "message"
                                || payload["type"]?.stringValue == "message"
                        else {
                            continue
                        }
                        return payload
                    }
                    throw TransportError.cancelled
                }
            }

            for _ in 0 ..< 300 where !environment.sessionState.isConnected {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(environment.sessionState.isConnected)
            #expect(environment.activeBotUserID == newBot.id)

            environment.selectChat(
                Chat(scene: .group, peerID: group.id, selfID: newBot.id)
            )
            await environment.send(
                content: [.mention(userID: oldBot.id), .text("hello")]
            )

            let message = try await outboundMessage.value
            if version == .v11 {
                #expect(message["self_id"]?.stringValue == newBot.id)
            } else {
                #expect(message["self"]?["user_id"]?.stringValue == newBot.id)
            }
            #expect(message["user_id"]?.stringValue == activeUser.id)
            #expect(message["group_id"]?.stringValue == group.id)
            let mention = try #require(message["message"]?[0])
            if version == .v11 {
                #expect(mention["type"]?.stringValue == "at")
                #expect(mention["data"]?["qq"]?.stringValue == oldBot.id)
            } else {
                #expect(mention["type"]?.stringValue == "mention")
                #expect(mention["data"]?["user_id"]?.stringValue == oldBot.id)
            }

            await environment.disconnect()
            server.stop()
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: root)
        } catch {
            acceptedConnections.cancel()
            await environment.disconnect()
            server.stop()
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    @Test("a forward-connection protocol session publishes RTT after becoming ready")
    func serverSessionPublishesRoundTripTime() async throws {
        let store = try MatchaStore()
        let platform = PlatformService(store: store)
        let (session, port) = try await startServerSession(platform: platform)
        let client = WebSocketClient(
            configuration: .init(
                url: try #require(URL(string: "ws://127.0.0.1:\(port)/")),
                reconnectInterval: nil
            )
        )
        let updates = await session.roundTripTimeUpdates()
        let measurement = Task {
            try await withTimeout(waitingFor: "the forward-connection protocol session to publish RTT") {
                for await update in updates {
                    if case let .measured(duration) = update {
                        return duration
                    }
                }
                throw TransportError.cancelled
            }
        }

        do {
            client.start()
            let duration = try await measurement.value
            #expect(duration > .zero)
            client.stop()
            await session.stop()
        } catch {
            client.stop()
            await session.stop()
            throw error
        }
    }

    @Test("OneBot direction names follow the protocol implementation's role")
    func oneBotDirectionNamesMatchImplementationRole() {
        let serverName = TransportMode.webSocketServer.displayName
        let clientName = TransportMode.webSocketClient.displayName
        #expect(serverName.localizedCaseInsensitiveContains("forward"))
        #expect(clientName.localizedCaseInsensitiveContains("reverse"))
    }

    @Test("binding an occupied port fails startup instead of pretending to listen")
    func occupiedPortFailsStartup() async throws {
        let (first, port) = try await startServer()
        let second = WebSocketServer(port: port)
        defer {
            second.stop()
            first.stop()
        }

        do {
            try await second.start()
            Issue.record("The second listener must not become ready on the same port")
        } catch let error as TransportError {
            guard case let .listenFailed(reportedPort, _) = error else {
                Issue.record("Expected listenFailed, got \(error)")
                return
            }
            #expect(reportedPort == port)
        }
    }

    @Test("a failed app session stays failed and cannot record a local-only send")
    @MainActor
    func failedAppSessionDoesNotReportMessageSuccess() async throws {
        let (occupiedServer, port) = try await startServer()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Matcha-FailedSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaultsName = "dev.matcha.tests.failed-session.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        let store = try MatchaStore()
        let user = User(
            id: "10001",
            name: "User",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let bot = User(
            id: "10002",
            name: "Bot",
            createdAt: Date(timeIntervalSince1970: 2)
        )
        try await store.save(user)
        try await store.save(bot)
        let environment = AppEnvironment(
            store: store,
            assetStore: try AssetStore(
                directory: root.appendingPathComponent("Assets", isDirectory: true)
            ),
            appLog: AppLog(directory: root, emitUnifiedLog: false),
            defaults: defaults
        )

        do {
            for _ in 0 ..< 300 where environment.users.count < 2 {
                try await Task.sleep(for: .milliseconds(10))
            }
            environment.setActiveUser(user.id)
            await environment.setBotUser(bot.id)
            environment.settings = ConnectionSettings(
                transport: .webSocketServer,
                host: "127.0.0.1",
                port: port,
                autoReconnect: false
            )

            let didStart = await environment.connect()
            #expect(!didStart)
            guard case .failed = environment.sessionState else {
                Issue.record("The failed listener must leave the app in its failed state")
                throw TransportError.cancelled
            }
            #expect(environment.activeBotUserID == nil)
            let connectionError = environment.lastError
            #expect(connectionError != nil)
            #expect(environment.saveSettings())
            #expect(environment.lastError == connectionError)

            let chat = Chat(scene: .temp, peerID: user.id, selfID: bot.id)
            environment.selectChat(chat)
            let didSend = await environment.send(
                content: [.text("must not be local-only")],
                in: chat,
                as: user.id
            )
            #expect(!didSend)
            #expect(try await store.messages(in: chat).isEmpty)

            occupiedServer.stop()
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: root)
        } catch {
            await environment.disconnect()
            occupiedServer.stop()
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    @Test("the protocol handshake precedes domain events created during the handshake")
    func protocolHandshakePrecedesConcurrentEvents() async throws {
        let store = try MatchaStore()
        try await store.save(User(id: "20002", name: "Alice"))
        let platform = PlatformService(store: store)
        let ordering = HandshakeOrderingProbe()
        let implementation = OrderedHandshakeAdapter(ordering: ordering)
        let (session, port) = try await startServerSession(
            platform: platform,
            implementation: implementation
        )
        let traffic = await session.trafficLog()
        let ordinaryEventLogged = Task {
            try await withTimeout(waitingFor: "the domain event created during the handshake to enter fan-out") {
                for await entry in traffic where entry.payload["kind"]?.stringValue == "ordinary" {
                    return entry
                }
                throw TransportError.cancelled
            }
        }
        let client = WebSocketClient(
            configuration: .init(
                url: try #require(URL(string: "ws://127.0.0.1:\(port)/")),
                reconnectInterval: nil
            )
        )
        let connected = Task {
            try await withTimeout(waitingFor: "the handshake-ordering test to connect") {
                for await update in client.updates {
                    switch update {
                    case let .connected(connection):
                        return connection
                    case let .failed(error):
                        throw error
                    case .reconnecting:
                        continue
                    }
                }
                throw TransportError.cancelled
            }
        }

        do {
            client.start()
            let connection = try await connected.value
            try await withTimeout(waitingFor: "the protocol handshake to begin") {
                for await _ in ordering.handshakeStarts {
                    return
                }
                throw TransportError.cancelled
            }

            try await platform.sendMessage(
                scene: .friend,
                peerID: "20002",
                senderID: "20002",
                selfID: implementation.selfID,
                content: [.text("Event during handshake")]
            )
            _ = try await ordinaryEventLogged.value

            await ordering.releaseHandshake()
            let firstFrame = try await withTimeout(waitingFor: "the protocol's first frame") {
                for await frame in connection.frames {
                    return frame
                }
                throw TransportError.cancelled
            }
            let text = try #require(firstFrame.textValue)
            let payload = try JSONValue.decode(from: Data(text.utf8))
            #expect(payload["kind"]?.stringValue == "handshake")

            client.stop()
            await session.stop()
        } catch {
            await ordering.releaseHandshake()
            ordinaryEventLogged.cancel()
            connected.cancel()
            client.stop()
            await session.stop()
            throw error
        }
    }

    @Test("stopping a session closes connections mid-handshake and they do not revive")
    func stoppingDuringHandshakeClosesPendingConnection() async throws {
        let store = try MatchaStore()
        let platform = PlatformService(store: store)
        let ordering = HandshakeOrderingProbe()
        let implementation = OrderedHandshakeAdapter(ordering: ordering)
        let (session, port) = try await startServerSession(
            platform: platform,
            implementation: implementation
        )
        let client = WebSocketClient(
            configuration: .init(
                url: try #require(URL(string: "ws://127.0.0.1:\(port)/")),
                reconnectInterval: nil
            )
        )
        let connected = Task {
            try await withTimeout(waitingFor: "the pending-handshake connection to establish during stop") {
                for await update in client.updates {
                    switch update {
                    case let .connected(connection):
                        return connection
                    case let .failed(error):
                        throw error
                    case .reconnecting:
                        continue
                    }
                }
                throw TransportError.cancelled
            }
        }

        do {
            client.start()
            let connection = try await connected.value
            try await withTimeout(waitingFor: "the protocol handshake being stopped to begin") {
                for await _ in ordering.handshakeStarts {
                    return
                }
                throw TransportError.cancelled
            }

            await session.stop()
            try await withTimeout(waitingFor: "the connection mid-handshake to close") {
                for await _ in connection.frames {}
            }

            await ordering.releaseHandshake()
            try await withTimeout(waitingFor: "the cancelled protocol handshake to resume") {
                for await _ in ordering.handshakeResumes {
                    return
                }
                throw TransportError.cancelled
            }
            try await Task.sleep(for: .milliseconds(50))
            #expect(await session.state == .idle)

            client.stop()
        } catch {
            await ordering.releaseHandshake()
            connected.cancel()
            client.stop()
            await session.stop()
            throw error
        }
    }

    @Test("the Milky API and event WebSocket share a port")
    func milkyServesAPIAndEventWebSocketOnOnePort() async throws {
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
            assetResolver: EmptyMilkyAssetResolver()
        )
        let (session, port) = try await startMilkyServiceSession(
            platform: platform,
            implementation: implementation,
            token: "secret"
        )
        let settings = ConnectionSettings(
            transport: .milkyService,
            host: "127.0.0.1",
            port: port,
            accessToken: "secret"
        )
        #expect(settings.eventStreamURL?.absoluteString == "ws://127.0.0.1:\(port)/event")
        #expect(await session.state == .ready(port: port))

        let eventClient = WebSocketClient(
            configuration: .init(
                url: try #require(URL(string: "ws://127.0.0.1:\(port)/event?access_token=secret")),
                reconnectInterval: nil
            )
        )
        let connected = Task {
            try await withTimeout(waitingFor: "the Milky /event WebSocket to connect") {
                for await update in eventClient.updates {
                    switch update {
                    case let .connected(connection):
                        return connection
                    case let .failed(error):
                        throw error
                    case .reconnecting:
                        continue
                    }
                }
                throw TransportError.cancelled
            }
        }
        do {
            eventClient.start()
            let eventConnection = try await connected.value
            #expect(await session.state == .ready(port: port))

            var request = URLRequest(
                url: try #require(URL(string: "http://127.0.0.1:\(port)/api/get_login_info"))
            )
            request.httpMethod = "POST"
            request.httpBody = Data("{}".utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
            let (responseData, response) = try await URLSession.shared.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            let responsePayload = try JSONValue.decode(from: responseData)
            #expect(responsePayload["status"]?.stringValue == "ok")
            #expect(responsePayload["data"]?["uin"]?.stringValue == bot.id)

            var queryOnlyRequest = request
            queryOnlyRequest.url = URL(
                string: "http://127.0.0.1:\(port)/api/get_login_info?access_token=secret"
            )
            queryOnlyRequest.setValue(nil, forHTTPHeaderField: "Authorization")
            let (_, queryOnlyResponse) = try await URLSession.shared.data(for: queryOnlyRequest)
            #expect((queryOnlyResponse as? HTTPURLResponse)?.statusCode == 401)

            var malformedRequest = request
            malformedRequest.httpBody = Data("{".utf8)
            let (malformedData, malformedResponse) = try await URLSession.shared.data(
                for: malformedRequest
            )
            #expect((malformedResponse as? HTTPURLResponse)?.statusCode == 200)
            let malformedPayload = try JSONValue.decode(from: malformedData)
            #expect(malformedPayload["status"]?.stringValue == "failed")
            #expect(malformedPayload["retcode"]?.intValue == -400)

            try await platform.sendMessage(
                scene: .friend,
                peerID: alice.id,
                senderID: alice.id,
                selfID: bot.id,
                content: [.text("Milky event")]
            )
            let eventFrame = try await withTimeout(waitingFor: "a Milky event frame") {
                for await frame in eventConnection.frames {
                    return frame
                }
                throw TransportError.cancelled
            }
            let eventText = try #require(eventFrame.textValue)
            let eventPayload = try JSONValue.decode(from: Data(eventText.utf8))
            #expect(eventPayload["self_id"]?.stringValue == bot.id)
            #expect(eventPayload["event_type"]?.stringValue == "message_receive")

            eventClient.stop()
            await session.stop()
            try await Task.sleep(for: .milliseconds(100))
            #expect(await session.state == .idle)
        } catch {
            connected.cancel()
            eventClient.stop()
            await session.stop()
            throw error
        }
    }

    @Test(
        "reverse connections use versioned paths, handshake metadata, and an initial frame",
        arguments: OneBotVersion.allCases
    )
    func reverseConnectionUsesVersionSpecificHandshake(_ version: OneBotVersion) async throws {
        let handshakeCapture = HandshakeCapture()
        let (server, port) = try await startServer { _, headers in
            handshakeCapture.record(headers)
            return .accept
        }
        let store = try MatchaStore()
        let platform = PlatformService(store: store)
        let implementation = OneBotProtocolImplementation(
            version: version,
            selfID: "10001",
            platform: platform,
            assetResolver: EmptyAssetResolver()
        )
        let handshake = implementation.webSocketClientHandshake
        let settings = ConnectionSettings(
            transport: .webSocketClient,
            host: "127.0.0.1",
            port: port,
            path: "",
            accessToken: "secret",
            autoReconnect: false
        )
        let session = ProtocolSession(
            implementation: implementation,
            platform: platform,
            settings: settings
        )
        let accepted = Task {
            try await withTimeout(waitingFor: "the server to accept a OneBot reverse connection") {
                for await connection in server.connections {
                    return connection
                }
                throw TransportError.cancelled
            }
        }

        do {
            let url = try #require(settings.webSocketURL(defaultPath: handshake.defaultPath))
            #expect(url.path == version.noneBotReverseWebSocketPath)

            try await session.start()
            let connection = try await accepted.value
            let capturedHandshake = try await withTimeout(waitingFor: "the WebSocket handshake callback") {
                while handshakeCapture.snapshot() == nil {
                    try await Task.sleep(for: .milliseconds(10))
                }
                return try #require(handshakeCapture.snapshot())
            }
            let requestHeaders = capturedHandshake
            #expect(requestHeaders.bearerToken == "secret")
            #expect(requestHeaders["User-Agent"] == "Matcha/\(MatchaVersion.current)")

            switch version {
            case .v11:
                #expect(requestHeaders["X-Self-ID"] == "10001")
                #expect(requestHeaders["X-Client-Role"] == "Universal")
                #expect(requestHeaders["Sec-WebSocket-Protocol"] == nil)
            case .v12:
                #expect(requestHeaders["X-Self-ID"] == nil)
                #expect(requestHeaders["X-Client-Role"] == nil)
                #expect(requestHeaders["Sec-WebSocket-Protocol"] == "12.matcha")
            }

            let expectedFrameCount = version == .v12 ? 2 : 1
            let handshakeFrames = try await withTimeout(waitingFor: "the OneBot handshake meta-event") {
                var frames: [WebSocketFrame] = []
                for await frame in connection.frames {
                    frames.append(frame)
                    if frames.count == expectedFrameCount {
                        return frames
                    }
                }
                throw TransportError.cancelled
            }
            let text = try #require(handshakeFrames.first?.textValue)
            let payload = try JSONValue.decode(from: Data(text.utf8))
            #expect(payload["time"]?.doubleValue != nil)
            switch version {
            case .v11:
                #expect(payload["self_id"]?.stringValue == "10001")
                #expect(payload["post_type"]?.stringValue == "meta_event")
                #expect(payload["meta_event_type"]?.stringValue == "lifecycle")
                #expect(payload["sub_type"]?.stringValue == "connect")
            case .v12:
                #expect(payload["id"]?.stringValue?.isEmpty == false)
                #expect(payload["type"]?.stringValue == "meta")
                #expect(payload["detail_type"]?.stringValue == "connect")
                #expect(payload["sub_type"]?.stringValue == "")
                #expect(payload["version"]?["impl"]?.stringValue == "matcha")
                #expect(payload["version"]?["version"]?.stringValue == MatchaVersion.current)
                #expect(payload["version"]?["onebot_version"]?.stringValue == "12")

                let statusText = try #require(handshakeFrames.last?.textValue)
                let statusUpdate = try JSONValue.decode(from: Data(statusText.utf8))
                #expect(statusUpdate["id"]?.stringValue?.isEmpty == false)
                #expect(statusUpdate["time"]?.doubleValue != nil)
                #expect(statusUpdate["type"]?.stringValue == "meta")
                #expect(statusUpdate["detail_type"]?.stringValue == "status_update")
                #expect(statusUpdate["sub_type"]?.stringValue == "")
                let status = try #require(statusUpdate["status"])
                #expect(status["good"]?.boolValue == true)
                let bot = try #require(status["bots"]?[0])
                #expect(bot["self"]?["platform"]?.stringValue == "matcha")
                #expect(bot["self"]?["user_id"]?.stringValue == "10001")
                #expect(bot["online"]?.boolValue == true)
            }

            await session.stop()
            server.stop()
        } catch {
            await session.stop()
            server.stop()
            throw error
        }
    }

    /// Binding a randomly chosen high port can race with another process, so retry
    /// the actual listener rather than treating a guessed free port as reserved.
    private func startServer(
        authenticator: @escaping WebSocketServer.Authenticator = { _, _ in .accept }
    ) async throws -> (WebSocketServer, UInt16) {
        var lastError: (any Error)?
        for _ in 0 ..< 20 {
            let port = UInt16.random(in: 30_000 ... 60_000)
            let server = WebSocketServer(port: port, authenticator: authenticator)
            do {
                try await server.start()
                return (server, port)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? TransportError.listenFailed(port: 0, underlying: "No available test port found")
    }

    private func startServerSession(
        platform: PlatformService,
        implementation: any ProtocolImplementation = ProbeAdapter()
    ) async throws -> (ProtocolSession, UInt16) {
        var lastError: (any Error)?
        for _ in 0 ..< 20 {
            let port = UInt16.random(in: 30_000 ... 60_000)
            let session = ProtocolSession(
                implementation: implementation,
                platform: platform,
                settings: ConnectionSettings(
                    transport: .webSocketServer,
                    host: "127.0.0.1",
                    port: port,
                    autoReconnect: false
                )
            )
            do {
                try await session.start()
                return (session, port)
            } catch {
                lastError = error
                await session.stop()
            }
        }
        throw lastError ?? TransportError.listenFailed(port: 0, underlying: "No available test port found")
    }

    private func startMilkyServiceSession(
        platform: PlatformService,
        implementation: MilkyProtocolImplementation,
        token: String
    ) async throws -> (ProtocolSession, UInt16) {
        var lastError: (any Error)?
        for _ in 0 ..< 20 {
            let port = UInt16.random(in: 30_000 ... 60_000)
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
            do {
                try await session.start()
                return (session, port)
            } catch {
                lastError = error
                await session.stop()
            }
        }
        throw lastError ?? TransportError.listenFailed(port: 0, underlying: "No available test port found")
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

private final class ProbeAdapter: ProtocolImplementation, @unchecked Sendable {
    static let identifier = "test.probe"
    static let displayName = "Probe"
    static let supportedTransports: Set<TransportMode> = [.webSocketServer, .webSocketClient]

    let selfID = "10001"

    func handle(call: ProtocolCall) async -> ProtocolReply { .success() }
    func envelope(for reply: ProtocolReply, echo: JSONValue?) -> JSONValue { reply.data }
    func encode(event: DomainEvent) async -> [OutboundFrame] { [] }
}

private final class OrderedHandshakeAdapter: ProtocolImplementation, @unchecked Sendable {
    static let identifier = "test.ordered-handshake"
    static let displayName = "Ordered Handshake"
    static let supportedTransports: Set<TransportMode> = [.webSocketServer]

    let selfID = "10001"
    private let ordering: HandshakeOrderingProbe

    init(ordering: HandshakeOrderingProbe) {
        self.ordering = ordering
    }

    func handle(call: ProtocolCall) async -> ProtocolReply { .success() }
    func envelope(for reply: ProtocolReply, echo: JSONValue?) -> JSONValue { reply.data }

    func encode(event: DomainEvent) async -> [OutboundFrame] {
        [OutboundFrame(payload: ["kind": "ordinary", "type": "message"])]
    }

    func handshakeFrames() async -> [OutboundFrame] {
        await ordering.suspendHandshake()
        return [OutboundFrame(payload: ["kind": "handshake", "type": "meta"])]
    }
}

private actor HandshakeOrderingProbe {
    nonisolated let handshakeStarts: AsyncStream<Void>
    nonisolated let handshakeResumes: AsyncStream<Void>

    private let handshakeStartContinuation: AsyncStream<Void>.Continuation
    private let handshakeResumeContinuation: AsyncStream<Void>.Continuation
    private var handshakeReleased = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init() {
        var startContinuation: AsyncStream<Void>.Continuation!
        handshakeStarts = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            startContinuation = $0
        }
        handshakeStartContinuation = startContinuation

        var resumeContinuation: AsyncStream<Void>.Continuation!
        handshakeResumes = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            resumeContinuation = $0
        }
        handshakeResumeContinuation = resumeContinuation
    }

    func suspendHandshake() async {
        handshakeStartContinuation.yield(())
        handshakeStartContinuation.finish()

        if !handshakeReleased {
            await withCheckedContinuation { continuation in
                if handshakeReleased {
                    continuation.resume()
                } else {
                    releaseContinuation = continuation
                }
            }
        }
        handshakeResumeContinuation.yield(())
        handshakeResumeContinuation.finish()
    }

    func releaseHandshake() {
        handshakeReleased = true
        let continuation = releaseContinuation
        releaseContinuation = nil
        continuation?.resume()
    }
}

private struct EmptyAssetResolver: AssetResolver {
    func reference(for asset: Asset, version: OneBotVersion) async -> AssetReference {
        AssetReference(identifier: asset.id, url: "")
    }

    func asset(forIdentifier identifier: String, kind: MatchaOneBot.AssetKind) async -> Asset? { nil }

    func asset(
        forReference reference: String,
        url: String?,
        kind: MatchaOneBot.AssetKind
    ) async -> Asset? { nil }
}

private struct EmptyMilkyAssetResolver: MilkyAssetResolving {
    func resource(for asset: Asset) async -> MilkyResource {
        MilkyResource(resourceID: asset.id, tempURL: "")
    }

    func ingest(uri: String, kind: MatchaMilky.AssetKind) async -> Asset? { nil }
    func displayName(for userID: String) async -> String { userID }
    func replyReference(messageID: String) async -> MilkyReplyReference? { nil }
    func messageID(forSeq seq: Int64) async -> String? { nil }
}

private final class HandshakeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: HTTPHeaders?

    func record(_ headers: HTTPHeaders) {
        lock.lock()
        value = headers
        lock.unlock()
    }

    func snapshot() -> HTTPHeaders? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class HandshakeHistory: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [HTTPHeaders] = []

    func record(_ headers: HTTPHeaders) {
        lock.lock()
        values.append(headers)
        lock.unlock()
    }

    func snapshot() -> [HTTPHeaders] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private extension SessionState {
    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}
