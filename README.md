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

### 前置条件

- macOS 26 或更高版本。
- 完整安装 `.xcode-version` 指定的 Xcode（当前为 Xcode 27.0 beta 6）。仅安装 Command Line
  Tools 不足以提供所需的完整 macOS SDK 与 Swift 编译器插件。
- 可选安装 `xcodes`，用于按仓库版本文件选择 Xcode。

### 选择 Xcode 工具链

若已安装 `xcodes`，在仓库根目录运行：

```sh
xcodes select
xcodebuild -version
```

`xcodes select` 会读取 `.xcode-version`。若不使用 `xcodes`，可以在 Xcode 的
**Settings > Locations > Command Line Tools** 中选择相同版本，或只为当前 shell 指定完整
Xcode；路径需与本机安装位置一致：

```sh
export DEVELOPER_DIR="/Applications/Xcode-27.0.0-Beta.6.app/Contents/Developer"
xcodebuild -version
```

若 `xcodebuild` 报告当前 developer directory 是 `/Library/Developer/CommandLineTools`，说明
仍在使用独立的 Command Line Tools，需要先完成上述选择。

### 使用 Xcode 构建与运行

使用所选版本的 Xcode 打开工程：

```sh
xed Matcha.xcodeproj
```

选择共享 scheme `Matcha App` 与运行目标 `My Mac`，然后使用 **Product > Run**（`⌘R`）。
Xcode App target 是 `.app` bundle、Info.plist、资源、签名和 Archive 的唯一来源；
`Package.swift` 只定义应用依赖的 Swift modules 与 package tests，因此 `swift run` 不会生成
可运行的 Matcha App。

### 使用命令行构建与运行

命令行构建使用同一个共享 scheme，并将 Derived Data 放入已被 Git 忽略的固定目录：

```sh
xcodebuild \
  -project Matcha.xcodeproj \
  -scheme "Matcha App" \
  -configuration Debug \
  -destination "generic/platform=macOS" \
  -derivedDataPath .build/xcode \
  build
```

构建成功后运行：

```sh
open .build/xcode/Build/Products/Debug/Matcha.app
```

Debug 构建使用本地 ad-hoc 签名，无需 Apple Developer 账号。Release 构建需将
`-configuration Debug` 改为 `-configuration Release`；产物位于
`.build/xcode/Build/Products/Release/Matcha.app`。用于分发时应通过 Xcode 的
**Product > Archive** 生成 archive，并配置相应的签名与公证流程。

App Sandbox 当前保持关闭：协议端允许传入任意本机绝对文件路径作为消息附件，而 sandbox
无法在没有用户交互授权的情况下读取这些路径。若将来面向 Mac App Store 分发，需要先重新
设计该文件传输契约，不能只打开 sandbox 开关。

## Quality Checks

仓库使用所选 Xcode 工具链内置的 `swift format`，规则固定在 `.swift-format`。在仓库根目录
运行统一检查入口：

```sh
./script/check.sh
```

该脚本依次执行严格格式检查、启用 warnings-as-errors 的 SwiftPM 测试，以及启用
warnings-as-errors 的完整 macOS App 构建。任一步失败都会立即停止。

需要写回格式时，显式运行：

```sh
swift format format \
  --configuration .swift-format \
  --in-place \
  --parallel \
  --recursive \
  Package.swift App Sources Tests
```

命令刻意只列出源码入口，避免递归扫描 `.build` 中的生成文件。格式化后应再次运行
`./script/check.sh`。

## Testing

```sh
swift test
```

测试由 SwiftPM 唯一拥有，以保留 package 内部的白盒测试边界。该命令只构建 SwiftPM
modules 与测试，不生成 `.app` bundle。运行前同样需要让 `xcode-select` 或
`DEVELOPER_DIR` 指向完整 Xcode。

与真实 `nonebot-adapter-milky` 进程的联调测试默认禁用。启用时需显式提供
`MATCHA_LIVE_MILKY_API_PORT`、`MATCHA_LIVE_MILKY_TOKEN` 与
`MATCHA_LIVE_MILKY_SELF_ID`；WebHook 场景另需 `MATCHA_LIVE_MILKY_WEBHOOK_URL`，
WebSocket 场景则设置 `MATCHA_LIVE_MILKY_EXPECT_WEBSOCKET=1`。这些运行时值不会写入仓库。

## Dependencies

The project has no third-party dependencies. Persistence uses SwiftData; the interface uses SwiftUI
with narrowly scoped AppKit components; and networking, cryptography, and file type identification
use Network.framework, CryptoKit, and UniformTypeIdentifiers, respectively.
