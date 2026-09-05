import Foundation
import Testing

@testable import ReiTransport

@Suite("HTTP Webhook Client")
struct HTTPWebhookClientTests {
    @Test("POST sends JSON and bearer authentication and accepts 204")
    func postsJSONWithBearerAuthentication() async throws {
        let capture = RequestCapture()
        let (server, port) = try await startServer { request in
            await capture.record(request)
            return .empty(status: 204)
        }
        defer { server.stop() }

        let body = Data(#"{"event_type":"message_receive"}"#.utf8)
        let client = HTTPWebhookClient(
            configuration: .init(
                url: try #require(URL(string: "http://127.0.0.1:\(port)/milky/events")),
                accessToken: "secret"
            )
        )

        try await client.post(body)

        let request = try #require(await capture.request)
        #expect(request.method == "POST")
        #expect(request.path == "/milky/events")
        #expect(request.body == body)
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.headers.bearerToken == "secret")
    }

    @Test("a non-2xx response is a stable transport failure")
    func rejectsUnauthorizedResponse() async throws {
        let (server, port) = try await startServer { _ in
            .empty(status: 401)
        }
        defer { server.stop() }

        let client = HTTPWebhookClient(
            configuration: .init(
                url: try #require(URL(string: "http://127.0.0.1:\(port)/milky/events"))
            )
        )

        do {
            try await client.post(Data("{}".utf8))
            Issue.record("Expected the 401 response to fail")
        } catch let error as HTTPWebhookClientError {
            guard case .rejected(let statusCode) = error else {
                Issue.record("Expected rejected, got \(error)")
                return
            }
            #expect(statusCode == 401)
        }
    }

    @Test("an empty token omits Authorization")
    func emptyTokenOmitsAuthorization() async throws {
        let capture = RequestCapture()
        let (server, port) = try await startServer { request in
            await capture.record(request)
            return .empty(status: 204)
        }
        defer { server.stop() }

        let client = HTTPWebhookClient(
            configuration: .init(
                url: try #require(URL(string: "http://127.0.0.1:\(port)/milky/")),
                accessToken: ""
            )
        )

        try await client.post(Data("{}".utf8))
        #expect(await capture.request?.headers["Authorization"] == nil)
    }

    @Test("redirects are rejected before credentials reach another endpoint")
    func rejectsRedirects() async throws {
        let redirectedCapture = RequestCapture()
        let (redirectedServer, redirectedPort) = try await startServer { request in
            await redirectedCapture.record(request)
            return .empty(status: 204)
        }
        defer { redirectedServer.stop() }

        let (redirectingServer, redirectingPort) = try await startServer { _ in
            HTTPResponse(
                status: 302,
                headers: [
                    ("Location", "http://127.0.0.1:\(redirectedPort)/captured")
                ]
            )
        }
        defer { redirectingServer.stop() }

        let client = HTTPWebhookClient(
            configuration: .init(
                url: try #require(URL(string: "http://127.0.0.1:\(redirectingPort)/milky/")),
                accessToken: "secret"
            )
        )

        do {
            try await client.post(Data("{}".utf8))
            Issue.record("Expected the redirect response to fail")
        } catch let error as HTTPWebhookClientError {
            #expect(error == .rejected(statusCode: 302))
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await redirectedCapture.request == nil)
    }

    @Test("an endpoint with an empty host is rejected before networking")
    func rejectsEmptyHost() async throws {
        let client = HTTPWebhookClient(
            configuration: .init(
                url: try #require(URL(string: "http://:8080/milky/"))
            )
        )

        do {
            try await client.post(Data("{}".utf8))
            Issue.record("Expected the endpoint to be rejected")
        } catch let error as HTTPWebhookClientError {
            #expect(error == .invalidEndpoint)
        }
    }

    @Test("cancelling a delivery propagates task cancellation")
    func propagatesCancellation() async throws {
        let capture = RequestCapture()
        let (server, port) = try await startServer { request in
            await capture.record(request)
            try? await Task.sleep(for: .seconds(30))
            return .empty(status: 204)
        }
        defer { server.stop() }

        let client = HTTPWebhookClient(
            configuration: .init(
                url: try #require(URL(string: "http://127.0.0.1:\(port)/milky/events"))
            )
        )
        let delivery = Task {
            try await client.post(Data("{}".utf8))
        }

        for _ in 0..<300 {
            if await capture.request != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try #require(await capture.request)
        delivery.cancel()

        do {
            try await delivery.value
            Issue.record("Expected the delivery task to be cancelled")
        } catch is CancellationError {
            // Cancellation is intentionally not collapsed into a network failure.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

    private func startServer(
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
}

private actor RequestCapture {
    private(set) var request: HTTPRequest?

    func record(_ request: HTTPRequest) {
        self.request = request
    }
}
