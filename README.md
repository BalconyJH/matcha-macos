# Matcha for macOS

Matcha is a development tool that simulates a chat platform. It presents itself as QQ: the bot
framework under test connects to it as if it were a real platform, while you use the app to send
messages as any identity, create groups, and send friend requests. The framework receives the same
events and action responses it would receive in production. No real account is required, there is no
risk-control system to worry about, and you do not need another person to help reproduce an issue.

Matcha for macOS is an independent native macOS rewrite of
[A-kirami/matcha](https://github.com/A-kirami/matcha), originally created by Akirami. The upstream
project uses Vue and Tauri; this implementation uses AppKit and SwiftUI and depends only on Apple
system frameworks.

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
- `App/MatchaApplication.swift` is the composition root for the Xcode application target. It owns
  the application lifecycle, window scenes, and menu bar; the remaining implementation stays in
  SwiftPM modules.

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

### Prerequisites

- macOS 26 or later.
- A full installation of the Xcode version specified by `.xcode-version` (currently Xcode 27.0
  beta 6). Command Line Tools alone do not include the complete macOS SDK and Swift compiler
  plugins required by this project.
- Optionally, install `xcodes` to select Xcode from the repository's version file.

### Select the Xcode Toolchain

With `xcodes` installed, run the following commands from the repository root:

```sh
xcodes select
xcodebuild -version
```

`xcodes select` reads `.xcode-version`. Without `xcodes`, select the same version under
**Xcode > Settings > Locations > Command Line Tools**, or set the full Xcode path for the current
shell. Adjust the path to match the local installation:

```sh
export DEVELOPER_DIR="/Applications/Xcode-27.0.0-Beta.6.app/Contents/Developer"
xcodebuild -version
```

If `xcodebuild` reports `/Library/Developer/CommandLineTools` as the active developer directory,
the standalone Command Line Tools are still selected. Select the full Xcode installation before
continuing.

### Build and Run with Xcode

Open the project with the selected Xcode installation:

```sh
xed Matcha.xcodeproj
```

Select the shared `Matcha App` scheme and the `My Mac` destination, then choose
**Product > Run** (`⌘R`). The Xcode application target is the sole source of the `.app` bundle,
Info.plist, resources, signing, and archives. `Package.swift` defines the Swift modules and package
tests used by the application, so `swift run` does not produce a runnable Matcha app.

### Build and Run from the Command Line

The command-line build uses the same shared scheme and places Derived Data in a deterministic,
Git-ignored directory:

```sh
xcodebuild \
  -project Matcha.xcodeproj \
  -scheme "Matcha App" \
  -configuration Debug \
  -destination "generic/platform=macOS" \
  -derivedDataPath .build/xcode \
  build
```

After a successful build, launch the app with:

```sh
open .build/xcode/Build/Products/Debug/Matcha.app
```

Debug builds use local ad-hoc signing and do not require an Apple Developer account. For a Release
build, change `-configuration Debug` to `-configuration Release`; the result is written to
`.build/xcode/Build/Products/Release/Matcha.app`. Distribution builds should be archived through
**Product > Archive** in Xcode and configured with the appropriate signing and notarization.

App Sandbox is currently disabled because protocol clients may provide arbitrary local absolute
paths for message attachments. A sandboxed app cannot read those paths without user-mediated
authorization. Supporting Mac App Store distribution would therefore require redesigning the file
transfer contract rather than merely enabling the sandbox.

## Quality Checks

The repository uses `swift format` from the selected Xcode toolchain. Its complete rule set is
checked into `.swift-format`. Run the unified quality gate from the repository root:

```sh
./script/check.sh
```

The script runs strict formatting checks, the SwiftPM test suite with warnings treated as errors,
and a complete macOS application build with warnings treated as errors. It stops at the first
failure.

To apply formatting changes, run:

```sh
swift format format \
  --configuration .swift-format \
  --in-place \
  --parallel \
  --recursive \
  Package.swift App Sources Tests
```

The command lists source roots explicitly to avoid generated files under `.build`. Run
`./script/check.sh` again after formatting.

## Testing

```sh
swift test
```

The test suite lives in SwiftPM to preserve white-box access to package internals. This command
builds only SwiftPM modules and tests; it does not produce an `.app` bundle. Ensure that
`xcode-select` or `DEVELOPER_DIR` points to the full Xcode installation before running it.

Live interoperability tests against a real `nonebot-adapter-milky` process are disabled by
default. Enable them by setting `MATCHA_LIVE_MILKY_API_PORT`, `MATCHA_LIVE_MILKY_TOKEN`, and
`MATCHA_LIVE_MILKY_SELF_ID`. WebHook scenarios also require `MATCHA_LIVE_MILKY_WEBHOOK_URL`;
WebSocket scenarios require `MATCHA_LIVE_MILKY_EXPECT_WEBSOCKET=1`. These runtime values are never
written to the repository.

## Dependencies

The project has no third-party dependencies. Persistence uses SwiftData; the interface uses SwiftUI
with narrowly scoped AppKit components; and networking, cryptography, and file type identification
use Network.framework, CryptoKit, and UniformTypeIdentifiers, respectively.

## License

Matcha for macOS is distributed under the [GNU Affero General Public License v3.0](LICENSE). The
original [Matcha](https://github.com/A-kirami/matcha) project's code is Copyright © 2023 Akirami and
is licensed under the GNU AGPL v3.0; its logo is separately licensed under CC BY-NC-ND.
