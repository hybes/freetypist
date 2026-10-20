import Foundation
import Combine

public enum StatsTimeRange: String, CaseIterable, Identifiable, Sendable {
    case last7Days = "Last 7 Days"
    case last14Days = "Last 14 Days"
    case last30Days = "Last 30 Days"
    case last90Days = "Last 90 Days"

    public var id: String { rawValue }

    public var daysCount: Int {
        switch self {
        case .last7Days: return 7
        case .last14Days: return 14
        case .last30Days: return 30
        case .last90Days: return 90
        }
    }
}

public enum StatsMetricType: String, CaseIterable, Identifiable, Sendable {
    case words = "Words"
    case completions = "Completions"
    case characters = "Characters"

    public var id: String { rawValue }
}

public struct DayStatsRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: String { dateString }
    public let dateString: String // yyyy-MM-dd
    public var completionsAccepted: Int
    public var completionsShown: Int
    public var wordsSaved: Int
    public var charactersSaved: Int
    public var avgLatencyMs: Int
    public var cacheHits: Int

    public init(
        dateString: String,
        completionsAccepted: Int = 0,
        completionsShown: Int = 0,
        wordsSaved: Int = 0,
        charactersSaved: Int = 0,
        avgLatencyMs: Int = 0,
        cacheHits: Int = 0
    ) {
        self.dateString = dateString
        self.completionsAccepted = completionsAccepted
        self.completionsShown = completionsShown
        self.wordsSaved = wordsSaved
        self.charactersSaved = charactersSaved
        self.avgLatencyMs = avgLatencyMs
        self.cacheHits = cacheHits
    }
}

public final class StatsManager: ObservableObject, @unchecked Sendable {
    public static let shared = StatsManager()

    @Published public var totalWordsSaved: Int { didSet { save() } }
    @Published public var totalCharactersSaved: Int { didSet { save() } }
    @Published public var totalCompletionsAccepted: Int { didSet { save() } }
    @Published public var totalCompletionsShown: Int { didSet { save() } }
    @Published public var todayCompletionsAccepted: Int { didSet { save() } }
    @Published public var todayWordsSaved: Int { didSet { save() } }
    @Published public var dailyHistory: [DayStatsRecord] = []
    @Published public var appWordsBreakdown: [String: Int] = [:]
    @Published public var sourceBreakdown: [String: Int] = [:]
    @Published public var latencyBuckets: [String: Int] = [
        "<15ms (Instant)": 0,
        "15–50ms (Metal)": 0,
        "50–150ms": 0,
        "150ms+": 0
    ]

    private let userDefaults: UserDefaults
    private var lastDateString: String

    private let statsFileURL: URL

    init(userDefaults: UserDefaults = AppStorage.defaults, statsFileURL: URL? = nil) {
        self.userDefaults = userDefaults
        self.statsFileURL = statsFileURL ?? AppStorage.directory.appendingPathComponent("completionStats.json")
        let todayStr = StatsManager.currentDayString()
        self.lastDateString = userDefaults.string(forKey: "ft_stats_lastDate") ?? todayStr

        self.totalWordsSaved = userDefaults.integer(forKey: "ft_stats_wordsSaved")
        self.totalCharactersSaved = userDefaults.integer(forKey: "ft_stats_charsSaved")
        self.totalCompletionsAccepted = userDefaults.integer(forKey: "ft_stats_completionsAccepted")
        self.totalCompletionsShown = userDefaults.integer(forKey: "ft_stats_completionsShown")

        if lastDateString == todayStr {
            self.todayCompletionsAccepted = userDefaults.integer(forKey: "ft_stats_todayCompletions")
            self.todayWordsSaved = userDefaults.integer(forKey: "ft_stats_todayWords")
        } else {
            self.todayCompletionsAccepted = 0
            self.todayWordsSaved = 0
            self.lastDateString = todayStr
        }

        if let appDict = userDefaults.dictionary(forKey: "ft_stats_appBreakdown") as? [String: Int] {
            self.appWordsBreakdown = appDict
        }
        if let srcDict = userDefaults.dictionary(forKey: "ft_stats_sourceBreakdown") as? [String: Int] {
            self.sourceBreakdown = srcDict
        }
        if let latDict = userDefaults.dictionary(forKey: "ft_stats_latencyBuckets") as? [String: Int] {
            self.latencyBuckets = latDict
        }

        loadDailyHistory()
    }

    public static func currentDayString(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    public func recordShown(latencyMs: Int, fromCache: Bool = false) {
        checkDayRollover()
        totalCompletionsShown += 1

        let bucket: String
        if latencyMs < 15 || fromCache {
            bucket = "<15ms (Instant)"
        } else if latencyMs <= 50 {
            bucket = "15–50ms (Metal)"
        } else if latencyMs <= 150 {
            bucket = "50–150ms"
        } else {
            bucket = "150ms+"
        }
        latencyBuckets[bucket, default: 0] += 1

        let today = Self.currentDayString()
        if let idx = dailyHistory.firstIndex(where: { $0.dateString == today }) {
            let count = dailyHistory[idx].completionsShown
            dailyHistory[idx].avgLatencyMs = (dailyHistory[idx].avgLatencyMs * count + max(0, latencyMs)) / (count + 1)
            dailyHistory[idx].completionsShown += 1
            if fromCache { dailyHistory[idx].cacheHits += 1 }
        } else {
            dailyHistory.append(
                DayStatsRecord(
                    dateString: today,
                    completionsAccepted: 0,
                    completionsShown: 1,
                    wordsSaved: 0,
                    charactersSaved: 0,
                    avgLatencyMs: max(0, latencyMs),
                    cacheHits: fromCache ? 1 : 0
                )
            )
        }
        saveDailyHistory()
        save()
    }

    public func recordAccepted(text: String, appName: String = "App", source: String = "On-Device Engine") {
        checkDayRollover()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let words = text.split { $0.isWhitespace }.count
        let chars = text.count

        totalWordsSaved += words
        totalCharactersSaved += chars
        totalCompletionsAccepted += 1
        todayCompletionsAccepted += 1
        todayWordsSaved += words
        appWordsBreakdown[appName, default: 0] += words
        sourceBreakdown[source, default: 0] += words

        let today = Self.currentDayString()
        if let idx = dailyHistory.firstIndex(where: { $0.dateString == today }) {
            dailyHistory[idx].completionsAccepted += 1
            dailyHistory[idx].wordsSaved += words
            dailyHistory[idx].charactersSaved += chars
        } else {
            dailyHistory.append(
                DayStatsRecord(
                    dateString: today,
                    completionsAccepted: 1,
                    completionsShown: 0,
                    wordsSaved: words,
                    charactersSaved: chars,
                    avgLatencyMs: 0,
                    cacheHits: 0
                )
            )
        }
        saveDailyHistory()
        save()
    }

    /// Always returns a continuous calendar series for the requested range so the bar chart never renders a single stretched bar.
    public func records(for range: StatsTimeRange) -> [DayStatsRecord] {
        let count = range.daysCount
        let cal = Calendar.current
        let now = Date()
        let byDate = Dictionary(dailyHistory.map { ($0.dateString, $0) }, uniquingKeysWith: { _, last in last })

        var result: [DayStatsRecord] = []
        for offset in stride(from: count - 1, through: 0, by: -1) {
            if let date = cal.date(byAdding: .day, value: -offset, to: now) {
                let dStr = Self.currentDayString(for: date)
                if let existing = byDate[dStr] {
                    result.append(existing)
                } else {
                    result.append(DayStatsRecord(dateString: dStr))
                }
            }
        }
        return result
    }

    public var dailyAverageWords: Int {
        let activeDays = dailyHistory.filter { $0.wordsSaved > 0 }
        guard !activeDays.isEmpty else { return todayWordsSaved }
        let sum = activeDays.reduce(0) { $0 + $1.wordsSaved }
        return sum / activeDays.count
    }

    public var currentStreakDays: Int {
        let byDate = Dictionary(dailyHistory.map { ($0.dateString, $0.wordsSaved) }, uniquingKeysWith: max)
        let calendar = Calendar.current
        var day = calendar.startOfDay(for: Date())
        if (byDate[Self.currentDayString(for: day)] ?? 0) == 0 {
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        var streak = 0
        while (byDate[Self.currentDayString(for: day)] ?? 0) > 0 {
            streak += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        return streak
    }

    public var acceptanceRatePercentage: Int {
        guard totalCompletionsShown > 0 else { return 0 }
        return min(100, Int(Double(totalCompletionsAccepted) / Double(totalCompletionsShown) * 100))
    }

    public var estimatedTimeSavedMinutes: Double {
        return Double(totalWordsSaved) / 40.0
    }

    public var estimatedTimeSavedFormatted: String {
        let mins = estimatedTimeSavedMinutes
        if mins < 60 {
            return String(format: "%.1f mins", mins)
        } else {
            let hours = mins / 60.0
            return String(format: "%.1f hours", hours)
        }
    }

    public func exportCSV() -> String {
        var lines = ["Date,WordsSaved,CompletionsAccepted,CompletionsShown,CharactersSaved,AvgLatencyMs,CacheHits"]
        for rec in dailyHistory.sorted(by: { $0.dateString < $1.dateString }) {
            lines.append("\(rec.dateString),\(rec.wordsSaved),\(rec.completionsAccepted),\(rec.completionsShown),\(rec.charactersSaved),\(rec.avgLatencyMs),\(rec.cacheHits)")
        }
        return lines.joined(separator: "\n")
    }

    private func checkDayRollover() {
        let todayStr = StatsManager.currentDayString()
        if lastDateString != todayStr {
            todayCompletionsAccepted = 0
            todayWordsSaved = 0
            lastDateString = todayStr
            userDefaults.set(todayStr, forKey: "ft_stats_lastDate")
            userDefaults.set(0, forKey: "ft_stats_todayCompletions")
            userDefaults.set(0, forKey: "ft_stats_todayWords")
        }
    }

    private func save() {
        userDefaults.set(totalWordsSaved, forKey: "ft_stats_wordsSaved")
        userDefaults.set(totalCharactersSaved, forKey: "ft_stats_charsSaved")
        userDefaults.set(totalCompletionsAccepted, forKey: "ft_stats_completionsAccepted")
        userDefaults.set(totalCompletionsShown, forKey: "ft_stats_completionsShown")
        userDefaults.set(todayCompletionsAccepted, forKey: "ft_stats_todayCompletions")
        userDefaults.set(todayWordsSaved, forKey: "ft_stats_todayWords")
        userDefaults.set(lastDateString, forKey: "ft_stats_lastDate")
        userDefaults.set(appWordsBreakdown, forKey: "ft_stats_appBreakdown")
        userDefaults.set(sourceBreakdown, forKey: "ft_stats_sourceBreakdown")
        userDefaults.set(latencyBuckets, forKey: "ft_stats_latencyBuckets")
    }

    private func loadDailyHistory() {
        guard FileManager.default.fileExists(atPath: statsFileURL.path),
              let data = try? Data(contentsOf: statsFileURL),
              let decoded = try? JSONDecoder().decode([DayStatsRecord].self, from: data) else {
            return
        }
        self.dailyHistory = decoded
    }

    private func saveDailyHistory() {
        let trimmed = Array(dailyHistory.sorted { $0.dateString < $1.dateString }.suffix(90))
        self.dailyHistory = trimmed
        if let data = try? JSONEncoder().encode(trimmed) {
            try? data.write(to: statsFileURL, options: .atomic)
        }
    }

    public func importCotypistStats(
        dailyRecords: [DayStatsRecord],
        appBreakdown: [String: Int] = [:]
    ) -> (daysImported: Int, wordsImported: Int, completionsImported: Int) {
        var byDate = Dictionary(dailyHistory.map { ($0.dateString, $0) }, uniquingKeysWith: { _, last in last })
        var imported = (userDefaults.data(forKey: "ft_cotypistImportedStats").flatMap {
            try? JSONDecoder().decode([String: DayStatsRecord].self, from: $0)
        }) ?? [:]
        var daysAdded = 0
        var wordsAdded = 0
        var compsAdded = 0
        var charsAdded = 0
        var shownAdded = 0

        for rec in dailyRecords {
            let old = imported[rec.dateString] ?? DayStatsRecord(dateString: rec.dateString)
            let words = max(0, rec.wordsSaved - old.wordsSaved)
            let comps = max(0, rec.completionsAccepted - old.completionsAccepted)
            let chars = max(0, rec.charactersSaved - old.charactersSaved)
            let shown = max(0, rec.completionsShown - old.completionsShown)
            guard words > 0 || comps > 0 || chars > 0 || shown > 0 else { continue }
            var day = byDate[rec.dateString] ?? DayStatsRecord(dateString: rec.dateString)
            day.wordsSaved += words
            day.completionsAccepted += comps
            day.charactersSaved += chars
            day.completionsShown += shown
            byDate[rec.dateString] = day
            imported[rec.dateString] = DayStatsRecord(
                dateString: rec.dateString,
                completionsAccepted: max(old.completionsAccepted, rec.completionsAccepted),
                completionsShown: max(old.completionsShown, rec.completionsShown),
                wordsSaved: max(old.wordsSaved, rec.wordsSaved),
                charactersSaved: max(old.charactersSaved, rec.charactersSaved)
            )
            daysAdded += 1
            wordsAdded += words
            compsAdded += comps
            charsAdded += chars
            shownAdded += shown
        }
        for (app, words) in appBreakdown where words > 0 {
            appWordsBreakdown[app] = max(appWordsBreakdown[app] ?? 0, words)
        }
        dailyHistory = byDate.values.sorted { $0.dateString < $1.dateString }
        totalWordsSaved += wordsAdded
        totalCharactersSaved += charsAdded
        totalCompletionsAccepted += compsAdded
        totalCompletionsShown += shownAdded
        if let today = byDate[Self.currentDayString()] {
            todayWordsSaved = today.wordsSaved
            todayCompletionsAccepted = today.completionsAccepted
        }
        sourceBreakdown["Migrated from Cotypist", default: 0] += wordsAdded
        if let data = try? JSONEncoder().encode(imported) {
            userDefaults.set(data, forKey: "ft_cotypistImportedStats")
        }
        saveDailyHistory()
        save()
        return (daysAdded, wordsAdded, compsAdded)
    }

    public func resetStats() {
        totalWordsSaved = 0
        totalCharactersSaved = 0
        totalCompletionsAccepted = 0
        totalCompletionsShown = 0
        todayCompletionsAccepted = 0
        todayWordsSaved = 0
        dailyHistory = []
        appWordsBreakdown = [:]
        sourceBreakdown = [:]
        latencyBuckets = [
            "<15ms (Instant)": 0,
            "15–50ms (Metal)": 0,
            "50–150ms": 0,
            "150ms+": 0
        ]
        userDefaults.removeObject(forKey: "ft_cotypistImportedStats")
        try? FileManager.default.removeItem(at: statsFileURL)
        save()
    }
}
