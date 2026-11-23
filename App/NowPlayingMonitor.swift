import Foundation
import WidgetKit

final class NowPlayingMonitor {
    private let syncQueue = DispatchQueue(label: "com.marigold.NowPlayingWidget.sync", qos: .utility)
    private let artworkResolver = HighResArtworkResolver()
    private let reader: NowPlayingReader
    private let pipeline: WidgetSyncPipeline
    private var refreshTimer: Timer?
    private var commandDirectorySources: [DispatchSourceFileSystemObject] = []
    private var pendingCommandWorkItem: DispatchWorkItem?
    private var pendingSyncs = 0
    private var lastCommandID: UUID?
    var onSnapshotRead: ((NowPlayingSnapshot) -> Void)?
    var onRefreshError: ((String) -> Void)?

    init() {
        let reader = NowPlayingReader(artworkResolver: artworkResolver)
        self.reader = reader
        self.pipeline = WidgetSyncPipeline(
            read: reader.read,
            containers: NowPlayingShared.writableContainerURLs,
            requestReload: { WidgetCenter.shared.reloadTimelines(ofKind: NowPlayingShared.widgetKind) }
        )
        artworkResolver.onResolved = { [weak self] in
            DispatchQueue.main.async {
                self?.refresh()
            }
        }
    }

    deinit {
        refreshTimer?.invalidate()
        pendingCommandWorkItem?.cancel()
        commandDirectorySources.forEach { $0.cancel() }
    }

    func start() {
        refresh()
        processPlaybackCommand()
        startWatchingPlaybackCommands()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        guard pendingSyncs == 0 else { return }
        enqueueSync(forceWrite: false)
    }

    func syncWidget(onEvent: @escaping (WidgetSyncEvent) -> Void) {
        enqueueSync(forceWrite: true, onEvent: onEvent)
    }

    private func enqueueSync(
        forceWrite: Bool,
        onEvent: ((WidgetSyncEvent) -> Void)? = nil
    ) {
        pendingSyncs += 1
        syncQueue.async { [self] in
            pipeline.sync(forceWrite: forceWrite) { event in
                DispatchQueue.main.async { [self] in
                    switch event {
                    case let .read(snapshot):
                        onSnapshotRead?(snapshot)
                    case let .readFailed(detail), let .writeFailed(detail):
                        onRefreshError?(detail)
                    case .written, .reloadRequested:
                        break
                    }
                    onEvent?(event)
                }
            }
            DispatchQueue.main.async { [self] in pendingSyncs -= 1 }
        }
    }

    private func startWatchingPlaybackCommands() {
        guard commandDirectorySources.isEmpty else { return }

        for directory in NowPlayingShared.writableContainerURLs() {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fd = open(directory.path, O_EVTONLY)
            guard fd >= 0 else { continue }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: .write,
                queue: .main
            )
            source.setEventHandler { [weak self] in
                self?.schedulePlaybackCommandCheck()
            }
            source.setCancelHandler {
                close(fd)
            }
            source.resume()
            commandDirectorySources.append(source)
        }
    }

    private func schedulePlaybackCommandCheck() {
        pendingCommandWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.processPlaybackCommand()
        }
        pendingCommandWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: workItem)
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

private extension JSONDecoder {
    static var playbackCommand: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
