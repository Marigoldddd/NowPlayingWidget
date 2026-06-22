import Foundation
import WidgetKit

final class NowPlayingMonitor {
    private let reader = NowPlayingReader()
    private var refreshTimer: Timer?
    private var commandTimer: Timer?
    private var lastDisplayKey: String?
    private var lastCommandID: UUID?

    func start() {
        refresh()
        processPlaybackCommand()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        commandTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.processPlaybackCommand()
        }
    }

    func refresh() {
        Task {
            do {
                let result = try await reader.read()
                try save(result)
            } catch {
                // Keep the previous widget state. The menu-bar app is intentionally quiet.
            }
        }
    }

    private func save(_ result: NowPlayingReadResult) throws {
        let displayKey = [
            result.snapshot.title,
            result.snapshot.artist,
            result.snapshot.album,
            result.snapshot.isPlaying.description,
            result.snapshot.sourceBundleID,
            result.snapshot.hasArtwork.description,
            result.snapshot.backgroundRed.description,
            result.snapshot.backgroundGreen.description,
            result.snapshot.backgroundBlue.description,
        ].joined(separator: "\u{1f}")

        guard displayKey != lastDisplayKey else { return }
        let encoded = try JSONEncoder.widget.encode(result.snapshot)

        for container in NowPlayingShared.writableContainerURLs() {
            try FileManager.default.createDirectory(
                at: container,
                withIntermediateDirectories: true
            )

            let dataURL = container.appendingPathComponent(NowPlayingShared.dataFileName)
            let artworkURL = container.appendingPathComponent(NowPlayingShared.artworkFileName)

            if let artworkData = result.artworkData {
                try artworkData.write(to: artworkURL, options: .atomic)
            } else if FileManager.default.fileExists(atPath: artworkURL.path) {
                try? FileManager.default.removeItem(at: artworkURL)
            }

            try encoded.write(to: dataURL, options: .atomic)
        }

        lastDisplayKey = displayKey

        WidgetCenter.shared.reloadTimelines(ofKind: NowPlayingShared.widgetKind)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func processPlaybackCommand() {
        for url in NowPlayingShared.readablePlaybackCommandURLs()
        where FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url),
                  let request = try? JSONDecoder.playbackCommand.decode(
                    PlaybackCommandRequest.self,
                    from: data
                  ) else {
                try? FileManager.default.removeItem(at: url)
                continue
            }

            guard request.id != lastCommandID else {
                try? FileManager.default.removeItem(at: url)
                continue
            }

            lastCommandID = request.id
            try? FileManager.default.removeItem(at: url)

            do {
                try PlaybackControlRunner.run(request.command)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    self?.refresh()
                }
            } catch {
                // Ignore failed media commands and continue monitoring.
            }
            break
        }
    }
}

private extension JSONEncoder {
    static var widget: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var playbackCommand: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
