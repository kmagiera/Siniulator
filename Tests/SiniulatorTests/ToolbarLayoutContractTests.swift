import Foundation
import XCTest
@testable import Siniulator

final class ToolbarLayoutContractTests: XCTestCase {
    func testAllSupportedWidthsKeepTitleModesAndActionsDisjoint() {
        for title: CGFloat in [0, 80, 140, 320] {
            for selector: CGFloat in [0, 120, 160] {
                let metrics = SimulatorToolbarMetrics(titleWidth: title, modeSize: CGSize(width: selector, height: 36))
                let widths = [metrics.minimumCompactWidth, metrics.minimumExpandedWidth - 1,
                    metrics.minimumExpandedWidth, metrics.minimumExpandedWidth + 1, 1600]
                for width in widths where width >= metrics.minimumCompactWidth {
                    let layout = metrics.layout(width: width)
                    let bounds = CGRect(x: 0, y: 0, width: width, height: layout.height)
                    XCTAssertTrue(bounds.contains(layout.name))
                    XCTAssertTrue(bounds.contains(layout.buttons))
                    XCTAssertFalse(layout.name.intersects(layout.buttons))
                    if let modes = layout.modes {
                        XCTAssertTrue(bounds.contains(modes))
                        XCTAssertEqual(modes.midX, width / 2)
                        XCTAssertFalse(modes.intersects(layout.name))
                        XCTAssertFalse(modes.intersects(layout.runtime))
                        XCTAssertFalse(modes.intersects(layout.buttons))
                    }
                    if !layout.isCompact { XCTAssertGreaterThanOrEqual(layout.name.width, title) }
                }
            }
        }
    }

    func testPillUsesClosedWidthAndTitleMinimumWithoutHistory() {
        let metrics = SimulatorToolbarMetrics(titleWidth: 80, modeSize: CGSize(width: 128, height: 36))
        for available: CGFloat in [424, 800, 1400] {
            for closed: CGFloat in [0.5, 1] {
                let deviceWidth = available - 24
                let minimum = metrics.pillWidth(availableWidth: available, deviceWidth: deviceWidth,
                    projectedFraction: closed, closedFraction: closed)
                for projected: CGFloat in [1, 0.8, 0.5, 0.25, 0.1, 0.3, 0.5] {
                    let width = metrics.pillWidth(availableWidth: available, deviceWidth: deviceWidth,
                        projectedFraction: projected, closedFraction: closed)
                    XCTAssertGreaterThanOrEqual(width, minimum)
                    XCTAssertLessThanOrEqual(width, available)
                    XCTAssertEqual(metrics.layout(width: width).height, metrics.layout(width: available).height,
                        "Pose changes alone must not switch toolbar rows or resize the viewport")
                }
            }
        }
    }

    func testAttachedAndFullscreenStylesDoNotAlterTheSizingPolicy() {
        for selector: CGFloat in [0, 128] {
            let metrics = SimulatorToolbarMetrics(titleWidth: 140, modeSize: CGSize(width: selector, height: 36))
            let desktop = metrics.layout(width: 1000)
            let attached = metrics.layout(width: 1000, attached: true)
            XCTAssertEqual(attached.height, desktop.height)
            XCTAssertEqual(attached.modes, desktop.modes)
            XCTAssertEqual(attached.name, desktop.name)
            XCTAssertEqual(attached.cornerRadius, 0)
            for progress: CGFloat in [0, 0.5, 1] {
                let full = metrics.layout(width: 1000, isFullScreen: true, topInset: 24, revealProgress: progress)
                XCTAssertFalse(full.isCompact)
                XCTAssertEqual(full.cornerRadius, 0)
                XCTAssertEqual(full.modes?.midX, desktop.modes?.midX)
                XCTAssertEqual(full.buttons.minX, desktop.buttons.minX)
                XCTAssertEqual(full.name.maxX, desktop.name.maxX)
            }
        }
    }
}
