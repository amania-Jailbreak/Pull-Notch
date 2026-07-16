//
//  ContentView.swift
//  Pull Notch
//
//  Created by amania on 2026/03/30.
//

import AppKit
import Observation
import PullNotchPluginKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var overlayModel: NotchOverlayModel
    @State private var isHovering = false
    @State private var isDropTargeted = false
    @State private var visualizerHeights: [CGFloat] = [8, 13, 10, 16, 12, 7]
    @State private var pinnedScrollID: UUID?
    @State private var acceptsPinnedScrollSelection = false

    var body: some View {
        ZStack(alignment: .top) {
            islandShape
        }
        .frame(
            width: overlayModel.panelSize.width,
            height: overlayModel.panelSize.height,
            alignment: .top
        )
        .padding(.top, overlayModel.effectiveWindowTopInset)
        .background(Color.clear)
        .dropDestination(for: URL.self) { urls, _ in
            let fileURLs = urls.filter(\.isFileURL)
            guard !fileURLs.isEmpty else { return false }
            return overlayModel.pinFiles(fileURLs).acceptedCount > 0
        } isTargeted: { isTargeted in
            isDropTargeted = isTargeted
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 18)
                .onEnded { value in
                    guard overlayModel.expandedPanel == .musicPlayer,
                          overlayModel.activeExpandedBuiltInPage != .pinnedFile
                    else {
                        return
                    }
                    let horizontal = value.translation.width
                    let vertical = value.translation.height
                    guard abs(horizontal) > abs(vertical), abs(horizontal) > 26 else { return }

                    if horizontal < 0 {
                        overlayModel.showNextExpandedWidgetPage()
                    } else {
                        overlayModel.showPreviousExpandedWidgetPage()
                    }
                }
        )
    }

    @ViewBuilder
    private var islandShape: some View {
        if overlayModel.usesExternalCompactLayout {
            externalCompactIsland
        } else {
            standardIslandShape
        }
    }

    private var standardIslandShape: some View {
        ZStack(alignment: .top) {
            SiriGlassIslandSurface(
                cornerRadius: islandCornerRadius,
                showsBorder: true,
                castsShadow: true
            )
                .frame(width: overlayModel.visibleWidth, height: overlayModel.currentIslandHeight)
                .opacity(showsExtendedIslandSurface ? 1 : 0)
                .overlay(alignment: .bottom) {
                    expandedContent
                }
                .clipShape(DynamicIslandShape(cornerRadius: islandCornerRadius))
                .onHover(perform: handleIslandHover)
                .animation(islandGeometryAnimation, value: overlayModel.visibleWidth)
                .animation(islandGeometryAnimation, value: overlayModel.currentIslandHeight)
                .animation(islandContentAnimation, value: transientPresentationKey)

            SiriGlassIslandSurface(
                cornerRadius: 22,
                showsBorder: true,
                castsShadow: true
            )
                .frame(width: overlayModel.visibleWidth, height: overlayModel.compactBarHeight)
                // Transient banners and expanded pages use the full-height
                // surface above. Hiding only this background keeps compact
                // widgets available without stacking a second glass cap.
                .opacity(showsExtendedIslandSurface ? 0 : 1)
                .overlay(alignment: .top) {
                    ZStack {
                        if overlayModel.expandedPanel != .musicPlayer {
                            compactBar
                                .padding(.top, 4)
                                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .center)))
                        }
                    }
                }
                .contentShape(DynamicIslandShape(cornerRadius: 22))
                .onHover(perform: handleIslandHover)
                .onTapGesture {
                    if overlayModel.expandedPanel != .onboarding {
                        overlayModel.toggleMusicPlayer()
                    }
                }
                .contextMenu {
                    if overlayModel.expandedPanel == nil {
                        Button {
                            overlayModel.openSettingsWindow()
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }

                        Divider()

                        Button(role: .destructive) {
                            NSApp.terminate(nil)
                        } label: {
                            Label("Quit Pull Notch", systemImage: "power")
                        }
                    }
                }
                .allowsHitTesting(overlayModel.expandedPanel != .musicPlayer)
                .animation(islandGeometryAnimation, value: overlayModel.expandedPanel == .musicPlayer)
                .animation(islandContentAnimation, value: showsExtendedIslandSurface)
        }
        .frame(width: overlayModel.panelSize.width, alignment: .center)
        .overlay {
            if isDropTargeted {
                DynamicIslandShape(cornerRadius: 22)
                    .stroke(Color.white.opacity(0.55), lineWidth: 1.5)
                    .overlay {
                        Text("Drop To Pin")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.86))
                }
            }
        }
        .scaleEffect(hoverScale)
        .animation(.smooth(duration: 0.18), value: hoverScale)
    }

    private var externalCompactIsland: some View {
        SiriGlassIslandSurface(cornerRadius: 13, showsBorder: true, castsShadow: true)
            .frame(width: overlayModel.visibleWidth, height: overlayModel.externalCompactHeight)
            .overlay {
                HStack(spacing: 10) {
                    compactWidgetSlot(overlayModel.leadingWidget)
                        .frame(minWidth: overlayModel.leadingWidgetWidth, alignment: .leading)

                    externalCompactToast
                        .frame(maxWidth: .infinity, alignment: .center)
                        .clipped()

                    compactWidgetSlot(overlayModel.trailingWidget)
                        .frame(minWidth: overlayModel.trailingWidgetWidth, alignment: .trailing)
                }
                .padding(.horizontal, 10)
            }
            .contentShape(DynamicIslandShape(cornerRadius: 12))
            .onHover(perform: handleIslandHover)
            .onTapGesture {
                if overlayModel.expandedPanel != .onboarding {
                    overlayModel.toggleMusicPlayer()
                }
            }
            .contextMenu {
                if overlayModel.expandedPanel == nil {
                    Button {
                        overlayModel.openSettingsWindow()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }

                    Divider()

                    Button(role: .destructive) {
                        NSApp.terminate(nil)
                    } label: {
                        Label("Quit Pull Notch", systemImage: "power")
                    }
                }
            }
            .frame(width: overlayModel.panelSize.width, alignment: .center)
            .animation(islandGeometryAnimation, value: overlayModel.visibleWidth)
            .animation(islandContentAnimation, value: transientPresentationKey)
    }

    private func handleIslandHover(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        overlayModel.setHoverTitleVisible(hovering)

        if hovering {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
    }

    @ViewBuilder
    private var externalCompactToast: some View {
        if overlayModel.showsToastLyrics {
            TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
                if let lyricText = overlayModel.toastLyricsText(at: timeline.date) {
                    MarqueeText(
                        text: lyricText,
                        font: .system(size: 12, weight: .medium),
                        color: .gray,
                        leadingSystemImage: "quote.opening"
                    )
                    .id(lyricText)
                }
            }
        } else if overlayModel.showsTrackText, let detailLine = overlayModel.detailLine {
            MarqueeText(
                text: detailLine,
                font: .system(size: 12, weight: .medium),
                color: .gray
            )
            .id(detailLine)
        } else {
            Color.clear
        }
    }

    private var hoverScale: CGFloat {
        if overlayModel.showsHoverChange || overlayModel.expandedPanel == .musicPlayer {
            return 1
        }
        return isHovering ? 1.018 : 1
    }

    private var showsExtendedIslandSurface: Bool {
        overlayModel.currentIslandHeight > overlayModel.compactBarHeight
    }

    private var islandCornerRadius: CGFloat {
        overlayModel.expandedPanel == .musicPlayer ? 30 : 22
    }

    private var musicPlayerExpansionAnimation: Animation {
        .spring(response: 0.42, dampingFraction: 0.9)
    }

    private var islandGeometryAnimation: Animation {
        .spring(response: 0.36, dampingFraction: 0.92)
    }

    private var islandContentAnimation: Animation {
        .easeOut(duration: 0.18)
    }

    private var transientPresentationKey: String {
        [
            overlayModel.expandedPanel == .musicPlayer ? "player" : nil,
            overlayModel.expandedPanel == .onboarding ? "onboarding" : nil,
            overlayModel.showsVolumeChange ? "volume" : nil,
            overlayModel.showsPluginStatus ? "plugin" : nil,
            overlayModel.showsBatteryLowWarning ? "battery" : nil,
            overlayModel.showsHoverChange ? "hover" : nil,
            overlayModel.showsToastLyrics ? "lyrics-toast" : nil,
            overlayModel.showsTrackChange ? "track" : nil
        ]
        .compactMap { $0 }
        .first ?? "compact"
    }

    private var musicPlayerExpansionTransition: AnyTransition {
        .modifier(
            active: CenterExpansionModifier(scale: 1, opacity: 0, yOffset: 8, blurRadius: 10),
            identity: CenterExpansionModifier(scale: 1, opacity: 1, yOffset: 0, blurRadius: 0)
        )
    }

    private var compactBar: some View {
        HStack(spacing: 12) {
            compactWidgetSlot(overlayModel.leadingWidget)
            Spacer(minLength: overlayModel.compactCenterSpacing)
            compactWidgetSlot(overlayModel.trailingWidget)
        }
        .padding(.horizontal, 12)
        .frame(width: overlayModel.visibleWidth, height: overlayModel.compactBarHeight)
    }

    private func compactWidgetSlot(_ widget: CompactIslandWidget?) -> some View {
        ZStack {
            compactWidgetView(widget)
                .id(widget?.id ?? "empty")
                .transition(.opacity)
        }
        .animation(.easeOut(duration: 0.14), value: widget?.id)
    }

    @ViewBuilder
    private func compactWidgetView(_ widget: CompactIslandWidget?) -> some View {
        if let widget {
            switch widget.style {
            case .artwork:
                artworkView(for: widget.artworkData)
            case .visualizer(let isActive):
                visualizerView(isActive: isActive)
            case .symbol(let systemName):
                symbolWidget(systemName)
            case .labeledSymbol(let systemName, let text):
                labeledWidget(systemName: systemName, text: text)
            case .circularProgress(let systemName, let progress, let isActive, let text):
                circularProgressWidget(systemName: systemName, progress: progress, isActive: isActive, text: text)
            case .custom(let render):
                render()
                    .frame(width: widget.preferredWidth, height: overlayModel.compactBarHeight)
            }
        } else {
            Color.clear
                .frame(width: 24, height: 24)
        }
    }

    private func artworkView(for artworkData: Data?) -> some View {
        Group {
            if let artworkImage = artworkImage(for: artworkData) {
                Image(nsImage: artworkImage)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [Color.gray.opacity(0.55), Color.gray.opacity(0.25)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func artworkImage(for artworkData: Data?) -> NSImage? {
        guard let artworkData else { return nil }
        return NSImage(data: artworkData)
    }

    private func symbolWidget(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.78))
            .frame(width: 24, height: 24)
    }

    private func labeledWidget(systemName: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))

            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(height: 24)
    }

    private func circularProgressWidget(systemName: String, progress: CGFloat, isActive: Bool, text: String) -> some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.14), lineWidth: 2)

                Circle()
                    .trim(from: 0, to: max(0.04, progress))
                    .stroke(
                        isActive ? Color.white.opacity(0.92) : Color.white.opacity(0.62),
                        style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                Image(systemName: systemName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(isActive ? 0.88 : 0.68))
            }
            .frame(width: 24, height: 24)

            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(height: 24)
    }

    private func visualizerView(isActive: Bool) -> some View {
        let barHeights = overlayModel.usesRealNowPlayingVisualizer ? overlayModel.liveVisualizerHeights : visualizerHeights

        return HStack(alignment: .center, spacing: 3) {
            ForEach(Array(barHeights.enumerated()), id: \.offset) { index, height in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(visualizerBarColor(at: index, total: barHeights.count))
                    .frame(width: 2.5, height: isActive ? height : 5)
                    .animation(
                        .smooth(duration: 0.18).delay(Double(index) * 0.018),
                        value: height
                    )
            }
        }
        .frame(height: 24)
        .task(id: "\(isActive)-\(overlayModel.usesRealNowPlayingVisualizer)") {
            guard isActive, !overlayModel.usesRealNowPlayingVisualizer else {
                visualizerHeights = [5, 5, 5, 5, 5, 5]
                return
            }

            while !Task.isCancelled {
                guard isActive, !overlayModel.usesRealNowPlayingVisualizer else { return }
                visualizerHeights = (0..<6).map { _ in .random(in: 7...21) }
                try? await Task.sleep(for: .milliseconds(155))
            }
        }
    }

    private func visualizerBarColor(at index: Int, total: Int) -> Color {
        guard total > 1 else { return overlayModel.visualizerBrightColor }

        let progress = CGFloat(index) / CGFloat(total - 1)
        let start = NSColor(overlayModel.visualizerBrightColor)
        let end = NSColor(overlayModel.visualizerDarkColor)

        guard
            let startRGB = start.usingColorSpace(.deviceRGB),
            let endRGB = end.usingColorSpace(.deviceRGB)
        else {
            return progress < 0.5 ? overlayModel.visualizerBrightColor : overlayModel.visualizerDarkColor
        }

        var startRed: CGFloat = 0
        var startGreen: CGFloat = 0
        var startBlue: CGFloat = 0
        var startAlpha: CGFloat = 0
        startRGB.getRed(&startRed, green: &startGreen, blue: &startBlue, alpha: &startAlpha)

        var endRed: CGFloat = 0
        var endGreen: CGFloat = 0
        var endBlue: CGFloat = 0
        var endAlpha: CGFloat = 0
        endRGB.getRed(&endRed, green: &endGreen, blue: &endBlue, alpha: &endAlpha)

        let red = startRed + ((endRed - startRed) * progress)
        let green = startGreen + ((endGreen - startGreen) * progress)
        let blue = startBlue + ((endBlue - startBlue) * progress)
        let alpha = startAlpha + ((endAlpha - startAlpha) * progress)

        return Color(
            nsColor: NSColor(
                calibratedRed: red,
                green: green,
                blue: blue,
                alpha: alpha
            )
        )
    }

    @ViewBuilder
    private var expandedContent: some View {
        if overlayModel.expandedPanel == .musicPlayer {
            musicPlayerPanel
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                .transition(musicPlayerExpansionTransition)
        } else if overlayModel.expandedPanel == .onboarding {
            onboardingPanel
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
        } else if overlayModel.showsVolumeChange {
            volumeBanner
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        } else if overlayModel.showsPluginStatus {
            pluginStatusBanner
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
        } else if overlayModel.showsBatteryLowWarning {
            batteryWarningBanner
                .padding(.horizontal, 14)
                .padding(.bottom, 2)
        } else if overlayModel.showsHoverChange {
            hoverTitleBanner
                .opacity(overlayModel.showsHoverText ? 1 : 0)
                .offset(y: overlayModel.showsHoverText ? 0 : -2)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
                .animation(.smooth(duration: 0.18), value: overlayModel.showsHoverText)
        } else {
            trackChangeBanner
                .opacity((overlayModel.showsTrackText || overlayModel.showsToastLyrics) ? 1 : 0)
                .offset(y: (overlayModel.showsTrackText || overlayModel.showsToastLyrics) ? 0 : -2)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
                .animation(.smooth(duration: 0.18), value: overlayModel.showsTrackText)
                .animation(.smooth(duration: 0.18), value: overlayModel.showsToastLyrics)
        }
    }

    private var batteryWarningBanner: some View {
        MarqueeText(
            text: "Warning!! The battery is running low. Please charge it immediately!",
            font: .system(size: 12, weight: .semibold),
            color: .red.opacity(0.96),
            leadingSystemImage: nil
        )
        .frame(width: overlayModel.visibleWidth - 28, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black)
        )
        .clipped()
    }

    private var volumeBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.12))
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.95), Color.white.opacity(0.68)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(10, geometry.size.width * overlayModel.volumeLevel))
                            .animation(.spring(response: 0.24, dampingFraction: 0.82), value: overlayModel.volumeLevel)
                    }
                }
                .frame(height: 8)

                Text("\(Int((overlayModel.volumeLevel * 100).rounded()))%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(width: 40, alignment: .trailing)
            }

            if let outputDeviceName = overlayModel.volumeOutputDeviceName {
                Text(outputDeviceName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.52))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .frame(width: overlayModel.visibleWidth - 32, alignment: .leading)
    }

    private var onboardingPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pull Notch")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)

            Text("Apple Music の現在再生中、音量変更、クリック展開のプレイヤーをこの島に表示します。")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.gray)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                onboardingRow("music.note", "再生中の曲名とアートワーク")
                onboardingRow("speaker.wave.2.fill", "音量変更時のボリュームバー")
                onboardingRow("play.circle.fill", "クリックで開くミニプレイヤー")
            }

            Button {
                overlayModel.completeOnboarding()
            } label: {
                Text("はじめる")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white)
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(14)
        .frame(width: overlayModel.visibleWidth - 32, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black)
        )
    }

    private func onboardingRow(_ systemName: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.78))
                .frame(width: 14)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
        }
    }

    @ViewBuilder
    private var hoverTitleBanner: some View {
        if let detailLine = overlayModel.detailLine {
            MarqueeText(
                text: detailLine,
                font: .system(size: 12, weight: .medium),
                color: .gray
            )
            .frame(width: overlayModel.visibleWidth - 28, alignment: .leading)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture {
                overlayModel.toggleMusicPlayer()
            }
        }
    }

    @ViewBuilder
    private var trackChangeBanner: some View {
        if overlayModel.showsToastLyrics {
            TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
                if let lyricText = overlayModel.toastLyricsText(at: timeline.date) {
                    MarqueeText(
                        text: lyricText,
                        font: .system(size: 12, weight: .medium),
                        color: .gray,
                        leadingSystemImage: "quote.opening"
                    )
                    .id(lyricText)
                    .frame(width: overlayModel.visibleWidth - 28, alignment: .leading)
                    .clipped()
                }
            }
        } else if let detailLine = overlayModel.detailLine {
            MarqueeText(
                text: detailLine,
                font: .system(size: 12, weight: .medium),
                color: .gray
            )
            .id(detailLine)
            .frame(width: overlayModel.visibleWidth - 28, alignment: .leading)
            .clipped()
        }
    }

    private var musicPlayerPanel: some View {
        ZStack(alignment: .top) {
            activeExpandedPageBody
                .id(activeExpandedPageID)
                .transition(.opacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .frame(width: overlayModel.visibleWidth - 28, alignment: .center)
        .clipped()
        .animation(.smooth(duration: 0.18), value: activeExpandedPageID)
    }

    @ViewBuilder
    private var activeExpandedPageBody: some View {
        if overlayModel.expandedWidgetPages.isEmpty {
            emptyExpandedPanel
        } else if overlayModel.activeExpandedBuiltInPage == .nowPlaying {
            nowPlayingPlayerPanel
        } else if overlayModel.activeExpandedBuiltInPage == .pinnedFile {
            VStack(alignment: .leading, spacing: 6) {
                expandedPageHeader
                pinnedFileExpandedPage
            }
            .padding(.top, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if overlayModel.activeExpandedBuiltInPage == .widgetBoard {
            VStack(alignment: .leading, spacing: 8) {
                expandedPageHeader
                dashboardWidgetBoard
            }
            .padding(.top, 52)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if let activeExpandedWidgetPage = overlayModel.activeExpandedWidgetPage,
                  case .plugin = activeExpandedWidgetPage.source,
                  let render = activeExpandedWidgetPage.render {
            VStack(alignment: .leading, spacing: 12) {
                expandedPageHeader
                render()
            }
            .padding(.top, 60)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                expandedPageHeader
                expandedPageContent
            }
            .padding(.top, 60)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var activeExpandedPageID: String {
        overlayModel.activeExpandedWidgetPage?.id ?? "empty-expanded-page"
    }

    private var pluginStatusBanner: some View {
        Group {
            if let pluginStatusMessage = overlayModel.pluginStatusMessage {
                MarqueeText(
                    text: pluginStatusMessage,
                    font: .system(size: 12, weight: .semibold),
                    color: .white.opacity(0.9)
                )
                .frame(width: overlayModel.visibleWidth - 28, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.white.opacity(0.06), lineWidth: 1)
                        )
                )
            }
        }
    }

    private var nowPlayingPlayerPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom, spacing: 18) {
                Group {
                    if let artworkImage = artworkImage(for: overlayModel.artworkData) {
                        Image(nsImage: artworkImage)
                            .resizable()
                            .scaledToFill()
                    } else {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.16), Color.white.opacity(0.06)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .overlay {
                                Image(systemName: "music.note")
                                    .font(.system(size: 24, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                    }
                }
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .onTapGesture {
                    overlayModel.activateNowPlayingApp()
                }
                .offset(y: -6)

                VStack(alignment: .leading, spacing: 12) {
                    Spacer(minLength: 0)

                    Text(overlayModel.detailLine?.components(separatedBy: " - ").first ?? "Not Playing")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(overlayModel.detailLine?.components(separatedBy: " - ").dropFirst().joined(separator: " - ") ?? "No artist")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)

                    Text(overlayModel.sourceApp ?? "Music")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.42))
                        .lineLimit(1)

                    HStack(spacing: 14) {
                        playerButton("backward.fill") {
                            overlayModel.send(.previousTrack)
                        }

                        playerButton(overlayModel.isPlaying ? "pause.fill" : "play.fill", prominent: true) {
                            overlayModel.send(.togglePlayPause)
                        }

                        playerButton("forward.fill") {
                            overlayModel.send(.nextTrack)
                        }
                    }
                    .padding(.top, 2)

                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

                VStack(alignment: .trailing, spacing: 18) {
                    if overlayModel.expandedWidgetPages.count > 1 {
                        compactExpandedPager
                    }

                    Spacer(minLength: 0)

                    HStack(alignment: .center, spacing: 10) {
                        visualizerView(isActive: overlayModel.isPlaying)
                            .frame(width: 34)
                    }
                    .padding(.trailing, 4)
                }
                .frame(width: 92)
                .frame(maxHeight: .infinity, alignment: .trailing)
            }

            lyricsPanel
        }
        .padding(.top, 18)
        .padding(.bottom, 2)
        .frame(width: overlayModel.visibleWidth - 28, alignment: .leading)
    }

    private var lyricsPanel: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !overlayModel.isPlaying)) { timeline in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "quote.opening")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))

                    Text(overlayModel.lyricsStatusText)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.58))

                    Spacer(minLength: 0)
                }

                Group {
                    let lyricLines = overlayModel.visibleLyricsLines(at: timeline.date)

                    if !lyricLines.isEmpty {
                        ZStack(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(Array(lyricLines.enumerated()), id: \.offset) { _, item in
                                    lyricLine(
                                        text: item.line.text,
                                        isActive: item.isActive,
                                        isContext: item.isContext
                                    )
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .id(lyricLines.map(\.line.id).joined(separator: "|"))
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .move(edge: .top).combined(with: .opacity)
                            ))
                        }
                        .frame(maxWidth: .infinity, minHeight: 41, maxHeight: 41, alignment: .topLeading)
                        .clipped()
                    } else if let fallbackText = overlayModel.lyricsFallbackPreviewText {
                        Text(fallbackText)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.76))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(height: 41, alignment: .topLeading)
                            .clipped()
                    } else {
                        Text(overlayModel.lyricsLoadState == .loading ? "Matching this song ..." : "No synced lyrics found for the current track.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(height: 41, alignment: .topLeading)
                            .clipped()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.smooth(duration: 0.2), value: lyricLinesIdentity(at: timeline.date))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
    }

    private func lyricLine(text: String, isActive: Bool, isContext: Bool) -> some View {
        let font = Font.system(size: isActive ? 14 : 12, weight: isActive ? .semibold : .medium)

        return Text(text)
            .font(font)
            .foregroundStyle(
                isActive
                    ? Color.white.opacity(0.98)
                    : Color.white.opacity(isContext ? 0.46 : 0.72)
            )
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(height: 18, alignment: .leading)
        .clipped()
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.16), value: isActive)
    }

    private func lyricLinesIdentity(at date: Date) -> String {
        overlayModel.visibleLyricsLines(at: date)
            .map(\.line.id)
            .joined(separator: "|")
    }

    private var expandedPageHeader: some View {
        HStack(spacing: 10) {
            Text(overlayModel.activeExpandedWidgetPage?.title ?? "Widget")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))

            Spacer(minLength: 0)

            if overlayModel.expandedWidgetPages.count > 1 {
                panelIconButton("chevron.left") {
                    overlayModel.showPreviousExpandedWidgetPage()
                }
                .opacity(canMoveExpandedPageBackward ? 1 : 0.35)

                HStack(spacing: 5) {
                    ForEach(overlayModel.expandedWidgetPages) { page in
                        Circle()
                            .fill(page.id == overlayModel.activeExpandedWidgetPage?.id ? Color.white.opacity(0.9) : Color.white.opacity(0.24))
                            .frame(width: 5, height: 5)
                    }
                }

                panelIconButton("chevron.right") {
                    overlayModel.showNextExpandedWidgetPage()
                }
                .opacity(canMoveExpandedPageForward ? 1 : 0.35)
            }
        }
    }

    private var compactExpandedPager: some View {
        HStack(spacing: 6) {
            compactPagerButton("chevron.left") {
                overlayModel.showPreviousExpandedWidgetPage()
            }
            .opacity(canMoveExpandedPageBackward ? 1 : 0.35)

            HStack(spacing: 4) {
                ForEach(overlayModel.expandedWidgetPages) { page in
                    Capsule(style: .continuous)
                        .fill(page.id == overlayModel.activeExpandedWidgetPage?.id ? Color.white.opacity(0.88) : Color.white.opacity(0.18))
                        .frame(width: page.id == overlayModel.activeExpandedWidgetPage?.id ? 12 : 4, height: 4)
                }
            }

            compactPagerButton("chevron.right") {
                overlayModel.showNextExpandedWidgetPage()
            }
            .opacity(canMoveExpandedPageForward ? 1 : 0.35)
        }
    }

    @ViewBuilder
    private var expandedPageContent: some View {
        switch overlayModel.activeExpandedWidgetPage {
        case let descriptor?:
            switch descriptor.source {
            case .builtIn(.nowPlaying):
                nowPlayingExpandedPage
            case .builtIn(.widgetBoard):
                dashboardWidgetBoard
            case .builtIn(.pinnedFile):
                pinnedFileExpandedPage
            case .builtIn(.weather):
                weatherExpandedPage
            case .builtIn(.pomodoro):
                pomodoroExpandedPage
            case .plugin:
                if let render = descriptor.render {
                    render()
                } else {
                    EmptyView()
                }
            }
        case nil:
            EmptyView()
        }
    }

    private var canMoveExpandedPageBackward: Bool {
        guard
            let currentPage = overlayModel.activeExpandedWidgetPage,
            let index = overlayModel.expandedWidgetPages.firstIndex(where: { $0.id == currentPage.id })
        else {
            return false
        }

        return index > 0
    }

    private var canMoveExpandedPageForward: Bool {
        guard
            let currentPage = overlayModel.activeExpandedWidgetPage,
            let index = overlayModel.expandedWidgetPages.firstIndex(where: { $0.id == currentPage.id })
        else {
            return false
        }

        return index < overlayModel.expandedWidgetPages.count - 1
    }

    private var nowPlayingExpandedPage: some View { nowPlayingPlayerPanel }

    private var dashboardWidgetBoard: some View {
        HStack(spacing: 10) {
            dashboardPane(slot: .leading)
            dashboardPane(slot: .trailing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func dashboardPane(slot: DashboardWidgetSlot) -> some View {
        let identity = overlayModel.dashboardWidgetIdentity(for: slot)
        let showsSystemWarning = identity == .builtIn(.systemStatus)
            && overlayModel.systemStatusSnapshot.hasWarning

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: overlayModel.dashboardWidgetSymbol(identity))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.58))

                Text(overlayModel.dashboardWidgetTitle(identity))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)

                Spacer(minLength: 0)

                dashboardWidgetPicker(slot: slot, selected: identity)
            }

            dashboardWidgetContent(identity)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(showsSystemWarning ? Color.orange.opacity(0.10) : Color.white.opacity(0.055))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(
                            showsSystemWarning ? Color.orange.opacity(0.42) : Color.white.opacity(0.08),
                            lineWidth: 0.8
                        )
                )
        )
    }

    private func dashboardWidgetPicker(slot: DashboardWidgetSlot, selected: DashboardWidgetIdentity) -> some View {
        Menu {
            ForEach(overlayModel.availableDashboardWidgets, id: \.storageToken) { identity in
                Button {
                    overlayModel.selectDashboardWidget(identity, for: slot)
                } label: {
                    Label(
                        overlayModel.dashboardWidgetTitle(identity),
                        systemImage: selected == identity ? "checkmark" : overlayModel.dashboardWidgetSymbol(identity)
                    )
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.46))
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private func dashboardWidgetContent(_ identity: DashboardWidgetIdentity) -> some View {
        switch identity {
        case .builtIn(let kind):
            switch kind {
            case .todayAgenda:
                dashboardAgendaWidget
            case .monthCalendar:
                dashboardMonthCalendarWidget
            case .nowPlayingArtwork:
                if overlayModel.isFeatureEnabled(.nowPlaying) {
                    dashboardArtworkWidget
                } else {
                    dashboardDisabledFeatureState("Now Playing")
                }
            case .weather:
                if overlayModel.isFeatureEnabled(.weather) {
                    dashboardWeatherWidget
                } else {
                    dashboardDisabledFeatureState("Weather")
                }
            case .pomodoro:
                if overlayModel.isFeatureEnabled(.pomodoro) {
                    dashboardPomodoroWidget
                } else {
                    dashboardDisabledFeatureState("Pomodoro")
                }
            case .pinnedFile:
                if overlayModel.isFeatureEnabled(.pinnedFile) {
                    dashboardPinnedFileWidget
                } else {
                    dashboardDisabledFeatureState("Pinned File")
                }
            case .battery:
                if overlayModel.isFeatureEnabled(.battery) {
                    dashboardBatteryWidget
                } else {
                    dashboardDisabledFeatureState("Battery")
                }
            case .todayTasks:
                if overlayModel.isFeatureEnabled(.reminders) {
                    dashboardTodayTasksWidget
                } else {
                    dashboardDisabledFeatureState("Reminders")
                }
            case .systemStatus:
                if overlayModel.isFeatureEnabled(.systemStatus) {
                    dashboardSystemStatusWidget
                } else {
                    dashboardDisabledFeatureState("System Status")
                }
            }
        case .plugin(let id):
            if let descriptor = overlayModel.pluginDashboardWidgets.first(where: { $0.id == id }) {
                descriptor.render()
            } else {
                dashboardUnavailableState(
                    systemName: "puzzlepiece.extension",
                    title: "Plugin unavailable",
                    message: "The selected plugin is disabled or not loaded."
                )
            }
        }
    }

    @ViewBuilder
    private var dashboardAgendaWidget: some View {
        let calendarModel = overlayModel.calendarWidgetModel
        Group {
            switch calendarModel.accessState {
            case .authorized:
                VStack(alignment: .leading, spacing: 7) {
                    Text(Date.now.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)

                    if calendarModel.todayEvents.isEmpty {
                        Spacer(minLength: 10)
                        dashboardUnavailableState(
                            systemName: "calendar.badge.checkmark",
                            title: "No events today",
                            message: "Your schedule is clear."
                        )
                    } else {
                        ForEach(calendarModel.todayEvents) { event in
                            dashboardEventRow(event)
                        }
                        Spacer(minLength: 0)
                    }
                }
            case .requesting:
                dashboardProgressState("Requesting calendar access…")
            case .notDetermined:
                dashboardProgressState("Preparing Calendar…")
            case .denied, .restricted:
                dashboardCalendarPermissionState
            }
        }
        .task { await calendarModel.prepareIfNeeded() }
    }

    @ViewBuilder
    private var dashboardMonthCalendarWidget: some View {
        let calendarModel = overlayModel.calendarWidgetModel
        Group {
            switch calendarModel.accessState {
            case .authorized:
                VStack(spacing: 3) {
                    HStack {
                        dashboardMonthButton("chevron.left") { calendarModel.moveMonth(by: -1) }
                        Spacer()
                        Text(calendarModel.monthTitle)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                        Spacer()
                        dashboardMonthButton("chevron.right") { calendarModel.moveMonth(by: 1) }
                    }

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                        ForEach(Array(calendarModel.weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                            Text(symbol)
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.35))
                                .frame(height: 11)
                        }

                        ForEach(Array(calendarModel.monthGridDates.enumerated()), id: \.offset) { _, date in
                            if let date {
                                dashboardCalendarDay(date, model: calendarModel)
                            } else {
                                Color.clear.frame(height: 17)
                            }
                        }
                    }

                    if let event = calendarModel.selectedDateEvents.first {
                        dashboardEventRow(event, compact: true)
                    } else {
                        Text("No events on selected day")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.35))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 2)
                    }
                }
            case .requesting:
                dashboardProgressState("Requesting calendar access…")
            case .notDetermined:
                dashboardProgressState("Preparing Calendar…")
            case .denied, .restricted:
                dashboardCalendarPermissionState
            }
        }
        .task { await calendarModel.prepareIfNeeded() }
    }

    private func dashboardCalendarDay(_ date: Date, model: CalendarWidgetModel) -> some View {
        Button {
            model.select(date: date)
        } label: {
            VStack(spacing: 0) {
                Text(date.formatted(.dateTime.day()))
                    .font(.system(size: 9, weight: model.isToday(date) ? .bold : .medium))
                Circle()
                    .fill(model.hasEvents(on: date) ? Color.white.opacity(0.8) : Color.clear)
                    .frame(width: 2.5, height: 2.5)
            }
            .foregroundStyle(model.isSelected(date) ? Color.black : Color.white.opacity(model.isToday(date) ? 1 : 0.72))
            .frame(maxWidth: .infinity, minHeight: 17)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(model.isSelected(date) ? Color.white : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var dashboardArtworkWidget: some View {
        Group {
            if let image = artworkImage(for: overlayModel.artworkData) {
                HStack(spacing: 12) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 112, height: 112)
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                        .shadow(color: .black.opacity(0.35), radius: 10, y: 5)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(overlayModel.nowPlayingTitle ?? "Now Playing")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Text(overlayModel.nowPlayingArtist ?? "Unknown Artist")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
            } else {
                dashboardUnavailableState(systemName: "music.note", title: "Not Playing", message: "Cover art appears when media starts.")
            }
        }
    }

    private var dashboardWeatherWidget: some View {
        Group {
            if let temperature = overlayModel.weatherTemperatureText {
                VStack(spacing: 11) {
                    HStack(spacing: 11) {
                        Image(systemName: overlayModel.weatherSymbolName ?? "cloud.fill")
                            .font(.system(size: 30, weight: .medium))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white.opacity(0.86))
                            .frame(width: 45)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(temperature)
                                .font(.system(size: 28, weight: .bold))
                                .foregroundStyle(.white)
                            Text(overlayModel.manualWeatherLocation ?? "Current Location")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        dashboardSmallButton("Refresh", systemName: "arrow.clockwise") { overlayModel.refreshWeather() }
                    }

                    weatherForecastStrip
                }
                .padding(.vertical, 5)
                .frame(maxHeight: .infinity)
            } else {
                dashboardUnavailableState(systemName: "cloud.slash", title: "Weather unavailable", message: "Enable Weather or set a location.")
            }
        }
    }

    private var dashboardPomodoroWidget: some View {
        VStack(spacing: 7) {
            Spacer(minLength: 0)
            Image(systemName: overlayModel.pomodoroPhase.symbolName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            Text(overlayModel.pomodoroTimeText)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
            Text(overlayModel.pomodoroPhase.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
            HStack(spacing: 6) {
                dashboardSmallButton(overlayModel.pomodoroIsRunning ? "Pause" : "Start", systemName: overlayModel.pomodoroIsRunning ? "pause.fill" : "play.fill") {
                    overlayModel.togglePomodoroRunning()
                }
                dashboardSmallButton("Skip", systemName: "forward.end.fill") { overlayModel.skipPomodoroPhase() }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private var dashboardPinnedFileWidget: some View {
        Group {
            if let file = overlayModel.selectedPinnedFile {
                VStack(spacing: 8) {
                    Spacer(minLength: 0)
                    PinnedFileThumbnailView(item: file, size: 72)
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    Text(file.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(file.isAvailable ? .white : .orange)
                        .lineLimit(1)
                    Text("\(overlayModel.pinnedFiles.count) pinned")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            } else {
                dashboardUnavailableState(systemName: "pin.slash", title: "No pinned files", message: "Drop files onto Pull Notch to add them.")
            }
        }
    }

    private var dashboardBatteryWidget: some View {
        Group {
            if overlayModel.batteryLevel != nil || !overlayModel.accessoryBatteryDevices.isEmpty {
                VStack(spacing: 7) {
                    if let level = overlayModel.batteryLevel {
                        batteryDeviceRow(
                            name: "This Mac",
                            level: level,
                            detail: overlayModel.batteryIsCharging ? (overlayModel.chargingPowerText ?? "Charging") : "Internal battery",
                            symbolName: overlayModel.batterySymbolName,
                            isConnected: true
                        )
                    }
                    ForEach(overlayModel.accessoryBatteryDevices.prefix(3)) { device in
                        batteryDeviceRow(
                            name: device.name,
                            level: device.level,
                            detail: device.detailText,
                            symbolName: device.symbolName,
                            isConnected: device.isConnected
                        )
                    }
                }
                .frame(maxWidth: .infinity)
            } else {
                dashboardUnavailableState(systemName: "battery.0percent", title: "Battery unavailable", message: "No battery-powered devices were detected.")
            }
        }
    }

    private func batteryDeviceRow(
        name: String,
        level: Int,
        detail: String,
        symbolName: String,
        isConnected: Bool
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbolName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(level <= 15 ? .orange : .white.opacity(0.78))
                .frame(width: 25)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(isConnected ? 0.9 : 0.55))
                        .lineLimit(1)
                    if !isConnected {
                        Text("CACHED")
                            .font(.system(size: 6.5, weight: .bold))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                }
                Text(detail)
                    .font(.system(size: 8.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text("\(level)%")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(level <= 15 ? .orange : .white.opacity(0.88))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var weatherForecastStrip: some View {
        HStack(spacing: 3) {
            ForEach(Array(overlayModel.weatherForecast.prefix(7).enumerated()), id: \.element.id) { index, day in
                VStack(spacing: 4) {
                    Text(index == 0 ? "Today" : day.date.formatted(.dateTime.weekday(.narrow)))
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(index == 0 ? 0.8 : 0.42))
                    Image(systemName: day.symbolName)
                        .font(.system(size: 12, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white.opacity(0.72))
                    Text("\(day.highTemperature)°")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.86))
                    Text("\(day.lowTemperature)°")
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.36))
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var dashboardTodayTasksWidget: some View {
        let model = overlayModel.reminderWidgetModel
        Group {
            switch model.accessState {
            case .authorized:
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        if model.overdueCount > 0 {
                            Text("\(model.overdueCount) overdue")
                                .foregroundStyle(.orange.opacity(0.9))
                        }
                        Text("\(model.remainingCount) remaining")
                            .foregroundStyle(.white.opacity(0.42))
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 9, weight: .semibold))

                    if model.isLoading && model.items.isEmpty {
                        dashboardProgressState("Loading Reminders…")
                    } else if model.items.isEmpty {
                        dashboardUnavailableState(
                            systemName: "checkmark.circle.fill",
                            title: "All caught up",
                            message: "No overdue or due-today reminders."
                        )
                    } else {
                        ForEach(model.items.prefix(4)) { item in
                            dashboardReminderRow(item)
                        }
                        Spacer(minLength: 0)
                    }

                    if let errorMessage = model.errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.orange.opacity(0.85))
                            .lineLimit(2)
                    }
                }
            case .requesting:
                dashboardProgressState("Requesting Reminders access…")
            case .notDetermined:
                dashboardProgressState("Preparing Reminders…")
            case .denied, .restricted:
                VStack(spacing: 8) {
                    dashboardUnavailableState(
                        systemName: "checklist.unchecked",
                        title: "Reminders access needed",
                        message: "Allow access in System Settings."
                    )
                    dashboardSmallButton("Open Settings", systemName: "gear") {
                        overlayModel.openReminderPrivacySettings()
                    }
                }
            }
        }
        .task { await model.prepareIfNeeded() }
    }

    private func dashboardReminderRow(_ item: ReminderWidgetItem) -> some View {
        HStack(spacing: 8) {
            Button {
                overlayModel.completeReminder(id: item.id)
            } label: {
                Image(systemName: "circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(item.isOverdue ? Color.orange.opacity(0.9) : Color.white.opacity(0.55))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                Text(item.isOverdue ? "Overdue · \(item.listTitle)" : reminderDueTimeText(item.dueDate, listTitle: item.listTitle))
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(item.isOverdue ? Color.orange.opacity(0.72) : Color.white.opacity(0.35))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var dashboardSystemStatusWidget: some View {
        let snapshot = overlayModel.systemStatusSnapshot
        return VStack(alignment: .leading, spacing: 10) {
            dashboardSystemMetricRow(
                title: "CPU",
                value: snapshot.cpuUsage,
                valueText: snapshot.cpuUsage.map(percentText) ?? "Unavailable",
                isWarning: (snapshot.cpuUsage ?? 0) >= 0.85
            )
            dashboardSystemMetricRow(
                title: "Memory",
                value: snapshot.memoryUsage,
                valueText: memoryStatusText(snapshot),
                isWarning: (snapshot.memoryUsage ?? 0) >= 0.85
            )
            dashboardSystemMetricRow(
                title: "Storage",
                value: snapshot.storageUsage,
                valueText: storageStatusText(snapshot),
                isWarning: (snapshot.storageUsage ?? 0) >= 0.90
            )
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
    }

    private func dashboardSystemMetricRow(
        title: String,
        value: Double?,
        valueText: String,
        isWarning: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.58))
                Spacer()
                Text(valueText)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(isWarning ? Color.orange.opacity(0.95) : Color.white.opacity(0.72))
                    .lineLimit(1)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    if let value {
                        Capsule()
                            .fill(isWarning ? Color.orange.opacity(0.85) : Color.white.opacity(0.72))
                            .frame(width: proxy.size.width * CGFloat(min(1, max(0, value))))
                    }
                }
            }
            .frame(height: 6)
        }
    }

    private func reminderDueTimeText(_ date: Date, listTitle: String) -> String {
        let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: date)
        if components.hour == 0 && components.minute == 0 {
            return "Today · \(listTitle)"
        }
        return "\(date.formatted(date: .omitted, time: .shortened)) · \(listTitle)"
    }

    private func percentText(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func memoryStatusText(_ snapshot: SystemStatusSnapshot) -> String {
        guard let used = snapshot.usedMemoryBytes, let total = snapshot.totalMemoryBytes else { return "Unavailable" }
        return "\(byteCount(used)) / \(byteCount(total))"
    }

    private func storageStatusText(_ snapshot: SystemStatusSnapshot) -> String {
        guard let available = snapshot.availableStorageBytes else { return "Unavailable" }
        return "\(byteCount(UInt64(max(0, available)))) free"
    }

    private func byteCount(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    private var dashboardCalendarPermissionState: some View {
        VStack(spacing: 8) {
            dashboardUnavailableState(systemName: "calendar.badge.exclamationmark", title: "Calendar access needed", message: "Allow read access in System Settings.")
            dashboardSmallButton("Open Settings", systemName: "gear") {
                overlayModel.calendarWidgetModel.openSystemSettings()
            }
        }
    }

    private func dashboardEventRow(_ event: CalendarEventItem, compact: Bool = false) -> some View {
        HStack(spacing: 7) {
            Capsule().fill(Color.white.opacity(0.55)).frame(width: 2.5)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: compact ? 9 : 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
                Text(event.isAllDay ? "All-day" : event.startDate.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, compact ? 1 : 3)
    }

    private func dashboardUnavailableState(systemName: String, title: String, message: String) -> some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            Image(systemName: systemName)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.white.opacity(0.42))
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
            Text(message)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.35))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func dashboardDisabledFeatureState(_ featureName: String) -> some View {
        dashboardUnavailableState(
            systemName: "switch.2",
            title: "\(featureName) is disabled",
            message: "Enable it from Pull Notch Settings."
        )
    }

    private func dashboardProgressState(_ text: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.4))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func dashboardMonthButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.white.opacity(0.07)))
        }
        .buttonStyle(.plain)
    }

    private func dashboardSmallButton(_ title: String, systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    private var pinnedFileExpandedPage: some View {
        VStack(alignment: .leading, spacing: 5) {
            pinnedFileCoverFlow

            if let selected = overlayModel.selectedPinnedFile {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selected.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        Text(
                            overlayModel.pinnedFileStatusMessage
                                ?? (selected.isAvailable ? selected.parentPath : "File unavailable · \(selected.parentPath)")
                        )
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(
                                overlayModel.pinnedFileStatusMessage == nil && selected.isAvailable
                                    ? Color.gray
                                    : Color.orange.opacity(0.9)
                            )
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Text("\(overlayModel.pinnedFiles.count)/\(overlayModel.maximumPinnedFileCount)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                }

                HStack(spacing: 7) {
                    panelActionButton("Preview", systemName: "eye.fill", isEnabled: selected.isAvailable) {
                        overlayModel.quickLookPinnedFile()
                    }

                    panelActionButton("Open", systemName: "arrow.up.forward.app", isEnabled: selected.isAvailable) {
                        guard let url = selected.url else { return }
                        NSWorkspace.shared.open(url)
                    }

                    panelActionButton("Share", systemName: "square.and.arrow.up", isEnabled: selected.isAvailable) {
                        overlayModel.sharePinnedFile()
                    }

                    panelActionButton("Reveal", systemName: "folder.fill", isEnabled: selected.isAvailable) {
                        guard let url = selected.url else { return }
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }

                    panelActionButton("Unpin", systemName: "pin.slash.fill") {
                        overlayModel.removePinnedFile(id: selected.id)
                    }

                    Spacer(minLength: 0)

                    panelIconButton("plus") {
                        overlayModel.choosePinnedFiles()
                    }
                }
            }
        }
    }

    private var pinnedFileCoverFlow: some View {
        let selectedID = overlayModel.selectedPinnedFileID ?? overlayModel.pinnedFiles.first?.id
        let selectedIndex = overlayModel.pinnedFiles.firstIndex(where: { $0.id == selectedID }) ?? 0

        return ScrollView(.horizontal) {
            LazyHStack(spacing: -8) {
                ForEach(Array(overlayModel.pinnedFiles.enumerated()), id: \.element.id) { index, item in
                    pinnedFileCoverFlowCard(
                        item,
                        position: index - selectedIndex,
                        isSelected: item.id == selectedID
                    )
                    .id(item.id)
                    .frame(width: 100)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        overlayModel.selectPinnedFile(id: item.id)
                        overlayModel.quickLookPinnedFile()
                    }
                    .onTapGesture {
                        overlayModel.selectPinnedFile(id: item.id)
                        withAnimation(.smooth(duration: 0.22)) {
                            pinnedScrollID = item.id
                        }
                    }
                    .draggable(item.id.uuidString)
                    .dropDestination(for: String.self) { values, _ in
                        guard let value = values.first,
                              let sourceID = UUID(uuidString: value)
                        else {
                            return false
                        }
                        overlayModel.movePinnedFile(id: sourceID, before: item.id)
                        overlayModel.selectPinnedFile(id: sourceID)
                        pinnedScrollID = sourceID
                        return true
                    }
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .contentMargins(.horizontal, max(0, (overlayModel.visibleWidth - 128) / 2), for: .scrollContent)
        .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
        .scrollPosition(id: $pinnedScrollID, anchor: .center)
        .frame(height: 112)
        .task {
            acceptsPinnedScrollSelection = false
            pinnedScrollID = selectedID
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            pinnedScrollID = selectedID
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            acceptsPinnedScrollSelection = true
        }
        .onChange(of: pinnedScrollID) { _, newValue in
            if acceptsPinnedScrollSelection, let newValue {
                overlayModel.selectPinnedFile(id: newValue)
            }
        }
        .onChange(of: overlayModel.selectedPinnedFileID) { _, newValue in
            guard pinnedScrollID != newValue else { return }
            withAnimation(.smooth(duration: 0.22)) {
                pinnedScrollID = newValue
            }
        }
    }

    private func pinnedFileCoverFlowCard(
        _ item: PinnedFileItem,
        position: Int,
        isSelected: Bool
    ) -> some View {
        let thumbnailSize: CGFloat = isSelected ? 92 : 72
        let rotation = isSelected ? 0 : (position < 0 ? 52.0 : -52.0)

        return VStack(spacing: 1) {
            PinnedFileThumbnailView(item: item, size: thumbnailSize)
                .frame(width: thumbnailSize, height: thumbnailSize)
                .clipShape(RoundedRectangle(cornerRadius: isSelected ? 15 : 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: isSelected ? 15 : 12, style: .continuous)
                        .stroke(Color.white.opacity(isSelected ? 0.28 : 0.10), lineWidth: 0.8)
                }
                .overlay(alignment: .topTrailing) {
                    if !item.isAvailable {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.orange)
                            .padding(5)
                            .background(Circle().fill(Color.black.opacity(0.72)))
                            .padding(4)
                    }
                }
                .shadow(color: .black.opacity(isSelected ? 0.45 : 0.25), radius: isSelected ? 12 : 7, y: 5)

            PinnedFileThumbnailView(item: item, size: thumbnailSize)
                .frame(width: thumbnailSize, height: 18)
                .clipped()
                .scaleEffect(x: 1, y: -1)
                .opacity(isSelected ? 0.20 : 0.10)
                .mask(
                    LinearGradient(
                        colors: [.white.opacity(0.7), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .rotation3DEffect(.degrees(rotation), axis: (x: 0, y: 1, z: 0), perspective: 0.72)
        .scaleEffect(isSelected ? 1 : 0.82)
        .opacity(isSelected ? 1 : 0.65)
        .zIndex(isSelected ? 10 : Double(max(0, 5 - abs(position))))
        .animation(.smooth(duration: 0.22), value: isSelected)
    }

    private var weatherExpandedPage: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .frame(width: 64, height: 64)
                .overlay {
                    Image(systemName: overlayModel.weatherSymbolName ?? "cloud.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.82))
                }

            VStack(alignment: .leading, spacing: 6) {
                Text(overlayModel.weatherTemperatureText ?? "--°")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(overlayModel.manualWeatherLocation ?? "Current Location")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.gray)
                    .lineLimit(1)

                Text(overlayModel.manualWeatherLocation == nil ? "位置情報または現在地ベース" : "手動で設定した地点")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))

                HStack(spacing: 8) {
                    panelActionButton("Refresh", systemName: "arrow.clockwise") {
                        overlayModel.refreshWeather()
                    }
                }
                .padding(.top, 4)
            }

            Spacer(minLength: 0)
            }

            weatherForecastStrip
        }
    }

    private var pomodoroExpandedPage: some View {
        HStack(alignment: .center, spacing: 14) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .frame(width: 64, height: 64)
                .overlay {
                    Image(systemName: overlayModel.pomodoroPhase.symbolName)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.84))
                }

            VStack(alignment: .leading, spacing: 6) {
                Text(overlayModel.pomodoroPhase.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.gray)
                    .lineLimit(1)

                Text(overlayModel.pomodoroTimeText)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .lineLimit(1)

                Text(overlayModel.pomodoroIsRunning ? "タイマー進行中" : "停止中")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))

                HStack(spacing: 8) {
                    panelActionButton(
                        overlayModel.pomodoroIsRunning ? "Pause" : "Start",
                        systemName: overlayModel.pomodoroIsRunning ? "pause.fill" : "play.fill"
                    ) {
                        overlayModel.togglePomodoroRunning()
                    }

                    panelActionButton("Skip", systemName: "forward.end.fill") {
                        overlayModel.skipPomodoroPhase()
                    }

                    panelActionButton("Reset", systemName: "arrow.counterclockwise") {
                        overlayModel.resetPomodoro()
                    }
                }
                .padding(.top, 4)
            }

            Spacer(minLength: 0)
        }
    }

    private var emptyExpandedPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Widget")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))

            Text("現在アクティブなwidgetがありません")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)

            Text("機能を有効にすると、ここに利用可能な widget が表示されます。")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.gray)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: overlayModel.visibleWidth - 28, alignment: .leading)
    }

    private func playerButton(
        _ systemName: String,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: prominent ? 14 : 12, weight: .semibold))
                .foregroundStyle(.white.opacity(prominent ? 0.95 : 0.72))
                .frame(width: prominent ? 30 : 26, height: prominent ? 30 : 26)
                .background(
                    Circle()
                        .fill(prominent ? Color.white.opacity(0.14) : Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
    }

    private func panelIconButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
    }

    private func compactPagerButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.72))
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
    }

    private func panelActionButton(
        _ title: String,
        systemName: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(.white.opacity(0.82))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
    }
}

private struct CenterExpansionModifier: ViewModifier {
    let scaleX: CGFloat
    let scaleY: CGFloat
    let opacity: Double
    let yOffset: CGFloat
    let blurRadius: CGFloat

    init(scale: CGFloat, opacity: Double, yOffset: CGFloat, blurRadius: CGFloat = 0) {
        self.scaleX = scale
        self.scaleY = scale
        self.opacity = opacity
        self.yOffset = yOffset
        self.blurRadius = blurRadius
    }

    init(scaleX: CGFloat, scaleY: CGFloat, opacity: Double, yOffset: CGFloat, blurRadius: CGFloat = 0) {
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.opacity = opacity
        self.yOffset = yOffset
        self.blurRadius = blurRadius
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: scaleX, y: scaleY, anchor: UnitPoint(x: 0.5, y: 0))
            .blur(radius: blurRadius)
            .opacity(opacity)
            .offset(y: yOffset)
    }
}

private struct SiriGlassIslandSurface: View {
    let cornerRadius: CGFloat
    let showsBorder: Bool
    let castsShadow: Bool

    var body: some View {
        let shape = DynamicIslandShape(cornerRadius: cornerRadius)

        Color.clear
            .glassEffect(
                .regular.tint(Color.black.opacity(0.38)),
                in: shape
            )
            .overlay {
                shape.fill(
                    LinearGradient(
                        stops: [
                            .init(color: Color.black.opacity(0.70), location: 0),
                            .init(color: Color.black.opacity(0.54), location: 0.38),
                            .init(color: Color.black.opacity(0.30), location: 0.72),
                            .init(color: Color.white.opacity(0.035), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .allowsHitTesting(false)
            }
            .overlay {
                if showsBorder {
                    shape.stroke(
                        LinearGradient(
                            stops: [
                                .init(color: Color.white.opacity(0.13), location: 0),
                                .init(color: Color.white.opacity(0.025), location: 0.42),
                                .init(color: Color.white.opacity(0.10), location: 1)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.65
                    )
                    .allowsHitTesting(false)
                }
            }
            .shadow(
                color: Color.black.opacity(castsShadow ? 0.24 : 0),
                radius: castsShadow ? 12 : 0,
                x: 0,
                y: castsShadow ? 7 : 0
            )
            .shadow(
                color: Color.white.opacity(castsShadow ? 0.025 : 0),
                radius: castsShadow ? 1 : 0,
                x: 0,
                y: 1
            )
    }
}

private struct PinnedFileThumbnailView: View {
    let item: PinnedFileItem
    let size: CGFloat

    @State private var image: NSImage?

    var body: some View {
        Image(nsImage: image ?? fallbackImage)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .background(Color.white.opacity(0.06))
            .task(id: cacheKey) {
                image = await PinnedFileThumbnailCache.shared.image(for: item, size: size)
            }
    }

    private var fallbackImage: NSImage {
        if let url = item.url {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "doc.fill", accessibilityDescription: nil) ?? NSImage()
    }

    private var cacheKey: String {
        "\(item.id.uuidString)-\(item.modificationDate?.timeIntervalSinceReferenceDate ?? 0)-\(Int(size))"
    }
}

@MainActor
private final class PinnedFileThumbnailCache {
    static let shared = PinnedFileThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()

    func image(for item: PinnedFileItem, size: CGFloat) async -> NSImage {
        let key = "\(item.id.uuidString)-\(item.modificationDate?.timeIntervalSinceReferenceDate ?? 0)-\(Int(size))" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let fallback: NSImage
        if let url = item.url {
            fallback = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            fallback = NSImage(systemSymbolName: "doc.fill", accessibilityDescription: nil) ?? NSImage()
        }
        guard item.isAvailable, let url = item.url else {
            cache.setObject(fallback, forKey: key)
            return fallback
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: size * 2, height: size * 2),
            scale: 2,
            representationTypes: .all
        )

        let generated = await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.nsImage)
            }
        }
        let result = generated ?? fallback
        cache.setObject(result, forKey: key)
        return result
    }
}

#Preview {
    ContentView(overlayModel: previewOverlayModel)
}

private struct DynamicIslandShape: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(cornerRadius, rect.width / 2, rect.height / 2)

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - radius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.closeSubpath()
        return path
    }
}

private var previewOverlayModel: NotchOverlayModel {
    let overlayModel = NotchOverlayModel()
    overlayModel.present(
        .init(
            id: "preview",
            detailLine: "Everything in Its Right Place - Radiohead",
            sourceApp: "Music",
            artworkData: nil,
            isPlaying: true
        ),
        revealChange: true
    )
    return overlayModel
}

private struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color
    var leadingSystemImage: String? = "music.note"

    @State private var availableWidth: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @State private var animate = false

    private var animationID: String {
        "\(text)-\(Int(availableWidth.rounded()))-\(Int(textWidth.rounded()))"
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                if textWidth > availableWidth, availableWidth > 0 {
                    HStack(spacing: 24) {
                        marqueeLabel
                        marqueeLabel
                    }
                    .frame(width: availableWidth, alignment: .leading)
                    .offset(x: animate ? -(textWidth + 24) : 0)
                } else {
                    marqueeLabel
                        .frame(width: availableWidth, alignment: .center)
                }
            }
            .clipped()
            .onAppear { availableWidth = geometry.size.width }
            .onChange(of: geometry.size.width) { _, newValue in
                availableWidth = newValue
            }
            .task(id: animationID) {
                animate = false
                guard textWidth > availableWidth, availableWidth > 0 else { return }
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                withAnimation(.linear(duration: marqueeDuration).repeatForever(autoreverses: false)) {
                    animate = true
                }
            }
        }
        .frame(height: 16)
    }

    private var marqueeDuration: TimeInterval {
        max(7, TimeInterval((textWidth + 24) / 22))
    }

    private var marqueeLabel: some View {
        HStack(spacing: 6) {
            if let leadingSystemImage {
                Image(systemName: leadingSystemImage)
                    .font(font)
                    .foregroundStyle(color)
            }

            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .fixedSize()
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        textWidth = proxy.size.width
                    }
                    .onChange(of: proxy.size.width) { _, newValue in
                        textWidth = newValue
                    }
            }
        )
    }
}
