import Foundation

enum NowPlayingSource {
    static let displayNameKeys: [String: String] = [
        "com.netease.163music": "source.netease",
        "com.tencent.QQMusicMac": "source.qqmusic",
        "com.apple.Music": "source.applemusic",
        "com.spotify.client": "source.spotify",
    ]

    static func displayName(for bundleID: String, language: AppLanguage? = nil) -> String? {
        guard let key = displayNameKeys[bundleID] else { return nil }
        return L10n.tr(key, language: language)
    }
}

enum WidgetTheme: String, Codable, CaseIterable, Identifiable {
    case classic
    case vinyl
    case poster

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classic: return L10n.tr("theme.classic.name")
        case .vinyl: return L10n.tr("theme.vinyl.name")
        case .poster: return L10n.tr("theme.poster.name")
        }
    }

    var subtitle: String {
        switch self {
        case .classic: return L10n.tr("theme.classic.subtitle")
        case .vinyl: return L10n.tr("theme.vinyl.subtitle")
        case .poster: return L10n.tr("theme.poster.subtitle")
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
        case .small: return L10n.tr("size.small")
        case .medium: return L10n.tr("size.medium")
        case .large: return L10n.tr("size.large")
        }
    }
}

struct WidgetAppearance: Codable, Equatable {
    var theme: WidgetTheme
    var smallTheme: WidgetTheme?
    var mediumTheme: WidgetTheme?
    var largeTheme: WidgetTheme?
    var language: AppLanguage

    static let `default` = WidgetAppearance(theme: .classic)

    init(
        theme: WidgetTheme,
        smallTheme: WidgetTheme? = nil,
        mediumTheme: WidgetTheme? = nil,
        largeTheme: WidgetTheme? = nil,
        language: AppLanguage = .system
    ) {
        self.theme = theme
        self.smallTheme = smallTheme
        self.mediumTheme = mediumTheme
        self.largeTheme = largeTheme
        self.language = language
    }

    private enum CodingKeys: String, CodingKey {
        case theme
        case smallTheme
        case mediumTheme
        case largeTheme
        case language
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        theme = try container.decodeIfPresent(WidgetTheme.self, forKey: .theme) ?? .classic
        smallTheme = try container.decodeIfPresent(WidgetTheme.self, forKey: .smallTheme)
        mediumTheme = try container.decodeIfPresent(WidgetTheme.self, forKey: .mediumTheme)
        largeTheme = try container.decodeIfPresent(WidgetTheme.self, forKey: .largeTheme)
        language = try container.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
    }

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

    static var empty: NowPlayingSnapshot {
        NowPlayingSnapshot(
            title: L10n.tr("placeholder.title"),
            artist: L10n.tr("placeholder.artist"),
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
    }

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
