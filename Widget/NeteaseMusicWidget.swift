import AppKit
import SwiftUI
import WidgetKit

struct MusicEntry: TimelineEntry {
    let date: Date
    let snapshot: NowPlayingSnapshot
    let artworkURL: URL?
}

struct MusicProvider: TimelineProvider {
    func placeholder(in context: Context) -> MusicEntry {
        MusicEntry(date: Date(), snapshot: .empty, artworkURL: nil)
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

            let artworkURL = snapshot.hasArtwork
                ? NowPlayingShared.readableArtworkURLs().first(where: {
                    FileManager.default.fileExists(atPath: $0.path)
                })
                : nil
            return MusicEntry(date: Date(), snapshot: snapshot, artworkURL: artworkURL)
        }

        return MusicEntry(date: Date(), snapshot: .empty, artworkURL: nil)
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
        .background(CardBackground(snapshot: entry.snapshot))
        .modifier(WidgetBackground(snapshot: entry.snapshot))
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

    var body: some View {
        ZStack {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
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
    let snapshot: NowPlayingSnapshot

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
            red: min(max(snapshot.backgroundRed * scale, 0), 1),
            green: min(max(snapshot.backgroundGreen * scale, 0), 1),
            blue: min(max(snapshot.backgroundBlue * scale, 0), 1)
        )
    }
}

struct WidgetBackground: ViewModifier {
    let snapshot: NowPlayingSnapshot

    func body(content: Content) -> some View {
        if #available(macOSApplicationExtension 14.0, *) {
            content.containerBackground(for: .widget) {
                CardBackground(snapshot: snapshot)
            }
        } else {
            content.background(CardBackground(snapshot: snapshot))
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
