import AppKit
import AVFoundation
import XCTest
@testable import Siniulator

final class RecordingTests: XCTestCase {
    func testRecordingAcknowledgementCanSpanPipeReadsAndOnlyStartsOnce() {
        let output = RecordingOutput()
        XCTAssertFalse(output.append(Data("Opening encoder…\nRecord".utf8)))
        XCTAssertTrue(output.append(Data("ing started\n".utf8)))
        XCTAssertFalse(output.append(Data("Recording started\nEncoder finished".utf8)))
        XCTAssertEqual(output.text, "Opening encoder…\nRecording started\nRecording started\nEncoder finished")
    }

    func testSameSecondRecordingsKeepMP4ExtensionAndIndependentDragSources() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = Date(timeIntervalSince1970: 1_789_674_737)
        let files = try (0..<2).map { _ in try CaptureFile.reserve(deviceName: "iPhone", date: date, kind: .recording) }
        defer { for file in files { try? FileManager.default.removeItem(at: file.temporaryURL.deletingLastPathComponent()) } }
        for (index, file) in files.enumerated() { try Data([UInt8(index)]).write(to: file.temporaryURL) }
        let saved = try files.map { try $0.save(in: directory) }
        XCTAssertNotEqual(saved[0], saved[1])
        XCTAssertTrue(saved[1].lastPathComponent.hasSuffix(" (2).mp4"))
        for (index, file) in files.enumerated() {
            XCTAssertEqual(file.kind.contentType, .mpeg4Movie)
            XCTAssertEqual(try Data(contentsOf: file.temporaryURL), Data([UInt8(index)]))
            XCTAssertEqual(try Data(contentsOf: saved[index]), Data([UInt8(index)]))
        }
    }

    @MainActor func testMoviePosterDecodesTheLastFrameRatherThanAnEarlierKeyframe() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 80, AVVideoHeightKey: 160])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 80, kCVPixelBufferHeightKey as String: 160,
            kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? SimulatorError(message: "Fixture encoder failed to start.") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw writer.error ?? SimulatorError(message: "Fixture encoder failed.") }
                try await Task.sleep(for: .milliseconds(5))
            }
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer), kCVReturnSuccess)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let context = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: 80, height: 160,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue))
            // Only the final non-keyframe is blue; seeking an earlier keyframe
            // or using the first frame will produce a red poster.
            context.setFillColor(frame == 29 ? CGColor(red: 0, green: 0, blue: 1, alpha: 1) : CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 160))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            guard adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)) else {
                throw writer.error ?? SimulatorError(message: "Fixture frame could not be encoded.")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        let poster = try await VideoRecording.lastFrame(in: url)
        let color = try XCTUnwrap(NSBitmapImageRep(cgImage: poster).colorAt(x: poster.width / 2, y: poster.height / 2)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(color.blueComponent, 0.8)
        XCTAssertLessThan(color.redComponent, 0.1)
    }
}
