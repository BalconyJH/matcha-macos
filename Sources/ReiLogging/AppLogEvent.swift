import Foundation

public enum AppLogLevel: String, CaseIterable, Codable, Sendable {
    case debug
    case info
    case notice
    case warning
    case error
}

/// The subsystem that originated a record.
///
/// App-owned operations use ``application`` regardless of which service they call;
/// their domain meaning stays in ``AppLogFields/operation``.
public enum AppLogCategory: String, CaseIterable, Codable, Sendable {
    case lifecycle
    case persistence
    case application
    case connection
}

/// A high-signal operation owned by Rei itself rather than a protocol consumer.
///
/// Raw values are stable structured-log tokens. The vocabulary deliberately has
/// no associated strings, so identifiers, names, content, hosts, and paths cannot
/// cross the logging boundary.
public enum AppLogOperation: String, CaseIterable, Codable, Sendable {
    case loadSettings = "settings.load"
    case migrateSettings = "settings.migrate"
    case saveSettings = "settings.save"
    case selectActivePersona = "persona.active.select"
    case selectBotPersona = "persona.bot.select"
    case createPersona = "persona.create"
    case createGroup = "group.create"
    case deleteGroup = "group.delete"
    case addFriend = "friend.add"
    case removeFriend = "friend.remove"
    case addGroupMember = "group.member.add"
    case removeGroupMember = "group.member.remove"
    case selectChat = "chat.select"
    case closeChat = "chat.close"
    case clearMessageHistory = "message.history.clear"
    case sendMessage = "message.send"
    case recallMessage = "message.recall"
    case approveRequest = "request.approve"
    case rejectRequest = "request.reject"
    case importAttachment = "attachment.import"
    case chooseAttachments = "attachment.choose"
    case loadGroupMembers = "group.members.load"
    case loadQuotedMessage = "message.quoted.load"
    case clearLogs = "logs.clear"
    case exportLogs = "logs.export"
}

public enum AppLogProtocol: String, CaseIterable, Codable, Sendable {
    case oneBotV11
    case oneBotV12
    case milky
}

public enum AppLogTransport: String, CaseIterable, Codable, Sendable {
    case webSocketServer
    case webSocketClient
    case milkyService
    /// Retained so persisted records from the earlier transport model remain decodable.
    case milkyWebSocket
    case milkyWebhook
    case httpServer
}

public enum AppLogConnectionRejection: String, CaseIterable, Codable, Sendable {
    case missingBotAccount
}

/// A privacy-safe description of a failure.
///
/// Error descriptions and user-info values are intentionally not retained. An
/// invalid or data-shaped NSError domain is replaced before it reaches any sink.
public struct AppLogFailure: Hashable, Codable, Sendable {
    public let domain: String
    public let code: Int

    private enum CodingKeys: String, CodingKey {
        case domain
        case code
    }

    public init(_ error: any Error) {
        let nsError = error as NSError
        domain = Self.sanitize(domain: nsError.domain)
        code = nsError.code
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        domain = Self.sanitize(
            domain: try container.decode(String.self, forKey: .domain)
        )
        code = try container.decode(Int.self, forKey: .code)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(domain, forKey: .domain)
        try container.encode(code, forKey: .code)
    }

    private static func sanitize(domain: String) -> String {
        let trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowedDomains: Set<String> = [
            NSCocoaErrorDomain,
            NSPOSIXErrorDomain,
            NSOSStatusErrorDomain,
            NSMachErrorDomain,
            NSURLErrorDomain,
            "ReiCore.StorePersistenceError",
            "ReiProtocol.PlatformError",
            "ReiProtocol.ProtocolSessionError",
            "ReiTransport.TransportError",
        ]
        guard allowedDomains.contains(trimmed) else {
            return "redacted.errorDomain"
        }
        return trimmed
    }
}

/// Events accepted by the application log.
///
/// This is deliberately a closed, caller-first vocabulary. Callers cannot attach
/// free-form messages, identifiers, hosts, paths, payloads, or metadata.
public enum AppLogEvent: Hashable, Sendable {
    case applicationStarted
    case environmentLoaded
    case environmentLoadFailed(AppLogFailure)
    case storeObservationFailed(AppLogFailure)
    case operationCompleted(AppLogOperation)
    /// The call returned an error; this intentionally makes no rollback claim.
    case operationReturnedError(operation: AppLogOperation, failure: AppLogFailure)
    case attachmentImportUnavailable
    case connectionRequested(
        protocolKind: AppLogProtocol,
        transportKind: AppLogTransport,
        port: UInt16
    )
    case connectionRejected(AppLogConnectionRejection)
    case sessionListening(port: UInt16)
    case sessionReady(port: UInt16)
    case sessionConnecting
    case sessionConnected
    case sessionStopped
    case sessionFailed
    case sessionStartFailed(AppLogFailure)
    case sessionEventDeliveryFailed

    public var identifier: String {
        switch self {
        case .applicationStarted:
            "application.started"
        case .environmentLoaded:
            "environment.loaded"
        case .environmentLoadFailed:
            "environment.loadFailed"
        case .storeObservationFailed:
            "store.observationFailed"
        case .operationCompleted(let operation):
            "app.\(operation.rawValue).completed"
        case .operationReturnedError(let operation, _):
            "app.\(operation.rawValue).returnedError"
        case .attachmentImportUnavailable:
            "app.attachment.import.unavailable"
        case .connectionRequested:
            "connection.requested"
        case .connectionRejected:
            "connection.rejected"
        case .sessionListening:
            "session.listening"
        case .sessionReady:
            "session.ready"
        case .sessionConnecting:
            "session.connecting"
        case .sessionConnected:
            "session.connected"
        case .sessionStopped:
            "session.stopped"
        case .sessionFailed:
            "session.failed"
        case .sessionStartFailed:
            "session.startFailed"
        case .sessionEventDeliveryFailed:
            "session.eventDeliveryFailed"
        }
    }

    var level: AppLogLevel {
        switch self {
        case .applicationStarted, .environmentLoaded, .operationCompleted,
            .sessionListening, .sessionReady, .sessionConnecting, .sessionStopped:
            .info
        case .connectionRequested, .sessionConnected:
            .notice
        case .connectionRejected, .attachmentImportUnavailable:
            .warning
        case .sessionEventDeliveryFailed:
            .warning
        case .environmentLoadFailed, .storeObservationFailed, .sessionFailed,
            .sessionStartFailed, .operationReturnedError:
            .error
        }
    }

    var category: AppLogCategory {
        switch self {
        case .applicationStarted, .environmentLoaded, .environmentLoadFailed:
            .lifecycle
        case .storeObservationFailed:
            .persistence
        case .operationCompleted, .operationReturnedError, .attachmentImportUnavailable:
            .application
        case .connectionRequested, .connectionRejected, .sessionListening,
            .sessionReady, .sessionConnecting, .sessionConnected, .sessionStopped, .sessionFailed,
            .sessionStartFailed, .sessionEventDeliveryFailed:
            .connection
        }
    }

    var fields: AppLogFields {
        switch self {
        case .environmentLoadFailed(let failure),
            .storeObservationFailed(let failure),
            .sessionStartFailed(let failure):
            AppLogFields(failure: failure)
        case .operationCompleted(let operation):
            AppLogFields(operation: operation)
        case .operationReturnedError(let operation, let failure):
            AppLogFields(operation: operation, failure: failure)
        case .attachmentImportUnavailable:
            AppLogFields(operation: .importAttachment)
        case .connectionRequested(let protocolKind, let transportKind, let port):
            AppLogFields(
                protocolKind: protocolKind,
                transportKind: transportKind,
                port: port
            )
        case .connectionRejected(let rejection):
            AppLogFields(connectionRejection: rejection)
        case .sessionListening(let port), .sessionReady(let port):
            AppLogFields(port: port)
        case .applicationStarted, .environmentLoaded, .sessionConnecting,
            .sessionConnected, .sessionStopped, .sessionFailed,
            .sessionEventDeliveryFailed:
            AppLogFields()
        }
    }
}

/// The complete, typed field set a log event may produce.
///
/// There is no public initializer: fields are derived from ``AppLogEvent`` and
/// cannot be supplied independently by callers.
public struct AppLogFields: Hashable, Codable, Sendable {
    public let operation: AppLogOperation?
    public let protocolKind: AppLogProtocol?
    public let transportKind: AppLogTransport?
    public let port: UInt16?
    public let connectionRejection: AppLogConnectionRejection?
    public let errorDomain: String?
    public let errorCode: Int?

    init(
        operation: AppLogOperation? = nil,
        protocolKind: AppLogProtocol? = nil,
        transportKind: AppLogTransport? = nil,
        port: UInt16? = nil,
        connectionRejection: AppLogConnectionRejection? = nil,
        errorDomain: String? = nil,
        errorCode: Int? = nil
    ) {
        self.operation = operation
        self.protocolKind = protocolKind
        self.transportKind = transportKind
        self.port = port
        self.connectionRejection = connectionRejection
        self.errorDomain = errorDomain
        self.errorCode = errorCode
    }

    init(failure: AppLogFailure) {
        self.init(errorDomain: failure.domain, errorCode: failure.code)
    }

    init(operation: AppLogOperation, failure: AppLogFailure) {
        self.init(
            operation: operation,
            errorDomain: failure.domain,
            errorCode: failure.code
        )
    }

    public var isEmpty: Bool {
        operation == nil
            && protocolKind == nil
            && transportKind == nil
            && port == nil
            && connectionRejection == nil
            && errorDomain == nil
            && errorCode == nil
    }

    var renderedComponents: [String] {
        var components: [String] = []
        if let operation {
            components.append("operation=\(operation.rawValue)")
        }
        if let protocolKind {
            components.append("protocolKind=\(protocolKind.rawValue)")
        }
        if let transportKind {
            components.append("transportKind=\(transportKind.rawValue)")
        }
        if let port {
            components.append("port=\(port)")
        }
        if let connectionRejection {
            components.append("connectionRejection=\(connectionRejection.rawValue)")
        }
        if let errorDomain {
            components.append("errorDomain=\(errorDomain)")
        }
        if let errorCode {
            components.append("errorCode=\(errorCode)")
        }
        return components
    }
}
