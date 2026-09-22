#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
fail() { echo "Release: $*" >&2; exit 1; }
[[ "$#" == 0 ]] || fail "Usage: $0 (configure the release through environment variables)"
command -v create-dmg >/dev/null 2>&1 || fail "Install create-dmg with npm install --global create-dmg@8.1.0 (requires Node.js 20 or later)."
create_dmg_help="$(create-dmg --help)"
[[ "$create_dmg_help" == *--no-version-in-filename* ]] || fail "Use the create-dmg npm package from https://github.com/sindresorhus/create-dmg."
[[ -n "${CODE_SIGN_IDENTITY:-}" && "$CODE_SIGN_IDENTITY" != - ]] || fail "Set CODE_SIGN_IDENTITY to a Developer ID Application certificate name or SHA-1."
[[ "${RELEASE_VERSION:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Set RELEASE_VERSION to a version such as 0.1.0."
[[ "${BUILD_NUMBER:-}" =~ ^[1-9][0-9]*$ ]] || fail "Set BUILD_NUMBER to a positive integer that increases with each release."
public_key="${SPARKLE_PUBLIC_ED_KEY:-$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Resources/Info.plist 2>/dev/null || true)}"
[[ "$public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || fail "Set SPARKLE_PUBLIC_ED_KEY to the public key printed by Sparkle's generate_keys."
[[ -z "${SPARKLE_PRIVATE_KEY:-}" || -z "${SPARKLE_PRIVATE_KEY_FILE:-}" ]] || fail "Use either SPARKLE_PRIVATE_KEY or SPARKLE_PRIVATE_KEY_FILE."
if [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
    [[ -r "$SPARKLE_PRIVATE_KEY_FILE" ]] || fail "SPARKLE_PRIVATE_KEY_FILE must point to a readable exported Sparkle key."
fi

notary_arguments=()
if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    notary_arguments=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
elif [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
    [[ -r "$NOTARY_KEY_PATH" && -n "${NOTARY_KEY_ID:-}" ]] || fail "Set NOTARY_KEY_PATH and NOTARY_KEY_ID for App Store Connect authentication."
    notary_arguments=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID")
    if [[ -n "${NOTARY_ISSUER:-}" ]]; then notary_arguments+=(--issuer "$NOTARY_ISSUER"); fi
else
    [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]] || fail "Set NOTARY_KEYCHAIN_PROFILE, API key variables, or APPLE_ID / APPLE_TEAM_ID / APPLE_APP_SPECIFIC_PASSWORD."
    notary_arguments=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD")
fi
export SPARKLE_PUBLIC_ED_KEY="$public_key"
export BUILD_ARCHS="${BUILD_ARCHS:-arm64 x86_64}"
download_url_prefix="${APPCAST_DOWNLOAD_URL_PREFIX:-https://updates.siniulator.app/}"
release_directory="$project_root/build/release"
updates_directory="$release_directory/updates"
archive_name="Siniulator-$RELEASE_VERSION-$BUILD_NUMBER.dmg"
archive="$updates_directory/$archive_name"
[[ ! -e "$archive" ]] || fail "$archive_name already exists; use a new BUILD_NUMBER."
if [[ -f "$updates_directory/appcast.xml" ]]; then
    newer_updates="$(xmllint --xpath "count(/rss/channel/item[*[local-name()='version'] >= $BUILD_NUMBER])" "$updates_directory/appcast.xml")"
    [[ "$newer_updates" == 0 ]] || fail "BUILD_NUMBER must be greater than every version in the existing appcast."
fi
mkdir -p "$updates_directory"
work_directory="$(mktemp -d "${TMPDIR:-/tmp}/siniulator-release.XXXXXX")"
trap 'rm -rf "$work_directory"' EXIT

"$project_root/scripts/build-app.sh" release
app_directory="$project_root/build/Siniulator.app"
signature="$(codesign --display --verbose=4 "$app_directory" 2>&1)"
[[ "$signature" == *"Authority=Developer ID Application:"* ]] || fail "The app must be signed with a Developer ID Application certificate."

notarize() {
    local submission="$1" report="$2" status submission_id result=0
    xcrun notarytool submit "$submission" "${notary_arguments[@]}" --wait --output-format plist > "$report" || result=$?
    status="$(/usr/libexec/PlistBuddy -c 'Print :status' "$report" 2>/dev/null || true)"
    if [[ "$result" != 0 || "$status" != Accepted ]]; then
        submission_id="$(/usr/libexec/PlistBuddy -c 'Print :id' "$report" 2>/dev/null || true)"
        if [[ -n "$submission_id" ]]; then
            xcrun notarytool log "$submission_id" "${notary_arguments[@]}" "${report%.plist}.json" || true
        fi
        echo "Notarization failed (${status:-command error}); see $report and any accompanying JSON log." >&2
        return 1
    fi
}
# Staple the app before making the final DMG, so the installed app has its own ticket.
ditto -c -k --sequesterRsrc --keepParent "$app_directory" "$work_directory/Siniulator.zip"
notarize "$work_directory/Siniulator.zip" "$release_directory/notarization-app.plist"
xcrun stapler staple "$app_directory"
"$project_root/scripts/verify-release.sh" "$app_directory"

mkdir "$work_directory/dmg"
# Use the same drag-and-drop layout as SimCam. Signing stays here so the
# configured identity, Keychain, and secure timestamp apply to the final DMG.
create-dmg --overwrite --no-version-in-filename --dmg-title Siniulator --no-code-sign \
    "$app_directory" "$work_directory/dmg"
[[ -f "$work_directory/dmg/Siniulator.dmg" ]] || fail "create-dmg did not produce Siniulator.dmg."
mv "$work_directory/dmg/Siniulator.dmg" "$work_directory/$archive_name"
disk_sign_arguments=(--force --sign "$CODE_SIGN_IDENTITY" --timestamp)
if [[ -n "${CODE_SIGN_KEYCHAIN:-}" ]]; then disk_sign_arguments+=(--keychain "$CODE_SIGN_KEYCHAIN"); fi
codesign "${disk_sign_arguments[@]}" "$work_directory/$archive_name"
notarize "$work_directory/$archive_name" "$release_directory/notarization-dmg.plist"
xcrun stapler staple "$work_directory/$archive_name"
xcrun stapler validate "$work_directory/$archive_name"

# Generate in a staging directory; a missing or mismatched signing key must not
# replace the last working appcast or leave a half-finished release in updates/.
staged_updates="$work_directory/updates"
mkdir "$staged_updates"
cp "$work_directory/$archive_name" "$staged_updates/$archive_name"
"$project_root/scripts/generate-appcast.sh" "$staged_updates/$archive_name" "$staged_updates/appcast.xml"
archive_length="$(stat -f %z "$staged_updates/$archive_name")"
valid_enclosures="$(xmllint --xpath "count(/rss/channel/item[*[local-name()='version']='$BUILD_NUMBER']/enclosure[@url='$download_url_prefix$archive_name'][@length='$archive_length'][@*[local-name()='edSignature']!=''])" "$staged_updates/appcast.xml")"
[[ "$valid_enclosures" == 1 ]] || fail "The generated appcast is missing this release's signed enclosure; check the Sparkle key pair."
# Check the exact final bytes and the packaged app before replacing any release.
"$project_root/scripts/verify-release.sh" "$staged_updates/$archive_name"
# Keep old versioned archives available for clients with cached appcast URLs.
ditto "$staged_updates" "$updates_directory"
cp "$archive" "$release_directory/Siniulator.dmg"
(cd "$release_directory" && shasum -a 256 "updates/$archive_name" Siniulator.dmg > SHA256SUMS)
printf '\nRelease ready: %s\nThe appcast enclosure points to %s.\n' "$archive" "$download_url_prefix"
