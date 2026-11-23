import AppKit
import Foundation

final class HighResArtworkResolver {
    private struct CacheKey: Hashable {
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
        title: String,
        artist: String,
        album: String,
        currentArtwork: Data?
    ) -> Data? {
        guard !title.isEmpty, title != "未知歌曲" else { return nil }
        if let currentArtwork, isHighResolution(currentArtwork) {
            return nil
        }

        let key = CacheKey(title: title, artist: artist, album: album)

        lock.lock()
        if let entry = cache[key] {
            lock.unlock()
            if case let .resolved(data) = entry {
                return data
            }
            return nil
        }
        if inFlight.contains(key) {
            lock.unlock()
            return nil
        }
        inFlight.insert(key)
        lock.unlock()

        Task.detached(priority: .utility) { [weak self] in
            await self?.fetchAndCache(key: key)
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

    private func fetchAndCache(key: CacheKey) async {
        let fetched = await searchArtwork(title: key.title, artist: key.artist)
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

    private func searchArtwork(title: String, artist: String) async -> Data? {
        let cleanArtist = (artist == "未知歌手") ? "" : artist
        let strippedTitle = stripParentheticalSuffix(title)

        var queries: [String] = []
        queries.append([title, cleanArtist].filter { !$0.isEmpty }.joined(separator: " "))
        if strippedTitle != title, !strippedTitle.isEmpty {
            queries.append([strippedTitle, cleanArtist].filter { !$0.isEmpty }.joined(separator: " "))
        }

        for query in queries {
            if let url = await queryITunesArtworkURL(term: query),
               let data = await downloadData(from: url) {
                return data
            }
        }

        for query in queries {
            if let url = await queryDeezerArtworkURL(term: query),
               let data = await downloadData(from: url) {
                return data
            }
        }

        return nil
    }

    private func queryITunesArtworkURL(term: String) async -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "5"),
        ]
        guard let url = components?.url,
              let data = await downloadData(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            return nil
        }

        for item in results {
            guard let artwork100 = item["artworkUrl100"] as? String else { continue }
            let highResString = artwork100
                .replacingOccurrences(of: "100x100bb", with: "600x600bb")
                .replacingOccurrences(of: "100x100", with: "600x600")
            if let highResURL = URL(string: highResString) {
                return highResURL
            }
        }
        return nil
    }

    private func queryDeezerArtworkURL(term: String) async -> URL? {
        var components = URLComponents(string: "https://api.deezer.com/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: term),
            URLQueryItem(name: "limit", value: "3"),
        ]
        guard let url = components?.url,
              let data = await downloadData(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["data"] as? [[String: Any]] else {
            return nil
        }

        for item in results {
            guard let album = item["album"] as? [String: Any] else { continue }
            let urlString = (album["cover_xl"] as? String)
                ?? (album["cover_big"] as? String)
            if let urlString, let artworkURL = URL(string: urlString) {
                return artworkURL
            }
        }
        return nil
    }

    private func downloadData(from url: URL) async -> Data? {
        do {
            let (data, response) = try await session.data(from: url)
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
}
