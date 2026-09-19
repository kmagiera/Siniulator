import AppKit
import SimulatorBridge

enum DeviceDisplayMode: Int, CaseIterable {
    case cover
    case innerPartiallyOpen
    case innerFullyOpen

    var label: String {
        switch self {
        case .cover: "Cover"
        case .innerPartiallyOpen: "Partially Open"
        case .innerFullyOpen: "Fully Open"
        }
    }
    var tooltip: String {
        switch self {
        case .cover: "Show Cover Display"
        case .innerPartiallyOpen: "Show Inner Display, Partially Open"
        case .innerFullyOpen: "Show Inner Display, Fully Open"
        }
    }
    var deviceKitAssetName: String {
        switch self {
        case .cover: "v68.closed"
        case .innerPartiallyOpen: "v68.bent"
        case .innerFullyOpen: "v68.flat"
        }
    }
    var fallbackSymbol: String {
        switch self {
        case .cover: "rectangle.portrait"
        case .innerPartiallyOpen: "book"
        case .innerFullyOpen: "rectangle"
        }
    }
    @MainActor func image() -> NSImage? {
        if let image = DeviceKitResources.image(named: deviceKitAssetName) {
            image.accessibilityDescription = label
            return image
        }
        return NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: label)
    }
    var hingeAngle: Double {
        switch self {
        case .cover: 0
        case .innerPartiallyOpen: 120
        case .innerFullyOpen: 180
        }
    }
    static let coverHandoffAngle = 15.0
    static func mode(forHingeAngle angle: Double) -> DeviceDisplayMode {
        if angle <= coverHandoffAngle { return .cover }
        if angle >= 179.5 { return .innerFullyOpen }
        return .innerPartiallyOpen
    }
    // Toolbar selection describes the physical pose, not the active display
    // (whose handoff happens before the hinge reaches either endpoint).
    static func selectedMode(forHingeAngle angle: Double) -> DeviceDisplayMode {
        if angle <= 0 { return .cover }
        if angle >= 180 { return .innerFullyOpen }
        return .innerPartiallyOpen
    }
}

struct DuoHingeAnimation {
    let start: Double
    let target: Double
    var duration: TimeInterval { max(0.35, min(1, abs(target - start) / 180)) }

    func angle(at progress: Double) -> Double {
        if progress <= 0 { return start }
        if progress >= 1 { return target }
        // Quintic ease-in-out: zero velocity and acceleration at both ends.
        let t = progress
        let eased = t * t * t * (t * (6 * t - 15) + 10)
        return start + (target - start) * eased
    }
}

enum DeviceKitResources {
    static var pluginURL: URL {
        URL(fileURLWithPath: DeveloperDirectory.preferred)
            .deletingLastPathComponent()
            .appendingPathComponent(
                "SharedFrameworks/DeviceKit.framework/Versions/A/PlugIns/CoreDevicePopDeviceKitExtension.devicekitplugin")
    }

    static var duoModelURL: URL {
        pluginURL.appendingPathComponent("Contents/Resources/V68.usdz")
    }

    @MainActor
    static let bundle: Bundle? = {
        Bundle(url: pluginURL)
    }()

    @MainActor
    static func image(named name: String) -> NSImage? {
        bundle?.image(forResource: NSImage.Name(name))
    }
}

struct ChromeGeometry {
    let screenSize: CGSize
    let border: NSEdgeInsets
    let padding: NSEdgeInsets
    let quarterTurns: Int
    var portraitSize: CGSize {
        CGSize(width: screenSize.width + border.left + border.right + padding.left + padding.right,
               height: screenSize.height + border.top + border.bottom + padding.top + padding.bottom)
    }
    var size: CGSize { quarterTurns % 2 == 0 ? portraitSize : CGSize(width: portraitSize.height, height: portraitSize.width) }
    var body: CGRect {
        CGRect(x: padding.left, y: padding.top, width: screenSize.width + border.left + border.right,
               height: screenSize.height + border.top + border.bottom)
    }
    var screen: CGRect {
        rotated(CGRect(x: padding.left + border.left, y: padding.top + border.top, width: screenSize.width, height: screenSize.height))
    }
    func rotated(_ rect: CGRect) -> CGRect {
        switch quarterTurns % 4 {
        case 1: return CGRect(x: portraitSize.height - rect.maxY, y: rect.minX, width: rect.height, height: rect.width)
        case 2: return CGRect(x: portraitSize.width - rect.maxX, y: portraitSize.height - rect.maxY, width: rect.width, height: rect.height)
        case 3: return CGRect(x: rect.minY, y: portraitSize.width - rect.maxX, width: rect.height, height: rect.width)
        default: return rect
        }
    }
    func fit(in bounds: CGRect, maximumScale: CGFloat? = nil) -> (rect: CGRect, scale: CGFloat) {
        let factor = max(0, min(bounds.width / size.width, bounds.height / size.height, maximumScale ?? .greatestFiniteMagnitude))
        let rect = CGRect(x: bounds.midX - size.width * factor / 2, y: bounds.midY - size.height * factor / 2, width: size.width * factor, height: size.height * factor)
        return (rect, factor)
    }
    static func placed(_ rect: CGRect, in fitted: CGRect, scale: CGFloat) -> CGRect {
        CGRect(x: fitted.minX + rect.minX * scale, y: fitted.minY + rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
    }
}

@MainActor final class DeviceChrome {
    struct HardwareButton {
        let image: NSImage
        let pressedImage: NSImage?
        let anchor: String
        let offset: CGPoint
        let command: DeviceCommand?
        func rect(in body: CGRect) -> CGRect {
            let x = anchor == "right" ? body.maxX + offset.x : body.minX + offset.x - image.size.width
            return CGRect(x: x, y: body.minY + offset.y, width: image.size.width, height: image.size.height)
        }
    }
    let logicalScreenSize: CGSize
    let pixelWidth: UInt32
    let pixelHeight: UInt32
    let displayScale: CGFloat
    let displayDPI: CGFloat?
    let screenID: UInt32
    let digitizerTarget: UInt64
    let nativeQuarterTurns: Int
    let displayMode: DeviceDisplayMode?
    let cornerRadius: CGFloat
    let outerRadius: CGFloat
    let border: NSEdgeInsets
    let padding: NSEdgeInsets
    let artwork: DeviceBezelArtwork?
    let buttons: [HardwareButton]
    let resourceURL: URL?
    private static var cache: [String: DeviceChrome] = [:]

    static func load(for device: SimulatorDevice, displayMode: DeviceDisplayMode? = nil) -> DeviceChrome {
        let identifier = device.deviceTypeIdentifier ?? device.name
        let cacheKey = "\(identifier):\(displayMode?.rawValue ?? -1)"
        if let cached = cache[cacheKey] { return cached }
        let resources = profileResources(for: device)
        let profile = plist("profile.plist", in: resources)
        let capabilities = plist("capabilities.plist", in: resources)["capabilities"] as? [String: Any] ?? [:]
        let displays = capabilities["displays"] as? [[String: Any]] ?? []
        let integrated = displays.filter { ($0["displayType"] as? String) == "integrated" }
        let mode = integrated.count > 1 ? displayMode ?? .innerFullyOpen : nil
        let display = Self.preferredDisplay(in: displays, displayMode: mode)
        let digitizerTarget = Self.preferredDigitizerTarget(in: displays, displayMode: mode)
        let chromeID = (integrated.count > 1 ? display["chromeIdentifier"] : profile["chromeIdentifier"]) as? String
            ?? display["chromeIdentifier"] as? String
        let chromeName = chromeID?.split(separator: ".").last.map(String.init)
        let chromeURL = chromeName.map { URL(fileURLWithPath: "/Library/Developer/DeviceKit/Chrome/\($0).devicechrome/Contents/Resources") }
        let chrome = DeviceChrome(resources: integrated.count > 1 ? nil : chromeURL, display: display,
                                  digitizerTarget: digitizerTarget, displayMode: mode,
                                  isTablet: device.name.contains("iPad"))
        cache[cacheKey] = chrome
        return chrome
    }
    static func displayModes(for device: SimulatorDevice) -> [DeviceDisplayMode] {
        guard let capabilities = plist("capabilities.plist", in: profileResources(for: device))["capabilities"] as? [String: Any],
              let displays = capabilities["displays"] as? [[String: Any]] else { return [] }
        return displays.filter { ($0["displayType"] as? String) == "integrated" }.count > 1 ? DeviceDisplayMode.allCases : []
    }
    private static func profileResources(for device: SimulatorDevice) -> URL? {
        let identifier = device.deviceTypeIdentifier ?? device.name
        let root = URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Profiles/DeviceTypes")
        let types = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return (types.first { Bundle(url: $0)?.bundleIdentifier == identifier }
            ?? types.first { $0.deletingPathExtension().lastPathComponent == device.name })?
            .appendingPathComponent("Contents/Resources")
    }
    private static func plist(_ name: String, in resources: URL?) -> [String: Any] {
        guard let url = resources?.appendingPathComponent(name),
              let data = try? Data(contentsOf: url) else { return [:] }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] ?? [:]
    }
    static func preferredDisplay(in displays: [[String: Any]], displayMode: DeviceDisplayMode? = nil) -> [String: Any] {
        let integrated = displays.filter { ($0["displayType"] as? String) == "integrated" }
        let candidates = integrated.isEmpty ? displays : integrated
        if displayMode == .cover {
            return candidates.min { displayArea($0) < displayArea($1) } ?? [:]
        }
        return candidates.max { lhs, rhs in
            displayArea(lhs) < displayArea(rhs)
        } ?? [:]
    }
    static func preferredDigitizerTarget(in displays: [[String: Any]], displayMode: DeviceDisplayMode? = nil) -> UInt64 {
        let integrated = displays.filter { ($0["displayType"] as? String) == "integrated" }
        guard integrated.count > 1 else { return 0 }
        let display = preferredDisplay(in: integrated, displayMode: displayMode)
        // CoreDevice's DigitizerTarget uses 0 for the default screen and the
        // profile screen ID for display1...display10.
        return (display["screenID"] as? NSNumber)?.uint64Value ?? 0
    }
    private static func displayArea(_ display: [String: Any]) -> Double {
        ((display["width"] as? NSNumber)?.doubleValue ?? 0)
            * ((display["height"] as? NSNumber)?.doubleValue ?? 0)
    }
    private init(resources: URL?, display: [String: Any], digitizerTarget: UInt64 = 0,
                 displayMode: DeviceDisplayMode? = nil, isTablet: Bool) {
        func number(_ dictionary: [String: Any], _ key: String, _ fallback: CGFloat) -> CGFloat {
            (dictionary[key] as? NSNumber).map { CGFloat(truncating: $0) } ?? fallback
        }
        displayScale = max(1, number(display, "scale", isTablet ? 2 : 3))
        let dpi = number(display, "hdpi", 0)
        displayDPI = dpi.isFinite && dpi > 0 ? dpi : nil
        screenID = (display["screenID"] as? NSNumber)?.uint32Value ?? 0
        self.digitizerTarget = digitizerTarget
        nativeQuarterTurns = ScreenGeometry.nativeQuarterTurns(
            degrees: (display["nativeRotation"] as? NSNumber)?.intValue ?? 0)
        self.displayMode = displayMode
        let width = number(display, "width", isTablet ? 1668 : 1206)
        let height = number(display, "height", isTablet ? 2388 : 2622)
        pixelWidth = UInt32(max(0, width.rounded()))
        pixelHeight = UInt32(max(0, height.rounded()))
        logicalScreenSize = CGSize(width: width / displayScale, height: height / displayScale)
        cornerRadius = number(display, "cornerRadiusUL", isTablet ? 18 : 62)
        let data = resources.flatMap { try? Data(contentsOf: $0.appendingPathComponent("chrome.json")) }
        let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        resourceURL = json.isEmpty ? nil : resources
        let imageInfo = json["images"] as? [String: Any] ?? [:]
        let sizing = imageInfo["sizing"] as? [String: Any] ?? [:]
        border = NSEdgeInsets(top: number(sizing, "topHeight", 18), left: number(sizing, "leftWidth", 18),
                              bottom: number(sizing, "bottomHeight", 18), right: number(sizing, "rightWidth", 18))
        let pad = imageInfo["devicePadding"] as? [String: Any] ?? [:]
        padding = NSEdgeInsets(top: number(pad, "top", 0), left: number(pad, "left", 9), bottom: number(pad, "bottom", 0), right: number(pad, "right", 9))
        let paths = json["paths"] as? [String: Any] ?? [:]
        let outside = paths["simpleOutsideBorder"] as? [String: Any] ?? [:]
        outerRadius = number(outside, "cornerRadiusX", cornerRadius + border.left)
        func image(_ name: String?) -> NSImage? {
            guard let resources, let name else { return nil }
            return NSImage(contentsOf: resources.appendingPathComponent(name).appendingPathExtension("pdf"))
        }
        artwork = DeviceBezelArtwork { image(imageInfo[$0] as? String) }
        let commands: [String: DeviceCommand] = ["power": .lock, "volume-up": .volumeUp, "volume-down": .volumeDown, "home": .home]
        buttons = (json["inputs"] as? [[String: Any]] ?? []).compactMap { input in
            guard let art = image(input["image"] as? String) else { return nil }
            let offsets = input["offsets"] as? [String: Any] ?? [:]
            let normal = offsets["normal"] as? [String: Any] ?? [:]
            return HardwareButton(image: art, pressedImage: image(input["imageDown"] as? String), anchor: input["anchor"] as? String ?? "left",
                                  offset: CGPoint(x: number(normal, "x", 0), y: number(normal, "y", 0)), command: commands[input["name"] as? String ?? ""])
        }
    }
    func geometry(quarterTurns: Int, showsBezels: Bool = true) -> ChromeGeometry {
        ChromeGeometry(screenSize: logicalScreenSize, border: showsBezels ? border : NSEdgeInsetsZero,
            padding: showsBezels ? padding : NSEdgeInsetsZero, quarterTurns: quarterTurns)
    }
}

/// The screen is rendered separately; system bezel artwork only needs its eight edges and corners.
@MainActor struct DeviceBezelArtwork {
    private let topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight: NSImage

    init?(image: (String) -> NSImage?) {
        guard let topLeft = image("topLeft"), let top = image("top"), let topRight = image("topRight"),
              let left = image("left"), let right = image("right"),
              let bottomLeft = image("bottomLeft"), let bottom = image("bottom"), let bottomRight = image("bottomRight") else { return nil }
        self.topLeft = topLeft
        self.top = top
        self.topRight = topRight
        self.left = left
        self.right = right
        self.bottomLeft = bottomLeft
        self.bottom = bottom
        self.bottomRight = bottomRight
    }

    func draw(in rect: CGRect) {
        let leftWidth = topLeft.size.width, rightWidth = topRight.size.width
        let topHeight = topLeft.size.height, bottomHeight = bottomLeft.size.height
        let middleWidth = max(0, rect.width - leftWidth - rightWidth)
        let middleHeight = max(0, rect.height - topHeight - bottomHeight)
        let pieces: [(NSImage, CGRect)] = [
            (topLeft, CGRect(x: rect.minX, y: rect.minY, width: leftWidth, height: topHeight)),
            (top, CGRect(x: rect.minX + leftWidth, y: rect.minY, width: middleWidth, height: topHeight)),
            (topRight, CGRect(x: rect.maxX - rightWidth, y: rect.minY, width: rightWidth, height: topHeight)),
            (left, CGRect(x: rect.minX, y: rect.minY + topHeight, width: leftWidth, height: middleHeight)),
            (right, CGRect(x: rect.maxX - rightWidth, y: rect.minY + topHeight, width: rightWidth, height: middleHeight)),
            (bottomLeft, CGRect(x: rect.minX, y: rect.maxY - bottomHeight, width: leftWidth, height: bottomHeight)),
            (bottom, CGRect(x: rect.minX + leftWidth, y: rect.maxY - bottomHeight, width: middleWidth, height: bottomHeight)),
            (bottomRight, CGRect(x: rect.maxX - rightWidth, y: rect.maxY - bottomHeight, width: rightWidth, height: bottomHeight))
        ]
        // Stretch one-point edge PDFs: tiling leaves seams at fractional scales.
        NSGraphicsContext.current?.imageInterpolation = .high
        for (image, destination) in pieces {
            image.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}

@MainActor final class DeviceCanvasView: NSView {
    let screen: SimulatorScreenView
    private(set) var chrome: DeviceChrome
    var onButton: ((DeviceCommand) -> Void)?
    var onDuoProjectionWidthChange: ((CGFloat) -> Void)?
    var duoProjectionSizeFractions: CGSize { bodyView.duoProjectionSizeFractions }
    var usesDuoModel: Bool { showsBezels && bodyView.hasDuoModel }
    func containsDuoHardware(at point: CGPoint) -> Bool {
        bodyView.containsDuoHardware(at: bodyView.convert(point, from: self))
    }
    var duoProjectionWidthFraction: CGFloat { duoProjectionSizeFractions.width }
    var duoClosedProjectionWidthFraction: CGFloat {
        bodyView.hasDuoModel && screen.quarterTurns.isMultiple(of: 2) ? 0.5 : 1
    }
    var duoResizeCornerPoints: [DeviceResizeCorner: CGPoint]? {
        bodyView.duoResizeCornerPoints?.mapValues { convert($0, from: bodyView) }
    }
    var maximumScale: CGFloat? { didSet { needsLayout = true; needsDisplay = true } }
    var showsBezels = true {
        didSet { needsLayout = true; needsDisplay = true }
    }
    var pixelAligned = false { didSet { needsLayout = true } }
    var alignsScreenToTop = false { didSet { if oldValue != alignsScreenToTop { needsLayout = true } } }
    private let bodyView: DeviceBodyView
    private let modelChrome: DeviceChrome
    override var isFlipped: Bool { true }
    init(screen: SimulatorScreenView, chrome: DeviceChrome, modelChrome: DeviceChrome) {
        self.screen = screen
        self.chrome = chrome
        self.bodyView = DeviceBodyView(screen: screen, chrome: chrome)
        // Keep the 3D viewport independent of which framebuffer is receiving
        // touches. Switching panels during a pinch must not resize the camera.
        self.modelChrome = modelChrome
        super.init(frame: .zero)
        configureScreen(for: chrome)
        addSubview(bodyView)
        bodyView.onButton = { [weak self] command in self?.onButton?(command) }
        bodyView.onDuoProjectionWidthChange = { [weak self] fraction in
            guard let self else { return }
            self.onDuoProjectionWidthChange?(self.duoProjectionWidthFraction)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    var geometry: ChromeGeometry {
        if showsBezels, bodyView.hasDuoModel {
            return modelChrome.geometry(quarterTurns: ScreenGeometry.normalizedQuarterTurns(
                screen.quarterTurns + modelChrome.nativeQuarterTurns))
        }
        return chrome.geometry(quarterTurns: screen.displayQuarterTurns, showsBezels: showsBezels)
    }
    func updateDuoDisplay(_ display: SIDisplay, chrome: DeviceChrome) {
        bodyView.updateDuoDisplay(display, chrome: chrome)
    }
    var fittedGeometry: (rect: CGRect, scale: CGFloat) {
        var fit = geometry.fit(in: bounds, maximumScale: maximumScale)
        if alignsScreenToTop { fit.rect.origin.y = bounds.minY }
        return fit
    }
    func setChrome(_ chrome: DeviceChrome) {
        self.chrome = chrome
        configureScreen(for: chrome)
        bodyView.chrome = chrome
        needsLayout = true
        needsDisplay = true
    }
    func setHingeAngle(_ angle: CGFloat) {
        bodyView.setHingeAngle(angle)
    }
#if DEBUG
    func duoSnapshot() -> NSImage? { bodyView.duoSnapshot() }
#endif
    private func configureScreen(for chrome: DeviceChrome) {
        if screen.display == nil || screen.displayChrome?.screenID == chrome.screenID {
            screen.nativeQuarterTurns = chrome.nativeQuarterTurns
        }
    }
    override func layout() {
        super.layout()
        let fit = fittedGeometry
        bodyView.frame = fit.rect
        bodyView.scale = fit.scale
        bodyView.showsBezels = showsBezels
        bodyView.pixelAligned = pixelAligned
    }
}

@MainActor private final class DeviceBodyView: NSView {
    func containsDuoHardware(at point: CGPoint) -> Bool {
        guard showsBezels, let duoModel else { return false }
        return duoModel.containsHardware(at: duoModel.convert(point, from: self))
    }
    let screen: SimulatorScreenView
    var chrome: DeviceChrome { didSet { pressed = nil; needsLayout = true; needsDisplay = true } }
    var scale: CGFloat = 1 { didSet { needsLayout = true; needsDisplay = true } }
    var showsBezels = true { didSet { pressed = nil; needsLayout = true; needsDisplay = true } }
    var pixelAligned = false { didSet { needsLayout = true } }
    var onButton: ((DeviceCommand) -> Void)?
    var onDuoProjectionWidthChange: ((CGFloat) -> Void)?
    var duoProjectionSizeFractions: CGSize {
        guard let fraction = duoModel?.projectedWidthFraction else { return CGSize(width: 1, height: 1) }
        // The 3D hardware follows the requested device orientation. The inner
        // and cover displays have different native texture rotations, but that
        // must not move the physical resize handles to a different axis.
        return screen.quarterTurns.isMultiple(of: 2)
            ? CGSize(width: fraction, height: 1)
            : CGSize(width: 1, height: fraction)
    }
    private var pressed: Int?
    private var duoModel: DuoModelView?
    var hasDuoModel: Bool { duoModel != nil }
    var duoResizeCornerPoints: [DeviceResizeCorner: CGPoint]? {
        guard showsBezels, let duoModel else { return nil }
        return duoModel.resizeCornerPoints.mapValues { convert($0, from: duoModel) }
    }
    override var isFlipped: Bool { true }
    private var geometry: ChromeGeometry {
        chrome.geometry(quarterTurns: screen.displayQuarterTurns, showsBezels: showsBezels)
    }

    init(screen: SimulatorScreenView, chrome: DeviceChrome) {
        self.screen = screen
        self.chrome = chrome
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        duoModel = DuoModelView(screen: screen, chrome: chrome)
        if let duoModel { addSubview(duoModel) }
        addSubview(screen)
        addSubview(screen.gestureOverlay)
        screen.wantsLayer = true
        screen.layer?.masksToBounds = true
        screen.layer?.cornerCurve = .continuous
        screen.onDisplayChange = { [weak self] display in
            guard let self else { return }
            self.duoModel?.updateDisplay(display, engine: self.screen.renderer.engine,
                chrome: self.screen.displayChrome ?? self.chrome)
        }
        duoModel?.onProjectionWidthChange = { [weak self] fraction in
            self?.onDuoProjectionWidthChange?(fraction)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    func updateDuoDisplay(_ display: SIDisplay, chrome: DeviceChrome) {
        duoModel?.updateDisplay(display, engine: screen.renderer.engine, chrome: chrome)
    }

    func setHingeAngle(_ angle: CGFloat) {
        duoModel?.setHingeAngle(angle, chrome: chrome, screen: screen)
    }
#if DEBUG
    func duoSnapshot() -> NSImage? { duoModel?.snapshot() }
#endif

    override func layout() {
        super.layout()
        if let duoModel, showsBezels {
            duoModel.isHidden = false
            duoModel.frame = bounds
            duoModel.configure(chrome: chrome, screen: screen)
            screen.frame = bounds
            screen.gestureOverlay.frame = screen.frame
            screen.renderer.layer.isHidden = true
            screen.renderer.layer.opacity = 0
            screen.renderer.setEnabled(false)
            screen.layer?.cornerRadius = 0
            screen.layer?.masksToBounds = false
            screen.coordinateMapper = { [weak screen, weak duoModel] point, clamped in
                guard let screen, let duoModel else { return nil }
                return duoModel.normalizedScreenPoint(at: duoModel.convert(point, from: screen), clamped: clamped)
            }
            screen.coordinateProjector = { [weak screen, weak duoModel] point in
                guard let screen, let duoModel, let projected = duoModel.projectedScreenPoint(point) else { return nil }
                return screen.convert(projected, from: duoModel)
            }
            needsDisplay = true
            return
        }
        duoModel?.isHidden = true
        screen.renderer.layer.isHidden = false
        screen.renderer.layer.opacity = 1
        screen.renderer.setEnabled(true)
        screen.coordinateMapper = nil
        screen.coordinateProjector = nil
        let frame = ChromeGeometry.placed(geometry.screen, in: bounds, scale: scale)
        screen.frame = pixelAligned ? backingAlignedRect(frame,
            options: [.alignMinXNearest, .alignMinYNearest, .alignWidthNearest, .alignHeightNearest]) : frame
        screen.gestureOverlay.frame = screen.frame
        screen.layer?.cornerRadius = chrome.cornerRadius * scale
        screen.layer?.masksToBounds = true
        screen.needsDisplay = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard showsBezels, scale > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        if duoModel != nil { return }
        let geometry = geometry
        context.saveGState()
        defer { context.restoreGState() }
        context.scaleBy(x: scale, y: scale)
        switch geometry.quarterTurns % 4 {
        case 1: context.translateBy(x: geometry.portraitSize.height, y: 0); context.rotate(by: .pi / 2)
        case 2: context.translateBy(x: geometry.portraitSize.width, y: geometry.portraitSize.height); context.rotate(by: .pi)
        case 3: context.translateBy(x: 0, y: geometry.portraitSize.width); context.rotate(by: -.pi / 2)
        default: break
        }
        for (index, button) in chrome.buttons.enumerated() {
            let art = pressed == index ? button.pressedImage ?? button.image : button.image
            art.draw(in: button.rect(in: geometry.body), from: .zero, operation: .sourceOver,
                     fraction: 1, respectFlipped: true, hints: nil)
        }
        NSColor.black.setFill()
        let body = NSBezierPath(roundedRect: geometry.body, xRadius: chrome.outerRadius, yRadius: chrome.outerRadius)
        body.fill()
        if let artwork = chrome.artwork {
            artwork.draw(in: geometry.body)
        } else {
            NSColor(calibratedWhite: 0.35, alpha: 1).setStroke()
            body.lineWidth = 2
            body.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let geometry = geometry
        for (index, button) in chrome.buttons.enumerated() where showsBezels {
            let rect = ChromeGeometry.placed(geometry.rotated(button.rect(in: geometry.body)), in: bounds, scale: scale)
            if rect.contains(point), let command = button.command {
                pressed = index
                needsDisplay = true
                onButton?(command)
                return
            }
        }
        if window?.styleMask.contains(.fullScreen) != true { window?.performDrag(with: event) }
    }
    override func mouseUp(with event: NSEvent) { pressed = nil; needsDisplay = true }
}
