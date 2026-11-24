import AppKit
import Foundation

struct SemanticVersion: Comparable, Equatable {
    let components: [Int]
    let raw: String

    init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.hasPrefix("v") || trimmed.hasPrefix("V")
            ? String(trimmed.dropFirst())
            : trimmed
        let core = cleaned.split(separator: "-", maxSplits: 1).first.map(String.init) ?? cleaned
        let parts = core.split(separator: ".")
        guard !parts.isEmpty else { return nil }

        var parsed: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            parsed.append(value)
        }
        self.components = parsed
        self.raw = cleaned
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }

    static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

struct ReleaseInfo: Equatable {
    let tagName: String
    let version: SemanticVersion
    let notes: String
    let htmlURL: URL
    let dmgURL: URL?
    let dmgName: String?
}

enum UpdateCheckResult: Equatable {
    case upToDate(currentVersion: String)
    case updateAvailable(ReleaseInfo)
}

enum AppUpdaterError: LocalizedError {
    case invalidResponse
    case rateLimited
    case httpStatus(Int)
    case missingDMGAsset
    case untrustedDownloadHost
    case mountFailed(String)
    case invalidAppBundle
    case movedToDownloads(URL)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return L10n.tr("update.error.invalid_response")
        case .rateLimited:
            return L10n.tr("update.error.rate_limited")
        case let .httpStatus(code):
            return L10n.fmt("update.error.http_status", code)
        case .missingDMGAsset:
            return L10n.tr("update.error.missing_dmg")
        case .untrustedDownloadHost:
            return L10n.tr("update.error.untrusted_url")
        case let .mountFailed(detail):
            return L10n.fmt("update.error.mount_failed", detail)
        case .invalidAppBundle:
            return L10n.tr("update.error.invalid_bundle")
        case let .movedToDownloads(url):
            return L10n.fmt("update.error.permission_denied", url.lastPathComponent)
        }
    }
}

final class AppUpdater {
    static let repoLatestReleaseURL = URL(
        string: "https://api.github.com/repos/Marigoldddd/NowPlayingWidget/releases/latest"
    )!
    static let releasesPageURL = URL(
        string: "https://github.com/Marigoldddd/NowPlayingWidget/releases"
    )!

    private static let lastLaunchedVersionKey = "NowPlayingWidget.lastLaunchedBuildIdentity"
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 10
            config.timeoutIntervalForResource = 300
            self.session = URLSession(configuration: config)
        }
    }

    static var currentVersionString: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
    }

    static var currentBuildIdentity: String {
        let short = currentVersionString
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
        return "\(short)-\(build)"
    }

    /// Automatically restarts any stale widget extension process once after an app upgrade.
    static func refreshWidgetExtensionIfUpgraded() {
        let identity = currentBuildIdentity
        let previous = UserDefaults.standard.string(forKey: lastLaunchedVersionKey)
        guard previous != identity else { return }
        UserDefaults.standard.set(identity, forKey: lastLaunchedVersionKey)
        guard previous != nil else { return }

        let killTask = Process()
        killTask.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killTask.arguments = ["NowPlayingWidgetExtension"]
        killTask.standardOutput = Pipe()
        killTask.standardError = Pipe()
        try? killTask.run()
        killTask.waitUntilExit()
    }

    func checkForUpdates(currentVersion: String = AppUpdater.currentVersionString) async throws -> UpdateCheckResult {
        var request = URLRequest(url: Self.repoLatestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("NowPlayingWidget/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppUpdaterError.invalidResponse
        }
        if http.statusCode == 403 || http.statusCode == 429 {
            throw AppUpdaterError.rateLimited
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AppUpdaterError.httpStatus(http.statusCode)
        }

        let release = try Self.parseRelease(from: data)
        guard let localVersion = SemanticVersion(currentVersion) else {
            throw AppUpdaterError.invalidResponse
        }

        if release.version > localVersion {
            return .updateAvailable(release)
        }
        return .upToDate(currentVersion: localVersion.raw)
    }

    static func parseRelease(from data: Data) throws -> ReleaseInfo {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String,
              let version = SemanticVersion(tagName),
              let htmlString = json["html_url"] as? String,
              let htmlURL = URL(string: htmlString) else {
            throw AppUpdaterError.invalidResponse
        }

        let notes = (json["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var dmgURL: URL?
        var dmgName: String?

        if let assets = json["assets"] as? [[String: Any]] {
            for asset in assets {
                guard let name = asset["name"] as? String,
                      name.lowercased().hasSuffix(".dmg"),
                      let urlString = asset["browser_download_url"] as? String,
                      let url = URL(string: urlString) else {
                    continue
                }
                dmgURL = url
                dmgName = name
                break
            }
        }

        return ReleaseInfo(
            tagName: tagName,
            version: version,
            notes: notes,
            htmlURL: htmlURL,
            dmgURL: dmgURL,
            dmgName: dmgName
        )
    }

    func downloadAndInstall(
        release: ReleaseInfo,
        onStage: @MainActor @escaping (String) -> Void
    ) async throws {
        guard let dmgURL = release.dmgURL else {
            throw AppUpdaterError.missingDMGAsset
        }
        guard Self.isTrustedDownloadURL(dmgURL) else {
            throw AppUpdaterError.untrustedDownloadHost
        }

        await onStage(L10n.fmt("update.stage.downloading", release.dmgName ?? release.tagName))

        var request = URLRequest(url: dmgURL)
        request.setValue("NowPlayingWidget/\(Self.currentVersionString)", forHTTPHeaderField: "User-Agent")
        let (tempDownloadedURL, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw AppUpdaterError.httpStatus(code)
        }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NowPlayingWidgetUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let dmgPath = workDir.appendingPathComponent(release.dmgName ?? "NowPlayingWidget.dmg")
        try FileManager.default.moveItem(at: tempDownloadedURL, to: dmgPath)

        let targetAppURL = Self.preferredInstallURL()
        let parentDir = targetAppURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parentDir.path) else {
            let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
            let fallbackURL = downloadsDir.appendingPathComponent(dmgPath.lastPathComponent)
            try? FileManager.default.removeItem(at: fallbackURL)
            try FileManager.default.moveItem(at: dmgPath, to: fallbackURL)
            try? FileManager.default.removeItem(at: workDir)
            await MainActor.run {
                NSWorkspace.shared.activateFileViewerSelecting([fallbackURL])
            }
            throw AppUpdaterError.movedToDownloads(fallbackURL)
        }

        await onStage(L10n.tr("update.stage.mounting"))

        let mountDir = workDir.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mountDir, withIntermediateDirectories: true)

        let attachResult = try Self.runProcess(
            executable: "/usr/bin/hdiutil",
            arguments: ["attach", "-nobrowse", "-readonly", "-mountpoint", mountDir.path, dmgPath.path]
        )
        guard attachResult.status == 0 else {
            try? FileManager.default.removeItem(at: workDir)
            throw AppUpdaterError.mountFailed(attachResult.output)
        }

        let stagingAppURL = workDir.appendingPathComponent("NowPlayingWidget.app", isDirectory: true)
        do {
            let mountedAppURL = mountDir.appendingPathComponent("NowPlayingWidget.app", isDirectory: true)
            guard Self.isValidReplacementApp(at: mountedAppURL) else {
                throw AppUpdaterError.invalidAppBundle
            }

            let copyResult = try Self.runProcess(
                executable: "/usr/bin/ditto",
                arguments: [mountedAppURL.path, stagingAppURL.path]
            )
            guard copyResult.status == 0, Self.isValidReplacementApp(at: stagingAppURL) else {
                throw AppUpdaterError.invalidAppBundle
            }
        } catch {
            _ = try? Self.runProcess(
                executable: "/usr/bin/hdiutil",
                arguments: ["detach", mountDir.path, "-force"]
            )
            try? FileManager.default.removeItem(at: workDir)
            throw error
        }

        _ = try? Self.runProcess(
            executable: "/usr/bin/hdiutil",
            arguments: ["detach", mountDir.path, "-force"]
        )
        try? FileManager.default.removeItem(at: dmgPath)

        // Ensure no quarantine attribute blocks relaunching the updated ad-hoc bundle.
        _ = try? Self.runProcess(
            executable: "/usr/bin/xattr",
            arguments: ["-dr", "com.apple.quarantine", stagingAppURL.path]
        )

        await onStage(L10n.tr("update.stage.replacing"))

        try Self.launchDetachedInstaller(
            currentPID: ProcessInfo.processInfo.processIdentifier,
            stagingAppURL: stagingAppURL,
            targetAppURL: targetAppURL,
            workDir: workDir
        )

        await MainActor.run {
            NSApp.terminate(nil)
        }
    }

    static func isTrustedDownloadURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else {
            return false
        }
        return host == "github.com"
            || host.hasSuffix(".github.com")
            || host == "githubusercontent.com"
            || host.hasSuffix(".githubusercontent.com")
    }

    private static func preferredInstallURL() -> URL {
        let currentURL = Bundle.main.bundleURL.standardizedFileURL
        if currentURL.pathExtension == "app",
           FileManager.default.isWritableFile(atPath: currentURL.deletingLastPathComponent().path) {
            return currentURL
        }
        return URL(fileURLWithPath: "/Applications/NowPlayingWidget.app")
    }

    private static func isValidReplacementApp(at appURL: URL) -> Bool {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        let executableURL = appURL.appendingPathComponent("Contents/MacOS/NowPlayingWidget")
        guard FileManager.default.isExecutableFile(atPath: executableURL.path),
              let plist = NSDictionary(contentsOf: infoURL),
              let bundleID = plist["CFBundleIdentifier"] as? String else {
            return false
        }
        let expectedID = Bundle.main.bundleIdentifier ?? "com.marigold.NowPlayingWidget"
        return bundleID == expectedID
    }

    private static func runProcess(
        executable: String,
        arguments: [String]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, text)
    }

    private static func launchDetachedInstaller(
        currentPID: Int32,
        stagingAppURL: URL,
        targetAppURL: URL,
        workDir: URL
    ) throws {
        let script = """
        OLD_PID="$1"
        STAGING_APP="$2"
        TARGET_APP="$3"
        WORK_DIR="$4"
        LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"

        i=0
        while kill -0 "$OLD_PID" 2>/dev/null && [ "$i" -lt 50 ]; do
            sleep 0.1
            i=$((i + 1))
        done

        killall NowPlayingWidgetExtension 2>/dev/null || true
        rm -rf "$TARGET_APP"
        ditto "$STAGING_APP" "$TARGET_APP"
        rm -rf "$WORK_DIR"
        "$LSREG" -f -R -trusted "$TARGET_APP" 2>/dev/null || true
        pluginkit -a "$TARGET_APP/Contents/PlugIns/NowPlayingWidgetExtension.appex" 2>/dev/null || true
        open -a "$TARGET_APP"
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            script,
            "npw-updater",
            String(currentPID),
            stagingAppURL.path,
            targetAppURL.path,
            workDir.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}
