#!/bin/bash
set -euo pipefail
if [[ "$#" != 0 ]]; then
    echo "Usage: $0" >&2
    exit 1
fi
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
scripts/build-app.sh debug
output_directory="$(mktemp -d "$project_root/build/native-toolbar.XXXXXX")"
swift scripts/fixtures/ToolbarPointer.swift "$output_directory" > "$output_directory/pointer.log" 2>&1 &
pointer_pid=$!
trap 'kill "$pointer_pid" 2>/dev/null || true' EXIT
open -n -W build/Siniulator.app --stdout "$output_directory/app.log" --stderr "$output_directory/app-error.log" \
    --args -ApplePersistenceIgnoreState YES --toolbar-smoke --output-dir "$output_directory"
if wait "$pointer_pid"; then
    trap - EXIT
else
    trap - EXIT
    cat "$output_directory/app-error.log" >&2
    cat "$output_directory/pointer.log" >&2
    exit 1
fi
cat "$output_directory/toolbar-results.txt"
printf 'Artifacts: %s\n' "$output_directory"
