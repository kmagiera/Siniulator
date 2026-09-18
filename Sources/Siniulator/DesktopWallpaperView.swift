import AppKit

/// A fullscreen Space has no desktop window behind it. Supply the configured
/// wallpaper to AppKit's within-window blur, without capturing other apps.
@MainActor final class DesktopWallpaperView: NSView {
    let imageView = NSImageView()
    private(set) var sourceURL: URL?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        imageView.imageScaling = .scaleAxesIndependently
        addSubview(imageView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    func reset() {
        // Release the large image outside fullscreen, and reread the current
        // wallpaper on the next entry even if its system URL is unchanged.
        imageView.image = nil
        sourceURL = nil
    }

    func refresh() {
        guard let window, let screen = window.screen else { return }
        let workspace = NSWorkspace.shared
        let url = workspace.desktopImageURL(for: screen)
        if sourceURL != url {
            sourceURL = url
            imageView.image = url.flatMap { $0.isFileURL ? NSImage(contentsOf: $0) : nil }
        }
        let options = workspace.desktopImageOptions(for: screen) ?? [:]
        layer?.backgroundColor = (options[.fillColor] as? NSColor ?? .black).cgColor
        guard let image = imageView.image else { return }
        let scaling = (options[.imageScaling] as? NSNumber).flatMap { NSImageScaling(rawValue: $0.uintValue) } ?? .scaleProportionallyUpOrDown
        let clipping = (options[.allowClipping] as? NSNumber)?.boolValue ?? false
        let placed = Self.imageFrame(image: image.size, desktop: screen.frame, scaling: scaling, clipping: clipping)
        // Match the whole display, even when this window occupies only one tile
        // or AppKit places its top below the camera housing.
        imageView.frame = convert(window.convertFromScreen(placed), from: nil)
    }

    nonisolated static func imageFrame(image: CGSize, desktop: CGRect, scaling: NSImageScaling, clipping: Bool) -> CGRect {
        guard image.width > 0, image.height > 0 else { return desktop }
        if scaling == .scaleAxesIndependently { return desktop }
        let x = desktop.width / image.width, y = desktop.height / image.height
        let proportionalScale = clipping ? max(x, y) : min(x, y)
        let factor: CGFloat
        switch scaling {
        case .scaleNone: factor = 1
        case .scaleProportionallyDown: factor = min(1, proportionalScale)
        default: factor = proportionalScale
        }
        let size = CGSize(width: image.width * factor, height: image.height * factor)
        return CGRect(x: desktop.midX - size.width / 2, y: desktop.midY - size.height / 2, width: size.width, height: size.height)
    }
}
