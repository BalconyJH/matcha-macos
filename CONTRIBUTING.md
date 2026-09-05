# Contributing

Contributions are welcome through GitHub issues and pull requests.

## Development Setup

Requirements:

- macOS 26.2 or later
- Xcode 26.6 or later with the macOS 26 SDK
- GNU Make, included with Xcode Command Line Tools

Select a compatible full Xcode installation before building. With `xcodes` installed, run
`xcodes select` to choose the recommended stable version from `.xcode-version`; otherwise set
`DEVELOPER_DIR` to any Xcode 26.6-or-newer application's `Contents/Developer` directory. Command
Line Tools alone are not sufficient. Required CI uses stable Xcode 26.6, while newer Xcode versions
remain valid for local compatibility testing.

Run the complete repository gate before opening a pull request:

```sh
./script/check.sh
```

The same checks are available separately when iterating on one layer:

```sh
make quality
make test
make build
make analyze
```

`make test` runs the SwiftPM test target. `make build` and `make analyze` exercise the Xcode
application target as an unsigned Universal 2 Release build. Neither command creates a
distribution-ready application.

Apply repository formatting with `make format`, then rerun the complete gate.

## Change Guidelines

- Preserve the boundary between `ReiCore`, transports, protocol implementations, and UI code.
- Add regression tests for fixes and tests for new protocol behavior.
- Keep OneBot and Milky wire behavior compatible with their documented protocol versions.
- Avoid unrelated formatting and generated Xcode user-state changes.
- Never commit access tokens, signing certificates, private keys, provisioning profiles, or real
  message data.
- Update README, release, or security documentation when requirements or trust boundaries change.

Live Milky interoperability tests remain opt-in. Follow the environment-variable instructions in
README and never commit those runtime values.

## Pull Requests

Keep each pull request focused and describe the resulting behavior. Include the commands and manual
checks actually used for validation. The `Required Checks` CI job must pass before merge.

Security vulnerabilities must follow [SECURITY.md](SECURITY.md) instead of the public issue or
pull-request workflow.
