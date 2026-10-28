import AppKit
import Foundation

// Run with Scripts/test-reader.sh; no player installation or playback required.
@main
struct NowPlayingReaderTests {
    static func main() throws {
        let reader = NowPlayingReader()
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32
        )!
        bitmap.setColor(.red, atX: 0, y: 0)
        let cover = bitmap.representation(using: .png, properties: [:])!
        var fixture: [String: Any] = [
            "kMRMediaRemoteNowPlayingInfoClientBundleIdentifier": "com.tencent.QQMusicMac",
            "kMRMediaRemoteNowPlayingInfoTitle": "测试歌曲",
            "kMRMediaRemoteNowPlayingInfoArtist": "测试歌手",
            "kMRMediaRemoteNowPlayingInfoAlbum": "测试专辑",
            "kMRMediaRemoteNowPlayingInfoPlaybackRate": 1,
            "kMRMediaRemoteNowPlayingInfoArtworkData": cover.base64EncodedString(),
        ]

        func parse() throws -> NowPlayingReadResult {
            let json = try JSONSerialization.data(withJSONObject: fixture)
            return try reader.parse(Data("CLI diagnostic\n".utf8) + json + Data("\n".utf8))
        }

        let playing = try parse()
        precondition(playing.snapshot.sourceBundleID == "com.tencent.QQMusicMac")
        precondition(NowPlayingSource.displayName(for: playing.snapshot.sourceBundleID) == "QQ 音乐")
        precondition(playing.snapshot.title == "测试歌曲")
        precondition(playing.snapshot.artist == "测试歌手")
        precondition(playing.snapshot.album == "测试专辑")
        precondition(playing.snapshot.isPlaying && playing.snapshot.hasArtwork)
        precondition(playing.artworkData == cover)

        fixture["kMRMediaRemoteNowPlayingInfoPlaybackRate"] = "0"
        fixture.removeValue(forKey: "kMRMediaRemoteNowPlayingInfoArtworkData")
        let paused = try parse()
        precondition(!paused.snapshot.isPlaying && !paused.snapshot.hasArtwork)
        precondition(paused.artworkData == nil)

        fixture["kMRMediaRemoteNowPlayingInfoTitle"] = ""
        fixture["kMRMediaRemoteNowPlayingInfoArtist"] = ""
        let missing = try parse()
        precondition(missing.snapshot.title == "未知歌曲")
        precondition(missing.snapshot.artist == "未知歌手")

        for bundleID in NowPlayingSource.displayNames.keys {
            fixture["kMRMediaRemoteNowPlayingInfoClientBundleIdentifier"] = bundleID
            let result = try parse()
            precondition(result.snapshot.sourceBundleID == bundleID)
        }
        fixture["kMRMediaRemoteNowPlayingInfoClientBundleIdentifier"] = "com.example.unsupported"
        let unsupported = try parse()
        precondition(unsupported.snapshot == .empty)
        do {
            _ = try reader.parse(Data("invalid output".utf8))
            preconditionFailure("Malformed output should throw")
        } catch is CocoaError {
            // Expected: corrupt CLI output must remain an error, not stale data.
        }
        print("PASS: QQ Music metadata/artwork, pause, missing fields, existing players, unsupported source, malformed output")
    }
}
