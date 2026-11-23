import Foundation

enum WidgetSyncEvent {
    case read(NowPlayingSnapshot)
    case written
    case reloadRequested
    case readFailed(String)
    case writeFailed(String)
}

/// Called on one serial queue so automatic and manual refreshes cannot overwrite each other.
final class WidgetSyncPipeline {
    private let read: () throws -> NowPlayingReadResult
    private let containers: () -> [URL]
    private let requestReload: () -> Void
    private var lastWritten: NowPlayingReadResult?

    init(
        read: @escaping () throws -> NowPlayingReadResult,
        containers: @escaping () -> [URL],
        requestReload: @escaping () -> Void
    ) {
        self.read = read
        self.containers = containers
        self.requestReload = requestReload
    }

    func sync(forceWrite: Bool, onEvent: (WidgetSyncEvent) -> Void) {
        let result: NowPlayingReadResult
        do {
            result = try read()
        } catch {
            onEvent(.readFailed(error.localizedDescription))
            return
        }
        onEvent(.read(result.snapshot))

        guard forceWrite || !matchesLastWrite(result) else { return }
        do {
            try write(result)
        } catch {
            // A partial write must not cause the next automatic refresh to skip a retry.
            lastWritten = nil
            onEvent(.writeFailed(error.localizedDescription))
            return
        }

        lastWritten = result
        onEvent(.written)
        requestReload()
        onEvent(.reloadRequested)
    }

    private func matchesLastWrite(_ result: NowPlayingReadResult) -> Bool {
        guard let lastWritten else { return false }
        var snapshot = result.snapshot
        snapshot.updatedAt = lastWritten.snapshot.updatedAt
        return snapshot == lastWritten.snapshot && result.artworkData == lastWritten.artworkData
    }

    private func write(_ result: NowPlayingReadResult) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(result.snapshot)

        for container in containers() {
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
            let artworkURL = container.appendingPathComponent(NowPlayingShared.artworkFileName)
            if let artworkData = result.artworkData {
                try artworkData.write(to: artworkURL, options: .atomic)
            } else if FileManager.default.fileExists(atPath: artworkURL.path) {
                try FileManager.default.removeItem(at: artworkURL)
            }
            try encoded.write(to: container.appendingPathComponent(NowPlayingShared.dataFileName), options: .atomic)
        }
    }
}
