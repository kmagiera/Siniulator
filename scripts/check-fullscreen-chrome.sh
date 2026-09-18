#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
screen_index=0
test_appearance=system
expect_backdrop_variation=false
usage() { echo "Usage: $0 [screen-index] [--expect-backdrop-variation] [light|dark|system]" >&2; exit 1; }
if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
    screen_index="$1"
    shift
fi
if [[ "${1:-}" == --expect-backdrop-variation ]]; then
    expect_backdrop_variation=true
    shift
fi
if [[ "$#" -gt 0 ]]; then
    case "$1" in light|dark|system) test_appearance="$1" ;; *) usage ;; esac
    shift
fi
[[ "$#" == 0 ]] || usage
scripts/build-app.sh debug
output_directory="$(mktemp -d "$project_root/build/fullscreen-chrome.XXXXXX")"
swift scripts/fixtures/FullscreenPointer.swift "$output_directory" > "$output_directory/pointer.log" 2>&1 &
pointer_pid=$!
trap 'kill "$pointer_pid" 2>/dev/null || true' EXIT
open -n -W build/Siniulator.app --stdout "$output_directory/app.log" --stderr "$output_directory/app-error.log" \
    --args -ApplePersistenceIgnoreState YES --fullscreen-chrome-smoke --screen-index "$screen_index" --output-dir "$output_directory" --test-appearance "$test_appearance"
if wait "$pointer_pid"; then
    trap - EXIT
else
    trap - EXIT
    cat "$output_directory/app-error.log" >&2
    cat "$output_directory/pointer.log" >&2
    exit 1
fi
cat "$output_directory/fullscreen-chrome-results.txt"
if [[ -f "$output_directory/fullscreen-idle.png" ]]; then
    appearance_arguments=("$output_directory")
    if [[ "$expect_backdrop_variation" == true ]]; then
        appearance_arguments+=(--expect-backdrop-variation)
    fi
    swift scripts/fixtures/FullscreenAppearance.swift "${appearance_arguments[@]}"
fi
printf 'Artifacts: %s\n' "$output_directory"
