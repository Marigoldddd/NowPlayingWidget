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
        subsystem: "com.marigold.NowPlayingWidget",
        category: "PlaybackControl"
    )

    static func run(_ command: PlaybackCommand) throws {
        guard let executable = NowPlayingCLI.executableURL else {
            logger.error("nowplaying-cli not found")
            throw CocoaError(.fileNoSuchFile)
        }

        logger.info(
            "Running \(executable.path, privacy: .private) \(command.rawValue, privacy: .public)"
        )

        _ = try NowPlayingCLI.run(arguments: [command.rawValue])
        logger.info("nowplaying-cli \(command.rawValue, privacy: .public) finished")
        WidgetCenter.shared.reloadTimelines(ofKind: NowPlayingShared.widgetKind)
    }
}
