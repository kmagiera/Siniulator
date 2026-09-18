#!/bin/bash
set -euo pipefail
if [[ "$#" -lt 2 || "$#" -gt 3 || -z "$1" || -z "$2" ]]; then
    echo "Usage: $0 runtime-identifier device-type-identifier [output-directory]" >&2
    exit 1
fi
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
runtime="$1"
device_type="$2"
output_directory="${3:-$project_root/build/integration-results}"
mkdir -p "$output_directory"
output_directory="$(cd "$output_directory" && pwd)"
rm -f "$output_directory/exercise-success.txt"
: > "$output_directory/stdout.log"
: > "$output_directory/stderr.log"
./scripts/build-app.sh debug
./scripts/build-fixture.sh
test_device="$(xcrun simctl create 'Siniulator Integration QA' "$device_type" "$runtime")"
cleanup() {
    xcrun simctl shutdown "$test_device" >/dev/null 2>&1 || true
    xcrun simctl delete "$test_device" >/dev/null 2>&1 || true
}
trap cleanup EXIT
xcrun simctl boot "$test_device"
xcrun simctl bootstatus "$test_device" -b
xcrun simctl install "$test_device" build/InteractionQA.app
open -n -W --stdout "$output_directory/stdout.log" --stderr "$output_directory/stderr.log" \
    build/Siniulator.app --args -ApplePersistenceIgnoreState YES --exercise "$test_device" --output-dir "$output_directory"
cat "$output_directory/stdout.log" "$output_directory/stderr.log"
if [[ ! -f "$output_directory/exercise-success.txt" ]]; then
    echo "Integration test failed: the app exited without writing exercise-success.txt (it may have crashed)." >&2
    echo "App logs: $output_directory/stdout.log and $output_directory/stderr.log" >&2
    exit 1
fi
