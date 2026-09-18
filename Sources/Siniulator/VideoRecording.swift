import AppKit
import AVFoundation

@MainActor final class VideoRecording {
    private enum Event {
        case started
        case finished(Int32, Process.TerminationReason)
    }
    private let process: Process
    private var completion: Task<Void, Error>!
    private(set) var hasStarted = false
    private(set) var isStopping = false

    init(deviceID: String, outputURL: URL) throws {
        let process = Process()
        self.process = process
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "io", deviceID, "recordVideo", "--codec=h264", "--mask=ignored", "--force", outputURL.path]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        let output = RecordingOutput()
        let (events, continuation) = AsyncStream<Event>.makeStream()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            if output.append(handle.availableData) { continuation.yield(.started) }
        }
        process.terminationHandler = { process in
            pipe.fileHandleForReading.readabilityHandler = nil
            continuation.yield(.finished(process.terminationStatus, process.terminationReason))
            continuation.finish()
        }
        do { try process.run() }
        catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            continuation.finish()
            throw error
        }
        completion = Task { [weak self] in
            for await event in events {
                switch event {
                case .started:
                    self?.hasStarted = true
                    if self?.isStopping == true, process.isRunning { process.interrupt() }
                case .finished(let status, let reason):
                    guard status == 0 || status == 130 || (reason == .uncaughtSignal && status == 2) else {
                        throw SimulatorError(message: output.text.isEmpty ? "Video recording failed." : output.text)
                    }
                    return
                }
            }
        }
    }

    func stop() {
        guard !isStopping else { return }
        isStopping = true
        // A very fast Stop must not interrupt xcrun before simctl has opened the
        // encoder. Its first-frame acknowledgement makes SIGINT safe.
        if hasStarted, process.isRunning { process.interrupt() }
    }

    func waitUntilFinished() async throws { try await completion.value }

    static func lastFrame(in url: URL, maximumSize: CGSize = CGSize(width: 220, height: 340)) async throws -> CGImage {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration.seconds > 0 else { throw SimulatorError(message: "The recording contains no video frames.") }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let time = CMTimeMaximum(.zero, CMTimeSubtract(duration, CMTime(value: 1, timescale: 600)))
        return try await generator.image(at: time).image
    }
}

final class RecordingOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var started = false
    // The acknowledgement can span multiple pipe reads.
    func append(_ value: Data) -> Bool {
        lock.withLock {
            data.append(value)
            guard !started, String(decoding: data, as: UTF8.self).contains("Recording started") else { return false }
            started = true
            return true
        }
    }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
