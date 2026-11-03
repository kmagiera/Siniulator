import Metal
import MetalPerformanceShaders
import XCTest
@testable import Siniulator

final class ScreenRendererTests: XCTestCase {
    func testOneToOneRenderingPreservesSinglePixelDetails() throws {
        try assertRenderingMatchesSource(downscale: 1)
    }

    func testDownscalingFiltersOnlyOnce() throws {
        try assertRenderingMatchesSource(downscale: 3)
    }

    private func assertRenderingMatchesSource(downscale: Int) throws {
        let engine = try MetalScreenEngine.shared.get()
        let queue = try XCTUnwrap(engine.device.makeCommandQueue())
        let downscaler = ScreenDownscaler(device: engine.device)
        // Non-power-of-two dimensions expose rounding in interpolated UV derivatives.
        let width = 440, height = 956
        func texture(width: Int, height: Int) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: width, height: height, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            return try XCTUnwrap(engine.device.makeTexture(descriptor: descriptor))
        }
        func pixels(_ texture: MTLTexture) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
            bytes.withUnsafeMutableBytes {
                texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 4,
                    from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
            }
            return bytes
        }
        let source = try texture(width: width * downscale, height: height * downscale)
        var bytes = [UInt8](repeating: 255, count: source.width * source.height * 4)
        for y in 0..<source.height {
            for x in 0..<source.width {
                let value: UInt8 = (x / downscale + y / downscale) % 2 == 0 ? 0 : 255
                let offset = (y * source.width + x) * 4
                for channel in 0..<3 { bytes[offset + channel] = value }
            }
        }
        bytes.withUnsafeBytes {
            source.replace(region: MTLRegionMake2D(0, 0, source.width, source.height), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: source.width * 4)
        }
        var expected = bytes
        if downscale > 1 {
            let reference = try texture(width: width, height: height)
            let referenceCommand = try XCTUnwrap(queue.makeCommandBuffer())
            MPSImageLanczosScale(device: engine.device).encode(commandBuffer: referenceCommand,
                sourceTexture: source, destinationTexture: reference)
            referenceCommand.commit(); referenceCommand.waitUntilCompleted()
            if let error = referenceCommand.error { throw error }
            expected = pixels(reference)
        }

        for turns in 0..<4 {
            let target = try texture(width: turns % 2 == 0 ? width : height,
                height: turns % 2 == 0 ? height : width)
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            engine.encode(source: source, target: target, turns: turns, command: command, downscaler: downscaler)
            command.commit(); command.waitUntilCompleted()
            if let error = command.error { throw error }
            let actual = pixels(target)
            var largestDifference = 0
            for y in 0..<target.height {
                for x in 0..<target.width {
                    let original: (x: Int, y: Int)
                    switch turns {
                    case 1: original = (y, height - 1 - x)
                    case 2: original = (width - 1 - x, height - 1 - y)
                    case 3: original = (width - 1 - y, x)
                    default: original = (x, y)
                    }
                    for channel in 0..<3 {
                        let difference = abs(Int(actual[(y * target.width + x) * 4 + channel])
                            - Int(expected[(original.y * width + original.x) * 4 + channel]))
                        largestDifference = max(largestDifference, difference)
                    }
                }
            }
            XCTAssertLessThanOrEqual(largestDifference, 1, "downscale=\(downscale), turns=\(turns)")
        }
    }
}
