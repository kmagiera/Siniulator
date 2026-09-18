#!/bin/bash
set -euo pipefail
if [[ "$#" != 0 ]]; then
    echo "Usage: $0" >&2
    exit 1
fi
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
scripts/build-app.sh debug
output_directory="$(mktemp -d "$project_root/build/rotation.XXXXXX")"
open -n -W build/Siniulator.app --stdout "$output_directory/app.log" --stderr "$output_directory/app-error.log" \
    --args -ApplePersistenceIgnoreState YES --rotation-smoke --output-dir "$output_directory"
if [[ ! -f "$output_directory/rotation-results.txt" ]]; then
    cat "$output_directory/app-error.log" >&2
    exit 1
fi
cat "$output_directory/rotation-results.txt"
printf 'Artifacts: %s\n' "$output_directory"
