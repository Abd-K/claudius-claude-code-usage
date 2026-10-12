import Foundation

/// One reading: how much of each limit was used at a moment.
struct UsagePoint: Codable {
    let t: Date
    let used: [String: Double]
}

/// Readings kept on disk so the panel can draw the week's trend and say how much
/// went today — the usage endpoint only ever reports the present. Stored in
/// Application Support; nothing here leaves the machine.
final class UsageHistory {
    private(set) var points: [UsagePoint] = []
    private let url: URL
    /// A little over a week: the weekly window plus the night before it began,
    /// which is what "today" needs on the window's first day.
    private static let keep: TimeInterval = 8 * 86_400
    /// An unchanged reading is still stored this often, so a quiet stretch is on
    /// record as quiet rather than as a gap nothing can be said about.
    private static let heartbeat: TimeInterval = 15 * 60

    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claudius/history.json")) {
        self.url = url
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        if let data = try? Data(contentsOf: url),
           let saved = try? dec.decode([UsagePoint].self, from: data) {
            points = saved
        }
    }

    func record(_ windows: [UsageWindow], at now: Date = Date()) {
        var used: [String: Double] = [:]
        for w in windows { if let p = w.percent { used[w.name] = p } }
        guard !used.isEmpty else { return }
        if let last = points.last, last.used == used,
           now.timeIntervalSince(last.t) < Self.heartbeat { return }
        points.append(UsagePoint(t: now, used: used))
        points.removeAll { now.timeIntervalSince($0.t) > Self.keep }
        save()
    }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try enc.encode(points).write(to: url, options: .atomic)
        } catch {}
    }

    /// Readings of one limit since `start`, oldest first.
    func series(_ name: String, since start: Date) -> [(t: Date, used: Double)] {
        points.compactMap { p in
            guard p.t >= start, let v = p.used[name] else { return nil }
            return (p.t, v)
        }
    }

    /// Percentage points of a limit used since local midnight, or nil when the
    /// readings can't say where midnight stood.
    ///
    /// The baseline is the last reading at or before midnight. It's trusted only
    /// when it is close to midnight, or when the first reading after midnight
    /// matches it — an unchanged value either side of a gap means nothing was used
    /// in it. Otherwise usage from the evening before would be counted as today's.
    func usedToday(_ w: UsageWindow, now: Date = Date()) -> Double? {
        guard let used = w.percent, let start = w.windowStart else { return nil }
        let midnight = Calendar.current.startOfDay(for: now)
        if start >= midnight { return used }   // the window itself began today
        let inWindow = series(w.name, since: start)
        guard let before = inWindow.last(where: { $0.t <= midnight }) else { return nil }
        let after = inWindow.first(where: { $0.t > midnight })
        let pinned = midnight.timeIntervalSince(before.t) <= 2 * 3600 || after?.used == before.used
        return pinned ? max(0, used - before.used) : nil
    }
}
