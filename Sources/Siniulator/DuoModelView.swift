import AppKit
import IOSurface
import Metal
import SceneKit
import SimulatorBridge

/// Renders Apple's DeviceKit model for the foldable simulator. The model is
/// loaded at runtime from the selected Xcode, so Siniulator neither copies nor
/// ships Apple's private artwork.
@MainActor final class DuoModelView: SCNView, SCNSceneRendererDelegate {
    private enum Animation {
        // Pose times in V68.usdz's 37.5-second animation timeline. The
        // `book_close` clip folds the inner display and turns the hardware;
        // the camera completes that turn so its cover display faces forward.
        static let innerOpen: TimeInterval = 10.833333333333334
        static let innerPartiallyOpen: TimeInterval = 12.5
        // Last closing keyframe: frame 380 at 24 fps. At 15.5 s the
        // cover is still six degrees away from facing the camera squarely.
        static let cover: TimeInterval = 380.0 / 24.0

        static func time(for mode: DeviceDisplayMode) -> TimeInterval {
            switch mode {
            case .cover: cover
            case .innerPartiallyOpen: innerPartiallyOpen
            case .innerFullyOpen: innerOpen
            }
        }

        static func time(forHingeAngle angle: CGFloat) -> TimeInterval {
            let angle = min(180, max(0, angle))
            return innerOpen + (cover - innerOpen) * (180 - angle) / 180
        }

        static func hingeAngle(at time: TimeInterval) -> CGFloat {
            let progress = (time - innerOpen) / (cover - innerOpen)
            return 180 * (1 - min(1, max(0, progress)))
        }

        static func cameraOrbit(at time: TimeInterval) -> CGFloat {
            DuoModelView.cameraOrbit(forHingeAngle: hingeAngle(at: time))
        }
    }

    private static let innerScreenName = "mQHVkATpIwJRVQx"
    private static let coverScreenName = "zaWsadDZpWAUDAX"

    private struct PoseAnimation {
        let node: SCNNode
        let key: String
        let animation: SCNAnimation
    }

    private let content: SCNNode
    private let poseAnimations: [PoseAnimation]
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
    private var guestQuarterTurns = 0
    private var nativeQuarterTurns = 0
    private var poseTime = Animation.innerOpen
    private var cameraOrbit: CGFloat = 0
    private var hasConfiguredPose = false
    private var referenceModelSize = CGSize(width: 16, height: 11.5)
    private(set) var projectedWidthFraction: CGFloat = 1
    var onProjectionWidthChange: ((CGFloat) -> Void)?
    private struct ResizePose: Equatable {
        let size: CGSize
        let time: TimeInterval
        let turns: Int
    }
    private var resizePose: ResizePose?
    private var renderedResizePose: ResizePose?
    private var resizePoints: [DeviceResizeCorner: CGPoint] = [:]

    /// Query the posed mesh, not its undeformed bounding box or the toolbar's
    /// approximate width fraction. In particular the cover already occupies a
    /// one-panel viewport and must not have its hit targets halved again.
    var resizeCornerPoints: [DeviceResizeCorner: CGPoint] {
        let pose = ResizePose(size: bounds.size, time: poseTime, turns: guestQuarterTurns)
        if resizePose == pose { return resizePoints }
        resizePoints = [:]
        guard bounds.width > 1, bounds.height > 1 else { return resizePoints }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let options: [SCNHitTestOption: Any] = [
            .rootNode: content, .ignoreHiddenNodes: true, .backFaceCulling: false,
            .searchMode: SCNHitTestSearchMode.any.rawValue
        ]
        func contains(_ point: CGPoint) -> Bool { !hitTest(point, options: options).isEmpty }
        guard contains(center) else { return resizePoints }
        for corner in DeviceResizeCorner.allCases {
            // SCNView uses bottom-left coordinates; callers convert these into
            // the flipped presentation view before installing cursor rects.
            let vertex = CGPoint(x: corner.isLeft ? bounds.minX : bounds.maxX,
                y: corner.isTop ? bounds.maxY : bounds.minY)
            func boundary(at angle: CGFloat) -> CGPoint {
                let dx = cos(angle) * (corner.isLeft ? -1 : 1)
                let dy = sin(angle) * (corner.isTop ? 1 : -1)
                let radius = min(bounds.width / 2 / max(0.0001, abs(dx)),
                    bounds.height / 2 / max(0.0001, abs(dy)))
                var low: CGFloat = 0, high = radius
                while high - low > 0.5 {
                    let mid = (low + high) / 2
                    if contains(CGPoint(x: center.x + dx * mid, y: center.y + dy * mid)) { low = mid }
                    else { high = mid }
                }
                return CGPoint(x: center.x + dx * low, y: center.y + dy * low)
            }
            func distance(_ point: CGPoint) -> CGFloat {
                hypot(point.x - vertex.x, point.y - vertex.y)
            }
            var bestAngle: CGFloat = 0
            var best = boundary(at: 0)
            let step = CGFloat.pi / 16
            for index in 1...8 {
                let angle = CGFloat(index) * step
                let point = boundary(at: angle)
                if distance(point) < distance(best) { best = point; bestAngle = angle }
            }
            var span = step
            for _ in 0..<5 {
                span /= 2
                for angle in [max(0, bestAngle - span), min(.pi / 2, bestAngle + span)] {
                    let point = boundary(at: angle)
                    if distance(point) < distance(best) { best = point; bestAngle = angle }
                }
            }
            resizePoints[corner] = best
        }
        resizePose = pose
        return resizePoints
    }

    nonisolated func renderer(_ renderer: any SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let pose = ResizePose(size: bounds.size, time: poseTime, turns: guestQuarterTurns)
            guard renderedResizePose != pose else { return }
            renderedResizePose = pose
            // Cursor queries may precede SceneKit's presentation of this pose.
            // Retry once it has drawn, and never cache an empty pre-draw hit.
            resizePose = nil
            if let window, let root = window.contentView { window.invalidateCursorRects(for: root) }
        }
    }

    static var assetURL: URL {
        DeviceKitResources.duoModelURL
    }

    nonisolated static func cameraOrbit(forHingeAngle angle: CGFloat) -> CGFloat {
        // Start at 140° closed (40° open), so the cover is coming into view
        // before the runtime dims the inner panel. Keep the camera's midpoint
        // aligned with the existing digitizer/haptic handoff at 15° open.
        let handoff = CGFloat(DeviceDisplayMode.coverHandoffAngle)
        let progress = angle > handoff
            ? max(0, (40 - angle) / (40 - handoff))
            : 1 + min(1, max(0, (handoff - angle) / handoff))
        return -.pi / 4 * progress
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
        poseAnimations = Self.takePoseAnimations(from: loaded.rootNode)
        super.init(frame: .zero, options: [
            SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue
        ])

        let scene = loaded
        scene.rootNode.addChildNode(cameraNode)
        installLighting(in: scene)
        self.scene = scene
        delegate = self

        let camera = SCNCamera()
        camera.fieldOfView = 31
        camera.zNear = 0.01
        camera.zFar = 200
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
        preferredFramesPerSecond = 30
        isPlaying = false
        loops = false

        prepareScreen(innerScreen)
        prepareScreen(coverScreen)
        applyPose(at: Animation.innerOpen)
        SCNTransaction.flush()
        captureReferenceModelSize()
        configure(chrome: chrome, screen: screen)
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

    func configure(chrome: DeviceChrome, screen: SimulatorScreenView) {
        guard let nextMode = chrome.displayMode else { return }
        guestQuarterTurns = screen.quarterTurns
        nativeQuarterTurns = chrome.nativeQuarterTurns
        if !hasConfiguredPose {
            hasConfiguredPose = true
            setPose(time: Animation.time(for: nextMode))
        } else {
            updateCamera()
            needsDisplay = true
        }
    }

    func updateDisplay(_ display: SIDisplay?, engine: MetalScreenEngine, chrome: DeviceChrome) {
        let target = chrome.displayMode == .cover ? coverScreen : innerScreen
        let key = ObjectIdentifier(target)
        guard let display else {
            // A disconnect must not leave a live-looking image on either panel.
            screenTextures.removeAll()
            for node in [innerScreen, coverScreen] {
                for material in node.geometry?.materials ?? [] { material.diffuse.contents = nil }
            }
            return
        }
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

    override func layout() {
        super.layout()
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
        guard chrome.displayMode != nil else { return }
        guestQuarterTurns = screen.quarterTurns
        nativeQuarterTurns = chrome.nativeQuarterTurns
        hasConfiguredPose = true
        setPose(time: Animation.time(forHingeAngle: angle))
    }

    private static func takePoseAnimations(from content: SCNNode) -> [PoseAnimation] {
        var result: [PoseAnimation] = []
        for node in [content] + descendants(of: content) {
            for key in node.animationKeys {
                guard let player = node.animationPlayer(forKey: key) else { continue }
                player.animation.repeatCount = 0
                player.animation.isRemovedOnCompletion = false
                player.animation.usesSceneTimeBase = false
                result.append(PoseAnimation(node: node, key: key, animation: player.animation))
                node.removeAnimation(forKey: key, blendOutDuration: 0)
            }
        }
        return result
    }

    private func applyPose(at time: TimeInterval) {
        for pose in poseAnimations {
            pose.node.removeAnimation(forKey: pose.key, blendOutDuration: 0)
            pose.animation.timeOffset = time
            let player = SCNAnimationPlayer(animation: pose.animation)
            player.speed = 0
            pose.node.addAnimationPlayer(player, forKey: pose.key)
            player.play()
        }
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

    private func setPose(time: TimeInterval) {
        poseTime = time
        cameraOrbit = Animation.cameraOrbit(at: time)
        applyPose(at: time)
        activeScreen = DeviceDisplayMode.mode(forHingeAngle: Double(Animation.hingeAngle(at: time))) == .cover
            ? coverScreen : innerScreen
        // Both panels stay textured during the camera orbit. The hardware's
        // depth occlusion replaces a hard visibility switch at 15 degrees.
        projectedWidthFraction = max(
            sin(Animation.hingeAngle(at: time) * .pi / 360),
            abs(cameraOrbit) / .pi)
        onProjectionWidthChange?(projectedWidthFraction)
        SCNTransaction.flush()
        updateCamera()
        needsDisplay = true
    }

    private func captureReferenceModelSize() {
        let points = modelPoints()
        guard !points.isEmpty else { return }
        let modelRight = SCNVector3(1, 0, 0)
        let modelUp = SCNVector3(0, 0, -1)
        func length(along axis: SCNVector3) -> CGFloat {
            let values = points.map { Self.dot($0, axis) }
            return max(0.1, values.max()! - values.min()!)
        }
        referenceModelSize = CGSize(width: length(along: modelRight), height: length(along: modelUp))
    }

    private func updateCamera() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        SCNTransaction.flush()
        let points = modelPoints()
        guard !points.isEmpty else { return }

        let direction = SCNVector3(sin(cameraOrbit), cos(cameraOrbit), 0)
        let modelUp = SCNVector3(0, 0, -1)
        let viewRight = Self.cross(modelUp, direction)
        let right: SCNVector3
        let up: SCNVector3
        switch ScreenGeometry.normalizedQuarterTurns(guestQuarterTurns) {
        case 1: right = modelUp; up = Self.negated(viewRight)
        case 2: right = Self.negated(viewRight); up = Self.negated(modelUp)
        case 3: right = Self.negated(modelUp); up = viewRight
        default: right = viewRight; up = modelUp
        }

        func range(along axis: SCNVector3) -> (min: CGFloat, max: CGFloat) {
            let values = points.map { Self.dot($0, axis) }
            return (values.min()!, values.max()!)
        }
        let horizontalRange = range(along: right)
        let verticalRange = range(along: up)
        let depthRange = range(along: direction)
        var center = Self.add(
            Self.add(Self.scaled(right, (horizontalRange.min + horizontalRange.max) / 2),
                     Self.scaled(up, (verticalRange.min + verticalRange.max) / 2)),
            Self.scaled(direction, (depthRange.min + depthRange.max) / 2))
        let orbitProgress = min(1, abs(cameraOrbit) / (.pi / 2))
        // The USD skinning bounds remain centered on the unfolded mesh. As the
        // camera reaches the cover side, follow the physical half-panel away
        // from the hinge so the closed phone stays centered in the viewport.
        // Follow the physical cover half in model space. Applying this offset
        // along the view's right axis made the closed phone drift in the same
        // screen direction after every quarter turn (and almost leave the view
        // upside down) instead of rotating the correction with the hardware.
        center = Self.add(center, SCNVector3(0, referenceModelSize.width * 0.28 * orbitProgress, 0))
        let turns = ScreenGeometry.normalizedQuarterTurns(guestQuarterTurns)
        // While viewing the inner display, retain the fully-open framing so the
        // fold recedes in depth without growing taller. Once the camera orbits
        // to the cover, blend toward the actual one-panel projected width.
        let framingWidth = referenceModelSize.width
            * (1 - orbitProgress * (1 - projectedWidthFraction))
        let horizontal = turns.isMultiple(of: 2) ? framingWidth : referenceModelSize.height
        let vertical = turns.isMultiple(of: 2) ? referenceModelSize.height : framingWidth
        let aspect = max(0.1, self.bounds.width / self.bounds.height)
        let halfFOV = CGFloat((cameraNode.camera?.fieldOfView ?? 31) * .pi / 360)
        // Keep only a small antialiasing guard around the hardware. The old
        // six-percent camera padding stacked with the layout margin and left a
        // conspicuous empty strip below the toolbar.
        let cameraPadding = 1.034 + 0.066 * orbitProgress
        let distance = max(vertical / 2, horizontal / (2 * aspect)) / tan(halfFOV) * cameraPadding
        let fold = (180 - Animation.hingeAngle(at: poseTime)) * .pi / 360
        let expectedDepth = referenceModelSize.width / 4 * sin(fold)
        // SceneKit reports the undeformed mesh depth here, so using that bound
        // would treat the closed phone's original full width as camera depth.
        // The fold angle is the reliable source for the deformed near edge.
        let depth = expectedDepth * 2 * (1 - orbitProgress)
        cameraNode.position = Self.add(center, Self.scaled(direction, distance + depth))
        cameraNode.look(at: center, up: up, localFront: SCNVector3(0, 0, -1))
    }

    /// Sample the undeformed model bounds in world space. Projecting these
    /// points onto the camera basis gives deterministic framing; the skinned
    /// half-panel poses receive analytic depth and centering corrections.
    private func modelPoints() -> [SCNVector3] {
        var points: [SCNVector3] = []
        for node in Self.descendants(of: content) where node.geometry != nil {
            let box = node.boundingBox
            for x in [box.min.x, box.max.x] {
                for y in [box.min.y, box.max.y] {
                    for z in [box.min.z, box.max.z] {
                        points.append(node.convertPosition(SCNVector3(x, y, z), to: nil))
                    }
                }
            }
        }
        return points
    }

    private static func dot(_ lhs: SCNVector3, _ rhs: SCNVector3) -> CGFloat {
        lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
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

    private static func negated(_ vector: SCNVector3) -> SCNVector3 {
        SCNVector3(-vector.x, -vector.y, -vector.z)
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
