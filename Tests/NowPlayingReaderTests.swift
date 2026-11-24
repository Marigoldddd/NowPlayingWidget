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

        L10n.overrideLanguage = .zhHans
        let playing = try parse()
        precondition(playing.snapshot.sourceBundleID == "com.tencent.QQMusicMac")
        precondition(NowPlayingSource.displayName(for: playing.snapshot.sourceBundleID) == "QQ 音乐")
        precondition(NowPlayingSource.displayName(for: "com.netease.163music", language: .en) == "NetEase Music")
        precondition(playing.snapshot.title == "测试歌曲")
        precondition(playing.snapshot.artist == "测试歌手")
        precondition(playing.snapshot.album == "测试专辑")
        precondition(playing.snapshot.isPlaying && playing.snapshot.hasArtwork)
        precondition(playing.artworkData == cover)
        precondition(reader.backgroundColorComputeCount == 1)

        // Repeated reads with identical artwork should reuse cached background color.
        let cachedRead = try parse()
        precondition(cachedRead.artworkData == cover)
        precondition(cachedRead.snapshot.backgroundRed == playing.snapshot.backgroundRed)
        precondition(cachedRead.snapshot.backgroundGreen == playing.snapshot.backgroundGreen)
        precondition(cachedRead.snapshot.backgroundBlue == playing.snapshot.backgroundBlue)
        precondition(reader.backgroundColorComputeCount == 1)

        // Changing artwork should recompute background color.
        let blueBitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 4, bitsPerPixel: 32
        )!
        blueBitmap.setColor(NSColor(calibratedRed: 0, green: 0, blue: 1, alpha: 1), atX: 0, y: 0)
        let blueCover = blueBitmap.representation(using: .png, properties: [:])!
        fixture["kMRMediaRemoteNowPlayingInfoArtworkData"] = blueCover.base64EncodedString()
        let changedCover = try parse()
        precondition(changedCover.artworkData == blueCover)
        precondition(changedCover.snapshot.backgroundBlue > changedCover.snapshot.backgroundRed)
        precondition(reader.backgroundColorComputeCount == 2)

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

        for bundleID in NowPlayingSource.displayNameKeys.keys {
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
        for theme in WidgetTheme.allCases {
            let encoded = try JSONEncoder().encode(WidgetAppearance(theme: theme))
            let decoded = try JSONDecoder().decode(WidgetAppearance.self, from: encoded)
            precondition(decoded.theme == theme)
        }
        var perSize = WidgetAppearance(theme: .classic)
        perSize.setTheme(.vinyl, for: .small)
        perSize.setTheme(.poster, for: .large)
        let perSizeDecoded = try JSONDecoder().decode(WidgetAppearance.self, from: try JSONEncoder().encode(perSize))
        precondition(perSizeDecoded.theme(for: .small) == .vinyl)
        precondition(perSizeDecoded.theme(for: .medium) == .classic)
        precondition(perSizeDecoded.theme(for: .large) == .poster)
        precondition(WidgetDeepLink(url: PlaybackCommand.next.url) == .playback(.next))
        if let openURL = WidgetDeepLink.openPlayerURL(bundleID: "com.netease.163music") {
            precondition(WidgetDeepLink(url: openURL) == .openPlayer(bundleID: "com.netease.163music"))
        } else {
            preconditionFailure("Expected valid openPlayerURL")
        }
        precondition(WidgetDeepLink.openPlayerURL(bundleID: "") == nil)

        var cliCallCount = 0
        let idleReader = NowPlayingReader(
            hasRunningPlayer: { false },
            runCLI: {
                cliCallCount += 1
                return Data()
            }
        )
        let idleRead = try idleReader.read()
        precondition(idleRead.snapshot == .empty)
        precondition(idleRead.artworkData == nil)
        precondition(cliCallCount == 0)

        let lrcSample = """
        [00:00.000] 作词 : ひとみ
        [00:00.224] 作曲 : ひとみ
        [00:00.449] 君が僕に見せてくれた
        [00:05.713] 世界はとても綺麗だったな
        [00:11.460]
        [00:22.822] 書架の隙間に住まう
        [00:25.417] 一輪の花は
        """
        let snippet = LyricResolver.extractSnippet(fromLRC: lrcSample, limit: 5)
        precondition(snippet.lines == [
            "君が僕に見せてくれた",
            "世界はとても綺麗だったな",
            "書架の隙間に住まう",
            "一輪の花は",
        ])
        precondition(snippet.translations.isEmpty)

        let tlyricSample = """
        [by:Test]
        [00:00.449]是你让我看到
        [00:05.713]这世界有多么美丽
        [00:22.822]在栖息于书架缝隙中的
        [00:25.417]一朵花
        """
        let bilingual = LyricResolver.extractSnippet(fromLRC: lrcSample, tlyric: tlyricSample)
        precondition(bilingual.lines == [
            "君が僕に見せてくれた",
            "世界はとても綺麗だったな",
            "書架の隙間に住まう",
        ])
        precondition(bilingual.translations == [
            "是你让我看到",
            "这世界有多么美丽",
            "在栖息于书架缝隙中的",
        ])

        let chorusLRC = """
        [00:01.000] Yeah
        [00:05.000] First intro line here
        [00:10.000] Second intro line here
        [00:20.000] Shining bright like a star tonight
        [00:25.000] Dancing under the neon light
        [00:30.000] Never gonna let you fade away
        [00:40.000] Verse two line one here
        [00:45.000] Verse two line two here
        [00:55.000] Shining bright like a star tonight
        [01:00.000] Dancing under the neon light
        [01:05.000] Never gonna let you fade away
        """
        let chorusSnippet = LyricResolver.extractSnippet(fromLRC: chorusLRC, limit: 3)
        precondition(chorusSnippet.lines == [
            "Shining bright like a star tonight",
            "Dancing under the neon light",
            "Never gonna let you fade away",
        ])

        precondition(SemanticVersion("v1.0.18")! > SemanticVersion("1.0.9")!)
        precondition(SemanticVersion("1.0.18") == SemanticVersion("v1.0.18.0"))
        precondition(AppUpdater.isTrustedDownloadURL(URL(string: "https://github.com/Marigoldddd/NowPlayingWidget/releases/download/v1.0.18/app.dmg")!))
        precondition(!AppUpdater.isTrustedDownloadURL(URL(string: "https://evil.example.com/app.dmg")!))

        let sampleReleaseJSON = """
        {
          "tag_name": "v1.0.18",
          "html_url": "https://github.com/Marigoldddd/NowPlayingWidget/releases/tag/v1.0.18",
          "body": "Bug fixes",
          "assets": [
            {
              "name": "NowPlayingWidget-v1.0.18-macOS-universal.dmg",
              "browser_download_url": "https://github.com/Marigoldddd/NowPlayingWidget/releases/download/v1.0.18/NowPlayingWidget-v1.0.18-macOS-universal.dmg"
            }
          ]
        }
        """.data(using: .utf8)!
        let parsedRelease = try AppUpdater.parseRelease(from: sampleReleaseJSON)
        precondition(parsedRelease.version == SemanticVersion("1.0.18"))
        precondition(parsedRelease.dmgName == "NowPlayingWidget-v1.0.18-macOS-universal.dmg")
        precondition(parsedRelease.dmgURL != nil)

        // ListeningHistoryStore: threshold commit, rapid skip exclusion, cross-player stats & heatmap
        let historyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NowPlayingHistoryTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: historyDir) }
        let store = ListeningHistoryStore(directoryURL: historyDir, commitThresholdSeconds: 10)
        let t0 = Date(timeIntervalSince1970: 1_795_500_000)

        let songA = NowPlayingSnapshot(
            title: "運命の人",
            artist: "『ユイカ』",
            album: "紺色に憧れて",
            isPlaying: true,
            sourceBundleID: "com.netease.163music",
            updatedAt: t0,
            hasArtwork: false,
            backgroundRed: 0,
            backgroundGreen: 0,
            backgroundBlue: 0
        )
        let songB = NowPlayingSnapshot(
            title: "Cruel Summer",
            artist: "Taylor Swift",
            album: "Lover",
            isPlaying: true,
            sourceBundleID: "com.spotify.client",
            updatedAt: t0,
            hasArtwork: false,
            backgroundRed: 0,
            backgroundGreen: 0,
            backgroundBlue: 0
        )

        precondition(!store.record(snapshot: songA, artworkURL: nil, at: t0))
        precondition(!store.record(snapshot: songA, artworkURL: nil, at: t0.addingTimeInterval(5)))
        precondition(store.record(snapshot: songA, artworkURL: nil, at: t0.addingTimeInterval(11)))
        // Rapid skip on songB (<10s) should not commit a play
        precondition(!store.record(snapshot: songB, artworkURL: nil, at: t0.addingTimeInterval(20)))
        precondition(store.record(snapshot: songB, artworkURL: nil, at: t0.addingTimeInterval(32)))

        let summary = store.stats(for: .all, now: t0.addingTimeInterval(40), language: .zhHans)
        precondition(summary.playCount == 2)
        precondition(summary.playerDistribution.count == 2)
        precondition(summary.topTracks.count == 2)
        let heatmap = store.heatmap(weeks: 4, now: t0.addingTimeInterval(40), language: .zhHans)
        precondition(heatmap.currentStreakDays == 1)
        precondition(heatmap.activeDaysCount == 1)

        let reloaded = ListeningHistoryStore(directoryURL: historyDir, commitThresholdSeconds: 10)
        precondition(reloaded.database.entries.count == 2)
        reloaded.clearHistory()
        precondition(reloaded.database.entries.isEmpty)

        print("PASS: QQ Music metadata/artwork, pause, missing fields, existing players, unsupported source, malformed output, themes, deep links, zero-process idle, bilingual lyrics, chorus scoring, updater, listening history")
        try WidgetSyncPipelineTests.run()
    }
}
