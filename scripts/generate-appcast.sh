#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "Appcast: $*" >&2; exit 1; }
[[ "$#" == 2 ]] || fail "Usage: $0 path/to/Siniulator-VERSION-BUILD.dmg path/to/appcast.xml"
archive="$1"
output="$2"
[[ -f "$archive" && "$archive" == *.dmg ]] || fail "Expected an existing DMG archive."
[[ -z "${SPARKLE_PRIVATE_KEY:-}" || -z "${SPARKLE_PRIVATE_KEY_FILE:-}" ]] || fail "Use either SPARKLE_PRIVATE_KEY or SPARKLE_PRIVATE_KEY_FILE."
sparkle_tool="$project_root/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
[[ -x "$sparkle_tool" ]] || fail "Sparkle's generate_appcast tool was not found; run swift package resolve."
arguments=(--download-url-prefix https://updates.siniulator.app/ --maximum-versions 1 --maximum-deltas 0)
if [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
    [[ -r "$SPARKLE_PRIVATE_KEY_FILE" ]] || fail "SPARKLE_PRIVATE_KEY_FILE is not readable."
    arguments+=(--ed-key-file "$SPARKLE_PRIVATE_KEY_FILE")
elif [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    arguments+=(--ed-key-file -)
fi

# A fresh directory prevents old feed entries or delta references from surviving.
work_directory="$(mktemp -d "${TMPDIR:-/tmp}/siniulator-appcast.XXXXXX")"
trap 'rm -rf "$work_directory"' EXIT
archive_name="$(basename "$archive")"
cp "$archive" "$work_directory/$archive_name"
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$sparkle_tool" "${arguments[@]}" "$work_directory"
else
    "$sparkle_tool" "${arguments[@]}" "$work_directory"
fi
feed="$work_directory/appcast.xml"
[[ "$(xmllint --xpath 'count(/rss/channel/item)' "$feed")" == 1 ]] || fail "Expected exactly one update in the appcast."
[[ "$(xmllint --xpath "count(//*[local-name()='deltas'])" "$feed")" == 0 ]] || fail "The appcast must not contain delta updates."
archive_length="$(stat -f %z "$archive")"
valid_enclosures="$(xmllint --xpath "count(/rss/channel/item/enclosure[@url='https://updates.siniulator.app/$archive_name'][@length='$archive_length'][@*[local-name()='edSignature']!=''])" "$feed")"
[[ "$valid_enclosures" == 1 ]] || fail "The appcast is missing the signed full DMG enclosure."
mkdir -p "$(dirname "$output")"
cp "$feed" "$output"
printf 'Appcast ready (one full update, no deltas): %s\n' "$output"
