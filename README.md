# Matcha for macOS

Matcha is a development tool that simulates a chat platform. It presents itself as QQ: the bot
framework under test connects to it as if it were a real platform, while you use the app to send
messages as any identity, create groups, and send friend requests. The framework receives the same
events and action responses it would receive in production. No real account is required, there is no
risk-control system to worry about, and you do not need another person to help reproduce an issue.

This project is a native macOS rewrite of
[BalconyJH/matcha](https://github.com/BalconyJH/matcha). The upstream project uses Vue and Tauri;
this version uses AppKit and SwiftUI and depends only on system frameworks.

## Supported Protocols

- OneBot V11, with forward and reverse WebSocket connections
- OneBot V12, with forward and reverse WebSocket connections
- Milky 1.3, with its HTTP API, `/event` WebSocket, and optional WebHook event sinks

Matcha is the simulated messaging platform and implements the protocol-facing endpoint. It does not
provide a NoneBot adapter plugin. `nonebot-adapter-onebot` and `nonebot-adapter-milky` are consumers:
they call Matcha's protocol endpoints and receive the events Matcha produces. OneBot dispatches by
the `action` field over a persistent connection, while Milky dispatches API calls by URL path over
HTTP. All simulated state remains in Matcha.

## Connecting NoneBot

OneBot defines forward and reverse connections from the perspective of the **protocol
implementation**. Matcha is the protocol implementation here:

| Mode | Matcha role | NoneBot role and configuration |
| --- | --- | --- |
| Forward WebSocket | Server; waits for a connection | Use a `WebSocketClient` driver. Point V11 `ONEBOT_WS_URLS` or V12 `ONEBOT_V12_WS_URLS` at Matcha. |
| Reverse WebSocket (recommended) | Client; initiates the connection | V11 uses `ReverseDriver`; V12 uses an ASGI driver such as `DRIVER=~fastapi`. Matcha connects to NoneBot's listening address. |

For a reverse connection, select **WebSocket Client (Reverse Connection)** in Matcha and enter
NoneBot's `HOST`, `PORT`, and the appropriate path:

- OneBot V11: `/onebot/v11/ws`
- OneBot V12: `/onebot/v12/ws`

For example, if NoneBot listens on `127.0.0.1:8080`, the full V12 address is
`ws://127.0.0.1:8080/onebot/v12/ws`. If NoneBot has an Access Token configured, enter the same value
in Matcha. When the two processes run in different containers, virtual machines, or hosts, do not
use `127.0.0.1` to address the other process. Use a service name or address that Matcha can actually
reach. See the [NoneBot OneBot connection guide](https://onebot.adapters.nonebot.dev/docs/guide/setup/)
for the complete configuration.

### Milky

Milky is one protocol service rather than a choice between mutually exclusive connection modes.
Starting it always exposes these endpoints on Matcha's configured `host:port`:

- `http://host:port/api/<action>`: API called by consumers
- `ws://host:port/event`: event stream consumed over WebSocket

NoneBot's `nonebot-adapter-milky` can consume `/event` with `MILKY_CLIENTS`. For example, if Matcha
listens on `127.0.0.1:5700`:

```dotenv
DRIVER=~aiohttp+~fastapi
MILKY_CLIENTS='[{"host":"127.0.0.1","port":"5700","access_token":"the same Token as Matcha","secure":false}]'
```

WebHooks are optional additional event sinks; adding one does not disable `/event`. To exercise
NoneBot's `MILKY_WEBHOOK` consumer, add `http://127.0.0.1:8080/milky/` under Matcha's **Event
WebHooks**, then configure NoneBot with:

```dotenv
DRIVER=~aiohttp+~fastapi
MILKY_WEBHOOK='{"host":"127.0.0.1","port":"5700","access_token":"the same Token as Matcha","secure":false}'
```

The `MILKY_WEBHOOK` host and port point back to Matcha's API listener; they are not NoneBot's own
listening address. The configured token is used for API requests, `/event` connections, and WebHook
delivery. Matcha can serve `MILKY_CLIENTS` consumers and any number of WebHook destinations at the
same time. A consumer attached through both routes receives the same event twice, so that topology
should be intentional. The app reports **Serving** as soon as the API and event service is ready; it
does not wait for a consumer to connect before allowing simulated messages.

## Architecture

- `MatchaCore` contains the domain model and storage. Users, groups, and messages are persisted with
  SwiftData, while media uses content-addressed file storage. This module knows nothing about any
  wire protocol.
- `MatchaTransport` is the transport layer. Its WebSocket server and client and minimal HTTP/1.1
  server are all built on Network.framework.
- `MatchaProtocol` contains the protocol-neutral translation/session boundary and `PlatformService`.
- `MatchaOneBot` and `MatchaMilky` implement the protocol endpoints consumed by framework adapters.
- `MatchaLogging` provides typed application diagnostics written to OSLog, rotating JSON Lines files,
  and a bounded in-memory window. Log events cannot contain access tokens, message bodies, or raw
  protocol payloads.
- `MatchaUI` provides the SwiftUI and AppKit interface, including a dedicated application log
  console. Raw protocol traffic remains available in a separate inspector.
- `App/MatchaApplication.swift` 是 Xcode App target 的 composition root，负责应用生命周期、
  window scene 与 menu bar；其余实现仍由 SwiftPM modules 提供。

The key invariant lives in `PlatformService`: every state change passes through it, whether it was
triggered by a person pressing Send in the app or by a framework calling `send_group_message`.
Because both paths converge there, a connected framework cannot distinguish activity it caused from
activity initiated by the operator. This is what makes the simulation credible. Protocol encoders
subscribe to the event stream and never write state directly.

## Application Log Console

Open the standalone console with **Window > Log Console** (`⌥⌘L`). It supports searching and
filtering by event, level, and category; viewing and copying structured details; and clearing or
exporting the complete history. The in-memory window retains up to 1,000 records from the current
process. On-disk logs live in the application cache directory and use a 5 MiB active file with up to
five rotated files. Every export creates a unique directory at the chosen location containing raw
JSON Lines records and a structured summary, without overwriting previous exports.

## Build and Run

Matcha 要求 macOS 26 或更高版本，并需要完整安装 Xcode。仓库中的 `.xcode-version` 固定了
当前验证过的 Xcode 版本；Command Line Tools 不包含 SwiftData、SwiftUI 与 Swift Testing
所需的完整编译器插件。

```sh
open Matcha.xcodeproj
```

在 Xcode 中选择共享 scheme `Matcha App` 与运行目标 `My Mac`，然后使用 Run。Xcode App target
是 `.app` bundle、Info.plist、资源、签名和 Archive 的唯一来源；`Package.swift` 只定义应用
依赖的 Swift modules 与 package tests。

命令行构建使用同一个共享 scheme：

```sh
xcodes select
xcodebuild \
  -project Matcha.xcodeproj \
  -scheme "Matcha App" \
  -configuration Debug \
  -destination "platform=macOS" \
  build
```

`xcodes select` 会读取 `.xcode-version`。未使用 `xcodes` 时，可在 Xcode 的 Locations 设置中
选择相同版本，或为命令显式设置 `DEVELOPER_DIR`。

App Sandbox 当前保持关闭：协议端允许传入任意本机绝对文件路径作为消息附件，而 sandbox
无法在没有用户交互授权的情况下读取这些路径。若将来面向 Mac App Store 分发，需要先重新
设计该文件传输契约，不能只打开 sandbox 开关。

## Testing

```sh
swift test
```

测试由 SwiftPM 唯一拥有，以保留 package 内部的白盒测试边界。运行前同样需要让
`xcode-select` 或 `DEVELOPER_DIR` 指向完整 Xcode。

与真实 `nonebot-adapter-milky` 进程的联调测试默认禁用。启用时需显式提供
`MATCHA_LIVE_MILKY_API_PORT`、`MATCHA_LIVE_MILKY_TOKEN` 与
`MATCHA_LIVE_MILKY_SELF_ID`；WebHook 场景另需 `MATCHA_LIVE_MILKY_WEBHOOK_URL`，
WebSocket 场景则设置 `MATCHA_LIVE_MILKY_EXPECT_WEBSOCKET=1`。这些运行时值不会写入仓库。

## Dependencies

The project has no third-party dependencies. Persistence uses SwiftData; the interface uses SwiftUI
with narrowly scoped AppKit components; and networking, cryptography, and file type identification
use Network.framework, CryptoKit, and UniformTypeIdentifiers, respectively.
