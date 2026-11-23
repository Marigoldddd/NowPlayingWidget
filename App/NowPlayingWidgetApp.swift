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
    private let model = NowPlayingAppModel.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = MenuBarIcon.image()
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "正在播放小组件"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "打开主页面", action: #selector(openMainWindow), keyEquivalent: "o"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
        self.statusItem = statusItem

        model.startMonitoring()

        let isDefaultLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        if isDefaultLaunch {
            MainWindowController.shared.show()
        }
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
    static let shared = NowPlayingAppModel()

    @Published private(set) var snapshot: NowPlayingSnapshot
    @Published private(set) var lastRefreshDate: Date?
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var hasIdleArtwork: Bool
    @Published private(set) var appearance: WidgetAppearance
    @Published private(set) var artworkRevision = 0
    @Published private(set) var message: String?
    @Published private(set) var widgetSyncReport: WidgetSyncReport?

    private let monitor = NowPlayingMonitor()
    private var hasStarted = false

    private init() {
        let snapshot = Self.loadSavedSnapshot()
        self.snapshot = snapshot
        self.lastRefreshDate = snapshot.updatedAt.timeIntervalSince1970 > 0 ? snapshot.updatedAt : nil
        self.hasIdleArtwork = Self.idleArtworkExists
        self.appearance = NowPlayingShared.loadAppearance()
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
                ? "已开启按尺寸设置皮肤，可分别选择小号、中号、大号皮肤。"
                : "已恢复统一皮肤（\(next.theme.displayName)）。"
        )
    }

    func selectTheme(_ theme: WidgetTheme, for sizeClass: WidgetSizeClass? = nil) {
        var next = appearance
        if let sizeClass, appearance.usesPerSizeThemes {
            guard appearance.theme(for: sizeClass) != theme else { return }
            next.setTheme(theme, for: sizeClass)
            saveAppearance(
                next,
                statusMessage: "已将「\(sizeClass.displayName)」小组件切换为「\(theme.displayName)」。"
            )
        } else {
            guard appearance.theme != theme || appearance.usesPerSizeThemes else { return }
            next = WidgetAppearance(theme: theme)
            saveAppearance(
                next,
                statusMessage: "已切换为「\(theme.displayName)」皮肤，正在请求刷新小组件。"
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
            message = "保存皮肤设置失败: \(error.localizedDescription)"
        }
    }

    var sourceName: String {
        NowPlayingSource.displayName(for: snapshot.sourceBundleID)
            ?? (snapshot.isIdle ? "等待音乐播放" : "未知播放器")
    }

    var playbackStateText: String {
        if snapshot.isIdle { return "未检测到音乐" }
        return snapshot.isPlaying ? "播放中" : "已暂停"
    }

    var cliStatusText: String {
        NowPlayingCLI.executableURL == nil ? "未找到内置 nowplaying-cli" : "内置 nowplaying-cli 可用"
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

        monitor.onSnapshotRead = { [weak self] snapshot in
            self?.snapshot = snapshot
            self?.lastRefreshDate = Date()
            self?.lastErrorMessage = nil
        }
        monitor.onSnapshotWritten = { [weak self] in
            self?.artworkRevision += 1
        }
        monitor.onRefreshError = { [weak self] detail in
            self?.lastErrorMessage = detail
        }
        monitor.start()
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
            message = "静止图片已更新。"
            WidgetCenter.shared.reloadTimelines(ofKind: NowPlayingShared.widgetKind)
        } catch {
            message = "保存图片失败: \(error.localizedDescription)"
        }
    }

    func removeIdleArtwork() {
        for container in NowPlayingShared.writableContainerURLs() {
            let url = container.appendingPathComponent(NowPlayingShared.idleArtworkFileName)
            try? FileManager.default.removeItem(at: url)
        }
        hasIdleArtwork = false
        artworkRevision += 1
        message = "已恢复默认音乐图标。"
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
            read = .done(snapshot.isIdle ? "未检测到支持的播放器，使用待机画面" : "已读取：\(snapshot.title)")
            write = .running
        case .written:
            write = .done("已写入小组件数据")
            request = .running
        case .reloadRequested:
            request = .done("已请求更新，实际显示由 macOS 调度")
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
        TabView(selection: $selectedTab) {
            OverviewPage(model: model)
                .tabItem {
                    Label("概览", systemImage: "music.note")
                }
                .tag(MainTab.overview)

            AppearancePage(model: model)
                .tabItem {
                    Label("外观", systemImage: "photo")
                }
                .tag(MainTab.appearance)

            HelpPage()
                .tabItem {
                    Label("帮助", systemImage: "questionmark.circle")
                }
                .tag(MainTab.help)
        }
        .padding(22)
        .frame(minWidth: 720, minHeight: 500)
    }
}

private enum MainTab {
    case overview
    case appearance
    case help
}

private struct OverviewPage: View {
    @ObservedObject var model: NowPlayingAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Now Playing Widget")
                    .font(.largeTitle.bold())
                Text("桌面小组件的控制台。保持这个 App 运行，小组件就会同步当前播放信息。")
                    .foregroundStyle(.secondary)
            }

            StatusCard(model: model)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                ActionCard(
                    title: model.widgetSyncReport?.isInProgress == true ? "同步中…" : "同步小组件",
                    subtitle: "读取歌曲、写入数据并请求更新",
                    systemImage: "arrow.clockwise"
                ) {
                    model.syncWidget()
                }
                .disabled(model.widgetSyncReport?.isInProgress == true)
                .accessibilityIdentifier("syncWidget")

                ActionCard(
                    title: "打开数据目录",
                    subtitle: "查看共享 JSON 和封面文件",
                    systemImage: "folder"
                ) {
                    model.openDataFolder()
                }
            }

            if let report = model.widgetSyncReport {
                VStack(alignment: .leading, spacing: 6) {
                    syncRow("读取播放信息", step: report.read)
                    syncRow("写入数据", step: report.write)
                    syncRow("请求刷新", step: report.request)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private func syncRow(_ title: String, step: WidgetSyncReport.Step) -> some View {
        let (icon, detail, color): (String, String, Color)
        switch step {
        case .waiting: (icon, detail, color) = ("circle", "等待中", .secondary)
        case .running: (icon, detail, color) = ("clock", "进行中…", .secondary)
        case .skipped: (icon, detail, color) = ("minus.circle", "未执行", .secondary)
        case let .done(text): (icon, detail, color) = ("checkmark.circle.fill", text, .green)
        case let .failed(text): (icon, detail, color) = ("exclamationmark.circle.fill", "失败：\(text)", .orange)
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
        guard let date = model.lastRefreshDate else {
            return "尚未读取播放信息"
        }
        return "上次读取：\(Self.formatter.localizedString(for: date, relativeTo: Date()))"
    }

    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}

private struct AppearancePage: View {
    @ObservedObject var model: NowPlayingAppModel
    @State private var selectedSizeClass: WidgetSizeClass = .medium

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("外观")
                        .font(.largeTitle.bold())
                    Text("选择桌面小组件皮肤，或自定义未播放音乐时显示的静止图片。")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("小组件皮肤")
                            .font(.title3.bold())
                        Spacer(minLength: 0)
                        Toggle(
                            "按尺寸分别设置",
                            isOn: Binding(
                                get: { model.isPerSizeThemeEnabled },
                                set: { model.setPerSizeThemeEnabled($0) }
                            )
                        )
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }

                    if model.isPerSizeThemeEnabled {
                        Picker("小组件尺寸", selection: $selectedSizeClass) {
                            ForEach(WidgetSizeClass.allCases) { sizeClass in
                                Text("\(sizeClass.displayName)（\(model.theme(for: sizeClass).displayName)）")
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
                            .id("\(theme.rawValue)-\(model.artworkRevision)")
                        }
                    }

                    Text(
                        model.isPerSizeThemeEnabled
                            ? "已开启按尺寸设置：可分别为桌面上的小号、中号、大号小组件指定不同皮肤。"
                            : "当前所有尺寸共用同一套皮肤；开启右上角「按尺寸分别设置」可给小 / 中 / 大号单独选皮肤。"
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
                        Text("静止状态图片")
                            .font(.title3.bold())
                        Text("未检测到音乐时，小组件会优先显示这里设置的图片；不设置则使用默认音乐图标。")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 10) {
                            Button(model.hasIdleArtwork ? "更换图片" : "选择图片") {
                                model.chooseIdleArtwork()
                            }
                            Button("删除图片") {
                                model.removeIdleArtwork()
                            }
                            .disabled(!model.hasIdleArtwork)
                        }

                        Text(model.hasIdleArtwork ? "当前：已设置自定义图片" : "当前：使用默认图标")
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

                VStack(alignment: .leading, spacing: 8) {
                    Text("数据目录")
                        .font(.headline)
                    Text(model.supportFolderPath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button("在 Finder 中打开") {
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
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("帮助")
                    .font(.largeTitle.bold())
                Text("第一次安装后，可以按这个流程确认小组件已经正常工作。")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 14) {
                HelpRow(number: 1, title: "保持 App 运行", detail: "菜单栏里出现音乐图标后，后台同步服务就已经启动。")
                HelpRow(number: 2, title: "添加桌面小组件", detail: "在 macOS 的小组件面板中添加“正在播放”。")
                HelpRow(number: 3, title: "播放音乐并同步", detail: "支持网易云音乐、QQ 音乐、Apple Music 和 Spotify。如需手动同步，前往「概览」点击「同步小组件」；桌面更新时机由 macOS 决定。")
                HelpRow(number: 4, title: "使用播放控制", detail: "小组件里的上一首、播放暂停、下一首按钮会唤起主 App 执行控制，所以主 App 需要保持运行。")
            }
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            Spacer(minLength: 0)
        }
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
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
