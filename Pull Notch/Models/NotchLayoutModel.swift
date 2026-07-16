import CoreGraphics
import Foundation

enum NotchOverlayDisplayMode {
    case macDisplay
    case externalDisplay
}

nonisolated struct NotchLayoutConfiguration: Sendable {
    let compactEmptyWidth: CGFloat
    let notchHeight: CGFloat
    let externalCompactHeight: CGFloat
    let externalCompactWidth: CGFloat
    let expandedHeight: CGFloat
    let volumeExpandedHeight: CGFloat
    let playerExpandedHeight: CGFloat
    let widgetExpandedHeight: CGFloat
    let dashboardExpandedHeight: CGFloat
    let onboardingExpandedHeight: CGFloat
    let windowHorizontalInset: CGFloat
    let windowTopInset: CGFloat
    let windowBottomInset: CGFloat

    static let standard = NotchLayoutConfiguration(
        compactEmptyWidth: 244,
        notchHeight: 48,
        externalCompactHeight: 26,
        externalCompactWidth: 520,
        expandedHeight: 88,
        volumeExpandedHeight: 112,
        playerExpandedHeight: 286,
        widgetExpandedHeight: 252,
        dashboardExpandedHeight: 320,
        onboardingExpandedHeight: 176,
        windowHorizontalInset: 20,
        windowTopInset: 2,
        windowBottomInset: 14
    )
}

struct NotchLayoutState {
    let displayMode: NotchOverlayDisplayMode
    let expandedPanel: ExpandedIslandPanel?
    let activeExpandedBuiltInPage: ExpandedWidgetPageKind?
    let hasExpandedPages: Bool
    let expandedMaximumPreferredWidth: CGFloat
    let leadingWidgetStyle: CompactWidgetStyle?
    let leadingWidgetWidth: CGFloat
    let trailingWidgetStyle: CompactWidgetStyle?
    let trailingWidgetWidth: CGFloat
    let showsBatteryLowWarning: Bool
    let showsVolumeChange: Bool
    let showsPluginStatus: Bool
    let showsHoverChange: Bool
    let showsTrackChange: Bool
    let showsToastLyrics: Bool
}

struct NotchLayoutSnapshot {
    let compactCenterSpacing: CGFloat
    let compactVisibleWidth: CGFloat
    let visibleWidth: CGFloat
    let panelContentWidth: CGFloat
    let usesExternalCompactLayout: Bool
    let compactBarHeight: CGFloat
    let effectiveWindowTopInset: CGFloat
    let effectiveWindowBottomInset: CGFloat
    let currentIslandHeight: CGFloat
    let panelSize: CGSize
}

struct NotchCompactLayoutMetrics {
    let centerSpacing: CGFloat
    let visibleWidth: CGFloat
}

@MainActor
struct NotchLayoutModel {
    let configuration: NotchLayoutConfiguration

    init(configuration: NotchLayoutConfiguration = .standard) {
        self.configuration = configuration
    }

    func compactMetrics(
        leadingStyle: CompactWidgetStyle?,
        leadingWidth: CGFloat,
        trailingStyle: CompactWidgetStyle?,
        trailingWidth: CGFloat
    ) -> NotchCompactLayoutMetrics {
        let centerSpacing = compactCenterSpacing(
            leading: leadingStyle,
            trailing: trailingStyle
        )
        return NotchCompactLayoutMetrics(
            centerSpacing: centerSpacing,
            visibleWidth: max(
                configuration.compactEmptyWidth,
                leadingWidth + trailingWidth + centerSpacing + 36
            )
        )
    }

    func snapshot(for state: NotchLayoutState) -> NotchLayoutSnapshot {
        let compactMetrics = compactMetrics(
            leadingStyle: state.leadingWidgetStyle,
            leadingWidth: state.leadingWidgetWidth,
            trailingStyle: state.trailingWidgetStyle,
            trailingWidth: state.trailingWidgetWidth
        )
        let centerSpacing = compactMetrics.centerSpacing
        let compactVisibleWidth = compactMetrics.visibleWidth
        let usesExternalCompactLayout = state.displayMode == .externalDisplay
            && state.expandedPanel == nil

        let visibleWidth: CGFloat
        if usesExternalCompactLayout {
            visibleWidth = max(compactVisibleWidth, configuration.externalCompactWidth)
        } else if state.expandedPanel == .musicPlayer {
            // Keep the NSPanel frame stable while paging. Using the active
            // page width here makes every page switch resize and recenter the
            // window, which looks like the overlay is drifting on screen.
            visibleWidth = max(compactVisibleWidth, state.expandedMaximumPreferredWidth)
        } else {
            visibleWidth = compactVisibleWidth
        }

        var panelContentWidth = compactVisibleWidth
        if state.displayMode == .externalDisplay {
            panelContentWidth = max(panelContentWidth, configuration.externalCompactWidth)
        }
        if state.hasExpandedPages {
            panelContentWidth = max(panelContentWidth, state.expandedMaximumPreferredWidth)
        }

        let topInset = usesExternalCompactLayout ? 0 : configuration.windowTopInset
        let bottomInset = usesExternalCompactLayout ? 0 : configuration.windowBottomInset
        let islandHeight = currentIslandHeight(
            state: state,
            usesExternalCompactLayout: usesExternalCompactLayout
        )

        return NotchLayoutSnapshot(
            compactCenterSpacing: centerSpacing,
            compactVisibleWidth: compactVisibleWidth,
            visibleWidth: visibleWidth,
            panelContentWidth: panelContentWidth,
            usesExternalCompactLayout: usesExternalCompactLayout,
            compactBarHeight: usesExternalCompactLayout
                ? configuration.externalCompactHeight
                : configuration.notchHeight,
            effectiveWindowTopInset: topInset,
            effectiveWindowBottomInset: bottomInset,
            currentIslandHeight: islandHeight,
            panelSize: CGSize(
                // Reserve the widest page before expansion. The transparent
                // NSPanel then stays centered while the visible island grows
                // from its own top-center instead of resizing from a corner.
                width: panelContentWidth + (configuration.windowHorizontalInset * 2),
                height: islandHeight + topInset + bottomInset
            )
        )
    }

    private func currentIslandHeight(
        state: NotchLayoutState,
        usesExternalCompactLayout: Bool
    ) -> CGFloat {
        if usesExternalCompactLayout {
            return configuration.externalCompactHeight
        }
        if state.expandedPanel == .onboarding {
            return configuration.onboardingExpandedHeight
        }
        if state.expandedPanel == .musicPlayer {
            switch state.activeExpandedBuiltInPage {
            case .nowPlaying:
                return configuration.playerExpandedHeight
            case .widgetBoard:
                return configuration.dashboardExpandedHeight
            default:
                return configuration.widgetExpandedHeight
            }
        }
        if state.showsBatteryLowWarning {
            return configuration.expandedHeight
        }
        if state.showsVolumeChange {
            return configuration.volumeExpandedHeight
        }
        if state.showsPluginStatus || state.showsHoverChange {
            return configuration.expandedHeight
        }
        if state.showsTrackChange || state.showsToastLyrics {
            return configuration.expandedHeight
        }
        return configuration.notchHeight
    }

    private func compactCenterSpacing(
        leading: CompactWidgetStyle?,
        trailing: CompactWidgetStyle?
    ) -> CGFloat {
        // New CompactWidgetStyle cases should receive an explicit spacing rule.
        switch (leading, trailing) {
        case (.artwork?, .visualizer?):
            return 200
        case (.labeledSymbol?, .labeledSymbol?):
            return 240
        case (.labeledSymbol?, .circularProgress?), (.circularProgress?, .labeledSymbol?):
            return 232
        case (.circularProgress?, .circularProgress?):
            return 224
        case (.labeledSymbol?, _), (_, .labeledSymbol?):
            return 216
        case (.circularProgress?, _), (_, .circularProgress?):
            return 224
        case (.some, .some):
            return 192
        default:
            return 200
        }
    }
}
