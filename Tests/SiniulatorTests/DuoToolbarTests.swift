import AppKit
import SceneKit
import XCTest
@testable import Siniulator

final class DuoToolbarTests: XCTestCase {
    func testSizingFollowsScaleWithOnlyAControlMinimum() {
        let sizing = DuoToolbarSizing(widthFraction: 0.7, minimumWidth: 400)
        XCTAssertEqual(sizing.width(for: 700), 490, accuracy: 0.001)
        XCTAssertEqual(sizing.width(for: 1000), 700, accuracy: 0.001)
        XCTAssertEqual(sizing.width(for: 280), 400)
    }

    @MainActor func testAuthoredWeightedWidthIsIndependentOfEveryFoldAndRoll() throws {
        guard FileManager.default.fileExists(atPath: DuoModelView.assetURL.path) else {
            throw XCTSkip("Duo DeviceKit model not installed")
        }
        let device = SimulatorDevice(udid: "duo-scale-toolbar", name: "iPhone Duo", state: "Booted",
            isAvailable: true, deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
            runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-1")
        let chrome = DeviceChrome.load(for: device, displayMode: .cover)
        let screen = SimulatorScreenView(renderer: try ScreenRenderer())
        let root = DevicePresentationView(screen: screen, chrome: chrome, device: device) { _ in }
        root.setFrameSize(CGSize(width: 1400, height: 1400))
        root.layoutSubtreeIfNeeded()
        let scene = try XCTUnwrap(SCNSceneSource(url: DuoModelView.assetURL, options: nil)?.scene(options: [
            .animationImportPolicy: SCNSceneSource.AnimationImportPolicy.play
        ]))
        let clip = try XCTUnwrap(DuoPoseClip(root: scene.rootNode))
        let closed = try XCTUnwrap(clip.projectedBounds(angle: 0, quarterTurns: 0, side: 1000))
        let open = try XCTUnwrap(clip.projectedBounds(angle: 180, quarterTurns: 0, side: 1000))
        let weightedWidth = (2 * closed.width + open.width) / 3
        XCTAssertEqual(root.duoToolbarSizing.widthFraction * 1000, weightedWidth, accuracy: 0.001)
        XCTAssertGreaterThan(weightedWidth, closed.width)
        XCTAssertLessThan(weightedWidth, (closed.width + open.width) / 2)
        var previousWidth: CGFloat = 0
        for side: CGFloat in [280, 700, 1000, 1400] {
            root.duoViewportSide = side
            root.layoutSubtreeIfNeeded()
            let expected = max(root.controls.minimumExpandedWidth, weightedWidth * side / 1000)
            XCTAssertGreaterThanOrEqual(expected, previousWidth)
            previousWidth = expected
            for turns in stride(from: CGFloat(0), through: 3.75, by: 0.25) {
                for angle: CGFloat in [0, 40, 75, 110, 140, 180] {
                    root.canvas.setRenderedDuoPose(DuoRenderPose(angle: angle, quarterTurns: turns))
                    root.setFrameSize(root.duoWindowSize)
                    root.needsLayout = true
                    root.layoutSubtreeIfNeeded()
                    XCTAssertEqual(root.controls.frame.width, expected, accuracy: 0.001)
                    XCTAssertEqual(root.controls.frame.height, SimulatorControlBarLayout.expandedHeight)
                    XCTAssertEqual(root.controls.frame.midX, root.bounds.midX, accuracy: 0.001)
                    XCTAssertEqual(root.visualDeviceRect.minY - root.controls.frame.maxY, DuoStage.toolbarGap, accuracy: 0.001)
                    XCTAssertGreaterThanOrEqual(root.bounds.maxY - root.visualDeviceRect.maxY, DuoStage.outerMargin - 0.001)
                    let layout = root.controls.barLayout
                    XCTAssertFalse(layout.isCompact)
                    XCTAssertGreaterThanOrEqual(layout.name.width, root.controls.titleWidth - 0.001)
                    XCTAssertGreaterThanOrEqual(layout.buttons.minX, (layout.modes?.maxX ?? 0) + SimulatorToolbarMetrics.groupGap)
                }
            }
        }
        print("Duo toolbar reference widths at viewport 1000: cover \(closed.width), open \(open.width), weighted mean \(weightedWidth); control minimum \(root.controls.minimumExpandedWidth)")
    }
}
