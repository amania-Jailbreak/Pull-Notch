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
import PullNotchPluginKit
import Quartz
import ScreenCaptureKit
import SwiftUI

@main
struct Pull_NotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlayWindow: NotchPanel?
    private var settingsWindow: SettingsPanel?
    private let overlayModel = NotchOverlayModel()
    private let pluginManager = PluginManager()
    private let pluginBridgeServer = PluginBridgeServer.shared
    private let nowPlayingMonitor = AppleMusicNowPlayingMonitor()
    private let screenAudioMonitor = ScreenAudioVisualizerMonitor()
    private let volumeMonitor = SystemVolumeMonitor()
    private let batteryMonitor = SystemBatteryMonitor()
    private let weatherMonitor = WeatherMonitor()
    private let updateChecker = GitHubUpdateChecker()
    private var sizeObserver: NSObjectProtocol?
    private var outsideClickMonitor: Any?
    private var scrollWheelMonitor: Any?
    private var spaceKeyMonitor: Any?
    private var mousePassthroughMonitor: Any?
    private var sharingPicker: NSSharingServicePicker?
    private var pinnedFileOpenPanel: NSOpenPanel?
    private let pinnedFileQuickLookController = PinnedFileQuickLookController()
    private var lastScrollPageSwitchAt: TimeInterval = 0
    private var lastOverlayFrame: NSRect?
    private var overlayScreenID: CGDirectDisplayID?
    private var screenChangeWorkItem: DispatchWorkItem?
    private var isUpdatingOverlayPosition = false

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
        overlayModel.quickLookPinnedFileHandler = { [weak self] url in
            self?.showQuickLook(for: url)
        }
        overlayModel.choosePinnedFilesHandler = { [weak self] in
            self?.showPinnedFileChooser()
        }
        createOverlayWindow()
        overlayModel.presentOnboardingIfNeeded()
        observeOverlaySize()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        observeOutsideClicks()
        observeScrollWheelPaging()
        observeSpaceKeyForToastDismissal()
        observeMousePassthrough()
        nowPlayingMonitor.start(using: overlayModel)
        screenAudioMonitor.start(using: overlayModel)
        volumeMonitor.start(using: overlayModel)
        batteryMonitor.start(using: overlayModel)
        weatherMonitor.start(using: overlayModel)
        pluginManager.start(using: overlayModel)
        pluginBridgeServer.start(using: overlayModel)
        scheduleAutomaticUpdateCheck()
        MenuBarManager.shared.restoreOnLaunchIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        MenuBarManager.shared.deactivate()
    }

    private func scheduleAutomaticUpdateCheck() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, let update = await updateChecker.checkAutomatically() else { return }
            await MainActor.run {
                self.showUpdateAvailableAlert(release: update.release, version: update.version)
            }
        }
    }

    private func showUpdateAvailableAlert(release: GitHubRelease, version: AppReleaseVersion) {
        let alert = NSAlert()
        alert.messageText = "Pull Notch \(version.displayText) が利用可能です"
        alert.informativeText = "新しいバージョンがGitHub Releasesで公開されています。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "リリースページを開く")
        alert.addButton(withTitle: "あとで")

        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.htmlURL)
        }
    }

    @objc private func screenParametersDidChange() {
        screenChangeWorkItem?.cancel()
        lastOverlayFrame = nil
        refreshOverlayScreenSelection()
        updateOverlayPosition()

        // AppKit can publish several screen-parameter notifications while it
        // is still settling the new coordinate space. Re-apply the same
        // selected screen after that burst instead of deriving a new target
        // from the panel's temporary frame on every notification.
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lastOverlayFrame = nil
            self.updateOverlayPosition()
            self.screenAudioMonitor.screenConfigurationDidChange(using: self.overlayModel)
        }
        screenChangeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    @objc private func updateOverlayPosition() {
        guard let overlayWindow else { return }
        guard !isUpdatingOverlayPosition else { return }
        guard let screen = selectedOverlayScreen(fallbackWindow: overlayWindow) else { return }

        isUpdatingOverlayPosition = true
        defer { isUpdatingOverlayPosition = false }

        overlayModel.setDisplayMode(isBuiltInDisplay(screen) ? .macDisplay : .externalDisplay)

        let panelSize = overlayModel.panelSize
        let x = screen.frame.midX - (panelSize.width / 2)
        let y: CGFloat
        if overlayModel.usesExternalCompactLayout {
            y = screen.frame.maxY - panelSize.height
        } else {
            y = screen.frame.maxY - panelSize.height + 10
        }
        let targetFrame = NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height)

        guard !framesApproximatelyEqual(lastOverlayFrame ?? overlayWindow.frame, targetFrame) else { return }
        lastOverlayFrame = targetFrame
        overlayWindow.setFrame(targetFrame, display: true, animate: false)
        updateOverlayMousePassthrough()
    }

    private func selectedOverlayScreen(fallbackWindow: NSWindow) -> NSScreen? {
        if let overlayScreenID,
           let selectedScreen = NSScreen.screens.first(where: { displayID(for: $0) == overlayScreenID }) {
            return selectedScreen
        }

        let fallback = availableScreen(matching: fallbackWindow.screen)
            ?? NSScreen.main
            ?? NSScreen.screens.first
        overlayScreenID = fallback.flatMap { displayID(for: $0) }
        return fallback
    }

    private func refreshOverlayScreenSelection() {
        guard let overlayWindow else { return }

        if let overlayScreenID,
           let selectedScreen = NSScreen.screens.first(where: { displayID(for: $0) == overlayScreenID }) {
            let intersection = overlayWindow.frame.intersection(selectedScreen.frame)
            let intersectionArea = max(0, intersection.width) * max(0, intersection.height)
            let windowArea = overlayWindow.frame.width * overlayWindow.frame.height
            if intersectionArea >= windowArea * 0.5 {
                return
            }
        }

        let fallback = availableScreen(matching: overlayWindow.screen)
            ?? NSScreen.main
            ?? NSScreen.screens.first
        overlayScreenID = fallback.flatMap { displayID(for: $0) }
        lastOverlayFrame = nil
    }

    private func availableScreen(matching candidate: NSScreen?) -> NSScreen? {
        guard let candidateID = candidate.flatMap({ displayID(for: $0) }) else { return nil }
        return NSScreen.screens.first(where: { displayID(for: $0) == candidateID })
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    private func isBuiltInDisplay(_ screen: NSScreen) -> Bool {
        guard let displayID = displayID(for: screen) else {
            return true
        }
        return CGDisplayIsBuiltin(displayID) != 0
    }

    private func framesApproximatelyEqual(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) < 0.5
            && abs(lhs.origin.y - rhs.origin.y) < 0.5
            && abs(lhs.size.width - rhs.size.width) < 0.5
            && abs(lhs.size.height - rhs.size.height) < 0.5
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
        window.contentView = NotchHostingView(overlayModel: overlayModel)

        overlayWindow = window
        overlayScreenID = (NSScreen.main ?? NSScreen.screens.first).flatMap { displayID(for: $0) }
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
                contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Pull Notch Settings"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.backgroundColor = .clear
            window.isOpaque = false
            window.minSize = NSSize(width: 940, height: 640)
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

    private func showQuickLook(for url: URL) {
        pinnedFileQuickLookController.present(url: url)
    }

    private func showPinnedFileChooser() {
        guard pinnedFileOpenPanel == nil else { return }

        let panel = NSOpenPanel()
        panel.title = "Add Files to Pull Notch"
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        pinnedFileOpenPanel = panel

        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard let self else { return }
            defer { self.pinnedFileOpenPanel = nil }
            guard response == .OK else { return }
            self.overlayModel.pinFiles(panel.urls)
        }
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
                self.overlayWindow != nil
            else {
                return
            }

            let location = NSEvent.mouseLocation
            if !self.overlayInteractiveFrameInScreen().contains(location) {
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
                self.overlayWindow != nil
            else {
                return event
            }

            let location = NSEvent.mouseLocation
            guard self.overlayInteractiveFrameInScreen().contains(location) else { return event }

            if self.overlayModel.expandedPanel == .musicPlayer,
               self.overlayModel.activeExpandedBuiltInPage == .pinnedFile {
                return event
            }

            let horizontalDelta = abs(event.scrollingDeltaX)
            let verticalDelta = abs(event.scrollingDeltaY)
            let dominantDelta = max(horizontalDelta, verticalDelta)
            let secondaryDelta = min(horizontalDelta, verticalDelta)
            guard dominantDelta >= 18 else { return event }
            guard secondaryDelta <= dominantDelta * 0.65 else { return event }

            if self.overlayModel.expandedPanel == .musicPlayer,
               self.overlayModel.activeExpandedBuiltInPage == .widgetBoard,
               verticalDelta > horizontalDelta {
                return event
            }

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

    private func observeSpaceKeyForToastDismissal() {
        spaceKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 49,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
               let self,
               self.overlayModel.expandedPanel == .musicPlayer,
               self.overlayModel.activeExpandedBuiltInPage == .pinnedFile,
               self.overlayModel.selectedPinnedFile?.isAvailable == true {
                self.overlayModel.quickLookPinnedFile()
                return nil
            }

            guard
                event.keyCode == 49,
                event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                let self,
                self.overlayWindow != nil,
                self.overlayInteractiveFrameInScreen().contains(NSEvent.mouseLocation),
                self.overlayModel.handleToastSpaceKey()
            else {
                return event
            }

            return nil
        }
    }

    private func observeMousePassthrough() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        mousePassthroughMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateOverlayMousePassthrough()
            }
        }
    }

    private func updateOverlayMousePassthrough() {
        guard let overlayWindow else { return }
        let shouldAcceptMouseEvents = overlayInteractiveFrameInScreen().contains(NSEvent.mouseLocation)
        if overlayWindow.ignoresMouseEvents == shouldAcceptMouseEvents {
            overlayWindow.ignoresMouseEvents = !shouldAcceptMouseEvents
        }
    }

    private func overlayInteractiveFrameInScreen() -> NSRect {
        guard let overlayWindow else { return .zero }
        let windowFrame = overlayWindow.frame
        let width = overlayModel.visibleWidth
        let height = overlayModel.currentIslandHeight
        let x = windowFrame.midX - (width / 2)
        let y = windowFrame.maxY - overlayModel.effectiveWindowTopInset - height
        return NSRect(x: x, y: y, width: width, height: height).insetBy(dx: -2, dy: -2)
    }
}

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class NotchHostingView: NSHostingView<ContentView> {
    private let overlayModel: NotchOverlayModel

    init(overlayModel: NotchOverlayModel) {
        self.overlayModel = overlayModel
        super.init(rootView: ContentView(overlayModel: overlayModel))
    }

    @MainActor @preconcurrency required init(rootView: ContentView) {
        self.overlayModel = rootView.overlayModel
        super.init(rootView: rootView)
    }

    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard interactiveFrameInBounds().contains(point) else { return nil }
        return super.hitTest(point)
    }

    private func interactiveFrameInBounds() -> NSRect {
        let width = overlayModel.visibleWidth
        let height = overlayModel.currentIslandHeight
        let x = bounds.midX - (width / 2)
        let y = bounds.maxY - overlayModel.effectiveWindowTopInset - height
        return NSRect(x: x, y: y, width: width, height: height).insetBy(dx: -2, dy: -2)
    }
}

final class PinnedFileQuickLookController: NSObject, QLPreviewPanelDataSource {
    private var previewURL: URL?

    func present(url: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible, previewURL == url {
            panel.orderOut(nil)
            return
        }
        previewURL = url
        panel.dataSource = self
        panel.reloadData()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> any QLPreviewItem {
        previewURL! as NSURL
    }
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
        case plugins

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general:
                return "General"
            case .widgets:
                return "Widgets"
            case .weather:
                return "Weather"
            case .plugins:
                return "Plugins"
            }
        }
    }

    @Bindable var overlayModel: NotchOverlayModel
    @State private var selectedTab: SettingsTab = .general
    @State private var manualWeatherLocationDraft = ""
    @State private var menuBarManagerActive = false
    @State private var menuBarHiddenItemCount = 0
    @State private var menuBarAccessibilityChecked = false
    @State private var confirmsClearingPinnedFiles = false

    private func toggleMenuBarManagement() {
        if menuBarManagerActive {
            MenuBarManager.shared.deactivate()
            menuBarManagerActive = false
            menuBarHiddenItemCount = 0
        } else {
            let granted = MenuBarManager.shared.checkAccessibilityPermission(prompt: true)
            menuBarAccessibilityChecked = granted
            guard granted else { return }

            MenuBarManager.shared.activate()
            menuBarManagerActive = true
            menuBarHiddenItemCount = MenuBarManager.shared.hiddenItemsInfo().count
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.025, green: 0.027, blue: 0.038),
                    Color(red: 0.055, green: 0.05, blue: 0.085),
                    Color(red: 0.035, green: 0.055, blue: 0.075)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    tabPicker
                    Spacer(minLength: 18)
                    sidebarFooter
                }
                .padding(18)
                .frame(width: 248)
                .background(.black.opacity(0.18))

                Rectangle()
                    .fill(Color.white.opacity(0.07))
                    .frame(width: 1)

                VStack(alignment: .leading, spacing: 0) {
                    contentHeader
                    Rectangle()
                        .fill(Color.white.opacity(0.065))
                        .frame(height: 1)
                    tabContent
                }
            }
        }
        .frame(minWidth: 940, minHeight: 640)
        .preferredColorScheme(.dark)
        .onAppear {
            manualWeatherLocationDraft = overlayModel.manualWeatherLocation ?? ""
            menuBarAccessibilityChecked = MenuBarManager.shared.checkAccessibilityPermission(prompt: false)
            menuBarManagerActive = MenuBarManager.shared.isActive
            menuBarHiddenItemCount = MenuBarManager.shared.hiddenItemsInfo().count
        }
        .onChange(of: overlayModel.manualWeatherLocation) { _, newValue in
            manualWeatherLocationDraft = newValue ?? ""
        }
        .alert(
            "\(overlayModel.pinnedFiles.count)件のピン留めをすべて解除しますか？",
            isPresented: $confirmsClearingPinnedFiles
        ) {
            Button("キャンセル", role: .cancel) {}
            Button("すべて解除", role: .destructive) {
                overlayModel.clearPinnedFiles()
            }
        } message: {
            Text("並び順を含むファイル棚の内容が削除されます。元のファイルは削除されません。")
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.55, green: 0.48, blue: 1), Color(red: 0.25, green: 0.72, blue: 1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "capsule.tophalf.filled")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 40, height: 40)
            .shadow(color: Color(red: 0.45, green: 0.55, blue: 1).opacity(0.28), radius: 12, y: 5)

            VStack(alignment: .leading, spacing: 2) {
                Text("Pull Notch")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)

                Text("Settings")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, 5)
        .padding(.bottom, 24)
    }

    private var tabPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PREFERENCES")
                .font(.system(size: 9, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.28))
                .padding(.horizontal, 10)
                .padding(.bottom, 3)
            ForEach(SettingsTab.allCases) { tab in
                tabPickerButton(for: tab)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func tabPickerButton(for tab: SettingsTab) -> some View {
        let isSelected = selectedTab == tab
        let subtitleColor: Color = isSelected ? .white.opacity(0.62) : .white.opacity(0.35)
        let foregroundColor: Color = isSelected ? .white : .white.opacity(0.72)

        return Button {
            withAnimation(.easeOut(duration: 0.16)) {
                selectedTab = tab
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: iconName(for: tab))
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 27, height: 27)
                    .background(Color.white.opacity(isSelected ? 0.12 : 0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.title)
                        .font(.system(size: 13, weight: .semibold))

                    Text(subtitle(for: tab))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(subtitleColor)
                }

                Spacer(minLength: 0)

                if isSelected {
                    Circle()
                        .fill(Color(red: 0.48, green: 0.74, blue: 1))
                        .frame(width: 6, height: 6)
                }
            }
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule()
                        .fill(Color(red: 0.42, green: 0.7, blue: 1))
                        .frame(width: 3, height: 30)
                        .offset(x: -5)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
                    .shadow(color: .green.opacity(0.5), radius: 4)
                Text("All changes saved")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.52))
            }

            Text("Settings are applied immediately.")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.28))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var contentHeader: some View {
        HStack(spacing: 14) {
            ZStack {
                Image(systemName: iconName(for: selectedTab))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(red: 0.63, green: 0.78, blue: 1))
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(selectedTab.title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                Text(pageDescription(for: selectedTab))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))
            }

            Spacer(minLength: 0)

            Text("LIVE")
                .font(.system(size: 8, weight: .bold))
                .tracking(1)
                .foregroundStyle(Color.green.opacity(0.85))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Color.green.opacity(0.1), in: Capsule())
        }
        .padding(.horizontal, 26)
        .padding(.top, 21)
        .padding(.bottom, 17)
    }

    @ViewBuilder
    private var tabContent: some View {
        ScrollView {
            switch selectedTab {
            case .general:
                LazyVStack(spacing: 14) {
                    featureSection
                    pinnedFileSection
                    menuBarSection
                }
                .padding(.vertical, 2)
            case .widgets:
                LazyVStack(spacing: 14) {
                    nowPlayingSection
                    toastSection
                    dashboardWidgetBoardSection
                    reminderWidgetSettingsSection
                    compactWidgetPrioritySection
                }
                .padding(.vertical, 2)
            case .weather:
                LazyVStack(spacing: 14) {
                    weatherLocationSection
                }
                .padding(.vertical, 2)
            case .plugins:
                LazyVStack(spacing: 14) {
                    pluginsSection
                }
                .padding(.vertical, 2)
            }
        }
        .contentMargins(.horizontal, 26, for: .scrollContent)
        .contentMargins(.vertical, 22, for: .scrollContent)
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

    private var toastSection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(
                    title: "Toast",
                    subtitle: "Widgetとは別に、曲変更バナーの位置へ常時出す小さな情報表示です。"
                )

                settingsToggleButton(
                    title: "歌詞Toastを表示",
                    subtitle: "再生中の曲に同期歌詞があれば、現在行を常時表示します。",
                    isOn: overlayModel.toastShowsLyrics
                ) {
                    overlayModel.setToastLyricsVisible(!overlayModel.toastShowsLyrics)
                }

                Text("歌詞が見つからない場合は曲名表示にフォールバックします。")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))
            }
        }
    }

    private func visualizerModeButton(_ mode: NowPlayingVisualizerMode, title: String) -> some View {
        Button {
            overlayModel.setNowPlayingVisualizerMode(mode)
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(overlayModel.nowPlayingVisualizerMode == mode ? 0.96 : 0.68))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(overlayModel.nowPlayingVisualizerMode == mode ? Color(red: 0.36, green: 0.64, blue: 1) : Color.white.opacity(0.05))
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
                    title: "Pinned File Shelf",
                    subtitle: "ノッチへのドロップまたは選択画面から、最大12件を追加できます。"
                )

                HStack(spacing: 8) {
                    Text("\(overlayModel.pinnedFiles.count) / \(overlayModel.maximumPinnedFileCount)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))

                    if let selected = overlayModel.selectedPinnedFile {
                        Text("Selected: \(selected.displayName)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(selected.isAvailable ? Color.white.opacity(0.72) : Color.orange.opacity(0.9))
                            .lineLimit(1)
                    } else {
                        Text("まだピン留めされたファイルはありません。")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.07))
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Color(red: 0.38, green: 0.66, blue: 1), Color(red: 0.62, green: 0.52, blue: 1)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: proxy.size.width * CGFloat(overlayModel.pinnedFiles.count) / CGFloat(max(1, overlayModel.maximumPinnedFileCount)))
                    }
                }
                .frame(height: 5)

                HStack(spacing: 8) {
                    buttonChip("Add Files…", emphasized: true) {
                        overlayModel.choosePinnedFiles()
                    }

                    if !overlayModel.pinnedFiles.isEmpty {
                        buttonChip("すべて解除", emphasized: false) {
                            confirmsClearingPinnedFiles = true
                        }
                    }
                }
            }
        }
    }

    private var compactWidgetPrioritySection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 16) {
                sectionHeader(
                    title: "Compact Widgets",
                    subtitle: "Widgetを1つの場所だけに置きます。Left/Rightは上から順に表示候補、Hiddenは完全に非表示です。"
                )

                HStack(alignment: .top, spacing: 12) {
                    compactWidgetGroup(zone: .leading)
                    compactWidgetGroup(zone: .trailing)
                    compactWidgetGroup(zone: .hidden)
                }
            }
        }
    }

    private var dashboardWidgetBoardSection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader(
                    title: "Expanded Widget Board",
                    subtitle: "拡大表示の左右2ペインに表示するwidgetを選びます。同じwidgetを両側に配置できます。"
                )

                HStack(alignment: .top, spacing: 12) {
                    dashboardSlotSettings(.leading)
                    dashboardSlotSettings(.trailing)
                }
            }
        }
    }

    private var reminderWidgetSettingsSection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(
                    title: "Today Tasks",
                    subtitle: "今日と期限超過のApple Remindersを表示するリストを選びます。"
                )

                switch overlayModel.reminderAccessState {
                case .authorized:
                    if overlayModel.reminderLists.isEmpty {
                        Text("利用できるリマインダーリストがありません。")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.45))
                    } else {
                        VStack(spacing: 7) {
                            ForEach(overlayModel.reminderLists) { list in
                                Button {
                                    overlayModel.setReminderListEnabled(
                                        id: list.id,
                                        isEnabled: !overlayModel.isReminderListEnabled(id: list.id)
                                    )
                                } label: {
                                    HStack(spacing: 9) {
                                        Image(systemName: overlayModel.isReminderListEnabled(id: list.id) ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(overlayModel.isReminderListEnabled(id: list.id) ? Color.white : Color.white.opacity(0.28))
                                        Text(list.title)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(.white.opacity(0.82))
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 2)
                                    .padding(.vertical, 9)
                                    .overlay(alignment: .bottom) {
                                        Rectangle().fill(Color.white.opacity(0.055)).frame(height: 1)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                case .notDetermined:
                    HStack(spacing: 9) {
                        Text("Apple Remindersへのアクセスが必要です。")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.48))
                        Spacer(minLength: 0)
                        buttonChip("アクセスを許可", emphasized: true) {
                            Task { await overlayModel.requestReminderAccess() }
                        }
                    }
                case .requesting:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("権限を確認しています…")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.48))
                    }
                case .denied, .restricted:
                    HStack(spacing: 9) {
                        Text("システム設定でRemindersへのアクセスを許可してください。")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.orange.opacity(0.8))
                        Spacer(minLength: 0)
                        buttonChip("システム設定", emphasized: false) {
                            overlayModel.openReminderPrivacySettings()
                        }
                    }
                }

                if let errorMessage = overlayModel.reminderErrorMessage {
                    Text(errorMessage)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.orange.opacity(0.8))
                        .lineLimit(2)
                }
            }
            .task {
                if overlayModel.reminderAccessState == .authorized {
                    overlayModel.reminderWidgetModel.refresh()
                }
            }
        }
    }

    private func dashboardSlotSettings(_ slot: DashboardWidgetSlot) -> some View {
        let selected = overlayModel.dashboardWidgetIdentity(for: slot)

        return VStack(alignment: .leading, spacing: 9) {
            Text(slot.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.48))

            Menu {
                ForEach(dashboardOptions(including: selected), id: \.storageToken) { identity in
                    Button {
                        overlayModel.selectDashboardWidget(identity, for: slot)
                    } label: {
                        Label(
                            overlayModel.dashboardWidgetTitle(identity),
                            systemImage: identity == selected ? "checkmark" : overlayModel.dashboardWidgetSymbol(identity)
                        )
                    }
                }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: overlayModel.dashboardWidgetSymbol(selected))
                        .font(.system(size: 12, weight: .semibold))
                    Text(overlayModel.dashboardWidgetTitle(selected))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if !overlayModel.isDashboardWidgetAvailable(selected) {
                        Text("Unavailable")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.orange.opacity(0.9))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.35))
                }
                .foregroundStyle(.white.opacity(0.84))
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                )
            }
            .menuStyle(.borderlessButton)
        }
        .frame(maxWidth: .infinity)
    }

    private func dashboardOptions(including selected: DashboardWidgetIdentity) -> [DashboardWidgetIdentity] {
        var options = overlayModel.availableDashboardWidgets
        if !options.contains(selected) {
            options.append(selected)
        }
        return options
    }

    private var menuBarSection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(
                    title: "Menu Bar",
                    subtitle: "メニューバーのアイコンを非表示にします。Bartenderのような動作です。いつでも戻せます。"
                )

                settingsToggleButton(
                    title: "メニューバーアイコンを隠す",
                    subtitle: "Accessibility権限が必要です。オフにすると全アイコンが即座に復元されます。",
                    isOn: menuBarManagerActive
                ) {
                    toggleMenuBarManagement()
                }

                if menuBarManagerActive {
                    Text("\(menuBarHiddenItemCount) 個のアイコンを非表示にしています")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }

                if !menuBarAccessibilityChecked {
                    Text("システム設定 → プライバシーとセキュリティ → アクセシビリティでPull Notchを許可してください")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func compactWidgetGroup(zone: CompactWidgetZone) -> some View {
        let items = overlayModel.widgetLayoutItems(for: zone)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: zoneIcon(zone))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(zoneAccent(zone))
                    .frame(width: 25, height: 25)

                Text(zone.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)

                Text(zoneDescription(zone))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.38))

                Spacer(minLength: 0)

                Text("\(items.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.44))
            }

            VStack(spacing: 0) {
                if items.isEmpty {
                    compactWidgetEmptyState(zone)
                } else {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        compactWidgetRow(item, zone: zone, index: index)
                        if index < items.count - 1 {
                            Rectangle()
                                .fill(Color.white.opacity(0.06))
                                .frame(height: 1)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .overlay(alignment: .trailing) {
            if zone != .hidden {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func compactWidgetRow(_ item: CompactWidgetLayoutItem, zone: CompactWidgetZone, index: Int) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text("\(index + 1)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.38))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(widgetIdentityLabel(item.identity))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.38))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                priorityButton("chevron.up") { overlayModel.moveCompactWidget(item.identity, in: zone, direction: .up) }
                    .disabled(!overlayModel.canMoveCompactWidget(item.identity, in: zone, direction: .up))

                priorityButton("chevron.down") { overlayModel.moveCompactWidget(item.identity, in: zone, direction: .down) }
                    .disabled(!overlayModel.canMoveCompactWidget(item.identity, in: zone, direction: .down))
            }

            HStack(spacing: 4) {
                if zone != .leading {
                    widgetMoveChip("arrow.left") { overlayModel.moveCompactWidget(item.identity, to: .leading) }
                }

                if zone != .trailing {
                    widgetMoveChip("arrow.right") { overlayModel.moveCompactWidget(item.identity, to: .trailing) }
                }

                if zone != .hidden {
                    widgetMoveChip("eye.slash", subtle: true) { overlayModel.moveCompactWidget(item.identity, to: .hidden) }
                }
            }
        }
        .padding(.vertical, 9)
    }

    private func compactWidgetEmptyState(_ zone: CompactWidgetZone) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: zone == .hidden ? "tray" : "rectangle.dashed")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(0.32))

            Text(zone == .hidden ? "Nothing hidden" : "No widgets here")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.62))

            Text(zone == .hidden ? "Hide buttons will move widgets into this area." : "Use Left/Right buttons on another card to fill this slot.")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.38))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
    }

    private func priorityButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.82))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
    }

    private func widgetMoveChip(_ systemName: String, subtle: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(subtle ? .white.opacity(0.48) : .white.opacity(0.78))
                .frame(width: 24, height: 22)
                .background(Capsule(style: .continuous).fill(Color.white.opacity(subtle ? 0.04 : 0.075)))
        }
        .buttonStyle(.plain)
    }

    private func zoneAccent(_ zone: CompactWidgetZone) -> Color {
        switch zone {
        case .leading:
            return Color(red: 0.45, green: 0.78, blue: 1.0)
        case .trailing:
            return Color(red: 0.72, green: 0.96, blue: 0.55)
        case .hidden:
            return Color.white.opacity(0.55)
        }
    }

    private func zonePanelFill(_ zone: CompactWidgetZone) -> Color {
        switch zone {
        case .leading:
            return Color.white.opacity(0.03)
        case .trailing:
            return Color.white.opacity(0.03)
        case .hidden:
            return Color.white.opacity(0.02)
        }
    }

    private func zoneIcon(_ zone: CompactWidgetZone) -> String {
        switch zone {
        case .leading:
            return "arrow.left.to.line.compact"
        case .trailing:
            return "arrow.right.to.line.compact"
        case .hidden:
            return "eye.slash.fill"
        }
    }

    private func zoneDescription(_ zone: CompactWidgetZone) -> String {
        switch zone {
        case .leading:
            return "左側に表示"
        case .trailing:
            return "右側に表示"
        case .hidden:
            return "表示しない"
        }
    }

    private func widgetIdentityLabel(_ identity: CompactWidgetIdentity) -> String {
        switch identity {
        case .builtIn:
            return "Built-in widget"
        case .plugin(let id):
            return id.components(separatedBy: "::").first.map { "Plugin: \($0)" } ?? "Plugin widget"
        }
    }

    private func settingsToggleButton(
        title: String,
        subtitle: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: settingSymbol(for: title))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isOn ? Color(red: 0.64, green: 0.8, blue: 1) : .white.opacity(0.38))
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)

                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Capsule()
                    .fill(isOn ? Color(red: 0.38, green: 0.66, blue: 1) : Color.white.opacity(0.11))
                    .frame(width: 42, height: 24)
                    .overlay(alignment: isOn ? .trailing : .leading) {
                        Circle()
                            .fill(.white)
                            .frame(width: 18, height: 18)
                            .padding(3)
                            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                    }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 9)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.white.opacity(0.055))
                    .frame(height: 1)
            }
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
        case .plugins:
            return "puzzlepiece.extension.fill"
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
        case .plugins:
            return "拡張機能"
        }
    }

    private func pageDescription(for tab: SettingsTab) -> String {
        switch tab {
        case .general:
            return "Core behavior, files, startup and menu bar controls"
        case .widgets:
            return "Build your compact notch and expanded dashboard"
        case .weather:
            return "Location source and forecast refresh settings"
        case .plugins:
            return "Manage installed extensions and their settings"
        }
    }

    private func settingSymbol(for title: String) -> String {
        switch title {
        case "Launch At Login": return "power"
        case "アートワークを表示": return "photo.fill"
        case "ビジュアライザーを表示": return "waveform"
        case "ビジュアライザーを動かす": return "waveform.badge.magnifyingglass"
        case "歌詞Toastを表示": return "quote.bubble.fill"
        case "メニューバーアイコンを隠す": return "menubar.arrow.up.rectangle"
        case "Enabled": return "power.circle.fill"
        default:
            if let feature = OverlayFeature.allCases.first(where: { $0.title == title }) {
                switch feature {
                case .nowPlaying: return "music.note"
                case .pinnedFile: return "pin.fill"
                case .battery: return "battery.100percent"
                case .weather: return "cloud.sun.fill"
                case .pomodoro: return "timer"
                case .reminders: return "checklist"
                case .systemStatus: return "gauge.with.dots.needle.50percent"
                case .volumeOverlay: return "speaker.wave.2.fill"
                case .hoverTitle: return "text.bubble.fill"
                }
            }
            return "slider.horizontal.3"
        }
    }

    private var pluginsSection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader(
                    title: "Plugins",
                    subtitle: "Application Support 内の bundle から読み込んだ plugin を管理します。"
                )

                if overlayModel.pluginRuntimeInfos.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "puzzlepiece.extension")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.32))

                        Text("No plugins loaded")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.72))

                        Text("Application Support に plugin bundle を置くと、ここに状態と設定が表示されます。")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 18)
                } else {
                    ForEach(overlayModel.pluginRuntimeInfos) { plugin in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 12) {
                                Image(systemName: "puzzlepiece.extension.fill")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(plugin.state == .loaded ? Color.green.opacity(0.9) : .white.opacity(0.52))
                                    .frame(width: 38, height: 38)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(plugin.displayName)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.white)

                                    Text("v\(plugin.version) • \(plugin.state.rawValue.capitalized)")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.48))
                                }

                                Spacer(minLength: 0)

                                Capsule()
                                    .fill(plugin.state == .loaded ? Color.green.opacity(0.18) : Color.white.opacity(0.08))
                                    .overlay {
                                        Text(plugin.state == .loaded ? "Loaded" : plugin.state == .disabled ? "Disabled" : "Failed")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(plugin.state == .loaded ? Color.green.opacity(0.9) : .white.opacity(0.72))
                                    }
                                    .frame(width: 72, height: 24)
                            }

                            if let errorMessage = plugin.errorMessage {
                                Text(errorMessage)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.red.opacity(0.9))
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            settingsToggleButton(
                                title: "Enabled",
                                subtitle: plugin.bundlePath,
                                isOn: plugin.state != .disabled
                            ) {
                                overlayModel.setPluginEnabled(plugin.id, isEnabled: plugin.state == .disabled)
                            }

                            let sections = overlayModel.settingsSectionsForPlugin(plugin.id)
                            ForEach(sections) { section in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(section.title)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.88))

                                    if let subtitle = section.subtitle {
                                        Text(subtitle)
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.white.opacity(0.46))
                                            .fixedSize(horizontal: false, vertical: true)
                                    }

                                    section.render()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .overlay(alignment: .bottom) {
                                    Rectangle().fill(Color.white.opacity(0.055)).frame(height: 1)
                                }
                            }
                        }
                        .padding(.vertical, 12)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
                        }
                    }
                }
            }
        }
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.white.opacity(0.075))
                    .frame(height: 1)
            }
    }

    private func sectionHeader(title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: sectionSymbol(for: title))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(red: 0.62, green: 0.78, blue: 1))
                .frame(width: 31, height: 31)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)

                Text(subtitle)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.43))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sectionSymbol(for title: String) -> String {
        switch title {
        case "Features": return "switch.2"
        case "Pinned File Shelf": return "pin.square.fill"
        case "Menu Bar": return "menubar.rectangle"
        case "Weather Location": return "location.fill"
        case "Now Playing": return "music.note.house.fill"
        case "Toast": return "rectangle.and.text.magnifyingglass"
        case "Expanded Widget Board": return "rectangle.split.2x1.fill"
        case "Today Tasks": return "checklist"
        case "Compact Widgets": return "capsule.fill"
        case "Plugins": return "puzzlepiece.extension.fill"
        case "Visualizer Source": return "waveform.path"
        default: return "slider.horizontal.3"
        }
    }

    private func buttonChip(_ title: String, emphasized: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(emphasized ? 0.96 : 0.76))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(emphasized ? Color(red: 0.36, green: 0.64, blue: 1) : Color.white.opacity(0.07))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(emphasized ? 0.08 : 0.08), lineWidth: 1)
                    )
            )
    }
}

@Observable
// Coordinates focused state models while preserving the API consumed by the
// app delegate, settings UI, content view, monitors, and plugin bridge.
final class NotchOverlayModel {
    static let layoutDidChangeNotification = Notification.Name("NotchOverlayModel.layoutDidChange")

    private let lyricsModel = LyricsModel(loader: LyricsService())
    private let nowPlayingModel = NowPlayingModel()
    private let pomodoroModel = PomodoroModel()
    private let widgetLayoutStore = WidgetLayoutStore()
    private let dashboardWidgetLayoutStore = DashboardWidgetLayoutStore()
    let calendarWidgetModel = CalendarWidgetModel()
    let reminderWidgetModel = ReminderWidgetModel()
    let systemStatusModel = SystemStatusModel()
    private let pluginHostStore = PluginHostStore()
    private let preferencesStore = OverlayPreferencesStore()
    private let pinnedFileShelfStore = PinnedFileShelfStore()
    private let artworkPaletteExtractor = ArtworkPaletteExtractor()
    private let volumeOverlayModel = VolumeOverlayModel()
    private let temporaryWidgetStore = TemporaryWidgetStore()
    private let transientPresentationModel = TransientPresentationModel()
    private let batteryModel = BatteryModel()
    private let expandedPageNavigationModel = ExpandedPageNavigationModel()
    private let compactWidgetFactory = CompactWidgetFactory()
    private let expandedPageCatalog = ExpandedPageCatalog()
    private let notchLayoutModel = NotchLayoutModel()
    private let launchAtLoginModel = LaunchAtLoginModel()

    private(set) var visualizerBrightColor: Color = .white.opacity(0.92)
    private(set) var visualizerDarkColor: Color = .white.opacity(0.6)
    private(set) var compactWidgets: [CompactIslandWidget] = []
    private(set) var weatherTemperatureText: String?
    private(set) var weatherSymbolName: String?
    private(set) var weatherForecast: [WeatherForecastDay] = []
    private(set) var weatherLocationStatusMessage: String?
    private(set) var weatherLocationStatusColor: Color = .white.opacity(0.55)
    private(set) var liveVisualizerHeights: [CGFloat] = Array(repeating: 5, count: 6)
    private(set) var realVisualizerIsAvailable = false
    private(set) var pinnedFileStatusMessage: String?
    private(set) var expandedPanel: ExpandedIslandPanel?
    private(set) var displayMode: NotchOverlayDisplayMode = .macDisplay
    private weak var pluginManager: PluginManager?
    @ObservationIgnored private var pinnedFileStatusTask: Task<Void, Never>?
    var mediaControlHandler: ((MediaControlCommand) -> Void)?
    var settingsWindowHandler: (() -> Void)?
    var weatherLocationUpdateHandler: ((String?) -> Void)?
    var sharePinnedFileHandler: ((URL) -> Void)?
    var quickLookPinnedFileHandler: ((URL) -> Void)?
    var choosePinnedFilesHandler: (() -> Void)?
    var refreshWeatherHandler: (() -> Void)?
    var visualizerModeChangeHandler: ((NowPlayingVisualizerMode) -> Void)?

    init() {
        lyricsModel.onUpdate = { [weak self] in
            self?.notifyLayoutChange()
        }
        pluginHostStore.onChange = { [weak self] change in
            self?.handlePluginHostChange(change)
        }
        volumeOverlayModel.onUpdate = { [weak self] in
            self?.handleVolumeOverlayUpdate()
        }
        temporaryWidgetStore.onUpdate = { [weak self] in
            self?.handleTemporaryWidgetUpdate()
        }
        transientPresentationModel.onUpdate = { [weak self] in
            self?.notifyLayoutChange()
        }
        pomodoroModel.onUpdate = { [weak self] in
            self?.handlePomodoroUpdate()
        }
        pomodoroModel.onPhaseTransition = { [weak self] in
            self?.perform(.alignment)
            self?.playPomodoroTransitionSound()
        }
        reminderWidgetModel.onUpdate = { [weak self] in
            self?.refreshCompactWidgets()
            self?.notifyLayoutChange()
        }
        systemStatusModel.onUpdate = { [weak self] in
            self?.refreshCompactWidgets()
            self?.notifyLayoutChange()
        }
        if isFeatureEnabled(.systemStatus) {
            systemStatusModel.start()
        }
        launchAtLoginModel.refresh()
    }

    var pomodoroPhase: PomodoroPhase { pomodoroModel.phase }
    var pomodoroRemainingSeconds: Int { pomodoroModel.remainingSeconds }
    var pomodoroIsRunning: Bool { pomodoroModel.isRunning }
    var compactWidgetLayout: CompactWidgetLayout { widgetLayoutStore.layout }
    var dashboardWidgetLayout: DashboardWidgetLayout { dashboardWidgetLayoutStore.layout }
    var syncedLyrics: [SyncedLyricLine] { lyricsModel.syncedLyrics }
    var plainLyricsText: String? { lyricsModel.plainLyricsText }
    var lyricsLoadState: LyricsLoadState { lyricsModel.loadState }
    var lyricsProvider: LyricsProvider? { lyricsModel.provider }
    var pluginWidgets: [PluginWidgetDescriptor] { pluginHostStore.widgets }
    var pluginExpandedPageDescriptors: [PluginExpandedPageDescriptor] { pluginHostStore.expandedPages }
    var pluginDashboardWidgets: [PluginDashboardWidgetDescriptor] { pluginHostStore.dashboardWidgets }
    var pluginRuntimeInfos: [PluginRuntimeInfo] { pluginHostStore.runtimeInfos }
    var pluginSettingsSections: [PluginSettingsSectionDescriptor] { pluginHostStore.settingsSections }
    var manualWeatherLocation: String? { preferencesStore.manualWeatherLocation }
    var pinnedFiles: [PinnedFileItem] { pinnedFileShelfStore.items }
    var selectedPinnedFileID: UUID? { pinnedFileShelfStore.selectedID }
    var selectedPinnedFile: PinnedFileItem? { pinnedFileShelfStore.selectedItem }
    var pinnedFileURL: URL? { selectedPinnedFile?.url }
    var maximumPinnedFileCount: Int { PinnedFileShelfStore.maximumItemCount }
    var nowPlayingShowsArtwork: Bool { preferencesStore.nowPlayingShowsArtwork }
    var nowPlayingShowsVisualizer: Bool { preferencesStore.nowPlayingShowsVisualizer }
    var nowPlayingAnimatesVisualizer: Bool { preferencesStore.nowPlayingAnimatesVisualizer }
    var nowPlayingVisualizerMode: NowPlayingVisualizerMode { preferencesStore.nowPlayingVisualizerMode }
    var toastShowsLyrics: Bool { preferencesStore.toastShowsLyrics }
    var currentPresentation: IslandPresentation? { nowPlayingModel.currentPresentation }
    var detailLine: String? { nowPlayingModel.detailLine }
    var isPlaying: Bool { nowPlayingModel.isPlaying }
    var nowPlayingDurationSeconds: TimeInterval? { nowPlayingModel.durationSeconds }
    var nowPlayingPlaybackPositionSeconds: TimeInterval { nowPlayingModel.playbackPositionSeconds }
    var nowPlayingPlaybackPositionUpdatedAt: Date? { nowPlayingModel.playbackPositionUpdatedAt }
    var sourceApp: String? { nowPlayingModel.sourceApp }
    var albumName: String? { nowPlayingModel.albumName }
    var artworkData: Data? { nowPlayingModel.artworkData }
    var nowPlayingTitle: String? { nowPlayingModel.title }
    var nowPlayingArtist: String? { nowPlayingModel.artist }
    var showsVolumeChange: Bool { volumeOverlayModel.isVisible }
    var volumeLevel: Double { volumeOverlayModel.level }
    var volumeOutputDeviceName: String? { volumeOverlayModel.outputDeviceName }
    var temporaryCompactWidgets: [CompactWidgetPlacement: CompactIslandWidget] { temporaryWidgetStore.widgets }
    var showsTrackChange: Bool { transientPresentationModel.showsTrackChange }
    var showsTrackText: Bool { transientPresentationModel.showsTrackText }
    var showsHoverChange: Bool { transientPresentationModel.showsHoverChange }
    var showsHoverText: Bool { transientPresentationModel.showsHoverText }
    var toastLyricsDismissed: Bool { transientPresentationModel.toastLyricsDismissed }
    var pluginStatusMessage: String? { transientPresentationModel.pluginStatusMessage }
    var showsPluginStatus: Bool { transientPresentationModel.showsPluginStatus }
    var batteryLevel: Int? { batteryModel.level }
    var batterySymbolName: String { batteryModel.symbolName ?? "battery.0percent" }
    var batteryIsCharging: Bool { batteryModel.isCharging }
    var chargingPowerWatts: Double? { batteryModel.chargingWatts }
    var accessoryBatteryDevices: [AccessoryBatteryDevice] { batteryModel.accessoryDevices }
    var currentExpandedPageID: String? { expandedPageNavigationModel.currentPageID }
    var expandedPageNavigationDirection: ExpandedPageNavigationDirection { expandedPageNavigationModel.direction }
    var externalCompactHeight: CGFloat { notchLayoutModel.configuration.externalCompactHeight }
    var launchAtLoginEnabled: Bool { launchAtLoginModel.isEnabled }
    var launchAtLoginStatusText: String { launchAtLoginModel.statusText }
    var reminderAccessState: ReminderAccessState { reminderWidgetModel.accessState }
    var reminderLists: [ReminderListItem] { reminderWidgetModel.lists }
    var todayReminderItems: [ReminderWidgetItem] { reminderWidgetModel.items }
    var reminderErrorMessage: String? { reminderWidgetModel.errorMessage }
    var systemStatusSnapshot: SystemStatusSnapshot { systemStatusModel.snapshot }

    var compactVisibleWidth: CGFloat {
        compactLayoutMetrics.visibleWidth
    }

    var visibleWidth: CGFloat {
        notchLayoutSnapshot.visibleWidth
    }

    var panelContentWidth: CGFloat {
        notchLayoutSnapshot.panelContentWidth
    }

    var usesExternalCompactLayout: Bool {
        notchLayoutSnapshot.usesExternalCompactLayout
    }

    var compactBarHeight: CGFloat {
        notchLayoutSnapshot.compactBarHeight
    }

    var effectiveWindowTopInset: CGFloat {
        notchLayoutSnapshot.effectiveWindowTopInset
    }

    var effectiveWindowBottomInset: CGFloat {
        notchLayoutSnapshot.effectiveWindowBottomInset
    }

    var showsToastLyrics: Bool {
        toastShowsLyrics
            && !toastLyricsDismissed
            && isPlaying
            && isFeatureEnabled(.nowPlaying)
            && currentPresentation != nil
            && expandedPanel == nil
            && !showsVolumeChange
            && !showsPluginStatus
            && !showsBatteryLowWarning
    }

    var compactCenterSpacing: CGFloat {
        compactLayoutMetrics.centerSpacing
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
        notchLayoutSnapshot.currentIslandHeight
    }

    var panelSize: CGSize {
        notchLayoutSnapshot.panelSize
    }

    var expandedWidgetPages: [ExpandedPageDescriptor] {
        expandedPageCatalog.pages(
            state: expandedPageCatalogState,
            pluginPages: pluginExpandedPageDescriptors
        )
    }

    var activeExpandedWidgetPage: ExpandedPageDescriptor? {
        expandedPageCatalog.activePage(
            currentPageID: currentExpandedPageID,
            in: expandedWidgetPages
        )
    }

    var activeExpandedBuiltInPage: ExpandedWidgetPageKind? {
        expandedPageCatalog.activeBuiltInPage(
            currentPageID: currentExpandedPageID,
            in: expandedWidgetPages
        )
    }

    private var expandedMaxPreferredWidth: CGFloat {
        expandedPageCatalog.maximumPreferredWidth(
            for: expandedWidgetPages,
            state: expandedPageCatalogState
        )
    }

    func estimatedPlaybackPosition(at date: Date = .now) -> TimeInterval {
        nowPlayingModel.estimatedPlaybackPosition(at: date)
    }

    func activeLyricLineIndex(at date: Date = .now) -> Int? {
        lyricsModel.activeLineIndex(at: estimatedPlaybackPosition(at: date))
    }

    func visibleLyricsLines(at date: Date = .now) -> [(line: SyncedLyricLine, isActive: Bool, isContext: Bool)] {
        lyricsModel.visibleLines(at: estimatedPlaybackPosition(at: date))
    }

    var lyricsStatusText: String {
        lyricsModel.statusText
    }

    var lyricsFallbackPreviewText: String? {
        lyricsModel.fallbackPreviewText
    }

    func toastLyricsText(at date: Date = .now) -> String? {
        lyricsModel.toastText(
            at: estimatedPlaybackPosition(at: date),
            fallbackDetail: detailLine
        )
    }

    func updateNowPlaying(track: AppleMusicTrack) {
        guard isFeatureEnabled(.nowPlaying) else { return }

        let shouldReveal = nowPlayingModel.update(track: track)
        guard let presentation = nowPlayingModel.currentPresentation else { return }
        updateVisualizerPalette(from: presentation.artworkData)
        refreshCompactWidgets()
        finishPresentingNowPlaying(
            revealChange: shouldReveal,
            hapticFeedback: shouldReveal ? .generic : nil
        )

        lyricsModel.update(
            for: LyricsTrackMetadata(
                trackName: track.title,
                artistName: track.artist,
                albumName: track.album,
                durationSeconds: track.durationSeconds
            )
        )

        pluginHostStore.updateNowPlayingSnapshot(pluginNowPlayingSnapshot)
    }

    func present(
        _ presentation: IslandPresentation,
        revealChange: Bool = true,
        hapticFeedback: IslandHapticFeedback? = nil
    ) {
        nowPlayingModel.present(presentation)
        updateVisualizerPalette(from: presentation.artworkData)
        refreshCompactWidgets()
        finishPresentingNowPlaying(
            revealChange: revealChange,
            hapticFeedback: hapticFeedback
        )
    }

    private func finishPresentingNowPlaying(
        revealChange: Bool,
        hapticFeedback: IslandHapticFeedback?
    ) {
        if revealChange {
            if let hapticFeedback {
                perform(hapticFeedback)
            }
            showTrackChangeTemporarily()
        } else {
            notifyLayoutChange()
        }
    }

    func setDisplayMode(_ mode: NotchOverlayDisplayMode) {
        guard displayMode != mode else { return }
        displayMode = mode
        notifyLayoutChange()
    }

    func showTrackChangeTemporarily() {
        guard expandedPanel == nil else {
            notifyLayoutChange()
            return
        }
        guard !showsVolumeChange else {
            notifyLayoutChange()
            return
        }
        transientPresentationModel.showTrackChange()
    }

    @discardableResult
    func dismissToastIfVisible() -> Bool {
        transientPresentationModel.dismissToast(
            lyricsToastIsVisible: showsToastLyrics,
            toastLyricsEnabled: toastShowsLyrics
        )
    }

    @discardableResult
    func handleToastSpaceKey() -> Bool {
        transientPresentationModel.handleSpaceKey(
            lyricsToastIsVisible: showsToastLyrics,
            toastLyricsEnabled: toastShowsLyrics
        )
    }

    func clearNowPlaying() {
        nowPlayingModel.clear()
        resetVisualizerPalette()
        lyricsModel.reset()
        transientPresentationModel.reset()
        ensureExpandedWidgetPage()
        refreshCompactWidgets()
        pluginHostStore.updateNowPlayingSnapshot(nil)
        notifyLayoutChange()
    }

    func activateNowPlayingApp() {
        guard let sourceApp, sourceApp != "unknown" else { return }
        guard let runningApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == sourceApp }) else { return }
        runningApp.unhide()
        runningApp.activate(options: [.activateAllWindows])
    }

    func toggleMusicPlayer() {
        guard expandedPanel != .onboarding else { return }

        if expandedPanel == .musicPlayer {
            expandedPanel = nil
        } else {
            pinnedFileShelfStore.refresh()
            expandedPanel = .musicPlayer
            ensureExpandedWidgetPage()
            dismissVolumeOverlay()
            transientPresentationModel.hideTrackAndPluginStatus()
            perform(.generic)
        }

        notifyLayoutChange()
    }

    func dismissExpandedPanel() {
        guard expandedPanel != nil, expandedPanel != .onboarding else { return }
        expandedPanel = nil
        transientPresentationModel.hidePluginStatusAndHover()
        notifyLayoutChange()
    }

    func openSettingsWindow() {
        guard expandedPanel != .onboarding else { return }
        expandedPanel = nil
        dismissVolumeOverlay()
        transientPresentationModel.reset()
        perform(.generic)
        settingsWindowHandler?()
        notifyLayoutChange()
    }

    func presentOnboardingIfNeeded() {
        guard !preferencesStore.hasShownOnboarding else { return }
        expandedPanel = .onboarding
        notifyLayoutChange()
    }

    func completeOnboarding() {
        preferencesStore.completeOnboarding()
        if expandedPanel == .onboarding {
            expandedPanel = nil
            refreshCompactWidgets()
            notifyLayoutChange()
        }
    }

    func setHoverTitleVisible(_ isVisible: Bool) {
        guard isFeatureEnabled(.hoverTitle) else { return }
        transientPresentationModel.setHoverVisible(
            isVisible,
            canShow: expandedPanel == nil
                && !showsTrackChange
                && !showsVolumeChange
                && !showsPluginStatus
                && currentPresentation != nil
        )
    }

    func showVolume(level: Double, outputDeviceName: String?) {
        guard isFeatureEnabled(.volumeOverlay) else { return }
        guard expandedPanel == nil else { return }

        transientPresentationModel.hideForVolume()
        volumeOverlayModel.show(level: level, outputDeviceName: outputDeviceName)
        let currentLevel = volumeLevel
        let currentDevice = volumeOutputDeviceName
        pluginHostStore.updateVolumeSnapshot(
            PluginVolumeSnapshot(level: currentLevel, outputDeviceName: currentDevice)
        )
    }

    private func handleVolumeOverlayUpdate() {
        pluginHostStore.synchronizeVolumeSnapshot(
            PluginVolumeSnapshot(level: volumeLevel, outputDeviceName: volumeOutputDeviceName)
        )
        notifyLayoutChange()
    }

    func send(_ command: MediaControlCommand) {
        mediaControlHandler?(command)
        perform(.generic)
    }

    func updateBattery(
        level: Int?,
        isCharging: Bool,
        chargingWatts: Double?
    ) {
        let update = batteryModel.update(
            level: level,
            isCharging: isCharging,
            chargingWatts: chargingWatts,
            canShowChargingPower: expandedPanel == nil && isFeatureEnabled(.battery)
        )
        var needsWidgetRefresh = update.didChange

        if update.shouldShowChargingPower {
            showChargingPowerIndicator()
            needsWidgetRefresh = true
        } else if update.shouldClearChargingPower,
                  temporaryCompactWidgets[.trailing]?.identity == .builtIn(.chargingPower) {
            clearTemporaryCompactWidget(for: .trailing, identity: .builtIn(.chargingPower))
            needsWidgetRefresh = true
        }

        guard needsWidgetRefresh else { return }
        refreshCompactWidgets()
        notifyLayoutChange()
    }

    func updateAccessoryBatteries(_ devices: [AccessoryBatteryDevice]) {
        guard batteryModel.updateAccessoryDevices(devices) else { return }
        refreshCompactWidgets()
        notifyLayoutChange()
    }

    func updateWeather(
        temperatureText: String?,
        symbolName: String?,
        forecast: [WeatherForecastDay] = []
    ) {
        weatherTemperatureText = temperatureText
        weatherSymbolName = symbolName
        weatherForecast = forecast
        ensureExpandedWidgetPage()
        refreshCompactWidgets()
        pluginHostStore.updateWeatherSnapshot(pluginWeatherSnapshot)
        notifyLayoutChange()
    }

    func setManualWeatherLocation(_ location: String?) {
        let trimmedLocation = preferencesStore.setManualWeatherLocation(location)
        if let trimmedLocation {
            weatherLocationStatusMessage = "'\(trimmedLocation)' の天気を取得中..."
            weatherLocationStatusColor = .white.opacity(0.58)
        } else {
            weatherLocationStatusMessage = nil
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
        preferencesStore.setNowPlayingArtworkVisible(isVisible)
        refreshCompactWidgets()
        notifyLayoutChange()
    }

    func setNowPlayingVisualizerVisible(_ isVisible: Bool) {
        preferencesStore.setNowPlayingVisualizerVisible(isVisible)
        refreshCompactWidgets()
        notifyLayoutChange()
    }

    func setNowPlayingVisualizerAnimated(_ isAnimated: Bool) {
        preferencesStore.setNowPlayingVisualizerAnimated(isAnimated)
        refreshCompactWidgets()
        notifyLayoutChange()
    }

    func setNowPlayingVisualizerMode(_ mode: NowPlayingVisualizerMode) {
        guard nowPlayingVisualizerMode != mode else { return }
        preferencesStore.setNowPlayingVisualizerMode(mode)
        if mode == .fake {
            updateLiveVisualizerLevels(Array(repeating: 5, count: 6), isAvailable: false)
        }
        visualizerModeChangeHandler?(mode)
    }

    func setToastLyricsVisible(_ isVisible: Bool) {
        preferencesStore.setToastLyricsVisible(isVisible)
        transientPresentationModel.setToastLyricsVisible(isVisible)
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
        launchAtLoginModel.setEnabled(isEnabled)
        notifyLayoutChange()
    }

    @discardableResult
    func pinFiles(_ urls: [URL]) -> PinnedFileAddResult {
        let result = pinnedFileShelfStore.add(urls)
        ensureExpandedWidgetPage()
        refreshCompactWidgets()
        perform(.generic)
        notifyLayoutChange()
        if result.rejectedCount > 0 {
            let message = "Shelf full — \(result.rejectedCount) item(s) were not added"
            showPinnedFileStatus(message)
            if expandedPanel == nil {
                showPluginStatus(message: message, duration: 3)
            }
        } else if result.addedCount > 0 {
            showPinnedFileStatus("Added \(result.addedCount) item(s)")
        } else if result.duplicateCount > 0 {
            showPinnedFileStatus("Already pinned — selected existing item")
        }
        return result
    }

    func pinFile(_ url: URL) {
        pinFiles([url])
    }

    func selectPinnedFile(id: UUID) {
        pinnedFileShelfStore.select(id: id)
        refreshCompactWidgets()
        notifyLayoutChange()
    }

    func movePinnedFile(id: UUID, before targetID: UUID) {
        pinnedFileShelfStore.move(id: id, before: targetID)
        notifyLayoutChange()
    }

    func removePinnedFile(id: UUID) {
        pinnedFileShelfStore.remove(id: id)
        ensureExpandedWidgetPage()
        refreshCompactWidgets()
        notifyLayoutChange()
    }

    func clearPinnedFile() {
        clearPinnedFiles()
    }

    func clearPinnedFiles() {
        pinnedFileShelfStore.clear()
        ensureExpandedWidgetPage()
        refreshCompactWidgets()
        notifyLayoutChange()
    }

    func sharePinnedFile() {
        guard let pinnedFileURL, selectedPinnedFile?.isAvailable == true else { return }
        sharePinnedFileHandler?(pinnedFileURL)
    }

    func quickLookPinnedFile() {
        guard let pinnedFileURL, selectedPinnedFile?.isAvailable == true else { return }
        quickLookPinnedFileHandler?(pinnedFileURL)
    }

    func choosePinnedFiles() {
        choosePinnedFilesHandler?()
    }

    private func showPinnedFileStatus(_ message: String) {
        pinnedFileStatusTask?.cancel()
        pinnedFileStatusMessage = message
        notifyLayoutChange()
        pinnedFileStatusTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            self.pinnedFileStatusMessage = nil
            self.pinnedFileStatusTask = nil
            self.notifyLayoutChange()
        }
    }

    func refreshWeather() {
        refreshWeatherHandler?()
    }

    func togglePomodoroRunning() {
        pomodoroModel.toggle()
        perform(.generic)
    }

    func resetPomodoro() {
        pomodoroModel.reset()
    }

    func skipPomodoroPhase() {
        pomodoroModel.skip()
        perform(.generic)
    }

    func completeReminder(id: String) {
        reminderWidgetModel.complete(id: id)
    }

    func setReminderListEnabled(id: String, isEnabled: Bool) {
        reminderWidgetModel.setListEnabled(id: id, isEnabled: isEnabled)
    }

    func isReminderListEnabled(id: String) -> Bool {
        reminderWidgetModel.isListEnabled(id: id)
    }

    func requestReminderAccess() async {
        await reminderWidgetModel.requestAccess()
    }

    func openReminderPrivacySettings() {
        reminderWidgetModel.openSystemSettings()
    }

    func selectExpandedWidgetPage(_ page: ExpandedWidgetPageKind) {
        guard let descriptor = expandedWidgetPages.first(where: {
            if case .builtIn(let builtInPage) = $0.source {
                return builtInPage == page
            }
            return false
        }) else { return }
        selectExpandedWidgetPage(id: descriptor.id)
    }

    func selectExpandedWidgetPage(id: String) {
        guard expandedPageNavigationModel.select(pageID: id, in: expandedWidgetPageIDs) else { return }
        notifyLayoutChange()
    }

    func showPreviousExpandedWidgetPage() {
        guard expandedPageNavigationModel.selectPrevious(in: expandedWidgetPageIDs) else { return }
        notifyLayoutChange()
    }

    func showNextExpandedWidgetPage() {
        guard expandedPageNavigationModel.selectNext(in: expandedWidgetPageIDs) else { return }
        notifyLayoutChange()
    }

    func dashboardWidgetIdentity(for slot: DashboardWidgetSlot) -> DashboardWidgetIdentity {
        dashboardWidgetLayout[slot]
    }

    func selectDashboardWidget(_ identity: DashboardWidgetIdentity, for slot: DashboardWidgetSlot) {
        dashboardWidgetLayoutStore.select(identity, for: slot)
        notifyLayoutChange()
    }

    func dashboardWidgetTitle(_ identity: DashboardWidgetIdentity) -> String {
        switch identity {
        case .builtIn(let kind):
            return kind.title
        case .plugin(let id):
            return pluginDashboardWidgets.first(where: { $0.id == id })?.title
                ?? id.components(separatedBy: "::").last
                ?? "Plugin Widget"
        }
    }

    func dashboardWidgetSymbol(_ identity: DashboardWidgetIdentity) -> String {
        switch identity {
        case .builtIn(let kind): return kind.symbolName
        case .plugin(let id):
            return pluginDashboardWidgets.first(where: { $0.id == id })?.symbolName ?? "puzzlepiece.extension"
        }
    }

    func isDashboardWidgetAvailable(_ identity: DashboardWidgetIdentity) -> Bool {
        switch identity {
        case .builtIn:
            return true
        case .plugin(let id):
            return pluginDashboardWidgets.contains { $0.id == id }
        }
    }

    var availableDashboardWidgets: [DashboardWidgetIdentity] {
        BuiltInDashboardWidgetKind.allCases.map(DashboardWidgetIdentity.builtIn)
            + pluginDashboardWidgets
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                .map { .plugin($0.id) }
    }

    func widgetLayoutItems(for zone: CompactWidgetZone) -> [CompactWidgetLayoutItem] {
        compactWidgetLayout[zone].compactMap { identity in
            guard let title = compactWidgetFactory.title(for: identity, pluginWidgets: pluginWidgets) else { return nil }
            return CompactWidgetLayoutItem(
                id: "\(zone.storageKey).\(identity.storageToken)",
                identity: identity,
                title: title,
                zone: zone
            )
        }
    }

    func canMoveCompactWidget(_ identity: CompactWidgetIdentity, in zone: CompactWidgetZone, direction: MoveDirection) -> Bool {
        widgetLayoutStore.canMove(identity, in: zone, direction: direction)
    }

    func moveCompactWidget(_ identity: CompactWidgetIdentity, in zone: CompactWidgetZone, direction: MoveDirection) {
        guard widgetLayoutStore.move(identity, in: zone, direction: direction) else { return }
        refreshCompactWidgets()
        notifyLayoutChange()
    }

    func moveCompactWidget(_ identity: CompactWidgetIdentity, to targetZone: CompactWidgetZone) {
        guard widgetLayoutStore.move(identity, to: targetZone) else { return }
        refreshCompactWidgets()
        notifyLayoutChange()
    }

    func isFeatureEnabled(_ feature: OverlayFeature) -> Bool {
        preferencesStore.isFeatureEnabled(feature)
    }

    func setFeatureEnabled(_ feature: OverlayFeature, isEnabled: Bool) {
        preferencesStore.setFeatureEnabled(feature, isEnabled: isEnabled)

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
            if !isEnabled {
                clearTemporaryCompactWidget(for: .trailing, identity: .builtIn(.chargingPower))
            }
            refreshCompactWidgets()
        case .weather:
            refreshCompactWidgets()
        case .pomodoro:
            if !isEnabled, activeExpandedBuiltInPage == .pomodoro, expandedPanel == .musicPlayer {
                ensureExpandedWidgetPage()
            }
            refreshCompactWidgets()
        case .reminders:
            if isEnabled {
                reminderWidgetModel.refresh()
            }
            refreshCompactWidgets()
        case .systemStatus:
            if isEnabled {
                systemStatusModel.start()
            } else {
                systemStatusModel.stop()
            }
            refreshCompactWidgets()
        case .volumeOverlay:
            if !isEnabled {
                dismissVolumeOverlay()
            }
        case .hoverTitle:
            if !isEnabled {
                transientPresentationModel.disableHover()
            }
        }

        notifyLayoutChange()
    }

    private func notifyLayoutChange() {
        NotificationCenter.default.post(name: Self.layoutDidChangeNotification, object: self)
    }

    private func refreshCompactWidgets() {
        let state = compactWidgetFactoryState
        let leading = temporaryCompactWidgets[.leading]
            ?? compactWidgetFactory.firstAvailableWidget(
                identities: widgetLayoutStore.layout[.leading],
                placement: .leading,
                state: state,
                pluginWidgets: pluginWidgets
            )
        let trailing = temporaryCompactWidgets[.trailing]
            ?? compactWidgetFactory.firstAvailableWidget(
                identities: widgetLayoutStore.layout[.trailing],
                placement: .trailing,
                state: state,
                pluginWidgets: pluginWidgets
            )

        compactWidgets = [leading, trailing].compactMap { $0 }
    }

    private func ensureExpandedWidgetPage() {
        expandedPageNavigationModel.synchronize(pageIDs: expandedWidgetPageIDs)
    }

    private var expandedWidgetPageIDs: [String] {
        expandedWidgetPages.map(\.id)
    }

    private var compactLayoutMetrics: NotchCompactLayoutMetrics {
        notchLayoutModel.compactMetrics(
            leadingStyle: leadingWidget?.style,
            leadingWidth: leadingWidgetWidth,
            trailingStyle: trailingWidget?.style,
            trailingWidth: trailingWidgetWidth
        )
    }

    private var notchLayoutSnapshot: NotchLayoutSnapshot {
        notchLayoutModel.snapshot(for: notchLayoutState)
    }

    private var notchLayoutState: NotchLayoutState {
        let pages = expandedWidgetPages
        let activeBuiltInPage = expandedPageCatalog.activeBuiltInPage(
            currentPageID: currentExpandedPageID,
            in: pages
        )
        return NotchLayoutState(
            displayMode: displayMode,
            expandedPanel: expandedPanel,
            activeExpandedBuiltInPage: activeBuiltInPage,
            hasExpandedPages: !pages.isEmpty,
            expandedMaximumPreferredWidth: expandedMaxPreferredWidth,
            leadingWidgetStyle: leadingWidget?.style,
            leadingWidgetWidth: leadingWidgetWidth,
            trailingWidgetStyle: trailingWidget?.style,
            trailingWidgetWidth: trailingWidgetWidth,
            showsBatteryLowWarning: showsBatteryLowWarning,
            showsVolumeChange: showsVolumeChange,
            showsPluginStatus: showsPluginStatus,
            showsHoverChange: showsHoverChange,
            showsTrackChange: showsTrackChange,
            showsToastLyrics: showsToastLyrics
        )
    }

    private var expandedPageCatalogState: ExpandedPageCatalogState {
        ExpandedPageCatalogState(
            compactWidth: compactLayoutMetrics.visibleWidth,
            nowPlaying: .init(
                isAvailable: currentPresentation != nil,
                title: nowPlayingModel.title,
                artist: nowPlayingModel.artist,
                sourceApp: sourceApp
            ),
            pinnedFile: .init(
                isEnabled: isFeatureEnabled(.pinnedFile),
                selectedDisplayName: selectedPinnedFile?.displayName,
                selectedParentPath: selectedPinnedFile?.parentPath,
                count: pinnedFiles.count
            ),
            weather: .init(
                isEnabled: isFeatureEnabled(.weather),
                temperatureText: weatherTemperatureText,
                location: manualWeatherLocation
            ),
            pomodoro: .init(
                isEnabled: isFeatureEnabled(.pomodoro),
                timeText: pomodoroTimeText,
                phaseTitle: pomodoroPhase.title
            )
        )
    }

    private var compactWidgetFactoryState: CompactWidgetFactoryState {
        CompactWidgetFactoryState(
            pinnedFile: .init(
                isEnabled: isFeatureEnabled(.pinnedFile),
                selectedURL: pinnedFileURL,
                selectedDisplayName: selectedPinnedFile?.displayName,
                count: pinnedFiles.count
            ),
            nowPlaying: .init(
                isEnabled: isFeatureEnabled(.nowPlaying),
                isAvailable: currentPresentation != nil,
                showsArtwork: nowPlayingShowsArtwork,
                artworkData: artworkData,
                showsVisualizer: nowPlayingShowsVisualizer,
                animatesVisualizer: nowPlayingAnimatesVisualizer,
                isPlaying: isPlaying
            ),
            battery: .init(
                isEnabled: isFeatureEnabled(.battery),
                level: batteryLevel ?? accessoryBatteryDevices.first?.level,
                symbolName: batteryModel.symbolName ?? accessoryBatteryDevices.first?.symbolName,
                chargingPowerText: chargingPowerText
            ),
            weather: .init(
                isEnabled: isFeatureEnabled(.weather),
                temperatureText: weatherTemperatureText,
                symbolName: weatherSymbolName
            ),
            pomodoro: .init(
                isEnabled: isFeatureEnabled(.pomodoro),
                symbolName: pomodoroPhase.symbolName,
                progress: pomodoroProgress,
                isRunning: pomodoroIsRunning,
                remainingSeconds: pomodoroRemainingSeconds,
                timeText: pomodoroTimeText
            ),
            reminders: .init(
                isEnabled: isFeatureEnabled(.reminders),
                isAuthorized: reminderAccessState == .authorized,
                remainingCount: reminderWidgetModel.remainingCount,
                overdueCount: reminderWidgetModel.overdueCount
            ),
            systemStatus: .init(
                isEnabled: isFeatureEnabled(.systemStatus),
                cpuUsage: systemStatusSnapshot.cpuUsage
            )
        )
    }

    private func perform(_ hapticFeedback: IslandHapticFeedback) {
        NSHapticFeedbackManager.defaultPerformer.perform(
            hapticFeedback.pattern,
            performanceTime: .now
        )
    }

    var pomodoroTimeText: String {
        pomodoroModel.timeText
    }

    var showsBatteryLowWarning: Bool {
        batteryModel.showsLowWarning(canPresent: expandedPanel == nil)
    }

    var chargingPowerText: String? {
        batteryModel.chargingPowerText
    }

    var pomodoroProgress: CGFloat {
        pomodoroModel.progress
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

    private func updateVisualizerPalette(from artworkData: Data?) {
        guard
            let artworkData,
            let palette = artworkPaletteExtractor.palette(from: artworkData)
        else {
            resetVisualizerPalette()
            return
        }

        visualizerBrightColor = Color(nsColor: palette.brightColor)
        visualizerDarkColor = Color(nsColor: palette.darkColor)
    }

    private func resetVisualizerPalette() {
        visualizerBrightColor = .white.opacity(0.92)
        visualizerDarkColor = .white.opacity(0.6)
    }

    private func dismissVolumeOverlay(resetLevel: Bool = false) {
        volumeOverlayModel.dismiss(resetLevel: resetLevel)
    }

    private func showChargingPowerIndicator() {
        guard let chargingPowerWidget = compactWidgetFactory.chargingPowerWidget(state: compactWidgetFactoryState) else { return }
        presentTemporaryCompactWidget(chargingPowerWidget, duration: 3)
    }

    private func updateTemporaryPomodoroWidget() {
        if let urgentPomodoroWidget = compactWidgetFactory.urgentPomodoroWidget(state: compactWidgetFactoryState) {
            setTemporaryCompactWidget(urgentPomodoroWidget)
        } else {
            clearTemporaryCompactWidget(for: .trailing, identity: .builtIn(.pomodoro))
        }
    }

    private func handlePomodoroUpdate() {
        updateTemporaryPomodoroWidget()
    }

    private func presentTemporaryCompactWidget(_ widget: CompactIslandWidget, duration: TimeInterval) {
        temporaryWidgetStore.present(widget, duration: duration)
    }

    private func setTemporaryCompactWidget(_ widget: CompactIslandWidget) {
        temporaryWidgetStore.set(widget)
    }

    private func handleTemporaryWidgetUpdate() {
        refreshCompactWidgets()
        notifyLayoutChange()
    }

    private func clearTemporaryCompactWidget(for placement: CompactWidgetPlacement, identity: CompactWidgetIdentity? = nil) {
        temporaryWidgetStore.clear(placement: placement, identity: identity)
    }

    func attachPluginManager(_ pluginManager: PluginManager) {
        self.pluginManager = pluginManager
    }

    func updatePluginRuntimeInfos(_ infos: [PluginRuntimeInfo]) {
        pluginHostStore.updateRuntimeInfos(infos)
    }

    private func handlePluginHostChange(_ change: PluginHostChange) {
        if change.contains(.widgets) {
            widgetLayoutStore.synchronize(availablePluginIDs: pluginHostStore.availableWidgetIDs)
            refreshCompactWidgets()
        }
        if change.contains(.expandedPages) {
            ensureExpandedWidgetPage()
        }
        notifyLayoutChange()
    }

    func bridgeStateSnapshot() -> BridgeStateSnapshot {
        BridgeStateSnapshot(
            nowPlaying: pluginNowPlayingSnapshot.map {
                BridgeNowPlayingSnapshot(
                    title: $0.title,
                    artist: $0.artist,
                    album: $0.album,
                    sourceApp: $0.sourceApp,
                    isPlaying: $0.isPlaying
                )
            },
            weather: BridgeWeatherSnapshot(
                temperatureText: pluginWeatherSnapshot.temperatureText,
                symbolName: pluginWeatherSnapshot.symbolName,
                manualLocation: pluginWeatherSnapshot.manualLocation
            ),
            volume: pluginVolumeSnapshot.map {
                BridgeVolumeSnapshot(level: $0.level, outputDeviceName: $0.outputDeviceName)
            },
            expandedPanel: expandedPanel.map {
                switch $0 {
                case .musicPlayer:
                    return "musicPlayer"
                case .onboarding:
                    return "onboarding"
                }
            },
            activeExpandedPageID: activeExpandedWidgetPage?.id,
            pluginStatusMessage: showsPluginStatus ? pluginStatusMessage : nil,
            plugins: pluginRuntimeInfos.map {
                BridgePluginRuntimeSnapshot(
                    id: $0.id,
                    displayName: $0.displayName,
                    version: $0.version,
                    capabilities: $0.capabilities.map(\.rawValue).sorted(),
                    state: $0.state.rawValue,
                    errorMessage: $0.errorMessage
                )
            }
        )
    }

    func bridgeOpenMusicPlayer() {
        guard expandedPanel != .onboarding, expandedPanel != .musicPlayer else { return }
        expandedPanel = .musicPlayer
        ensureExpandedWidgetPage()
        transientPresentationModel.hidePluginStatus()
        notifyLayoutChange()
    }

    func bridgeUpsertWidget(_ payload: BridgeWidgetPayload, clientID: String) throws {
        guard let descriptor = payload.pluginDescriptor() else {
            throw NSError(domain: "PullNotch.PluginBridge", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Invalid widget payload."
            ])
        }
        pluginHostStore.registerWidget(descriptor, pluginID: bridgePluginID(for: clientID))
    }

    func bridgeRemoveWidget(id: String, clientID: String) {
        pluginHostStore.unregisterWidget(id: id, pluginID: bridgePluginID(for: clientID))
    }

    func bridgeUpsertDashboardWidget(_ payload: BridgeDashboardWidgetPayload, clientID: String) {
        let descriptor = PluginDashboardWidgetDescriptor(
            id: payload.id,
            title: payload.title,
            symbolName: payload.symbolName ?? "puzzlepiece.extension"
        ) {
            AnyView(BridgePageView(payload: payload.pagePayload, contentPadding: 8))
        }
        pluginHostStore.registerDashboardWidget(descriptor, pluginID: bridgePluginID(for: clientID))
    }

    func bridgeRemoveDashboardWidget(id: String, clientID: String) {
        pluginHostStore.unregisterDashboardWidget(id: id, pluginID: bridgePluginID(for: clientID))
    }

    func bridgeUpsertPage(_ payload: BridgePagePayload, clientID: String) {
        let descriptor = PluginExpandedPageDescriptor(
            id: payload.id,
            title: payload.title,
            preferredWidth: CGFloat(payload.preferredWidth ?? 360)
        ) { [weak self] in
            AnyView(BridgePageView(payload: payload, onDismiss: { self?.dismissExpandedPanel() }))
        }

        pluginHostStore.registerExpandedPage(descriptor, pluginID: bridgePluginID(for: clientID))

        if payload.notification == true {
            let scopedID = "\(bridgePluginID(for: clientID))::\(payload.id)"
            let pageID = "plugin:\(scopedID)"

            if expandedPanel != .musicPlayer {
                expandedPanel = .musicPlayer
                ensureExpandedWidgetPage()
                dismissVolumeOverlay()
                transientPresentationModel.hideTrackAndPluginStatus()
                perform(.generic)
            }

            selectExpandedWidgetPage(id: pageID)
            notifyLayoutChange()
        }
    }

    func bridgeRemovePage(id: String, clientID: String) {
        pluginHostStore.unregisterExpandedPage(id: id, pluginID: bridgePluginID(for: clientID))
    }

    func bridgeClearContent(clientID: String) {
        unregisterPluginContent(for: bridgePluginID(for: clientID))
    }

    func setPluginEnabled(_ id: String, isEnabled: Bool) {
        pluginManager?.setPluginEnabled(id: id, isEnabled: isEnabled)
    }

    func settingsSectionsForPlugin(_ pluginID: String) -> [PluginSettingsSectionDescriptor] {
        pluginHostStore.settingsSections(for: pluginID)
    }

    func makePluginContext(for manifest: PluginManifest) -> PluginContext {
        pluginHostStore.makeContext(for: manifest) { [weak self] message, duration in
            self?.showPluginStatus(message: message, duration: duration)
        }
    }

    func unregisterPluginContent(for pluginID: String) {
        pluginHostStore.unregisterContent(for: pluginID)
    }

    private func bridgePluginID(for clientID: String) -> String {
        let sanitized = clientID.replacingOccurrences(of: "::", with: "--")
        return "bridge.\(sanitized)"
    }

    private var pluginNowPlayingSnapshot: PluginNowPlayingSnapshot? {
        guard currentPresentation != nil else { return nil }
        return PluginNowPlayingSnapshot(
            title: nowPlayingModel.title ?? "",
            artist: nowPlayingModel.artist ?? "",
            album: albumName ?? "",
            sourceApp: sourceApp,
            isPlaying: isPlaying
        )
    }

    private var pluginWeatherSnapshot: PluginWeatherSnapshot {
        PluginWeatherSnapshot(
            temperatureText: weatherTemperatureText,
            symbolName: weatherSymbolName,
            manualLocation: manualWeatherLocation
        )
    }

    private var pluginVolumeSnapshot: PluginVolumeSnapshot? {
        return PluginVolumeSnapshot(level: volumeLevel, outputDeviceName: volumeOutputDeviceName)
    }

    func showPluginStatus(message: String, duration: TimeInterval = 3) {
        dismissVolumeOverlay()
        transientPresentationModel.showPluginStatus(message: message, duration: duration)
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

}
