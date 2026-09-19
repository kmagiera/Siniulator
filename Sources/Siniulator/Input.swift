import AppKit
import CoreFoundation
import XPC
import SimulatorBridge

enum TouchPhase: UInt64 { case start = 0, move = 1, end = 2 }

@MainActor final class SimulatorInput {
    private let core: SICoreSimulator
    private let device: Any
    private var digitizerTarget: UInt64
    private var connection: InputConnection?
    private var vendorConnection: InputConnection?
    private var legacy: SILegacyInput?
    var onError: ((Error) -> Void)?
#if DEBUG
    var transportName: String { connection == nil ? "Indigo HID" : "DTUHID" }
#endif
    var usesNativeRotation: Bool { connection != nil }

    init(core: SICoreSimulator, device: Any, digitizerTarget: UInt64 = 0) throws {
        self.core = core
        self.device = device
        self.digitizerTarget = digitizerTarget
        typealias Endpoint = @convention(c) (mach_port_t, UInt64, UInt64) -> xpc_object_t?
        typealias Connection = @convention(c) (xpc_object_t) -> xpc_connection_t?
        typealias Enable = @convention(c) (xpc_connection_t) -> Void
        let handle = dlopen(nil, RTLD_NOW)
        if let handle,
           let ep = dlsym(handle, "xpc_endpoint_create_mach_port_4sim"),
           let cn = dlsym(handle, "xpc_connection_create_from_endpoint"),
           let en = dlsym(handle, "xpc_connection_enable_sim2host_4sim"),
           let port = try? core.lookup(Self.serviceName, device: device), port != 0,
           let endpoint = unsafeBitCast(ep, to: Endpoint.self)(port, 0, 0),
           let connection = unsafeBitCast(cn, to: Connection.self)(endpoint) {
            unsafeBitCast(en, to: Enable.self)(connection)
            self.connection = InputConnection(connection)
            xpc_connection_set_target_queue(connection, .global(qos: .userInteractive))
            xpc_connection_set_event_handler(connection) { [weak self] event in
                if xpc_get_type(event) == XPC_TYPE_ERROR {
                    DispatchQueue.main.async {
                        self?.onError?(SimulatorError(message: "The simulator input connection closed. Retry the connection."))
                    }
                }
            }
            xpc_connection_resume(connection)

            if digitizerTarget != 0,
               let port = try? core.lookup(Self.vendorServiceName, device: device), port != 0,
               let endpoint = unsafeBitCast(ep, to: Endpoint.self)(port, 0, 0),
               let vendorConnection = unsafeBitCast(cn, to: Connection.self)(endpoint) {
                unsafeBitCast(en, to: Enable.self)(vendorConnection)
                self.vendorConnection = InputConnection(vendorConnection)
                xpc_connection_set_target_queue(vendorConnection, .global(qos: .userInteractive))
                xpc_connection_set_event_handler(vendorConnection) { _ in }
                xpc_connection_resume(vendorConnection)
            }
        } else {
            legacy = try SILegacyInput(device: device)
        }
    }

    static let serviceName = "com.apple.coredevice.feature.remote.hid.digitizer"
    static let vendorServiceName = "com.apple.coredevice.feature.remote.hid.vendordefined"

    func setDigitizerTarget(_ target: UInt64) { digitizerTarget = target }

    func activate() async throws {
        guard let connection = connection?.value else { return }
        try await activate(connection, feature: Self.serviceName)
        if let vendorConnection = vendorConnection?.value {
            try await activate(vendorConnection, feature: Self.vendorServiceName)
        }
        try await Task.sleep(for: .milliseconds(200))
    }

    private func activate(_ connection: xpc_connection_t, feature: String) async throws {
        let payload = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(payload, "usageCode", 0)
        xpc_dictionary_set_uint64(payload, "state", 2)
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, "messageType", "IndigoKeyboardButtonEvent")
        xpc_dictionary_set_bool(message, "isBarrier", true)
        xpc_dictionary_set_string(message, "featureIdentifier", feature)
        xpc_dictionary_set_value(message, "payload", payload)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let reply = InputReply(continuation)
            xpc_connection_send_message_with_reply(connection, message, .global(qos: .userInitiated)) { event in
                if xpc_get_type(event) == XPC_TYPE_ERROR {
                    reply.finish(.failure(SimulatorError(message: "Could not activate simulator input feature \(feature). Retry the connection.")))
                } else { reply.finish(.success(())) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                reply.finish(.failure(SimulatorError(message: "Simulator input feature \(feature) activation timed out.")))
            }
        }
    }

    private func send(_ type: String, payload: xpc_object_t) {
        guard let connection = connection?.value else { return }
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, "messageType", type)
        xpc_dictionary_set_bool(message, "isBarrier", false)
        xpc_dictionary_set_string(message, "featureIdentifier", Self.serviceName)
        xpc_dictionary_set_value(message, "payload", payload)
        xpc_connection_send_message(connection, message)
    }

    @discardableResult
    func setHingeAngle(_ angle: Double) -> Bool {
        guard let data = Self.hingeEventData(angle: angle) else { return false }
        return sendVendorDefined(data)
    }

    /// V68 publishes orientation through the same Virtualization provider as
    /// its hinge. Sending a normal device rotation is immediately overwritten
    /// by that provider, so foldables must update the provider itself.
    @discardableResult
    func setFoldableOrientation(quarterTurns: Int) -> Bool {
        guard let data = Self.orientationEventData(quarterTurns: quarterTurns) else { return false }
        return sendVendorDefined(data)
    }

    @discardableResult
    private func sendVendorDefined(_ data: Data) -> Bool {
        guard let connection = vendorConnection?.value else { return false }

        let payload = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(payload, "usagePage", 0xff61)
        xpc_dictionary_set_uint64(payload, "usage", 0x5b)
        xpc_dictionary_set_uint64(payload, "version", 0)
        data.withUnsafeBytes { bytes in
            xpc_dictionary_set_data(payload, "data", bytes.baseAddress, bytes.count)
        }
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, "messageType", "IndigoVendorDefinedEvent")
        xpc_dictionary_set_string(message, "featureIdentifier", Self.vendorServiceName)
        xpc_dictionary_set_value(message, "payload", payload)
        xpc_connection_send_message(connection, message)
        return true
    }

    nonisolated static func orientationEventData(quarterTurns: Int) -> Data? {
        let values = ["portrait", "landscape-right", "pud", "landscape-left"]
        return virtualMachineEventData(source: "orientation-picker-control", type: "enum",
            value: values[ScreenGeometry.normalizedQuarterTurns(quarterTurns)])
    }

    nonisolated static func hingeEventData(angle: Double) -> Data? {
        virtualMachineEventData(source: "hinge-slider-control", type: "range", value: angle)
    }

    nonisolated private static func virtualMachineEventData(source: String, type: String, value: Any) -> Data? {
        let dictionary: NSDictionary = ["provider": "com.apple.Virtualization.VirtualMachines",
                                        "source": source, "type": type, "value": value]
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let symbol = dlsym(handle, "IOCFSerialize") else { return nil }
        defer { dlclose(handle) }
        typealias Serialize = @convention(c) (CFTypeRef, CFOptionFlags) -> Unmanaged<CFData>?
        guard let serialized = unsafeBitCast(symbol, to: Serialize.self)(dictionary, 1) else { return nil }
        return serialized.takeRetainedValue() as Data
    }

    func touch(_ point: CGPoint, phase: TouchPhase, edge: UInt64 = 0, second: CGPoint? = nil) {
        if connection != nil {
            let payload = xpc_dictionary_create(nil, nil, 0)
            func contact(_ point: CGPoint) -> xpc_object_t {
                let value = xpc_dictionary_create(nil, nil, 0)
                xpc_dictionary_set_double(value, "x", point.x)
                xpc_dictionary_set_double(value, "y", point.y)
                return value
            }
            xpc_dictionary_set_value(payload, "pointOne", contact(point))
            if let second { xpc_dictionary_set_value(payload, "pointTwo", contact(second)) }
            xpc_dictionary_set_uint64(payload, "eventType", phase.rawValue)
            xpc_dictionary_set_uint64(payload, "edge", edge)
            xpc_dictionary_set_uint64(payload, "target", digitizerTarget)
            send("IndigoDigitizerEvent", payload: payload)
        } else {
            let event: UInt = phase == .start ? 1 : (phase == .end ? 2 : 6)
            legacy?.sendTouch(point, phase: event, edge: UInt32(edge), secondPoint: second.map(NSValue.init(point:))) { [weak self] error in
                if let error { Task { @MainActor in self?.onError?(error) } }
            }
        }
    }

    func key(_ usage: UInt64, down: Bool) {
        if connection != nil {
            let payload = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_uint64(payload, "usageCode", usage)
            xpc_dictionary_set_uint64(payload, "state", down ? 1 : 2)
            send("IndigoKeyboardButtonEvent", payload: payload)
        } else {
            legacy?.sendKey(UInt32(usage), down: down) { [weak self] error in
                if let error { Task { @MainActor in self?.onError?(error) } }
            }
        }
    }

    func button(usage: UInt64, legacySource: Int32) {
        sendButton(usage: usage, legacySource: legacySource, down: true)
        Task { [self] in
            try? await Task.sleep(for: .milliseconds(15))
            sendButton(usage: usage, legacySource: legacySource, down: false)
        }
    }
    private func sendButton(usage: UInt64, legacySource: Int32, down: Bool) {
        if connection != nil {
            let payload = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_uint64(payload, "usagePage", 0x0c)
            xpc_dictionary_set_uint64(payload, "usageCode", usage)
            xpc_dictionary_set_uint64(payload, "state", down ? 1 : 2)
            send("IndigoButtonEvent", payload: payload)
        } else {
            let completion: @Sendable (Error?) -> Void = { [weak self] error in
                if let error { Task { @MainActor in self?.onError?(error) } }
            }
            if usage == 0xe9 || usage == 0xea {
                legacy?.sendConsumerUsage(UInt32(usage), down: down, completion: completion)
            } else { legacy?.sendButton(legacySource, down: down, completion: completion) }
        }
    }

    func rotate(orientation: UInt32, udid: String) async throws {
        if usesNativeRotation {
            let orientations = [1: "portrait", 2: "portraitUpsideDown", 3: "landscapeRight", 4: "landscapeLeft"]
            let data = try await CommandRunner.run("/usr/bin/xcrun", ["devicectl", "device", "orientation", "set", "--device", udid,
                orientations[Int(orientation)] ?? "portrait", "--timeout", "5", "--quiet", "--json-output", "-"])
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let result = object?["result"] as? [String: Any], result["deviceIsOrientationLocked"] as? Bool == true {
                throw SimulatorError(message: "Orientation lock is enabled on the device.")
            }
            return
        }
        try await rotateUsingPurple(orientation: orientation)
    }

    /// Older simulator runtimes use the PurpleWorkspacePort GSEvent protocol.
    private func rotateUsingPurple(orientation: UInt32) async throws {
        // Purple GSEvent protocol documented in idb. The buffer is explicitly aligned for mach_msg.
        let port = try core.lookup("PurpleWorkspacePort", device: device)
        guard port != 0 else { throw SimulatorError(message: "SpringBoard is not ready for rotation.") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let buffer = UnsafeMutableRawPointer.allocate(byteCount: 112, alignment: 8)
                defer { buffer.deallocate(); mach_port_deallocate(mach_task_self_, port) }
                buffer.initializeMemory(as: UInt8.self, repeating: 0, count: 112)
                func write(_ value: UInt32, at offset: Int) { buffer.storeBytes(of: value, toByteOffset: offset, as: UInt32.self) }
                write(0x13, at: 0); write(108, at: 4); write(port, at: 8); write(0x7b, at: 20)
                write(50 | 0x20000, at: 0x18); write(4, at: 0x48); write(orientation, at: 0x4c)
                let result = mach_msg(buffer.assumingMemoryBound(to: mach_msg_header_t.self), MACH_SEND_MSG | MACH_SEND_TIMEOUT, 108, 0, 0, 2000, 0)
                if result == KERN_SUCCESS { continuation.resume() }
                else { continuation.resume(throwing: SimulatorError(message: "Rotation failed: \(String(cString: mach_error_string(result)))")) }
            }
        }
    }

    func orientationTurns(udid: String) async throws -> Int {
        guard usesNativeRotation else {
            return ScreenGeometry.normalizedQuarterTurns(UserDefaults.standard.integer(forKey: "orientation-\(udid)"))
        }
        let data = try await CommandRunner.run("/usr/bin/xcrun", ["devicectl", "device", "orientation", "get", "--device", udid,
            "--timeout", "5", "--quiet", "--json-output", "-"])
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let result = object?["result"] as? [String: Any]
        let orientation = result?["deviceOrientationNonFlat"] as? String ?? "portrait"
        return ["portrait": 0, "landscapeRight": 1, "portraitUpsideDown": 2, "landscapeLeft": 3][orientation] ?? 0
    }

    func shake() throws { try core.postNotification("com.apple.UIKit.SimulatorShake", device: device) }

    func setHardwareKeyboardEnabled(_ enabled: Bool) throws {
        try core.setHardwareKeyboardEnabled(enabled, device: device)
    }

    private static let slowAnimationsNotification = "com.apple.UIKit.SimulatorSlowMotionAnimationState"

    func slowAnimationsEnabled() throws -> Bool {
        let state = try core.notificationState(Self.slowAnimationsNotification, device: device)
        return state.uint64Value != 0
    }

    func setSlowAnimationsEnabled(_ enabled: Bool) throws {
        // UIKit reads the notification's state when it receives the post. This
        // changes guest animations without slowing the renderer or input queue.
        try core.setNotificationState(enabled ? 1 : 0, name: Self.slowAnimationsNotification, device: device)
        try core.postNotification(Self.slowAnimationsNotification, device: device)
    }
}

// XPC cancellation can run on whichever thread releases the connection.
private final class InputConnection {
    let value: xpc_connection_t
    init(_ value: xpc_connection_t) { self.value = value }
    deinit { xpc_connection_cancel(value) }
}

// macOS virtual keycode → USB HID Keyboard/Keypad usage. Command shortcuts stay in AppKit.
enum KeyboardMap {
    static let usages: [UInt16: UInt64] = [
        0:4, 1:22, 2:7, 3:9, 4:11, 5:10, 6:29, 7:27, 8:6, 9:25, 11:5,
        12:20, 13:26, 14:8, 15:21, 16:28, 17:23, 18:30, 19:31, 20:32, 21:33,
        22:35, 23:34, 24:46, 25:38, 26:36, 27:45, 28:37, 29:39, 30:48, 31:18,
        32:24, 33:47, 34:12, 35:19, 36:40, 37:15, 38:13, 39:52, 40:14, 41:51,
        42:49, 43:54, 44:56, 45:17, 46:16, 47:55, 48:43, 49:44, 50:53, 51:42,
        53:41, 65:99, 67:85, 69:87, 75:84, 76:88, 78:86, 81:103,
        82:98, 83:89, 84:90, 85:91, 86:92, 87:93, 88:94, 89:95, 91:96, 92:97,
        96:62, 97:63, 98:64, 99:60, 100:65, 101:66, 103:68, 105:104, 106:107,
        107:105, 109:67, 111:69, 113:106, 115:74, 116:75, 117:76, 118:61,
        119:77, 120:59, 121:78, 122:58, 123:80, 124:79, 125:81, 126:82
    ]
}

// The lock makes completion from XPC and the timeout mutually exclusive.
private final class InputReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
