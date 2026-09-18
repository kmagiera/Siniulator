#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$#" != 1 || ! -d "$1/Contents/Frameworks/Sparkle.framework" ]]; then
    echo "Usage: $0 path/to/Siniulator.app (including Sparkle.framework)" >&2
    exit 1
fi
app_directory="$1"
identity="${CODE_SIGN_IDENTITY:--}"
sign_arguments=(--force --sign "$identity")
if [[ "$identity" != - ]]; then
    sign_arguments+=(--options runtime --timestamp)
    if [[ -n "${CODE_SIGN_KEYCHAIN:-}" ]]; then
        sign_arguments+=(--keychain "$CODE_SIGN_KEYCHAIN")
    fi
fi
sparkle="$app_directory/Contents/Frameworks/Sparkle.framework/Versions/Current"
# Sign from the inside out. Downloader's sandbox entitlements belong only to it.
codesign "${sign_arguments[@]}" "$sparkle/XPCServices/Installer.xpc"
codesign "${sign_arguments[@]}" --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
codesign "${sign_arguments[@]}" "$sparkle/Autoupdate"
codesign "${sign_arguments[@]}" "$sparkle/Updater.app"
codesign "${sign_arguments[@]}" "$app_directory/Contents/Frameworks/Sparkle.framework"
if [[ "$identity" != - ]]; then
    codesign "${sign_arguments[@]}" --entitlements "$project_root/Resources/Release.entitlements" "$app_directory"
else
    codesign "${sign_arguments[@]}" "$app_directory"
fi
codesign --verify --deep --strict --verbose=2 "$app_directory"
if [[ -n "${APPLE_TEAM_ID:-}" && "$identity" != - ]]; then
    actual_team="$(codesign --display --verbose=4 "$app_directory" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    if [[ "$actual_team" != "$APPLE_TEAM_ID" ]]; then
        echo "Signing certificate does not belong to APPLE_TEAM_ID." >&2
        exit 1
    fi
fi
