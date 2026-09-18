import AppKit

// WindowServer images are necessary: cacheDisplay omits behind-window effects
// and cannot detect the extra fullscreen titlebar background painted by AppKit.
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let regions = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("appearance-regions.json"))) as! [String: [Double]]
func load(_ name: String) throws -> NSBitmapImageRep {
    let url = directory.appendingPathComponent("fullscreen-\(name).png")
    guard let bitmap = NSBitmapImageRep(data: try Data(contentsOf: url)) else { fatalError("Invalid screenshot: \(name)") }
    return bitmap
}
func pixels(_ bitmap: NSBitmapImageRep, region: [Double]) -> [[CGFloat]] {
    let x = Int(region[0] * Double(bitmap.pixelsWide)), y = Int(region[1] * Double(bitmap.pixelsHigh))
    let width = max(1, Int(region[2] * Double(bitmap.pixelsWide))), height = max(1, Int(region[3] * Double(bitmap.pixelsHigh)))
    return stride(from: y, to: y + height, by: max(1, height / 32)).flatMap { row in
        stride(from: x, to: x + width, by: max(1, width / 32)).map { column in
            let color = bitmap.colorAt(x: column, y: row)!.usingColorSpace(.deviceRGB)!
            return [color.redComponent, color.greenComponent, color.blueComponent]
        }
    }
}
let baseline = try load("idle")
let header = pixels(baseline, region: regions["header"]!)
var lines: [String] = []
if let expected = regions["header-brightness"] {
    let brightness = header.flatMap { $0 }.reduce(0, +) / CGFloat(header.count * 3)
    guard brightness >= expected[0], brightness <= expected[1] else {
        fputs("FAIL: fullscreen toolbar background does not match its appearance (brightness=\(brightness)).\n", stderr)
        exit(1)
    }
    lines.append("PASS: fullscreen toolbar background matches its light/dark appearance.")
}
if let expected = regions["appearance-toggle-brightness"] {
    let changed = pixels(try load("appearance-toggle"), region: regions["header"]!)
    let brightness = changed.flatMap { $0 }.reduce(0, +) / CGFloat(changed.count * 3)
    guard brightness >= expected[0], brightness <= expected[1] else {
        fputs("FAIL: fullscreen toolbar did not render its changed appearance (brightness=\(brightness)).\n", stderr)
        exit(1)
    }
    lines.append("PASS: fullscreen toolbar background follows a live light/dark change.")
}
for phase in ["header-title", "header-right", "reveal-system-menu", "reveal-system-status", "header-native-hover", "hide"] {
    let current = pixels(try load(phase), region: regions["header"]!)
    let difference = zip(header, current).flatMap { left, right in zip(left, right).map { abs($0 - $1) } }.max()!
    guard difference <= 1.0 / 255 else {
        fputs("FAIL: toolbar background changed during \(phase), maximum RGB difference=\(difference).\n", stderr)
        exit(1)
    }
    lines.append("PASS: identical toolbar background during \(phase) (maximum RGB difference=\(difference)).")
}
let body = pixels(baseline, region: regions["body"]!)
let ranges = (0..<3).map { channel in body.map { $0[channel] }.max()! - body.map { $0[channel] }.min()! }
if CommandLine.arguments.contains("--expect-backdrop-variation"), ranges.max()! <= 8.0 / 255 {
    fputs("FAIL: fullscreen backdrop is a flat color; expected visible wallpaper variation.\n", stderr)
    exit(1)
}
lines.append("Backdrop RGB ranges: \(ranges). Wallpaper variation assertion \(CommandLine.arguments.contains("--expect-backdrop-variation") ? "enabled" : "disabled (uniform wallpapers are valid)").")
let result = lines.joined(separator: "\n") + "\n"
try Data(result.utf8).write(to: directory.appendingPathComponent("fullscreen-appearance-results.txt"))
print(result)
