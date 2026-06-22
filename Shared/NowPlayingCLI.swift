import Foundation

enum NowPlayingCLI {
    private static let bundledDirectoryName = "nowplaying-cli"
    private static let executableRelativePath = "bin/nowplaying-cli"

    static var executableURL: URL? {
        executableCandidates.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    static func run(arguments: [String]) throws -> Data {
        guard let executableURL else {
            throw CocoaError(.fileNoSuchFile)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NowPlayingCLIError.commandFailed(
                status: process.terminationStatus,
                output: String(data: data, encoding: .utf8) ?? ""
            )
        }

        return data
    }

    private static var executableCandidates: [URL] {
        var candidates: [URL] = []

        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(
                resourceURL
                    .appendingPathComponent(bundledDirectoryName)
                    .appendingPathComponent(executableRelativePath)
            )
        }

        // App Intents invoked by the Widget extension run inside the nested
        // .appex bundle. Also look in the containing app's Resources folder.
        if Bundle.main.bundleURL.pathExtension == "appex" {
            let appContentsURL = Bundle.main.bundleURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            candidates.append(
                appContentsURL
                    .appendingPathComponent("Resources")
                    .appendingPathComponent(bundledDirectoryName)
                    .appendingPathComponent(executableRelativePath)
            )
        }

        // Keep Homebrew locations as a development fallback.
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/nowplaying-cli"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/nowplaying-cli"))

        var seen = Set<String>()
        return candidates.filter { seen.insert($0.path).inserted }
    }
}

enum NowPlayingCLIError: LocalizedError {
    case commandFailed(status: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(status, output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "nowplaying-cli exited with status \(status)."
                : "nowplaying-cli exited with status \(status): \(detail)"
        }
    }
}
