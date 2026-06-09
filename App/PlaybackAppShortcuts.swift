import AppIntents

struct PlaybackAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PreviousTrackIntent(),
            phrases: ["\(.applicationName) previous track"],
            shortTitle: "上一首",
            systemImageName: "backward.fill"
        )
        AppShortcut(
            intent: PlayTrackIntent(),
            phrases: ["\(.applicationName) play music"],
            shortTitle: "播放",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: PauseTrackIntent(),
            phrases: ["\(.applicationName) pause music"],
            shortTitle: "暂停",
            systemImageName: "pause.fill"
        )
        AppShortcut(
            intent: NextTrackIntent(),
            phrases: ["\(.applicationName) next track"],
            shortTitle: "下一首",
            systemImageName: "forward.fill"
        )
    }
}
