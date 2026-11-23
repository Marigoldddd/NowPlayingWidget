import AppKit
import Foundation

struct NowPlayingReadResult {
    var snapshot: NowPlayingSnapshot
    var artworkData: Data?
}

final class NowPlayingReader {
    private struct CachedArtwork {
        let base64: String
        let data: Data?
        let backgroundColor: (red: Double, green: Double, blue: Double)
    }

    private let artworkResolver: HighResArtworkResolver?
    private let cacheLock = NSLock()
    private var cachedArtwork: CachedArtwork?
    private var cachedHighResKey: String?
    private var cachedHighResColor: (red: Double, green: Double, blue: Double)?
    private(set) var backgroundColorComputeCount = 0

    init(artworkResolver: HighResArtworkResolver? = nil) {
        self.artworkResolver = artworkResolver
    }

    func read() throws -> NowPlayingReadResult {
        try parse(runNowPlayingCLI())
    }

    func parse(_ raw: Data) throws -> NowPlayingReadResult {
        let json = try extractJSONObject(from: raw)
        let object = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        let info = object ?? [:]

        let sourceBundleID = string(info, "kMRMediaRemoteNowPlayingInfoClientBundleIdentifier")
        guard NowPlayingSource.displayName(for: sourceBundleID) != nil else {
            return NowPlayingReadResult(snapshot: .empty, artworkData: nil)
        }

        let rawTitle = string(info, "kMRMediaRemoteNowPlayingInfoTitle")
        let rawArtist = string(info, "kMRMediaRemoteNowPlayingInfoArtist")
        let resolvedTitle = rawTitle.isEmpty ? "未知歌曲" : rawTitle
        let resolvedArtist = rawArtist.isEmpty ? "未知歌手" : rawArtist
        let album = string(info, "kMRMediaRemoteNowPlayingInfoAlbum")
        let playbackRate = number(info, "kMRMediaRemoteNowPlayingInfoPlaybackRate")
        let artworkBase64 = string(info, "kMRMediaRemoteNowPlayingInfoArtworkData")
        var (artworkData, backgroundColor) = resolveArtwork(from: artworkBase64)

        if let highResData = artworkResolver?.resolveIfNeeded(
            title: resolvedTitle,
            artist: resolvedArtist,
            album: album,
            currentArtwork: artworkData
        ) {
            artworkData = highResData
            backgroundColor = highResBackgroundColor(
                for: highResData,
                cacheKey: "\(resolvedTitle)\u{1f}\(resolvedArtist)\u{1f}\(album)"
            )
        }

        let snapshot = NowPlayingSnapshot(
            title: resolvedTitle,
            artist: resolvedArtist,
            album: album,
            isPlaying: playbackRate > 0,
            sourceBundleID: sourceBundleID,
            updatedAt: Date(),
            hasArtwork: artworkData != nil,
            backgroundRed: backgroundColor.red,
            backgroundGreen: backgroundColor.green,
            backgroundBlue: backgroundColor.blue
        )

        return NowPlayingReadResult(snapshot: snapshot, artworkData: artworkData)
    }

    private func runNowPlayingCLI() throws -> Data {
        try NowPlayingCLI.run(arguments: ["get-raw"])
    }

    private func extractJSONObject(from data: Data) throws -> Data {
        guard let text = String(data: data, encoding: .utf8),
              let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start <= end else {
            throw CocoaError(.fileReadCorruptFile)
        }

        return Data(text[start...end].utf8)
    }

    private func string(_ info: [String: Any], _ key: String) -> String {
        info[key] as? String ?? ""
    }

    private func number(_ info: [String: Any], _ key: String) -> Double {
        if let value = info[key] as? Double { return value }
        if let value = info[key] as? Int { return Double(value) }
        if let value = info[key] as? String { return Double(value) ?? 0 }
        return 0
    }

    private func resolveArtwork(
        from base64: String
    ) -> (data: Data?, backgroundColor: (red: Double, green: Double, blue: Double)) {
        guard !base64.isEmpty else {
            cacheLock.lock()
            cachedArtwork = nil
            cacheLock.unlock()
            return (nil, (0.64, 0.10, 0.13))
        }

        cacheLock.lock()
        if let cached = cachedArtwork, cached.base64 == base64 {
            cacheLock.unlock()
            return (cached.data, cached.backgroundColor)
        }
        cacheLock.unlock()

        let artworkData = Data(base64Encoded: base64)
        let color = backgroundColor(from: artworkData)

        cacheLock.lock()
        cachedArtwork = CachedArtwork(base64: base64, data: artworkData, backgroundColor: color)
        backgroundColorComputeCount += 1
        cacheLock.unlock()

        return (artworkData, color)
    }

    private func highResBackgroundColor(
        for data: Data,
        cacheKey: String
    ) -> (red: Double, green: Double, blue: Double) {
        cacheLock.lock()
        if cachedHighResKey == cacheKey, let cached = cachedHighResColor {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let color = backgroundColor(from: data)

        cacheLock.lock()
        cachedHighResKey = cacheKey
        cachedHighResColor = color
        backgroundColorComputeCount += 1
        cacheLock.unlock()

        return color
    }

    private func backgroundColor(from artworkData: Data?) -> (red: Double, green: Double, blue: Double) {
        guard let artworkData,
              let image = NSImage(data: artworkData),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return (0.64, 0.10, 0.13)
        }

        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        let step = max(1, min(width, height) / 32)
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var count = 0.0

        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    continue
                }
                red += color.redComponent
                green += color.greenComponent
                blue += color.blueComponent
                count += 1
            }
        }

        guard count > 0 else {
            return (0.64, 0.10, 0.13)
        }

        let average = NSColor(
            srgbRed: red / count,
            green: green / count,
            blue: blue / count,
            alpha: 1
        )

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)

        let displaySaturation = min(max(saturation * 1.55, 0.30), 0.88)
        let displayBrightness = min(max(brightness * 0.50, 0.18), 0.42)
        let displayColor = NSColor(
            hue: hue,
            saturation: displaySaturation,
            brightness: displayBrightness,
            alpha: 1
        ).usingColorSpace(.sRGB) ?? average

        return (
            Double(displayColor.redComponent),
            Double(displayColor.greenComponent),
            Double(displayColor.blueComponent)
        )
    }
}
