import AppKit
import Foundation

final class HighResArtworkResolver {
    private struct CacheKey: Hashable {
        let sourceBundleID: String
        let title: String
        let artist: String
        let album: String
    }

    private enum CacheEntry {
        case resolved(Data)
        case missing
    }

    private let lock = NSLock()
    private var cache: [CacheKey: CacheEntry] = [:]
    private var cacheOrder: [CacheKey] = []
    private var inFlight: Set<CacheKey> = []
    private let maxCacheCount = 50
    private let minimumDimension = 300
    private let maxNormalizedPixelDifference = 0.14
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

    /// Returns cached high-res artwork if available, or triggers an async lookup when the
    /// provided artwork is smaller than 300px.
    func resolveIfNeeded(
        sourceBundleID: String,
        title: String,
        artist: String,
        album: String,
        currentArtwork: Data?
    ) -> Data? {
        guard !title.isEmpty, title != "未知歌曲", title != "Unknown Song" else { return nil }
        if let currentArtwork, isHighResolution(currentArtwork) {
            return nil
        }

        let key = CacheKey(
            sourceBundleID: sourceBundleID,
            title: title,
            artist: artist,
            album: album
        )

        let cachedResult: (hit: Bool, data: Data?) = lock.withLock {
            if let entry = cache[key] {
                if case let .resolved(data) = entry {
                    return (true, data)
                }
                return (true, nil)
            }
            if inFlight.contains(key) {
                return (true, nil)
            }
            inFlight.insert(key)
            return (false, nil)
        }

        if cachedResult.hit {
            return cachedResult.data
        }

        let referenceThumbnail = currentArtwork.flatMap { Self.normalizedThumbnail($0) }
        Task.detached(priority: .utility) { [weak self] in
            await self?.fetchAndCache(key: key, referenceThumbnail: referenceThumbnail)
        }
        return nil
    }

    func isHighResolution(_ data: Data) -> Bool {
        guard let image = NSImage(data: data),
              let rep = image.representations.first else {
            return false
        }
        let maxDim = max(rep.pixelsWide, rep.pixelsHigh)
        return maxDim >= minimumDimension
    }

    private func fetchAndCache(key: CacheKey, referenceThumbnail: [UInt8]?) async {
        let fetched = await searchArtwork(key: key, referenceThumbnail: referenceThumbnail)
        if finishFetch(key: key, fetched: fetched) {
            onResolved?()
        }
    }

    private func finishFetch(key: CacheKey, fetched: Data?) -> Bool {
        lock.withLock {
            inFlight.remove(key)
            if let fetched, isHighResolution(fetched) {
                store(key: key, entry: .resolved(fetched))
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

    private func searchArtwork(key: CacheKey, referenceThumbnail: [UInt8]?) async -> Data? {
        let cleanArtist = (key.artist == "未知歌手" || key.artist == "Unknown Artist") ? "" : key.artist
        let strippedTitle = stripParentheticalSuffix(key.title)

        var queries: [String] = []
        queries.append([key.title, cleanArtist].filter { !$0.isEmpty }.joined(separator: " "))
        if strippedTitle != key.title, !strippedTitle.isEmpty {
            queries.append([strippedTitle, cleanArtist].filter { !$0.isEmpty }.joined(separator: " "))
        }

        // For NetEase Music, query NetEase cloudsearch first so we get the exact official album cover.
        if key.sourceBundleID == "com.netease.163music" {
            for query in queries {
                let urls = await queryNetEaseArtworkURLs(term: query, preferredAlbum: key.album)
                if let matched = await pickMatchingArtwork(from: urls, referenceThumbnail: referenceThumbnail) {
                    return matched
                }
            }
        }

        for query in queries {
            let urls = await queryITunesArtworkURLs(term: query, preferredAlbum: key.album)
            if let matched = await pickMatchingArtwork(from: urls, referenceThumbnail: referenceThumbnail) {
                return matched
            }
        }

        for query in queries {
            let urls = await queryDeezerArtworkURLs(term: query, preferredAlbum: key.album)
            if let matched = await pickMatchingArtwork(from: urls, referenceThumbnail: referenceThumbnail) {
                return matched
            }
        }

        return nil
    }

    private func pickMatchingArtwork(from urls: [URL], referenceThumbnail: [UInt8]?) async -> Data? {
        var bestMatch: (data: Data, difference: Double)?

        for url in urls.prefix(5) {
            guard let data = await downloadData(from: url),
                  isHighResolution(data) else {
                continue
            }

            guard let referenceThumbnail else {
                return data
            }

            guard let candidateThumbnail = Self.normalizedThumbnail(data) else {
                continue
            }
            let difference = Self.meanAbsoluteDifference(referenceThumbnail, candidateThumbnail)
            if difference <= maxNormalizedPixelDifference {
                if difference <= 0.05 {
                    return data
                }
                if bestMatch == nil || difference < bestMatch!.difference {
                    bestMatch = (data, difference)
                }
            }
        }

        return bestMatch?.data
    }

    private func queryNetEaseArtworkURLs(term: String, preferredAlbum: String) async -> [URL] {
        var components = URLComponents(string: "https://music.163.com/api/cloudsearch/pc")
        components?.queryItems = [
            URLQueryItem(name: "s", value: term),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "limit", value: "6"),
        ]
        guard let url = components?.url else { return [] }

        var request = URLRequest(url: url)
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")

        guard let data = await downloadData(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let songs = result["songs"] as? [[String: Any]] else {
            return []
        }

        let ordered = songs.sorted { lhs, rhs in
            let lhsAlbum = (lhs["al"] as? [String: Any])?["name"] as? String ?? ""
            let rhsAlbum = (rhs["al"] as? [String: Any])?["name"] as? String ?? ""
            return albumScore(lhsAlbum, preferred: preferredAlbum) > albumScore(rhsAlbum, preferred: preferredAlbum)
        }

        var seen = Set<String>()
        var urls: [URL] = []
        for song in ordered {
            guard let album = song["al"] as? [String: Any],
                  var picUrl = album["picUrl"] as? String,
                  !picUrl.isEmpty else {
                continue
            }
            if picUrl.hasPrefix("http://") {
                picUrl = "https://" + picUrl.dropFirst("http://".count)
            }
            let sized = "\(picUrl)?param=640y640"
            if seen.insert(sized).inserted, let artworkURL = URL(string: sized) {
                urls.append(artworkURL)
            }
        }
        return urls
    }

    private func queryITunesArtworkURLs(term: String, preferredAlbum: String) async -> [URL] {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "6"),
        ]
        guard let url = components?.url,
              let data = await downloadData(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            return []
        }

        let ordered = results.sorted { lhs, rhs in
            let lhsAlbum = lhs["collectionName"] as? String ?? ""
            let rhsAlbum = rhs["collectionName"] as? String ?? ""
            return albumScore(lhsAlbum, preferred: preferredAlbum) > albumScore(rhsAlbum, preferred: preferredAlbum)
        }

        var seen = Set<String>()
        var urls: [URL] = []
        for item in ordered {
            guard let artwork100 = item["artworkUrl100"] as? String else { continue }
            let highResString = artwork100
                .replacingOccurrences(of: "100x100bb", with: "600x600bb")
                .replacingOccurrences(of: "100x100", with: "600x600")
            if seen.insert(highResString).inserted, let highResURL = URL(string: highResString) {
                urls.append(highResURL)
            }
        }
        return urls
    }

    private func queryDeezerArtworkURLs(term: String, preferredAlbum: String) async -> [URL] {
        var components = URLComponents(string: "https://api.deezer.com/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: term),
            URLQueryItem(name: "limit", value: "6"),
        ]
        guard let url = components?.url,
              let data = await downloadData(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["data"] as? [[String: Any]] else {
            return []
        }

        let ordered = results.sorted { lhs, rhs in
            let lhsAlbum = (lhs["album"] as? [String: Any])?["title"] as? String ?? ""
            let rhsAlbum = (rhs["album"] as? [String: Any])?["title"] as? String ?? ""
            return albumScore(lhsAlbum, preferred: preferredAlbum) > albumScore(rhsAlbum, preferred: preferredAlbum)
        }

        var seen = Set<String>()
        var urls: [URL] = []
        for item in ordered {
            guard let album = item["album"] as? [String: Any] else { continue }
            let urlString = (album["cover_xl"] as? String)
                ?? (album["cover_big"] as? String)
            if let urlString, seen.insert(urlString).inserted, let artworkURL = URL(string: urlString) {
                urls.append(artworkURL)
            }
        }
        return urls
    }

    private func albumScore(_ candidate: String, preferred: String) -> Int {
        guard !preferred.isEmpty else { return 0 }
        let lhs = candidate.lowercased()
        let rhs = preferred.lowercased()
        if lhs == rhs { return 2 }
        if lhs.contains(rhs) || rhs.contains(lhs) { return 1 }
        return 0
    }

    private func downloadData(from url: URL) async -> Data? {
        await downloadData(for: URLRequest(url: url))
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

    private static func normalizedThumbnail(_ data: Data) -> [UInt8]? {
        guard let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let size = 16
        let bytesPerRow = size * 4
        var buffer = [UInt8](repeating: 0, count: size * bytesPerRow)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &buffer,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
        return buffer
    }

    private static func meanAbsoluteDifference(_ lhs: [UInt8], _ rhs: [UInt8]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 1.0 }
        var totalDiff = 0
        var channels = 0
        for index in stride(from: 0, to: lhs.count, by: 4) {
            totalDiff += abs(Int(lhs[index]) - Int(rhs[index]))
            totalDiff += abs(Int(lhs[index + 1]) - Int(rhs[index + 1]))
            totalDiff += abs(Int(lhs[index + 2]) - Int(rhs[index + 2]))
            channels += 3
        }
        return Double(totalDiff) / Double(channels * 255)
    }
}
