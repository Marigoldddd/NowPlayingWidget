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
