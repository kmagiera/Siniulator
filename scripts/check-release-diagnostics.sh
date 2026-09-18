#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
verification_directory="$(mktemp -d "${TMPDIR:-/tmp}/siniulator-release-diagnostics.XXXXXX")"
trap 'rm -rf "$verification_directory"' EXIT

# Inspect actual binaries, so a missing guard in another source file fails too.
swift build --configuration debug
debug_binary_directory="$(swift build --configuration debug --show-bin-path)"
swift build --configuration release
release_binary_directory="$(swift build --configuration release --show-bin-path)"

xcrun nm -j "$debug_binary_directory/Siniulator" > "$verification_directory/debug-symbols.txt"
xcrun swift-demangle < "$verification_directory/debug-symbols.txt" > "$verification_directory/debug-demangled.txt"
if ! rg -q 'Siniulator\.Diagnostics' "$verification_directory/debug-demangled.txt"; then
    echo "FAIL: Debug binary does not contain the expected diagnostics" >&2
    exit 1
fi
xcrun nm -j "$release_binary_directory/Siniulator" > "$verification_directory/release-symbols.txt"
xcrun swift-demangle < "$verification_directory/release-symbols.txt" > "$verification_directory/release-demangled.txt"
if rg -n 'Siniulator\.(Diagnostics|PerformanceDiagnostics|Benchmark[A-Za-z]+|SimulatorScreenView\.screenshot|SimulatorInput\.transportName|SimulatorControlBar\.presentedTitleFrame|AppDelegate\.(launchDiagnosticsIfRequested|isDiagnostic))' "$verification_directory/release-demangled.txt"; then
    echo "FAIL: diagnostic or benchmark code is present in the normal Release binary" >&2
    exit 1
fi
strings "$release_binary_directory/Siniulator" > "$verification_directory/release-strings.txt"
if rg -n -- '--(probe|exercise|smoke|presentation-smoke|window-controls-smoke|fullscreen-chrome-smoke|toolbar-smoke|rotation-smoke|recording-smoke|startup-smoke|test-appearance|open-all|benchmark)([[:space:]]|$)' "$verification_directory/release-strings.txt"; then
    echo "FAIL: a diagnostic launch flag is present in the normal Release binary" >&2
    exit 1
fi
echo "PASS: Debug includes diagnostics; normal Release contains no diagnostic/benchmark symbols or launch flags"
