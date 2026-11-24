import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers
import WidgetKit

@main
struct NowPlayingWidgetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            MainWindowView(model: NowPlayingAppModel.shared)
                .frame(width: 760, height: 520)
                .onOpenURL { url in
                    DeepLinkRouter.handle(url, model: NowPlayingAppModel.shared)
                }
        }
    }
}

private enum DeepLinkRouter {
    private static let logger = Logger(subsystem: "com.marigold.NowPlayingWidget", category: "DeepLink")
    private static var lastURL: String?
    private static var lastDate: Date = .distantPast

    static func handle(_ url: URL, model: NowPlayingAppModel) {
        let now = Date()
        if lastURL == url.absoluteString, now.timeIntervalSince(lastDate) < 0.2 {
            return
        }
        lastURL = url.absoluteString
        lastDate = now

        guard let deepLink = WidgetDeepLink(url: url) else {
            logger.warning("Ignored unknown URL: \(url.absoluteString, privacy: .public)")
            return
        }

        switch deepLink {
        case let .playback(command):
            do {
                try PlaybackControlRunner.run(command)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    model.refreshAfterPlaybackControl()
                }
            } catch {
                logger.error("Playback command failed: \(error.localizedDescription, privacy: .public)")
            }
        case let .openPlayer(bundleID):
            openPlayerApplication(bundleID: bundleID)
        }
    }

    private static func openPlayerApplication(bundleID: String) {
        guard NowPlayingSource.displayName(for: bundleID) != nil,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            logger.error("Unable to resolve player bundleID: \(bundleID, privacy: .public)")
            return
        }

        logger.info("Opening player \(bundleID, privacy: .public) at \(appURL.path, privacy: .public)")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
            if let error {
                logger.error("openApplication failed: \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async {
                    NSWorkspace.shared.open(appURL)
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var openMenuItem: NSMenuItem?
    private var quitMenuItem: NSMenuItem?
    private let model = NowPlayingAppModel.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = MenuBarIcon.image()
        statusItem.button?.imagePosition = .imageOnly

        let menu = NSMenu()
        let openItem = NSMenuItem(title: "", action: #selector(openMainWindow), keyEquivalent: "o")
        let quitItem = NSMenuItem(title: "", action: #selector(quit), keyEquivalent: "q")
        menu.addItem(openItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        statusItem.menu = menu
        self.statusItem = statusItem
        self.openMenuItem = openItem
        self.quitMenuItem = quitItem
        updateMenuLocalization()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLanguageChanged),
            name: NowPlayingAppModel.languageDidChangeNotification,
            object: nil
        )

        model.startMonitoring()

        let isDefaultLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        if isDefaultLaunch {
            MainWindowController.shared.show()
        }
    }

    @objc private func handleLanguageChanged() {
        updateMenuLocalization()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.flushHistory()
    }

    private func updateMenuLocalization() {
        let lang = model.appearance.language
        statusItem?.button?.toolTip = L10n.tr("menubar.tooltip", language: lang)
        openMenuItem?.title = L10n.tr("menubar.open_main", language: lang)
        quitMenuItem?.title = L10n.tr("menubar.quit", language: lang)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            DeepLinkRouter.handle(url, model: model)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindowController.shared.show()
        return true
    }

    @objc private func openMainWindow() {
        MainWindowController.shared.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

final class MainWindowController {
    static let shared = MainWindowController()

    private var window: NSWindow?

    private init() {}

    func show() {
        if window == nil {
            let contentView = MainWindowView(model: NowPlayingAppModel.shared)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Now Playing Widget"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 720, height: 500)
            window.contentView = NSHostingView(rootView: contentView)
            window.center()
            self.window = window
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

final class NowPlayingAppModel: ObservableObject {
    enum UpdateStatus: Equatable {
        case idle
        case checking
        case upToDate(String)
        case available(ReleaseInfo)
        case installing(ReleaseInfo, String)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .checking, .installing:
                return true
            default:
                return false
            }
        }
    }

    static let languageDidChangeNotification = Notification.Name("NowPlayingWidgetLanguageDidChange")
    static let shared = NowPlayingAppModel()

    @Published private(set) var snapshot: NowPlayingSnapshot
    @Published private(set) var lastRefreshDate: Date?
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var hasIdleArtwork: Bool
    @Published private(set) var appearance: WidgetAppearance
    @Published private(set) var artworkRevision = 0
    @Published private(set) var message: String?
    @Published private(set) var widgetSyncReport: WidgetSyncReport?
    @Published private(set) var updateStatus: UpdateStatus = .idle
    @Published private(set) var historyRevision = 0

    private let monitor = NowPlayingMonitor()
    private let updater = AppUpdater()
    private let historyStore = ListeningHistoryStore()
    private var hasStarted = false

    private init() {
        let snapshot = Self.loadSavedSnapshot()
        let loadedAppearance = NowPlayingShared.loadAppearance()
        L10n.overrideLanguage = loadedAppearance.language
        self.snapshot = snapshot
        self.lastRefreshDate = snapshot.updatedAt.timeIntervalSince1970 > 0 ? snapshot.updatedAt : nil
        self.hasIdleArtwork = Self.idleArtworkExists
        self.appearance = loadedAppearance
    }

    func selectLanguage(_ language: AppLanguage) {
        guard appearance.language != language else { return }
        var next = appearance
        next.language = language
        L10n.overrideLanguage = language
        saveAppearance(
            next,
            statusMessage: L10n.fmt("language.updated", language: language, language.displayName)
        )
        NotificationCenter.default.post(name: Self.languageDidChangeNotification, object: nil)
    }

    var isPerSizeThemeEnabled: Bool {
        appearance.usesPerSizeThemes
    }

    func theme(for sizeClass: WidgetSizeClass?) -> WidgetTheme {
        if let sizeClass, appearance.usesPerSizeThemes {
            return appearance.theme(for: sizeClass)
        }
        return appearance.theme
    }

    func setPerSizeThemeEnabled(_ enabled: Bool) {
        var next = appearance
        if enabled {
            let base = appearance.theme
            next.smallTheme = appearance.smallTheme ?? base
            next.mediumTheme = appearance.mediumTheme ?? base
            next.largeTheme = appearance.largeTheme ?? base
        } else {
            next.smallTheme = nil
            next.mediumTheme = nil
            next.largeTheme = nil
        }
        saveAppearance(
            next,
            statusMessage: enabled
                ? L10n.tr("appearance.skin.toggle_on", language: appearance.language)
                : L10n.fmt("appearance.skin.toggle_off", language: appearance.language, next.theme.displayName)
        )
    }

    func selectTheme(_ theme: WidgetTheme, for sizeClass: WidgetSizeClass? = nil) {
        var next = appearance
        if let sizeClass, appearance.usesPerSizeThemes {
            guard appearance.theme(for: sizeClass) != theme else { return }
            next.setTheme(theme, for: sizeClass)
            saveAppearance(
                next,
                statusMessage: L10n.fmt(
                    "appearance.skin.switched_size",
                    language: appearance.language,
                    sizeClass.displayName,
                    theme.displayName
                )
            )
        } else {
            guard appearance.theme != theme || appearance.usesPerSizeThemes else { return }
            next.theme = theme
            next.smallTheme = nil
            next.mediumTheme = nil
            next.largeTheme = nil
            saveAppearance(
                next,
                statusMessage: L10n.fmt(
                    "appearance.skin.switched_all",
                    language: appearance.language,
                    theme.displayName
                )
            )
        }
    }

    private func saveAppearance(_ next: WidgetAppearance, statusMessage: String) {
        do {
            try NowPlayingShared.saveAppearance(next)
            appearance = next
            message = statusMessage
            WidgetCenter.shared.reloadTimelines(ofKind: NowPlayingShared.widgetKind)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            message = L10n.fmt("appearance.skin.save_failed", language: appearance.language, error.localizedDescription)
        }
    }

    var sourceName: String {
        NowPlayingSource.displayName(for: snapshot.sourceBundleID, language: appearance.language)
            ?? (snapshot.isIdle
                ? L10n.tr("status.waiting_music", language: appearance.language)
                : L10n.tr("status.unknown_player", language: appearance.language))
    }

    var playbackStateText: String {
        if snapshot.isIdle { return L10n.tr("status.no_music", language: appearance.language) }
        return L10n.tr(snapshot.isPlaying ? "status.playing" : "status.paused", language: appearance.language)
    }

    var cliStatusText: String {
        L10n.tr(
            NowPlayingCLI.executableURL == nil ? "status.cli.missing" : "status.cli.available",
            language: appearance.language
        )
    }

    var cliStatusIsHealthy: Bool {
        NowPlayingCLI.executableURL != nil
    }

    var supportFolderPath: String {
        displayPath(NowPlayingShared.widgetSupportURL())
    }

    var artworkURL: URL? {
        if snapshot.isIdle {
            return Self.idleArtworkURL
        }
        guard snapshot.hasArtwork else { return nil }
        return NowPlayingShared.readableArtworkURLs().first {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    var idleArtworkURL: URL? {
        Self.idleArtworkURL
    }

    func startMonitoring() {
        guard !hasStarted else { return }
        hasStarted = true

        AppUpdater.refreshWidgetExtensionIfUpgraded()
        WidgetCenter.shared.reloadAllTimelines()

        monitor.onSnapshotRead = { [weak self] snapshot in
            guard let self else { return }
            self.snapshot = snapshot
            self.lastRefreshDate = Date()
            self.lastErrorMessage = nil
            let didCommit = self.historyStore.record(snapshot: snapshot, artworkURL: self.artworkURL)
            if didCommit || snapshot.isPlaying {
                self.historyRevision += 1
            }
        }
        monitor.onSnapshotWritten = { [weak self] in
            self?.artworkRevision += 1
        }
        monitor.onRefreshError = { [weak self] detail in
            self?.lastErrorMessage = detail
        }
        monitor.start()
    }

    var hasListeningHistory: Bool {
        _ = historyRevision
        return !historyStore.database.entries.isEmpty || !historyStore.database.dailyBuckets.isEmpty
    }

    func listeningStats(for range: StatsTimeRange) -> ListeningStatsSummary {
        _ = historyRevision
        return historyStore.stats(for: range, language: appearance.language)
    }

    func listeningHeatmap(weeks: Int = 26) -> ListeningHeatmapData {
        _ = historyRevision
        return historyStore.heatmap(weeks: weeks, language: appearance.language)
    }

    func recentPlaybackEntries(
        for range: StatsTimeRange,
        sourceBundleID: String? = nil,
        limit: Int = 30
    ) -> [PlaybackHistoryEntry] {
        _ = historyRevision
        return historyStore.recentEntries(for: range, sourceBundleID: sourceBundleID, limit: limit)
    }

    func cachedHistoryArtworkURL(for hash: String?) -> URL? {
        historyStore.artworkURL(for: hash)
    }

    func clearListeningHistory() {
        historyStore.clearHistory()
        historyRevision += 1
    }

    func flushHistory() {
        historyStore.flushIfNeeded(force: true)
    }

    func refreshAfterPlaybackControl() {
        monitor.refresh()
    }

    func syncWidget() {
        guard widgetSyncReport?.isInProgress != true else { return }
        widgetSyncReport = WidgetSyncReport()
        monitor.syncWidget { [weak self] event in
            self?.widgetSyncReport?.record(event)
        }
    }

    var currentVersionText: String {
        L10n.fmt("update.current_version", language: appearance.language, AppUpdater.currentVersionString)
    }

    func checkForUpdates() {
        guard !updateStatus.isBusy else { return }
        updateStatus = .checking

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await updater.checkForUpdates()
                await MainActor.run {
                    switch result {
                    case let .upToDate(version):
                        self.updateStatus = .upToDate(version)
                    case let .updateAvailable(release):
                        self.updateStatus = .available(release)
                    }
                }
            } catch {
                await MainActor.run {
                    self.updateStatus = .failed(error.localizedDescription)
                }
            }
        }
    }

    func installUpdate(_ release: ReleaseInfo) {
        guard !updateStatus.isBusy else { return }
        updateStatus = .installing(release, L10n.tr("update.stage.preparing", language: appearance.language))

        Task { [weak self] in
            guard let self else { return }
            do {
                try await updater.downloadAndInstall(release: release) { stage in
                    self.updateStatus = .installing(release, stage)
                }
            } catch {
                await MainActor.run {
                    self.updateStatus = .failed(error.localizedDescription)
                }
            }
        }
    }

    func openReleaseURL(_ url: URL = AppUpdater.releasesPageURL) {
        NSWorkspace.shared.open(url)
    }

    func openDataFolder() {
        let folder = NowPlayingShared.widgetSupportURL()
        try? FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    func chooseIdleArtwork() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK,
              let url = panel.url,
              let image = NSImage(contentsOf: url),
              let data = image.pngData else {
            return
        }

        do {
            try writeIdleArtwork(data)
            hasIdleArtwork = true
            artworkRevision += 1
            message = L10n.tr("appearance.idle.updated", language: appearance.language)
            WidgetCenter.shared.reloadTimelines(ofKind: NowPlayingShared.widgetKind)
        } catch {
            message = L10n.fmt("appearance.idle.save_failed", language: appearance.language, error.localizedDescription)
        }
    }

    func removeIdleArtwork() {
        for container in NowPlayingShared.writableContainerURLs() {
            let url = container.appendingPathComponent(NowPlayingShared.idleArtworkFileName)
            try? FileManager.default.removeItem(at: url)
        }
        hasIdleArtwork = false
        artworkRevision += 1
        message = L10n.tr("appearance.idle.restored", language: appearance.language)
        WidgetCenter.shared.reloadTimelines(ofKind: NowPlayingShared.widgetKind)
    }

    private func writeIdleArtwork(_ data: Data) throws {
        for container in NowPlayingShared.writableContainerURLs() {
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
            let url = container.appendingPathComponent(NowPlayingShared.idleArtworkFileName)
            try data.write(to: url, options: .atomic)
        }
    }

    private static var idleArtworkExists: Bool {
        idleArtworkURL != nil
    }

    private static var idleArtworkURL: URL? {
        NowPlayingShared.readableIdleArtworkURLs().first {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    private static func loadSavedSnapshot() -> NowPlayingSnapshot {
        for dataURL in NowPlayingShared.readableDataURLs()
        where FileManager.default.fileExists(atPath: dataURL.path) {
            guard let data = try? Data(contentsOf: dataURL) else { continue }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let snapshot = try? decoder.decode(NowPlayingSnapshot.self, from: data) {
                return snapshot
            }
        }
        return .empty
    }

    private func displayPath(_ url: URL) -> String {
        let home = NowPlayingShared.realUserHomeURL().standardized.path
        let path = url.standardized.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

struct WidgetSyncReport {
    enum Step {
        case waiting, running, skipped
        case done(String)
        case failed(String)
    }

    private(set) var read: Step = .running
    private(set) var write: Step = .waiting
    private(set) var request: Step = .waiting
    private(set) var isInProgress = true

    mutating func record(_ event: WidgetSyncEvent) {
        switch event {
        case let .read(snapshot):
            read = .done(
                snapshot.isIdle
                    ? L10n.tr("status.sync.read.idle")
                    : L10n.fmt("status.sync.read.track", snapshot.title)
            )
            write = .running
        case .written:
            write = .done(L10n.tr("status.sync.write.done"))
            request = .running
        case .reloadRequested:
            request = .done(L10n.tr("status.sync.request.done"))
            isInProgress = false
        case let .readFailed(detail):
            read = .failed(detail)
            write = .skipped
            request = .skipped
            isInProgress = false
        case let .writeFailed(detail):
            write = .failed(detail)
            request = .skipped
            isInProgress = false
        }
    }
}

struct MainWindowView: View {
    @ObservedObject var model: NowPlayingAppModel
    @State private var selectedTab = MainTab.overview

    var body: some View {
        let lang = model.appearance.language
        TabView(selection: $selectedTab) {
            OverviewPage(model: model)
                .tabItem {
                    Label(L10n.tr("nav.overview", language: lang), systemImage: "music.note")
                }
                .tag(MainTab.overview)

            StatsPage(model: model)
                .tabItem {
                    Label(L10n.tr("nav.stats", language: lang), systemImage: "chart.bar.xaxis")
                }
                .tag(MainTab.stats)

            AppearancePage(model: model)
                .tabItem {
                    Label(L10n.tr("nav.appearance", language: lang), systemImage: "photo")
                }
                .tag(MainTab.appearance)

            HelpPage(language: lang)
                .tabItem {
                    Label(L10n.tr("nav.help", language: lang), systemImage: "questionmark.circle")
                }
                .tag(MainTab.help)
        }
        .padding(22)
        .frame(minWidth: 720, minHeight: 500)
    }
}

private enum MainTab {
    case overview
    case stats
    case appearance
    case help
}

private struct OverviewPage: View {
    @ObservedObject var model: NowPlayingAppModel

    var body: some View {
        let lang = model.appearance.language
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Now Playing Widget")
                        .font(.largeTitle.bold())
                    Text(L10n.tr("overview.subtitle", language: lang))
                        .foregroundStyle(.secondary)
                }

                StatusCard(model: model)

                HStack(spacing: 12) {
                    ActionCard(
                        title: L10n.tr(
                            model.widgetSyncReport?.isInProgress == true ? "overview.sync.in_progress" : "overview.sync.title",
                            language: lang
                        ),
                        subtitle: L10n.tr("overview.sync.subtitle", language: lang),
                        systemImage: "arrow.clockwise"
                    ) {
                        model.syncWidget()
                    }
                    .disabled(model.widgetSyncReport?.isInProgress == true)
                    .accessibilityIdentifier("syncWidget")

                    ActionCard(
                        title: updateButtonTitle,
                        subtitle: model.currentVersionText,
                        systemImage: updateButtonIcon
                    ) {
                        model.checkForUpdates()
                    }
                    .disabled(model.updateStatus.isBusy)
                    .accessibilityIdentifier("checkForUpdates")

                    ActionCard(
                        title: L10n.tr("overview.folder.title", language: lang),
                        subtitle: L10n.tr("overview.folder.subtitle", language: lang),
                        systemImage: "folder"
                    ) {
                        model.openDataFolder()
                    }
                }
                .fixedSize(horizontal: false, vertical: true)

                updateStatusSection

                if let report = model.widgetSyncReport {
                    VStack(alignment: .leading, spacing: 6) {
                        syncRow(L10n.tr("overview.step.read", language: lang), step: report.read)
                        syncRow(L10n.tr("overview.step.write", language: lang), step: report.write)
                        syncRow(L10n.tr("overview.step.request", language: lang), step: report.request)
                    }
                }
            }
        }
    }

    private var updateButtonTitle: String {
        let lang = model.appearance.language
        switch model.updateStatus {
        case .checking:
            return L10n.tr("update.action.checking", language: lang)
        case .installing:
            return L10n.tr("update.action.installing", language: lang)
        case let .available(release):
            return L10n.fmt("update.action.available", language: lang, release.tagName)
        default:
            return L10n.tr("update.action.check", language: lang)
        }
    }

    private var updateButtonIcon: String {
        switch model.updateStatus {
        case .available:
            return "sparkles"
        case .checking, .installing:
            return "clock.arrow.circlepath"
        default:
            return "arrow.down.circle"
        }
    }

    @ViewBuilder
    private var updateStatusSection: some View {
        let lang = model.appearance.language
        switch model.updateStatus {
        case .idle:
            EmptyView()

        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.tr("update.checking_banner", language: lang))
                    .foregroundStyle(.secondary)
            }
            .font(.callout)

        case let .upToDate(version):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(L10n.fmt("update.up_to_date_banner", language: lang, version))
                    .foregroundStyle(.secondary)
            }
            .font(.callout)

        case let .available(release):
            UpdateReleaseCard(
                release: release,
                stageText: nil,
                language: lang,
                onInstall: { model.installUpdate(release) },
                onOpenPage: { model.openReleaseURL(release.htmlURL) }
            )

        case let .installing(release, stage):
            UpdateReleaseCard(
                release: release,
                stageText: stage,
                language: lang,
                onInstall: {},
                onOpenPage: { model.openReleaseURL(release.htmlURL) }
            )

        case let .failed(detail):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(L10n.tr("update.open_releases", language: lang)) {
                    model.openReleaseURL()
                }
                .controlSize(.small)
            }
            .font(.callout)
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func syncRow(_ title: String, step: WidgetSyncReport.Step) -> some View {
        let lang = model.appearance.language
        let (icon, detail, color): (String, String, Color)
        switch step {
        case .waiting: (icon, detail, color) = ("circle", L10n.tr("status.sync.step.waiting", language: lang), .secondary)
        case .running: (icon, detail, color) = ("clock", L10n.tr("status.sync.step.running", language: lang), .secondary)
        case .skipped: (icon, detail, color) = ("minus.circle", L10n.tr("status.sync.step.skipped", language: lang), .secondary)
        case let .done(text): (icon, detail, color) = ("checkmark.circle.fill", text, .green)
        case let .failed(text): (icon, detail, color) = ("exclamationmark.circle.fill", L10n.fmt("status.sync.step.failed", language: lang, text), .orange)
        }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(title)
                .fontWeight(.semibold)
                .fixedSize()
            Text(detail)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .help(detail)
        }
        .font(.callout)
    }
}

private struct StatusCard: View {
    @ObservedObject var model: NowPlayingAppModel

    var body: some View {
        HStack(spacing: 18) {
            ArtworkPreview(url: model.artworkURL, size: 116)
                .id(model.artworkRevision)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    StatusPill(
                        text: model.playbackStateText,
                        systemImage: model.snapshot.isPlaying ? "play.fill" : "pause.fill",
                        isHealthy: !model.snapshot.isIdle
                    )
                    StatusPill(
                        text: model.cliStatusText,
                        systemImage: "terminal",
                        isHealthy: model.cliStatusIsHealthy
                    )
                }

                Text(model.snapshot.title)
                    .font(.title2.bold())
                    .lineLimit(2)

                Text("\(model.snapshot.artist) · \(model.sourceName)")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if !model.snapshot.album.isEmpty {
                    Text(model.snapshot.album)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 10) {
                    Label(lastRefreshText, systemImage: "clock")
                    if let lastErrorMessage = model.lastErrorMessage {
                        Label(lastErrorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var lastRefreshText: String {
        let lang = model.appearance.language
        guard let date = model.lastRefreshDate else {
            return L10n.tr("overview.last_read.none", language: lang)
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.locale = L10n.locale(for: lang)
        return L10n.fmt("overview.last_read.format", language: lang, formatter.localizedString(for: date, relativeTo: Date()))
    }
}

private struct AppearancePage: View {
    @ObservedObject var model: NowPlayingAppModel
    @State private var selectedSizeClass: WidgetSizeClass = .medium

    var body: some View {
        let lang = model.appearance.language
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("appearance.title", language: lang))
                        .font(.largeTitle.bold())
                    Text(L10n.tr("appearance.subtitle", language: lang))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(L10n.tr("appearance.skin.title", language: lang))
                            .font(.title3.bold())
                        Spacer(minLength: 0)
                        Toggle(
                            L10n.tr("appearance.skin.per_size", language: lang),
                            isOn: Binding(
                                get: { model.isPerSizeThemeEnabled },
                                set: { model.setPerSizeThemeEnabled($0) }
                            )
                        )
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }

                    if model.isPerSizeThemeEnabled {
                        Picker(L10n.tr("appearance.skin.size_picker", language: lang), selection: $selectedSizeClass) {
                            ForEach(WidgetSizeClass.allCases) { sizeClass in
                                Text(
                                    L10n.fmt(
                                        "appearance.skin.size_picker_option",
                                        language: lang,
                                        sizeClass.displayName,
                                        model.theme(for: sizeClass).displayName
                                    )
                                )
                                .tag(sizeClass)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    let activeSize: WidgetSizeClass? = model.isPerSizeThemeEnabled ? selectedSizeClass : nil
                    let currentTheme = model.theme(for: activeSize)

                    HStack(spacing: 12) {
                        ForEach(WidgetTheme.allCases) { theme in
                            ThemeOptionCard(
                                theme: theme,
                                isSelected: currentTheme == theme,
                                artworkURL: model.artworkURL
                            ) {
                                model.selectTheme(theme, for: activeSize)
                            }
                            .id("\(theme.rawValue)-\(model.artworkRevision)-\(lang.rawValue)")
                        }
                    }

                    Text(
                        L10n.tr(
                            model.isPerSizeThemeEnabled
                                ? "appearance.skin.per_size_hint_on"
                                : "appearance.skin.per_size_hint_off",
                            language: lang
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                HStack(alignment: .center, spacing: 18) {
                    ArtworkPreview(url: model.idleArtworkURL, size: 128)
                        .id(model.artworkRevision)

                    VStack(alignment: .leading, spacing: 10) {
                        Text(L10n.tr("appearance.idle.title", language: lang))
                            .font(.title3.bold())
                        Text(L10n.tr("appearance.idle.subtitle", language: lang))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 10) {
                            Button(L10n.tr(model.hasIdleArtwork ? "appearance.idle.replace" : "appearance.idle.choose", language: lang)) {
                                model.chooseIdleArtwork()
                            }
                            Button(L10n.tr("appearance.idle.remove", language: lang)) {
                                model.removeIdleArtwork()
                            }
                            .disabled(!model.hasIdleArtwork)
                        }

                        Text(L10n.tr(model.hasIdleArtwork ? "appearance.idle.current_custom" : "appearance.idle.current_default", language: lang))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let message = model.message {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L10n.tr("language.title", language: lang))
                                .font(.headline)
                            Text(L10n.tr("language.subtitle", language: lang))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Picker(
                            L10n.tr("language.title", language: lang),
                            selection: Binding(
                                get: { model.appearance.language },
                                set: { model.selectLanguage($0) }
                            )
                        ) {
                            ForEach(AppLanguage.allCases) { item in
                                Text(item.displayName).tag(item)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 260)
                    }
                }
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.tr("appearance.folder.title", language: lang))
                        .font(.headline)
                    Text(model.supportFolderPath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button(L10n.tr("appearance.folder.open_finder", language: lang)) {
                        model.openDataFolder()
                    }
                }
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
    }
}

private struct ThemeOptionCard: View {
    let theme: WidgetTheme
    let isSelected: Bool
    let artworkURL: URL?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ThemeThumbnail(theme: theme, artworkURL: artworkURL)
                    .frame(height: 82)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                HStack(spacing: 6) {
                    Text(theme.displayName)
                        .font(.headline)
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }

                Text(theme.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct ThemeThumbnail: View {
    let theme: WidgetTheme
    let artworkURL: URL?

    var body: some View {
        switch theme {
        case .classic:
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.52, green: 0.14, blue: 0.22), Color(red: 0.16, green: 0.05, blue: 0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                HStack(spacing: 10) {
                    miniArtwork
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.85)).frame(width: 52, height: 6)
                        RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.45)).frame(width: 36, height: 4)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
            }

        case .vinyl:
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.16, green: 0.18, blue: 0.26), Color(red: 0.06, green: 0.07, blue: 0.10)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(Color(white: 0.08))
                            .frame(width: 52, height: 52)
                        Circle()
                            .stroke(.white.opacity(0.12), lineWidth: 0.6)
                            .frame(width: 44, height: 44)
                        miniArtwork
                            .frame(width: 33, height: 33)
                            .clipShape(Circle())
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.85)).frame(width: 52, height: 6)
                        RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.45)).frame(width: 36, height: 4)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
            }

        case .poster:
            ZStack(alignment: .bottomLeading) {
                miniArtwork
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                LinearGradient(
                    colors: [.clear, .black.opacity(0.78)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.9)).frame(width: 64, height: 6)
                    RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.55)).frame(width: 42, height: 4)
                }
                .padding(10)
            }
        }
    }

    @ViewBuilder
    private var miniArtwork: some View {
        if let artworkURL, let image = NSImage(contentsOf: artworkURL) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            LinearGradient(
                colors: [.orange.opacity(0.75), .purple.opacity(0.75)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

private struct HelpPage: View {
    let language: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("help.title", language: language))
                    .font(.largeTitle.bold())
                Text(L10n.tr("help.subtitle", language: language))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 14) {
                HelpRow(number: 1, title: L10n.tr("help.step1.title", language: language), detail: L10n.tr("help.step1.detail", language: language))
                HelpRow(number: 2, title: L10n.tr("help.step2.title", language: language), detail: L10n.tr("help.step2.detail", language: language))
                HelpRow(number: 3, title: L10n.tr("help.step3.title", language: language), detail: L10n.tr("help.step3.detail", language: language))
                HelpRow(number: 4, title: L10n.tr("help.step4.title", language: language), detail: L10n.tr("help.step4.detail", language: language))
            }
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            Spacer(minLength: 0)
        }
    }
}

private struct UpdateReleaseCard: View {
    let release: ReleaseInfo
    let stageText: String?
    let language: AppLanguage
    let onInstall: () -> Void
    let onOpenPage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Label(L10n.fmt("update.new_version_banner", language: language, release.tagName), systemImage: "sparkles")
                    .font(.headline)

                Spacer(minLength: 0)

                Button(L10n.tr("update.view_page", language: language), action: onOpenPage)
                    .controlSize(.small)

                if release.dmgURL != nil {
                    Button(L10n.tr("update.install_now", language: language), action: onInstall)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(stageText != nil)
                }
            }

            if let stageText {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(stageText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !release.notes.isEmpty {
                ScrollView {
                    MarkdownNotesView(markdown: release.notes)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 165)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct MarkdownNotesView: View {
    let markdown: String

    private enum LineKind {
        case heading(String)
        case bullet(indentLevel: Int, text: String)
        case paragraph(String)
        case codeBlockLine(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(parsedLines.enumerated()), id: \.offset) { _, line in
                switch line {
                case let .heading(title):
                    Text(inlineMarkdown(title))
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                        .padding(.top, 4)

                case let .bullet(indentLevel, text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(indentLevel == 0 ? "•" : "◦")
                            .foregroundStyle(.secondary)
                        Text(inlineMarkdown(text))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(indentLevel) * 14)

                case let .paragraph(text):
                    Text(inlineMarkdown(text))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                case let .codeBlockLine(code):
                    Text(code)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .textSelection(.enabled)
    }

    private var parsedLines: [LineKind] {
        var result: [LineKind] = []
        var inCodeBlock = false

        for rawLine in markdown.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inCodeBlock.toggle()
                continue
            }
            if inCodeBlock {
                if !trimmed.isEmpty {
                    result.append(.codeBlockLine(rawLine))
                }
                continue
            }
            guard !trimmed.isEmpty else { continue }

            if trimmed.hasPrefix("#") {
                let heading = trimmed.drop(while: { $0 == "#" || $0 == " " })
                if !heading.isEmpty {
                    result.append(.heading(String(heading)))
                }
                continue
            }

            let leadingSpaces = rawLine.prefix(while: { $0 == " " || $0 == "\t" }).count
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                let content = String(trimmed.dropFirst(2))
                result.append(.bullet(indentLevel: leadingSpaces >= 2 ? 1 : 0, text: content))
                continue
            }

            result.append(.paragraph(trimmed))
        }
        return result
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

private struct ActionCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .frame(width: 34, height: 34)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .buttonStyle(.plain)
    }
}

private struct ArtworkPreview: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        Group {
            if let url, let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(
                        colors: [.red.opacity(0.76), .purple.opacity(0.58), .black.opacity(0.9)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.34, weight: .bold))
                        .foregroundStyle(.white.opacity(0.88))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
    }
}

private struct StatusPill: View {
    let text: String
    let systemImage: String
    let isHealthy: Bool

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                isHealthy ? Color.green.opacity(0.18) : Color.secondary.opacity(0.14),
                in: Capsule()
            )
            .foregroundStyle(isHealthy ? .green : .secondary)
    }
}

private struct HelpRow: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private extension NowPlayingSnapshot {
    var isIdle: Bool {
        sourceBundleID.isEmpty && title == NowPlayingSnapshot.empty.title && artist == NowPlayingSnapshot.empty.artist
    }
}

private extension NSImage {
    var pngData: Data? {
        guard let tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffRepresentation) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}

enum MenuBarIcon {
    static func image() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.black.setFill()

        let cloud = NSBezierPath()
        cloud.appendOval(in: NSRect(x: 2.2, y: 8.0, width: 5.8, height: 5.8))
        cloud.appendOval(in: NSRect(x: 5.4, y: 9.6, width: 7.2, height: 6.8))
        cloud.appendOval(in: NSRect(x: 10.2, y: 8.2, width: 5.6, height: 5.6))
        cloud.appendRoundedRect(
            NSRect(x: 3.8, y: 7.0, width: 10.8, height: 4.8),
            xRadius: 2.4,
            yRadius: 2.4
        )
        cloud.fill()

        let stem = NSBezierPath(roundedRect: NSRect(x: 10.9, y: 4.5, width: 1.9, height: 8.2), xRadius: 0.9, yRadius: 0.9)
        stem.fill()

        let flag = NSBezierPath()
        flag.move(to: NSPoint(x: 12.3, y: 12.3))
        flag.line(to: NSPoint(x: 16.0, y: 13.2))
        flag.line(to: NSPoint(x: 16.0, y: 11.0))
        flag.line(to: NSPoint(x: 12.3, y: 10.1))
        flag.close()
        flag.fill()

        let noteHead = NSBezierPath(ovalIn: NSRect(x: 7.5, y: 3.0, width: 5.0, height: 4.2))
        noteHead.fill()

        let discHole = NSBezierPath(ovalIn: NSRect(x: 5.6, y: 4.8, width: 2.1, height: 2.1))
        discHole.fill()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}
