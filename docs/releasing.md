# Releasing Siniulator

`scripts/release.sh` builds, signs and notarizes an app and DMG, then generates
a signed Sparkle feed. It uploads submissions to Apple for notarization; download
artifacts stay local until you publish them. For an ad hoc local build, use
`scripts/build-app.sh` without release credentials.

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
