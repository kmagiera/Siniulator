#if SINIULATOR_BENCHMARK
import AppKit
import Metal
import IOSurface
import Darwin

private struct BenchmarkOptions {
    var configuration = BenchmarkConfiguration()
    var policy = BenchmarkPolicy()
    var directory = URL(fileURLWithPath: "build/benchmarks/latest")
    var baseline = URL(fileURLWithPath: "Benchmarks/Baselines/render.json")
    var recordBaseline = false
    var measureOnly = false

    init(arguments: [String]) throws {
        var index = 1
        while index < arguments.count {
            let option = arguments[index]
            index += 1
            switch option {
            case "--benchmark": continue
            case "--record-baseline": recordBaseline = true; continue
            case "--measure-only": measureOnly = true; continue
            default: break
            }
            guard index < arguments.count else { throw BenchmarkError(message: "Missing value for \(option).") }
            let value = arguments[index]; index += 1
            switch option {
            case "--output-dir": directory = URL(fileURLWithPath: value)
            case "--baseline": baseline = URL(fileURLWithPath: value)
            case "--samples", "--warmup", "--rounds":
                guard let number = Int(value) else { throw BenchmarkError(message: "Invalid number for \(option).") }
                if option == "--samples" { configuration.samples = number }
                else if option == "--warmup" { configuration.warmup = number }
                else { configuration.rounds = number }
            case "--relative-threshold", "--cpu-tolerance-ms", "--gpu-tolerance-ms":
                guard let number = Double(value), number.isFinite, number >= 0 else { throw BenchmarkError(message: "Invalid tolerance for \(option).") }
                if option == "--relative-threshold" { policy.relativeThreshold = number / 100 }
                else if option == "--cpu-tolerance-ms" { policy.cpuToleranceMs = number }
                else { policy.gpuToleranceMs = number }
            default: throw BenchmarkError(message: "Unknown benchmark option: \(option).")
            }
        }
        guard configuration.isValid, !(recordBaseline && measureOnly) else {
            throw BenchmarkError(message: "Use 100–10000 samples, 20–1000 warmup samples and 3–21 odd rounds. --record-baseline and --measure-only are exclusive.")
        }
    }
}

enum PerformanceDiagnostics {
    private static func fixture(configuration: BenchmarkConfiguration) throws -> IOSurface {
        let width = configuration.sourceWidth, height = configuration.sourceHeight
        let properties: [String: Any] = [kIOSurfaceWidth as String: width, kIOSurfaceHeight as String: height,
            kIOSurfaceBytesPerElement as String: 4, kIOSurfaceBytesPerRow as String: width * 4,
            kIOSurfacePixelFormat as String: UInt32(0x42475241)]
        guard let surface = IOSurfaceCreate(properties as CFDictionary) else { throw BenchmarkError(message: "Cannot allocate fixture IOSurface.", exitCode: 1) }
        guard IOSurfaceLock(surface, [], nil) == KERN_SUCCESS else { throw BenchmarkError(message: "Cannot lock fixture.", exitCode: 1) }
        defer { IOSurfaceUnlock(surface, [], nil) }
        let bytes = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
        let stride = IOSurfaceGetBytesPerRow(surface)
        // A single initialization before measurement. Asymmetric gradients and
        // checkerboard detail reveal orientation, sampling and colour errors.
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * stride + x * 4
                bytes[offset] = UInt8((x / 53 + y / 97) % 2 == 0 ? 40 : 190)
                bytes[offset + 1] = UInt8(20 + y * 210 / (height - 1))
                bytes[offset + 2] = UInt8(20 + x * 210 / (width - 1))
                bytes[offset + 3] = 255
            }
        }
        return surface
    }

    static func measure(configuration: BenchmarkConfiguration, environment: BenchmarkEnvironment) throws -> BenchmarkReport {
        let engine = try MetalScreenEngine.shared.get()
        let surface = try fixture(configuration: configuration)
        guard let source = engine.texture(for: surface), let queue = engine.device.makeCommandQueue() else {
            throw BenchmarkError(message: "IOSurface texture or command queue unavailable.", exitCode: 1)
        }
        let scenarios = [("window-portrait", 600, 1280, 0), ("window-landscape", 1280, 600, 1),
                         ("window-retina", 1200, 2560, 0), ("full-screen-portrait", 1920, 1080, 0)]
        func target(width: Int, height: Int) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
            guard let texture = engine.device.makeTexture(descriptor: descriptor) else { throw BenchmarkError(message: "Target texture unavailable.", exitCode: 1) }
            return texture
        }
        func encode(reference: Bool, turn: Int, target: MTLTexture) throws -> (cpu: Double, gpu: Double) {
            guard let command = queue.makeCommandBuffer() else { throw BenchmarkError(message: "Command buffer unavailable.", exitCode: 1) }
            let start = CACurrentMediaTime()
            if reference { engine.encodeReference(surface: surface, target: target, turns: turn, command: command) }
            else { engine.encode(source: source, target: target, turns: turn, command: command) }
            let cpu = (CACurrentMediaTime() - start) * 1000
            // Waiting and pixel readback are benchmark-only. Neither operation
            // is in the normal renderer, and neither counts towards CPU encode.
            command.commit(); command.waitUntilCompleted()
            if let error = command.error { throw error }
            let gpu = (command.gpuEndTime - command.gpuStartTime) * 1000
            guard cpu.isFinite, gpu.isFinite, cpu > 0, gpu > 0 else { throw BenchmarkError(message: "GPU timestamps or CPU timing unavailable.", exitCode: 1) }
            return (cpu, gpu)
        }
        var cases: [BenchmarkCaseResult] = []
        for (name, width, height, turn) in scenarios {
            let texture = try target(width: width, height: height)
            var cpuRounds = [[BenchmarkRound](), [BenchmarkRound]()]
            var gpuRounds = [[BenchmarkRound](), [BenchmarkRound]()]
            for round in 0..<configuration.rounds {
                for _ in 0..<configuration.warmup {
                    for path in 0..<2 { _ = try encode(reference: path == 1, turn: turn, target: texture) }
                }
                var cpuSamples = [[Double](), [Double]()], gpuSamples = [[Double](), [Double]()]
                for sample in 0..<configuration.samples {
                    // Alternate the order to reduce clock/thermal bias between paths.
                    for path in (sample + round) % 2 == 0 ? [0, 1] : [1, 0] {
                        let timing = try autoreleasepool { try encode(reference: path == 1, turn: turn, target: texture) }
                        cpuSamples[path].append(timing.cpu); gpuSamples[path].append(timing.gpu)
                    }
                }
                for path in 0..<2 {
                    cpuRounds[path].append(BenchmarkRound(p50Ms: BenchmarkDistribution.percentile(cpuSamples[path], 0.5), p95Ms: BenchmarkDistribution.percentile(cpuSamples[path], 0.95)))
                    gpuRounds[path].append(BenchmarkRound(p50Ms: BenchmarkDistribution.percentile(gpuSamples[path], 0.5), p95Ms: BenchmarkDistribution.percentile(gpuSamples[path], 0.95)))
                }
            }
            func timings(_ path: Int) -> BenchmarkTimings {
                BenchmarkTimings(cpuEncode: BenchmarkDistribution(rounds: cpuRounds[path]), gpuExecute: BenchmarkDistribution(rounds: gpuRounds[path]))
            }
            cases.append(BenchmarkCaseResult(name: name, width: width, height: height, quarterTurns: turn, metal: timings(0), coreImage: timings(1)))
        }
        let texture = try target(width: 600, height: 1280)
        func pixels() -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
            bytes.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 4,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0) }
            return bytes
        }
        var checks: [BenchmarkImageCheck] = []
        for turn in 0..<4 {
            _ = try encode(reference: true, turn: turn, target: texture); let expected = pixels()
            _ = try encode(reference: false, turn: turn, target: texture); let actual = pixels()
            let size = turn % 2 == 0 ? CGSize(width: source.width, height: source.height) : CGSize(width: source.height, height: source.width)
            let rect = ScreenGeometry.imageRect(image: size, in: CGRect(x: 0, y: 0, width: texture.width, height: texture.height))
            var difference = 0.0, channels = 0
            for y in 0..<texture.height {
                for x in 0..<texture.width {
                    let offset = (y * texture.width + x) * 4
                    let point = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                    if rect.insetBy(dx: 2, dy: 2).contains(point) {
                        // Normalize Core Image readback's opposite texture origin.
                        let referenceOffset = ((texture.height - 1 - y) * texture.width + x) * 4
                        for channel in 0..<3 { difference += Double(abs(Int(expected[referenceOffset + channel]) - Int(actual[offset + channel]))); channels += 1 }
                    } else if !rect.insetBy(dx: -2, dy: -2).contains(point) {
                        // Check Metal's letterbox independently of CI colour management.
                        for (channel, value) in [11, 9, 9].enumerated() {
                            guard abs(Int(actual[offset + channel]) - value) <= 1 else { throw BenchmarkError(message: "Invalid letterbox in orientation \(turn).", exitCode: 1) }
                        }
                    }
                }
            }
            guard channels > 0 else { throw BenchmarkError(message: "Empty rendered content.", exitCode: 1) }
            let mean = difference / Double(channels)
            guard mean < 4 else { throw BenchmarkError(message: "Image differs from reference in orientation \(turn): \(mean).", exitCode: 1) }
            checks.append(BenchmarkImageCheck(quarterTurns: turn, meanRGBDifference: mean))
        }
        return BenchmarkReport(schemaVersion: 1, createdAt: ISO8601DateFormatter().string(from: Date()),
            environment: environment, configuration: configuration, cases: cases, imageChecks: checks)
    }

    private static func hardwareModel() throws -> String {
        var count = 0
        guard sysctlbyname("hw.model", nil, &count, nil, 0) == 0 else { throw BenchmarkError(message: "Cannot read hardware model.") }
        var bytes = [UInt8](repeating: 0, count: count)
        guard sysctlbyname("hw.model", &bytes, &count, nil, 0) == 0 else { throw BenchmarkError(message: "Cannot read hardware model.") }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    @MainActor static func run() async {
        do {
            let options = try BenchmarkOptions(arguments: CommandLine.arguments)
            let artifacts = ["render-performance.json", "render-performance.txt", "comparison.json"].map { options.directory.appendingPathComponent($0) }
            guard !artifacts.contains(where: { $0.standardizedFileURL == options.baseline.standardizedFileURL }) else {
                throw BenchmarkError(message: "Baseline must be separate from the result files.")
            }
            try FileManager.default.createDirectory(at: options.directory, withIntermediateDirectories: true)
            for artifact in artifacts where FileManager.default.fileExists(atPath: artifact.path) {
                try FileManager.default.removeItem(at: artifact)
            }
#if DEBUG
            let configuration = "debug"
#else
            let configuration = "release"
#endif
            let xcode = String(decoding: try await CommandRunner.run("/usr/bin/xcodebuild", ["-version"]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let engine = try MetalScreenEngine.shared.get()
            let environment = BenchmarkEnvironment(hardwareModel: try hardwareModel(), gpu: engine.device.name,
                os: ProcessInfo.processInfo.operatingSystemVersionString, xcode: xcode,
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, buildConfiguration: configuration)
            let report = try await Task.detached(priority: .userInitiated) { try measure(configuration: options.configuration, environment: environment) }.value
            try write(report, to: options.directory.appendingPathComponent("render-performance.json"))
            try Data(report.text.utf8).write(to: options.directory.appendingPathComponent("render-performance.txt"))
            print(report.text)
            if options.recordBaseline {
                try write(report, to: options.baseline)
                print("BASELINE RECORDED: \(options.baseline.path)")
            } else if options.measureOnly {
                print("MEASURE ONLY: baseline not compared or modified")
            } else {
                guard FileManager.default.fileExists(atPath: options.baseline.path) else { throw BenchmarkError(message: "Baseline missing: \(options.baseline.path). Run with --record-baseline to create it explicitly.") }
                let previous = try JSONDecoder().decode(BenchmarkReport.self, from: Data(contentsOf: options.baseline))
                let regressions = try BenchmarkComparison.compare(current: report, baseline: previous, policy: options.policy)
                try write(BenchmarkComparison(baselinePath: options.baseline.path, policy: options.policy, regressions: regressions), to: options.directory.appendingPathComponent("comparison.json"))
                for regression in regressions {
                    print(String(format: "REGRESSION: %@ %@: %.4f ms, baseline %.4f ms, limit %.4f ms", regression.caseName, regression.metric, regression.currentMs, regression.baselineMs, regression.limitMs))
                }
                guard regressions.isEmpty else { throw BenchmarkError(message: "\(regressions.count) performance regression(s). Baseline was not modified.", exitCode: 1) }
                print("PASS: all Metal CPU/GPU p50 and p95 metrics within tolerance")
            }
            print("RESULTS: \(options.directory.path)")
        } catch {
            fputs("BENCHMARK FAILED: \(error.localizedDescription)\n", stderr)
            exit((error as? BenchmarkError)?.exitCode ?? 1)
        }
    }
}
#endif
