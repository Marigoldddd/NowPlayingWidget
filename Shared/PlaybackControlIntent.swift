import AppIntents
import Foundation
import OSLog
import WidgetKit

struct PreviousTrackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "上一首"
    static var description = IntentDescription("切换到上一首歌曲。")

    func perform() async throws -> some IntentResult {
        try PlaybackControlRunner.run(.previous)
        return .result()
    }
}

struct PlayTrackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "播放"
    static var description = IntentDescription("开始播放当前歌曲。")

    func perform() async throws -> some IntentResult {
        try PlaybackControlRunner.run(.play)
        return .result()
    }
}

struct PauseTrackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "暂停"
    static var description = IntentDescription("暂停当前歌曲。")

    func perform() async throws -> some IntentResult {
        try PlaybackControlRunner.run(.pause)
        return .result()
    }
}

struct NextTrackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "下一首"
    static var description = IntentDescription("切换到下一首歌曲。")

    func perform() async throws -> some IntentResult {
        try PlaybackControlRunner.run(.next)
        return .result()
    }
}

enum PlaybackCommand: String {
    case previous
    case play
    case pause
    case next
}

enum PlaybackControlRunner {
    private static let logger = Logger(
        subsystem: "com.marigold.NeteaseNowPlaying",
        category: "PlaybackControl"
    )

    private static let executableCandidates = [
        "/opt/homebrew/bin/nowplaying-cli",
        "/usr/local/bin/nowplaying-cli",
    ]

    static func run(_ command: PlaybackCommand) throws {
        guard let executable = executableCandidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            logger.error("nowplaying-cli not found")
            throw CocoaError(.fileNoSuchFile)
        }

        logger.info("Running nowplaying-cli \(command.rawValue, privacy: .public)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [command.rawValue]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let text = String(data: data, encoding: .utf8) ?? ""
            logger.error("nowplaying-cli \(command.rawValue, privacy: .public) failed: \(text, privacy: .public)")
            throw CocoaError(.executableLoad)
        }

        logger.info("nowplaying-cli \(command.rawValue, privacy: .public) finished")
        WidgetCenter.shared.reloadTimelines(ofKind: NowPlayingShared.widgetKind)
    }
}
