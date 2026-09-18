import AppKit

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
    let displayScale: CGFloat
    let displayDPI: CGFloat?
    let cornerRadius: CGFloat
    let outerRadius: CGFloat
    let border: NSEdgeInsets
    let padding: NSEdgeInsets
    let artwork: DeviceBezelArtwork?
    let buttons: [HardwareButton]
    let resourceURL: URL?
    private static var cache: [String: DeviceChrome] = [:]

    static func load(for device: SimulatorDevice) -> DeviceChrome {
        let identifier = device.deviceTypeIdentifier ?? device.name
        if let cached = cache[identifier] { return cached }
        let root = URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Profiles/DeviceTypes")
        let types = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let type = types.first { Bundle(url: $0)?.bundleIdentifier == identifier }
            ?? types.first { $0.deletingPathExtension().lastPathComponent == device.name }
        let resources = type?.appendingPathComponent("Contents/Resources")
        func plist(_ name: String) -> [String: Any] {
            guard let url = resources?.appendingPathComponent(name), let data = try? Data(contentsOf: url) else { return [:] }
            return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] ?? [:]
        }
        let profile = plist("profile.plist")
        let capabilities = plist("capabilities.plist")["capabilities"] as? [String: Any] ?? [:]
        let displays = capabilities["displays"] as? [[String: Any]] ?? []
        let display = displays.first { $0["deviceName"] as? String == "primary" } ?? displays.first ?? [:]
        let chromeID = profile["chromeIdentifier"] as? String ?? display["chromeIdentifier"] as? String
        let chromeName = chromeID?.split(separator: ".").last.map(String.init)
        let chromeURL = chromeName.map { URL(fileURLWithPath: "/Library/Developer/DeviceKit/Chrome/\($0).devicechrome/Contents/Resources") }
        let chrome = DeviceChrome(resources: chromeURL, display: display, isTablet: device.name.contains("iPad"))
        cache[identifier] = chrome
        return chrome
    }
    private init(resources: URL?, display: [String: Any], isTablet: Bool) {
        func number(_ dictionary: [String: Any], _ key: String, _ fallback: CGFloat) -> CGFloat {
            (dictionary[key] as? NSNumber).map { CGFloat(truncating: $0) } ?? fallback
        }
        displayScale = max(1, number(display, "scale", isTablet ? 2 : 3))
        let dpi = number(display, "hdpi", 0)
        displayDPI = dpi.isFinite && dpi > 0 ? dpi : nil
        logicalScreenSize = CGSize(width: number(display, "width", isTablet ? 1668 : 1206) / displayScale,
                                   height: number(display, "height", isTablet ? 2388 : 2622) / displayScale)
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
    let chrome: DeviceChrome
    var onButton: ((DeviceCommand) -> Void)?
    var maximumScale: CGFloat? { didSet { needsLayout = true; needsDisplay = true } }
    var showsBezels = true {
        didSet { pressed = nil; needsLayout = true; needsDisplay = true }
    }
    var pixelAligned = false { didSet { needsLayout = true } }
    var alignsScreenToTop = false { didSet { if oldValue != alignsScreenToTop { needsLayout = true } } }
    private var pressed: Int?
    override var isFlipped: Bool { true }
    init(screen: SimulatorScreenView, chrome: DeviceChrome) {
        self.screen = screen; self.chrome = chrome
        super.init(frame: .zero)
        addSubview(screen)
        screen.wantsLayer = true
        screen.layer?.masksToBounds = true
        screen.layer?.cornerCurve = .continuous
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    var geometry: ChromeGeometry { chrome.geometry(quarterTurns: screen.quarterTurns, showsBezels: showsBezels) }
    var fittedGeometry: (rect: CGRect, scale: CGFloat) {
        var fit = geometry.fit(in: bounds, maximumScale: maximumScale)
        if alignsScreenToTop { fit.rect.origin.y = bounds.minY }
        return fit
    }
    override func layout() {
        super.layout()
        let fit = fittedGeometry
        let frame = ChromeGeometry.placed(geometry.screen, in: fit.rect, scale: fit.scale)
        screen.frame = pixelAligned ? backingAlignedRect(frame,
            options: [.alignMinXNearest, .alignMinYNearest, .alignWidthNearest, .alignHeightNearest]) : frame
        screen.layer?.cornerRadius = chrome.cornerRadius * fit.scale
        screen.needsDisplay = true
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard showsBezels else { return }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let geometry = geometry, fit = geometry.fit(in: bounds, maximumScale: maximumScale)
        guard fit.scale > 0 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: fit.rect.minX, y: fit.rect.minY)
        context.scaleBy(x: fit.scale, y: fit.scale)
        switch geometry.quarterTurns % 4 {
        case 1: context.translateBy(x: geometry.portraitSize.height, y: 0); context.rotate(by: .pi / 2)
        case 2: context.translateBy(x: geometry.portraitSize.width, y: geometry.portraitSize.height); context.rotate(by: .pi)
        case 3: context.translateBy(x: 0, y: geometry.portraitSize.width); context.rotate(by: -.pi / 2)
        default: break
        }
        for (index, button) in chrome.buttons.enumerated() {
            let art = pressed == index ? button.pressedImage ?? button.image : button.image
            art.draw(in: button.rect(in: geometry.body), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        NSColor.black.setFill()
        let body = NSBezierPath(roundedRect: geometry.body, xRadius: chrome.outerRadius, yRadius: chrome.outerRadius)
        body.fill()
        if let artwork = chrome.artwork {
            artwork.draw(in: geometry.body)
        } else {
            NSColor(calibratedWhite: 0.35, alpha: 1).setStroke(); body.lineWidth = 2; body.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let geometry = geometry, fit = geometry.fit(in: bounds, maximumScale: maximumScale)
        for (index, button) in chrome.buttons.enumerated() where showsBezels {
            let rect = ChromeGeometry.placed(geometry.rotated(button.rect(in: geometry.body)), in: fit.rect, scale: fit.scale)
            if rect.contains(point), let command = button.command { pressed = index; needsDisplay = true; onButton?(command); return }
        }
        if window?.styleMask.contains(.fullScreen) != true { window?.performDrag(with: event) }
    }
    override func mouseUp(with event: NSEvent) { pressed = nil; needsDisplay = true }
}
