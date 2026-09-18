import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let originalPointer = CGEvent(source: nil)!.location
defer { CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: originalPointer, mouseButton: .left)!.post(tap: .cghidEventTap) }
func post(_ point: CGPoint, type: CGEventType = .mouseMoved, option: Bool = false) {
    let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!
    event.flags = option ? .maskAlternate : []
    event.post(tap: .cghidEventTap)
}
func capture(_ name: String, region: String) throws {
    guard CGPreflightScreenCaptureAccess() else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-R", region, directory.appendingPathComponent(name + ".png").path]
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw NSError(domain: "ToolbarCapture", code: 1) }
}
var last = ""
let deadline = Date().addingTimeInterval(150)
while Date() < deadline {
    let status = (try? String(contentsOf: directory.appendingPathComponent("toolbar-ack.txt"), encoding: .utf8)) ?? ""
    if status == "done" { print("PASS: real pointer toolbar driver"); break }
    if status == "failed" { exit(1) }
    guard let data = try? Data(contentsOf: directory.appendingPathComponent("toolbar-phase.json")),
          let phase = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let name = phase["name"] as? String, name != last else { Thread.sleep(forTimeInterval: 0.02); continue }
    let region = phase["region"] as! String
    let activate = phase["activate"] as! [Double]
    let rest = phase["rest"] as! [Double]
    let blank = CGPoint(x: activate[0], y: activate[1])
    post(blank); post(blank, type: .leftMouseDown); post(blank, type: .leftMouseUp)
    post(CGPoint(x: rest[0], y: rest[1]))
    Thread.sleep(forTimeInterval: 0.25)
    try capture(name + "-idle", region: region)
    for target in phase["targets"] as! [[String: Any]] {
        let point = CGPoint(x: target["x"] as! Double, y: target["y"] as! Double)
        let label = name + "-" + String(target["index"] as! Int)
        post(point); Thread.sleep(forTimeInterval: 0.2)
        try capture(label + "-hover", region: region)
        post(point, type: .leftMouseDown); Thread.sleep(forTimeInterval: 0.25)
        // Capture outside the app: NSButton's tracking loop blocks async work
        // inside the app while its native pressed effect is visible.
        try capture(label + "-pressed", region: region)
        post(point, type: .leftMouseUp); Thread.sleep(forTimeInterval: 0.1)
        if target["index"] as! Int == 2, phase["optionRotate"] as? Bool == true {
            post(point, type: .leftMouseDown, option: true)
            post(point, type: .leftMouseUp, option: true)
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
    try Data(name.utf8).write(to: directory.appendingPathComponent("toolbar-ack.txt"), options: .atomic)
    last = name
}
if Date() >= deadline { fputs("Toolbar pointer test timed out.\n", stderr); exit(1) }
if !CGPreflightScreenCaptureAccess() { print("SKIP: toolbar images need external Screen Recording access") }
