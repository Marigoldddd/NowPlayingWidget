import Foundation

enum WidgetSyncPipelineTests {
    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let widget = root.appendingPathComponent("widget")
        let local = root.appendingPathComponent("local")
        let dataURL = widget.appendingPathComponent(NowPlayingShared.dataFileName)
        let artworkURL = widget.appendingPathComponent(NowPlayingShared.artworkFileName)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let artwork = Data([1, 2, 3])
        var result = NowPlayingReadResult(
            snapshot: NowPlayingSnapshot(title: "Test", artist: "Artist", album: "", isPlaying: true,
                                         sourceBundleID: "com.tencent.QQMusicMac", updatedAt: Date(), hasArtwork: true),
            artworkData: artwork
        )
        var destinations = [widget, local]
        var readShouldFail = false
        var events: [String] = []
        let pipeline = WidgetSyncPipeline(
            read: {
                if readShouldFail { throw CocoaError(.fileReadCorruptFile) }
                return result
            },
            containers: { destinations },
            requestReload: {
                for container in [widget, local] {
                    let file = container.appendingPathComponent(NowPlayingShared.dataFileName)
                    let persisted = try! decoder.decode(NowPlayingSnapshot.self, from: Data(contentsOf: file))
                    precondition(persisted.title == result.snapshot.title)
                    precondition(persisted.hasArtwork == result.snapshot.hasArtwork)
                    let cover = try? Data(contentsOf: container.appendingPathComponent(NowPlayingShared.artworkFileName))
                    precondition(cover == result.artworkData)
                }
                events.append("reload")
            }
        )

        func sync(force: Bool = false) -> [String] {
            events.removeAll()
            pipeline.sync(forceWrite: force) { event in
                switch event {
                case .read: events.append("read")
                case .written: events.append("written")
                case .reloadRequested: events.append("requested")
                case .readFailed: events.append("readFailed")
                case .writeFailed: events.append("writeFailed")
                }
            }
            return events
        }

        let completed = ["read", "written", "reload", "requested"]
        precondition(sync() == completed)
        result.snapshot.updatedAt.addTimeInterval(5)
        precondition(sync() == ["read"])

        // A manual sync must repair missing/invalid files even when the song is unchanged.
        try Data("corrupt".utf8).write(to: dataURL)
        try FileManager.default.removeItem(at: artworkURL)
        precondition(sync(force: true) == completed)

        result.artworkData = Data([3, 2, 1])
        precondition(sync() == completed)

        readShouldFail = true
        precondition(sync(force: true) == ["readFailed"])
        readShouldFail = false

        let blocked = root.appendingPathComponent("not-a-directory")
        try Data([0]).write(to: blocked)
        destinations = [widget, blocked]
        precondition(sync(force: true) == ["read", "writeFailed"])
        destinations = [widget, local]
        precondition(sync() == completed)

        result = NowPlayingReadResult(snapshot: .empty, artworkData: nil)
        precondition(sync(force: true) == completed)
        print("PASS: widget sync order, automatic deduplication, forced repair, cover changes, read/write failures, idle")
    }
}
