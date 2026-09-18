#if SINIULATOR_BENCHMARK
import Foundation

struct BenchmarkError: LocalizedError {
    let message: String
    var exitCode: Int32 = 2
    var errorDescription: String? { message }
}

struct BenchmarkConfiguration: Codable, Equatable {
    var samples = 240
    var warmup = 40
    var rounds = 5
    var fixture = "bgra-gradient-checker-v1"
    var sourceWidth = 1320
    var sourceHeight = 2868

    var isValid: Bool {
        (100...10000).contains(samples) && (20...1000).contains(warmup) &&
        (3...21).contains(rounds) && !rounds.isMultiple(of: 2) &&
        sourceWidth > 1 && sourceHeight > 1 && !fixture.isEmpty
    }
}

struct BenchmarkEnvironment: Codable, Equatable {
    let hardwareModel: String
    let gpu: String
    let os: String
    let xcode: String
    let lowPowerMode: Bool
    let buildConfiguration: String
}

struct BenchmarkRound: Codable {
    let p50Ms: Double
    let p95Ms: Double
}

struct BenchmarkDistribution: Codable {
    let p50Ms: Double
    let p95Ms: Double
    let rounds: [BenchmarkRound]

    static func percentile(_ samples: [Double], _ fraction: Double) -> Double {
        precondition(!samples.isEmpty && (0...1).contains(fraction))
        let sorted = samples.sorted()
        return sorted[max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)]
    }
    init(rounds: [BenchmarkRound]) {
        self.rounds = rounds
        p50Ms = Self.percentile(rounds.map(\.p50Ms), 0.5)
        p95Ms = Self.percentile(rounds.map(\.p95Ms), 0.5)
    }
}

struct BenchmarkTimings: Codable {
    let cpuEncode: BenchmarkDistribution
    let gpuExecute: BenchmarkDistribution
}

struct BenchmarkCaseResult: Codable {
    let name: String
    let width: Int
    let height: Int
    let quarterTurns: Int
    let metal: BenchmarkTimings
    let coreImage: BenchmarkTimings
}

struct BenchmarkImageCheck: Codable {
    let quarterTurns: Int
    let meanRGBDifference: Double
}

struct BenchmarkReport: Codable {
    let schemaVersion: Int
    let createdAt: String
    let environment: BenchmarkEnvironment
    let configuration: BenchmarkConfiguration
    let cases: [BenchmarkCaseResult]
    let imageChecks: [BenchmarkImageCheck]

    var text: String {
        var result = "Offscreen IOSurface render benchmark; deterministic \(configuration.fixture), \(configuration.sourceWidth)×\(configuration.sourceHeight).\n"
        result += "\(configuration.rounds) rounds × \(configuration.samples) samples, \(configuration.warmup) warmup samples per path/round. Reported percentiles are medians of round percentiles.\n"
        result += "\(environment.hardwareModel), \(environment.gpu), \(environment.os), \(environment.xcode.replacingOccurrences(of: "\n", with: "; ")), low power: \(environment.lowPowerMode).\n"
        result += "No FPS, compositor, frame notification or input-to-display latency measurement.\n"
        for item in cases {
            result += "\n\(item.name): \(item.width)×\(item.height), rotation \(item.quarterTurns)\n"
            for (label, timing) in [("Direct Metal", item.metal), ("Core Image reference", item.coreImage)] {
                result += String(format: "  %@: CPU p50 %.4f / p95 %.4f ms; GPU p50 %.4f / p95 %.4f ms\n", label,
                    timing.cpuEncode.p50Ms, timing.cpuEncode.p95Ms, timing.gpuExecute.p50Ms, timing.gpuExecute.p95Ms)
            }
        }
        for check in imageChecks {
            result += String(format: "Orientation %d: content mean RGB difference %.3f / 255; letterbox check passed\n", check.quarterTurns, check.meanRGBDifference)
        }
        return result
    }
}

struct BenchmarkPolicy: Codable {
    var relativeThreshold = 0.25
    var cpuToleranceMs = 0.003
    var gpuToleranceMs = 0.010
}

struct BenchmarkRegression: Codable {
    let caseName: String
    let metric: String
    let baselineMs: Double
    let currentMs: Double
    let limitMs: Double
}

struct BenchmarkComparison: Codable {
    let baselinePath: String
    let policy: BenchmarkPolicy
    let regressions: [BenchmarkRegression]

    static func compare(current: BenchmarkReport, baseline: BenchmarkReport, policy: BenchmarkPolicy) throws -> [BenchmarkRegression] {
        guard current.schemaVersion == 1, baseline.schemaVersion == current.schemaVersion else {
            throw BenchmarkError(message: "Incompatible benchmark schema. Record a new baseline explicitly.")
        }
        guard current.environment == baseline.environment else {
            throw BenchmarkError(message: "Hardware, GPU, macOS, Xcode, power mode or build configuration differs from baseline. Use a separate baseline for this environment.")
        }
        guard current.configuration.isValid, current.configuration == baseline.configuration else {
            throw BenchmarkError(message: "Benchmark fixture or sample configuration differs from baseline.")
        }
        guard !current.cases.isEmpty, Set(current.cases.map(\.name)).count == current.cases.count,
              Set(baseline.cases.map(\.name)).count == baseline.cases.count,
              Set(current.cases.map(\.name)) == Set(baseline.cases.map(\.name)),
              [current, baseline].allSatisfy({ report in
                  Set(report.imageChecks.map(\.quarterTurns)) == Set(0..<4) && report.imageChecks.count == 4 &&
                  report.imageChecks.allSatisfy({ $0.meanRGBDifference.isFinite && $0.meanRGBDifference >= 0 && $0.meanRGBDifference < 4 })
              }),
              policy.relativeThreshold.isFinite, policy.relativeThreshold >= 0,
              policy.cpuToleranceMs.isFinite, policy.cpuToleranceMs >= 0,
              policy.gpuToleranceMs.isFinite, policy.gpuToleranceMs >= 0 else {
            throw BenchmarkError(message: "Missing, duplicate or invalid benchmark cases, quality checks or thresholds.")
        }
        var regressions: [BenchmarkRegression] = []
        for item in current.cases {
            let previous = baseline.cases.first { $0.name == item.name }!
            guard item.width > 0, item.height > 0, (0..<4).contains(item.quarterTurns),
                  item.width == previous.width, item.height == previous.height, item.quarterTurns == previous.quarterTurns else {
                throw BenchmarkError(message: "Render dimensions or orientation changed for \(item.name).")
            }
            for candidate in [item, previous] {
                for distribution in [candidate.metal.cpuEncode, candidate.metal.gpuExecute,
                                     candidate.coreImage.cpuEncode, candidate.coreImage.gpuExecute] {
                    guard distribution.p50Ms <= distribution.p95Ms,
                          distribution.rounds.count == current.configuration.rounds,
                          distribution.rounds.allSatisfy({ $0.p50Ms.isFinite && $0.p95Ms.isFinite && $0.p50Ms > 0 && $0.p50Ms <= $0.p95Ms }),
                          distribution.p50Ms == BenchmarkDistribution.percentile(distribution.rounds.map(\.p50Ms), 0.5),
                          distribution.p95Ms == BenchmarkDistribution.percentile(distribution.rounds.map(\.p95Ms), 0.5) else {
                        throw BenchmarkError(message: "Invalid round measurements for \(item.name).")
                    }
                }
            }
            for (metric, measured, old, tolerance) in [
                ("cpu.p50", item.metal.cpuEncode.p50Ms, previous.metal.cpuEncode.p50Ms, policy.cpuToleranceMs),
                ("cpu.p95", item.metal.cpuEncode.p95Ms, previous.metal.cpuEncode.p95Ms, policy.cpuToleranceMs),
                ("gpu.p50", item.metal.gpuExecute.p50Ms, previous.metal.gpuExecute.p50Ms, policy.gpuToleranceMs),
                ("gpu.p95", item.metal.gpuExecute.p95Ms, previous.metal.gpuExecute.p95Ms, policy.gpuToleranceMs)
            ] {
                guard measured.isFinite, old.isFinite, measured > 0, old > 0 else {
                    throw BenchmarkError(message: "Invalid timing for \(item.name) \(metric).")
                }
                let limit = old + max(old * policy.relativeThreshold, tolerance)
                guard limit.isFinite else { throw BenchmarkError(message: "Tolerance overflow for \(metric).") }
                if measured > limit {
                    regressions.append(BenchmarkRegression(caseName: item.name, metric: metric,
                        baselineMs: old, currentMs: measured, limitMs: limit))
                }
            }
        }
        return regressions
    }
}
#endif
