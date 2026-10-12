import SwiftUI

// MARK: - Data

struct CLIOutput: Decodable {
    let token_status: String
    let windows: [CLIWindow]
}

struct CLIWindow: Decodable {
    let name: String
    let percent: Double?
    let left: Double?
    let resets_in_seconds: Int?
    let blocked: Bool
}

struct UsageWindow: Identifiable {
    let name: String
    let percent: Double?
    let left: Double?
    let resetDate: Date?
    let blocked: Bool
    var id: String { name }

    /// Full length of this window: 5h for the session, 7d for weekly/model windows.
    var duration: TimeInterval { name == "session" ? 5 * 3600 : 7 * 24 * 3600 }

    /// Fraction of the window elapsed (0…1).
    var elapsedFraction: Double {
        guard let reset = resetDate else { return 1 }
        return max(0.02, min(1, 1 - reset.timeIntervalSinceNow / duration))
    }

    /// The 5h session window only exists while you're active — it does not reset on a
    /// fixed clock. When its reset is already at or behind now, no window is open: the
    /// CLI floors the countdown to 0, which would otherwise render as a reset stuck at
    /// "0m" for hours. Weekly/model windows reset on a schedule regardless, so they're
    /// never idle. (resetDate carries `now + resets_in_seconds`, so <= now == lapsed.)
    var sessionIdle: Bool {
        guard name == "session" else { return false }
        guard let reset = resetDate else { return true }
        return reset.timeIntervalSinceNow <= 0
    }

    /// Urgency (0 green · 1 yellow · 2 orange · 3 red): starts from how much is
    /// left, then adjusts for time-to-reset — eases when reset is imminent (relief
    /// is coming) and escalates when you're on track to run out before it resets.
    var urgencyLevel: Int {
        if blocked { return 3 }
        let q = (left ?? percent.map { 100 - $0 } ?? 100) / 100   // quota-left fraction
        // No open session window: rank on remaining quota alone — there's no live
        // window to project a burn rate against, so the time escalation doesn't apply.
        if sessionIdle { return q < 0.10 ? 3 : (q < 0.25 ? 2 : (q < 0.50 ? 1 : 0)) }
        let elapsed = elapsedFraction
        let t = 1 - elapsed                                        // time-left fraction
        var level = q < 0.10 ? 3 : (q < 0.25 ? 2 : (q < 0.50 ? 1 : 0))   // magnitude base
        if elapsed > 0.1 {                                         // escalate: will you run out early?
            let projected = (1 - q) / elapsed
            if projected >= 1.5 { level = min(3, level + 2) }      // way ahead — locked out a while
            else if projected >= 1.0 { level = min(3, level + 1) } // on track to run out before reset
        }
        if t < 0.1 { level = max(0, level - 1) }                   // ease: reset is imminent
        return level
    }

    /// Gauge color from urgency (same scale used by the menu-bar badges).
    var fillColor: Color {
        switch urgencyLevel {
        case 0: return .green
        case 1: return .yellow
        case 2: return .orange
        default: return .red
        }
    }

    /// Pace glyph shown next to the name. Two different systems:
    ///  • Session (5h): a burn projection — "will I run out before it resets?".
    ///    ↑ orange/red when front-loading; nothing while coasting (no ↓, since
    ///    under-using a 5h window just resets).
    ///  • Weekly / Fable: even-pacing on the 20%/day budget — ↑ ahead, ↓ behind,
    ///    • on pace.
    var paceSpec: (glyph: String, color: Color)? {
        guard let used = percent else { return nil }
        if name == "session" {
            guard !sessionIdle, elapsedFraction >= 0.1 else { return nil }   // no window / too early
            let projected = used / elapsedFraction
            if projected >= 100 { return ("↑", .red) }
            if projected >= 80 { return ("↑", .orange) }
            return nil
        }
        let perDay = used / max(0.5, elapsedFraction * 7)
        if perDay > 30 { return ("↑", .red) }
        if perDay > 20 { return ("↑", .orange) }
        if perDay < 10 { return ("↓", .blue) }
        return ("•", .secondary)
    }
}

// MARK: - Forecasts

extension UsageWindow {
    var displayName: String {
        switch name {
        case "session": return "5-hour"
        case "weekly": return "Weekly"
        default: return name.capitalized
        }
    }

    /// Percent of the limit still available, 0…100.
    var leftPercent: Double? { left ?? percent.map { 100 - $0 } }

    /// The 5h and weekly limits gate everything; a model-scoped one only gates
    /// that model, so it shouldn't paint the whole panel as limited.
    var isPrimary: Bool { name == "session" || name == "weekly" }

    /// When this window began: its reset minus its length.
    var windowStart: Date? { resetDate.map { $0.addingTimeInterval(-duration) } }

    /// Fraction of the window's time still to run (1 = just began, 0 = resetting).
    /// nil when no window is open, since there's no clock running to compare against.
    var timeLeftFraction: Double? {
        guard let reset = resetDate, !sessionIdle else { return nil }
        return max(0, min(1, reset.timeIntervalSinceNow / duration))
    }

    /// When the limit runs dry at the average rate so far — only when that lands
    /// before the reset, since otherwise there's nothing to warn about. Held back
    /// until a tenth of the window has passed and 5% is used: earlier than that a
    /// single burst reads as a runaway rate.
    func runOutDate(at now: Date = Date()) -> Date? {
        guard !blocked, !sessionIdle, let used = percent, used >= 5, used < 100,
              let reset = resetDate, let start = windowStart else { return nil }
        let elapsed = now.timeIntervalSince(start)
        guard elapsed >= duration * 0.1 else { return nil }
        let out = now.addingTimeInterval((100 - used) / (used / elapsed))
        return out < reset ? out : nil
    }

    /// An even share of what's left for each day until the reset (weekly windows).
    /// The last day gets the whole remainder rather than a multiple of it.
    var dailyBudget: Double? {
        guard name != "session", let left = leftPercent, let reset = resetDate else { return nil }
        let days = reset.timeIntervalSinceNow / 86_400
        guard days > 0 else { return nil }
        return left / max(1, days)
    }
}

/// Where the claude-usage backend lives: ~/.local/bin for a source install,
/// Homebrew's bin for a brew one. Checked on each use, so installing it while
/// the app runs needs no relaunch.
enum Backend {
    static var path: String {
        let candidates = [NSHomeDirectory() + "/.local/bin/claude-usage",
                          "/opt/homebrew/bin/claude-usage",
                          "/usr/local/bin/claude-usage"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[0]
    }
}

/// Shared time formatting for the panel and alerts.
enum Fmt {
    /// The absolute reset moment: clock time if it's within a day ("3:15 PM"),
    /// otherwise weekday + time ("Sat 8:00 AM") so multi-day windows are unambiguous.
    static func clock(_ d: Date) -> String {
        if d.timeIntervalSinceNow < 24 * 3600 {
            return d.formatted(date: .omitted, time: .shortened)
        }
        return d.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    static func human(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval))
        let d = s / 86_400
        let h = (s % 86_400) / 3_600
        let m = (s % 3_600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(String(format: "%02d", m))m" }
        return "\(m)m"
    }

    static func percent(_ v: Double) -> String {
        v > 0 && v < 1 ? String(format: "%.1f%%", v) : "\(Int(v.rounded()))%"
    }
}

/// How the menu-bar item draws the two limits.
enum MenuBarStyle: String, CaseIterable, Identifiable {
    case badges, rings, numbers
    var id: String { rawValue }
    var title: String {
        switch self {
        case .badges: return "Badges"
        case .rings: return "Rings"
        case .numbers: return "Numbers"
        }
    }
}

enum FetchResult {
    case success(CLIOutput)
    case failure(String)
}

/// Result of an anchor probe. `.failed` is retryable (network/probe error);
/// `.skipped` (window already open / guard) and `.sent` are terminal.
enum AnchorOutcome { case sent, skipped, failed }
