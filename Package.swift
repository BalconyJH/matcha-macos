// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Matcha",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MatchaLogging", targets: ["MatchaLogging"]),
        .library(name: "MatchaUI", targets: ["MatchaUI"]),
    ],
    dependencies: [],
    targets: [
        .target(name: "MatchaLogging"),

        // Domain model and storage. Knows nothing about any wire protocol.
        .target(name: "MatchaCore"),

        // Transports: WebSocket server/client and a minimal HTTP/1.1 server,
        // all on Network.framework.
        .target(name: "MatchaTransport", dependencies: ["MatchaCore"]),

        // The protocol-neutral implementation contract shared by OneBot and Milky.
        .target(name: "MatchaProtocol", dependencies: ["MatchaCore", "MatchaTransport"]),

        // Peer protocol implementations.
        .target(name: "MatchaOneBot", dependencies: ["MatchaProtocol"]),
        .target(name: "MatchaMilky", dependencies: ["MatchaProtocol"]),

        // AppKit/SwiftUI user interface.
        .target(
            name: "MatchaUI",
            dependencies: [
                "MatchaCore", "MatchaProtocol", "MatchaOneBot", "MatchaMilky", "MatchaLogging",
            ]
        ),

        .testTarget(
            name: "MatchaTests",
            dependencies: [
                "MatchaCore", "MatchaTransport", "MatchaProtocol", "MatchaOneBot", "MatchaMilky",
                "MatchaLogging",
                .target(name: "MatchaUI"),
            ]
        ),
    ]
)
