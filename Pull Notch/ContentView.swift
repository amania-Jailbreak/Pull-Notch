//
//  ContentView.swift
//  Pull Notch
//
//  Created by amania on 2026/03/30.
//

import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var overlayModel: NotchOverlayModel
    @State private var isHovering = false
    @State private var isDropTargeted = false
    @State private var visualizerHeights: [CGFloat] = [8, 14, 10, 16, 7]

    var body: some View {
        ZStack(alignment: .top) {
            islandShape
        }
        .frame(
            width: overlayModel.panelSize.width,
            height: overlayModel.panelSize.height,
            alignment: .top
        )
        .padding(.top, overlayModel.windowTopInset)
        .background(Color.clear)
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            guard let fileURL = urls.first(where: { $0.isFileURL }) else { return false }
            overlayModel.pinFile(fileURL)
            return true
        } isTargeted: { isTargeted in
            isDropTargeted = isTargeted
        }
        .onHover { hovering in
            guard hovering != isHovering else { return }
            isHovering = hovering
            overlayModel.setHoverTitleVisible(hovering)

            if hovering {
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 18)
                .onEnded { value in
                    guard overlayModel.expandedPanel == .musicPlayer else { return }
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

    private var islandShape: some View {
        ZStack(alignment: .top) {
            DynamicIslandShape(cornerRadius: 22)
                .fill(islandFill)
                .frame(width: overlayModel.visibleWidth, height: overlayModel.currentIslandHeight)
                .opacity((overlayModel.showsTrackChange || overlayModel.expandedPanel == .musicPlayer || overlayModel.showsHoverChange || overlayModel.showsVolumeChange) ? 1 : 0)
                .overlay(alignment: .bottom) {
                    expandedContent
                }
                .animation(.easeOut(duration: 0.18), value: overlayModel.showsTrackChange)
                .animation(musicPlayerExpansionAnimation, value: overlayModel.expandedPanel == .musicPlayer)
                .animation(.easeOut(duration: 0.16), value: overlayModel.showsHoverChange)
                .animation(.easeOut(duration: 0.16), value: overlayModel.showsVolumeChange)

            DynamicIslandShape(cornerRadius: 22)
                .fill(islandFill)
                .frame(width: overlayModel.visibleWidth, height: overlayModel.notchHeight)
                .overlay(alignment: .top) {
                    ZStack {
                        if overlayModel.expandedPanel != .musicPlayer {
                            compactBar
                                .padding(.top, 4)
                                .transition(.scale(scale: 0.92, anchor: .center).combined(with: .opacity))
                        }
                    }
                }
                .contentShape(DynamicIslandShape(cornerRadius: 22))
                .onTapGesture {
                    if overlayModel.expandedPanel != .onboarding {
                        overlayModel.toggleMusicPlayer()
                    }
                }
                .allowsHitTesting(overlayModel.expandedPanel != .musicPlayer)
                .animation(musicPlayerExpansionAnimation, value: overlayModel.expandedPanel == .musicPlayer)
        }
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
        .animation(.easeOut(duration: 0.14), value: hoverScale)
    }

    private var hoverScale: CGFloat {
        if overlayModel.showsHoverChange || overlayModel.expandedPanel == .musicPlayer {
            return 1
        }
        return isHovering ? 1.04 : 1
    }

    private var islandFill: Color {
        .black
    }

    private var musicPlayerExpansionAnimation: Animation {
        .spring(response: 0.34, dampingFraction: 0.86)
    }

    private var musicPlayerExpansionTransition: AnyTransition {
        .modifier(
            active: CenterExpansionModifier(scale: 0.92, opacity: 0, yOffset: -20),
            identity: CenterExpansionModifier(scale: 1, opacity: 1, yOffset: 0)
        )
    }

    private var compactBar: some View {
        HStack(spacing: 12) {
            compactWidgetSlot(overlayModel.leadingWidget)
            Spacer(minLength: overlayModel.compactCenterSpacing)
            compactWidgetSlot(overlayModel.trailingWidget)
        }
        .padding(.horizontal, 12)
        .frame(width: overlayModel.visibleWidth, height: overlayModel.notchHeight)
    }

    private func compactWidgetSlot(_ widget: CompactIslandWidget?) -> some View {
        ZStack {
            compactWidgetView(widget)
                .id(widget?.id ?? "empty")
                .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.18), value: widget?.id)
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
                    .fill(index.isMultiple(of: 2) ? Color.white.opacity(0.92) : Color.white.opacity(0.6))
                    .frame(width: 2.5, height: isActive ? height : 5)
                    .animation(
                        .easeInOut(duration: 0.22).delay(Double(index) * 0.03),
                        value: height
                    )
            }
        }
        .frame(height: 24)
        .task(id: "\(isActive)-\(overlayModel.usesRealNowPlayingVisualizer)") {
            guard isActive, !overlayModel.usesRealNowPlayingVisualizer else {
                visualizerHeights = [5, 5, 5, 5, 5]
                return
            }

            while isActive && !overlayModel.usesRealNowPlayingVisualizer {
                visualizerHeights = (0..<5).map { _ in .random(in: 7...20) }
                try? await Task.sleep(for: .milliseconds(180))
            }
        }
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
        } else if overlayModel.showsBatteryLowWarning {
            batteryWarningBanner
                .padding(.horizontal, 14)
                .padding(.bottom, 2)
        } else if overlayModel.showsHoverChange {
            hoverTitleBanner
                .opacity(overlayModel.showsHoverText ? 1 : 0)
                .offset(y: overlayModel.showsHoverText ? 0 : -4)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
                .animation(.easeOut(duration: 0.2), value: overlayModel.showsHoverText)
        } else {
            trackChangeBanner
                .opacity(overlayModel.showsTrackText ? 1 : 0)
                .offset(y: overlayModel.showsTrackText ? 0 : -4)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
                .animation(.easeOut(duration: 0.2), value: overlayModel.showsTrackText)
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
                }
            }
            .frame(height: 8)
        }
        .frame(width: overlayModel.visibleWidth - 32, height: 18, alignment: .leading)
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
        if let detailLine = overlayModel.detailLine {
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
        ZStack(alignment: .topLeading) {
            activeExpandedPageBody
                .id(activeExpandedPageID)
                .transition(.opacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(width: overlayModel.visibleWidth - 28, alignment: .leading)
        .clipped()
        .animation(.easeInOut(duration: 0.2), value: activeExpandedPageID)
    }

    @ViewBuilder
    private var activeExpandedPageBody: some View {
        if overlayModel.expandedWidgetPages.isEmpty {
            emptyExpandedPanel
        } else if overlayModel.activeExpandedWidgetPage == .nowPlaying {
            nowPlayingPlayerPanel
        } else {
            VStack(alignment: .leading, spacing: 12) {
                expandedPageHeader
                expandedPageContent

                panelActionButton("Settings", systemName: "gearshape.fill") {
                    overlayModel.openSettingsWindow()
                }
            }
            .padding(.top, 60)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var activeExpandedPageID: String {
        overlayModel.activeExpandedWidgetPage?.id ?? "empty-expanded-page"
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

                    visualizerView(isActive: overlayModel.isPlaying)
                        .frame(width: 34)
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
                .animation(.easeInOut(duration: 0.24), value: lyricLinesIdentity(at: timeline.date))
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
                            .fill(page == overlayModel.activeExpandedWidgetPage ? Color.white.opacity(0.9) : Color.white.opacity(0.24))
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
                        .fill(page == overlayModel.activeExpandedWidgetPage ? Color.white.opacity(0.88) : Color.white.opacity(0.18))
                        .frame(width: page == overlayModel.activeExpandedWidgetPage ? 12 : 4, height: 4)
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
        case .nowPlaying:
            nowPlayingExpandedPage
        case .pinnedFile:
            pinnedFileExpandedPage
        case .weather:
            weatherExpandedPage
        case .pomodoro:
            pomodoroExpandedPage
        case nil:
            EmptyView()
        }
    }

    private var canMoveExpandedPageBackward: Bool {
        guard
            let currentPage = overlayModel.activeExpandedWidgetPage,
            let index = overlayModel.expandedWidgetPages.firstIndex(of: currentPage)
        else {
            return false
        }

        return index > 0
    }

    private var canMoveExpandedPageForward: Bool {
        guard
            let currentPage = overlayModel.activeExpandedWidgetPage,
            let index = overlayModel.expandedWidgetPages.firstIndex(of: currentPage)
        else {
            return false
        }

        return index < overlayModel.expandedWidgetPages.count - 1
    }

    private var nowPlayingExpandedPage: some View { nowPlayingPlayerPanel }

    private var pinnedFileExpandedPage: some View {
        HStack(alignment: .center, spacing: 14) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .frame(width: 64, height: 64)
                .overlay {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.82))
                }

            VStack(alignment: .leading, spacing: 6) {
                Text(overlayModel.pinnedFileURL?.lastPathComponent ?? "No File")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(overlayModel.pinnedFileURL?.deletingLastPathComponent().path ?? "ファイルがありません")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.gray)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    panelActionButton("Open", systemName: "arrow.up.forward.app") {
                        guard let pinnedFileURL = overlayModel.pinnedFileURL else { return }
                        NSWorkspace.shared.open(pinnedFileURL)
                    }

                    panelActionButton("Share", systemName: "square.and.arrow.up") {
                        overlayModel.sharePinnedFile()
                    }

                    panelActionButton("Reveal", systemName: "folder.fill") {
                        guard let pinnedFileURL = overlayModel.pinnedFileURL else { return }
                        NSWorkspace.shared.activateFileViewerSelecting([pinnedFileURL])
                    }

                    panelActionButton("Unpin", systemName: "pin.slash.fill") {
                        overlayModel.clearPinnedFile()
                    }
                }
                .padding(.top, 4)
            }

            Spacer(minLength: 0)
        }
    }

    private var weatherExpandedPage: some View {
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

            panelActionButton("Settings", systemName: "gearshape.fill") {
                overlayModel.openSettingsWindow()
            }
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

    private func panelActionButton(_ title: String, systemName: String, action: @escaping () -> Void) -> some View {
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
    }
}

private struct CenterExpansionModifier: ViewModifier {
    let scale: CGFloat
    let opacity: Double
    let yOffset: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale, anchor: .center)
            .opacity(opacity)
            .offset(y: yOffset)
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
            .onAppear {
                availableWidth = geometry.size.width
                animate = false
                if textWidth > geometry.size.width {
                    withAnimation(.linear(duration: 7).repeatForever(autoreverses: false)) {
                        animate = true
                    }
                }
            }
            .onChange(of: geometry.size.width) { _, newValue in
                availableWidth = newValue
                animate = false
                if textWidth > newValue {
                    withAnimation(.linear(duration: 7).repeatForever(autoreverses: false)) {
                        animate = true
                    }
                }
            }
            .onChange(of: textWidth) { _, newValue in
                animate = false
                if newValue > availableWidth, availableWidth > 0 {
                    withAnimation(.linear(duration: 7).repeatForever(autoreverses: false)) {
                        animate = true
                    }
                }
            }
        }
        .frame(height: 16)
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
