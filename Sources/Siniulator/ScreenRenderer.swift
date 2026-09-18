import AppKit
import Metal
import QuartzCore
import IOSurface
import CoreImage
import SimulatorBridge

final class MetalScreenEngine: Sendable {
    static let shared = Result { try MetalScreenEngine() }
    let device: MTLDevice
    let pipeline: MTLRenderPipelineState
    let images: CIContext
    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw SimulatorError(message: "Metal is unavailable.") }
        self.device = device
        images = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        let library = try device.makeLibrary(source: """
        #include <metal_stdlib>
        using namespace metal;
        struct Vertex { float4 position [[position]]; float2 uv; };
        vertex Vertex screen_vertex(uint i [[vertex_id]], constant float2 &scale [[buffer(0)]]) {
            float2 positions[] = {float2(-1,1), float2(-1,-1), float2(1,1), float2(1,-1)};
            float2 uvs[] = {float2(0,0), float2(0,1), float2(1,0), float2(1,1)};
            return {float4(positions[i]*scale,0,1), uvs[i]};
        }
        fragment float4 screen_fragment(Vertex v [[stage_in]], texture2d<float> image [[texture(0)]], constant uint &turn [[buffer(0)]]) {
            float2 uv = v.uv;
            if (turn == 1) uv = float2(uv.y,1-uv.x);
            if (turn == 2) uv = 1-uv;
            if (turn == 3) uv = float2(1-uv.y,uv.x);
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            return float4(image.sample(s,uv).rgb,1);
        }
        """, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "screen_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "screen_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }
    func texture(for surface: IOSurface) -> MTLTexture? {
        let format = surface.pixelFormat
        guard format == 0x42475241 || format == 0x52474241 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format == 0x42475241 ? .bgra8Unorm : .rgba8Unorm,
            width: surface.width, height: surface.height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        return device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0)
    }
    func encode(source: MTLTexture, target: MTLTexture, turns: Int, command: MTLCommandBuffer) {
        let turns = ScreenGeometry.normalizedQuarterTurns(turns)
        let size = turns % 2 == 0 ? CGSize(width: source.width, height: source.height) : CGSize(width: source.height, height: source.width)
        let rect = ScreenGeometry.imageRect(image: size, in: CGRect(x: 0, y: 0, width: target.width, height: target.height))
        var scale = SIMD2<Float>(Float(rect.width / CGFloat(target.width)), Float(rect.height / CGFloat(target.height)))
        var turn = UInt32(turns)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0.035, 0.035, 0.045, 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
        encoder.setFragmentBytes(&turn, length: MemoryLayout<UInt32>.size, index: 0)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }
    func encodeReference(surface: IOSurface, target: MTLTexture, turns: Int, command: MTLCommandBuffer, flipForAppKit: Bool = false) {
        let image = CIImage(ioSurface: surface).oriented([.up, .right, .down, .left][ScreenGeometry.normalizedQuarterTurns(turns)])
        let bounds = CGRect(x: 0, y: 0, width: target.width, height: target.height)
        let rect = ScreenGeometry.imageRect(image: image.extent.size, in: bounds)
        let scale = rect.width / image.extent.width
        let transform = CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)
            .scaledBy(x: scale, y: scale).translatedBy(x: rect.minX / scale, y: rect.minY / scale)
        let background = CIImage(color: CIColor(red: 0.035, green: 0.035, blue: 0.045)).cropped(to: bounds)
        var output = image.transformed(by: transform).composited(over: background)
        if flipForAppKit { output = output.transformed(by: CGAffineTransform(translationX: 0, y: bounds.height).scaledBy(x: 1, y: -1)) }
        images.render(output, to: target, commandBuffer: command,
            bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
    }
}

// Only the latest frame waits for the GPU; drawable acquisition and encoding
// never block AppKit's input event loop. No bitmap is copied through the CPU.
// The lock guards shared scheduling/display state; the serial render queue owns
// the texture cache. AppKit configures the layer on the main actor while Metal
// acquires and presents its drawables on the render queue.
final class ScreenRenderer: @unchecked Sendable {
    let layer = CAMetalLayer()
    let engine: MetalScreenEngine
    private let commands: MTLCommandQueue
    private let queue = DispatchQueue(label: "Siniulator.render", qos: .userInteractive)
    private let lock = NSLock()
    private var inFlight = 0
    private var display: SIDisplay?
    private var turns = 0
    private var size = CGSize.zero
    private var pending = false
    private var scheduled = false
    private var cachedSurface: IOSurface?
    private var cachedTexture: MTLTexture?
    @MainActor init() throws {
        engine = try MetalScreenEngine.shared.get()
        guard let commands = engine.device.makeCommandQueue() else { throw SimulatorError(message: "Metal command queue is unavailable.") }
        self.commands = commands
        layer.device = engine.device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.maximumDrawableCount = 2
        layer.presentsWithTransaction = false
        layer.backgroundColor = NSColor.black.cgColor
        layer.isOpaque = true
    }
    func setDisplay(_ display: SIDisplay?) {
        lock.lock(); self.display = display; lock.unlock()
        requestFrame()
    }
    @MainActor func configure(size: CGSize, scale: CGFloat, turns: Int) {
        let pixels = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        layer.contentsScale = scale
        layer.drawableSize = pixels
        lock.lock(); self.size = pixels; self.turns = turns; lock.unlock()
        requestFrame()
    }
    func requestFrame() {
        lock.lock()
        pending = true
        let shouldSchedule = !scheduled && inFlight < 2
        if shouldSchedule { scheduled = true }
        lock.unlock()
        if shouldSchedule { queue.async { [weak self] in self?.render() } }
    }
    private func render() {
        lock.lock()
        let display = display, size = size
        pending = false; scheduled = false; inFlight += 1
        lock.unlock()
        guard size.width > 1, size.height > 1, display != nil,
              let drawable = layer.nextDrawable(), let surface = display?.surface as? IOSurface,
              let command = commands.makeCommandBuffer() else { completed(); return }
        // nextDrawable can wait for the compositor. Read the framebuffer and
        // orientation afterwards, so that wait cannot age the queued image.
        lock.lock(); let turns = turns; lock.unlock()
        if cachedSurface !== surface {
            cachedSurface = surface
            cachedTexture = engine.texture(for: surface)
        }
        if let source = cachedTexture { engine.encode(source: source, target: drawable.texture, turns: turns, command: command) }
        else { engine.encodeReference(surface: surface, target: drawable.texture, turns: turns, command: command, flipForAppKit: true) }
        command.addCompletedHandler { [weak self, surface] _ in
            _ = surface // Keep the shared framebuffer alive until GPU reads finish.
            guard let self else { return }
            self.completed()
        }
        command.present(drawable)
        command.commit()
    }
    private func completed() {
        lock.lock(); inFlight -= 1; let pending = pending; lock.unlock()
        if pending { requestFrame() }
    }
}
