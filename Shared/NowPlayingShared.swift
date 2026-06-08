import Foundation

enum NowPlayingShared {
    static let widgetKind = "com.marigold.NeteaseNowPlaying.widget"
    static let widgetBundleID = "com.marigold.NeteaseNowPlaying.widget"
    static let supportFolderName = "NeteaseNowPlaying"
    static let dataFileName = "nowplaying.json"
    static let artworkFileName = "cover.jpg"

    static func localSupportURL() -> URL? {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )
        .first?
        .appendingPathComponent(supportFolderName)
    }

    static func widgetSupportURL() -> URL {
        realUserHomeURL()
            .appendingPathComponent("Library")
            .appendingPathComponent("Containers")
            .appendingPathComponent(widgetBundleID)
            .appendingPathComponent("Data")
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent(supportFolderName)
    }

    static func realUserHomeURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let components = home.standardized.pathComponents

        guard let libraryIndex = components.firstIndex(of: "Library"),
              libraryIndex > 1 else {
            return home
        }

        let prefix = components[..<libraryIndex]
        let path: String
        if prefix.first == "/" {
            path = "/" + prefix.dropFirst().joined(separator: "/")
        } else {
            path = prefix.joined(separator: "/")
        }
        return URL(fileURLWithPath: path)
    }

    static func writableContainerURLs() -> [URL] {
        var urls: [URL] = []
        urls.append(widgetSupportURL())
        if let localSupportURL = localSupportURL() {
            urls.append(localSupportURL)
        }
        return unique(urls)
    }

    static func readableDataURLs() -> [URL] {
        var urls: [URL] = []
        urls.append(widgetSupportURL().appendingPathComponent(dataFileName))
        if let localSupportURL = localSupportURL() {
            urls.append(localSupportURL.appendingPathComponent(dataFileName))
        }
        return unique(urls)
    }

    static func readableArtworkURLs() -> [URL] {
        var urls: [URL] = []
        urls.append(widgetSupportURL().appendingPathComponent(artworkFileName))
        if let localSupportURL = localSupportURL() {
            urls.append(localSupportURL.appendingPathComponent(artworkFileName))
        }
        return unique(urls)
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.path).inserted }
    }
}

struct NowPlayingSnapshot: Codable, Equatable {
    var title: String
    var artist: String
    var album: String
    var isPlaying: Bool
    var sourceBundleID: String
    var updatedAt: Date
    var hasArtwork: Bool
    var backgroundRed: Double
    var backgroundGreen: Double
    var backgroundBlue: Double

    static let empty = NowPlayingSnapshot(
        title: "等待网易云音乐",
        artist: "播放歌曲后会自动更新",
        album: "",
        isPlaying: false,
        sourceBundleID: "",
        updatedAt: Date(timeIntervalSince1970: 0),
        hasArtwork: false,
        backgroundRed: 0.64,
        backgroundGreen: 0.10,
        backgroundBlue: 0.13
    )

    init(
        title: String,
        artist: String,
        album: String,
        isPlaying: Bool,
        sourceBundleID: String,
        updatedAt: Date,
        hasArtwork: Bool,
        backgroundRed: Double = 0.64,
        backgroundGreen: Double = 0.10,
        backgroundBlue: Double = 0.13
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.isPlaying = isPlaying
        self.sourceBundleID = sourceBundleID
        self.updatedAt = updatedAt
        self.hasArtwork = hasArtwork
        self.backgroundRed = backgroundRed
        self.backgroundGreen = backgroundGreen
        self.backgroundBlue = backgroundBlue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        artist = try container.decode(String.self, forKey: .artist)
        album = try container.decode(String.self, forKey: .album)
        isPlaying = try container.decode(Bool.self, forKey: .isPlaying)
        sourceBundleID = try container.decode(String.self, forKey: .sourceBundleID)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        hasArtwork = try container.decode(Bool.self, forKey: .hasArtwork)
        backgroundRed = try container.decodeIfPresent(Double.self, forKey: .backgroundRed) ?? 0.64
        backgroundGreen = try container.decodeIfPresent(Double.self, forKey: .backgroundGreen) ?? 0.10
        backgroundBlue = try container.decodeIfPresent(Double.self, forKey: .backgroundBlue) ?? 0.13
    }
}
