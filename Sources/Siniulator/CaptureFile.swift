import AppKit
import UniformTypeIdentifiers

enum CaptureKind: Sendable {
    case screenshot, recording
    var title: String { self == .screenshot ? "Screenshot" : "Screen Recording" }
    var fileExtension: String { self == .screenshot ? "png" : "mp4" }
    var contentType: UTType { self == .screenshot ? .png : .mpeg4Movie }
}

struct CaptureFile: Sendable {
    let temporaryURL: URL
    let kind: CaptureKind

    static func filename(deviceName: String, date: Date = Date(), timeZone: TimeZone = .current, kind: CaptureKind = .screenshot) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = deviceName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "Simulator \(kind.title) - \(name) - \(formatter.string(from: date)).\(kind.fileExtension)"
    }

    static func reserve(deviceName: String, date: Date = Date(), kind: CaptureKind) throws -> CaptureFile {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Siniulator Captures", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(filename(deviceName: deviceName, date: date, kind: kind))
        return CaptureFile(temporaryURL: url, kind: kind)
    }

    static func stage(_ data: Data, deviceName: String, date: Date) throws -> CaptureFile {
        let file = try reserve(deviceName: deviceName, date: date, kind: .screenshot)
        do {
            try data.write(to: file.temporaryURL, options: .atomic)
            return file
        } catch {
            try? FileManager.default.removeItem(at: file.temporaryURL.deletingLastPathComponent())
            throw error
        }
    }

    func save(to destination: URL) throws {
        guard temporaryURL.standardizedFileURL != destination.standardizedFileURL else { return }
        let manager = FileManager.default
        let stagingDirectory = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: destination, create: true)
        defer { try? manager.removeItem(at: stagingDirectory) }
        let staged = stagingDirectory.appendingPathComponent(destination.lastPathComponent)
        // Finish copying before replacing an existing file. A failed copy must
        // preserve the destination the user selected in the save panel.
        try manager.copyItem(at: temporaryURL, to: staged)
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: staged)
        } else {
            try manager.moveItem(at: staged, to: destination)
        }
    }

    func save(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let basename = temporaryURL.deletingPathExtension().lastPathComponent
        var suffix = 1
        while true {
            let name = suffix == 1 ? temporaryURL.lastPathComponent : "\(basename) (\(suffix)).\(temporaryURL.pathExtension)"
            let destination = directory.appendingPathComponent(name)
            do {
                try FileManager.default.copyItem(at: temporaryURL, to: destination)
                return destination
            } catch {
                // Several captures within one second must never replace an earlier file.
                guard (error as? CocoaError)?.code == .fileWriteFileExists else { throw error }
                suffix += 1
            }
        }
    }
}

enum ScreenshotImage {
    static func png(_ image: CGImage) throws -> Data {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw SimulatorError(message: "Could not encode screenshot.")
        }
        return data
    }
}
