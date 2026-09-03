import Foundation

/// A stable failure vocabulary for one WebHook delivery.
public enum HTTPWebhookClientError: Error, LocalizedError, Sendable, Equatable {
    case invalidEndpoint
    case requestFailed(code: Int)
    case nonHTTPResponse
    case rejected(statusCode: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Invalid WebHook endpoint"
        case let .requestFailed(code):
            return "WebHook request failed with network error \(code)"
        case .nonHTTPResponse:
            return "WebHook response was not HTTP"
        case let .rejected(statusCode):
            return "WebHook endpoint returned HTTP \(statusCode)"
        }
    }
}

/// Sends JSON events to an HTTP WebHook endpoint.
///
/// A delivery succeeds only when the endpoint returns a 2xx status. Response bodies
/// are never buffered: receivers such as NoneBot acknowledge with `204 No Content`,
/// and a response body has no protocol meaning. Redirects are rejected so a Bearer
/// token cannot be forwarded to an endpoint the operator did not configure.
public struct HTTPWebhookClient: Sendable {
    public struct Configuration: Sendable {
        public var url: URL
        /// Sent as `Authorization: Bearer ...` when non-empty.
        public var accessToken: String?
        public var timeoutInterval: TimeInterval

        public init(
            url: URL,
            accessToken: String? = nil,
            timeoutInterval: TimeInterval = 30
        ) {
            self.url = url
            self.accessToken = accessToken
            self.timeoutInterval = timeoutInterval
        }
    }

    private let configuration: Configuration
    private let session: URLSession

    public init(
        configuration: Configuration,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session
    }

    /// Posts one already-encoded JSON document and waits for the response headers.
    public func post(_ body: Data) async throws {
        try Task.checkCancellation()
        guard Self.isValidEndpoint(configuration.url) else {
            throw HTTPWebhookClientError.invalidEndpoint
        }

        var request = URLRequest(url: configuration.url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = validatedTimeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accessToken = configuration.accessToken, !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(
                for: request,
                delegate: HTTPWebhookRedirectBlocker.shared
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw HTTPWebhookClientError.requestFailed(code: (error as NSError).code)
        }

        // The response body is outside the protocol contract. Cancelling its data
        // task avoids buffering an unbounded or never-ending body after the headers.
        bytes.task.cancel()
        try Task.checkCancellation()

        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPWebhookClientError.nonHTTPResponse
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw HTTPWebhookClientError.rejected(statusCode: httpResponse.statusCode)
        }
    }

    private var validatedTimeoutInterval: TimeInterval {
        let timeout = configuration.timeoutInterval
        return timeout.isFinite && timeout > 0 ? timeout : 30
    }

    private static func isValidEndpoint(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return (scheme == "http" || scheme == "https")
            && url.host?.isEmpty == false
            && (url.port.map { (1 ... Int(UInt16.max)).contains($0) } ?? true)
    }
}

private final class HTTPWebhookRedirectBlocker: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable
{
    static let shared = HTTPWebhookRedirectBlocker()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
