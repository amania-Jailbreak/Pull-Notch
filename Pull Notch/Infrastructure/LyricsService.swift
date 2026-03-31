import Foundation

#if canImport(MusanovaKit) && canImport(MusicKit)
import MusanovaKit
import MusicKit
#endif

private struct LyricsRequestKey: Hashable {
    let trackName: String
    let artistName: String
    let albumName: String
    let durationSeconds: Int
}

private struct LrcLibLyrics: Decodable {
    let id: Int
    let trackName: String
    let artistName: String
    let albumName: String
    let duration: Double
    let instrumental: Bool
    let plainLyrics: String?
    let syncedLyrics: String?
}

private struct PetitLyricsSong {
    let lyricsId: String
    let title: String
    let artist: String
    let durationSeconds: Int
    let availableLyricsType: Int
}

private struct PetitLyricsLine {
    let startTimeSeconds: TimeInterval
    let text: String
}

private struct PetitLyricsPayload {
    let lyricsData: String
}

private struct AppleMusicSearchResponse: Decodable {
    let results: AppleMusicSearchResults
}

private struct AppleMusicSearchResults: Decodable {
    let songs: AppleMusicSongs?
}

private struct AppleMusicSongs: Decodable {
    let data: [AppleMusicSongSummary]
}

private struct AppleMusicSongSummary: Decodable {
    let id: String
    let attributes: AppleMusicSongAttributes?
}

private struct AppleMusicSongAttributes: Decodable {
    let name: String?
    let artistName: String?
    let albumName: String?
    let durationInMillis: Int?
}

private struct QQMusicSearchResponse: Decodable {
    let code: Int
    let data: QQMusicSearchData?
}

private struct QQMusicSearchData: Decodable {
    let song: QQMusicSongContainer
}

private struct QQMusicSongContainer: Decodable {
    let list: [QQMusicSong]
}

private struct QQMusicSong: Decodable {
    let songmid: String
    let songname: String
    let singer: [QQMusicSinger]
    let albumname: String
    let interval: Int
}

private struct QQMusicSinger: Decodable {
    let name: String
}

private struct QQMusicLyricsResponse: Decodable {
    let code: Int
    let lyric: String?
}

private struct NetEaseSearchResponse: Decodable {
    let result: NetEaseSearchResult
}

private struct NetEaseSearchResult: Decodable {
    let songs: [NetEaseSong]
}

private struct NetEaseSong: Decodable {
    let id: Int
    let name: String
    let artists: [NetEaseArtist]
    let album: NetEaseAlbum
}

private struct NetEaseArtist: Decodable {
    let name: String
}

private struct NetEaseAlbum: Decodable {
    let name: String
}

private struct NetEaseLyricsResponse: Decodable {
    let lrc: NetEaseLRC?
}

private struct NetEaseLRC: Decodable {
    let lyric: String?
}

actor LyricsService {
    private enum LyricsFetchProvider: String, CaseIterable {
        case lrclib = "LRCLIB"
        case petitLyrics = "PetitLyrics"
        case musanovaKit = "MusanovaKit"
        case qqMusic = "QQ Music"
        case netEase = "NetEase"
    }

    private struct ProviderFetchResult {
        let provider: LyricsFetchProvider
        let lyrics: ResolvedLyrics?
    }

    private enum PetitLyricsConstants {
        static let endpoint = "https://p1.petitlyrics.com/api/GetPetitLyricsData.php"
        static let clientAppId = "p1110417"
        static let userID = "2faf895e-20ab-4a8b-b27e-5df5a426e488"
        static let terminalType = "10"
    }

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 8
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Pull Notch/1.0 (jp.amania.Pull-Notch)"
        ]
        return URLSession(configuration: configuration)
    }()

    private var cache: [LyricsRequestKey: ResolvedLyrics?] = [:]

    func lyrics(
        trackName: String,
        artistName: String,
        albumName: String,
        durationSeconds: TimeInterval?
    ) async -> ResolvedLyrics? {
        guard
            let durationSeconds,
            durationSeconds > 0
        else {
            return nil
        }

        let key = LyricsRequestKey(
            trackName: normalize(trackName),
            artistName: normalize(artistName),
            albumName: normalize(albumName),
            durationSeconds: Int(durationSeconds.rounded())
        )

        if let cached = cache[key] {
            return cached
        }

        log("starting parallel fetch for \(key.trackName) / \(key.artistName)")

        let resolvedLyrics = await withTaskGroup(of: ProviderFetchResult.self, returning: ResolvedLyrics?.self) { group in
            for provider in LyricsFetchProvider.allCases {
                group.addTask { [self] in
                    await fetchUsingProvider(provider, key: key)
                }
            }

            for await result in group {
                if let lyrics = result.lyrics {
                    log("selected \(result.provider.rawValue) as first successful provider")
                    group.cancelAll()
                    return lyrics
                }
            }

            return nil
        }

        cache[key] = resolvedLyrics

        if resolvedLyrics == nil {
            log("all providers missed for \(key.trackName) / \(key.artistName)")
        }

        return resolvedLyrics
    }

    func parseSyncedLyrics(_ syncedLyrics: String?) -> [SyncedLyricLine] {
        guard let syncedLyrics else { return [] }

        let linePattern = #"\[(\d{2}):(\d{2})(?:\.(\d{1,3}))?\]"#
        guard let regex = try? NSRegularExpression(pattern: linePattern) else { return [] }

        var parsedLines: [SyncedLyricLine] = []

        for rawLine in syncedLyrics.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let matches = regex.matches(in: line, range: NSRange(line.startIndex..., in: line))
            guard !matches.isEmpty else { continue }

            let lyricText = regex.stringByReplacingMatches(
                in: line,
                range: NSRange(line.startIndex..., in: line),
                withTemplate: ""
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !lyricText.isEmpty else { continue }

            for match in matches {
                guard
                    let minutesRange = Range(match.range(at: 1), in: line),
                    let secondsRange = Range(match.range(at: 2), in: line)
                else {
                    continue
                }

                let minutes = Double(line[minutesRange]) ?? 0
                let seconds = Double(line[secondsRange]) ?? 0
                let fraction: Double

                if let fractionRange = Range(match.range(at: 3), in: line) {
                    let rawFraction = String(line[fractionRange])
                    switch rawFraction.count {
                    case 1:
                        fraction = (Double(rawFraction) ?? 0) / 10
                    case 2:
                        fraction = (Double(rawFraction) ?? 0) / 100
                    default:
                        fraction = (Double(rawFraction) ?? 0) / 1000
                    }
                } else {
                    fraction = 0
                }

                parsedLines.append(
                    SyncedLyricLine(
                        timestamp: (minutes * 60) + seconds + fraction,
                        text: lyricText
                    )
                )
            }
        }

        return parsedLines.sorted { lhs, rhs in
            if lhs.timestamp == rhs.timestamp {
                return lhs.text < rhs.text
            }
            return lhs.timestamp < rhs.timestamp
        }
    }

    private func fetchBestLrcLibMatch(key: LyricsRequestKey) async -> LrcLibLyrics? {
        if let exactMatch = await fetchExactMatch(key: key) {
            return exactMatch
        }

        return await searchBestMatch(key: key)
    }

    private func resolvedLyrics(from lyrics: LrcLibLyrics, provider: LyricsProvider) -> ResolvedLyrics? {
        guard
            lyrics.plainLyrics?.isEmpty == false || lyrics.syncedLyrics?.isEmpty == false
        else {
            return nil
        }

        return ResolvedLyrics(
            plainLyrics: lyrics.plainLyrics,
            syncedLyrics: lyrics.syncedLyrics,
            provider: provider
        )
    }

    private func fetchUsingProvider(_ provider: LyricsFetchProvider, key: LyricsRequestKey) async -> ProviderFetchResult {
        log("[\(provider.rawValue)] request started")

        let lyrics: ResolvedLyrics?
        switch provider {
        case .lrclib:
            lyrics = await fetchBestLrcLibMatch(key: key).flatMap { resolvedLyrics(from: $0, provider: .lrclib) }
        case .petitLyrics:
            lyrics = await fetchPetitLyricsMatch(key: key)
        case .musanovaKit:
            lyrics = await fetchMusanovaLyricsMatch(key: key)
        case .qqMusic:
            lyrics = await fetchQQMusicLyricsMatch(key: key)
        case .netEase:
            lyrics = await fetchNetEaseLyricsMatch(key: key)
        }

        if let lyrics {
            let mode = lyrics.syncedLyrics?.isEmpty == false ? "synced" : "plain"
            log("[\(provider.rawValue)] success (\(mode))")
        } else {
            log("[\(provider.rawValue)] miss")
        }

        return ProviderFetchResult(provider: provider, lyrics: lyrics)
    }

    private func log(_ message: String) {
        print("LyricsService: \(message)")
    }

    private func fetchExactMatch(key: LyricsRequestKey) async -> LrcLibLyrics? {
        if let cached = await fetchLrcLib(path: "/api/get-cached", key: key) {
            return cached
        }

        return await fetchLrcLib(path: "/api/get", key: key)
    }

    private func fetchLrcLib(path: String, key: LyricsRequestKey) async -> LrcLibLyrics? {
        var components = URLComponents(string: "https://lrclib.net\(path)")
        components?.queryItems = [
            URLQueryItem(name: "track_name", value: key.trackName),
            URLQueryItem(name: "artist_name", value: key.artistName),
            URLQueryItem(name: "album_name", value: key.albumName),
            URLQueryItem(name: "duration", value: String(key.durationSeconds))
        ]

        guard let url = components?.url else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse else { return nil }
            guard httpResponse.statusCode == 200 else { return nil }

            return try JSONDecoder().decode(LrcLibLyrics.self, from: data)
        } catch {
            return nil
        }
    }

    private func searchBestMatch(key: LyricsRequestKey) async -> LrcLibLyrics? {
        var components = URLComponents(string: "https://lrclib.net/api/search")
        components?.queryItems = [
            URLQueryItem(name: "track_name", value: key.trackName),
            URLQueryItem(name: "artist_name", value: key.artistName),
            URLQueryItem(name: "album_name", value: key.albumName)
        ]

        guard let url = components?.url else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse else { return nil }
            guard httpResponse.statusCode == 200 else { return nil }

            let results = try JSONDecoder().decode([LrcLibLyrics].self, from: data)
            return results
                .filter { abs(Int($0.duration.rounded()) - key.durationSeconds) <= 2 }
                .sorted { lhs, rhs in
                    let lhsAlbumPenalty = lhs.albumName.caseInsensitiveCompare(key.albumName) == .orderedSame ? 0 : 1
                    let rhsAlbumPenalty = rhs.albumName.caseInsensitiveCompare(key.albumName) == .orderedSame ? 0 : 1
                    if lhsAlbumPenalty != rhsAlbumPenalty {
                        return lhsAlbumPenalty < rhsAlbumPenalty
                    }
                    return abs(lhs.duration - Double(key.durationSeconds)) < abs(rhs.duration - Double(key.durationSeconds))
                }
                .first
        } catch {
            return nil
        }
    }

    private func fetchPetitLyricsMatch(key: LyricsRequestKey) async -> ResolvedLyrics? {
        guard let song = await searchPetitLyricsSong(key: key) else { return nil }
        guard let payload = await fetchPetitLyricsPayload(song: song) else { return nil }

        guard
            let xmlData = Data(base64Encoded: payload.lyricsData),
            let xmlString = String(data: xmlData, encoding: .utf8)
        else {
            return nil
        }

        let lines = PetitLyricsLineParser.parse(xmlString: xmlString)
        guard !lines.isEmpty else { return nil }

        let plainLyrics = lines.map(\.text).joined(separator: "\n")
        let syncedLyrics = lines
            .map { "[\(lrcTimestamp(for: $0.startTimeSeconds))] \($0.text)" }
            .joined(separator: "\n")

        return ResolvedLyrics(
            plainLyrics: plainLyrics,
            syncedLyrics: syncedLyrics,
            provider: .petitLyrics
        )
    }

    private func fetchQQMusicLyricsMatch(key: LyricsRequestKey) async -> ResolvedLyrics? {
        guard let song = await searchQQMusicSong(key: key) else { return nil }
        guard let lrcString = await fetchQQMusicLRC(songmid: song.songmid) else { return nil }
        let parsedLines = parseSyncedLyrics(lrcString)
        guard !parsedLines.isEmpty else { return nil }

        return ResolvedLyrics(
            plainLyrics: parsedLines.map(\.text).joined(separator: "\n"),
            syncedLyrics: lrcString,
            provider: .qqMusic
        )
    }

    private func fetchNetEaseLyricsMatch(key: LyricsRequestKey) async -> ResolvedLyrics? {
        guard let song = await searchNetEaseSong(key: key) else { return nil }
        guard let lrcString = await fetchNetEaseLRC(songID: song.id) else { return nil }
        let parsedLines = parseSyncedLyrics(lrcString)
        guard !parsedLines.isEmpty else { return nil }
        guard parsedLines.last?.timestamp != 0 else { return nil }

        return ResolvedLyrics(
            plainLyrics: parsedLines.map(\.text).joined(separator: "\n"),
            syncedLyrics: lrcString,
            provider: .netEase
        )
    }

    private func fetchMusanovaLyricsMatch(key: LyricsRequestKey) async -> ResolvedLyrics? {
#if canImport(MusanovaKit) && canImport(MusicKit)
        guard let developerToken = ProcessInfo.processInfo.environment["DEVELOPER_TOKEN"], !developerToken.isEmpty else {
            return nil
        }

        guard let songID = await searchAppleMusicCatalogSongID(key: key, developerToken: developerToken) else {
            return nil
        }

        do {
            let request = MusicLyricsRequest(songID: MusicItemID(songID), developerToken: developerToken)
            let response = try await request.response()
            guard let ttml = response.data.first?.attributes.ttml, !ttml.isEmpty else {
                return nil
            }

            let lines = TTMLLyricParser.parse(xmlString: ttml)
            guard !lines.isEmpty else { return nil }

            let plainLyrics = lines.map(\.text).joined(separator: "\n")
            let syncedLyrics = lines
                .map { "[\(lrcTimestamp(for: $0.startTimeSeconds))] \($0.text)" }
                .joined(separator: "\n")

            return ResolvedLyrics(
                plainLyrics: plainLyrics,
                syncedLyrics: syncedLyrics,
                provider: .musanovaKit
            )
        } catch {
            return nil
        }
#else
        return nil
#endif
    }

    private func searchPetitLyricsSong(key: LyricsRequestKey) async -> PetitLyricsSong? {
        let body = [
            "key_artist": key.artistName,
            "key_album": "0",
            "index": "0",
            "key_title": key.trackName,
            "clientAppId": PetitLyricsConstants.clientAppId,
            "maxCount": "10",
            "userId": PetitLyricsConstants.userID,
            "terminalType": PetitLyricsConstants.terminalType
        ]

        guard let responseXML = await postForm(urlString: PetitLyricsConstants.endpoint, body: body) else {
            return nil
        }

        return PetitLyricsSearchParser.parse(xml: responseXML)
            .filter { $0.availableLyricsType == 3 }
            .sorted { lhs, rhs in
                let lhsArtistPenalty = lhs.artist.caseInsensitiveCompare(key.artistName) == .orderedSame ? 0 : 1
                let rhsArtistPenalty = rhs.artist.caseInsensitiveCompare(key.artistName) == .orderedSame ? 0 : 1
                if lhsArtistPenalty != rhsArtistPenalty {
                    return lhsArtistPenalty < rhsArtistPenalty
                }

                let lhsTitlePenalty = lhs.title.caseInsensitiveCompare(key.trackName) == .orderedSame ? 0 : 1
                let rhsTitlePenalty = rhs.title.caseInsensitiveCompare(key.trackName) == .orderedSame ? 0 : 1
                if lhsTitlePenalty != rhsTitlePenalty {
                    return lhsTitlePenalty < rhsTitlePenalty
                }

                return abs(lhs.durationSeconds - key.durationSeconds) < abs(rhs.durationSeconds - key.durationSeconds)
            }
            .first
    }

    private func fetchPetitLyricsPayload(song: PetitLyricsSong) async -> PetitLyricsPayload? {
        let body = [
            "key_lyricsId": song.lyricsId,
            "lyricsType": "3",
            "clientAppId": PetitLyricsConstants.clientAppId,
            "userId": PetitLyricsConstants.userID,
            "key_duration": String(song.durationSeconds),
            "terminalType": PetitLyricsConstants.terminalType
        ]

        guard let responseXML = await postForm(urlString: PetitLyricsConstants.endpoint, body: body) else {
            return nil
        }

        return PetitLyricsPayloadParser.parse(xml: responseXML)
    }

    private func postForm(urlString: String, body: [String: String]) async -> String? {
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
            .map { key, value in
                "\(percentEncode(key))=\(percentEncode(value))"
            }
            .joined(separator: "&")
            .data(using: .utf8)

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return nil }
            guard httpResponse.statusCode == 200 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func searchAppleMusicCatalogSongID(key: LyricsRequestKey, developerToken: String) async -> String? {
        for storefront in ["jp", "us"] {
            if let songID = await searchAppleMusicCatalogSongID(key: key, developerToken: developerToken, storefront: storefront) {
                return songID
            }
        }
        return nil
    }

    private func searchAppleMusicCatalogSongID(key: LyricsRequestKey, developerToken: String, storefront: String) async -> String? {
        var components = URLComponents(string: "https://api.music.apple.com/v1/catalog/\(storefront)/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: "\(key.trackName) \(key.artistName)"),
            URLQueryItem(name: "types", value: "songs"),
            URLQueryItem(name: "limit", value: "5")
        ]

        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(developerToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return nil }
            guard httpResponse.statusCode == 200 else { return nil }

            let searchResponse = try JSONDecoder().decode(AppleMusicSearchResponse.self, from: data)
            return searchResponse.results.songs?.data
                .sorted { lhs, rhs in
                    score(song: lhs, against: key) < score(song: rhs, against: key)
                }
                .first?
                .id
        } catch {
            return nil
        }
    }

    private func searchQQMusicSong(key: LyricsRequestKey) async -> QQMusicSong? {
        let keywords = "\(key.trackName) \(key.artistName)".trimmingCharacters(in: .whitespaces)
        guard let encodedKeywords = keywords.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }

        let urlString = "https://c.y.qq.com/soso/fcgi-bin/client_search_cp?format=json&p=1&n=5&w=\(encodedKeywords)"
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.setValue("https://y.qq.com", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return nil }
            guard httpResponse.statusCode == 200 else { return nil }
            let searchResult = try JSONDecoder().decode(QQMusicSearchResponse.self, from: data)
            let songs = searchResult.data?.song.list ?? []
            return songs.min { score(qqSong: $0, against: key) < score(qqSong: $1, against: key) }
        } catch {
            return nil
        }
    }

    private func fetchQQMusicLRC(songmid: String) async -> String? {
        guard let url = URL(string: "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?songmid=\(songmid)&format=json&nobase64=1") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue("https://y.qq.com", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return nil }
            guard httpResponse.statusCode == 200 else { return nil }
            let lyricResult = try JSONDecoder().decode(QQMusicLyricsResponse.self, from: data)
            guard lyricResult.code == 0 else { return nil }
            return lyricResult.lyric
        } catch {
            return nil
        }
    }

    private func searchNetEaseSong(key: LyricsRequestKey) async -> NetEaseSong? {
        let rawKeywords = "\(key.trackName) \(key.artistName)"
        let encodedKeywords = rawKeywords.replacingOccurrences(of: "&", with: "%26")
        guard let url = URL(string: "https://neteasecloudmusicapi-ten-wine.vercel.app/search?keywords=\(encodedKeywords)&limit=1") else {
            return nil
        }

        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse else { return nil }
            guard httpResponse.statusCode == 200 else { return nil }
            let searchResult = try JSONDecoder().decode(NetEaseSearchResponse.self, from: data)
            guard let song = searchResult.result.songs.first else { return nil }
            guard netEaseSongMatches(song, key: key) else { return nil }
            return song
        } catch {
            return nil
        }
    }

    private func fetchNetEaseLRC(songID: Int) async -> String? {
        guard let url = URL(string: "https://neteasecloudmusicapi-ten-wine.vercel.app/lyric?id=\(songID)") else {
            return nil
        }

        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse else { return nil }
            guard httpResponse.statusCode == 200 else { return nil }
            let lyricsResponse = try JSONDecoder().decode(NetEaseLyricsResponse.self, from: data)
            return lyricsResponse.lrc?.lyric
        } catch {
            return nil
        }
    }

    private func normalize(_ string: String) -> String {
        string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func score(song: AppleMusicSongSummary, against key: LyricsRequestKey) -> Int {
        var score = 0
        let attributes = song.attributes

        if attributes?.name?.caseInsensitiveCompare(key.trackName) != .orderedSame {
            score += 3
        }

        if attributes?.artistName?.caseInsensitiveCompare(key.artistName) != .orderedSame {
            score += 2
        }

        if let albumName = attributes?.albumName, albumName.caseInsensitiveCompare(key.albumName) != .orderedSame {
            score += 1
        }

        if let duration = attributes?.durationInMillis {
            score += abs((duration / 1000) - key.durationSeconds)
        }

        return score
    }

    private func score(qqSong: QQMusicSong, against key: LyricsRequestKey) -> Int {
        var score = 0
        let artists = qqSong.singer.map(\.name).joined(separator: ", ")

        if qqSong.songname.caseInsensitiveCompare(key.trackName) != .orderedSame {
            score += similarityPenalty(lhs: qqSong.songname, rhs: key.trackName)
        }
        if artists.caseInsensitiveCompare(key.artistName) != .orderedSame {
            score += similarityPenalty(lhs: artists, rhs: key.artistName)
        }
        if qqSong.albumname.caseInsensitiveCompare(key.albumName) != .orderedSame {
            score += similarityPenalty(lhs: qqSong.albumname, rhs: key.albumName)
        }
        score += abs(qqSong.interval - key.durationSeconds)
        return score
    }

    private func netEaseSongMatches(_ song: NetEaseSong, key: LyricsRequestKey) -> Bool {
        let artistName = song.artists.first?.name ?? ""
        let trackNameMatch = looseMatch(lhs: key.trackName, rhs: song.name)
        let artistMatch = looseMatch(lhs: key.artistName, rhs: artistName)
        let albumMatch = looseMatch(lhs: key.albumName, rhs: song.album.name)
        let trueCount = [trackNameMatch, artistMatch, albumMatch].filter { $0 }.count
        let requiredConditions = containsCJK(key.trackName) ? 1 : 2
        return trueCount >= requiredConditions
    }

    private func looseMatch(lhs: String, rhs: String) -> Bool {
        if lhs.caseInsensitiveCompare(rhs) == .orderedSame {
            return true
        }
        if lhs.localizedCaseInsensitiveContains(rhs) || rhs.localizedCaseInsensitiveContains(lhs) {
            return true
        }
        return similarityPenalty(lhs: lhs, rhs: rhs) <= 2
    }

    private func similarityPenalty(lhs: String, rhs: String) -> Int {
        let lhsNormalized = lhs.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let rhsNormalized = rhs.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lhsNormalized == rhsNormalized {
            return 0
        }
        let lhsSet = Set(lhsNormalized)
        let rhsSet = Set(rhsNormalized)
        let intersection = lhsSet.intersection(rhsSet).count
        let union = max(lhsSet.union(rhsSet).count, 1)
        let overlapScore = Double(intersection) / Double(union)
        return Int(((1 - overlapScore) * 10).rounded())
    }

    private func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) ||
            (0x3400...0x4DBF).contains(scalar.value) ||
            (0x20000...0x2A6DF).contains(scalar.value)
        }
    }

    private func percentEncode(_ string: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._* ")
        return string
            .addingPercentEncoding(withAllowedCharacters: allowed)?
            .replacingOccurrences(of: " ", with: "+") ?? string
    }

    private func lrcTimestamp(for time: TimeInterval) -> String {
        let totalCentiseconds = Int((time * 100).rounded())
        let minutes = totalCentiseconds / 6000
        let seconds = (totalCentiseconds % 6000) / 100
        let centiseconds = totalCentiseconds % 100
        return String(format: "%02d:%02d.%02d", minutes, seconds, centiseconds)
    }
}

private final class PetitLyricsSearchParser: NSObject, XMLParserDelegate {
    private var songs: [PetitLyricsSong] = []
    private var currentSong: [String: String] = [:]
    private var currentElement = ""
    private var currentText = ""
    private var songDepth = 0

    static func parse(xml: String) -> [PetitLyricsSong] {
        let parser = PetitLyricsSearchParser()
        guard let data = xml.data(using: .utf8) else { return [] }
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        xmlParser.parse()
        return parser.songs
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""
        if elementName == "song" {
            songDepth += 1
            currentSong = [:]
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if songDepth > 0, !value.isEmpty, elementName != "song" {
            currentSong[elementName] = value
        }

        if elementName == "song", songDepth > 0 {
            songDepth -= 1
            if
                let lyricsId = currentSong["lyricsId"],
                let title = currentSong["title"],
                let artist = currentSong["artist"],
                let duration = Int(currentSong["duration"] ?? ""),
                let availableLyricsType = Int(currentSong["availableLyricsType"] ?? "")
            {
                songs.append(
                    PetitLyricsSong(
                        lyricsId: lyricsId,
                        title: title,
                        artist: artist,
                        durationSeconds: duration,
                        availableLyricsType: availableLyricsType
                    )
                )
            }
            currentSong = [:]
        }

        currentElement = ""
        currentText = ""
    }
}

private final class PetitLyricsPayloadParser: NSObject, XMLParserDelegate {
    private var currentElement = ""
    private var currentText = ""
    private var lyricsData: String?

    static func parse(xml: String) -> PetitLyricsPayload? {
        let parser = PetitLyricsPayloadParser()
        guard let data = xml.data(using: .utf8) else { return nil }
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        xmlParser.parse()

        guard let lyricsData = parser.lyricsData, !lyricsData.isEmpty else {
            return nil
        }
        return PetitLyricsPayload(lyricsData: lyricsData)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if elementName == "lyricsData", !value.isEmpty {
            lyricsData = value
        }
        currentElement = ""
        currentText = ""
    }
}

private final class PetitLyricsLineParser: NSObject, XMLParserDelegate {
    private var lines: [PetitLyricsLine] = []
    private var currentLineText = ""
    private var currentLineStartTime: TimeInterval?
    private var currentElement = ""
    private var currentText = ""
    private var isInsideLine = false

    static func parse(xmlString: String) -> [PetitLyricsLine] {
        let parser = PetitLyricsLineParser()
        guard let data = xmlString.data(using: .utf8) else { return [] }
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        xmlParser.parse()
        return parser.lines
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""

        if elementName == "line" {
            isInsideLine = true
            currentLineText = ""
            currentLineStartTime = nil
        } else if elementName == "word", isInsideLine, currentLineStartTime == nil, let starttime = attributeDict["starttime"] {
            let milliseconds = Double(starttime) ?? 0
            currentLineStartTime = milliseconds / 1000
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if elementName == "linestring", isInsideLine, !value.isEmpty {
            currentLineText = decodeXMLEntities(value)
        } else if elementName == "line", isInsideLine {
            defer {
                isInsideLine = false
                currentLineText = ""
                currentLineStartTime = nil
            }

            guard
                let currentLineStartTime,
                !currentLineText.isEmpty
            else {
                return
            }

            lines.append(
                PetitLyricsLine(
                    startTimeSeconds: currentLineStartTime,
                    text: currentLineText
                )
            )
        }

        currentElement = ""
        currentText = ""
    }

    private func decodeXMLEntities(_ string: String) -> String {
        var output = string
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")

        let pattern = #"&#(x?[0-9A-Fa-f]+);"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return output }
        let matches = regex.matches(in: output, range: NSRange(output.startIndex..., in: output)).reversed()

        for match in matches {
            guard
                let fullRange = Range(match.range(at: 0), in: output),
                let valueRange = Range(match.range(at: 1), in: output)
            else {
                continue
            }

            let encoded = String(output[valueRange])
            let scalarValue: UInt32?
            if encoded.hasPrefix("x") || encoded.hasPrefix("X") {
                scalarValue = UInt32(encoded.dropFirst(), radix: 16)
            } else {
                scalarValue = UInt32(encoded, radix: 10)
            }

            guard
                let scalarValue,
                let scalar = UnicodeScalar(scalarValue)
            else {
                continue
            }

            output.replaceSubrange(fullRange, with: String(Character(scalar)))
        }

        return output
    }
}

private final class TTMLLyricParser: NSObject, XMLParserDelegate {
    private var lines: [PetitLyricsLine] = []
    private var currentLineText = ""
    private var currentLineStartTime: TimeInterval?
    private var currentText = ""
    private var isInsideParagraph = false

    static func parse(xmlString: String) -> [PetitLyricsLine] {
        let parser = TTMLLyricParser()
        guard let data = xmlString.data(using: .utf8) else { return [] }
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        xmlParser.parse()
        return parser.lines
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentText = ""

        if elementName == "p" {
            isInsideParagraph = true
            currentLineText = ""
            currentLineStartTime = parseTimestamp(attributeDict["begin"])
        } else if elementName == "span", isInsideParagraph, currentLineStartTime == nil {
            currentLineStartTime = parseTimestamp(attributeDict["begin"])
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if isInsideParagraph, (elementName == "span" || elementName == "p"), !trimmed.isEmpty {
            if !currentLineText.isEmpty, !currentLineText.hasSuffix(" ") {
                currentLineText.append(" ")
            }
            currentLineText.append(trimmed)
        }

        if elementName == "p", isInsideParagraph {
            defer {
                isInsideParagraph = false
                currentLineText = ""
                currentLineStartTime = nil
            }

            guard
                let currentLineStartTime,
                !currentLineText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return
            }

            lines.append(
                PetitLyricsLine(
                    startTimeSeconds: currentLineStartTime,
                    text: currentLineText.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
        }

        currentText = ""
    }

    private func parseTimestamp(_ raw: String?) -> TimeInterval? {
        guard let raw, !raw.isEmpty else { return nil }
        let cleaned = raw.replacingOccurrences(of: "s", with: "")
        return Double(cleaned)
    }
}
