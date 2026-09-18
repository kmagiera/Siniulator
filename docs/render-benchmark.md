# Render benchmark

```sh
scripts/benchmark-render.sh
```

Requires macOS, Metal and a full selected Xcode installation. The script builds
a separate optimized executable in `.build/benchmark` with
`-DSINIULATOR_BENCHMARK`. Normal builds contain no benchmark code. It does not
replace `build/Siniulator.app`, use a simulator or require an unlocked session.

## What it measures

A deterministic 1320×2868 BGRA IOSurface goes through the production
`MetalScreenEngine.texture(for:)` and `encode` methods. Cases cover window portrait
(600×1280), landscape (1280×600 at 90°), double resolution (1200×2560), and an
offscreen fullscreen-sized output (1920×1080).

Each of five rounds warms both Metal and the Core Image reference with 40 samples,
then alternates paths for 240 samples each. CPU timing measures command encoding;
GPU timing uses completed command-buffer timestamps. Reported p50/p95 values are
medians of per-round percentiles. Allocation, texture import, compilation, command
commit, waiting and correctness readback are outside CPU timing.

All four orientations are compared with Core Image, allowing mean device-image
RGB error below 4/255 after normalizing the readback origin. Letterboxing is
checked separately against Metal's clear color.

This is an offscreen render-engine benchmark. It does not measure frame delivery,
backpressure, drawable waits, WindowServer, vsync, FPS, input latency or native
fullscreen/Split View behavior.

## Baselines

`Benchmarks/Baselines/render.json` records a development-machine measurement.
Hardware, GPU, macOS, Xcode, power mode and workload must match. On another
machine, explicitly establish and select its own baseline:

```sh
scripts/benchmark-render.sh --record-baseline --baseline Benchmarks/Baselines/my-mac.json
scripts/benchmark-render.sh --baseline Benchmarks/Baselines/my-mac.json
```

Commit intentional baselines. Normal comparisons never replace them; recording
a new one accepts current performance. Run with stable power settings and little
background CPU/GPU activity.

Every case gates Metal CPU and GPU p50 and p95 independently. The default limit is
`baseline + max(baseline × 25%, absolute tolerance)`, with 0.003 ms CPU and 0.010 ms
GPU absolute tolerances. Core Image is context, not the historical baseline.

```sh
scripts/benchmark-render.sh --relative-threshold 15 --cpu-tolerance-ms 0.001 --gpu-tolerance-ms 0.005
scripts/benchmark-render.sh --measure-only
scripts/benchmark-render.sh --help
```

Changing `--samples`, `--warmup` or `--rounds` requires a matching baseline.
`--measure-only` collects data without comparing or changing a baseline.

## Results

Each run gets a unique folder under `build/benchmarks/`; `--output-dir PATH`
overrides it. The script replaces result files at the start to avoid stale passes.

| File | Contents |
| --- | --- |
| `render-performance.json` | Environment, cases, per-round timings and image checks |
| `render-performance.txt` | Readable measurements |
| `comparison.json` | Thresholds and regressions, for comparable runs |

Exit codes: `0` pass/baseline recorded/measure only; `1` regression or rendering
failure; `2` missing or incompatible baseline, or invalid configuration. A baseline
cannot be an output artifact. Archive JSON in CI and use a Mac with Metal and a
matching baseline; Linux cannot run this benchmark.

Tests cover tolerances, CPU/GPU regressions, missing or reordered cases,
environment mismatches, invalid timings and percentile aggregation:

```sh
swift test --scratch-path .build/benchmark-tests -Xswiftc -DSINIULATOR_BENCHMARK
```
