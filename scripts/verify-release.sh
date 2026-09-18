#!/bin/bash
set -euo pipefail
fail() { echo "Release verification: $*" >&2; exit 1; }
[[ "$#" == 1 ]] || fail "Usage: $0 path/to/Siniulator.app-or-dmg"
[[ -e "$1" ]] || fail "Artifact does not exist: $1"
artifact="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"

verify_signature() {
    local artifact="$1" signature
    shift
    codesign --verify --strict --verbose=2 "$@" "$artifact"
    signature="$(codesign --display --verbose=4 "$artifact" 2>&1)"
    [[ "$signature" == *"Authority=Developer ID Application:"* ]] || fail "Missing Developer ID Application signature: $artifact"
}

verify_app() {
    [[ -d "$1" ]] || fail "App bundle was not found: $1"
    verify_signature "$1" --deep
    xcrun stapler validate "$1"
    spctl --assess --type execute --verbose=2 "$1"
}

case "$artifact" in
    *.app)
        verify_app "$artifact"
        ;;
    *.dmg)
        verify_signature "$artifact"
        xcrun stapler validate "$artifact"
        spctl --assess --type open --context context:primary-signature --verbose=2 "$artifact"
        hdiutil verify "$artifact"

        # Inspect the app actually packaged in the DMG, including its own ticket.
        verification_directory="$(mktemp -d "${TMPDIR:-/tmp}/siniulator-verify-release.XXXXXX")"
        mount_directory="$verification_directory/volume"
        mkdir "$mount_directory"
        mounted=0
        cleanup() {
            if [[ "$mounted" == 1 ]]; then
                hdiutil detach "$mount_directory" >/dev/null || return 1
            fi
            rmdir "$mount_directory" "$verification_directory"
        }
        trap cleanup EXIT
        hdiutil attach "$artifact" -readonly -nobrowse -mountpoint "$mount_directory"
        mounted=1
        verify_app "$mount_directory/Siniulator.app"
        hdiutil detach "$mount_directory"
        mounted=0
        cleanup
        trap - EXIT
        ;;
    *) fail "Expected an .app bundle or .dmg image." ;;
esac
echo "PASS: Developer ID signature, stapled notarization, and Gatekeeper acceptance: $artifact"
