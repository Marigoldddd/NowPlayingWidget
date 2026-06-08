import AppKit
import Foundation

struct NowPlayingReadResult {
    var snapshot: NowPlayingSnapshot
    var artworkData: Data?
}

final class NowPlayingReader {
    private let executable = "/opt/homebrew/bin/nowplaying-cli"
    private let neteaseBundleID = "com.netease.163music"

    func read() async throws -> NowPlayingReadResult {
        let raw = try runNowPlayingCLI()
        let json = try extractJSONObject(from: raw)
        let object = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        let info = object ?? [:]

        let sourceBundleID = string(info, "kMRMediaRemoteNowPlayingInfoClientBundleIdentifier")
        guard sourceBundleID == neteaseBundleID else {
            return NowPlayingReadResult(snapshot: .empty, artworkData: nil)
        }

        let title = string(info, "kMRMediaRemoteNowPlayingInfoTitle")
        let artist = string(info, "kMRMediaRemoteNowPlayingInfoArtist")
        let album = string(info, "kMRMediaRemoteNowPlayingInfoAlbum")
        let playbackRate = number(info, "kMRMediaRemoteNowPlayingInfoPlaybackRate")
        let artworkBase64 = string(info, "kMRMediaRemoteNowPlayingInfoArtworkData")
        let artworkData = Data(base64Encoded: artworkBase64)
        let backgroundColor = backgroundColor(from: artworkData)

        let snapshot = NowPlayingSnapshot(
            title: title.isEmpty ? "未知歌曲" : title,
            artist: artist.isEmpty ? "未知歌手" : artist,
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["get-raw"]

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        try process.run()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        if !data.isEmpty {
            return data
        }

        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        if !errorData.isEmpty {
            return errorData
        }

        return Data()
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
