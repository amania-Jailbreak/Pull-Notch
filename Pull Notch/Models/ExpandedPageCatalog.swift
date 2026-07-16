import AppKit
import Foundation
import PullNotchPluginKit

struct ExpandedPageCatalogState {
    struct NowPlaying {
        let isAvailable: Bool
        let title: String?
        let artist: String?
        let sourceApp: String?
    }

    struct PinnedFile {
        let isEnabled: Bool
        let selectedDisplayName: String?
        let selectedParentPath: String?
        let count: Int
    }

    struct Weather {
        let isEnabled: Bool
        let temperatureText: String?
        let location: String?
    }

    struct Pomodoro {
        let isEnabled: Bool
        let timeText: String
        let phaseTitle: String
    }

    let compactWidth: CGFloat
    let nowPlaying: NowPlaying
    let pinnedFile: PinnedFile
    let weather: Weather
    let pomodoro: Pomodoro
}

@MainActor
struct ExpandedPageCatalog {
    func pages(
        state: ExpandedPageCatalogState,
        pluginPages: [PluginExpandedPageDescriptor]
    ) -> [ExpandedPageDescriptor] {
        var pages: [ExpandedPageDescriptor] = []

        if state.nowPlaying.isAvailable {
            pages.append(builtInDescriptor(.nowPlaying))
        }
        pages.append(builtInDescriptor(.widgetBoard))
        if state.pinnedFile.isEnabled, state.pinnedFile.count > 0 {
            pages.append(builtInDescriptor(.pinnedFile))
        }
        if state.weather.isEnabled, state.weather.temperatureText != nil {
            pages.append(builtInDescriptor(.weather))
        }
        if state.pomodoro.isEnabled {
            pages.append(builtInDescriptor(.pomodoro))
        }

        pages.append(contentsOf: pluginPages.map { descriptor in
            ExpandedPageDescriptor(
                id: "plugin:\(descriptor.id)",
                title: descriptor.title,
                source: .plugin(descriptor.id),
                preferredWidth: descriptor.preferredWidth,
                render: descriptor.render
            )
        })
        return pages
    }

    func activePage(
        currentPageID: String?,
        in pages: [ExpandedPageDescriptor]
    ) -> ExpandedPageDescriptor? {
        guard !pages.isEmpty else { return nil }
        guard let currentPageID else { return pages.first }
        return pages.first(where: { $0.id == currentPageID }) ?? pages.first
    }

    func activeBuiltInPage(
        currentPageID: String?,
        in pages: [ExpandedPageDescriptor]
    ) -> ExpandedWidgetPageKind? {
        guard let page = activePage(currentPageID: currentPageID, in: pages) else { return nil }
        guard case .builtIn(let builtInPage) = page.source else { return nil }
        return builtInPage
    }

    func preferredWidth(
        for page: ExpandedPageDescriptor,
        state: ExpandedPageCatalogState
    ) -> CGFloat {
        switch page.source {
        case .plugin:
            return page.preferredWidth ?? state.compactWidth
        case .builtIn(let builtInPage):
            return preferredWidth(for: builtInPage, state: state)
        }
    }

    func maximumPreferredWidth(
        for pages: [ExpandedPageDescriptor],
        state: ExpandedPageCatalogState
    ) -> CGFloat {
        pages
            .map { preferredWidth(for: $0, state: state) }
            .reduce(state.compactWidth, max)
    }

    private func builtInDescriptor(_ page: ExpandedWidgetPageKind) -> ExpandedPageDescriptor {
        ExpandedPageDescriptor(
            id: page.id,
            title: page.title,
            source: .builtIn(page),
            preferredWidth: nil,
            render: nil
        )
    }

    private func preferredWidth(
        for page: ExpandedWidgetPageKind,
        state: ExpandedPageCatalogState
    ) -> CGFloat {
        switch page {
        case .nowPlaying:
            let titleWidth = textWidth(
                state.nowPlaying.title ?? "Not Playing",
                font: .systemFont(ofSize: 14, weight: .semibold)
            )
            let subtitleWidth = textWidth(
                state.nowPlaying.artist ?? "No artist",
                font: .systemFont(ofSize: 12, weight: .medium)
            )
            let sourceWidth = textWidth(
                state.nowPlaying.sourceApp ?? "Music",
                font: .systemFont(ofSize: 11, weight: .medium)
            )
            let textColumnWidth = max(titleWidth, subtitleWidth, sourceWidth, 180)
            return min(560, max(420, 64 + 14 + textColumnWidth + 48))
        case .widgetBoard:
            return 720
        case .pinnedFile:
            let fileNameWidth = textWidth(
                state.pinnedFile.selectedDisplayName ?? "No File",
                font: .systemFont(ofSize: 14, weight: .semibold)
            )
            let pathWidth = textWidth(
                state.pinnedFile.selectedParentPath ?? "ファイルがありません",
                font: .systemFont(ofSize: 11, weight: .medium)
            )
            let buttonsWidth: CGFloat = 108 + 92 + 96 + 88
            let contentWidth = max(fileNameWidth, pathWidth, buttonsWidth)
            return min(720, max(600, contentWidth + 64))
        case .weather:
            let temperatureWidth = textWidth(
                state.weather.temperatureText ?? "--°",
                font: .systemFont(ofSize: 28, weight: .bold)
            )
            let locationWidth = textWidth(
                state.weather.location ?? "Current Location",
                font: .systemFont(ofSize: 12, weight: .medium)
            )
            return min(520, max(420, temperatureWidth + locationWidth + 180))
        case .pomodoro:
            let timerWidth = textWidth(
                state.pomodoro.timeText,
                font: .systemFont(ofSize: 28, weight: .bold)
            )
            let phaseWidth = textWidth(
                state.pomodoro.phaseTitle,
                font: .systemFont(ofSize: 12, weight: .medium)
            )
            return min(520, max(420, timerWidth + phaseWidth + 200))
        }
    }

    private func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil(NSString(string: text).size(withAttributes: [.font: font]).width)
    }
}
