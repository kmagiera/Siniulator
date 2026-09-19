#!/bin/bash
set -euo pipefail
if [[ "$#" != 0 ]]; then
    echo "Usage: $0" >&2
    exit 1
fi
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
scripts/build-app.sh debug
output_directory="$(mktemp -d "$project_root/build/duo.XXXXXX")"
launch_arguments=(-n -W build/Siniulator.app)
if [[ -n "${DEVELOPER_DIR:-}" ]]; then launch_arguments+=(--env "DEVELOPER_DIR=$DEVELOPER_DIR"); fi
open "${launch_arguments[@]}" --stdout "$output_directory/app.log" --stderr "$output_directory/app-error.log" \
    --args -ApplePersistenceIgnoreState YES --duo-smoke --output-dir "$output_directory"
if [[ ! -f "$output_directory/duo-results.txt" ]]; then
    cat "$output_directory/app-error.log" >&2
    exit 1
fi
cat "$output_directory/duo-results.txt"
printf 'Artifacts: %s\n' "$output_directory"
