import AppIntents
import Foundation
import OSLog
import WidgetKit

struct PreviousTrackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Previous Track"
    static var description = IntentDescription("Switch to the previous track.")

    func perform() async throws -> some IntentResult {
        try PlaybackControlRunner.perform(.previous)
        return .result()
    }
}

struct PlayTrackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play"
    static var description = IntentDescription("Start playing the current track.")

    func perform() async throws -> some IntentResult {
        try PlaybackControlRunner.perform(.play)
        return .result()
    }
}

struct PauseTrackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Pause"
    static var description = IntentDescription("Pause the current track.")

    func perform() async throws -> some IntentResult {
        try PlaybackControlRunner.perform(.pause)
        return .result()
    }
}

struct NextTrackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Next Track"
    static var description = IntentDescription("Switch to the next track.")

    func perform() async throws -> some IntentResult {
        try PlaybackControlRunner.perform(.next)
        return .result()
    }
}

enum PlaybackControlRunner {
    private static let logger = Logger(
        subsystem: "com.marigold.NowPlayingWidget",
        category: "PlaybackControl"
    )

    static func perform(_ command: PlaybackCommand) throws {
        if Bundle.main.bundleURL.pathExtension == "appex" {
            try enqueue(command)
        } else {
            try run(command)
        }
    }

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

    private static func enqueue(_ command: PlaybackCommand) throws {
        let request = PlaybackCommandRequest(
            id: UUID(),
            command: command,
            createdAt: Date()
        )
        let data = try JSONEncoder.playbackCommand.encode(request)
        var lastError: Error?
        var wroteRequest = false

        for url in NowPlayingShared.writablePlaybackCommandURLs() {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: url, options: .atomic)
                wroteRequest = true
            } catch {
                lastError = error
            }
        }

        guard wroteRequest else {
            throw lastError ?? CocoaError(.fileWriteUnknown)
        }

        logger.info("Queued playback command \(command.rawValue, privacy: .public)")
    }
}

private extension JSONEncoder {
    static var playbackCommand: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
