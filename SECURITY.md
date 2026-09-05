# Security Policy

## Reporting a Vulnerability

Report suspected vulnerabilities through GitHub's
[private vulnerability reporting](https://github.com/Kiyorae/rei/security/advisories/new).
Do not open a public issue or pull request before the maintainers have assessed the report.

Include the affected Rei version and build number, macOS version and architecture, selected
protocol and transport, exposure configuration, reproduction steps, realistic impact, and any
suggested mitigation. Remove unrelated access tokens, message content, local file paths, and
personal data. If a proof of concept needs sensitive data, share only the minimum necessary through
the private advisory.

The maintainers will coordinate validation, remediation, and disclosure through the advisory.
Please allow a fix to be prepared before publishing details that would put users at risk.

## Supported Versions

Before the first release, security fixes are applied to `main`. After releases begin, the latest
published version and `main` receive security fixes; older releases are not maintained separately.

## System and Scope

Rei is a local macOS development tool that simulates a messaging platform for bot frameworks. It
accepts OneBot and Milky traffic, mutates locally persisted simulated state, reads or downloads
operator- or peer-selected attachments, emits events to connected peers and WebHook destinations,
and displays raw protocol traffic for debugging.

This policy covers the application in `App/`, all modules in `Sources/`, the Xcode and SwiftPM build
definitions, and the GitHub Actions release pipeline. Security defects in an external bot framework,
adapter, Apple framework, or the upstream Vue/Tauri project are outside this repository unless Rei
violates one of the boundaries below.

Important assets include access tokens, files readable by the current macOS user, simulated users,
groups and messages, exported diagnostics, Developer ID and notarization credentials, and the
integrity of published release artifacts.

## Threat Model and Trust Boundaries

- The local operator and processes already running as the same macOS user are trusted to configure
  Rei and access its local application data.
- Inbound HTTP and WebSocket peers are untrusted until they satisfy the configured access-token
  boundary. An authenticated peer is intentionally allowed to exercise the simulated platform's
  protocol capabilities, including attachment references.
- The default listener address is loopback and the default access token is empty. Selecting a
  routable listener address, port forwarding, or otherwise exposing Rei beyond the local machine
  is an explicit trust-boundary change and should be paired with a strong token and trusted network.
- Outbound WebSocket peers and Milky WebHook destinations are selected by the operator. Their
  responses, timing, certificates, and availability remain untrusted.
- Attachment references, JSON payloads, HTTP headers, WebSocket frames, and remote response bodies
  can be attacker-controlled whenever a peer can reach the relevant transport.
- Pull-request code is untrusted. Developer ID certificates and notarization keys belong only to the
  protected release environment and must never be exposed to pull-request jobs or build artifacts.

## Security Invariants

- When an access token is configured, every inbound action request and event-stream connection must
  authenticate before protocol handling. Missing, malformed, prefix-matching, or incorrect tokens
  must fail closed. An empty token is an explicit opt-out, not an authentication guarantee.
- An unauthenticated peer must not read local files, inspect simulated state, mutate the platform, or
  subscribe to events when a token is configured.
- Outbound WebHook redirects must not forward bearer credentials to a different destination.
- Hostile input must not cause memory corruption, code execution, path traversal writes, or
  unbounded resource consumption. Existing HTTP header and body limits must remain effective.
- Structured application logs must not contain access tokens, message bodies, raw protocol payloads,
  or private file paths. The separate raw-traffic inspector must remain local, bounded, and
  process-lifetime-only unless the operator explicitly exports other diagnostics.
- Release credentials must be short-lived in CI, removed before third-party artifact handling, and
  unavailable to pull requests. Published applications must be Universal 2, Developer ID-signed with
  Hardened Runtime and a secure timestamp, Apple-notarized and stapled, checksum-verified, and bound
  to an immutable tag on `main`.

## Reportable Findings and Severity Context

A finding is reportable when it crosses one of these boundaries with a realistic path in the
supported configuration. Examples include authentication bypass, unauthorized local-file
disclosure, credential leakage, attacker-controlled writes outside Rei's storage, memory or CPU
exhaustion reachable from an exposed listener, code execution, or substitution of release source or
artifacts.

Treat unauthenticated remote code execution, release-signing credential compromise, release artifact
substitution, and unauthorized arbitrary local-file access as high or critical depending on
reachability. Authorization bypass, persistent cross-session data disclosure, and remotely
triggerable denial of service are generally at least medium severity. Protocol compatibility defects
without a confidentiality, integrity, availability, or supply-chain impact are ordinary bugs.

## Out of Scope and Intended Behavior

- A peer that possesses the configured token is intentionally trusted with the protocol operations
  Rei exposes. Reports must demonstrate an additional boundary violation rather than only that an
  authorized framework can control the simulated platform.
- Reading an operator-selected or authenticated-peer-selected absolute attachment path is part of
  the current simulation contract. Bypassing authentication to read a path, writing outside the
  content-addressed asset store, or disclosing a file to an unintended peer remains reportable.
- Access by a process already running as the same macOS user is not treated as a sandbox boundary.
- The absence of App Sandbox, TLS on a deliberately local plaintext transport, or authentication
  when the operator explicitly leaves the token empty is not by itself a vulnerability. A hidden
  expansion of exposure or a bypass of a configured control is reportable.

These statements describe product boundaries; they do not suppress vulnerabilities that provide a
new capability, cross a configured boundary, or make the default local configuration unsafe.

## Known Limitations and Compensating Controls

- App Sandbox is disabled because supported protocols can refer to arbitrary local absolute paths.
  Loopback-by-default networking and access-token authentication are the primary boundary for that
  capability.
- Inbound protocol traffic and current reverse WebSocket connections use plaintext HTTP or
  WebSocket transport. Keep them on loopback or a trusted network; use an external authenticated,
  encrypted tunnel before crossing an untrusted network.
- Connection settings, including the access token, are currently stored in per-user `UserDefaults`
  rather than Keychain. Protect the macOS account and avoid reusing production credentials.
- The access token is empty by default for local setup. Configure a strong token before binding to a
  non-loopback address or forwarding the port.
- The raw-traffic inspector intentionally displays verbatim protocol payloads and retains up to 500
  entries in memory for the current process. Review the view before screen sharing and do not copy
  sensitive payloads into public reports.
- GitHub's standard workflow token cannot authoritatively query the repository's
  release-immutability setting before publication. The protected release environment records an
  operator confirmation, and the workflow verifies the immutable release immediately after
  publication. Repository administrators must treat the setting and confirmation variable as
  security-sensitive state.
