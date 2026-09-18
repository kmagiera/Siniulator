#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
if [[ "${1:-}" == "--help" ]]; then
    cat <<'HELP'
Usage: scripts/benchmark-render.sh [options]
  --baseline PATH            Baseline JSON (default: Benchmarks/Baselines/render.json)
  --record-baseline          Explicitly create or replace the baseline
  --measure-only             Measure without comparing or changing a baseline
  --output-dir PATH          Results folder (default: build/benchmarks/<UTC timestamp>)
  --samples N                Samples per round/path (default: 240, min: 100)
  --warmup N                 Warmup per round/path (default: 40, min: 20)
  --rounds N                 Odd number of rounds (default: 5, min: 3)
  --relative-threshold N     Allowed increase in percent (default: 25)
  --cpu-tolerance-ms N       Minimum allowed CPU increase (default: 0.003 ms)
  --gpu-tolerance-ms N       Minimum allowed GPU increase (default: 0.010 ms)

Exit: 0 = pass / baseline recorded / measure only; 1 = regression or render failure;
      2 = incompatible baseline or configuration.
Requires macOS, Metal and Xcode. No booted simulator or unlocked GUI is needed.
HELP
    exit 0
fi

# Keep benchmark compilation separate from the normal app and its running binary.
swift build --configuration release --scratch-path .build/benchmark -Xswiftc -DSINIULATOR_BENCHMARK
benchmark_binary_directory="$(swift build --configuration release --scratch-path .build/benchmark --show-bin-path)"
benchmark_output_directory="$project_root/build/benchmarks/$(date -u +%Y%m%dT%H%M%SZ)-$$"
"$benchmark_binary_directory/Siniulator" --benchmark \
    --baseline "$project_root/Benchmarks/Baselines/render.json" \
    --output-dir "$benchmark_output_directory" "$@"
