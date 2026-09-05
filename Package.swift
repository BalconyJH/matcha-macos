// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Rei",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ReiLogging", targets: ["ReiLogging"]),
        .library(name: "ReiUI", targets: ["ReiUI"]),
    ],
    dependencies: [],
    targets: [
        .target(name: "ReiLogging"),

        // Domain model and storage. Knows nothing about any wire protocol.
        .target(name: "ReiCore"),

        // Transports: WebSocket server/client and a minimal HTTP/1.1 server,
        // all on Network.framework.
        .target(name: "ReiTransport", dependencies: ["ReiCore"]),

        // The protocol-neutral implementation contract shared by OneBot and Milky.
        .target(name: "ReiProtocol", dependencies: ["ReiCore", "ReiTransport"]),

        // Peer protocol implementations.
        .target(name: "ReiOneBot", dependencies: ["ReiProtocol"]),
        .target(name: "ReiMilky", dependencies: ["ReiProtocol"]),

        // AppKit/SwiftUI user interface.
        .target(
            name: "ReiUI",
            dependencies: [
                "ReiCore", "ReiProtocol", "ReiOneBot", "ReiMilky", "ReiLogging",
            ]
        ),

        .testTarget(
            name: "ReiTests",
            dependencies: [
                "ReiCore", "ReiTransport", "ReiProtocol", "ReiOneBot", "ReiMilky",
                "ReiLogging",
                .target(name: "ReiUI"),
            ]
        ),
    ]
)
