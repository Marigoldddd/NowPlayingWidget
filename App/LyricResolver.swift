import Foundation

struct LyricSnippet: Equatable {
    var lines: [String]
    var translations: [String]

    static let empty = LyricSnippet(lines: [], translations: [])
}

final class LyricResolver {
    private struct CacheKey: Hashable {
        let sourceBundleID: String
        let title: String
        let artist: String
        let album: String
    }

    private enum CacheEntry {
        case resolved(LyricSnippet)
        case missing
    }

    private struct TimedLine {
        let timeMs: Int
        let text: String
    }

    private let lock = NSLock()
    private var cache: [CacheKey: CacheEntry] = [:]
    private var cacheOrder: [CacheKey] = []
    private var inFlight: Set<CacheKey> = []
    private let maxCacheCount = 50
    private let session: URLSession

    var onResolved: (() -> Void)?

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 6
            config.timeoutIntervalForResource = 10
            self.session = URLSession(configuration: config)
        }
    }

    /// Returns cached lyric snippet if available, or triggers a single background lookup
    /// when a new track is observed.
    func resolveIfNeeded(
        sourceBundleID: String,
        title: String,
        artist: String,
        album: String
    ) -> LyricSnippet {
        guard !title.isEmpty, title != "未知歌曲", title != "Unknown Song" else { return .empty }

        let key = CacheKey(
            sourceBundleID: sourceBundleID,
            title: title,
            artist: artist,
            album: album
        )

        let cachedResult: (hit: Bool, snippet: LyricSnippet) = lock.withLock {
            if let entry = cache[key] {
                if case let .resolved(snippet) = entry {
                    return (true, snippet)
                }
                return (true, .empty)
            }
            if inFlight.contains(key) {
                return (true, .empty)
            }
            inFlight.insert(key)
            return (false, .empty)
        }

        if cachedResult.hit {
            return cachedResult.snippet
        }

        Task.detached(priority: .utility) { [weak self] in
            await self?.fetchAndCache(key: key)
        }
        return .empty
    }

    private func fetchAndCache(key: CacheKey) async {
        let snippet = await searchLyrics(key: key)
        if finishFetch(key: key, snippet: snippet) {
            onResolved?()
        }
    }

    private func finishFetch(key: CacheKey, snippet: LyricSnippet) -> Bool {
        lock.withLock {
            inFlight.remove(key)
            if !snippet.lines.isEmpty {
                store(key: key, entry: .resolved(snippet))
                return true
            }
            store(key: key, entry: .missing)
            return false
        }
    }

    private func store(key: CacheKey, entry: CacheEntry) {
        if cache[key] == nil {
            cacheOrder.append(key)
        }
        cache[key] = entry
        while cacheOrder.count > maxCacheCount {
            let oldest = cacheOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    private func searchLyrics(key: CacheKey) async -> LyricSnippet {
        let cleanArtist = (key.artist == "未知歌手" || key.artist == "Unknown Artist") ? "" : key.artist
        let strippedTitle = stripParentheticalSuffix(key.title)

        var queries: [String] = []
        queries.append([key.title, cleanArtist].filter { !$0.isEmpty }.joined(separator: " "))
        if strippedTitle != key.title, !strippedTitle.isEmpty {
            queries.append([strippedTitle, cleanArtist].filter { !$0.isEmpty }.joined(separator: " "))
        }

        if key.sourceBundleID == "com.netease.163music" {
            for query in queries {
                if let result = await queryNetEaseLyric(term: query, preferredAlbum: key.album) {
                    let snippet = Self.extractSnippet(fromLRC: result.lrc, tlyric: result.tlyric)
                    if !snippet.lines.isEmpty {
                        return snippet
                    }
                }
            }
        }

        for query in queries {
            if let raw = await queryLRCLib(term: query, preferredTitle: key.title) {
                let snippet = Self.extractSnippet(fromLRC: raw)
                if !snippet.lines.isEmpty {
                    return snippet
                }
            }
        }

        return .empty
    }

    private func queryNetEaseLyric(
        term: String,
        preferredAlbum: String
    ) async -> (lrc: String, tlyric: String?)? {
        var components = URLComponents(string: "https://music.163.com/api/cloudsearch/pc")
        components?.queryItems = [
            URLQueryItem(name: "s", value: term),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "limit", value: "4"),
        ]
        guard let url = components?.url else { return nil }

        var searchRequest = URLRequest(url: url)
        searchRequest.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")

        guard let searchData = await downloadData(for: searchRequest),
              let json = try? JSONSerialization.jsonObject(with: searchData) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let songs = result["songs"] as? [[String: Any]] else {
            return nil
        }

        let ordered = songs.sorted { lhs, rhs in
            let lhsAlbum = (lhs["al"] as? [String: Any])?["name"] as? String ?? ""
            let rhsAlbum = (rhs["al"] as? [String: Any])?["name"] as? String ?? ""
            return albumScore(lhsAlbum, preferred: preferredAlbum) > albumScore(rhsAlbum, preferred: preferredAlbum)
        }

        for song in ordered {
            guard let songID = song["id"] as? Int else { continue }
            var lyricComponents = URLComponents(string: "https://music.163.com/api/song/lyric")
            lyricComponents?.queryItems = [
                URLQueryItem(name: "id", value: String(songID)),
                URLQueryItem(name: "lv", value: "1"),
                URLQueryItem(name: "kv", value: "1"),
                URLQueryItem(name: "tv", value: "-1"),
            ]
            guard let lyricURL = lyricComponents?.url else { continue }
            var lyricRequest = URLRequest(url: lyricURL)
            lyricRequest.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")

            guard let lyricData = await downloadData(for: lyricRequest),
                  let lyricJSON = try? JSONSerialization.jsonObject(with: lyricData) as? [String: Any],
                  let lrc = lyricJSON["lrc"] as? [String: Any],
                  let lyricText = lrc["lyric"] as? String,
                  !lyricText.isEmpty else {
                continue
            }
            let tlyricText = (lyricJSON["tlyric"] as? [String: Any])?["lyric"] as? String
            return (lyricText, tlyricText)
        }
        return nil
    }

    private func queryLRCLib(term: String, preferredTitle: String) async -> String? {
        var components = URLComponents(string: "https://lrclib.net/api/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: term),
        ]
        guard let url = components?.url,
              let data = await downloadData(for: URLRequest(url: url)),
              let results = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }

        let ordered = results.sorted { lhs, rhs in
            let lhsTitle = lhs["trackName"] as? String ?? ""
            let rhsTitle = rhs["trackName"] as? String ?? ""
            return albumScore(lhsTitle, preferred: preferredTitle) > albumScore(rhsTitle, preferred: preferredTitle)
        }

        for item in ordered {
            if let synced = item["syncedLyrics"] as? String, !synced.isEmpty {
                return synced
            }
            if let plain = item["plainLyrics"] as? String, !plain.isEmpty {
                return plain
            }
        }
        return nil
    }

    private func albumScore(_ candidate: String, preferred: String) -> Int {
        guard !preferred.isEmpty else { return 0 }
        let lhs = candidate.lowercased()
        let rhs = preferred.lowercased()
        if lhs == rhs { return 2 }
        if lhs.contains(rhs) || rhs.contains(lhs) { return 1 }
        return 0
    }

    private func downloadData(for request: URLRequest) async -> Data? {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  !data.isEmpty else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    private func stripParentheticalSuffix(_ title: String) -> String {
        let stripped = title.replacingOccurrences(
            of: #"\s*[\(\[（【][^\)\]）】]*[\)\]）】]\s*$"#,
            with: "",
            options: .regularExpression
        )
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func extractSnippet(fromLRC raw: String, tlyric: String? = nil, limit: Int = 5) -> LyricSnippet {
        let originalTimed = parseTimedLines(raw)
        let originalLines = originalTimed.map(\.text)

        guard !originalLines.isEmpty else { return .empty }

        if let tlyric, !tlyric.isEmpty {
            let translatedTimed = parseTimedLines(tlyric)
            if !translatedTimed.isEmpty {
                let paired = pairTranslations(original: originalTimed, translated: translatedTimed)
                if !paired.isEmpty {
                    let chosenThree = bestBilingualWindow(in: paired, size: 3)
                    let totalChars = chosenThree.reduce(0) { $0 + $1.original.count + $1.translation.count }
                    let useThree = chosenThree.count == 3 && totalChars <= 135
                    let chosen = useThree ? chosenThree : bestBilingualWindow(in: paired, size: 2)
                    return LyricSnippet(
                        lines: chosen.map(\.original),
                        translations: chosen.map(\.translation)
                    )
                }
            }
        }

        if originalLines.count <= limit {
            return LyricSnippet(lines: originalLines, translations: [])
        }

        let best = bestMonolingualWindow(in: originalLines, size: limit)
        return LyricSnippet(lines: best, translations: [])
    }

    private static func bestBilingualWindow(
        in paired: [(original: String, translation: String)],
        size: Int
    ) -> [(original: String, translation: String)] {
        guard paired.count > size else { return paired }
        let originals = paired.map(\.original)
        let start = bestWindowStart(in: originals, size: size)
        return Array(paired[start..<(start + size)])
    }

    private static func bestMonolingualWindow(in lines: [String], size: Int) -> [String] {
        guard lines.count > size else { return lines }
        let start = bestWindowStart(in: lines, size: size)
        return Array(lines[start..<(start + size)])
    }

    private static func bestWindowStart(in lines: [String], size: Int) -> Int {
        guard lines.count > size else { return 0 }

        var frequencies: [String: Int] = [:]
        let normalizedLines = lines.map { normalizeForFrequency($0) }
        for norm in normalizedLines where !norm.isEmpty {
            frequencies[norm, default: 0] += 1
        }

        var bestStart = 0
        var bestScore = -Double.infinity

        for start in 0...(lines.count - size) {
            var score = 0.0
            let centerRatio = (Double(start) + Double(size) / 2.0) / Double(lines.count)
            if (0.25...0.75).contains(centerRatio) {
                score += 3.0
            } else if centerRatio < 0.12 || centerRatio > 0.90 {
                score -= 2.5
            }

            for offset in 0..<size {
                let line = lines[start + offset]
                let norm = normalizedLines[start + offset]
                let repeatCount = frequencies[norm] ?? 1
                if repeatCount >= 2 {
                    score += 6.0
                }

                let length = line.count
                if (6...28).contains(length) {
                    score += 4.0
                } else if length <= 3 {
                    score -= 3.0
                } else if length > 42 {
                    score -= 2.0
                }
            }

            if score > bestScore {
                bestScore = score
                bestStart = start
            }
        }

        return bestStart
    }

    private static func normalizeForFrequency(_ line: String) -> String {
        line.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    private static func pairTranslations(
        original: [TimedLine],
        translated: [TimedLine]
    ) -> [(original: String, translation: String)] {
        var pairs: [(original: String, translation: String)] = []
        for line in original where line.timeMs >= 0 {
            guard let match = translated.min(by: {
                abs($0.timeMs - line.timeMs) < abs($1.timeMs - line.timeMs)
            }),
            abs(match.timeMs - line.timeMs) <= 500,
            match.text != line.text else {
                continue
            }
            pairs.append((line.text, match.text))
        }
        return pairs
    }

    private static func parseTimedLines(_ raw: String) -> [TimedLine] {
        let metadataPrefixes = [
            "作词", "作曲", "编曲", "制作人", "混音", "母带", "吉他", "贝斯", "鼓", "和声",
            "录音", "监制", "出品", "词曲", "lyricist", "composer", "arranger", "producer",
            "written by", "lyrics by", "music by", "by ",
        ]

        var result: [TimedLine] = []
        for rawLine in raw.components(separatedBy: .newlines) {
            let timeMs = firstTimestampMs(in: rawLine) ?? -1
            let stripped = rawLine.replacingOccurrences(
                of: #"\[[^\]]*\]"#,
                with: "",
                options: .regularExpression
            ).trimmingCharacters(in: .whitespacesAndNewlines)

            guard !stripped.isEmpty else { continue }
            let lower = stripped.lowercased()
            if metadataPrefixes.contains(where: { lower.hasPrefix($0) || lower.contains("\($0):") || lower.contains("\($0)：") }) {
                continue
            }
            if stripped.hasPrefix("纯音乐") || stripped.contains("请欣赏") {
                continue
            }
            if ["music", "instrumental", "intro", "outro", "oh", "ooh", "yeah", "la", "la la"].contains(lower) {
                continue
            }
            result.append(TimedLine(timeMs: timeMs, text: stripped))
        }
        return result
    }

    private static func firstTimestampMs(in line: String) -> Int? {
        guard let start = line.firstIndex(of: "["),
              let end = line[start...].firstIndex(of: "]") else {
            return nil
        }
        let token = String(line[line.index(after: start)..<end])
        let parts = token.split(separator: ":")
        guard parts.count == 2,
              let minutes = Int(parts[0]) else {
            return nil
        }
        let secParts = parts[1].split(separator: ".")
        guard let seconds = Int(secParts[0]) else {
            return nil
        }
        var millis = 0
        if secParts.count > 1 {
            let frac = String(secParts[1].prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            millis = Int(frac) ?? 0
        }
        return (minutes * 60 + seconds) * 1000 + millis
    }
}
