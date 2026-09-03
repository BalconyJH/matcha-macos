# Releasing

Matcha is distributed directly to users as a Developer ID-signed and Apple-notarized macOS
application. The current file-access contract requires App Sandbox to remain disabled, so this
pipeline does not produce a Mac App Store build.

## Release Metadata

`Configuration/Shared.xcconfig` is the source of truth for the public version and bundle build
number:

```xcconfig
CURRENT_PROJECT_VERSION = 1
MARKETING_VERSION = 0.1.0
```

`MARKETING_VERSION` must use `MAJOR.MINOR.PATCH`, and `CURRENT_PROJECT_VERSION` must be a positive
integer. The OneBot and Milky implementation-version responses currently mirror the public version
in source. `make project-check` rejects a release metadata change until all three values agree.

## Repository Configuration

Before the first release, enable **Release immutability** under the repository's release settings.
The workflow deliberately fails its final verification if GitHub does not report the published
release as immutable. Also create an active tag ruleset for `v*` that restricts tag updates and
deletions. Tag creation must remain available to `github-actions[bot]`; the automation never needs
permission to move or delete a tag.

Protect `main` with pull requests and require the single `Required Checks` status from `CI`. That
aggregate job fails unless formatting/project validation, SwiftPM tests, and the release build all
succeed, so the branch rule does not need to track each internal job name separately.

Create a protected GitHub environment named `release`. Restrict its deployment branch to `main`;
requiring a maintainer review and preventing self-review are strongly recommended. Configure these
environment variables:

- `APPLE_TEAM_ID`: Apple Developer team identifier
- `APPLE_NOTARY_KEY_ID`: App Store Connect API key identifier
- `APPLE_NOTARY_ISSUER_ID`: App Store Connect API issuer identifier
- `RELEASE_IMMUTABILITY_CONFIRMED`: literal `true`, set only after enabling repository release
  immutability

Configure these environment secrets:

- `APPLE_DEVELOPER_ID_CERTIFICATE_P12_BASE64`: base64-encoded Developer ID Application certificate
  and private key in PKCS #12 form
- `APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD`: password protecting that PKCS #12 file
- `APPLE_NOTARY_KEY_P8_BASE64`: base64-encoded App Store Connect API private key

For example, prepare the two encoded values locally without writing a second unencrypted copy:

```sh
base64 -i DeveloperIDApplication.p12 | pbcopy
base64 -i AuthKey_KEYID.p8 | pbcopy
```

Limit the API key and certificate to the release environment, rotate them according to the team's
credential policy, and never use personal signing material in pull-request workflows.

GitHub does not grant a workflow `GITHUB_TOKEN` the Administration permission required to query the
repository's immutability setting before publication. The confirmation variable and protected
environment review are therefore the pre-publication guard; the workflow additionally checks the
published Release's `immutable` field and fails loudly if an administrator disabled the setting
after confirmation. That post-publication failure cannot retroactively prevent a brief mutable
release, so treat changes to the setting or confirmation variable as security-sensitive repository
administration.

CI and release packaging run on GitHub's stable `macos-26` image and explicitly select Xcode 26.6.
The repository gate accepts Xcode 26.6 or newer when it provides a macOS 26 or newer SDK, so local
Xcode 27 compatibility testing does not require a metadata change. `.xcode-version` is the
recommended local selection, not an equality constraint. GitHub runner images still change over
time; use a controlled self-hosted runner if release reproduction requires a fully frozen host image.

## Automatic Release

1. Update `MARKETING_VERSION`, increment `CURRENT_PROJECT_VERSION`, and update both protocol version
   mirrors in one pull request.
2. Run `./script/check.sh` and merge only after `Required Checks` succeeds.
3. CI validates the resulting `main` commit.
4. `Auto Tag` creates an immutable annotated `vMAJOR.MINOR.PATCH` tag when that version has not been
   tagged before.
5. The `Release` workflow validates the tag against current `main`, waits for any configured
   `release` environment approval, then builds a Universal 2 archive.
6. The workflow exports with a Developer ID Application identity, submits the app and disk image to
   Apple's notary service, staples both tickets, validates Gatekeeper policy, and publishes the
   GitHub Release.

When `main` still declares an already-tagged version, `Auto Tag` succeeds without moving the tag or
publishing again. A version bump is therefore the explicit release decision.

## Release Artifacts

Each GitHub Release contains:

- `Matcha-vMAJOR.MINOR.PATCH.zip`, containing the stapled application bundle
- `Matcha-vMAJOR.MINOR.PATCH.dmg`, a signed, notarized, and stapled drag-to-Applications image
- `SHA256SUMS`, covering the ZIP and DMG

The matching dSYM archive and notarization logs are retained as restricted workflow artifacts for
maintainer diagnostics. GitHub also records build provenance attestations for public release assets.

After downloading a release, verify it with:

```sh
shasum -a 256 -c SHA256SUMS
gh attestation verify Matcha-v0.1.0.zip --repo BalconyJH/matcha-macos
spctl --assess --type execute --verbose=4 /path/to/Matcha.app
```

## Recovery

Tags are immutable. Automation never moves or replaces an existing tag.

If automatic tagging was interrupted before creating a tag, run `Auto Tag` manually from `main`.
The optional `source_sha` must be the current full `main` commit SHA. If a valid tag exists but
packaging or GitHub Release publication failed, run `Release` manually from `main` and provide that
tag. The release workflow validates that the tag is on `main`, matches the configured version, and
resolves to the expected source before using release credentials.

Signing timestamps, notarization tickets, and disk-image metadata make a fresh build intentionally
non-reproducible byte-for-byte. Cross-run recovery therefore never mixes assets from two builds. If
an earlier run left a workflow-owned draft containing only the expected asset names, the recovery
run replaces the complete draft asset set with its newly verified ZIP, DMG, and checksum manifest.
An unexpected draft asset or metadata owner fails closed. Once a release is published and immutable,
a recovery run verifies its exact asset set, GitHub digests, checksum manifest, and source marker,
then exits without changing it. Rerunning only a failed publish job remains the fastest recovery
because it reuses that run's retained workflow artifact.

Duplicate runs for the same tag are serialized. Publication asks GitHub to determine `Latest` using
its legacy date-and-semantic-version policy rather than forcing an older recovered version to become
latest. Automation never creates a second release, changes a published asset, or moves a tag.
