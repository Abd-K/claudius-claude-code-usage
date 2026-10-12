import SwiftUI
import AppKit
import ServiceManagement

final class UsageModel: ObservableObject {
    @Published var windows: [UsageWindow] = []
    @Published var error: String?
    @Published var updatedAt: Date?
    @Published var isFetching = false
    @Published var isProbing = false
    @Published var probeResult: String?
    /// True when the Keychain token is missing or can't be revived — the one case
    /// that needs a human to log in.
    @Published var needsSignIn = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var autoAnchor = (UserDefaults.standard.object(forKey: "autoAnchor") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(autoAnchor, forKey: "autoAnchor")
            scheduleAutoAnchor()
        }
    }
    @Published var menuBarStyle = MenuBarStyle(
        rawValue: UserDefaults.standard.string(forKey: "menuBarStyle") ?? "") ?? .badges {
        didSet { UserDefaults.standard.set(menuBarStyle.rawValue, forKey: "menuBarStyle") }
    }
    /// Low / reached / back alerts. On by default: they're the reason to keep a
    /// limit watcher running at all.
    @Published var alerts = (UserDefaults.standard.object(forKey: "alerts") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(alerts, forKey: "alerts")
            if alerts { Notifier.shared.requestAccess() }
        }
    }
    let history: UsageHistory
    /// Seconds after a window's reset to fire the next anchor.
    private let anchorDelayAfterReset: TimeInterval = 60
    /// Mirrors the CLI's own anchor guard: once it has attempted a probe, no
    /// further non-forced attempt can do anything for this long.
    private let anchorGuardSeconds: TimeInterval = 30 * 60

    private var timer: Timer?
    private var signInWatch: Timer?
    private var anchorTimer: Timer?
    private var anchorRetryTimer: Timer?
    private var anchorRetries = 0
    private let maxAnchorRetries = 6
    private var autoAnchorInFlight = false
    /// Until this time an attempt could only be refused by the CLI's guard, so
    /// the 2-minute poll holds off instead of spending a usage read per tick.
    private var anchorHoldUntil: Date?
    private static let cliPath = NSHomeDirectory() + "/.local/bin/claude-usage"

    /// `live: false` builds a model that never polls, anchors or alerts — for
    /// rendering the panel from fixed data (scripts/snapshot.sh).
    init(live: Bool = true, history: UsageHistory = UsageHistory()) {
        self.history = history
        guard live else { return }
        Notifier.shared.start(requestingAccess: alerts)
        fetch()
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            self?.fetch()
        }
        // Refresh and re-evaluate anchoring the moment the machine wakes — timers
        // don't fire during sleep, so this is our catch-up on return.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleWake()
        }
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// On wake: refresh, and if auto-anchor is on but no window is currently open
    /// (e.g. we slept through a reset), open one now so a fresh window is rolling
    /// when you return. The CLI's 30-min guard keeps repeated wakes from spamming.
    private func handleWake() {
        fetch()
        if autoAnchor && openSessionWindow == nil { maybeAutoAnchor() }
    }

    // --- Menu bar item: the two limits in the chosen style + weekly-pace arrow ---

    private var sessionWindow: UsageWindow? { windows.first { $0.name == "session" } }
    private var weeklyWindow: UsageWindow? { windows.first { $0.name == "weekly" } }

    /// The 5h or weekly limit that's currently blocking you, and when the last of
    /// them lifts — the moment you can work again.
    var limitedUntil: Date? {
        let blocking = windows.filter { $0.isPrimary && $0.blocked }
        guard !blocking.isEmpty else { return nil }
        return blocking.compactMap(\.resetDate).max() ?? .distantFuture
    }

    /// Badge fill + inside-number color, from the same urgency scale as the panel
    /// (magnitude adjusted for time-to-reset).
    private static func badgeColors(_ w: UsageWindow?) -> (fill: NSColor, text: NSColor) {
        guard let w else { return (.systemGray, .white) }
        switch w.urgencyLevel {
        case 0: return (.systemGreen, .white)
        case 1: return (.systemYellow, .black)   // white reads poorly on bright yellow
        case 2: return (.systemOrange, .white)
        default: return (.systemRed, .white)
        }
    }

    /// The % left as a bare number ("–" when the window is absent).
    private static func label(_ w: UsageWindow?) -> String {
        guard let w, let l = w.leftPercent else { return "–" }
        return String(Int(l.rounded()))
    }

    /// Weekly-pace arrow on a generous 20%/day budget (≈140%/week, room for heavy
    /// days). One arrow shape; color carries the severity:
    ///   ↑ red    = way over (>30%/day) — heading to blow the weekly limit
    ///   ↑ orange = over budget (>20%/day)
    ///   (none)   = within a healthy 10–20%/day band
    ///   ↓ blue   = well behind (<10%/day) — weekly headroom going unused
    private var weeklyArrowSpec: (glyph: String, color: NSColor)? {
        guard let w = weeklyWindow, let used = w.percent else { return nil }
        let perDay = used / max(0.5, w.elapsedFraction * 7)
        if perDay > 30 { return ("↑", .systemRed) }
        if perDay > 20 { return ("↑", .systemOrange) }
        if perDay < 10 { return ("↓", .systemBlue) }
        return nil
    }

    /// Draws one badge (diameter d) at x with the window's % left inside — an oval
    /// when `rounded` is false (session), a rounded square when true (weekly), so
    /// the two are distinguishable at a glance.
    private static func drawBadge(_ w: UsageWindow?, at x: CGFloat, d: CGFloat, rounded: Bool) {
        let (fill, textColor) = badgeColors(w)
        fill.setFill()
        let rect = NSRect(x: x + 2, y: 2, width: d - 4, height: d - 4)
        (rounded ? NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
                 : NSBezierPath(ovalIn: rect)).fill()
        let text = label(w)
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: text.count > 2 ? 8 : 10, weight: .bold),
            .foregroundColor: textColor,
            .paragraphStyle: para,
        ]
        let ts = text.size(withAttributes: attrs)
        text.draw(in: NSRect(x: x, y: (d - ts.height) / 2, width: d, height: ts.height),
                  withAttributes: attrs)
    }

    /// Two concentric fuel rings: outer = 5-hour left, inner = weekly left.
    private static func drawRings(_ s: UsageWindow?, _ w: UsageWindow?, in r: NSRect) {
        let center = NSPoint(x: r.midX, y: r.midY)
        let line: CGFloat = 2.4
        let outer = r.width / 2 - line / 2
        for (win, radius) in [(s, outer), (w, outer - line - 1.6)] {
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = line
            NSColor.labelColor.withAlphaComponent(0.22).setStroke()
            track.stroke()
            guard let win, let left = win.leftPercent, left > 0 else { continue }
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90,
                          endAngle: 90 - 360 * min(1, left / 100), clockwise: true)
            arc.lineWidth = line
            arc.lineCapStyle = .round
            badgeColors(win).fill.setStroke()
            arc.stroke()
        }
    }

    /// "● 80  ■ 97": a colored mark (circle = 5-hour, square = weekly, as on the
    /// badges) before each number, the numbers in the menu bar's own text color.
    private static func numbersText(_ s: UsageWindow?, _ w: UsageWindow?) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let num: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        for (i, (win, mark)) in [(s, "●"), (w, "■")].enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "  ", attributes: num)) }
            out.append(NSAttributedString(string: mark + " ", attributes: [
                .font: NSFont.systemFont(ofSize: 9),
                .foregroundColor: badgeColors(win).fill,
                .baselineOffset: 1,
            ]))
            out.append(NSAttributedString(string: label(win), attributes: num))
        }
        return out
    }

    /// The menu-bar item in the chosen style, plus the weekly-pace arrow. Drawn on
    /// demand so the label-colored parts follow the menu bar's light or dark look.
    /// Non-template so the colors render.
    var menuBarImage: NSImage {
        let s = sessionWindow, w = weeklyWindow
        let h: CGFloat = 22
        let arrow = weeklyArrowSpec
        let arrowAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .heavy),
            .foregroundColor: arrow?.color ?? NSColor.clear,
        ]
        let arrowSize = arrow.map { $0.glyph.size(withAttributes: arrowAttrs) } ?? .zero
        let arrowW: CGFloat = arrow == nil ? 0 : arrowSize.width + 1

        let width: CGFloat
        let draw: () -> Void
        switch menuBarStyle {
        case .badges:
            width = 22 + 3 + 22
            draw = {
                Self.drawBadge(s, at: 0, d: 22, rounded: false)    // session = circle
                Self.drawBadge(w, at: 25, d: 22, rounded: true)    // weekly = rounded square
            }
        case .rings:
            width = 20
            draw = { Self.drawRings(s, w, in: NSRect(x: 0, y: 1, width: 20, height: 20)) }
        case .numbers:
            let text = Self.numbersText(s, w)
            let size = text.size()
            width = ceil(size.width) + 2
            draw = { text.draw(at: NSPoint(x: 1, y: (h - size.height) / 2)) }
        }
        let img = NSImage(size: NSSize(width: width + arrowW, height: h), flipped: false) { _ in
            draw()
            if let a = arrow {
                a.glyph.draw(at: NSPoint(x: width + 1, y: (h - arrowSize.height) / 2),
                             withAttributes: arrowAttrs)
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    func refreshIfStale() {
        if let t = updatedAt, Date().timeIntervalSince(t) < 45 { return }
        fetch()
    }

    func fetch() {
        guard !isFetching else { return }
        isFetching = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.runCLI()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isFetching = false
                switch result {
                case .success(let out):
                    let now = Date()
                    let fresh = out.windows.map {
                        UsageWindow(
                            name: $0.name,
                            percent: $0.percent,
                            left: $0.left,
                            resetDate: $0.resets_in_seconds.map { now.addingTimeInterval(Double($0)) },
                            blocked: $0.blocked)
                    }
                    self.history.record(fresh, at: now)
                    if self.alerts { Notifier.shared.compare(old: self.windows, new: fresh) }
                    self.windows = fresh
                    self.updatedAt = now
                    self.error = nil
                    self.needsSignIn = false
                    self.scheduleAutoAnchor()
                case .failure(let message):
                    self.error = Self.friendlyError(message)
                    self.needsSignIn = message.contains("signin_required")
                        || message.contains("no_credentials")
                }
            }
        }
    }

    /// The currently open session window (present with a future reset), or nil.
    ///
    /// A future reset is the whole test. There used to be a "nonzero usage" test
    /// alongside it, which read as a safety net and was in fact the opposite: the
    /// window a probe opens starts at 0% and stays there for a while, so a freshly
    /// anchored window looked closed and got anchored again every time the guard
    /// lifted — six probes across one window instead of one. A lapsed window is
    /// already excluded by the reset test, since the endpoint keeps reporting the
    /// old reset time and the CLI floors the countdown to zero once it passes.
    private var openSessionWindow: UsageWindow? {
        guard let s = windows.first(where: { $0.name == "session" }),
              let reset = s.resetDate, reset.timeIntervalSinceNow > 0 else { return nil }
        return s
    }

    /// Keep a 5-hour window rolling. While one is open, arm a one-shot timer for
    /// 60s after its reset so windows chain back-to-back on the reset boundary;
    /// once one has lapsed, anchor right now — a lapsed window is exactly the
    /// state this toggle exists to end.
    ///
    /// Anchoring out of the lapsed state, and not only from the timer, is what
    /// keeps the chain alive. This runs on every fetch, and it used to simply
    /// invalidate the pending timer whenever no window was open. Since the CLI
    /// floors the countdown to zero the moment a window lapses, any poll landing
    /// in the 60s before the timer was due killed it, and nothing rearmed it —
    /// one missed reset ended the chain for good. That same poll is now the
    /// safety net rather than the thing that breaks it, which also covers a timer
    /// lost to sleep or to a fetch that failed.
    func scheduleAutoAnchor() {
        anchorTimer?.invalidate()
        anchorTimer = nil
        guard autoAnchor else { clearAnchorRetry(); clearAnchorHold(); return }
        guard let s = openSessionWindow, let reset = s.resetDate else {
            maybeAutoAnchor()
            return
        }
        clearAnchorHold()
        let fireAt = reset.addingTimeInterval(anchorDelayAfterReset)
        let delay = max(1, fireAt.timeIntervalSinceNow)
        anchorTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.maybeAutoAnchor()
        }
    }

    /// Fire the anchor probe (non-forced): the CLI re-checks authoritatively and
    /// applies its own 30-min guard, so at most one probe goes out per window.
    /// A send parks further attempts for the length of that guard, a guard refusal
    /// parks them until it expires, and a genuine failure (network/probe) retries
    /// with backoff.
    /// `ignoringHold` is for the backoff retry, which owns the hold it is waiting
    /// out; every other caller must respect it.
    func maybeAutoAnchor(ignoringHold: Bool = false) {
        guard autoAnchor, !autoAnchorInFlight, !isProbing else { return }
        if !ignoringHold, let hold = anchorHoldUntil, hold.timeIntervalSinceNow > 0 { return }
        autoAnchorInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let (outcome, message) = Self.runAnchor(force: false)
            DispatchQueue.main.async {
                self.autoAnchorInFlight = false
                switch outcome {
                case .sent:
                    self.probeResult = "✓ auto: " + message
                    self.clearAnchorRetry()
                    // The CLI has just stamped its guard, so asking again before
                    // it lifts can only be refused — and the new window needs a
                    // moment to show up in the usage endpoint anyway.
                    self.holdAnchor(for: self.anchorGuardSeconds)
                case .skipped:
                    self.clearAnchorRetry()
                    self.applyAnchorHold(from: message)
                case .failed:
                    self.scheduleAnchorRetry(reason: message)
                }
                self.fetch()
            }
        }
    }

    private func clearAnchorRetry() {
        anchorRetries = 0
        anchorRetryTimer?.invalidate()
        anchorRetryTimer = nil
    }

    private func clearAnchorHold() { anchorHoldUntil = nil }

    private func holdAnchor(for seconds: TimeInterval) {
        anchorHoldUntil = Date().addingTimeInterval(seconds)
    }

    /// The CLI's guard refusal reads "anchored recently, wait 23m" — park until it
    /// lifts (plus a minute's slack) so the poll stops re-asking. Any other skip
    /// means a window is already open, so there is nothing to hold off.
    private func applyAnchorHold(from message: String) {
        guard let r = message.range(of: #"wait \d+m"#, options: .regularExpression),
              let minutes = Int(message[r].filter(\.isNumber)) else {
            clearAnchorHold()
            return
        }
        holdAnchor(for: Double(minutes + 1) * 60)
    }

    /// Retry a failed anchor with exponential backoff (2, 4, 8, 15, 15… min),
    /// so a transient network drop doesn't cost you the whole window. The backoff
    /// is also held on the poll: a failed attempt ends in a fetch, and without the
    /// hold that fetch would find no open window and attempt again at once.
    private func scheduleAnchorRetry(reason: String) {
        anchorRetryTimer?.invalidate()
        guard autoAnchor, anchorRetries < maxAnchorRetries else {
            clearAnchorRetry()
            holdAnchor(for: anchorGuardSeconds)   // out of retries: stop hammering
            probeResult = "auto-refresh gave up (\(reason)) — will try again later"
            return
        }
        anchorRetries += 1
        let delay = min(15 * 60, 60 * pow(2, Double(anchorRetries)))
        holdAnchor(for: delay)
        probeResult = "retrying anchor in \(Int(delay / 60))m (\(reason))"
        anchorRetryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.maybeAutoAnchor(ignoringHold: true)
        }
    }

    /// Fire a tiny cheapest-model request to open a fresh 5-hour session window now.
    func sendTestRequest() {
        guard !isProbing else { return }
        isProbing = true
        probeResult = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (outcome, message) = Self.runAnchor(force: true)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isProbing = false
                self.probeResult = (outcome == .sent ? "✓ " : "✗ ") + message
                // A forced run stamps the CLI's guard whether or not the probe
                // landed, so auto-anchoring has to wait it out either way.
                self.clearAnchorRetry()
                self.holdAnchor(for: self.anchorGuardSeconds)
                self.fetch()  // reflect the new window immediately
            }
        }
    }

    private static func runAnchor(force: Bool) -> (AnchorOutcome, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cliPath)
        proc.arguments = force ? ["anchor", "--force", "--json"] : ["anchor", "--json"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + NSHomeDirectory() + "/.local/bin"
        proc.environment = env
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do { try proc.run() } catch {
            return (.failed, "can't run claude-usage: \(error.localizedDescription)")
        }
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { proc.waitUntilExit(); finished.signal() }
        if finished.wait(timeout: .now() + 200) == .timedOut {
            proc.terminate()
            return (.failed, "request timed out")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let status = obj["status"] as? String {
            let msg = obj["message"] as? String ?? status
            switch status {
            case "sent": return (.sent, "5h limit refreshed")
            case "skipped": return (.skipped, msg)
            default: return (.failed, msg)   // "error" — network/probe/usage failure
            }
        }
        let errText = (String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (.failed, errText.isEmpty ? "request failed (exit \(proc.terminationStatus))" : errText)
    }

    /// Launch Claude Code's own login. Claudius never handles credentials itself —
    /// it runs `claude auth login` and lets Anthropic's flow do the work, then
    /// picks the new Keychain token up automatically.
    ///
    /// This goes through a generated .command file because `open -a Terminal <bin>`
    /// can't pass arguments — and dropping the user into a bare `claude` REPL, left
    /// to guess that they must type `/login`, is exactly the jarring part.
    func openSignIn() {
        let candidates = [
            NSHomeDirectory() + "/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        guard let claude = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            error = "Can't find the claude CLI — install Claude Code first"
            return
        }
        let dir = NSHomeDirectory() + "/Library/Application Support/Claudius"
        let script = dir + "/signin.command"
        let body = """
        #!/bin/zsh
        echo "Signing in to the Claude Code CLI (separate from the desktop app)…"
        echo
        "\(claude)" auth login
        echo
        echo "All done — close this window and go back to Claudius."
        """
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try body.write(toFile: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        } catch {
            self.error = "Couldn't prepare sign-in: \(error.localizedDescription)"
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: script))
        watchForSignIn()
    }

    /// While the login is open, check every few seconds so the app flips back to
    /// live numbers the moment it succeeds, rather than sitting on a stale error
    /// for up to a full poll interval. Costs nothing: while signed out the CLI
    /// answers locally without touching the network.
    private func watchForSignIn() {
        signInWatch?.invalidate()
        var ticks = 0
        signInWatch = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            ticks += 1
            if !self.needsSignIn || ticks > 60 {   // resolved, or give up after 5 min
                t.invalidate()
                self.signInWatch = nil
                return
            }
            self.fetch()
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            self.error = "login item: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Turn a raw CLI error status into a short, human sentence for the popover.
    private static func friendlyError(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        func number(after pattern: String) -> Int? {
            guard let r = s.range(of: pattern, options: .regularExpression) else { return nil }
            return Int(s[r].filter(\.isNumber))
        }
        if let secs = number(after: #"backing off \d+s"#) {
            let mins = max(1, Int((Double(secs) / 60).rounded()))
            return "Rate-limited by Anthropic — retrying in ~\(mins)m"
        }
        if s.contains("no_credentials") || s.contains("signin_required") {
            return "Claude Code CLI sign-in needed — separate from the desktop app"
        }
        if s.contains("stale_token") { return "Session token expired — refreshing…" }
        if let code = number(after: #"http_error_\d+"#) { return "Anthropic API error (\(code))" }
        if s.contains("timed out") { return "Request timed out — will retry" }
        if s.isEmpty { return "Couldn't read usage — will retry" }
        return s
    }

    private static func runCLI() -> FetchResult {
        guard FileManager.default.isExecutableFile(atPath: cliPath) else {
            return .failure("claude-usage not found at \(cliPath)")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cliPath)
        proc.arguments = ["--json", "--auto-refresh"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + NSHomeDirectory() + "/.local/bin"
        proc.environment = env
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do { try proc.run() } catch {
            return .failure("can't run claude-usage: \(error.localizedDescription)")
        }
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { proc.waitUntilExit(); finished.signal() }
        if finished.wait(timeout: .now() + 240) == .timedOut {
            proc.terminate()
            return .failure("claude-usage timed out")
        }
        let stdoutData = out.fileHandleForReading.readDataToEndOfFile()
        let stderrData = err.fileHandleForReading.readDataToEndOfFile()
        if let parsed = try? JSONDecoder().decode(CLIOutput.self, from: stdoutData) {
            return .success(parsed)
        }
        let message = (String(data: stderrData, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .failure(message.isEmpty ? "no usage data (exit \(proc.terminationStatus))" : message)
    }
}
