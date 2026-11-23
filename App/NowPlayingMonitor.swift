import AppKit
import Foundation
import WidgetKit

enum RefreshPolicy {
    static let activeInterval: TimeInterval = 3
    static let pausedBackoffThreshold: TimeInterval = 30
    static let pausedBackoffInterval: TimeInterval = 10
    static let idleInterval: TimeInterval = 15

    static func interval(for snapshot: NowPlayingSnapshot, pausedDuration: TimeInterval) -> TimeInterval {
        let isIdle = snapshot.sourceBundleID.isEmpty
            && snapshot.title == NowPlayingSnapshot.empty.title
            && snapshot.artist == NowPlayingSnapshot.empty.artist
        if isIdle {
            return idleInterval
        }
        if snapshot.isPlaying {
            return activeInterval
        }
        return pausedDuration >= pausedBackoffThreshold ? pausedBackoffInterval : activeInterval
    }
}

final class NowPlayingMonitor {
    private let syncQueue = DispatchQueue(label: "com.marigold.NowPlayingWidget.sync", qos: .utility)
    private let artworkResolver = HighResArtworkResolver()
    private let lyricResolver = LyricResolver()
    private let reader: NowPlayingReader
    private let pipeline: WidgetSyncPipeline
    private var refreshTimer: Timer?
    private var commandDirectorySources: [DispatchSourceFileSystemObject] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var pendingCommandWorkItem: DispatchWorkItem?
    private var pendingSyncs = 0
    private var lastCommandID: UUID?
    private var pausedSince: Date?
    private var currentInterval: TimeInterval = RefreshPolicy.activeInterval
    private var isStarted = false
    var onSnapshotRead: ((NowPlayingSnapshot) -> Void)?
    var onSnapshotWritten: (() -> Void)?
    var onRefreshError: ((String) -> Void)?

    init() {
        let reader = NowPlayingReader(
            artworkResolver: artworkResolver,
            lyricResolver: lyricResolver
        )
        self.reader = reader
        self.pipeline = WidgetSyncPipeline(
            read: reader.read,
            containers: NowPlayingShared.writableContainerURLs,
            requestReload: { WidgetCenter.shared.reloadAllTimelines() }
        )
        artworkResolver.onResolved = { [weak self] in
            DispatchQueue.main.async {
                self?.refresh()
            }
        }
        lyricResolver.onResolved = { [weak self] in
            DispatchQueue.main.async {
                self?.refresh()
            }
        }
    }

    deinit {
        refreshTimer?.invalidate()
        pendingCommandWorkItem?.cancel()
        commandDirectorySources.forEach { $0.cancel() }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { center.removeObserver($0) }
    }

    func start() {
        isStarted = true
        refresh()
        processPlaybackCommand()
        startWatchingPlaybackCommands()
        startWatchingPlayerLifecycle()
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
                        updateRefreshSchedule(for: snapshot)
                        onSnapshotRead?(snapshot)
                    case let .readFailed(detail), let .writeFailed(detail):
                        onRefreshError?(detail)
                    case .written:
                        onSnapshotWritten?()
                    case .reloadRequested:
                        break
                    }
                    onEvent?(event)
                }
            }
            DispatchQueue.main.async { [self] in
                pendingSyncs -= 1
                if pendingSyncs == 0, isStarted {
                    scheduleNextRefresh()
                }
            }
        }
    }

    private func updateRefreshSchedule(for snapshot: NowPlayingSnapshot) {
        let now = Date()
        let isIdle = snapshot.sourceBundleID.isEmpty
            && snapshot.title == NowPlayingSnapshot.empty.title
            && snapshot.artist == NowPlayingSnapshot.empty.artist

        if isIdle || snapshot.isPlaying {
            pausedSince = nil
        } else if pausedSince == nil {
            pausedSince = now
        }

        let pausedDuration = pausedSince.map { now.timeIntervalSince($0) } ?? 0
        currentInterval = RefreshPolicy.interval(for: snapshot, pausedDuration: pausedDuration)
    }

    private func scheduleNextRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: currentInterval, repeats: false) { [weak self] _ in
            self?.refresh()
        }
    }

    private func startWatchingPlayerLifecycle() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ]

        for name in names {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let bundleID = app.bundleIdentifier,
                      NowPlayingSource.displayName(for: bundleID) != nil else {
                    return
                }
                self?.pausedSince = nil
                self?.currentInterval = RefreshPolicy.activeInterval
                self?.refresh()
            }
            workspaceObservers.append(observer)
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
