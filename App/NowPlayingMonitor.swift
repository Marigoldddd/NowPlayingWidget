import Foundation
import WidgetKit

final class NowPlayingMonitor {
    private let reader = NowPlayingReader()
    private var timer: Timer?
    private var lastDisplayKey: String?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refresh()
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
}

private extension JSONEncoder {
    static var widget: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
