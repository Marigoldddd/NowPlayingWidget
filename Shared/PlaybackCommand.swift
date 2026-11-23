import Foundation

enum PlaybackCommand: String, Codable {
    case previous
    case play
    case pause
    case next

    var url: URL {
        URL(string: "nowplayingwidget://playback/\(rawValue)")!
    }

    init?(url: URL) {
        guard url.scheme == "nowplayingwidget",
              url.host == "playback" else {
            return nil
        }
        let commandName = url.pathComponents
            .filter { $0 != "/" }
            .first
        guard let commandName else { return nil }
        self.init(rawValue: commandName)
    }
}

struct PlaybackCommandRequest: Codable, Equatable {
    let id: UUID
    let command: PlaybackCommand
    let createdAt: Date
}

enum WidgetDeepLink: Equatable {
    case playback(PlaybackCommand)
    case openPlayer(bundleID: String)

    static func openPlayerURL(bundleID: String) -> URL? {
        guard !bundleID.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "nowplayingwidget"
        components.host = "open-player"
        components.queryItems = [URLQueryItem(name: "bundleID", value: bundleID)]
        return components.url
    }

    init?(url: URL) {
        guard url.scheme == "nowplayingwidget" else { return nil }
        if let command = PlaybackCommand(url: url) {
            self = .playback(command)
            return
        }
        if url.host == "open-player" {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let bundleID = components?.queryItems?.first(where: { $0.name == "bundleID" })?.value ?? ""
            guard !bundleID.isEmpty else { return nil }
            self = .openPlayer(bundleID: bundleID)
            return
        }
        return nil
    }
}
