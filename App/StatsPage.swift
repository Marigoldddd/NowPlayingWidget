import Charts
import SwiftUI

struct StatsPage: View {
    @ObservedObject var model: NowPlayingAppModel
    @State private var selectedRange: StatsTimeRange = .week
    @State private var selectedPlayerFilter: String?
    @State private var hoveredDay: HeatmapDayCell?
    @State private var showClearConfirm = false

    var body: some View {
        let lang = model.appearance.language
        let summary = model.listeningStats(for: selectedRange)
        let heatmap = model.listeningHeatmap(weeks: 26)
        let recent = model.recentPlaybackEntries(
            for: selectedRange,
            sourceBundleID: selectedPlayerFilter,
            limit: 30
        )

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header (clean, no subtitle)
                HStack(alignment: .center, spacing: 12) {
                    Text(L10n.tr("stats.title", language: lang))
                        .font(.largeTitle.bold())

                    Spacer(minLength: 0)

                    Picker(
                        L10n.tr("stats.range.label", language: lang),
                        selection: $selectedRange
                    ) {
                        ForEach(StatsTimeRange.allCases) { range in
                            Text(range.displayName(language: lang)).tag(range)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                }

                // Row 1: 3 KPI Cards + Compact Pie Card
                HStack(spacing: 12) {
                    StatsKPICard(
                        title: L10n.tr("stats.kpi.plays", language: lang),
                        value: L10n.fmt("stats.kpi.plays_value", language: lang, summary.playCount),
                        subtitle: deltaText(summary.previousPeriodDelta, range: selectedRange, language: lang),
                        subtitleColor: (summary.previousPeriodDelta ?? 0) > 0 ? .green : .secondary
                    )

                    StatsKPICard(
                        title: L10n.tr("stats.kpi.duration", language: lang),
                        value: formattedDuration(summary.totalDurationSeconds, language: lang),
                        subtitle: L10n.fmt("stats.kpi.avg_daily_minutes", language: lang, summary.averageDailyMinutes),
                        subtitleColor: .secondary
                    )

                    StatsKPICard(
                        title: L10n.tr("stats.kpi.top_artist", language: lang),
                        value: summary.topArtist?.name ?? "—",
                        subtitle: summary.topArtist.map {
                            L10n.fmt("stats.kpi.top_artist_sub", language: lang, $0.count, $0.sharePercentage)
                        } ?? L10n.tr("stats.empty_short", language: lang),
                        subtitleColor: .secondary
                    )

                    PlayerDistributionCard(
                        items: summary.playerDistribution,
                        language: lang
                    )
                }
                .fixedSize(horizontal: false, vertical: true)

                // Row 2: GitHub-style Contribution Heatmap
                ListeningHeatmapCard(
                    heatmap: heatmap,
                    hoveredDay: $hoveredDay,
                    language: lang
                )

                // Row 3: Top 3 + Recent Cross-Player History
                HStack(alignment: .top, spacing: 12) {
                    TopTracksCard(
                        tracks: summary.topTracks,
                        artworkURLProvider: { model.cachedHistoryArtworkURL(for: $0) },
                        language: lang
                    )
                    .frame(maxWidth: 270)

                    RecentHistoryCard(
                        entries: recent,
                        selectedPlayerFilter: $selectedPlayerFilter,
                        artworkURLProvider: { model.cachedHistoryArtworkURL(for: $0) },
                        hasAnyHistory: model.hasListeningHistory,
                        onRequestClear: { showClearConfirm = true },
                        language: lang
                    )
                }
            }
        }
        .confirmationDialog(
            L10n.tr("stats.clear.confirm_title", language: lang),
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.tr("stats.clear.confirm_action", language: lang), role: .destructive) {
                model.clearListeningHistory()
            }
            Button(L10n.tr("stats.clear.cancel", language: lang), role: .cancel) {}
        } message: {
            Text(L10n.tr("stats.clear.confirm_message", language: lang))
        }
    }

    private func deltaText(_ delta: Int?, range: StatsTimeRange, language: AppLanguage) -> String {
        guard let delta else {
            return L10n.tr("stats.kpi.all_time_sub", language: language)
        }
        let prefix = delta >= 0 ? "+\(delta)" : "\(delta)"
        switch range {
        case .today: return L10n.fmt("stats.kpi.delta_today", language: language, prefix)
        case .week: return L10n.fmt("stats.kpi.delta_week", language: language, prefix)
        case .month: return L10n.fmt("stats.kpi.delta_month", language: language, prefix)
        case .all: return L10n.tr("stats.kpi.all_time_sub", language: language)
        }
    }

    private func formattedDuration(_ seconds: TimeInterval, language: AppLanguage) -> String {
        let totalMinutes = Int((seconds / 60.0).rounded())
        if totalMinutes < 60 {
            return L10n.fmt("stats.duration.minutes", language: language, totalMinutes)
        }
        let hours = seconds / 3600.0
        return L10n.fmt("stats.duration.hours", language: language, String(format: "%.1f", hours))
    }
}

private struct StatsKPICard: View {
    let title: String
    let value: String
    let subtitle: String
    let subtitleColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.title2.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(subtitleColor)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct PlayerDistributionCard: View {
    let items: [PlayerDistributionItem]
    let language: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr("stats.kpi.players", language: language))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            if items.isEmpty {
                Spacer(minLength: 0)
                Text(L10n.tr("stats.empty_short", language: language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                HStack(spacing: 10) {
                    Chart(items) { item in
                        SectorMark(
                            angle: .value("Count", max(1, item.count)),
                            innerRadius: .ratio(0.58),
                            angularInset: 1.5
                        )
                        .foregroundStyle(PlayerVisualStyle.color(for: item.bundleID))
                        .cornerRadius(3)
                    }
                    .frame(width: 48, height: 48)
                    .chartLegend(.hidden)

                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(items.prefix(3)) { item in
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(PlayerVisualStyle.color(for: item.bundleID))
                                    .frame(width: 6, height: 6)
                                Text(PlayerVisualStyle.shortName(for: item.bundleID, language: language))
                                    .font(.caption2)
                                    .lineLimit(1)
                                Spacer(minLength: 2)
                                Text("\(item.percentage)%")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct ListeningHeatmapCard: View {
    let heatmap: ListeningHeatmapData
    @Binding var hoveredDay: HeatmapDayCell?
    let language: AppLanguage

    private let cellSize: CGFloat = 12
    private let cellSpacing: CGFloat = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Text(L10n.tr("stats.heatmap.title", language: language))
                    .font(.headline)

                Text(hoverStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Text(
                    L10n.fmt(
                        "stats.heatmap.streak_summary",
                        language: language,
                        heatmap.currentStreakDays,
                        heatmap.activeDaysCount
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.6), in: Capsule())
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 6) {
                    // Weekday labels (Mon / Wed / Fri / Sun)
                    VStack(alignment: .trailing, spacing: cellSpacing) {
                        Color.clear.frame(height: 14)
                        ForEach(0..<7, id: \.self) { row in
                            Text(weekdayLabel(row))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .frame(height: cellSize)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        // Month labels aligned with week columns
                        ZStack(alignment: .leading) {
                            Color.clear.frame(
                                width: CGFloat(max(1, heatmap.columns.count)) * (cellSize + cellSpacing) - cellSpacing,
                                height: 14
                            )
                            ForEach(heatmap.monthLabels) { item in
                                Text(item.label)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .offset(x: CGFloat(item.columnIndex) * (cellSize + cellSpacing))
                            }
                        }

                        HStack(alignment: .top, spacing: cellSpacing) {
                            ForEach(Array(heatmap.columns.enumerated()), id: \.offset) { _, column in
                                VStack(spacing: cellSpacing) {
                                    ForEach(0..<7, id: \.self) { row in
                                        if row < column.count, let cell = column[row] {
                                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                                .fill(cellColor(for: cell.level))
                                                .frame(width: cellSize, height: cellSize)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                                        .stroke(
                                                            hoveredDay?.id == cell.id ? Color.primary.opacity(0.45) : Color.clear,
                                                            lineWidth: 1
                                                        )
                                                )
                                                .onHover { isHovering in
                                                    if isHovering {
                                                        hoveredDay = cell
                                                    } else if hoveredDay?.id == cell.id {
                                                        hoveredDay = nil
                                                    }
                                                }
                                        } else {
                                            Color.clear.frame(width: cellSize, height: cellSize)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            HStack(spacing: 5) {
                Spacer(minLength: 0)
                Text(L10n.tr("stats.heatmap.less", language: language))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(cellColor(for: level))
                        .frame(width: 10, height: 10)
                }
                Text(L10n.tr("stats.heatmap.more", language: language))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var hoverStatusText: String {
        guard let day = hoveredDay else {
            return L10n.tr("stats.heatmap.hover_hint", language: language)
        }
        let formatter = DateFormatter()
        formatter.locale = L10n.locale(for: language)
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let dateText = formatter.string(from: day.date)
        let mins = Int((day.durationSeconds / 60.0).rounded())
        if day.playCount == 0 && mins == 0 {
            return L10n.fmt("stats.heatmap.hover_empty", language: language, dateText)
        }
        return L10n.fmt("stats.heatmap.hover_detail", language: language, dateText, day.playCount, mins)
    }

    private func weekdayLabel(_ row: Int) -> String {
        let isZH = L10n.resolvedLanguageCode(for: language) == "zh-Hans"
        switch row {
        case 0: return isZH ? "一" : "Mon"
        case 2: return isZH ? "三" : "Wed"
        case 4: return isZH ? "五" : "Fri"
        case 6: return isZH ? "日" : "Sun"
        default: return ""
        }
    }

    private func cellColor(for level: Int) -> Color {
        switch level {
        case 1: return Color(red: 0.608, green: 0.914, blue: 0.659)
        case 2: return Color(red: 0.251, green: 0.769, blue: 0.388)
        case 3: return Color(red: 0.188, green: 0.631, blue: 0.306)
        case 4: return Color(red: 0.129, green: 0.431, blue: 0.224)
        default: return Color.primary.opacity(0.08)
        }
    }
}

private struct TopTracksCard: View {
    let tracks: [TopTrackItem]
    let artworkURLProvider: (String?) -> URL?
    let language: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("stats.top_tracks.title", language: language))
                .font(.headline)

            if tracks.isEmpty {
                Text(L10n.tr("stats.empty_tracks", language: language))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 110, alignment: .center)
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        HStack(spacing: 10) {
                            HistoryArtworkThumb(
                                url: artworkURLProvider(track.artworkHash),
                                size: 38,
                                rankFallback: index + 1
                            )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title)
                                    .font(.callout.weight(.semibold))
                                    .lineLimit(1)
                                Text(track.artist)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 0)

                            Text(L10n.fmt("stats.play_count_badge", language: language, track.count))
                                .font(.caption.monospacedDigit())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.quaternary.opacity(0.7), in: Capsule())
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct RecentHistoryCard: View {
    let entries: [PlaybackHistoryEntry]
    @Binding var selectedPlayerFilter: String?
    let artworkURLProvider: (String?) -> URL?
    let hasAnyHistory: Bool
    let onRequestClear: () -> Void
    let language: AppLanguage

    private let filterOrder = [
        "com.netease.163music",
        "com.tencent.QQMusicMac",
        "com.apple.Music",
        "com.spotify.client",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                Text(L10n.tr("stats.recent.title", language: language))
                    .font(.headline)

                Spacer(minLength: 0)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        filterPill(title: L10n.tr("stats.filter.all", language: language), bundleID: nil)
                        ForEach(filterOrder, id: \.self) { bundleID in
                            filterPill(
                                title: PlayerVisualStyle.shortName(for: bundleID, language: language),
                                bundleID: bundleID
                            )
                        }
                    }
                }

                if hasAnyHistory {
                    Button(L10n.tr("stats.clear.button", language: language)) {
                        onRequestClear()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if entries.isEmpty {
                Text(L10n.tr("stats.empty_history", language: language))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 110, alignment: .center)
            } else {
                VStack(spacing: 10) {
                    ForEach(entries.prefix(12)) { entry in
                        HStack(spacing: 10) {
                            HistoryArtworkThumb(
                                url: artworkURLProvider(entry.artworkHash),
                                size: 36,
                                rankFallback: nil
                            )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                Text(entry.artist)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 0)

                            Text(NowPlayingSource.displayName(for: entry.sourceBundleID, language: language) ?? entry.sourceBundleID)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(PlayerVisualStyle.color(for: entry.sourceBundleID), in: Capsule())

                            Text(relativeTimeText(entry.startedAt))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 56, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func filterPill(title: String, bundleID: String?) -> some View {
        let isSelected = selectedPlayerFilter == bundleID
        return Button {
            selectedPlayerFilter = bundleID
        } label: {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(
                    isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary.opacity(0.6)),
                    in: Capsule()
                )
                .foregroundStyle(isSelected ? .white : .secondary)
        }
        .buttonStyle(.plain)
    }

    private func relativeTimeText(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.locale = L10n.locale(for: language)
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct HistoryArtworkThumb: View {
    let url: URL?
    let size: CGFloat
    let rankFallback: Int?

    var body: some View {
        Group {
            if let url, let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.75), Color.purple.opacity(0.65)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    if let rankFallback {
                        Text("\(rankFallback)")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                    } else {
                        Image(systemName: "music.note")
                            .font(.caption)
                            .foregroundStyle(.white)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private enum PlayerVisualStyle {
    static func color(for bundleID: String) -> Color {
        switch bundleID {
        case "com.netease.163music":
            return Color(red: 0.90, green: 0.17, blue: 0.17)
        case "com.tencent.QQMusicMac":
            return Color(red: 0.07, green: 0.72, blue: 0.42)
        case "com.apple.Music":
            return Color(red: 0.98, green: 0.24, blue: 0.32)
        case "com.spotify.client":
            return Color(red: 0.11, green: 0.73, blue: 0.33)
        default:
            return .accentColor
        }
    }

    static func shortName(for bundleID: String, language: AppLanguage) -> String {
        let isZH = L10n.resolvedLanguageCode(for: language) == "zh-Hans"
        switch bundleID {
        case "com.netease.163music": return isZH ? "网易云" : "NetEase"
        case "com.tencent.QQMusicMac": return isZH ? "QQ音乐" : "QQ Music"
        case "com.apple.Music": return "Apple"
        case "com.spotify.client": return "Spotify"
        default: return bundleID
        }
    }
}
