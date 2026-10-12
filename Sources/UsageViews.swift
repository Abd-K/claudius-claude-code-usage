import SwiftUI
import AppKit

// MARK: - Building blocks

struct MenuLabelView: View {
    @ObservedObject var model: UsageModel
    var body: some View {
        Image(nsImage: model.menuBarImage)
    }
}

/// The rounded panel each section of the popover sits on.
struct Card<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.045)))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

/// A horizontal fuel gauge: full = all of it left.
struct FuelBar: View {
    let fraction: Double
    let tint: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let f = min(1, max(0, fraction))
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.16))
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.7), tint],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: f > 0 ? max(height, geo.size.width * f) : 0)
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.5), value: fraction)
    }
}

// MARK: - Limits

/// The hero gauge. Thick outer ring: how much of the limit is left. Thin inner
/// ring: how much of the window's time is left. Fuel ahead of time means you
/// reach the reset with some to spare.
struct LimitRing: View {
    let window: UsageWindow
    var diameter: CGFloat = 84

    private var line: CGFloat { (diameter * 0.1).rounded() }
    private var left: Double { min(1, max(0, (window.leftPercent ?? 0) / 100)) }
    private var tint: Color { window.fillColor }

    var body: some View {
        ZStack {
            Circle().inset(by: line / 2)
                .stroke(tint.opacity(0.16), lineWidth: line)
            Circle().inset(by: line / 2)
                .trim(from: 0, to: left)
                .stroke(AngularGradient(colors: [tint.opacity(0.65), tint], center: .center,
                                        startAngle: .degrees(0),
                                        endAngle: .degrees(360 * max(left, 0.01))),
                        style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let t = window.timeLeftFraction {
                Circle().inset(by: line + 3)
                    .trim(from: 0, to: t)
                    .stroke(Color.secondary.opacity(0.55),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: -1) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(window.leftPercent.map { String(Int($0.rounded())) } ?? "–")
                        .font(.system(size: diameter * 0.27, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("%")
                        .font(.system(size: diameter * 0.13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Text("left")
                    .font(.system(size: max(9, diameter * 0.11)))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: diameter, height: diameter)
        .animation(.easeOut(duration: 0.6), value: left)
    }
}

/// A ring with its name, reset countdown and — only when there's something to
/// act on — a forecast line.
struct LimitTile: View {
    let window: UsageWindow
    var diameter: CGFloat = 84

    var body: some View {
        VStack(spacing: 4) {
            LimitRing(window: window, diameter: diameter)
                .help("Outer ring: \(window.displayName.lowercased()) limit left · inner ring: time left before it resets")
                .padding(.bottom, 2)
            HStack(spacing: 3) {
                Text(window.displayName).font(.system(size: 12, weight: .semibold))
                if let pace {
                    Text(pace.glyph)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(pace.color)
                        .help(paceHelp(pace.glyph))
                }
            }
            Text(resetText)
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .help(resetHelp)
            if let note = forecast {
                Text(note.text)
                    .font(.caption.weight(.medium)).monospacedDigit()
                    .foregroundStyle(note.color)
                    .help(note.help)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The pace glyph, minus the two cases where it only adds noise: while limited
    /// (the banner says it), and the neutral "on pace" dot beside a run-out forecast
    /// it would contradict.
    private var pace: (glyph: String, color: Color)? {
        guard !window.blocked, let p = window.paceSpec else { return nil }
        return p.glyph == "•" && forecast != nil ? nil : p
    }

    private var resetText: String {
        if window.sessionIdle { return "idle" }
        guard let d = window.resetDate else { return "–" }
        return "\(Fmt.human(d.timeIntervalSinceNow)) · \(Fmt.clock(d))"
    }

    private var resetHelp: String {
        if window.sessionIdle { return "No 5-hour window open — the next message starts one" }
        guard let d = window.resetDate else { return "" }
        return "Resets in \(Fmt.human(d.timeIntervalSinceNow)), at \(Fmt.clock(d))"
    }

    private var forecast: (text: String, color: Color, help: String)? {
        if window.blocked {
            let back = window.resetDate.map { "back \(Fmt.clock($0))" } ?? "limited"
            return (back, .red, "Limit reached")
        }
        guard let out = window.runOutDate(), let reset = window.resetDate else { return nil }
        let soon = out.timeIntervalSinceNow < 3600
        return ("out ~\(Fmt.clock(out))", soon ? .red : .orange,
                "At the rate so far this runs out at \(Fmt.clock(out)), before the reset at \(Fmt.clock(reset))")
    }

    private func paceHelp(_ glyph: String) -> String {
        if window.name == "session" { return "Using it fast for this point in the window" }
        switch glyph {
        case "↑": return "Ahead of pace — over 20% a day"
        case "↓": return "Under 10% a day — room to spare"
        default: return "On pace — 10–20% a day"
        }
    }
}

/// A model-scoped weekly limit (e.g. Fable) on one line.
struct ModelLimitRow: View {
    let window: UsageWindow

    var body: some View {
        HStack(spacing: 8) {
            Text(window.displayName)
                .font(.caption.weight(.medium)).lineLimit(1)
                .frame(width: 48, alignment: .leading)
            FuelBar(fraction: (window.leftPercent ?? 0) / 100, tint: window.fillColor, height: 5)
            Text(window.blocked ? "limited" : window.leftPercent.map { "\(Int($0.rounded()))%" } ?? "–")
                .font(.caption).monospacedDigit()
                .foregroundStyle(window.blocked ? Color.red : Color.secondary)
                .frame(width: 40, alignment: .trailing)
        }
        .help(help)
    }

    private var help: String {
        guard let d = window.resetDate else { return "\(window.displayName) weekly limit" }
        return "\(window.displayName) weekly limit · resets \(Fmt.clock(d)) (\(Fmt.human(d.timeIntervalSinceNow)))"
    }
}

/// This week at a glance. The line is weekly usage from the readings the app
/// keeps; dashed where it's inferred (the window starts at zero, so the stretch
/// before the first reading is drawn straight from there). The shaded band is
/// the 10–20%-a-day pace the weekly arrow is judged by.
struct WeekTrend: View {
    let window: UsageWindow
    let readings: [(t: Date, used: Double)]
    let now: Date

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let start = window.windowStart ?? now
            let x = { (t: Date) -> CGFloat in
                CGFloat(max(0, min(1, t.timeIntervalSince(start) / window.duration))) * w
            }
            let y = { (v: Double) -> CGFloat in h - CGFloat(max(0, min(100, v)) / 100) * h }
            let trace = readings + (window.percent.map { [(t: now, used: $0)] } ?? [])
            let origin = CGPoint(x: 0, y: h)
            let tint = window.fillColor

            ZStack(alignment: .topLeading) {
                Path { p in
                    for d in 1..<7 {
                        let dx = w * CGFloat(d) / 7
                        p.move(to: CGPoint(x: dx, y: 0))
                        p.addLine(to: CGPoint(x: dx, y: h))
                    }
                }
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)

                Path { p in
                    p.move(to: origin)
                    p.addLine(to: CGPoint(x: w * 5 / 7, y: 0))   // 20%/day reaches 100 on day 5
                    p.addLine(to: CGPoint(x: w, y: 0))
                    p.addLine(to: CGPoint(x: w, y: y(70)))       // 10%/day reaches 70 on day 7
                    p.closeSubpath()
                }
                .fill(Color.primary.opacity(0.07))

                if let first = trace.first, let last = trace.last {
                    Path { p in
                        p.move(to: origin)
                        p.addLine(to: CGPoint(x: x(first.t), y: y(first.used)))
                        for r in trace.dropFirst() { p.addLine(to: CGPoint(x: x(r.t), y: y(r.used))) }
                        p.addLine(to: CGPoint(x: x(last.t), y: h))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))

                    Path { p in
                        p.move(to: origin)
                        p.addLine(to: CGPoint(x: x(first.t), y: y(first.used)))
                    }
                    .stroke(tint.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))

                    Path { p in
                        p.move(to: CGPoint(x: x(first.t), y: y(first.used)))
                        for r in trace.dropFirst() { p.addLine(to: CGPoint(x: x(r.t), y: y(r.used))) }
                    }
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))

                    Circle().fill(tint)
                        .frame(width: 6, height: 6)
                        .position(x: x(last.t), y: y(last.used))
                }
            }
        }
        .frame(height: 40)
    }
}

/// The two main limits as rings, the week's trend, and any model-scoped limits.
struct LimitsCard: View {
    @ObservedObject var model: UsageModel
    let now: Date

    private var primary: [UsageWindow] { model.windows.filter(\.isPrimary) }
    private var others: [UsageWindow] { model.windows.filter { !$0.isPrimary } }
    private var weekly: UsageWindow? { model.windows.first { $0.name == "weekly" } }

    var body: some View {
        Card(spacing: 10) {
            if model.windows.isEmpty {
                HStack(spacing: 6) {
                    if model.error == nil { ProgressView().controlSize(.small) }
                    Text(model.error == nil ? "Loading…" : "No usage data")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(primary) { LimitTile(window: $0) }
                }
                if let weekly { week(weekly) }
                if !others.isEmpty {
                    VStack(spacing: 6) { ForEach(others) { ModelLimitRow(window: $0) } }
                }
            }
        }
    }

    @ViewBuilder private func week(_ w: UsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("This week").font(.caption.weight(.semibold))
                Spacer()
                let today = model.history.usedToday(w, now: now)
                let budget = w.dailyBudget
                if let today {
                    Text("today \(Fmt.percent(today))")
                        .foregroundStyle(budget.map { today > $0 } == true ? Color.orange : Color.secondary)
                        .help("Weekly limit used since midnight")
                }
                if today != nil && budget != nil { Text("·").foregroundStyle(.tertiary) }
                if let budget {
                    Text("\(Fmt.percent(budget))/day")
                        .foregroundStyle(.secondary)
                        .help("An even share of what's left for each day until the reset")
                }
            }
            .font(.caption).monospacedDigit()
            if let start = w.windowStart {
                WeekTrend(window: w, readings: model.history.series(w.name, since: start), now: now)
                    .help("Weekly usage this week · shaded band: 10–20% a day")
            }
        }
    }
}

/// Shown while the 5-hour or weekly limit is blocking you.
struct LimitedBanner: View {
    let until: Date

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "hourglass")
            Text(until == .distantFuture ? "Limited" : "Limited · back at \(Fmt.clock(until))")
            Spacer()
            if until != .distantFuture {
                Text(Fmt.human(until.timeIntervalSinceNow)).monospacedDigit()
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.red.gradient))
    }
}

// MARK: - Popover

struct PopoverView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var pin: PinController
    @ObservedObject var sessions: SessionsModel
    @ObservedObject var dock: DockController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let error = model.error {
                VStack(alignment: .leading, spacing: 6) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.needsSignIn {
                        Button("Sign in to the Claude Code CLI") { model.openSignIn() }
                            .controlSize(.small)
                            .help("Opens Terminal and runs `claude auth login`, then picks up "
                                  + "the new token automatically. The CLI signs in separately "
                                  + "from the Claude desktop app, so you can be logged into the "
                                  + "app and still need this. Claudius never sees your credentials.")
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.orange.opacity(0.10)))
            }

            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                VStack(spacing: 10) {
                    if let until = model.limitedUntil { LimitedBanner(until: until) }
                    LimitsCard(model: model, now: ctx.date)
                }
            }

            SessionsSection(model: sessions)

            footer

            if let result = model.probeResult {
                Text(result)
                    .font(.caption2)
                    .foregroundStyle(result.hasPrefix("✓") ? Color.green : Color.orange)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(12)
        .frame(width: 320)
        .onAppear { model.refreshIfStale() }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high)
                .frame(width: 20, height: 20)
            Text("Claudius").font(.system(size: 13, weight: .semibold))
            Spacer()
            Button {
                pin.toggle()
            } label: {
                Image(systemName: pin.isPinned ? "pin.fill" : "pin")
            }
            .buttonStyle(.borderless)
            .help(pin.isPinned ? "Close the floating window" : "Keep on top in a floating window")
            Button {
                model.fetch()
            } label: {
                if model.isFetching {
                    ProgressView().controlSize(.mini).frame(width: 14, height: 14)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .disabled(model.isFetching)
            .help(model.updatedAt.map {
                "Refresh · updated \($0.formatted(date: .omitted, time: .shortened))"
            } ?? "Refresh")
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $model.autoAnchor) {
                Text("Auto-refresh 5h limit").font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .fixedSize()
            .help("Your 5-hour usage limit only starts counting once you send a message, then resets 5 hours later. With this on, about a minute after it resets Claudius sends one tiny cheapest-model request so a fresh 5-hour limit begins right away — instead of waiting until you next use Claude. Heavy users get more resets (and so more usage) per day; if you rarely hit the 5-hour limit it does little. Off = your 5-hour limit only starts when you send your next message.")

            Button {
                model.sendTestRequest()
            } label: {
                if model.isProbing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "bolt.fill")
                }
            }
            .buttonStyle(.borderless)
            .disabled(model.isProbing)
            .help("Anchor one now — fire a tiny request to open a fresh 5h window immediately")

            Spacer()

            SettingsMenu(model: model, dock: dock)
        }
    }
}

/// Everything set-and-forget, behind one gear.
struct SettingsMenu: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var dock: DockController

    var body: some View {
        Menu {
            Picker("Menu bar", selection: $model.menuBarStyle) {
                ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Limit alerts", isOn: $model.alerts)
            Toggle("Show in Dock", isOn: $dock.showInDock)
            Toggle("Launch at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }))
            Divider()
            Button("Usage on claude.ai") {
                if let url = URL(string: "https://claude.ai/settings/usage") {
                    NSWorkspace.shared.open(url)
                }
            }
            Divider()
            Button("Quit Claudius") { NSApplication.shared.terminate(nil) }
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Settings")
    }
}

// MARK: - Pinned floating window

/// A compact always-on-top panel showing the same gauges, for keeping usage
/// visible without the popover auto-dismissing.
struct PinnedView: View {
    @ObservedObject var model: UsageModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            VStack(spacing: 10) {
                if model.windows.isEmpty {
                    Text(model.error ?? "Loading…")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .top, spacing: 6) {
                        ForEach(model.windows.filter(\.isPrimary)) {
                            LimitTile(window: $0, diameter: 64)
                        }
                    }
                    ForEach(model.windows.filter { !$0.isPrimary }) { ModelLimitRow(window: $0) }
                }
            }
        }
        .padding(12)
        .frame(width: 250)
    }
}

/// Owns the floating NSPanel. Toggled from the popover; also resets its own
/// state if the user closes the panel with its close button.
final class PinController: NSObject, ObservableObject, NSWindowDelegate {
    @Published var isPinned = false
    private var panel: NSPanel?
    private weak var model: UsageModel?

    func configure(_ model: UsageModel) { self.model = model }

    func toggle() { isPinned ? unpin() : pin() }

    func pin() {
        guard panel == nil, let model else { return }
        let host = NSHostingController(rootView: PinnedView(model: model))
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 250, height: 200),
                        styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.title = "Claude usage"
        p.contentViewController = host
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        // Stay on the workspace where it was pinned — no .canJoinAllSpaces, so it
        // doesn't follow you across Spaces/AeroSpace workspaces. WM-agnostic.
        p.collectionBehavior = [.managed, .fullScreenAuxiliary]
        p.delegate = self
        p.center()
        p.makeKeyAndOrderFront(nil)
        panel = p
        isPinned = true
    }

    func unpin() {
        panel?.orderOut(nil)
        panel = nil
        isPinned = false
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
        isPinned = false
    }
}
