import AppKit
import SwiftUI
import WidgetKit

struct MusicEntry: TimelineEntry {
    let date: Date
    let snapshot: NowPlayingSnapshot
    let artworkURL: URL?
    let backgroundColor: WidgetBackgroundColor
    let appearance: WidgetAppearance

    func theme(for family: WidgetFamily) -> WidgetTheme {
        let sizeClass: WidgetSizeClass
        switch family {
        case .systemSmall: sizeClass = .small
        case .systemLarge: sizeClass = .large
        default: sizeClass = .medium
        }
        return appearance.theme(for: sizeClass)
    }
}

struct MusicProvider: TimelineProvider {
    func placeholder(in context: Context) -> MusicEntry {
        let appearance = NowPlayingShared.loadAppearance()
        L10n.overrideLanguage = appearance.language
        return MusicEntry(
            date: Date(),
            snapshot: .empty,
            artworkURL: nil,
            backgroundColor: .defaultIdle,
            appearance: appearance
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (MusicEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MusicEntry>) -> Void) {
        let entry = loadEntry()
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60))))
    }

    private func loadEntry() -> MusicEntry {
        let appearance = NowPlayingShared.loadAppearance()
        L10n.overrideLanguage = appearance.language
        let dataURLs = NowPlayingShared.readableDataURLs()

        for dataURL in dataURLs where FileManager.default.fileExists(atPath: dataURL.path) {
            let data: Data
            do {
                data = try Data(contentsOf: dataURL)
            } catch {
                continue
            }

            let snapshot: NowPlayingSnapshot
            do {
                snapshot = try JSONDecoder.widget.decode(NowPlayingSnapshot.self, from: data)
            } catch {
                continue
            }

            let artworkURL = snapshot.isIdle
                ? NowPlayingShared.readableIdleArtworkURLs().first(where: {
                    FileManager.default.fileExists(atPath: $0.path)
                })
                : snapshot.hasArtwork
                ? NowPlayingShared.readableArtworkURLs().first(where: {
                    FileManager.default.fileExists(atPath: $0.path)
                })
                : nil
            let backgroundColor = snapshot.isIdle
                ? WidgetBackgroundColor.fromArtwork(at: artworkURL) ?? .from(snapshot: snapshot)
                : .from(snapshot: snapshot)
            return MusicEntry(
                date: Date(),
                snapshot: snapshot,
                artworkURL: artworkURL,
                backgroundColor: backgroundColor,
                appearance: appearance
            )
        }

        return MusicEntry(
            date: Date(),
            snapshot: .empty,
            artworkURL: nil,
            backgroundColor: .defaultIdle,
            appearance: appearance
        )
    }
}

struct NowPlayingWidgetEntryView: View {
    let entry: MusicEntry
    @Environment(\.widgetFamily) private var family

    private var activeTheme: WidgetTheme {
        entry.theme(for: family)
    }

    var body: some View {
        ZStack {
            if activeTheme == .poster {
                PosterBackground(
                    artworkURL: entry.artworkURL,
                    fallbackColor: entry.backgroundColor
                )
                .ignoresSafeArea()
            }

            Group {
                switch (activeTheme, family) {
                case (.classic, .systemSmall):
                    smallLayout
                case (.classic, .systemLarge):
                    largeLayout
                case (.classic, _):
                    mediumLayout
                case (.vinyl, .systemSmall):
                    vinylSmallLayout
                case (.vinyl, .systemLarge):
                    vinylLargeLayout
                case (.vinyl, _):
                    vinylMediumLayout
                case (.poster, .systemSmall):
                    posterSmallLayout
                case (.poster, .systemLarge):
                    posterLargeLayout
                case (.poster, _):
                    posterMediumLayout
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(WidgetBackground(entry: entry, theme: activeTheme))
        .widgetURL(openPlayerURL)
    }

    private var openPlayerURL: URL? {
        guard !entry.snapshot.isIdle else { return nil }
        return WidgetDeepLink.openPlayerURL(bundleID: entry.snapshot.sourceBundleID)
    }

    private var mediumLayout: some View {
        HStack(spacing: 18) {
            AnimatedArtworkView(entry: entry, size: 122)

            VStack(alignment: .leading, spacing: 9) {
                statusView

                Text(entry.snapshot.title)
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.76)

                Text(entry.snapshot.artist)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.86))
                    .lineLimit(1)

                if !entry.snapshot.album.isEmpty {
                    Text(entry.snapshot.album)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.64))
                        .lineLimit(1)
                }

                if !entry.snapshot.isIdle {
                    controlsView
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 15)
    }

    private var smallLayout: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                AnimatedArtworkView(entry: entry, size: 66)
                Spacer(minLength: 0)
                statusDot
            }

            Spacer(minLength: 0)

            Text(entry.snapshot.title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.8)

            Text(entry.snapshot.artist)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(1)
        }
        .padding(14)
    }

    private var vinylSmallLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VinylDiscView(
                    url: entry.artworkURL,
                    size: 74,
                    isPlaying: entry.snapshot.isPlaying
                )
                Spacer(minLength: 0)
                statusDot
            }

            Spacer(minLength: 0)

            Text(entry.snapshot.title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(entry.snapshot.artist)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
        }
        .padding(14)
    }

    private var vinylMediumLayout: some View {
        HStack(spacing: 16) {
            VinylDiscView(
                url: entry.artworkURL,
                size: 120,
                isPlaying: entry.snapshot.isPlaying
            )

            VStack(alignment: .leading, spacing: 8) {
                statusView

                Text(entry.snapshot.title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.76)

                Text(artistAlbumText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)

                if !entry.snapshot.isIdle {
                    controlsView
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    private var posterSmallLayout: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Spacer(minLength: 0)
                statusDot
                    .shadow(color: .black.opacity(0.5), radius: 3)
            }

            Spacer(minLength: 0)

            Text(entry.snapshot.title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
                .shadow(color: .black.opacity(0.55), radius: 4, y: 1)

            Text(entry.snapshot.artist)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(1)
                .shadow(color: .black.opacity(0.55), radius: 4, y: 1)
        }
        .padding(14)
    }

    private var posterMediumLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                statusDot
                Text(statusText)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.black.opacity(0.42), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(.white.opacity(0.18), lineWidth: 0.8)
            )

            Spacer(minLength: 0)

            Text(entry.snapshot.title)
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.76)
                .shadow(color: .black.opacity(0.6), radius: 6, y: 2)

            Text(artistAlbumText)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.84))
                .lineLimit(1)
                .shadow(color: .black.opacity(0.55), radius: 4, y: 1)

            if !entry.snapshot.isIdle {
                controlsView
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var largeLayout: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                AnimatedArtworkView(entry: entry, size: 108)

                VStack(alignment: .leading, spacing: 7) {
                    statusView

                    Text(entry.snapshot.title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.76)

                    Text(artistAlbumText)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(1)

                    if !entry.snapshot.isIdle {
                        controlsView
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
                .overlay(.white.opacity(0.14))

            lyricPosterSection
        }
        .padding(18)
    }

    private var vinylLargeLayout: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                VinylDiscView(
                    url: entry.artworkURL,
                    size: 112,
                    isPlaying: entry.snapshot.isPlaying
                )

                VStack(alignment: .leading, spacing: 7) {
                    statusView

                    Text(entry.snapshot.title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.76)

                    Text(artistAlbumText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.74))
                        .lineLimit(1)

                    if !entry.snapshot.isIdle {
                        controlsView
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
                .overlay(.white.opacity(0.12))

            lyricPosterSection
        }
        .padding(18)
    }

    private var posterLargeLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                statusDot
                Text(statusText)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.black.opacity(0.42), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(.white.opacity(0.18), lineWidth: 0.8)
            )

            Spacer(minLength: 0)

            lyricPosterSection

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.snapshot.title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.76)
                    .shadow(color: .black.opacity(0.6), radius: 6, y: 2)

                Text(artistAlbumText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.84))
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.55), radius: 4, y: 1)

                if !entry.snapshot.isIdle {
                    controlsView
                        .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
    }

    private var lyricPosterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if entry.snapshot.isIdle {
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                    Text(L10n.tr("widget.lyrics.empty_idle", language: entry.appearance.language))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.70))
                }
                Spacer(minLength: 0)
            } else if entry.snapshot.lyricLines.isEmpty {
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Image(systemName: "music.quarternote.3")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                    Text(L10n.tr("widget.lyrics.instrumental", language: entry.appearance.language))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.74))
                }
                Spacer(minLength: 0)
            } else if !entry.snapshot.lyricTranslations.isEmpty {
                Image(systemName: "quote.opening")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(entry.snapshot.lyricLines.prefix(3).enumerated()), id: \.offset) { index, line in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line)
                                .font(.system(size: 14.5, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.95))
                                .lineLimit(2)
                                .minimumScaleFactor(0.84)
                                .fixedSize(horizontal: false, vertical: true)
                                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)

                            if index < entry.snapshot.lyricTranslations.count {
                                Text(entry.snapshot.lyricTranslations[index])
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.68))
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.84)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .shadow(color: .black.opacity(0.30), radius: 2, y: 1)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            } else {
                Image(systemName: "quote.opening")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))

                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(entry.snapshot.lyricLines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: index < 2 ? 14.5 : 13.5, weight: index < 2 ? .semibold : .medium))
                            .foregroundStyle(.white.opacity(index < 2 ? 0.94 : 0.72))
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                            .fixedSize(horizontal: false, vertical: true)
                            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var artistAlbumText: String {
        entry.snapshot.album.isEmpty
            ? entry.snapshot.artist
            : "\(entry.snapshot.artist) · \(entry.snapshot.album)"
    }

    private var statusView: some View {
        HStack(spacing: 6) {
            statusDot
            Text(statusText)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(1)
        }
    }

    private var statusText: String {
        if entry.snapshot.isIdle { return "IDLE" }
        let state = entry.snapshot.isPlaying ? "PLAYING" : "PAUSED"
        guard !sourceName.isEmpty else { return state }
        return "\(state) · \(sourceName)"
    }

    private var sourceName: String {
        NowPlayingSource.displayName(for: entry.snapshot.sourceBundleID) ?? ""
    }

    private var statusDot: some View {
        Circle()
            .fill(entry.snapshot.isPlaying ? Color(red: 0.36, green: 0.92, blue: 0.42) : .white.opacity(0.42))
            .frame(width: 8, height: 8)
    }

    private var controlsView: some View {
        HStack(spacing: 24) {
            Link(destination: PlaybackCommand.previous.url) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .contentShape(Rectangle())

            if entry.snapshot.isPlaying {
                Link(destination: PlaybackCommand.pause.url) {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 20, weight: .bold))
                        .frame(width: 34, height: 34)
                }
                .contentShape(Rectangle())
            } else {
                Link(destination: PlaybackCommand.play.url) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 20, weight: .bold))
                        .frame(width: 34, height: 34)
                }
                .contentShape(Rectangle())
            }

            Link(destination: PlaybackCommand.next.url) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(.white)
        .frame(width: 134, alignment: .center)
    }
}

struct AnimatedArtworkView: View {
    let entry: MusicEntry
    let size: CGFloat

    var body: some View {
        ArtworkView(url: entry.artworkURL, size: size)
            .id(artworkID)
            .transition(.artworkSpin)
            .animation(.spring(response: 0.58, dampingFraction: 0.82), value: artworkID)
    }

    private var artworkID: String {
        [
            entry.snapshot.title,
            entry.snapshot.artist,
            entry.snapshot.album,
            entry.snapshot.hasArtwork ? "artwork" : "placeholder"
        ].joined(separator: "|")
    }
}

struct ArtworkView: View {
    let url: URL?
    let size: CGFloat
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        ZStack {
            if let image = image {
                artworkImage(image)
            } else {
                LinearGradient(
                    colors: [Color.white.opacity(0.20), Color.white.opacity(0.06)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.40), radius: 16, x: 0, y: 12)
        .shadow(color: .white.opacity(0.08), radius: 1, x: 0, y: -1)
    }

    private var image: NSImage? {
        guard let url else { return nil }
        return NSImage(contentsOf: url)
    }

    @ViewBuilder
    private func artworkImage(_ image: NSImage) -> some View {
        if #available(macOSApplicationExtension 15.0, *) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.medium)
                .widgetAccentedRenderingMode(renderingMode == .accented ? .fullColor : nil)
                .scaledToFill()
        } else {
            Image(nsImage: image)
                .resizable()
                .interpolation(.medium)
                .scaledToFill()
        }
    }
}

private struct ArtworkSpinModifier: ViewModifier {
    let angle: Double
    let scale: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .scaleEffect(scale)
            .rotation3DEffect(
                .degrees(angle),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.72
            )
    }
}

private extension AnyTransition {
    static var artworkSpin: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: ArtworkSpinModifier(angle: -360, scale: 0.82, opacity: 0),
                identity: ArtworkSpinModifier(angle: 0, scale: 1, opacity: 1)
            ),
            removal: .modifier(
                active: ArtworkSpinModifier(angle: 120, scale: 0.92, opacity: 0),
                identity: ArtworkSpinModifier(angle: 0, scale: 1, opacity: 1)
            )
        )
    }
}

struct CardBackground: View {
    let backgroundColor: WidgetBackgroundColor

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    color(scale: 1.58),
                    color(scale: 0.94),
                    color(scale: 0.36)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [.white.opacity(0.18), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 220
            )

            LinearGradient(
                colors: [.black.opacity(0.06), .black.opacity(0.34)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private func color(scale: Double) -> Color {
        Color(
            red: min(max(backgroundColor.red * scale, 0), 1),
            green: min(max(backgroundColor.green * scale, 0), 1),
            blue: min(max(backgroundColor.blue * scale, 0), 1)
        )
    }
}

struct WidgetBackgroundColor {
    let red: Double
    let green: Double
    let blue: Double

    static let defaultIdle = WidgetBackgroundColor(red: 0.64, green: 0.10, blue: 0.13)

    static func from(snapshot: NowPlayingSnapshot) -> WidgetBackgroundColor {
        WidgetBackgroundColor(
            red: snapshot.backgroundRed,
            green: snapshot.backgroundGreen,
            blue: snapshot.backgroundBlue
        )
    }

    static func fromArtwork(at url: URL?) -> WidgetBackgroundColor? {
        guard let url,
              let image = NSImage(contentsOf: url),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        let step = max(1, min(width, height) / 32)
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var count = 0.0

        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    continue
                }
                red += color.redComponent
                green += color.greenComponent
                blue += color.blueComponent
                count += 1
            }
        }

        guard count > 0 else { return nil }

        let average = NSColor(
            srgbRed: red / count,
            green: green / count,
            blue: blue / count,
            alpha: 1
        )

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)

        let displaySaturation = min(max(saturation * 1.55, 0.30), 0.88)
        let displayBrightness = min(max(brightness * 0.50, 0.18), 0.42)
        let displayColor = NSColor(
            hue: hue,
            saturation: displaySaturation,
            brightness: displayBrightness,
            alpha: 1
        ).usingColorSpace(.sRGB) ?? average

        return WidgetBackgroundColor(
            red: Double(displayColor.redComponent),
            green: Double(displayColor.greenComponent),
            blue: Double(displayColor.blueComponent)
        )
    }
}

struct VinylDiscView: View {
    let url: URL?
    let size: CGFloat
    let isPlaying: Bool
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                // Outer subtle rim shadow
                Circle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: size, height: size)

                // Dark vinyl record base
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color(white: 0.16), Color(white: 0.05), Color(white: 0.10)],
                            center: .center,
                            startRadius: size * 0.28,
                            endRadius: size * 0.50
                        )
                    )
                    .frame(width: size * 0.96, height: size * 0.96)

                // Diagonal vinyl sheen
                Circle()
                    .fill(
                        AngularGradient(
                            colors: [
                                .white.opacity(0.0),
                                .white.opacity(0.11),
                                .white.opacity(0.0),
                                .white.opacity(0.08),
                                .white.opacity(0.0)
                            ],
                            center: .center
                        )
                    )
                    .frame(width: size * 0.95, height: size * 0.95)

                // Concentric vinyl grooves in the outer ring
                ForEach([0.72, 0.78, 0.84, 0.90], id: \.self) { ratio in
                    Circle()
                        .stroke(.white.opacity(0.07), lineWidth: 0.6)
                        .frame(width: size * ratio, height: size * ratio)
                }

                // Large center album artwork (~64% of disc diameter)
                Group {
                    if let url, let image = NSImage(contentsOf: url) {
                        artworkImage(image)
                    } else {
                        ZStack {
                            LinearGradient(
                                colors: [Color.white.opacity(0.22), Color.white.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            Image(systemName: "music.note")
                                .font(.system(size: size * 0.24, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.76))
                        }
                    }
                }
                .frame(width: size * 0.64, height: size * 0.64)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(.black.opacity(0.45), lineWidth: 1.5)
                )
            }
            .shadow(color: .black.opacity(0.48), radius: 14, x: 0, y: 8)

            // Minimal white/silver tonearm at top-right
            VinylTonearmView(length: size * 0.44, isPlaying: isPlaying)
                .offset(x: size * 0.08, y: -size * 0.04)
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private func artworkImage(_ image: NSImage) -> some View {
        if #available(macOSApplicationExtension 15.0, *) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.medium)
                .widgetAccentedRenderingMode(renderingMode == .accented ? .fullColor : nil)
                .scaledToFill()
        } else {
            Image(nsImage: image)
                .resizable()
                .interpolation(.medium)
                .scaledToFill()
        }
    }
}

private struct VinylTonearmView: View {
    let length: CGFloat
    let isPlaying: Bool

    var body: some View {
        ZStack(alignment: .top) {
            // Pivot base
            Circle()
                .fill(.white.opacity(0.92))
                .frame(width: length * 0.20, height: length * 0.20)
                .overlay(
                    Circle()
                        .fill(Color(white: 0.28))
                        .frame(width: length * 0.07, height: length * 0.07)
                )
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)

            // Curved arm + cartridge head
            Path { path in
                let start = CGPoint(x: length * 0.5, y: length * 0.10)
                let bend = CGPoint(x: length * 0.42, y: length * 0.64)
                let tip = CGPoint(x: length * 0.22, y: length * 0.90)
                path.move(to: start)
                path.addQuadCurve(to: tip, control: bend)
            }
            .stroke(.white.opacity(0.92), style: StrokeStyle(lineWidth: max(2.2, length * 0.065), lineCap: .round))
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)

            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(.white.opacity(0.95))
                .frame(width: length * 0.14, height: length * 0.24)
                .rotationEffect(.degrees(34))
                .offset(x: -length * 0.26, y: length * 0.78)
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
        }
        .frame(width: length, height: length)
        .rotationEffect(.degrees(isPlaying ? 0 : -18), anchor: UnitPoint(x: 0.5, y: 0.10))
    }
}

struct VinylCardBackground: View {
    let backgroundColor: WidgetBackgroundColor

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(
                        red: min(max(backgroundColor.red * 0.45 + 0.09, 0.09), 0.26),
                        green: min(max(backgroundColor.green * 0.45 + 0.09, 0.09), 0.26),
                        blue: min(max(backgroundColor.blue * 0.45 + 0.11, 0.12), 0.30)
                    ),
                    Color(red: 0.06, green: 0.07, blue: 0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [.white.opacity(0.08), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 240
            )
        }
    }
}

struct PosterBackground: View {
    let artworkURL: URL?
    let fallbackColor: WidgetBackgroundColor
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        ZStack {
            if let artworkURL, let image = NSImage(contentsOf: artworkURL) {
                GeometryReader { proxy in
                    posterImage(compositedPosterImage(from: image) ?? image)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                }
            } else if renderingMode != .accented {
                CardBackground(backgroundColor: fallbackColor)
            }
        }
    }

    /// Bakes the dark readability scrim directly into the image so accented/transparent
    /// widget mode renders the full-bleed poster with identical contrast and never washes
    /// out a separate SwiftUI gradient overlay.
    private func compositedPosterImage(from image: NSImage) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let width = min(max(cgImage.width, 1), 640)
        let height = min(max(cgImage.height, 1), 640)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.interpolationQuality = .high
        context.draw(cgImage, in: rect)

        // Vertical scrim: lighter at top (CoreGraphics y=height), darker at bottom (y=0).
        let verticalColors = [
            CGColor(red: 0, green: 0, blue: 0, alpha: 0.78),
            CGColor(red: 0, green: 0, blue: 0, alpha: 0.34),
            CGColor(red: 0, green: 0, blue: 0, alpha: 0.14),
        ] as CFArray
        let verticalLocations: [CGFloat] = [0.0, 0.52, 1.0]
        if let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: verticalColors,
            locations: verticalLocations
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: 0, y: CGFloat(height)),
                options: []
            )
        }

        // Subtle left-to-right scrim for text readability.
        let horizontalColors = [
            CGColor(red: 0, green: 0, blue: 0, alpha: 0.34),
            CGColor(red: 0, green: 0, blue: 0, alpha: 0.0),
        ] as CFArray
        if let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: horizontalColors,
            locations: [0.0, 1.0]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: CGFloat(width), y: 0),
                options: []
            )
        }

        guard let output = context.makeImage() else { return nil }
        return NSImage(cgImage: output, size: NSSize(width: width, height: height))
    }

    @ViewBuilder
    private func posterImage(_ image: NSImage) -> some View {
        if #available(macOSApplicationExtension 15.0, *) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .widgetAccentedRenderingMode(renderingMode == .accented ? .fullColor : nil)
                .scaledToFill()
        } else {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
        }
    }
}

struct WidgetBackground: ViewModifier {
    let entry: MusicEntry
    let theme: WidgetTheme

    @ViewBuilder
    private var backgroundView: some View {
        switch theme {
        case .classic, .poster:
            CardBackground(backgroundColor: entry.backgroundColor)
        case .vinyl:
            VinylCardBackground(backgroundColor: entry.backgroundColor)
        }
    }

    func body(content: Content) -> some View {
        if #available(macOSApplicationExtension 14.0, *) {
            content.containerBackground(for: .widget) {
                backgroundView
            }
        } else {
            content.background(backgroundView)
        }
    }
}

@main
struct NowPlayingWidgetExtension: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: NowPlayingShared.widgetKind,
            provider: MusicProvider()
        ) { entry in
            NowPlayingWidgetEntryView(entry: entry)
        }
        .configurationDisplayName(LocalizedStringResource("widget.display_name"))
        .description(LocalizedStringResource("widget.description"))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

private extension JSONDecoder {
    static var widget: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension NowPlayingSnapshot {
    var isIdle: Bool {
        sourceBundleID.isEmpty && title == NowPlayingSnapshot.empty.title && artist == NowPlayingSnapshot.empty.artist
    }
}
