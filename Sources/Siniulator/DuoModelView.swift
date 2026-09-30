import AppKit
import IOSurface
import Metal
import SceneKit
import SimulatorBridge

/// Renders Apple's DeviceKit model for the foldable simulator. The model is
/// loaded at runtime from the selected Xcode, so Siniulator neither copies nor
/// ships Apple's private artwork.
@MainActor final class DuoModelView: SCNView {
    private static let innerScreenName = "mQHVkATpIwJRVQx"
    private static let coverScreenName = "zaWsadDZpWAUDAX"

    private let content: SCNNode
    private let poseClip: DuoPoseClip
    private let cameraNode = SCNNode()
    private var innerScreen: SCNNode
    private var coverScreen: SCNNode
    private var activeScreen: SCNNode
    private var screenHitMeshes: [ObjectIdentifier: DuoScreenHitMesh] = [:]
    private struct ScreenTexture {
        let surface: IOSurface
        let texture: MTLTexture
        let nativeQuarterTurns: Int
    }
    private var screenTextures: [ObjectIdentifier: ScreenTexture] = [:]
    private var requestedPanel: SCNNode?
    private var frozenPanelTexture: MTLTexture?
    private var nativeQuarterTurns = 0
    private var pose = DuoRenderPose(phase: 1, quarterTurns: 0)
    private(set) var projectedHardwareBounds: CGRect = .zero
    var maximumProjectedSpan: CGFloat { poseClip.maximumProjectedSpan }
    var toolbarWidthFraction: CGFloat { poseClip.toolbarWidthFraction }
    var anchorsHardwareToTop = false {
        didSet { if oldValue != anchorsHardwareToTop { updateCamera() } }
    }
    private struct ProjectionState: Equatable {
        let size: CGSize
        let pose: DuoRenderPose
        let anchored: Bool
    }
    private var projectionState: ProjectionState?
    private var resizePose: ProjectionState?
    private var resizePoints: [DeviceResizeCorner: CGPoint] = [:]
#if DEBUG
    private(set) var cameraUpdateCount = 0
    func snapshotCurrentPose() -> NSImage {
        // A hidden SCNView can return the previous skinned frame on its first
        // snapshot after a pose change. Prime that offscreen renderer before
        // capturing evidence. This is never part of the production frame loop.
        SCNTransaction.flush()
        _ = snapshot()
        return snapshot()
    }
#endif

    /// Corner targets use the cached authored silhouette, not asynchronous
    /// SceneKit hit tests or an approximation derived from toolbar width.
    var resizeCornerPoints: [DeviceResizeCorner: CGPoint] {
        if resizePose == projectionState { return resizePoints }
        resizePoints = [:]
        guard bounds.width > 1, bounds.height > 1,
              let corners = poseClip.projectedCorners(angle: pose.angle, quarterTurns: pose.quarterTurns, side: bounds.width),
              let envelope = poseClip.projectedBounds(angle: pose.angle, quarterTurns: pose.quarterTurns, side: bounds.width)
        else { return resizePoints }
        let dx = projectedHardwareBounds.minX - envelope.minX
        let dy = projectedHardwareBounds.minY - envelope.minY
        resizePoints = corners.mapValues { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        resizePose = projectionState
        return resizePoints
    }

    static var assetURL: URL {
        DeviceKitResources.duoModelURL
    }

    init?(screen: SimulatorScreenView, chrome: DeviceChrome) {
        guard let mode = chrome.displayMode,
              FileManager.default.fileExists(atPath: Self.assetURL.path),
              let source = SCNSceneSource(url: Self.assetURL, options: nil),
              let loaded = source.scene(options: [
                .animationImportPolicy: SCNSceneSource.AnimationImportPolicy.play
              ]) else { return nil }

        let nodes = Self.descendants(of: loaded.rootNode)
        guard let inner = loaded.rootNode.childNode(withName: Self.innerScreenName, recursively: true)
                ?? Self.screenNode(in: nodes, targetSize: CGSize(width: 15.797, height: 11.082)),
              let cover = loaded.rootNode.childNode(withName: Self.coverScreenName, recursively: true)
                ?? Self.screenNode(in: nodes, targetSize: CGSize(width: 7.739, height: 11.230)) else { return nil }

        innerScreen = inner
        coverScreen = cover
        activeScreen = mode == .cover ? cover : inner
        content = loaded.rootNode
        guard let clip = DuoPoseClip(root: loaded.rootNode) else { return nil }
        // Unsupported model schemas retain the ordinary framebuffer fallback;
        // there is no second, renderer-ray-tested geometry implementation.
        guard clip.projectedBounds(angle: 180, quarterTurns: 0, side: 1) != nil else { return nil }
        poseClip = clip
        super.init(frame: .zero, options: [
            SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue
        ])

        let scene = loaded
        scene.rootNode.addChildNode(cameraNode)
        installLighting(in: scene)
        self.scene = scene

        let camera = SCNCamera()
        camera.fieldOfView = DuoStage.fieldOfView
        camera.projectionDirection = .vertical
        camera.zNear = Double(DuoStage.nearPlane)
        camera.zFar = Double(DuoStage.farPlane)
        // The simulator IOSurface already contains display-referred sRGB.
        // HDR tone mapping here lifts blacks and desaturates the guest image.
        camera.wantsHDR = false
        cameraNode.camera = camera
        pointOfView = cameraNode

        backgroundColor = .clear
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        antialiasingMode = .multisampling4X
        allowsCameraControl = false
        rendersContinuously = true
        preferredFramesPerSecond = 60
        isPlaying = false
        loops = false

        prepareScreen(innerScreen)
        prepareScreen(coverScreen)
        setRenderedPose(DuoRenderPose(angle: CGFloat(mode.hingeAngle), quarterTurns: CGFloat(screen.quarterTurns)), chrome: chrome)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func containsHardware(at point: CGPoint) -> Bool {
        guard bounds.contains(point) else { return false }
        // Imported skinned screens need our UV hit test; the rigid housing
        // and buttons can use SceneKit's geometry hit test.
        if normalizedScreenPoint(at: point, clamped: false) != nil { return true }
        return !hitTest(point, options: [.rootNode: content, .ignoreHiddenNodes: true,
            .backFaceCulling: false, .searchMode: SCNHitTestSearchMode.any.rawValue]).isEmpty
    }

    func containsResizeFrame(at point: CGPoint) -> Bool {
        guard bounds.contains(point) else { return false }
        guard let envelope = poseClip.projectedBounds(angle: pose.angle, quarterTurns: pose.quarterTurns, side: bounds.width) else { return false }
        let rawPoint = CGPoint(x: point.x - projectedHardwareBounds.minX + envelope.minX,
            y: point.y - projectedHardwareBounds.minY + envelope.minY)
        guard let distance = poseClip.distanceToOutline(at: rawPoint, angle: pose.angle,
            quarterTurns: pose.quarterTurns, side: bounds.width), distance <= 5 else { return false }
        // Never intercept a touch on the posed screen, including its rounded
        // corners. The outline tolerance is only for the bezel/outside edge.
        if normalizedScreenPoint(at: point, clamped: false) != nil { return false }
        // A ray exactly on a rounded triangle edge can miss by a fraction of a
        // pixel after project/unproject. Do not turn that visible screen edge
        // into a resize handle. Only corner candidates use this extra check.
        return activeHitMesh?.nearestTextureCoordinate(to: point, project: { projectPoint($0) },
            unproject: { unprojectPoint($0) }, maximumDistance: 0.25) == nil
    }

    func setDisplayChrome(_ chrome: DeviceChrome) {
        nativeQuarterTurns = chrome.nativeQuarterTurns
    }

    func updateDisplay(_ display: SIDisplay?, engine: MetalScreenEngine, chrome: DeviceChrome) {
        let target = chrome.displayMode == .cover ? coverScreen : innerScreen
        let key = ObjectIdentifier(target)
        guard let display else {
            // A disconnect must not leave a live-looking image on either panel.
            screenTextures.removeAll()
            frozenPanelTexture = nil
            for node in [innerScreen, coverScreen] {
                for material in node.geometry?.materials ?? [] { material.diffuse.contents = nil }
            }
            return
        }
        if let requestedPanel, target !== requestedPanel { return }
        // An inactive panel can temporarily have no surface. Keep its last
        // texture, and never clear the other panel while waiting for damage.
        guard let surface = display.surface as? IOSurface else { return }
        if let cached = screenTextures[key], cached.surface === surface,
           cached.nativeQuarterTurns == chrome.nativeQuarterTurns { return }
        // SceneKit shades in linear space, so identify the display-referred
        // IOSurface as sRGB. Sampling an untagged UNORM texture treats encoded
        // values as linear and visibly washes out the entire framebuffer.
        guard let texture = engine.texture(for: surface, sRGB: true) else {
            screenTextures[key] = nil
            for material in target.geometry?.materials ?? [] { material.diffuse.contents = nil }
            return
        }
        screenTextures[key] = ScreenTexture(surface: surface, texture: texture,
            nativeQuarterTurns: chrome.nativeQuarterTurns)
        let transform = Self.textureTransform(quarterTurns: chrome.nativeQuarterTurns)
        for material in target.geometry?.materials ?? [] {
            material.diffuse.contents = texture
            material.diffuse.contentsTransform = transform
        }
        needsDisplay = true
    }

    /// The guest clears its inactive IOSurface. Detach the departing material
    /// before sending HID, keeping its own pixels visible through the turn.
    /// This bounded CPU copy happens only at a panel handoff, never per frame.
    func requestPanel(cover: Bool, engine: MetalScreenEngine) {
        let next = cover ? coverScreen : innerScreen
        let previous = requestedPanel ?? activeScreen
        guard previous !== next else { requestedPanel = next; return }
        if let frame = screenTextures[ObjectIdentifier(previous)] {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: frame.texture.pixelFormat,
                width: frame.texture.width, height: frame.texture.height, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = .shaderRead
            if let snapshot = engine.device.makeTexture(descriptor: descriptor) {
                IOSurfaceLock(frame.surface, .readOnly, nil)
                snapshot.replace(region: MTLRegionMake2D(0, 0, frame.texture.width, frame.texture.height), mipmapLevel: 0,
                    withBytes: IOSurfaceGetBaseAddress(frame.surface), bytesPerRow: frame.surface.bytesPerRow)
                IOSurfaceUnlock(frame.surface, .readOnly, nil)
                frozenPanelTexture = snapshot
                for material in previous.geometry?.materials ?? [] { material.diffuse.contents = snapshot }
            }
        }
        requestedPanel = next
        // Force the first incoming damage callback to restore the live texture,
        // even when CoreSimulator reuses the same IOSurface object.
        screenTextures[ObjectIdentifier(next)] = nil
    }

    override func layout() {
        super.layout()
        updateCamera()
    }

    override func setFrameSize(_ newSize: NSSize) {
        guard frame.size != newSize else { return }
        super.setFrameSize(newSize)
        updateCamera()
    }

    /// Converts a hit on the animated screen mesh back to the native simulator
    /// framebuffer. Rotation of the physical model accounts for guest
    /// orientation, so only the panel's native texture rotation is undone.
    func normalizedScreenPoint(at point: CGPoint, clamped: Bool) -> CGPoint? {
        guard let mesh = activeHitMesh else { return nil }
        func hit(_ point: CGPoint) -> CGPoint? {
            let near = unprojectPoint(SCNVector3(point.x, point.y, 0))
            let far = unprojectPoint(SCNVector3(point.x, point.y, 1))
            return mesh.textureCoordinate(from: near, to: far)
        }
        var uv = hit(point)
        if uv == nil, clamped {
            uv = mesh.nearestTextureCoordinate(to: point, project: { projectPoint($0) },
                                              unproject: { unprojectPoint($0) })
        }
        guard let uv else { return nil }
        // A Metal framebuffer texture already has a top-left origin. Apply
        // the same native rotation as textureTransform, without flipping V.
        let topOrigin = CGPoint(x: min(1, max(0, uv.x)), y: min(1, max(0, uv.y)))
        return ScreenGeometry.originalPoint(topOrigin, quarterTurns: nativeQuarterTurns)
    }

    func projectedScreenPoint(_ point: CGPoint) -> CGPoint? {
        let uv = ScreenGeometry.originalPoint(point, quarterTurns: -nativeQuarterTurns)
        guard let position = activeHitMesh?.position(at: uv) else { return nil }
        let projected = projectPoint(position)
        return CGPoint(x: projected.x, y: projected.y)
    }

    private var activeHitMesh: DuoScreenHitMesh? {
        let key = ObjectIdentifier(activeScreen)
        if screenHitMeshes[key] == nil { screenHitMeshes[key] = DuoScreenHitMesh(node: activeScreen) }
        return screenHitMeshes[key]
    }

    private func prepareScreen(_ node: SCNNode) {
        guard let geometry = node.geometry else { return }
        geometry.materials = geometry.materials.map { source in
            let material = source.copy() as? SCNMaterial ?? source
            material.lightingModel = .constant
            // DeviceKit's skinned display has mixed winding after deformation;
            // preserve its authored double-sided material.
            material.isDoubleSided = true
            material.blendMode = .replace
            material.transparency = 1
            material.transparent.contents = nil
            material.diffuse.intensity = 1
            material.multiply.contents = NSColor.white
            material.diffuse.wrapS = .clamp
            material.diffuse.wrapT = .clamp
            return material
        }
    }

    func setHingeAngle(_ angle: CGFloat, chrome: DeviceChrome, screen: SimulatorScreenView) {
        setRenderedPose(DuoRenderPose(angle: angle, quarterTurns: CGFloat(screen.quarterTurns)), chrome: chrome)
    }

    func setRenderedPose(_ pose: DuoRenderPose, chrome: DeviceChrome) {
        setDisplayChrome(chrome)
        guard self.pose != pose else { return }
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        SCNTransaction.animationDuration = 0
        if self.pose.angle != pose.angle { poseClip.apply(angle: pose.angle) }
        self.pose = pose
        activeScreen = DeviceDisplayMode.mode(forHingeAngle: Double(pose.angle)) == .cover ? coverScreen : innerScreen
        // Both panels stay textured; depth occlusion handles the visible handoff.
        updateCamera()
        SCNTransaction.commit()
        needsDisplay = true
    }

    private static func textureTransform(quarterTurns: Int) -> SCNMatrix4 {
        switch ScreenGeometry.normalizedQuarterTurns(quarterTurns) {
        case 1:
            SCNMatrix4(m11: 0, m12: -1, m13: 0, m14: 0,
                       m21: 1, m22: 0, m23: 0, m24: 0,
                       m31: 0, m32: 0, m33: 1, m34: 0,
                       m41: 0, m42: 1, m43: 0, m44: 1)
        case 2:
            SCNMatrix4(m11: -1, m12: 0, m13: 0, m14: 0,
                       m21: 0, m22: -1, m23: 0, m24: 0,
                       m31: 0, m32: 0, m33: 1, m34: 0,
                       m41: 1, m42: 1, m43: 0, m44: 1)
        case 3:
            SCNMatrix4(m11: 0, m12: 1, m13: 0, m14: 0,
                       m21: -1, m22: 0, m23: 0, m24: 0,
                       m31: 0, m32: 0, m33: 1, m34: 0,
                       m41: 1, m42: 0, m43: 0, m44: 1)
        default:
            SCNMatrix4Identity
        }
    }

    private func updateCamera() {
        guard bounds.width > 1, bounds.width == bounds.height else { return }
        let state = ProjectionState(size: bounds.size, pose: pose, anchored: anchorsHardwareToTop)
        guard projectionState != state else { return }
        projectionState = state
#if DEBUG
        cameraUpdateCount += 1
#endif
        let direction = SCNVector3(sin(pose.cameraOrbit), cos(pose.cameraOrbit), 0)
        let modelUp = SCNVector3(0, 0, -1)
        let viewRight = Self.cross(modelUp, direction)
        let rotation = pose.quarterTurns * .pi / 2
        let up = Self.add(Self.scaled(modelUp, cos(rotation)), Self.scaled(viewRight, -sin(rotation)))
        let center = SCNVector3(poseClip.center.x, poseClip.center.y, poseClip.center.z)
        let halfFOV = DuoStage.halfFieldOfView
        // Scale the fixed projection, not its camera distance. The enclosing
        // window is cropped to the current pose and is never a camera input.
        let limitingFOV = atan(tan(halfFOV) * DuoStage.cameraFitFraction)
        let distance = CGFloat(poseClip.radius) / sin(limitingFOV)
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        cameraNode.position = Self.add(center, Self.scaled(direction, distance))
        cameraNode.look(at: center, up: up, localFront: SCNVector3(0, 0, -1))
        projectedHardwareBounds = poseClip.projectedBounds(angle: pose.angle, quarterTurns: pose.quarterTurns, side: bounds.width) ?? .zero
        // Translate the *projection* in the same SceneKit transaction as the
        // skeleton. Moving the NSView separately could present a new offset
        // over an older Metal frame, making the top edge wobble. Neither lens
        // distance nor model scale changes while folding/rolling.
        var offset = CGPoint.zero
        if anchorsHardwareToTop {
            offset = CGPoint(x: bounds.midX - projectedHardwareBounds.midX,
                y: bounds.maxY - DuoStage.projectionTopInset - projectedHardwareBounds.maxY)
            projectedHardwareBounds = projectedHardwareBounds.offsetBy(dx: offset.x, dy: offset.y)
        }
        let near = DuoStage.nearPlane, far = DuoStage.farPlane
        let y = Float(1 / tan(halfFOV))
        let projection = simd_float4x4(columns: (
            SIMD4(y, 0, 0, 0), SIMD4(0, y, 0, 0),
            SIMD4(0, 0, -(far + near) / (far - near), -1),
            SIMD4(0, 0, -2 * far * near / (far - near), 0)))
        var translation = matrix_identity_float4x4
        translation.columns.3 = SIMD4(Float(offset.x * 2 / bounds.width), Float(offset.y * 2 / bounds.height), 0, 1)
        cameraNode.camera?.projectionTransform = SCNMatrix4(translation * projection)
        SCNTransaction.commit()
    }

    private static func cross(_ lhs: SCNVector3, _ rhs: SCNVector3) -> SCNVector3 {
        SCNVector3(lhs.y * rhs.z - lhs.z * rhs.y,
                   lhs.z * rhs.x - lhs.x * rhs.z,
                   lhs.x * rhs.y - lhs.y * rhs.x)
    }

    private static func scaled(_ vector: SCNVector3, _ scale: CGFloat) -> SCNVector3 {
        SCNVector3(vector.x * scale, vector.y * scale, vector.z * scale)
    }

    private static func add(_ lhs: SCNVector3, _ rhs: SCNVector3) -> SCNVector3 {
        SCNVector3(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z)
    }

    private static func descendants(of root: SCNNode) -> [SCNNode] {
        var result: [SCNNode] = []
        root.enumerateChildNodes { node, _ in result.append(node) }
        return result
    }

    private static func screenNode(in nodes: [SCNNode], targetSize: CGSize) -> SCNNode? {
        nodes.compactMap { node -> (SCNNode, CGFloat)? in
            guard node.geometry != nil else { return nil }
            let box = node.boundingBox
            let dimensions = [CGFloat(box.max.x - box.min.x), CGFloat(box.max.y - box.min.y), CGFloat(box.max.z - box.min.z)].sorted()
            guard dimensions[0] < 0.02 else { return nil }
            let error = abs(dimensions[2] - max(targetSize.width, targetSize.height))
                + abs(dimensions[1] - min(targetSize.width, targetSize.height))
            return (node, error)
        }.min { $0.1 < $1.1 }?.0
    }

    private func installLighting(in scene: SCNScene) {
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.color = NSColor(white: 0.5, alpha: 1)
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .omni
        key.light?.color = NSColor(white: 0.9, alpha: 1)
        key.light?.intensity = 900
        key.position = SCNVector3(-4, 24, -8)
        scene.rootNode.addChildNode(key)
    }
}
