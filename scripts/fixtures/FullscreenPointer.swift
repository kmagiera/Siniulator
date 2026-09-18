import AppKit

// Run beside a Debug --fullscreen-chrome-smoke invocation. Keep input outside
// the app so its production bundle needs no Accessibility or capture permission.
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let originalPointer = CGEvent(source: nil)!.location
func post(_ point: CGPoint, type: CGEventType = .mouseMoved) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!.post(tap: .cghidEventTap)
}
func finish(_ status: Int32) -> Never { post(originalPointer); exit(status) }
var last = ""
let timeout = Date().addingTimeInterval(120)
while Date() < timeout {
    let value = (try? String(contentsOf: directory.appendingPathComponent("phase.txt"), encoding: .utf8)) ?? ""
    let fields = value.split(separator: " ")
    if value != last, let phase = fields.first {
        if phase == "done" { print("PASS: external native pointer driver"); finish(0) }
        if phase == "failed" { fputs("Native full-screen chrome test failed.\n", stderr); finish(1) }
        if phase == "exit", fields.count == 3, let x = Double(fields[1]), let y = Double(fields[2]) {
            let point = CGPoint(x: x, y: y)
            post(point); post(point, type: .leftMouseDown); post(point, type: .leftMouseUp)
        } else if fields.count == 6, let x = Double(fields[2]), let top = Double(fields[3]),
                  let midX = Double(fields[4]), let midY = Double(fields[5]) {
            post(phase.hasPrefix("reveal") || phase.hasPrefix("header-") || phase == "exit-reveal" ? CGPoint(x: x, y: top) : CGPoint(x: midX, y: midY))
        } else { Thread.sleep(forTimeInterval: 0.02); continue }
        try! Data(String(phase).utf8).write(to: directory.appendingPathComponent("ack.txt"), options: .atomic)
        last = value
    }
    if let phase = fields.first, fields.count == 6,
       (try? String(contentsOf: directory.appendingPathComponent("capture.txt"), encoding: .utf8)) == String(phase),
       (try? String(contentsOf: directory.appendingPathComponent("captured.txt"), encoding: .utf8)) != String(phase) {
        if CGPreflightScreenCaptureAccess() {
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            let x = Double(fields[2])!, y = Double(fields[3])!
            let screen = NSScreen.screens.first { x >= $0.frame.minX && x <= $0.frame.maxX &&
                y >= NSScreen.screens.first!.frame.maxY - $0.frame.maxY && y <= NSScreen.screens.first!.frame.maxY - $0.frame.minY }!
            let rect = screen.frame
            let region = "\(Int(rect.minX)),\(Int(NSScreen.screens.first!.frame.maxY - rect.maxY)),\(Int(rect.width)),\(Int(rect.height))"
            capture.arguments = ["-x", "-R", region, directory.appendingPathComponent("fullscreen-\(phase).png").path]
            try! capture.run(); capture.waitUntilExit()
            guard capture.terminationStatus == 0 else { finish(1) }
        } else { print("SKIP: external screenshots need Screen Recording access") }
        try! Data(String(phase).utf8).write(to: directory.appendingPathComponent("captured.txt"), options: .atomic)
    }
    Thread.sleep(forTimeInterval: 0.01)
}
fputs("Timed out waiting for native full-screen chrome test.\n", stderr)
finish(1)
