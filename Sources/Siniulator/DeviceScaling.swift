import AppKit

enum DeviceScalingMode {
    case custom, physicalSize, pointAccurate, pixelAccurate, fitScreen

    var isAccurate: Bool { self == .physicalSize || self == .pointAccurate || self == .pixelAccurate }

    func logicalScale(deviceScale: CGFloat, backingScale: CGFloat,
                      deviceDPI: CGFloat? = nil, displayPointsPerInch: CGFloat? = nil) -> CGFloat? {
        switch self {
        case .physicalSize:
            guard let deviceDPI, let displayPointsPerInch,
                  deviceDPI.isFinite, deviceDPI > 0,
                  displayPointsPerInch.isFinite, displayPointsPerInch > 0 else { return nil }
            return deviceScale * displayPointsPerInch / deviceDPI
        case .pointAccurate: return 1
        case .pixelAccurate: return deviceScale / max(1, backingScale)
        case .custom, .fitScreen: return nil
        }
    }
}

extension NSScreen {
    var physicalPointsPerInch: CGFloat? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let millimeters = CGDisplayScreenSize(number.uint32Value)
        guard millimeters.width.isFinite, millimeters.width > 0 else { return nil }
        // Use AppKit points, rather than backing pixels: scaled Retina modes
        // must still display the same number of physical inches.
        return frame.width * 25.4 / millimeters.width
    }
}
