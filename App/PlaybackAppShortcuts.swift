import AppIntents

struct PlaybackAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PreviousTrackIntent(),
            phrases: ["\(.applicationName) previous track"],
            shortTitle: "Previous Track",
            systemImageName: "backward.fill"
        )
        AppShortcut(
            intent: PlayTrackIntent(),
            phrases: ["\(.applicationName) play music"],
            shortTitle: "Play",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: PauseTrackIntent(),
            phrases: ["\(.applicationName) pause music"],
            shortTitle: "Pause",
            systemImageName: "pause.fill"
        )
        AppShortcut(
            intent: NextTrackIntent(),
            phrases: ["\(.applicationName) next track"],
            shortTitle: "Next Track",
            systemImageName: "forward.fill"
        )
    }
}
