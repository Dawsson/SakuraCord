import Foundation
import SakuraCordModels

/// Synced slash-command usage, scored exactly as Discord's client scores it so
/// Frequently Used and search ordering match the official app.
///
/// The synced history comes from Discord's frecency settings; uses recorded
/// here stay pending until saved and are replayed over every newer history,
/// as Discord's `ApplicationCommandFrecencyStore` does.
@MainActor
final class ApplicationCommandFrecencyStore {
    struct PendingUsage: Codable, Hashable {
        var key: String
        var timestamp: UInt64
    }

    private struct Entry {
        var totalUses: Int
        var recentUses: [UInt64]
        /// -1 marks a value to recompute.
        var frecency: Double
        var score: Double
    }

    static let maximumSamples = 10
    static let frequentlyLimit = 100

    private var keys: [String] = []
    private var entries: [String: Entry] = [:]
    private var isDirty = false
    private var cachedFrequently: [String] = []
    private(set) var pendingUsages: [PendingUsage] = []
    /// Increments whenever scores may have changed.
    private(set) var revision = 0
    private(set) var hasLoadedRemoteHistory = false
    private var defaultsKey: String?
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    // MARK: Scope

    /// Pending uses survive relaunches per account, as Discord persists them.
    func configure(scope: String) {
        let safeScope = scope.replacingOccurrences(
            of: #"[^A-Za-z0-9_.-]"#, with: "-", options: .regularExpression
        )
        defaultsKey = "dev.sakuracord.command-frecency-pending.\(safeScope)"
        keys = []
        entries = [:]
        hasLoadedRemoteHistory = false
        pendingUsages = defaultsKey
            .flatMap { UserDefaults.standard.data(forKey: $0) }
            .flatMap { try? JSONDecoder().decode([PendingUsage].self, from: $0) } ?? []
        for usage in pendingUsages {
            track(usage.key, timestamp: usage.timestamp)
        }
        markDirty()
    }

    // MARK: History

    /// Replaces the synced history, then replays uses not yet saved.
    func overwrite(with history: ApplicationCommandFrecencyHistory) {
        keys = []
        entries = [:]
        for entry in history.entries {
            if entries[entry.key] == nil { keys.append(entry.key) }
            entries[entry.key] = Entry(
                totalUses: entry.totalUses,
                recentUses: entry.recentUses.filter { $0 > 0 },
                frecency: -1,
                score: Double(entry.score)
            )
        }
        for usage in pendingUsages {
            track(usage.key, timestamp: usage.timestamp)
        }
        hasLoadedRemoteHistory = true
        markDirty()
    }

    /// Records one use now, kept pending until a save succeeds.
    func recordUse(_ key: String) {
        let timestamp = UInt64(now().timeIntervalSince1970 * 1_000)
        pendingUsages.append(PendingUsage(key: key, timestamp: timestamp))
        persistPending()
        track(key, timestamp: nil, at: timestamp)
        compute()
    }

    /// A save acknowledges exactly its captured prefix; newer uses stay pending.
    func acknowledge(_ saved: [PendingUsage]) {
        guard pendingUsages.starts(with: saved) else { return }
        pendingUsages.removeFirst(saved.count)
        persistPending()
    }

    var hasPendingUsage: Bool { !pendingUsages.isEmpty }

    // MARK: Scores

    /// Discord's per-command score: 0.01 per weighted recent use. Picker sorts
    /// and Frequently Used order rely on this value, not on frecency.
    func score(for key: String) -> Double {
        if isDirty { compute() }
        return entries[key]?.score ?? 0
    }

    /// Up to 100 keys by descending frecency, ties in stored order.
    var frequently: [String] {
        if isDirty { compute() }
        return cachedFrequently
    }

    /// The history Discord's client would save: entries in stored order with
    /// their current frecency and rounded score.
    func historyForSave() -> ApplicationCommandFrecencyHistory {
        if isDirty { compute() }
        return ApplicationCommandFrecencyHistory(entries: keys.compactMap { key in
            guard let entry = entries[key] else { return nil }
            return ApplicationCommandFrecencyEntry(
                key: key,
                totalUses: entry.totalUses,
                recentUses: entry.recentUses,
                frecency: Int32(clamping: Int64(entry.frecency)),
                score: Int32(clamping: Int64((entry.score + 0.5).rounded(.down)))
            )
        })
    }

    // MARK: Discord's frecency computation

    private func track(_ key: String, timestamp: UInt64?, at fallback: UInt64? = nil) {
        if var entry = entries[key] {
            entry.frecency = -1
            entry.totalUses += 1
            if let timestamp {
                entry.recentUses.append(timestamp)
                entry.recentUses.sort()
            } else {
                entry.recentUses.append(fallback ?? UInt64(now().timeIntervalSince1970 * 1_000))
            }
            while entry.recentUses.count > Self.maximumSamples { entry.recentUses.removeFirst() }
            entries[key] = entry
        } else {
            keys.append(key)
            entries[key] = Entry(
                totalUses: 1,
                recentUses: [timestamp ?? fallback ?? UInt64(now().timeIntervalSince1970 * 1_000)],
                frecency: -1,
                score: 0
            )
        }
        markDirty()
    }

    private func markDirty() {
        isDirty = true
        revision &+= 1
    }

    private func compute() {
        let current = now()
        var removed = Set<String>()
        for key in keys {
            guard var entry = entries[key], entry.frecency == -1 else { continue }
            entry.score = 0
            for (index, timestamp) in entry.recentUses.enumerated() where index < Self.maximumSamples {
                entry.score += 0.01 * Double(Self.weight(days: Self.dayDifference(from: timestamp, to: current)))
            }
            if entry.score > 0 {
                if !entry.recentUses.isEmpty {
                    entry.frecency = (Double(entry.totalUses) * (entry.score / Double(entry.recentUses.count))).rounded(.up)
                }
                entries[key] = entry
            } else {
                entries[key] = nil
                removed.insert(key)
            }
        }
        if !removed.isEmpty { keys.removeAll { removed.contains($0) } }
        struct Ranked {
            let key: String
            let frecency: Double
            let offset: Int
        }
        var ranked: [Ranked] = []
        for (offset, key) in keys.enumerated() {
            guard let entry = entries[key] else { continue }
            ranked.append(Ranked(key: key, frecency: entry.frecency, offset: offset))
        }
        ranked.sort { lhs, rhs in
            lhs.frecency != rhs.frecency ? lhs.frecency > rhs.frecency : lhs.offset < rhs.offset
        }
        cachedFrequently = ranked.prefix(Self.frequentlyLimit).map(\.key)
        isDirty = false
    }

    /// Discord's day buckets for recent uses.
    nonisolated static func weight(days: Int) -> Int {
        switch days {
        case ...3: 100
        case ...15: 70
        case ...30: 50
        case ...45: 30
        case ...80: 10
        default: 1
        }
    }

    /// Moment's `diff(..., "days")`: elapsed milliseconds corrected for a
    /// change in UTC offset, truncated toward zero.
    nonisolated static func dayDifference(from timestamp: UInt64, to now: Date, timeZone: TimeZone = .current) -> Int {
        let then = Date(timeIntervalSince1970: Double(timestamp) / 1_000)
        let zoneDelta = Double(timeZone.secondsFromGMT(for: then) - timeZone.secondsFromGMT(for: now)) * 1_000
        let elapsed = (now.timeIntervalSince1970 * 1_000 - Double(timestamp) - zoneDelta) / 86_400_000
        return Int(elapsed.rounded(.towardZero))
    }

    private func persistPending() {
        guard let defaultsKey else { return }
        if pendingUsages.isEmpty {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else if let data = try? JSONEncoder().encode(pendingUsages) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
