#if SINIULATOR_BENCHMARK
import XCTest
@testable import Siniulator

final class BenchmarkTests: XCTestCase {
    private let environment = BenchmarkEnvironment(hardwareModel: "test-model", gpu: "test-gpu", os: "test-os",
        xcode: "test-xcode", lowPowerMode: false, buildConfiguration: "release")

    private func report(cpu: Double = 0.006, gpu: Double = 0.128, names: [String] = ["portrait"],
                        configuration: BenchmarkConfiguration = BenchmarkConfiguration(),
                        environment: BenchmarkEnvironment? = nil, checks: [Int] = Array(0..<4)) -> BenchmarkReport {
        let cpuRounds = Array(repeating: BenchmarkRound(p50Ms: cpu, p95Ms: cpu * 1.1), count: configuration.rounds)
        let gpuRounds = Array(repeating: BenchmarkRound(p50Ms: gpu, p95Ms: gpu * 1.1), count: configuration.rounds)
        let timing = BenchmarkTimings(cpuEncode: BenchmarkDistribution(rounds: cpuRounds), gpuExecute: BenchmarkDistribution(rounds: gpuRounds))
        return BenchmarkReport(schemaVersion: 1, createdAt: "test", environment: environment ?? self.environment,
            configuration: configuration, cases: names.map { BenchmarkCaseResult(name: $0, width: 600, height: 1280, quarterTurns: 0, metal: timing, coreImage: timing) },
            imageChecks: checks.map { BenchmarkImageCheck(quarterTurns: $0, meanRGBDifference: 1) })
    }

    func testIdenticalResultsAndOrdinaryNoisePass() throws {
        XCTAssertTrue(try BenchmarkComparison.compare(current: report(), baseline: report(), policy: BenchmarkPolicy()).isEmpty)
        // The absolute floor avoids treating several microseconds as a regression.
        XCTAssertTrue(try BenchmarkComparison.compare(current: report(cpu: 0.0084, gpu: 0.150), baseline: report(), policy: BenchmarkPolicy()).isEmpty)
        XCTAssertTrue(try BenchmarkComparison.compare(current: report(gpu: 0.038), baseline: report(gpu: 0.030), policy: BenchmarkPolicy()).isEmpty)
    }
    func testCPUAndGPURegressionsAreReportedByMetric() throws {
        let failures = try BenchmarkComparison.compare(current: report(cpu: 0.030, gpu: 0.300), baseline: report(), policy: BenchmarkPolicy())
        XCTAssertEqual(Set(failures.map(\.metric)), ["cpu.p50", "cpu.p95", "gpu.p50", "gpu.p95"])
        XCTAssertEqual(failures.first { $0.metric == "cpu.p50" }!.limitMs, 0.009, accuracy: 0.000001)
    }
    func testRelativeThresholdAppliesToMoreExpensiveWork() throws {
        let failures = try BenchmarkComparison.compare(current: report(gpu: 1.01), baseline: report(gpu: 0.8), policy: BenchmarkPolicy())
        XCTAssertEqual(Set(failures.map(\.metric)), ["gpu.p50", "gpu.p95"])
        XCTAssertEqual(failures.first { $0.metric == "gpu.p50" }!.limitMs, 1, accuracy: 0.000001)
    }
    func testCaseOrderDoesNotAffectComparison() throws {
        XCTAssertTrue(try BenchmarkComparison.compare(current: report(names: ["landscape", "portrait"]),
            baseline: report(names: ["portrait", "landscape"]), policy: BenchmarkPolicy()).isEmpty)
    }
    func testMissingAndDuplicateCasesCannotPass() {
        for names in [[], ["landscape"], ["portrait", "portrait"]] as [[String]] {
            XCTAssertThrowsError(try BenchmarkComparison.compare(current: report(names: names), baseline: report(), policy: BenchmarkPolicy()))
        }
    }
    func testDifferentPowerModeOrBuildCannotPass() {
        let changed = BenchmarkEnvironment(hardwareModel: environment.hardwareModel, gpu: environment.gpu,
            os: environment.os, xcode: environment.xcode, lowPowerMode: true, buildConfiguration: "debug")
        XCTAssertThrowsError(try BenchmarkComparison.compare(current: report(environment: changed), baseline: report(), policy: BenchmarkPolicy()))
    }
    func testFixtureVersionSurvivesJSONAndRejectsIncompatibleBaseline() throws {
        var configuration = BenchmarkConfiguration(); configuration.fixture = "different-fixture"
        let encoded = try JSONEncoder().encode(report(configuration: configuration))
        let decoded = try JSONDecoder().decode(BenchmarkReport.self, from: encoded)
        XCTAssertEqual(decoded.configuration.fixture, "different-fixture")
        XCTAssertThrowsError(try BenchmarkComparison.compare(current: report(), baseline: decoded, policy: BenchmarkPolicy()))
    }
    func testInvalidTimingsAndIncompleteQualityChecksCannotPass() {
        for candidate in [report(cpu: 0), report(gpu: .nan), report(checks: [0, 1, 2]), report(checks: [0, 1, 2, 2])] {
            XCTAssertThrowsError(try BenchmarkComparison.compare(current: candidate, baseline: report(), policy: BenchmarkPolicy()))
        }
    }
    func testRoundMedianAndNearestRankPercentile() {
        XCTAssertEqual(BenchmarkDistribution.percentile(Array(1...100).map(Double.init), 0.95), 95)
        let distribution = BenchmarkDistribution(rounds: [BenchmarkRound(p50Ms: 1, p95Ms: 2),
            BenchmarkRound(p50Ms: 100, p95Ms: 200), BenchmarkRound(p50Ms: 2, p95Ms: 3)])
        XCTAssertEqual(distribution.p50Ms, 2)
        XCTAssertEqual(distribution.p95Ms, 3)
    }

    func testMalformedDecodedReportsFailWithoutCrashing() throws {
        let encoded = try JSONEncoder().encode(report())
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        func check(_ object: [String: Any]) throws {
            let candidate = try JSONDecoder().decode(BenchmarkReport.self,
                from: JSONSerialization.data(withJSONObject: object))
            XCTAssertThrowsError(try BenchmarkComparison.compare(current: candidate, baseline: candidate, policy: BenchmarkPolicy()))
        }

        for (key, value) in [("rounds", 0), ("rounds", -1), ("rounds", 4), ("samples", 0), ("sourceWidth", 0)] {
            var object = original
            var configuration = try XCTUnwrap(object["configuration"] as? [String: Any])
            configuration[key] = value
            object["configuration"] = configuration
            if key == "rounds", value == 0 {
                var cases = try XCTUnwrap(object["cases"] as? [[String: Any]])
                for renderer in ["metal", "coreImage"] {
                    var timings = try XCTUnwrap(cases[0][renderer] as? [String: Any])
                    for metric in ["cpuEncode", "gpuExecute"] {
                        var distribution = try XCTUnwrap(timings[metric] as? [String: Any])
                        distribution["rounds"] = []
                        timings[metric] = distribution
                    }
                    cases[0][renderer] = timings
                }
                object["cases"] = cases
            }
            try check(object)
        }
        for (key, value) in [("width", 0), ("height", -1), ("quarterTurns", 4)] {
            var object = original
            var cases = try XCTUnwrap(object["cases"] as? [[String: Any]])
            cases[0][key] = value
            object["cases"] = cases
            try check(object)
        }

        var object = original
        var cases = try XCTUnwrap(object["cases"] as? [[String: Any]])
        var reference = try XCTUnwrap(cases[0]["coreImage"] as? [String: Any])
        var distribution = try XCTUnwrap(reference["cpuEncode"] as? [String: Any])
        distribution["rounds"] = []
        reference["cpuEncode"] = distribution
        cases[0]["coreImage"] = reference
        object["cases"] = cases
        try check(object)
    }
}
#endif
