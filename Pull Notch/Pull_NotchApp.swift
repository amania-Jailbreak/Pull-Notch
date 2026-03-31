//
//  Pull_NotchApp.swift
//  Pull Notch
//
//  Created by amania on 2026/03/30.
//

import AVFAudio
import AppKit
import CoreAudio
import CoreGraphics
import CoreLocation
import CoreMedia
import Foundation
import IOKit.ps
import Observation
import ScreenCaptureKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

@main
struct Pull_NotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

private extension NSColor {
    func withSaturation(multiplier: CGFloat) -> NSColor {
        guard let converted = usingColorSpace(.deviceRGB) else { return self }

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        converted.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        return NSColor(
            calibratedHue: hue,
            saturation: min(1, saturation * multiplier),
            brightness: brightness,
            alpha: alpha
        )
    }

    func withBrightness(multiplier: CGFloat) -> NSColor {
        guard let converted = usingColorSpace(.deviceRGB) else { return self }

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        converted.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        return NSColor(
            calibratedHue: hue,
            saturation: saturation,
            brightness: min(1, max(0, brightness * multiplier)),
            alpha: alpha
        )
    }

    var rgbComponents: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)? {
        guard let converted = usingColorSpace(.deviceRGB) else { return nil }

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        converted.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (red, green, blue, alpha)
    }

    var hsbComponents: (hue: CGFloat, saturation: CGFloat, brightness: CGFloat, alpha: CGFloat)? {
        guard let converted = usingColorSpace(.deviceRGB) else { return nil }

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        converted.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return (hue, saturation, brightness, alpha)
    }

    func distance(to other: NSColor) -> CGFloat {
        guard
            let lhs = rgbComponents,
            let rhs = other.rgbComponents
        else {
            return 0
        }

        let red = lhs.red - rhs.red
        let green = lhs.green - rhs.green
        let blue = lhs.blue - rhs.blue
        return sqrt((red * red) + (green * green) + (blue * blue))
    }
}

private struct ArtworkPalette {
    let mainColor: NSColor
    let subColor: NSColor
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlayWindow: NotchPanel?
    private var settingsWindow: SettingsPanel?
    private let overlayModel = NotchOverlayModel()
    private let nowPlayingMonitor = AppleMusicNowPlayingMonitor()
    private let screenAudioMonitor = ScreenAudioVisualizerMonitor()
    private let volumeMonitor = SystemVolumeMonitor()
    private let batteryMonitor = SystemBatteryMonitor()
    private let weatherMonitor = WeatherMonitor()
    private var sizeObserver: NSObjectProtocol?
    private var outsideClickMonitor: Any?
    private var scrollWheelMonitor: Any?
    private var sharingPicker: NSSharingServicePicker?
    private var lastScrollPageSwitchAt: TimeInterval = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        overlayModel.mediaControlHandler = { [weak self] command in
            self?.nowPlayingMonitor.send(command)
        }
        overlayModel.settingsWindowHandler = { [weak self] in
            self?.showSettingsWindow()
        }
        overlayModel.weatherLocationUpdateHandler = { [weak self] query in
            self?.weatherMonitor.setManualLocation(query)
        }
        overlayModel.refreshWeatherHandler = { [weak self] in
            self?.weatherMonitor.refreshNow()
        }
        overlayModel.visualizerModeChangeHandler = { [weak self] mode in
            self?.screenAudioMonitor.setMode(mode, using: self?.overlayModel)
        }
        overlayModel.sharePinnedFileHandler = { [weak self] url in
            self?.showSharePicker(for: url)
        }
        createOverlayWindow()
        overlayModel.presentOnboardingIfNeeded()
        observeOverlaySize()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateOverlayPosition),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        observeOutsideClicks()
        observeScrollWheelPaging()
        nowPlayingMonitor.start(using: overlayModel)
        screenAudioMonitor.start(using: overlayModel)
        volumeMonitor.start(using: overlayModel)
        batteryMonitor.start(using: overlayModel)
        weatherMonitor.start(using: overlayModel)
    }

    @objc private func updateOverlayPosition() {
        guard
            let screen = NSScreen.main ?? NSScreen.screens.first,
            let overlayWindow
        else {
            return
        }

        let panelSize = overlayModel.panelSize
        let x = screen.frame.midX - (panelSize.width / 2)
        let y = screen.frame.maxY - panelSize.height + 10
        overlayWindow.setFrame(NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height), display: true)
    }

    private func createOverlayWindow() {
        let panelSize = overlayModel.panelSize
        let window = NotchPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.ignoresMouseEvents = false
        window.hidesOnDeactivate = false
        window.contentView = NSHostingView(rootView: ContentView(overlayModel: overlayModel))

        overlayWindow = window
        updateOverlayPosition()
        window.orderFrontRegardless()
    }

    private func showSettingsWindow() {
        let window: SettingsPanel
        if let settingsWindow {
            window = settingsWindow
            if let hostingView = settingsWindow.contentView as? NSHostingView<SettingsWindowView> {
                hostingView.rootView = SettingsWindowView(overlayModel: overlayModel)
            }
        } else {
            window = SettingsPanel(
                contentRect: NSRect(x: 0, y: 0, width: 368, height: 340),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Pull Notch Settings"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.backgroundColor = .clear
            window.isOpaque = false
            window.center()
            window.contentView = NSHostingView(rootView: SettingsWindowView(overlayModel: overlayModel))
            settingsWindow = window
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func showSharePicker(for url: URL) {
        guard let overlayWindow, let contentView = overlayWindow.contentView else { return }

        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
        sharingPicker = picker
    }

    private func observeOverlaySize() {
        sizeObserver = NotificationCenter.default.addObserver(
            forName: NotchOverlayModel.layoutDidChangeNotification,
            object: overlayModel,
            queue: .main
        ) { [weak self] _ in
            self?.updateOverlayPosition()
        }
    }

    private func observeOutsideClicks() {
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard
                let self,
                let expandedPanel = self.overlayModel.expandedPanel,
                expandedPanel != .onboarding,
                let overlayWindow
            else {
                return
            }

            let location = event.locationInWindow
            if !overlayWindow.frame.contains(location) {
                DispatchQueue.main.async {
                    self.overlayModel.dismissExpandedPanel()
                }
            }
        }
    }

    private func observeScrollWheelPaging() {
        scrollWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard
                let self,
                let overlayWindow
            else {
                return event
            }

            let location = NSEvent.mouseLocation
            guard overlayWindow.frame.contains(location) else { return event }

            let horizontalDelta = abs(event.scrollingDeltaX)
            let verticalDelta = abs(event.scrollingDeltaY)
            let dominantDelta = max(horizontalDelta, verticalDelta)
            let secondaryDelta = min(horizontalDelta, verticalDelta)
            guard dominantDelta >= 18 else { return event }
            guard secondaryDelta <= dominantDelta * 0.65 else { return event }

            let now = ProcessInfo.processInfo.systemUptime

            if self.overlayModel.expandedPanel == nil,
               !self.overlayModel.expandedWidgetPages.isEmpty {
                guard now - self.lastScrollPageSwitchAt >= 0.35 else { return nil }
                self.lastScrollPageSwitchAt = now
                self.overlayModel.toggleMusicPlayer()
                return nil
            }

            guard
                self.overlayModel.expandedPanel == .musicPlayer,
                self.overlayModel.expandedWidgetPages.count > 1
            else {
                return event
            }

            guard now - self.lastScrollPageSwitchAt >= 0.5 else { return nil }
            self.lastScrollPageSwitchAt = now

            if horizontalDelta >= verticalDelta {
                if event.scrollingDeltaX > 0 {
                    self.overlayModel.showPreviousExpandedWidgetPage()
                } else {
                    self.overlayModel.showNextExpandedWidgetPage()
                }
            } else {
                if event.scrollingDeltaY < 0 {
                    self.overlayModel.showNextExpandedWidgetPage()
                } else {
                    self.overlayModel.showPreviousExpandedWidgetPage()
                }
            }

            return nil
        }
    }
}

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class SettingsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

struct SettingsWindowView: View {
    private enum SettingsTab: String, CaseIterable, Identifiable {
        case general
        case widgets
        case weather

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general:
                return "General"
            case .widgets:
                return "Widgets"
            case .weather:
                return "Weather"
            }
        }
    }

    @Bindable var overlayModel: NotchOverlayModel
    @State private var selectedTab: SettingsTab = .general
    @State private var manualWeatherLocationDraft = ""

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color(red: 0.07, green: 0.07, blue: 0.09)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 20) {
                header
                HStack(alignment: .top, spacing: 18) {
                    tabPicker
                    tabContent
                }
            }
            .padding(24)
        }
        .frame(minWidth: 720, minHeight: 520)
        .onAppear {
            manualWeatherLocationDraft = overlayModel.manualWeatherLocation ?? ""
        }
        .onChange(of: overlayModel.manualWeatherLocation) { _, newValue in
            manualWeatherLocationDraft = newValue ?? ""
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Settings")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)

            Text("機能切り替えと widget の見え方を、カテゴリごとに整理できます。")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
        }
    }

    private var tabPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(SettingsTab.allCases) { tab in
                tabPickerButton(for: tab)
            }
        }
        .frame(width: 210, alignment: .topLeading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private func tabPickerButton(for tab: SettingsTab) -> some View {
        let isSelected = selectedTab == tab
        let subtitleColor: Color = isSelected ? .black.opacity(0.7) : .white.opacity(0.42)
        let foregroundColor: Color = isSelected ? .black : .white.opacity(0.82)
        let backgroundFill: Color = isSelected ? .white : .white.opacity(0.04)
        let borderOpacity: Double = isSelected ? 0 : 0.08

        return Button {
            withAnimation(.easeOut(duration: 0.16)) {
                selectedTab = tab
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: iconName(for: tab))
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.title)
                        .font(.system(size: 13, weight: .semibold))

                    Text(subtitle(for: tab))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(subtitleColor)
                }

                Spacer(minLength: 0)
            }
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(backgroundFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(borderOpacity), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var tabContent: some View {
        ScrollView {
            switch selectedTab {
            case .general:
                LazyVStack(spacing: 14) {
                    featureSection
                    pinnedFileSection
                }
                .padding(.vertical, 2)
            case .widgets:
                LazyVStack(spacing: 14) {
                    nowPlayingSection
                    compactWidgetPrioritySection
                }
                .padding(.vertical, 2)
            case .weather:
                LazyVStack(spacing: 14) {
                    weatherLocationSection
                }
                .padding(.vertical, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .scrollIndicators(.hidden)
    }

    private var featureSection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(
                    title: "Features",
                    subtitle: "widget 表示と基本挙動のオンオフをまとめて切り替えます。"
                )

                VStack(spacing: 10) {
                    ForEach(OverlayFeature.allCases) { feature in
                        settingsToggleButton(
                            title: feature.title,
                            subtitle: feature.subtitle,
                            isOn: overlayModel.isFeatureEnabled(feature)
                        ) {
                            overlayModel.setFeatureEnabled(feature, isEnabled: !overlayModel.isFeatureEnabled(feature))
                        }
                    }
                }

                settingsToggleButton(
                    title: "Launch At Login",
                    subtitle: overlayModel.launchAtLoginStatusText,
                    isOn: overlayModel.launchAtLoginEnabled
                ) {
                    overlayModel.setLaunchAtLoginEnabled(!overlayModel.launchAtLoginEnabled)
                }
            }
        }
    }

    private var weatherLocationSection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(
                    title: "Weather Location",
                    subtitle: "現在地が使えない場合は都市名や住所を手動で指定できます。"
                )

                TextField("Tokyo, Japan", text: $manualWeatherLocationDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            )
                    )

                HStack(spacing: 8) {
                    buttonChip("保存", emphasized: true) {
                        overlayModel.setManualWeatherLocation(manualWeatherLocationDraft)
                    }

                    buttonChip("現在地を使う", emphasized: false) {
                        overlayModel.setManualWeatherLocation(nil)
                    }
                }

                if let statusMessage = overlayModel.weatherLocationStatusMessage {
                    Text(statusMessage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(overlayModel.weatherLocationStatusColor)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
        }
    }

    private var nowPlayingSection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(
                    title: "Now Playing",
                    subtitle: "常時表示で出す要素を細かく切り替えます。"
                )

                settingsToggleButton(
                    title: "アートワークを表示",
                    subtitle: "左側にジャケット画像を表示",
                    isOn: overlayModel.nowPlayingShowsArtwork
                ) {
                    overlayModel.setNowPlayingArtworkVisible(!overlayModel.nowPlayingShowsArtwork)
                }

                settingsToggleButton(
                    title: "ビジュアライザーを表示",
                    subtitle: "右側にバー表示を出す",
                    isOn: overlayModel.nowPlayingShowsVisualizer
                ) {
                    overlayModel.setNowPlayingVisualizerVisible(!overlayModel.nowPlayingShowsVisualizer)
                }

                settingsToggleButton(
                    title: "ビジュアライザーを動かす",
                    subtitle: "再生中にランダムアニメーションさせる",
                    isOn: overlayModel.nowPlayingAnimatesVisualizer
                ) {
                    overlayModel.setNowPlayingVisualizerAnimated(!overlayModel.nowPlayingAnimatesVisualizer)
                }
                .opacity(overlayModel.nowPlayingShowsVisualizer ? 1 : 0.45)

                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader(
                        title: "Visualizer Source",
                        subtitle: "フェイク表示か、画面音声を使う本物の表示かを切り替えます。"
                    )

                    HStack(spacing: 8) {
                        visualizerModeButton(.fake, title: "Fake")
                        visualizerModeButton(.real, title: "Real")
                    }

                    Text(overlayModel.realVisualizerStatusText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.48))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .opacity(overlayModel.nowPlayingShowsVisualizer && overlayModel.nowPlayingAnimatesVisualizer ? 1 : 0.45)
            }
        }
    }

    private func visualizerModeButton(_ mode: NowPlayingVisualizerMode, title: String) -> some View {
        Button {
            overlayModel.setNowPlayingVisualizerMode(mode)
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(overlayModel.nowPlayingVisualizerMode == mode ? .black : .white.opacity(0.84))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(overlayModel.nowPlayingVisualizerMode == mode ? Color.white : Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(overlayModel.nowPlayingVisualizerMode == mode ? 0 : 0.08), lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
    }

    private var pinnedFileSection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(
                    title: "Pinned File",
                    subtitle: "ノッチにファイルをドラッグすると、ここからすぐ扱えます。"
                )

                Text(overlayModel.pinnedFileURL?.lastPathComponent ?? "まだピン留めされたファイルはありません。")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if overlayModel.pinnedFileURL != nil {
                    buttonChip("ピン留めを解除", emphasized: false) {
                        overlayModel.clearPinnedFile()
                    }
                }
            }
        }
    }

    private var compactWidgetPrioritySection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader(
                    title: "Compact Widget Priority",
                    subtitle: "左右スロットごとに、優先順位が高い widget から表示されます。"
                )

                compactPriorityGroup(title: "Left Slot", placement: .leading)
                compactPriorityGroup(title: "Right Slot", placement: .trailing)
            }
        }
    }

    private func compactPriorityGroup(title: String, placement: CompactWidgetPlacement) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))

            ForEach(overlayModel.widgetKinds(for: placement)) { kind in
                HStack(spacing: 12) {
                    Text(kind.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)

                    Spacer(minLength: 0)

                    priorityButton("chevron.up") {
                        overlayModel.moveCompactWidget(kind, direction: .up)
                    }
                    .disabled(!overlayModel.canMoveCompactWidget(kind, direction: .up))

                    priorityButton("chevron.down") {
                        overlayModel.moveCompactWidget(kind, direction: .down)
                    }
                    .disabled(!overlayModel.canMoveCompactWidget(kind, direction: .down))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(0.06), lineWidth: 1)
                        )
                )
            }
        }
    }

    private func priorityButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.82))
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
    }

    private func settingsToggleButton(
        title: String,
        subtitle: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)

                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.gray)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Capsule()
                    .fill(isOn ? Color.white : Color.white.opacity(0.14))
                    .frame(width: 40, height: 24)
                    .overlay(alignment: isOn ? .trailing : .leading) {
                        Circle()
                            .fill(isOn ? Color.black : Color.white.opacity(0.82))
                            .frame(width: 16, height: 16)
                            .padding(4)
                    }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.06), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func iconName(for tab: SettingsTab) -> String {
        switch tab {
        case .general:
            return "slider.horizontal.3"
        case .widgets:
            return "square.grid.2x2.fill"
        case .weather:
            return "cloud.sun.fill"
        }
    }

    private func subtitle(for tab: SettingsTab) -> String {
        switch tab {
        case .general:
            return "基本設定"
        case .widgets:
            return "表示と優先順位"
        case .weather:
            return "地点と更新"
        }
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.08), Color.white.opacity(0.035)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
    }

    private func sectionHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)

            Text(subtitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.48))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func buttonChip(_ title: String, emphasized: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .foregroundStyle(emphasized ? .black : .white.opacity(0.82))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(emphasized ? Color.white : Color.white.opacity(0.08))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(emphasized ? 0 : 0.08), lineWidth: 1)
                    )
            )
    }
}

@Observable
final class NotchOverlayModel {
    static let layoutDidChangeNotification = Notification.Name("NotchOverlayModel.layoutDidChange")
    private static let hasShownOnboardingKey = "PullNotch.hasShownOnboarding"
    private static let featureKeyPrefix = "PullNotch.feature."
    private static let manualWeatherLocationKey = "PullNotch.weather.manualLocation"
    private static let nowPlayingArtworkVisibleKey = "PullNotch.nowPlaying.artworkVisible"
    private static let nowPlayingVisualizerVisibleKey = "PullNotch.nowPlaying.visualizerVisible"
    private static let nowPlayingVisualizerAnimatedKey = "PullNotch.nowPlaying.visualizerAnimated"
    private static let nowPlayingVisualizerModeKey = "PullNotch.nowPlaying.visualizerMode"
    private static let compactWidgetPriorityPrefix = "PullNotch.compactWidgetPriority."
    private static let pinnedFileBookmarkKey = "PullNotch.pinnedFileBookmark"

    let compactWidth: CGFloat = 290
    let compactEmptyWidth: CGFloat = 244
    let notchHeight: CGFloat = 52
    let expandedHeight: CGFloat = 88
    let volumeExpandedHeight: CGFloat = 112
    let playerExpandedHeight: CGFloat = 286
    let widgetExpandedHeight: CGFloat = 252
    let onboardingExpandedHeight: CGFloat = 176
    let windowHorizontalInset: CGFloat = 20
    let windowTopInset: CGFloat = 2
    let windowBottomInset: CGFloat = 14

    private var collapseTask: Task<Void, Never>?
    private var volumeHideTask: Task<Void, Never>?
    private var volumeOverlayVisibleUntil: Date?
    private var pomodoroTimerTask: Task<Void, Never>?
    private var temporaryWidgetTasks: [CompactWidgetPlacement: Task<Void, Never>] = [:]
    private var lyricsTask: Task<Void, Never>?
    private let lyricsService = LyricsService()

    private(set) var currentPresentation: IslandPresentation?
    private(set) var detailLine: String?
    private(set) var isPlaying = false
    private(set) var nowPlayingDurationSeconds: TimeInterval?
    private(set) var nowPlayingPlaybackPositionSeconds: TimeInterval = 0
    private(set) var nowPlayingPlaybackPositionUpdatedAt: Date?
    private(set) var showsTrackChange = false
    private(set) var showsTrackText = false
    private(set) var showsHoverChange = false
    private(set) var showsHoverText = false
    private(set) var showsVolumeChange = false
    private(set) var volumeLevel: Double = 0
    private(set) var volumeOutputDeviceName: String?
    private(set) var sourceApp: String?
    private(set) var artworkData: Data?
    private(set) var visualizerBrightColor: Color = .white.opacity(0.92)
    private(set) var visualizerDarkColor: Color = .white.opacity(0.6)
    private(set) var syncedLyrics: [SyncedLyricLine] = []
    private(set) var plainLyricsText: String?
    private(set) var lyricsLoadState: LyricsLoadState = .idle
    private(set) var lyricsProvider: LyricsProvider?
    private(set) var currentLyricsRequestKey: String?
    private(set) var compactWidgets: [CompactIslandWidget] = []
    private(set) var temporaryCompactWidgets: [CompactWidgetPlacement: CompactIslandWidget] = [:]
    private(set) var batteryLevel: Int?
    private(set) var batteryIsCharging = false
    private(set) var chargingPowerWatts: Double?
    private(set) var weatherTemperatureText: String?
    private(set) var weatherSymbolName: String?
    private(set) var manualWeatherLocation: String?
    private(set) var weatherLocationStatusMessage: String?
    private(set) var weatherLocationStatusColor: Color = .white.opacity(0.55)
    private(set) var pinnedFileURL: URL?
    private(set) var pomodoroPhase: PomodoroPhase = .focus
    private(set) var pomodoroRemainingSeconds = PomodoroPhase.focus.duration
    private(set) var pomodoroIsRunning = false
    private(set) var nowPlayingShowsArtwork = true
    private(set) var nowPlayingShowsVisualizer = true
    private(set) var nowPlayingAnimatesVisualizer = true
    private(set) var nowPlayingVisualizerMode: NowPlayingVisualizerMode = .fake
    private(set) var liveVisualizerHeights: [CGFloat] = Array(repeating: 5, count: 6)
    private(set) var realVisualizerIsAvailable = false
    private(set) var launchAtLoginEnabled = false
    private(set) var launchAtLoginStatusText = "ログイン時には起動しません。"
    private(set) var compactWidgetPriorities: [CompactWidgetKind: Int] = [:]
    private(set) var currentExpandedPageKind: ExpandedWidgetPageKind?
    private(set) var expandedPageNavigationDirection: ExpandedPageNavigationDirection = .forward
    private(set) var expandedPanel: ExpandedIslandPanel?
    private(set) var featureStates: [OverlayFeature: Bool] = [:]
    var mediaControlHandler: ((MediaControlCommand) -> Void)?
    var settingsWindowHandler: (() -> Void)?
    var weatherLocationUpdateHandler: ((String?) -> Void)?
    var sharePinnedFileHandler: ((URL) -> Void)?
    var refreshWeatherHandler: (() -> Void)?
    var visualizerModeChangeHandler: ((NowPlayingVisualizerMode) -> Void)?

    init() {
        featureStates = Dictionary(
            uniqueKeysWithValues: OverlayFeature.allCases.map { feature in
                let key = Self.featureKeyPrefix + feature.rawValue
                let storedValue = UserDefaults.standard.object(forKey: key) as? Bool
                return (feature, storedValue ?? true)
            }
        )
        manualWeatherLocation = UserDefaults.standard.string(forKey: Self.manualWeatherLocationKey)
        nowPlayingShowsArtwork = UserDefaults.standard.object(forKey: Self.nowPlayingArtworkVisibleKey) as? Bool ?? true
        nowPlayingShowsVisualizer = UserDefaults.standard.object(forKey: Self.nowPlayingVisualizerVisibleKey) as? Bool ?? true
        nowPlayingAnimatesVisualizer = UserDefaults.standard.object(forKey: Self.nowPlayingVisualizerAnimatedKey) as? Bool ?? true
        if let storedMode = UserDefaults.standard.string(forKey: Self.nowPlayingVisualizerModeKey),
           let visualizerMode = NowPlayingVisualizerMode(rawValue: storedMode) {
            nowPlayingVisualizerMode = visualizerMode
        }
        compactWidgetPriorities = Dictionary(
            uniqueKeysWithValues: CompactWidgetKind.allCases.enumerated().map { index, kind in
                let storedPriority = UserDefaults.standard.object(forKey: Self.compactWidgetPriorityPrefix + kind.rawValue) as? Int
                return (kind, storedPriority ?? index)
            }
        )
        pinnedFileURL = Self.restorePinnedFileURL()
        pomodoroRemainingSeconds = pomodoroPhase.duration
        refreshLaunchAtLoginStatus()
    }

    var compactVisibleWidth: CGFloat {
        let calculatedWidth = leadingWidgetWidth + trailingWidgetWidth + compactCenterSpacing + 36
        return max(compactEmptyWidth, calculatedWidth)
    }

    var visibleWidth: CGFloat {
        if expandedPanel == .musicPlayer {
            return max(compactVisibleWidth, expandedPagePreferredWidth)
        }
        return compactVisibleWidth
    }

    var compactCenterSpacing: CGFloat {
        switch (leadingWidget?.style, trailingWidget?.style) {
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

    var leadingWidget: CompactIslandWidget? {
        compactWidgets.first(where: { $0.placement == .leading })
    }

    var trailingWidget: CompactIslandWidget? {
        compactWidgets.first(where: { $0.placement == .trailing })
    }

    var leadingWidgetWidth: CGFloat {
        leadingWidget?.preferredWidth ?? 24
    }

    var trailingWidgetWidth: CGFloat {
        trailingWidget?.preferredWidth ?? 24
    }

    var currentIslandHeight: CGFloat {
        if expandedPanel == .onboarding {
            return onboardingExpandedHeight
        }
        if expandedPanel == .musicPlayer {
            return activeExpandedWidgetPage == .nowPlaying ? playerExpandedHeight : widgetExpandedHeight
        }
        if showsBatteryLowWarning {
            return expandedHeight
        }
        if showsVolumeChange {
            return volumeExpandedHeight
        }
        if showsHoverChange {
            return expandedHeight
        }
        return showsTrackChange ? expandedHeight : notchHeight
    }

    var panelSize: CGSize {
        CGSize(
            width: visibleWidth + (windowHorizontalInset * 2),
            height: currentIslandHeight + windowTopInset + windowBottomInset
        )
    }

    var expandedWidgetPages: [ExpandedWidgetPageKind] {
        var pages: [ExpandedWidgetPageKind] = []

        if currentPresentation != nil {
            pages.append(.nowPlaying)
        }

        if pinnedFileURL != nil, isFeatureEnabled(.pinnedFile) {
            pages.append(.pinnedFile)
        }

        if weatherTemperatureText != nil, isFeatureEnabled(.weather) {
            pages.append(.weather)
        }

        if isFeatureEnabled(.pomodoro) {
            pages.append(.pomodoro)
        }

        return pages
    }

    var activeExpandedWidgetPage: ExpandedWidgetPageKind? {
        let pages = expandedWidgetPages
        guard !pages.isEmpty else { return nil }
        if let currentExpandedPageKind, pages.contains(currentExpandedPageKind) {
            return currentExpandedPageKind
        }
        return pages.first
    }

    var expandedPagePreferredWidth: CGFloat {
        switch activeExpandedWidgetPage {
        case .nowPlaying:
            let titleWidth = textWidth(
                detailLine?.components(separatedBy: " - ").first ?? "Not Playing",
                font: .systemFont(ofSize: 14, weight: .semibold)
            )
            let subtitleWidth = textWidth(
                detailLine?.components(separatedBy: " - ").dropFirst().joined(separator: " - ") ?? "No artist",
                font: .systemFont(ofSize: 12, weight: .medium)
            )
            let sourceWidth = textWidth(
                sourceApp ?? "Music",
                font: .systemFont(ofSize: 11, weight: .medium)
            )
            let textColumnWidth = max(titleWidth, subtitleWidth, sourceWidth, 180)
            return min(560, max(420, 64 + 14 + textColumnWidth + 48))
        case .pinnedFile:
            let fileNameWidth = textWidth(
                pinnedFileURL?.lastPathComponent ?? "No File",
                font: .systemFont(ofSize: 14, weight: .semibold)
            )
            let pathWidth = textWidth(
                pinnedFileURL?.deletingLastPathComponent().path ?? "ファイルがありません",
                font: .systemFont(ofSize: 11, weight: .medium)
            )
            let buttonsWidth: CGFloat = 92 + 96 + 88
            let contentWidth = max(fileNameWidth, pathWidth, buttonsWidth)
            return min(720, max(520, 64 + 14 + contentWidth + 48))
        case .weather:
            let temperatureWidth = textWidth(
                weatherTemperatureText ?? "--°",
                font: .systemFont(ofSize: 28, weight: .bold)
            )
            let locationWidth = textWidth(
                manualWeatherLocation ?? "Current Location",
                font: .systemFont(ofSize: 12, weight: .medium)
            )
            return min(520, max(420, temperatureWidth + locationWidth + 180))
        case .pomodoro:
            let timerWidth = textWidth(
                pomodoroTimeText,
                font: .systemFont(ofSize: 28, weight: .bold)
            )
            let phaseWidth = textWidth(
                pomodoroPhase.title,
                font: .systemFont(ofSize: 12, weight: .medium)
            )
            return min(520, max(420, timerWidth + phaseWidth + 200))
        case nil:
            return compactVisibleWidth
        }
    }

    func estimatedPlaybackPosition(at date: Date = .now) -> TimeInterval {
        let basePosition = max(0, nowPlayingPlaybackPositionSeconds)
        guard
            isPlaying,
            let updatedAt = nowPlayingPlaybackPositionUpdatedAt
        else {
            return clampedPlaybackPosition(basePosition)
        }

        let advancedPosition = basePosition + max(0, date.timeIntervalSince(updatedAt))
        return clampedPlaybackPosition(advancedPosition)
    }

    func activeLyricLineIndex(at date: Date = .now) -> Int? {
        guard !syncedLyrics.isEmpty else { return nil }

        let playbackPosition = estimatedPlaybackPosition(at: date)
        var currentIndex: Int?

        for (index, line) in syncedLyrics.enumerated() where line.timestamp <= playbackPosition + 0.12 {
            currentIndex = index
        }

        return currentIndex
    }

    func visibleLyricsLines(at date: Date = .now) -> [(line: SyncedLyricLine, isActive: Bool, isContext: Bool)] {
        guard !syncedLyrics.isEmpty else { return [] }

        guard let activeIndex = activeLyricLineIndex(at: date) else {
            return Array(syncedLyrics.prefix(2)).map { ($0, false, true) }
        }

        let lowerBound = activeIndex
        let upperBound = min(syncedLyrics.count - 1, activeIndex + 1)

        return Array(syncedLyrics[lowerBound...upperBound].enumerated()).map { offset, line in
            let index = lowerBound + offset
            return (line, index == activeIndex, index != activeIndex)
        }
    }

    var lyricsStatusText: String {
        switch lyricsLoadState {
        case .idle:
            return "Lyrics"
        case .loading:
            return "Loading lyrics..."
        case .unavailable:
            return "Lyrics unavailable"
        case .ready:
            let providerName = lyricsProvider?.rawValue ?? "Lyrics"
            return syncedLyrics.isEmpty ? "Plain lyrics via \(providerName)" : "Synced via \(providerName)"
        }
    }

    var lyricsFallbackPreviewText: String? {
        guard
            syncedLyrics.isEmpty,
            let plainLyricsText
        else {
            return nil
        }

        return plainLyricsText
            .split(whereSeparator: \.isNewline)
            .prefix(2)
            .map(String.init)
            .joined(separator: "\n")
            .nilIfEmpty
    }

    func updateNowPlaying(track: AppleMusicTrack) {
        guard isFeatureEnabled(.nowPlaying) else { return }

        let lyricsRequestKey = normalizedLyricsRequestKey(for: track)
        let shouldReloadLyrics = lyricsRequestKey != currentLyricsRequestKey
        nowPlayingDurationSeconds = track.durationSeconds
        nowPlayingPlaybackPositionSeconds = max(0, track.playbackPositionSeconds ?? 0)
        nowPlayingPlaybackPositionUpdatedAt = .now

        let presentation = IslandPresentation(
            id: [track.title, track.artist, track.album].joined(separator: "||"),
            detailLine: [track.title, track.artist].filter { !$0.isEmpty }.joined(separator: " - "),
            sourceApp: track.bundleIdentifier,
            artworkData: track.artworkData,
            isPlaying: track.isPlaying
        )

        let shouldReveal = currentPresentation?.id != presentation.id
        refreshCompactWidgets()
        present(
            presentation,
            revealChange: shouldReveal,
            hapticFeedback: shouldReveal ? .generic : nil
        )

        if shouldReloadLyrics {
            loadLyrics(for: track, requestKey: lyricsRequestKey)
        }
    }

    func present(
        _ presentation: IslandPresentation,
        revealChange: Bool = true,
        hapticFeedback: IslandHapticFeedback? = nil
    ) {
        currentPresentation = presentation
        detailLine = presentation.detailLine
        sourceApp = presentation.sourceApp
        artworkData = presentation.artworkData
        updateVisualizerPalette(from: presentation.artworkData)
        isPlaying = presentation.isPlaying

        if revealChange {
            if let hapticFeedback {
                perform(hapticFeedback)
            }
            showTrackChangeTemporarily()
        } else {
            notifyLayoutChange()
        }
    }

    func showTrackChangeTemporarily() {
        collapseTask?.cancel()
        guard expandedPanel == nil else {
            notifyLayoutChange()
            return
        }
        guard !showsVolumeChange else {
            notifyLayoutChange()
            return
        }
        showsHoverChange = false
        showsHoverText = false
        showsTrackChange = true
        showsTrackText = true
        notifyLayoutChange()

        collapseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.showsTrackText = false
            self?.notifyLayoutChange()
            try? await Task.sleep(for: .seconds(0.28))
            guard !Task.isCancelled else { return }
            self?.showsTrackChange = false
            self?.notifyLayoutChange()
        }
    }

    func clearNowPlaying() {
        collapseTask?.cancel()
        lyricsTask?.cancel()
        currentPresentation = nil
        detailLine = nil
        sourceApp = nil
        artworkData = nil
        resetVisualizerPalette()
        nowPlayingDurationSeconds = nil
        nowPlayingPlaybackPositionSeconds = 0
        nowPlayingPlaybackPositionUpdatedAt = nil
        syncedLyrics = []
        plainLyricsText = nil
        lyricsLoadState = .idle
        lyricsProvider = nil
        currentLyricsRequestKey = nil
        showsHoverChange = false
        showsHoverText = false
        isPlaying = false
        showsTrackChange = false
        showsTrackText = false
        ensureExpandedWidgetPage()
        refreshCompactWidgets()
        notifyLayoutChange()
    }

    func toggleMusicPlayer() {
        guard expandedPanel != .onboarding else { return }

        collapseTask?.cancel()

        if expandedPanel == .musicPlayer {
            expandedPanel = nil
        } else {
            expandedPanel = .musicPlayer
            ensureExpandedWidgetPage()
            dismissVolumeOverlay()
            showsTrackChange = false
            showsTrackText = false
            perform(.generic)
        }

        notifyLayoutChange()
    }

    func dismissExpandedPanel() {
        guard expandedPanel != nil, expandedPanel != .onboarding else { return }
        expandedPanel = nil
        showsHoverChange = false
        showsHoverText = false
        notifyLayoutChange()
    }

    func openSettingsWindow() {
        guard expandedPanel != .onboarding else { return }
        collapseTask?.cancel()
        expandedPanel = nil
        dismissVolumeOverlay()
        showsTrackChange = false
        showsTrackText = false
        showsHoverChange = false
        showsHoverText = false
        perform(.generic)
        settingsWindowHandler?()
        notifyLayoutChange()
    }

    func presentOnboardingIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.hasShownOnboardingKey) else { return }
        expandedPanel = .onboarding
        notifyLayoutChange()
    }

    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.hasShownOnboardingKey)
        if expandedPanel == .onboarding {
            expandedPanel = nil
            notifyLayoutChange()
        }
    }

    func setHoverTitleVisible(_ isVisible: Bool) {
        guard isFeatureEnabled(.hoverTitle) else { return }
        guard expandedPanel == nil, !showsTrackChange, !showsVolumeChange, currentPresentation != nil else { return }
        guard showsHoverChange != isVisible || showsHoverText != isVisible else { return }
        showsHoverChange = isVisible
        showsHoverText = isVisible
        notifyLayoutChange()
    }

    func showVolume(level: Double, outputDeviceName: String?) {
        guard isFeatureEnabled(.volumeOverlay) else { return }
        guard expandedPanel == nil else { return }

        showsTrackChange = false
        showsTrackText = false
        showsHoverChange = false
        showsHoverText = false
        showsVolumeChange = true
        volumeLevel = max(0, min(1, level))
        volumeOutputDeviceName = outputDeviceName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        print("VolumeOverlay: show level=\(String(format: "%.3f", volumeLevel)) device=\(volumeOutputDeviceName ?? "unknown")")
        notifyLayoutChange()

        extendVolumeOverlayVisibility(by: 2.6)
    }

    func send(_ command: MediaControlCommand) {
        mediaControlHandler?(command)
        perform(.generic)
    }

    func updateBattery(
        level: Int?,
        isCharging: Bool,
        chargingWatts: Double?,
        previousStatus: (level: Int, isCharging: Bool, chargingWatts: Double?)?
    ) {
        batteryLevel = level
        batteryIsCharging = isCharging
        chargingPowerWatts = chargingWatts

        if isCharging,
           let chargingWatts,
           shouldShowChargingPowerIndicator(previousStatus: previousStatus, chargingWatts: chargingWatts) {
            showChargingPowerIndicator()
        } else if !isCharging {
            clearTemporaryCompactWidget(for: .trailing, kind: .chargingPower)
        }

        refreshCompactWidgets()
        notifyLayoutChange()
    }

    func updateWeather(temperatureText: String?, symbolName: String?) {
        weatherTemperatureText = temperatureText
        weatherSymbolName = symbolName
        ensureExpandedWidgetPage()
        refreshCompactWidgets()
        notifyLayoutChange()
    }

    func setManualWeatherLocation(_ location: String?) {
        let trimmedLocation = location?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        manualWeatherLocation = trimmedLocation
        if let trimmedLocation {
            weatherLocationStatusMessage = "'\(trimmedLocation)' の天気を取得中..."
            weatherLocationStatusColor = .white.opacity(0.58)
        } else {
            weatherLocationStatusMessage = nil
        }

        if let trimmedLocation {
            UserDefaults.standard.set(trimmedLocation, forKey: Self.manualWeatherLocationKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.manualWeatherLocationKey)
        }

        weatherLocationUpdateHandler?(trimmedLocation)
        notifyLayoutChange()
    }

    func updateWeatherLocationStatus(message: String?, isError: Bool) {
        weatherLocationStatusMessage = message
        weatherLocationStatusColor = isError ? Color.red.opacity(0.9) : Color.green.opacity(0.9)
        notifyLayoutChange()
    }

    func setNowPlayingArtworkVisible(_ isVisible: Bool) {
        nowPlayingShowsArtwork = isVisible
        UserDefaults.standard.set(isVisible, forKey: Self.nowPlayingArtworkVisibleKey)
        refreshCompactWidgets()
        notifyLayoutChange()
    }

    func setNowPlayingVisualizerVisible(_ isVisible: Bool) {
        nowPlayingShowsVisualizer = isVisible
        UserDefaults.standard.set(isVisible, forKey: Self.nowPlayingVisualizerVisibleKey)
        refreshCompactWidgets()
        notifyLayoutChange()
    }

    func setNowPlayingVisualizerAnimated(_ isAnimated: Bool) {
        nowPlayingAnimatesVisualizer = isAnimated
        UserDefaults.standard.set(isAnimated, forKey: Self.nowPlayingVisualizerAnimatedKey)
        refreshCompactWidgets()
        notifyLayoutChange()
    }

    func setNowPlayingVisualizerMode(_ mode: NowPlayingVisualizerMode) {
        guard nowPlayingVisualizerMode != mode else { return }
        nowPlayingVisualizerMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.nowPlayingVisualizerModeKey)
        if mode == .fake {
            updateLiveVisualizerLevels(Array(repeating: 5, count: 6), isAvailable: false)
        }
        visualizerModeChangeHandler?(mode)
    }

    func updateLiveVisualizerLevels(_ levels: [CGFloat], isAvailable: Bool) {
        realVisualizerIsAvailable = isAvailable

        if isAvailable, levels.count == liveVisualizerHeights.count {
            liveVisualizerHeights = zip(liveVisualizerHeights, levels).map { current, next in
                if next > current {
                    return (current * 0.22) + (next * 0.78)
                } else {
                    return (current * 0.68) + (next * 0.32)
                }
            }
        } else {
            liveVisualizerHeights = Array(repeating: 5, count: 6)
        }
    }

    func setLaunchAtLoginEnabled(_ isEnabled: Bool) {
        guard #available(macOS 13.0, *) else {
            launchAtLoginEnabled = false
            launchAtLoginStatusText = "この macOS では自動起動設定を変更できません。"
            notifyLayoutChange()
            return
        }

        do {
            if isEnabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLoginStatusText = error.localizedDescription
        }

        refreshLaunchAtLoginStatus()
        notifyLayoutChange()
    }

    func pinFile(_ url: URL) {
        pinnedFileURL = url
        if let bookmarkData = try? url.bookmarkData() {
            UserDefaults.standard.set(bookmarkData, forKey: Self.pinnedFileBookmarkKey)
        }
        ensureExpandedWidgetPage()
        refreshCompactWidgets()
        perform(.generic)
        notifyLayoutChange()
    }

    func clearPinnedFile() {
        pinnedFileURL = nil
        UserDefaults.standard.removeObject(forKey: Self.pinnedFileBookmarkKey)
        ensureExpandedWidgetPage()
        refreshCompactWidgets()
        notifyLayoutChange()
    }

    func sharePinnedFile() {
        guard let pinnedFileURL else { return }
        sharePinnedFileHandler?(pinnedFileURL)
    }

    func refreshWeather() {
        refreshWeatherHandler?()
    }

    func togglePomodoroRunning() {
        pomodoroIsRunning.toggle()
        if pomodoroIsRunning {
            startPomodoroTimer()
            updateTemporaryPomodoroWidget()
        } else {
            stopPomodoroTimer()
        }
        perform(.generic)
        refreshCompactWidgets()
        notifyLayoutChange()
    }

    func resetPomodoro() {
        stopPomodoroTimer()
        pomodoroPhase = .focus
        pomodoroRemainingSeconds = pomodoroPhase.duration
        updateTemporaryPomodoroWidget()
        refreshCompactWidgets()
        notifyLayoutChange()
    }

    func skipPomodoroPhase() {
        stopPomodoroTimer()
        pomodoroPhase = pomodoroPhase.next
        pomodoroRemainingSeconds = pomodoroPhase.duration
        updateTemporaryPomodoroWidget()
        refreshCompactWidgets()
        perform(.generic)
        notifyLayoutChange()
    }

    func selectExpandedWidgetPage(_ page: ExpandedWidgetPageKind) {
        let pages = expandedWidgetPages
        guard pages.contains(page) else { return }

        if
            let currentPage = activeExpandedWidgetPage,
            let currentIndex = pages.firstIndex(of: currentPage),
            let targetIndex = pages.firstIndex(of: page),
            currentIndex != targetIndex
        {
            expandedPageNavigationDirection = targetIndex > currentIndex ? .forward : .backward
        }

        currentExpandedPageKind = page
        notifyLayoutChange()
    }

    func showPreviousExpandedWidgetPage() {
        let pages = expandedWidgetPages
        guard
            let currentPage = activeExpandedWidgetPage,
            let index = pages.firstIndex(of: currentPage),
            index > 0
        else {
            return
        }

        expandedPageNavigationDirection = .backward
        currentExpandedPageKind = pages[index - 1]
        notifyLayoutChange()
    }

    func showNextExpandedWidgetPage() {
        let pages = expandedWidgetPages
        guard
            let currentPage = activeExpandedWidgetPage,
            let index = pages.firstIndex(of: currentPage),
            index < pages.count - 1
        else {
            return
        }

        expandedPageNavigationDirection = .forward
        currentExpandedPageKind = pages[index + 1]
        notifyLayoutChange()
    }

    func widgetKinds(for placement: CompactWidgetPlacement) -> [CompactWidgetKind] {
        CompactWidgetKind.allCases
            .filter { $0.placement == placement }
            .sorted { widgetPriority(for: $0) < widgetPriority(for: $1) }
    }

    func canMoveCompactWidget(_ kind: CompactWidgetKind, direction: MoveDirection) -> Bool {
        let kinds = widgetKinds(for: kind.placement)
        guard let index = kinds.firstIndex(of: kind) else { return false }

        switch direction {
        case .up:
            return index > 0
        case .down:
            return index < kinds.count - 1
        }
    }

    func moveCompactWidget(_ kind: CompactWidgetKind, direction: MoveDirection) {
        var kinds = widgetKinds(for: kind.placement)
        guard let index = kinds.firstIndex(of: kind) else { return }

        let targetIndex: Int
        switch direction {
        case .up:
            guard index > 0 else { return }
            targetIndex = index - 1
        case .down:
            guard index < kinds.count - 1 else { return }
            targetIndex = index + 1
        }

        kinds.swapAt(index, targetIndex)

        for (priority, currentKind) in kinds.enumerated() {
            compactWidgetPriorities[currentKind] = priority
            UserDefaults.standard.set(priority, forKey: Self.compactWidgetPriorityPrefix + currentKind.rawValue)
        }

        refreshCompactWidgets()
        notifyLayoutChange()
    }

    func isFeatureEnabled(_ feature: OverlayFeature) -> Bool {
        featureStates[feature] ?? true
    }

    func setFeatureEnabled(_ feature: OverlayFeature, isEnabled: Bool) {
        featureStates[feature] = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: Self.featureKeyPrefix + feature.rawValue)

        switch feature {
        case .pinnedFile:
            refreshCompactWidgets()
        case .nowPlaying:
            if !isEnabled {
                clearNowPlaying()
                if expandedPanel == .musicPlayer {
                    expandedPanel = nil
                }
            } else {
                refreshCompactWidgets()
            }
        case .battery:
            refreshCompactWidgets()
        case .weather:
            refreshCompactWidgets()
        case .pomodoro:
            if !isEnabled, activeExpandedWidgetPage == .pomodoro, expandedPanel == .musicPlayer {
                ensureExpandedWidgetPage()
            }
            refreshCompactWidgets()
        case .volumeOverlay:
            if !isEnabled {
                dismissVolumeOverlay()
            }
        case .hoverTitle:
            if !isEnabled {
                showsHoverChange = false
                showsHoverText = false
            }
        }

        notifyLayoutChange()
    }

    private func notifyLayoutChange() {
        NotificationCenter.default.post(name: Self.layoutDidChangeNotification, object: self)
    }

    private func refreshLaunchAtLoginStatus() {
        guard #available(macOS 13.0, *) else {
            launchAtLoginEnabled = false
            launchAtLoginStatusText = "この macOS では自動起動設定を変更できません。"
            return
        }

        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLoginEnabled = true
            launchAtLoginStatusText = "ログイン時に Pull Notch を自動で起動します。"
        case .requiresApproval:
            launchAtLoginEnabled = false
            launchAtLoginStatusText = "システム設定のログイン項目で許可が必要です。"
        case .notRegistered:
            launchAtLoginEnabled = false
            launchAtLoginStatusText = "ログイン時には起動しません。"
        case .notFound:
            launchAtLoginEnabled = false
            launchAtLoginStatusText = "配布ビルドで利用できる自動起動サービスが見つかりません。"
        @unknown default:
            launchAtLoginEnabled = false
            launchAtLoginStatusText = "自動起動の状態を判定できませんでした。"
        }
    }

    private func refreshCompactWidgets() {
        let availableWidgets = [
            pinnedFileWidget,
            nowPlayingArtworkWidget,
            batteryWidget,
            nowPlayingVisualizerWidget,
            weatherWidget,
            pomodoroWidget,
            chargingPowerWidget
        ].compactMap { $0 }

        let leading = temporaryCompactWidgets[.leading]
            ?? availableWidgets
                .filter { $0.placement == .leading }
                .min { widgetPriority(for: $0.kind) < widgetPriority(for: $1.kind) }
        let trailing = temporaryCompactWidgets[.trailing]
            ?? availableWidgets
                .filter { $0.placement == .trailing }
                .min { widgetPriority(for: $0.kind) < widgetPriority(for: $1.kind) }

        compactWidgets = [leading, trailing].compactMap { $0 }
    }

    private func widgetPriority(for kind: CompactWidgetKind) -> Int {
        compactWidgetPriorities[kind] ?? Int.max
    }

    private func ensureExpandedWidgetPage() {
        let pages = expandedWidgetPages
        if let currentExpandedPageKind, pages.contains(currentExpandedPageKind) {
            return
        }
        currentExpandedPageKind = pages.first
    }

    private func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil(NSString(string: text).size(withAttributes: [.font: font]).width)
    }

    private func compactWidgetWidth(for style: CompactWidgetStyle) -> CGFloat {
        switch style {
        case .artwork, .symbol:
            return 24
        case .visualizer:
            return 26
        case .labeledSymbol(let systemName, let text):
            let textWidth = NSString(string: text).size(withAttributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold)
            ]).width
            let iconWidth: CGFloat = systemName.isEmpty ? 0 : 12
            return ceil(textWidth) + iconWidth + 16
        case .circularProgress(_, _, _, let text):
            let textWidth = NSString(string: text).size(withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            ]).width
            return ceil(textWidth) + 42
        }
    }

    private var batteryWidget: CompactIslandWidget? {
        guard isFeatureEnabled(.battery), let batteryLevel else { return nil }
        let symbolName: String
        switch batteryLevel {
        case 90...100:
            symbolName = batteryIsCharging ? "bolt.fill" : "battery.100percent"
        case 50..<90:
            symbolName = batteryIsCharging ? "bolt.fill" : "battery.75percent"
        case 20..<50:
            symbolName = batteryIsCharging ? "bolt.fill" : "battery.50percent"
        default:
            symbolName = batteryIsCharging ? "bolt.fill" : "battery.25percent"
        }

        return CompactIslandWidget(
            id: "battery-widget",
            kind: .battery,
            placement: .leading,
            style: .labeledSymbol(systemName: symbolName, text: "\(batteryLevel)%"),
            preferredWidth: compactWidgetWidth(for: .labeledSymbol(systemName: symbolName, text: "\(batteryLevel)%")),
            artworkData: nil
        )
    }

    private var pinnedFileWidget: CompactIslandWidget? {
        guard isFeatureEnabled(.pinnedFile), let pinnedFileURL else { return nil }
        let fileName = pinnedFileURL.deletingPathExtension().lastPathComponent
        let fileIconName = symbolName(for: pinnedFileURL.pathExtension)
        let style = CompactWidgetStyle.labeledSymbol(systemName: fileIconName, text: fileName)

        return CompactIslandWidget(
            id: "pinned-file-widget",
            kind: .pinnedFile,
            placement: .leading,
            style: style,
            preferredWidth: compactWidgetWidth(for: style),
            artworkData: nil
        )
    }

    private var weatherWidget: CompactIslandWidget? {
        guard isFeatureEnabled(.weather),
              let weatherTemperatureText,
              let weatherSymbolName else { return nil }

        return CompactIslandWidget(
            id: "weather-widget",
            kind: .weather,
            placement: .trailing,
            style: .labeledSymbol(systemName: weatherSymbolName, text: weatherTemperatureText),
            preferredWidth: compactWidgetWidth(for: .labeledSymbol(systemName: weatherSymbolName, text: weatherTemperatureText)),
            artworkData: nil
        )
    }

    private var pomodoroWidget: CompactIslandWidget? {
        guard isFeatureEnabled(.pomodoro) else { return nil }
        let style = CompactWidgetStyle.circularProgress(
            systemName: pomodoroPhase.symbolName,
            progress: pomodoroProgress,
            isActive: pomodoroIsRunning,
            text: pomodoroTimeText
        )

        return CompactIslandWidget(
            id: "pomodoro-widget",
            kind: .pomodoro,
            placement: .trailing,
            style: style,
            preferredWidth: compactWidgetWidth(for: style),
            artworkData: nil
        )
    }

    private var chargingPowerWidget: CompactIslandWidget? {
        guard let chargingPowerText else { return nil }
        let style = CompactWidgetStyle.labeledSymbol(systemName: "bolt.fill", text: chargingPowerText)

        return CompactIslandWidget(
            id: "charging-power-widget",
            kind: .chargingPower,
            placement: .trailing,
            style: style,
            preferredWidth: compactWidgetWidth(for: style),
            artworkData: nil
        )
    }

    private var urgentPomodoroWidget: CompactIslandWidget? {
        guard isFeatureEnabled(.pomodoro), pomodoroIsRunning, pomodoroRemainingSeconds <= 5 else { return nil }
        let style = CompactWidgetStyle.circularProgress(
            systemName: "exclamationmark",
            progress: pomodoroProgress,
            isActive: true,
            text: pomodoroTimeText
        )

        return CompactIslandWidget(
            id: "urgent-pomodoro-widget",
            kind: .pomodoro,
            placement: .trailing,
            style: style,
            preferredWidth: compactWidgetWidth(for: style),
            artworkData: nil
        )
    }

    private var nowPlayingArtworkWidget: CompactIslandWidget? {
        guard isFeatureEnabled(.nowPlaying), currentPresentation != nil, nowPlayingShowsArtwork else { return nil }

        return CompactIslandWidget(
            id: "now-playing-artwork",
            kind: .nowPlayingArtwork,
            placement: .leading,
            style: .artwork,
            preferredWidth: compactWidgetWidth(for: .artwork),
            artworkData: artworkData
        )
    }

    private var nowPlayingVisualizerWidget: CompactIslandWidget? {
        guard isFeatureEnabled(.nowPlaying), currentPresentation != nil, nowPlayingShowsVisualizer else { return nil }
        let visualizerStyle: CompactWidgetStyle = nowPlayingAnimatesVisualizer
            ? .visualizer(isActive: isPlaying)
            : .symbol("music.note")

        return CompactIslandWidget(
            id: "now-playing-visualizer",
            kind: .nowPlayingVisualizer,
            placement: .trailing,
            style: visualizerStyle,
            preferredWidth: compactWidgetWidth(for: visualizerStyle),
            artworkData: nil
        )
    }

    private func perform(_ hapticFeedback: IslandHapticFeedback) {
        NSHapticFeedbackManager.defaultPerformer.perform(
            hapticFeedback.pattern,
            performanceTime: .now
        )
    }

    var pomodoroTimeText: String {
        let minutes = pomodoroRemainingSeconds / 60
        let seconds = pomodoroRemainingSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var showsBatteryLowWarning: Bool {
        guard let batteryLevel else { return false }
        return batteryLevel < 10 && !batteryIsCharging && expandedPanel == nil
    }

    var chargingPowerText: String? {
        guard let chargingPowerWatts else { return nil }
        if chargingPowerWatts >= 10 {
            return "\(Int(chargingPowerWatts.rounded()))W"
        } else {
            return String(format: "%.1fW", chargingPowerWatts)
        }
    }

    var pomodoroProgress: CGFloat {
        let duration = max(CGFloat(pomodoroPhase.duration), 1)
        let remaining = CGFloat(pomodoroRemainingSeconds)
        return max(0, min(1, 1 - (remaining / duration)))
    }

    var usesRealNowPlayingVisualizer: Bool {
        nowPlayingVisualizerMode == .real && realVisualizerIsAvailable
    }

    var realVisualizerStatusText: String {
        switch (nowPlayingVisualizerMode, realVisualizerIsAvailable) {
        case (.fake, _):
            return "ランダムアニメーションで軽く動かします。"
        case (.real, true):
            return "画面音声のレベルからリアルタイムに動きます。"
        case (.real, false):
            return "画面収録権限がないか、音声をまだ取れていないためフェイク表示に戻しています。"
        }
    }

    private func normalizedLyricsRequestKey(for track: AppleMusicTrack) -> String? {
        guard
            let durationSeconds = track.durationSeconds,
            durationSeconds > 0
        else {
            return nil
        }

        let normalizedTitle = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedArtist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAlbum = track.album.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedTitle.isEmpty, !normalizedArtist.isEmpty else {
            return nil
        }

        return [
            normalizedTitle.lowercased(),
            normalizedArtist.lowercased(),
            normalizedAlbum.lowercased(),
            String(Int(durationSeconds.rounded()))
        ]
        .joined(separator: "||")
    }

    private func loadLyrics(for track: AppleMusicTrack, requestKey: String?) {
        lyricsTask?.cancel()
        currentLyricsRequestKey = requestKey
        syncedLyrics = []
        plainLyricsText = nil
        lyricsProvider = nil

        guard let requestKey else {
            lyricsLoadState = .unavailable
            notifyLayoutChange()
            return
        }

        lyricsLoadState = .loading
        notifyLayoutChange()

        lyricsTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let lyrics = await lyricsService.lyrics(
                trackName: track.title,
                artistName: track.artist,
                albumName: track.album,
                durationSeconds: track.durationSeconds
            )

            guard !Task.isCancelled, self.currentLyricsRequestKey == requestKey else { return }

            let parsedSyncedLyrics = await lyricsService.parseSyncedLyrics(lyrics?.syncedLyrics)
            guard !Task.isCancelled, self.currentLyricsRequestKey == requestKey else { return }

            self.syncedLyrics = parsedSyncedLyrics
            self.plainLyricsText = lyrics?.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.lyricsProvider = lyrics?.provider

            if !parsedSyncedLyrics.isEmpty {
                self.lyricsLoadState = .ready
            } else if self.plainLyricsText?.isEmpty == false {
                self.lyricsLoadState = .ready
            } else {
                self.lyricsLoadState = .unavailable
            }

            self.notifyLayoutChange()
        }
    }

    private func clampedPlaybackPosition(_ position: TimeInterval) -> TimeInterval {
        guard let duration = nowPlayingDurationSeconds, duration > 0 else {
            return max(0, position)
        }
        return min(max(0, position), duration)
    }

    private func updateVisualizerPalette(from artworkData: Data?) {
        guard
            let artworkData,
            let palette = artworkPalette(from: artworkData)
        else {
            resetVisualizerPalette()
            return
        }

        let brightColor = palette.mainColor
            .withSaturation(multiplier: 1.18)
            .withBrightness(multiplier: 1.08)
        let darkColor = palette.subColor
            .withSaturation(multiplier: 1.12)
            .withBrightness(multiplier: 0.9)

        visualizerBrightColor = Color(nsColor: brightColor.withAlphaComponent(0.98))
        visualizerDarkColor = Color(nsColor: darkColor.withAlphaComponent(0.9))
    }

    private func resetVisualizerPalette() {
        visualizerBrightColor = .white.opacity(0.92)
        visualizerDarkColor = .white.opacity(0.6)
    }

    private func artworkPalette(from artworkData: Data) -> ArtworkPalette? {
        guard
            let image = NSImage(data: artworkData),
            let tiffData = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }

        let sampleSize = 28
        guard
            let reduced = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: sampleSize,
                pixelsHigh: sampleSize,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: reduced) {
            NSGraphicsContext.current = context
            context.imageInterpolation = .medium
            image.draw(in: NSRect(x: 0, y: 0, width: sampleSize, height: sampleSize))
            context.flushGraphics()
        }
        NSGraphicsContext.restoreGraphicsState()

        struct Bucket {
            var count: Int = 0
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var prominence: CGFloat = 0
        }

        var buckets: [String: Bucket] = [:]

        for y in 0..<sampleSize {
            for x in 0..<sampleSize {
                guard let color = reduced.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                guard let rgb = color.rgbComponents, let hsb = color.hsbComponents else { continue }
                guard rgb.alpha > 0.2 else { continue }
                guard hsb.brightness > 0.12 else { continue }

                let redKey = Int((rgb.red * 255).rounded()) / 32
                let greenKey = Int((rgb.green * 255).rounded()) / 32
                let blueKey = Int((rgb.blue * 255).rounded()) / 32
                let key = "\(redKey)-\(greenKey)-\(blueKey)"

                var bucket = buckets[key] ?? Bucket()
                bucket.count += 1
                bucket.red += rgb.red
                bucket.green += rgb.green
                bucket.blue += rgb.blue
                bucket.prominence += (hsb.saturation * 1.9) + (hsb.brightness * 1.1)
                buckets[key] = bucket
            }
        }

        let rankedColors = buckets.values.compactMap { bucket -> (color: NSColor, score: CGFloat)? in
            guard bucket.count > 0 else { return nil }

            let averagedColor = NSColor(
                calibratedRed: bucket.red / CGFloat(bucket.count),
                green: bucket.green / CGFloat(bucket.count),
                blue: bucket.blue / CGFloat(bucket.count),
                alpha: 1
            )

            guard let hsb = averagedColor.hsbComponents else { return nil }
            let score =
                bucket.prominence
                + (CGFloat(bucket.count) * 0.95)
                + (hsb.saturation * 18)
                + (hsb.brightness * 10)
            return (averagedColor, score)
        }
        .sorted { $0.score > $1.score }

        guard let mainColor = rankedColors.first?.color else { return nil }

        let subColor = rankedColors.first(where: { candidate in
            candidate.color.distance(to: mainColor) > 0.24
        })?.color ?? mainColor

        return ArtworkPalette(mainColor: mainColor, subColor: subColor)
    }

    private func extendVolumeOverlayVisibility(by duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        volumeOverlayVisibleUntil = deadline
        print("VolumeOverlay: extend deadline=\(deadline.timeIntervalSince1970)")

        guard volumeHideTask == nil else {
            print("VolumeOverlay: hide watcher already running")
            return
        }

        print("VolumeOverlay: start hide watcher")

        volumeHideTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                guard let visibleUntil = self.volumeOverlayVisibleUntil else { break }
                let remaining = visibleUntil.timeIntervalSinceNow

                print("VolumeOverlay: watcher remaining=\(String(format: "%.3f", remaining))")

                if remaining <= 0 {
                    print("VolumeOverlay: deadline reached, dismissing")
                    self.dismissVolumeOverlay()
                    break
                }

                let sleepDuration = min(remaining, 0.12)
                try? await Task.sleep(for: .seconds(sleepDuration))
            }
        }
    }

    private func dismissVolumeOverlay(resetLevel: Bool = false) {
        print("VolumeOverlay: dismiss resetLevel=\(resetLevel)")
        volumeHideTask?.cancel()
        volumeHideTask = nil
        volumeOverlayVisibleUntil = nil
        showsVolumeChange = false
        volumeOutputDeviceName = nil
        if resetLevel {
            volumeLevel = 0
        }
    }

    private func startPomodoroTimer() {
        pomodoroTimerTask?.cancel()
        pomodoroTimerTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.pomodoroIsRunning {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, self.pomodoroIsRunning else { return }

                if self.pomodoroRemainingSeconds > 0 {
                    self.pomodoroRemainingSeconds -= 1
                }

                if self.pomodoroRemainingSeconds <= 0 {
                    self.pomodoroPhase = self.pomodoroPhase.next
                    self.pomodoroRemainingSeconds = self.pomodoroPhase.duration
                    self.perform(.alignment)
                    self.playPomodoroTransitionSound()
                }

                self.updateTemporaryPomodoroWidget()
                self.refreshCompactWidgets()
                self.notifyLayoutChange()
            }
        }
    }

    private func stopPomodoroTimer() {
        pomodoroIsRunning = false
        pomodoroTimerTask?.cancel()
        pomodoroTimerTask = nil
        clearTemporaryCompactWidget(for: .trailing, kind: .pomodoro)
    }

    private func shouldShowChargingPowerIndicator(
        previousStatus: (level: Int, isCharging: Bool, chargingWatts: Double?)?,
        chargingWatts: Double
    ) -> Bool {
        guard expandedPanel == nil else { return false }
        guard let previousStatus else { return true }
        if !previousStatus.isCharging { return true }
        guard let previousWatts = previousStatus.chargingWatts else { return true }
        return abs(previousWatts - chargingWatts) >= 2
    }

    private func showChargingPowerIndicator() {
        guard let chargingPowerWidget else { return }
        presentTemporaryCompactWidget(chargingPowerWidget, duration: 3)
    }

    private func updateTemporaryPomodoroWidget() {
        if let urgentPomodoroWidget {
            setTemporaryCompactWidget(urgentPomodoroWidget)
        } else {
            clearTemporaryCompactWidget(for: .trailing, kind: .pomodoro)
        }
    }

    private func presentTemporaryCompactWidget(_ widget: CompactIslandWidget, duration: TimeInterval) {
        setTemporaryCompactWidget(widget)
        temporaryWidgetTasks[widget.placement]?.cancel()
        temporaryWidgetTasks[widget.placement] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.clearTemporaryCompactWidget(for: widget.placement, kind: widget.kind)
        }
    }

    private func setTemporaryCompactWidget(_ widget: CompactIslandWidget) {
        temporaryCompactWidgets[widget.placement] = widget
        refreshCompactWidgets()
        notifyLayoutChange()
    }

    private func clearTemporaryCompactWidget(for placement: CompactWidgetPlacement, kind: CompactWidgetKind? = nil) {
        if let kind, temporaryCompactWidgets[placement]?.kind != kind {
            return
        }
        temporaryWidgetTasks[placement]?.cancel()
        temporaryWidgetTasks[placement] = nil
        temporaryCompactWidgets[placement] = nil
        refreshCompactWidgets()
        notifyLayoutChange()
    }

    private func playPomodoroTransitionSound() {
        if let customSound = customPomodoroTransitionSound() {
            customSound.play()
        } else if let sound = NSSound(named: "Hero") {
            sound.play()
        } else {
            NSSound.beep()
        }
    }

    private func customPomodoroTransitionSound() -> NSSound? {
        let supportedExtensions = ["wav", "aiff", "mp3", "m4a"]

        for ext in supportedExtensions {
            let urls = Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? []
            if let url = urls.first(where: { url in
                let normalized = normalizedSoundFileName(url.deletingPathExtension().lastPathComponent)
                return normalized.contains("pomodoro") && normalized.contains("transition")
            }) {
                return NSSound(contentsOf: url, byReference: false)
            }
        }

        return nil
    }

    private func normalizedSoundFileName(_ fileName: String) -> String {
        fileName
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
            .lowercased()
    }

    private func symbolName(for pathExtension: String) -> String {
        if let type = UTType(filenameExtension: pathExtension) {
            if type.conforms(to: .image) {
                return "photo"
            }
            if type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) {
                return "film"
            }
            if type.conforms(to: .audio) {
                return "waveform"
            }
            if type.conforms(to: .pdf) {
                return "doc.richtext"
            }
            if type.conforms(to: .archive) {
                return "archivebox"
            }
            if type.conforms(to: .text) {
                return "doc.text"
            }
        }

        return "doc"
    }

    private static func restorePinnedFileURL() -> URL? {
        guard let bookmarkData = UserDefaults.standard.data(forKey: pinnedFileBookmarkKey) else { return nil }
        var isStale = false
        return try? URL(resolvingBookmarkData: bookmarkData, bookmarkDataIsStale: &isStale)
    }
}
