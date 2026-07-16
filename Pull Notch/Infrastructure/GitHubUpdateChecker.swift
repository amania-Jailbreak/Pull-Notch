import Foundation

nonisolated struct GitHubRelease: Decodable, Equatable, Sendable {
    let tagName: String
    let htmlURL: URL

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}

nonisolated struct AppReleaseVersion: Comparable, Sendable {
    let version: [Int]
    let build: Int

    var displayText: String {
        version.map(String.init).joined(separator: ".")
    }

    init?(versionString: String, buildString: String) {
        guard
            let version = Self.parseComponents(versionString),
            let build = Int(buildString),
            build >= 0
        else {
            return nil
        }

        self.version = version
        self.build = build
    }

    init?(releaseTag: String) {
        let prefix = "v"
        let buildSeparator = "-build-"
        guard
            releaseTag.hasPrefix(prefix),
            let separatorRange = releaseTag.range(of: buildSeparator),
            separatorRange.lowerBound > releaseTag.index(releaseTag.startIndex, offsetBy: prefix.count),
            releaseTag.range(of: buildSeparator, range: separatorRange.upperBound..<releaseTag.endIndex) == nil
        else {
            return nil
        }

        let versionString = String(releaseTag[releaseTag.index(releaseTag.startIndex, offsetBy: prefix.count)..<separatorRange.lowerBound])
        let buildString = String(releaseTag[separatorRange.upperBound...])
        self.init(versionString: versionString, buildString: buildString)
    }

    static func < (lhs: AppReleaseVersion, rhs: AppReleaseVersion) -> Bool {
        let componentCount = max(lhs.version.count, rhs.version.count)
        for index in 0..<componentCount {
            let lhsComponent = index < lhs.version.count ? lhs.version[index] : 0
            let rhsComponent = index < rhs.version.count ? rhs.version[index] : 0
            if lhsComponent != rhsComponent {
                return lhsComponent < rhsComponent
            }
        }
        return lhs.build < rhs.build
    }

    private static func parseComponents(_ string: String) -> [Int]? {
        let rawComponents = string.split(separator: ".", omittingEmptySubsequences: false)
        guard !rawComponents.isEmpty else { return nil }

        var components: [Int] = []
        components.reserveCapacity(rawComponents.count)
        for rawComponent in rawComponents {
            guard !rawComponent.isEmpty, let component = Int(rawComponent), component >= 0 else {
                return nil
            }
            components.append(component)
        }
        return components
    }
}

nonisolated struct GitHubReleaseResponse: Sendable {
    let data: Data
    let statusCode: Int
}

nonisolated protocol GitHubReleaseFetching: Sendable {
    func latestRelease(from url: URL) async throws -> GitHubReleaseResponse
}

nonisolated struct URLSessionGitHubReleaseFetcher: GitHubReleaseFetching {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        configuration.httpAdditionalHeaders = [
            "Accept": "application/vnd.github+json",
            "User-Agent": "Pull Notch Update Checker",
        ]
        session = URLSession(configuration: configuration)
    }

    func latestRelease(from url: URL) async throws -> GitHubReleaseResponse {
        let (data, response) = try await session.data(from: url)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        return GitHubReleaseResponse(data: data, statusCode: statusCode)
    }
}

actor GitHubUpdateChecker {
    typealias Update = (release: GitHubRelease, version: AppReleaseVersion)

    private static let defaultLatestReleaseURL = URL(
        string: "https://api.github.com/repos/amania-Jailbreak/Pull-Notch/releases/latest"
    )!
    private static let lastAutomaticCheckKey = "PullNotch.update.lastAutomaticCheck"
    private static let lastNotifiedTagKey = "PullNotch.update.lastNotifiedTag"
    private static let automaticCheckInterval: TimeInterval = 60 * 60 * 24

    private let fetcher: any GitHubReleaseFetching
    private let defaults: UserDefaults
    private let latestReleaseURL: URL
    private let currentVersion: @Sendable () -> AppReleaseVersion?
    private let now: @Sendable () -> Date

    init(
        fetcher: any GitHubReleaseFetching = URLSessionGitHubReleaseFetcher(),
        defaults: UserDefaults = .standard,
        latestReleaseURL: URL = GitHubUpdateChecker.defaultLatestReleaseURL,
        currentVersion: @escaping @Sendable () -> AppReleaseVersion? = { GitHubUpdateChecker.bundleVersion() },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fetcher = fetcher
        self.defaults = defaults
        self.latestReleaseURL = latestReleaseURL
        self.currentVersion = currentVersion
        self.now = now
    }

    func checkAutomatically() async -> Update? {
        let checkDate = now()
        let lastCheck = defaults.object(forKey: Self.lastAutomaticCheckKey) as? Date
        if let lastCheck, checkDate.timeIntervalSince(lastCheck) < Self.automaticCheckInterval {
            return nil
        }

        defaults.set(checkDate, forKey: Self.lastAutomaticCheckKey)

        guard let result = await latestUpdate() else { return nil }
        guard defaults.string(forKey: Self.lastNotifiedTagKey) != result.release.tagName else { return nil }
        defaults.set(result.release.tagName, forKey: Self.lastNotifiedTagKey)
        return result
    }

    private func latestUpdate() async -> Update? {
        guard let currentVersion = currentVersion() else { return nil }

        do {
            let response = try await fetcher.latestRelease(from: latestReleaseURL)
            guard response.statusCode == 200 else { return nil }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: response.data)
            guard let latestVersion = AppReleaseVersion(releaseTag: release.tagName) else { return nil }
            guard currentVersion < latestVersion else { return nil }
            return (release, latestVersion)
        } catch {
            return nil
        }
    }

    private static func bundleVersion() -> AppReleaseVersion? {
        let info = Bundle.main.infoDictionary
        guard
            let rawVersion = info?["CFBundleShortVersionString"] as? String,
            let rawBuild = info?["CFBundleVersion"] as? String
        else {
            return nil
        }
        return AppReleaseVersion(versionString: rawVersion, buildString: rawBuild)
    }
}
