import AppKit
import SwiftUI
import WidgetKit

@main
struct NeteaseNowPlayingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var monitor: NowPlayingMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = MenuBarIcon.image()
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "网易云小组件"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "立即刷新", action: #selector(refreshNow), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "打开数据目录", action: #selector(openDataFolder), keyEquivalent: "o"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
        self.statusItem = statusItem

        let monitor = NowPlayingMonitor()
        self.monitor = monitor
        monitor.start()
    }

    @objc private func refreshNow() {
        monitor?.refresh()
    }

    @objc private func openDataFolder() {
        let folder = NowPlayingShared.widgetSupportURL()
        try? FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

struct SettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("网易云音乐小组件")
                .font(.title2.bold())
            Text("保持菜单栏助手运行，它会读取 macOS 正在播放信息，并刷新桌面 WidgetKit 小组件。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("数据目录: ~/Library/Containers/\(NowPlayingShared.widgetBundleID)/Data/Library/Application Support/\(NowPlayingShared.supportFolderName)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 480, alignment: .leading)
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
