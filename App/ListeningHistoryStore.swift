import AppKit
import CryptoKit
import Foundation

enum StatsTimeRange: String, CaseIterable, Identifiable {
    case today
    case week
    case month
    case all

    var id: String { rawValue }

    func displayName(language: AppLanguage? = nil) -> String {
        switch self {
        case .today: return L10n.tr("stats.range.today", language: language)
        case .week: return L10n.tr("stats.range.week", language: language)
        case .month: return L10n.tr("stats.range.month", language: language)
        case .all: return L10n.tr("stats.range.all", language: language)
        }
    }
}

struct PlaybackHistoryEntry: Codable, Equatable, Identifiable {
    let id: UUID
    var title: String
    var artist: String
    var album: String
    var sourceBundleID: String
    var startedAt: Date
    var lastUpdatedAt: Date
    var durationSeconds: TimeInterval
    var artworkHash: String?
}

struct DailyListeningBucket: Codable, Equatable {
    var dayKey: String
    var playCount: Int
    var durationSeconds: TimeInterval
}

struct ListeningHistoryDatabase: Codable, Equatable {
    var entries: [PlaybackHistoryEntry]
    var dailyBuckets: [String: DailyListeningBucket]

    static let empty = ListeningHistoryDatabase(entries: [], dailyBuckets: [:])
}

struct PlayerDistributionItem: Identifiable, Equatable {
    let bundleID: String
    let name: String
    let count: Int
    let percentage: Int

    var id: String { bundleID }
}

struct TopTrackItem: Identifiable, Equatable {
    let trackKey: String
    let title: String
    let artist: String
    let count: Int
    let artworkHash: String?

    var id: String { trackKey }
}

struct TopArtistItem: Equatable {
    let name: String
    let count: Int
    let sharePercentage: Int
}

struct ListeningStatsSummary: Equatable {
    let playCount: Int
    let previousPeriodDelta: Int?
    let totalDurationSeconds: TimeInterval
    let averageDailyMinutes: Int
    let topArtist: TopArtistItem?
    let playerDistribution: [PlayerDistributionItem]
    let topTracks: [TopTrackItem]
}

struct HeatmapDayCell: Identifiable, Equatable {
    let dayKey: String
    let date: Date
    let playCount: Int
    let durationSeconds: TimeInterval
    let level: Int

    var id: String { dayKey }
}

struct HeatmapMonthLabel: Identifiable, Equatable {
    let columnIndex: Int
    let label: String

    var id: String { "\(columnIndex)-\(label)" }
}

struct ListeningHeatmapData: Equatable {
    let columns: [[HeatmapDayCell?]]
    let monthLabels: [HeatmapMonthLabel]
    let currentStreakDays: Int
    let activeDaysCount: Int
}

final class ListeningHistoryStore {
    private struct ActiveSession {
        let trackKey: String
        let title: String
        let artist: String
        let album: String
        let sourceBundleID: String
        let startedAt: Date
        var lastTickAt: Date?
        var accumulatedSeconds: TimeInterval
        var committedEntryID: UUID?
        var artworkHash: String?
    }

    private let directoryURL: URL
    private let historyFileURL: URL
    private let artworkCacheDirectoryURL: URL
    private let commitThresholdSeconds: TimeInterval
    private let maxTickDeltaSeconds: TimeInterval = 30
    private let maxStoredEntries = 2000
    private let flushIntervalSeconds: TimeInterval = 15

    private(set) var database: ListeningHistoryDatabase
    private var activeSession: ActiveSession?
    private var isDirty = false
    private var lastSavedAt: Date = .distantPast
    private let calendar: Calendar

    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    init(
        directoryURL: URL = NowPlayingShared.widgetSupportURL(),
        commitThresholdSeconds: TimeInterval = 10,
        calendar: Calendar = .current
    ) {
        self.directoryURL = directoryURL
        self.historyFileURL = directoryURL.appendingPathComponent("history.json")
        self.artworkCacheDirectoryURL = directoryURL.appendingPathComponent("artwork-cache", isDirectory: true)
        self.commitThresholdSeconds = commitThresholdSeconds
        var cal = calendar
        cal.firstWeekday = 2 // Monday
        self.calendar = cal
        self.database = Self.loadDatabase(from: historyFileURL)
    }

    @discardableResult
    func record(
        snapshot: NowPlayingSnapshot,
        artworkURL: URL?,
        at now: Date = Date()
    ) -> Bool {
        let isValidTrack = !snapshot.sourceBundleID.isEmpty
            && !snapshot.title.isEmpty
            && snapshot.title != "未知歌曲"
            && snapshot.title != "Unknown Song"

        guard isValidTrack else {
            activeSession?.lastTickAt = nil
            return false
        }

        let trackKey = Self.makeTrackKey(
            title: snapshot.title,
            artist: snapshot.artist,
            sourceBundleID: snapshot.sourceBundleID
        )

        if !snapshot.isPlaying {
            if var current = activeSession, current.trackKey == trackKey {
                current.lastTickAt = nil
                activeSession = current
            } else {
                activeSession?.lastTickAt = nil
            }
            return false
        }

        var didCommitOrChange = false

        if var current = activeSession, current.trackKey == trackKey {
            if let lastTick = current.lastTickAt {
                let rawDelta = now.timeIntervalSince(lastTick)
                let delta = min(max(0, rawDelta), maxTickDeltaSeconds)
                if delta > 0 {
                    current.accumulatedSeconds += delta
                    addDuration(delta, on: now)
                    if let entryID = current.committedEntryID,
                       let index = database.entries.firstIndex(where: { $0.id == entryID }) {
                        database.entries[index].durationSeconds += delta
                        database.entries[index].lastUpdatedAt = now
                    }
                    isDirty = true
                }
            }
            current.lastTickAt = now
            if current.artworkHash == nil, let artworkURL {
                current.artworkHash = cacheArtworkIfNeeded(from: artworkURL, trackKey: trackKey)
                if let entryID = current.committedEntryID,
                   let hash = current.artworkHash,
                   let index = database.entries.firstIndex(where: { $0.id == entryID }) {
                    database.entries[index].artworkHash = hash
                }
            }

            if current.committedEntryID == nil, current.accumulatedSeconds >= commitThresholdSeconds {
                let entryID = commitSession(&current, at: now)
                current.committedEntryID = entryID
                didCommitOrChange = true
            }
            activeSession = current
        } else {
            let artworkHash = artworkURL.flatMap { cacheArtworkIfNeeded(from: $0, trackKey: trackKey) }
            var next = ActiveSession(
                trackKey: trackKey,
                title: snapshot.title,
                artist: snapshot.artist,
                album: snapshot.album,
                sourceBundleID: snapshot.sourceBundleID,
                startedAt: now,
                lastTickAt: now,
                accumulatedSeconds: 0,
                committedEntryID: nil,
                artworkHash: artworkHash
            )
            if commitThresholdSeconds <= 0 {
                next.committedEntryID = commitSession(&next, at: now)
                didCommitOrChange = true
            }
            activeSession = next
        }

        flushIfNeeded(force: didCommitOrChange, at: now)
        return didCommitOrChange
    }

    func flushIfNeeded(force: Bool = false, at now: Date = Date()) {
        guard isDirty else { return }
        if !force, now.timeIntervalSince(lastSavedAt) < flushIntervalSeconds {
            return
        }
        saveDatabase(at: now)
    }

    func clearHistory() {
        database = .empty
        activeSession = nil
        isDirty = true
        saveDatabase(at: Date())
        try? FileManager.default.removeItem(at: artworkCacheDirectoryURL)
    }

    func artworkURL(for hash: String?) -> URL? {
        guard let hash, !hash.isEmpty else { return nil }
        let url = artworkCacheDirectoryURL.appendingPathComponent("\(hash).jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func recentEntries(
        for range: StatsTimeRange,
        sourceBundleID: String? = nil,
        limit: Int = 50,
        now: Date = Date()
    ) -> [PlaybackHistoryEntry] {
        let filtered = entries(in: range, now: now).filter { entry in
            guard let sourceBundleID else { return true }
            return entry.sourceBundleID == sourceBundleID
        }
        return Array(filtered.prefix(limit))
    }

    func stats(
        for range: StatsTimeRange,
        now: Date = Date(),
        language: AppLanguage? = nil
    ) -> ListeningStatsSummary {
        let currentEntries = entries(in: range, now: now)
        let playCount = currentEntries.count
        let delta = previousPeriodDelta(for: range, currentCount: playCount, now: now)

        let totalDuration = durationSum(for: range, entries: currentEntries, now: now)
        let activeDays = max(1, activeDaySpan(for: range, entries: currentEntries, now: now))
        let avgMinutes = Int((totalDuration / 60.0 / Double(activeDays)).rounded())

        // Top Artist
        var artistCounts: [String: Int] = [:]
        for entry in currentEntries {
            let cleanArtist = entry.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanArtist.isEmpty,
                  cleanArtist != "未知歌手",
                  cleanArtist != "Unknown Artist" else { continue }
            artistCounts[cleanArtist, default: 0] += 1
        }
        let topArtist: TopArtistItem? = artistCounts
            .max { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                return lhs.key > rhs.key
            }
            .map { pair in
                let share = playCount > 0 ? Int((Double(pair.value) / Double(playCount) * 100.0).rounded()) : 0
                return TopArtistItem(name: pair.key, count: pair.value, sharePercentage: share)
            }

        // Player Distribution
        var sourceCounts: [String: Int] = [:]
        for entry in currentEntries {
            sourceCounts[entry.sourceBundleID, default: 0] += 1
        }
        let distribution: [PlayerDistributionItem] = sourceCounts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .map { bundleID, count in
                let name = NowPlayingSource.displayName(for: bundleID, language: language) ?? bundleID
                let pct = playCount > 0 ? Int((Double(count) / Double(playCount) * 100.0).rounded()) : 0
                return PlayerDistributionItem(
                    bundleID: bundleID,
                    name: name,
                    count: count,
                    percentage: pct
                )
            }

        // Top 3 Tracks
        var trackBuckets: [String: (title: String, artist: String, count: Int, artworkHash: String?)] = [:]
        for entry in currentEntries {
            let key = "\(entry.title.lowercased())|\(entry.artist.lowercased())"
            if var existing = trackBuckets[key] {
                existing.count += 1
                if existing.artworkHash == nil {
                    existing.artworkHash = entry.artworkHash
                }
                trackBuckets[key] = existing
            } else {
                trackBuckets[key] = (entry.title, entry.artist, 1, entry.artworkHash)
            }
        }
        let topTracks = trackBuckets
            .sorted { lhs, rhs in
                if lhs.value.count != rhs.value.count { return lhs.value.count > rhs.value.count }
                return lhs.value.title < rhs.value.title
            }
            .prefix(3)
            .map { key, value in
                TopTrackItem(
                    trackKey: key,
                    title: value.title,
                    artist: value.artist,
                    count: value.count,
                    artworkHash: value.artworkHash
                )
            }

        return ListeningStatsSummary(
            playCount: playCount,
            previousPeriodDelta: delta,
            totalDurationSeconds: totalDuration,
            averageDailyMinutes: avgMinutes,
            topArtist: topArtist,
            playerDistribution: distribution,
            topTracks: topTracks
        )
    }

    func heatmap(
        weeks: Int = 26,
        now: Date = Date(),
        language: AppLanguage? = nil
    ) -> ListeningHeatmapData {
        let today = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: today) // 1=Sun, 2=Mon..7=Sat
        let mondayOffset = (weekday + 5) % 7 // 0 for Mon, 6 for Sun
        guard let currentWeekMonday = calendar.date(byAdding: .day, value: -mondayOffset, to: today),
              let firstMonday = calendar.date(byAdding: .day, value: -(weeks - 1) * 7, to: currentWeekMonday) else {
            return ListeningHeatmapData(columns: [], monthLabels: [], currentStreakDays: 0, activeDaysCount: 0)
        }

        var rawDays: [(date: Date, bucket: DailyListeningBucket?)] = []
        var maxPlays = 0
        var activeDays = 0

        for col in 0..<weeks {
            for row in 0..<7 {
                guard let date = calendar.date(byAdding: .day, value: col * 7 + row, to: firstMonday) else { continue }
                if date > today {
                    rawDays.append((date, nil))
                    continue
                }
                let key = Self.dayKeyFormatter.string(from: date)
                let bucket = database.dailyBuckets[key]
                let count = bucket?.playCount ?? 0
                if count > 0 || (bucket?.durationSeconds ?? 0) >= 30 {
                    activeDays += 1
                }
                if count > maxPlays {
                    maxPlays = count
                }
                rawDays.append((date, bucket))
            }
        }

        var columns: [[HeatmapDayCell?]] = []
        var monthLabels: [HeatmapMonthLabel] = []
        var lastMonth = -1
        let monthFormatter = DateFormatter()
        monthFormatter.locale = L10n.locale(for: language)
        monthFormatter.dateFormat = L10n.resolvedLanguageCode(for: language) == "zh-Hans" ? "M月" : "MMM"

        for col in 0..<weeks {
            var columnCells: [HeatmapDayCell?] = []
            for row in 0..<7 {
                let idx = col * 7 + row
                guard idx < rawDays.count else {
                    columnCells.append(nil)
                    continue
                }
                let item = rawDays[idx]
                if item.date > today {
                    columnCells.append(nil)
                    continue
                }
                if row == 0 {
                    let month = calendar.component(.month, from: item.date)
                    if month != lastMonth {
                        monthLabels.append(HeatmapMonthLabel(columnIndex: col, label: monthFormatter.string(from: item.date)))
                        lastMonth = month
                    }
                }
                let key = Self.dayKeyFormatter.string(from: item.date)
                let count = item.bucket?.playCount ?? 0
                let duration = item.bucket?.durationSeconds ?? 0
                let level = Self.intensityLevel(playCount: count, duration: duration, maxPlays: maxPlays)
                columnCells.append(
                    HeatmapDayCell(
                        dayKey: key,
                        date: item.date,
                        playCount: count,
                        durationSeconds: duration,
                        level: level
                    )
                )
            }
            columns.append(columnCells)
        }

        let streak = computeCurrentStreak(today: today)
        return ListeningHeatmapData(
            columns: columns,
            monthLabels: monthLabels,
            currentStreakDays: streak,
            activeDaysCount: activeDays
        )
    }

    // MARK: - Helpers

    private func commitSession(_ session: inout ActiveSession, at now: Date) -> UUID {
        let entry = PlaybackHistoryEntry(
            id: UUID(),
            title: session.title,
            artist: session.artist,
            album: session.album,
            sourceBundleID: session.sourceBundleID,
            startedAt: session.startedAt,
            lastUpdatedAt: now,
            durationSeconds: session.accumulatedSeconds,
            artworkHash: session.artworkHash
        )
        database.entries.insert(entry, at: 0)
        if database.entries.count > maxStoredEntries {
            database.entries.removeLast(database.entries.count - maxStoredEntries)
        }

        let dayKey = Self.dayKeyFormatter.string(from: now)
        var bucket = database.dailyBuckets[dayKey] ?? DailyListeningBucket(dayKey: dayKey, playCount: 0, durationSeconds: 0)
        bucket.playCount += 1
        database.dailyBuckets[dayKey] = bucket
        isDirty = true
        return entry.id
    }

    private func addDuration(_ seconds: TimeInterval, on date: Date) {
        let dayKey = Self.dayKeyFormatter.string(from: date)
        var bucket = database.dailyBuckets[dayKey] ?? DailyListeningBucket(dayKey: dayKey, playCount: 0, durationSeconds: 0)
        bucket.durationSeconds += seconds
        database.dailyBuckets[dayKey] = bucket
    }

    private func entries(in range: StatsTimeRange, now: Date) -> [PlaybackHistoryEntry] {
        guard let start = periodStartDate(for: range, now: now) else {
            return database.entries
        }
        return database.entries.filter { $0.startedAt >= start }
    }

    private func periodStartDate(for range: StatsTimeRange, now: Date) -> Date? {
        switch range {
        case .today:
            return calendar.startOfDay(for: now)
        case .week:
            let today = calendar.startOfDay(for: now)
            return calendar.date(byAdding: .day, value: -6, to: today)
        case .month:
            let today = calendar.startOfDay(for: now)
            return calendar.date(byAdding: .day, value: -29, to: today)
        case .all:
            return nil
        }
    }

    private func previousPeriodDelta(for range: StatsTimeRange, currentCount: Int, now: Date) -> Int? {
        let today = calendar.startOfDay(for: now)
        let prevStart: Date?
        let prevEnd: Date?

        switch range {
        case .today:
            prevStart = calendar.date(byAdding: .day, value: -1, to: today)
            prevEnd = today
        case .week:
            prevStart = calendar.date(byAdding: .day, value: -13, to: today)
            prevEnd = calendar.date(byAdding: .day, value: -6, to: today)
        case .month:
            prevStart = calendar.date(byAdding: .day, value: -59, to: today)
            prevEnd = calendar.date(byAdding: .day, value: -29, to: today)
        case .all:
            return nil
        }

        guard let start = prevStart, let end = prevEnd else { return nil }
        let prevCount = database.entries.filter { $0.startedAt >= start && $0.startedAt < end }.count
        return currentCount - prevCount
    }

    private func durationSum(for range: StatsTimeRange, entries: [PlaybackHistoryEntry], now: Date) -> TimeInterval {
        guard let start = periodStartDate(for: range, now: now) else {
            let bucketSum = database.dailyBuckets.values.reduce(0) { $0 + $1.durationSeconds }
            return bucketSum > 0 ? bucketSum : entries.reduce(0) { $0 + $1.durationSeconds }
        }
        let startKey = Self.dayKeyFormatter.string(from: start)
        let bucketSum = database.dailyBuckets.values
            .filter { $0.dayKey >= startKey }
            .reduce(0) { $0 + $1.durationSeconds }
        return bucketSum > 0 ? bucketSum : entries.reduce(0) { $0 + $1.durationSeconds }
    }

    private func activeDaySpan(for range: StatsTimeRange, entries: [PlaybackHistoryEntry], now: Date) -> Int {
        switch range {
        case .today: return 1
        case .week: return 7
        case .month: return 30
        case .all:
            let keys = Set(database.dailyBuckets.keys)
            return max(1, keys.count)
        }
    }

    private func computeCurrentStreak(today: Date) -> Int {
        var streak = 0
        var checkDate = today

        // If today has no plays yet, allow streak to continue from yesterday.
        let todayKey = Self.dayKeyFormatter.string(from: today)
        let todayBucket = database.dailyBuckets[todayKey]
        if (todayBucket?.playCount ?? 0) == 0 && (todayBucket?.durationSeconds ?? 0) < 30 {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else {
                return 0
            }
            checkDate = yesterday
        }

        while true {
            let key = Self.dayKeyFormatter.string(from: checkDate)
            let bucket = database.dailyBuckets[key]
            guard (bucket?.playCount ?? 0) > 0 || (bucket?.durationSeconds ?? 0) >= 30 else {
                break
            }
            streak += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: checkDate) else { break }
            checkDate = prev
        }
        return streak
    }

    private static func intensityLevel(playCount: Int, duration: TimeInterval, maxPlays: Int) -> Int {
        if playCount == 0 && duration < 30 { return 0 }
        if maxPlays <= 4 {
            return min(4, max(1, playCount))
        }
        let ratio = Double(playCount) / Double(maxPlays)
        if ratio <= 0.25 { return 1 }
        if ratio <= 0.50 { return 2 }
        if ratio <= 0.75 { return 3 }
        return 4
    }

    private static func makeTrackKey(title: String, artist: String, sourceBundleID: String) -> String {
        "\(sourceBundleID)|\(title.lowercased())|\(artist.lowercased())"
    }

    private func cacheArtworkIfNeeded(from sourceURL: URL, trackKey: String) -> String? {
        let digest = SHA256.hash(data: Data(trackKey.utf8))
        let hash = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        let destination = artworkCacheDirectoryURL.appendingPathComponent("\(hash).jpg")
        if FileManager.default.fileExists(atPath: destination.path) {
            return hash
        }
        guard let image = NSImage(contentsOf: sourceURL),
              let jpegData = Self.thumbnailJPEGData(from: image, size: 96) else {
            return nil
        }
        do {
            try FileManager.default.createDirectory(at: artworkCacheDirectoryURL, withIntermediateDirectories: true)
            try jpegData.write(to: destination, options: .atomic)
            return hash
        } catch {
            return nil
        }
    }

    private static func thumbnailJPEGData(from image: NSImage, size: CGFloat) -> Data? {
        let targetSize = NSSize(width: size, height: size)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size),
            pixelsHigh: Int(size),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: targetSize), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }

    private static func loadDatabase(from url: URL) -> ListeningHistoryDatabase {
        guard let data = try? Data(contentsOf: url) else {
            return .empty
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ListeningHistoryDatabase.self, from: data)) ?? .empty
    }

    private func saveDatabase(at now: Date) {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(database)
            try data.write(to: historyFileURL, options: .atomic)
            isDirty = false
            lastSavedAt = now
        } catch {
            // Non-fatal: history persistence shouldn't disrupt widget sync.
        }
    }
}
