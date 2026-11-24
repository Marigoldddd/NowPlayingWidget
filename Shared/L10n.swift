import Foundation

enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case system
    case zhHans = "zh-Hans"
    case en

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return L10n.tr("language.system")
        case .zhHans: return "简体中文"
        case .en: return "English"
        }
    }
}

enum L10n {
    private static let lock = NSLock()
    private static var _overrideLanguage: AppLanguage?

    static var overrideLanguage: AppLanguage? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _overrideLanguage
        }
        set {
            lock.lock()
            _overrideLanguage = newValue
            lock.unlock()
        }
    }

    static func resolvedLanguageCode(for language: AppLanguage? = nil) -> String {
        let effective = language ?? overrideLanguage ?? .system
        switch effective {
        case .zhHans:
            return "zh-Hans"
        case .en:
            return "en"
        case .system:
            for preferred in Locale.preferredLanguages {
                if preferred.hasPrefix("zh") {
                    return "zh-Hans"
                }
                if preferred.hasPrefix("en") {
                    return "en"
                }
            }
            return "en"
        }
    }

    static func locale(for language: AppLanguage? = nil) -> Locale {
        Locale(identifier: resolvedLanguageCode(for: language) == "zh-Hans" ? "zh_CN" : "en_US")
    }

    static func tr(_ key: String, language: AppLanguage? = nil) -> String {
        let code = resolvedLanguageCode(for: language)
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            let value = bundle.localizedString(forKey: key, value: "__MISSING__", table: "Localizable")
            if value != "__MISSING__" {
                return value
            }
        }
        let fallback = Bundle.main.localizedString(forKey: key, value: "__MISSING__", table: "Localizable")
        if fallback != "__MISSING__" {
            return fallback
        }
        return testFallbacks[code]?[key] ?? testFallbacks["en"]?[key] ?? key
    }

    static func fmt(_ key: String, language: AppLanguage? = nil, _ args: CVarArg...) -> String {
        let format = tr(key, language: language)
        return String(format: format, locale: locale(for: language), arguments: args)
    }

    private static let testFallbacks: [String: [String: String]] = [
        "zh-Hans": [
            "source.netease": "网易云音乐",
            "source.qqmusic": "QQ 音乐",
            "source.applemusic": "Apple Music",
            "source.spotify": "Spotify",
            "song.unknown": "未知歌曲",
            "artist.unknown": "未知歌手",
            "placeholder.title": "风声暂代旋律",
            "placeholder.artist": "等待同步",
        ],
        "en": [
            "source.netease": "NetEase Music",
            "source.qqmusic": "QQ Music",
            "source.applemusic": "Apple Music",
            "source.spotify": "Spotify",
            "song.unknown": "Unknown Song",
            "artist.unknown": "Unknown Artist",
            "placeholder.title": "Wind Takes the Melody",
            "placeholder.artist": "Waiting to Sync",
        ],
    ]
}
