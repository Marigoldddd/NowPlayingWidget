import Foundation

enum NowPlayingSource {
    static let displayNames: [String: String] = [
        "com.netease.163music": "网易云音乐",
        "com.tencent.QQMusicMac": "QQ 音乐",
        "com.apple.Music": "Apple Music",
        "com.spotify.client": "Spotify",
    ]

    static func displayName(for bundleID: String) -> String? {
        displayNames[bundleID]
    }
}

enum WidgetTheme: String, Codable, CaseIterable, Identifiable {
    case classic
    case vinyl
    case poster

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classic: return "经典卡片"
        case .vinyl: return "黑胶唱片"
        case .poster: return "全屏海报"
        }
    }

    var subtitle: String {
        switch self {
        case .classic: return "圆角封面搭配主色渐变"
        case .vinyl: return "圆形黑胶盘面与极简唱针"
        case .poster: return "封面铺满卡片与深色遮罩"
        }
    }

    var systemImage: String {
        switch self {
        case .classic: return "rectangle.inset.filled"
        case .vinyl: return "opticaldisc"
        case .poster: return "photo.fill"
        }
    }
}

enum WidgetSizeClass: String, Codable, CaseIterable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .small: return "小号"
        case .medium: return "中号"
        case .large: return "大号"
        }
    }
}

struct WidgetAppearance: Codable, Equatable {
    var theme: WidgetTheme
    var smallTheme: WidgetTheme?
    var mediumTheme: WidgetTheme?
    var largeTheme: WidgetTheme?

    static let `default` = WidgetAppearance(theme: .classic)

    var usesPerSizeThemes: Bool {
        smallTheme != nil || mediumTheme != nil || largeTheme != nil
    }

    func theme(for sizeClass: WidgetSizeClass) -> WidgetTheme {
        switch sizeClass {
        case .small: return smallTheme ?? theme
        case .medium: return mediumTheme ?? theme
        case .large: return largeTheme ?? theme
        }
    }

    mutating func setTheme(_ newTheme: WidgetTheme, for sizeClass: WidgetSizeClass) {
        switch sizeClass {
        case .small: smallTheme = newTheme
        case .medium: mediumTheme = newTheme
        case .large: largeTheme = newTheme
        }
    }
}

enum NowPlayingShared {
    static let widgetKind = "com.marigold.NowPlayingWidget.widget"
    static let widgetBundleID = "com.marigold.NowPlayingWidget.widget"
    static let supportFolderName = "NowPlayingWidget"
    static let dataFileName = "nowplaying.json"
    static let artworkFileName = "cover.jpg"
    static let idleArtworkFileName = "idle-cover.png"
    static let appearanceFileName = "appearance.json"
    static let playbackCommandFileName = "playback-command.json"

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

    static func readableIdleArtworkURLs() -> [URL] {
        var urls: [URL] = []
        urls.append(widgetSupportURL().appendingPathComponent(idleArtworkFileName))
        if let localSupportURL = localSupportURL() {
            urls.append(localSupportURL.appendingPathComponent(idleArtworkFileName))
        }
        return unique(urls)
    }

    static func writablePlaybackCommandURLs() -> [URL] {
        writableContainerURLs().map {
            $0.appendingPathComponent(playbackCommandFileName)
        }
    }

    static func readablePlaybackCommandURLs() -> [URL] {
        writablePlaybackCommandURLs()
    }

    static func readableAppearanceURLs() -> [URL] {
        writableContainerURLs().map {
            $0.appendingPathComponent(appearanceFileName)
        }
    }

    static func loadAppearance() -> WidgetAppearance {
        for url in readableAppearanceURLs()
        where FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url),
                  let appearance = try? JSONDecoder().decode(WidgetAppearance.self, from: data) else {
                continue
            }
            return appearance
        }
        return .default
    }

    static func saveAppearance(_ appearance: WidgetAppearance) throws {
        let data = try JSONEncoder().encode(appearance)
        for container in writableContainerURLs() {
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
            let url = container.appendingPathComponent(appearanceFileName)
            try data.write(to: url, options: .atomic)
        }
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
    var lyricLines: [String]
    var lyricTranslations: [String]

    static let empty = NowPlayingSnapshot(
        title: "风声暂代旋律",
        artist: "等待同步",
        album: "",
        isPlaying: false,
        sourceBundleID: "",
        updatedAt: Date(timeIntervalSince1970: 0),
        hasArtwork: false,
        backgroundRed: 0.64,
        backgroundGreen: 0.10,
        backgroundBlue: 0.13,
        lyricLines: [],
        lyricTranslations: []
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
        backgroundBlue: Double = 0.13,
        lyricLines: [String] = [],
        lyricTranslations: [String] = []
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
        self.lyricLines = lyricLines
        self.lyricTranslations = lyricTranslations
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
        lyricLines = try container.decodeIfPresent([String].self, forKey: .lyricLines) ?? []
        lyricTranslations = try container.decodeIfPresent([String].self, forKey: .lyricTranslations) ?? []
    }
}
