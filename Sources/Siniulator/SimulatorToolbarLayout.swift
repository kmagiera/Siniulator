import Foundation

/// The single source of toolbar sizing, shared by presentation and resizing.
/// Dimensions here reserve space; AppKit still lays out its native widgets.
struct SimulatorToolbarMetrics: Equatable {
    var titleWidth: CGFloat
    var modeSize: CGSize = .zero
    var actionSize = CGSize(width: 112, height: 36)

    static let titleLeading: CGFloat = 102
    static let groupGap: CGFloat = 12
    static let actionTrailing: CGFloat = 16
    var hasModes: Bool { modeSize.width > 0 }
    var minimumCompactWidth: CGFloat {
        hasModes ? max(300, modeSize.width + 2 * (actionSize.width + Self.actionTrailing + Self.groupGap)) : 300
    }
    var minimumExpandedWidth: CGFloat {
        if hasModes {
            return modeSize.width + 2 * max(Self.titleLeading + titleWidth + Self.groupGap,
                actionSize.width + Self.actionTrailing + Self.groupGap)
        }
        return Self.titleLeading + titleWidth + 20 + actionSize.width + 8
    }
    func layout(width: CGFloat, isFullScreen: Bool = false, topInset: CGFloat = 0,
                revealProgress: CGFloat = 0, attached: Bool = false) -> SimulatorControlBarLayout {
        SimulatorControlBarLayout(width: width, metrics: self, isFullScreen: isFullScreen,
            topInset: topInset, revealProgress: revealProgress, attached: attached)
    }
    func pillWidth(availableWidth: CGFloat, deviceWidth: CGFloat,
                   projectedFraction: CGFloat, closedFraction: CGFloat) -> CGFloat {
        let fraction = min(1, max(0, projectedFraction, closedFraction))
        return max(0, min(availableWidth, max(minimumExpandedWidth, deviceWidth * fraction)))
    }
}

/// Pure geometry: every custom view receives its complete rectangle here.
/// Native action rectangles are reservations, not frames imposed on AppKit.
struct SimulatorControlBarLayout {
    static let expandedHeight: CGFloat = 52
    static let compactHeight: CGFloat = 76
    static let minimumWidth: CGFloat = 300
    let isCompact: Bool
    let height: CGFloat
    let cornerRadius: CGFloat
    let buttons: CGRect
    let modes: CGRect?
    let name: CGRect
    let runtime: CGRect

    init(width: CGFloat, metrics: SimulatorToolbarMetrics, isFullScreen: Bool = false,
         topInset: CGFloat = 0, revealProgress: CGFloat = 0, attached: Bool = false) {
        let width = max(0, width)
        isCompact = !isFullScreen && width < metrics.minimumExpandedWidth
        height = isCompact ? Self.compactHeight : Self.expandedHeight
        cornerRadius = isFullScreen || attached ? 0 : isCompact ? 16 : height / 2
        let rowY: CGFloat = isCompact ? 32 : topInset + 8
        modes = metrics.hasModes ? CGRect(x: (width - metrics.modeSize.width) / 2,
            y: rowY, width: metrics.modeSize.width, height: metrics.actionSize.height) : nil
        let actionX = isCompact && !metrics.hasModes ? (width - metrics.actionSize.width) / 2
            : width - metrics.actionSize.width - (metrics.hasModes ? SimulatorToolbarMetrics.actionTrailing : 8)
        buttons = CGRect(x: actionX, y: rowY, width: metrics.actionSize.width, height: metrics.actionSize.height)
        if isCompact {
            name = CGRect(x: 84, y: 7, width: max(0, width - 96), height: 20)
            runtime = .zero
        } else {
            let left = isFullScreen ? 20 + 88 * min(1, max(0, revealProgress)) : SimulatorToolbarMetrics.titleLeading
            let end = modes.map { $0.minX - SimulatorToolbarMetrics.groupGap } ?? (buttons.minX - 10)
            name = CGRect(x: left, y: topInset + 10, width: max(0, end - left), height: 16)
            runtime = CGRect(x: left, y: topInset + 26, width: name.width, height: 16)
        }
    }
}
