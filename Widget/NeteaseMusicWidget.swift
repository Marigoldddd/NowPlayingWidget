import AppKit
import AppIntents
import SwiftUI
import WidgetKit

struct MusicEntry: TimelineEntry {
    let date: Date
    let snapshot: NowPlayingSnapshot
    let artworkURL: URL?
    let backgroundColor: WidgetBackgroundColor
}

struct MusicProvider: TimelineProvider {
    func placeholder(in context: Context) -> MusicEntry {
        MusicEntry(date: Date(), snapshot: .empty, artworkURL: nil, backgroundColor: .defaultIdle)
    }

    func getSnapshot(in context: Context, completion: @escaping (MusicEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MusicEntry>) -> Void) {
        let entry = loadEntry()
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60))))
    }

    private func loadEntry() -> MusicEntry {
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
            return MusicEntry(date: Date(), snapshot: snapshot, artworkURL: artworkURL, backgroundColor: backgroundColor)
        }

        return MusicEntry(date: Date(), snapshot: .empty, artworkURL: nil, backgroundColor: .defaultIdle)
    }
}

struct NeteaseMusicWidgetEntryView: View {
    let entry: MusicEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if family == .systemSmall {
                smallLayout
            } else {
                mediumLayout
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(WidgetBackground(backgroundColor: entry.backgroundColor))
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
        switch entry.snapshot.sourceBundleID {
        case "com.apple.Music":
            return "Apple Music"
        case "com.netease.163music":
            return "网易云音乐"
        default:
            return ""
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(entry.snapshot.isPlaying ? Color(red: 0.36, green: 0.92, blue: 0.42) : .white.opacity(0.42))
            .frame(width: 8, height: 8)
    }

    private var controlsView: some View {
        HStack(spacing: 24) {
            Button(intent: PreviousTrackIntent()) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            if entry.snapshot.isPlaying {
                Button(intent: PauseTrackIntent()) {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 20, weight: .bold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            } else {
                Button(intent: PlayTrackIntent()) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 20, weight: .bold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }

            Button(intent: NextTrackIntent()) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
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

struct WidgetBackground: ViewModifier {
    let backgroundColor: WidgetBackgroundColor

    func body(content: Content) -> some View {
        if #available(macOSApplicationExtension 14.0, *) {
            content.containerBackground(for: .widget) {
                CardBackground(backgroundColor: backgroundColor)
            }
        } else {
            content.background(CardBackground(backgroundColor: backgroundColor))
        }
    }
}

@main
struct NeteaseMusicWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: NowPlayingShared.widgetKind,
            provider: MusicProvider()
        ) { entry in
            NeteaseMusicWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("正在播放")
        .description("显示当前网易云音乐或 Apple Music 的歌曲、歌手、封面和播放状态。")
        .supportedFamilies([.systemSmall, .systemMedium])
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
