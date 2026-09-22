# Releasing Siniulator

`scripts/release.sh` builds, signs and notarizes an app and DMG, then generates
a signed Sparkle feed. It uploads submissions to Apple for notarization; download
artifacts stay local until you publish them. For an ad hoc local build, use
`scripts/build-app.sh` without release credentials.

The supported production path is the `Release` GitHub Actions workflow. It
creates a notarized universal DMG, a GitHub Release, an appcast whose enclosure
points at that release, and an Actions artifact named `appcast` for the updates
worker. The local instructions below remain useful for testing release tooling.

## Versioning policy

Pass the next stable semantic version (`MAJOR.MINOR.PATCH`) to the workflow. The
source plist intentionally contains `0.0.0` so local bundles identify themselves
as development builds. Do not edit it or create the tag first: the workflow
injects the release version into the built bundle and creates
`vMAJOR.MINOR.PATCH` only after every build and verification step succeeds.

The workflow fails before using secrets when:

- the version is not a three-part numeric version;
- its tag or GitHub Release already exists; or
- it is not greater than the highest stable version tag.

Published tags and release assets are immutable. Fixes therefore use a new patch
version instead of replacing an existing DMG. Sparkle orders updates by
`CFBundleVersion`, not by the marketing version. CI computes this build number as
`RELEASE_BUILD_NUMBER_BASE + github.run_number`; retries of the same run keep the
same number, and gaps caused by failed runs are harmless. Set the base once to at
least the greatest build number published before this workflow was introduced.
For this repository the initial value is `3`.

## GitHub Actions setup

Create a GitHub Environment named `release`. Configure any required reviewers
there, then add these environment variables under **Settings → Environments →
release → Environment variables**:

| Variable | Format |
| --- | --- |
| `APPLE_TEAM_ID` | The 10-character Apple Developer Team ID, for example `A1B2C3D4E5`. |
| `APPLE_API_KEY_ID` | The App Store Connect **team** API key ID. Individual keys cannot be used by `notarytool`. |
| `APPLE_API_ISSUER_ID` | The issuer UUID shown for the team API key. |
| `SPARKLE_PUBLIC_ED_KEY` | The 44-character Base64 public key printed by Sparkle `generate_keys`. This is public configuration, not a secret. |
| `RELEASE_BUILD_NUMBER_BASE` | Required; set it to `3` initially. Use a non-negative integer and never lower it while this workflow exists. |

Add these environment secrets in the same environment:

| Secret | Exact value to store |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | A single-line Base64 encoding of a `.p12` containing exactly one **Developer ID Application** certificate and its private key. |
| `MACOS_CERTIFICATE_PASSWORD` | The password used when exporting that `.p12`. |
| `APPLE_API_PRIVATE_KEY_P8` | The complete raw contents of the team API key `.p8`, including its `BEGIN PRIVATE KEY` and `END PRIVATE KEY` lines. |
| `SPARKLE_PRIVATE_ED_KEY` | The complete contents of the private-key file exported with Sparkle `generate_keys -x`. Keep the same key for every release. |

For example, produce the value for `MACOS_CERTIFICATE_P12` on macOS with:

```sh
base64 -i DeveloperIDApplication.p12 | tr -d '\n'
```

The built-in, short-lived `GITHUB_TOKEN` creates the tag and release; do not add a
personal access token for the build. The workflow pins all reusable GitHub
Actions to full commit SHAs, grants only release and attestation permissions, and
deletes the temporary Keychain even after failure.

## Triggering a release

Run the workflow on the default branch, either manually or from automation:

```sh
gh workflow run release.yml --ref main -f version=1.2.0
```

An external caller can use GitHub's workflow-dispatch REST endpoint with a GitHub
App or fine-grained token that has Actions write access:

```json
{
  "ref": "main",
  "inputs": {
    "version": "1.2.0"
  }
}
```

Do not bump the source plist, create a tag, or create a draft release beforehand.
On success, the workflow publishes:

- `Siniulator-VERSION-BUILD.dmg`, `appcast.xml`, `release.json`, and
  `SHA256SUMS` as assets of the immutable GitHub Release;
- an attestation for the DMG; and
- an Actions artifact named `appcast` containing `appcast.xml`, `release.json`,
  and `SHA256SUMS`, retained for 90 days.

## Updating `updates.siniulator.app`

The durable source for the worker is the `appcast.xml` GitHub Release asset. For
a public repository it is available at this stable URL after the release is
published:

```text
https://github.com/kmagiera/Siniulator/releases/latest/download/appcast.xml
```

Have the worker refresh after a successful `Release` workflow run or a
`release.published` webhook, validate that the response is XML, then replace the
served `/appcast.xml` atomically. The appcast already links to the versioned DMG
on GitHub, so the worker does not need to copy or proxy the binary. `release.json`
contains the exact `dmgUrl` and can also drive a redirect from the existing
`/Siniulator.dmg` download URL.

If the worker deliberately consumes Actions artifacts instead, select the
artifact named `appcast` from the latest successful run of `release.yml` and
unzip it. That API requires GitHub authentication and artifacts expire, which is
why the Release asset is preferable as the long-term source.

## Setup

Use Xcode 26 or later (including Icon Composer support), Node.js 20 or later, and
the [`create-dmg` npm package](https://github.com/sindresorhus/create-dmg):

```sh
npm install --global create-dmg@8.1.0
security find-identity -v -p codesigning
```

Install a Developer ID Application certificate **with its private key** in your
Keychain. Set `CODE_SIGN_IDENTITY` to its name or SHA-1. For CI, import the `.p12`
into a temporary Keychain, set `CODE_SIGN_KEYCHAIN`, and delete the Keychain in
a cleanup step. Keep certificate exports, passwords and private keys in a secret
store outside the repository.

Choose one notarization authentication method (in precedence order):

- `NOTARY_KEYCHAIN_PROFILE`, created with the command below.
- `NOTARY_KEY_PATH` and `NOTARY_KEY_ID`; also `NOTARY_ISSUER` for a team API key.
- `APPLE_ID`, `APPLE_TEAM_ID` and `APPLE_APP_SPECIFIC_PASSWORD`.

```sh
xcrun notarytool store-credentials siniulator-notary \
  --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID"
```

The command prompts for an app-specific password. If `APPLE_TEAM_ID` is supplied
for any authentication method, signing must use the same team.

Resolve Sparkle and create its update signing key once:

```sh
swift package resolve
.build/artifacts/sparkle/Sparkle/bin/generate_keys
```

Set `SPARKLE_PUBLIC_ED_KEY` to the printed public key, or commit it as
`SUPublicEDKey` in `Resources/Info.plist`. The environment variable takes precedence.
Sparkle stores the private key in the login Keychain under its default `ed25519`
account. Back it up outside the repository:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x /secure/path/sparkle-private-key
chmod 600 /secure/path/sparkle-private-key
```

For CI, set either `SPARKLE_PRIVATE_KEY_FILE` or `SPARKLE_PRIVATE_KEY` (passed to
Sparkle through stdin). With neither, Sparkle uses the Keychain. Keep the key
stable across releases; it is independent of Apple signing credentials. See
[Sparkle key management](https://sparkle-project.org/documentation/).

## Build and verify

Start with [.env.release.example](../.env.release.example), or inject its variables
from a secret store. Scripts do not load environment files automatically:

```sh
cp .env.release.example .env.release
# Edit .env.release before sourcing it.
set -a
source .env.release
set +a
scripts/release.sh
```

Set `RELEASE_VERSION` to a three-part version such as `0.1.0`, and `BUILD_NUMBER`
to a positive integer higher than the published release. `BUILD_ARCHS` defaults
to `arm64 x86_64` for releases; use `arm64` or `x86_64` for a single architecture.
`build-app.sh` defaults to the host architecture and accepts the same build,
version, public-key and code-signing variables.

Set `APPCAST_DOWNLOAD_URL_PREFIX` to an HTTPS URL ending in `/` when the DMG is
hosted somewhere other than `https://updates.siniulator.app/`. GitHub Actions
sets it to the versioned GitHub Release download path.

The release script:

1. Builds a fresh bundle with Sparkle, then signs helpers, framework and app from
   the inside out with Hardened Runtime and secure timestamps. Only the app
   disables library validation, to load Apple's simulator frameworks from Xcode.
2. Notarizes and staples the app, then checks its signature and Gatekeeper status.
3. Packages it in a drag-and-drop DMG, signs and notarizes the DMG, and staples it.
4. Generates a signed appcast containing one full DMG and no delta updates.
5. Verifies the final DMG and the app mounted from it before replacing the local
   feed and latest download, then writes SHA-256 checksums.

Signing, notarization, appcast and verification failures leave the previous feed
and latest download in place. Notarization
reports and rejection logs go to `build/release/`. `build-app.sh release` alone
does not notarize an app; use `release.sh` for distributed builds. To verify an
existing release independently:

```sh
scripts/verify-release.sh build/release/Siniulator.dmg
```
