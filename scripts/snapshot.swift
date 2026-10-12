import SwiftUI
import AppKit

/// Renders the README screenshots from fixed demo data, so they never show live
/// usage or real session names. Built and run by snapshot.sh, which compiles this
/// alongside the app's own sources (minus their @main).
@main
enum Snapshot {
    @MainActor static func main() {
        let args = CommandLine.arguments
        let out = URL(fileURLWithPath: args.count > 1 ? args[1] : "docs", isDirectory: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        if args.count > 2, let icon = NSImage(contentsOfFile: args[2]) {
            NSApplication.shared.applicationIconImage = icon
        }

        let healthy = Demo.usage(session: (38, 2 * 3600 + 14 * 60), weekly: (29, 4 * 86_400 + 17 * 3600),
                                 fable: 12)
        let tight = Demo.usage(session: (86, 2 * 3600 + 4 * 60), weekly: (62, 3 * 86_400 + 9 * 3600),
                               fable: 41)
        let limited = Demo.usage(session: (100, 47 * 60), weekly: (78, 2 * 86_400 + 6 * 3600),
                                 fable: 55, sessionBlocked: true)

        for dark in [true, false] {
            snap(Demo.popover(healthy), dark: dark,
                 to: out.appendingPathComponent(dark ? "popover.png" : "popover-light.png"))
        }
        snap(Demo.popover(tight), dark: true, to: out.appendingPathComponent("popover-tight.png"))
        snap(Demo.popover(limited), dark: true, to: out.appendingPathComponent("popover-limited.png"))
        snap(Demo.popover(healthy, consumption: true), dark: true,
             to: out.appendingPathComponent("consumption.png"))
        snap(Demo.menuBar(healthy), dark: true, to: out.appendingPathComponent("menubar.png"))
        snap(Demo.socialPreview(healthy), dark: true, framed: false,
             to: out.appendingPathComponent("social-preview.png"))
    }

    /// Draws a view on a popover-like card and writes it as a PNG.
    @MainActor static func snap<V: View>(_ view: V, dark: Bool, framed: Bool = true, to url: URL) {
        let card = view
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: NSColor(white: dark ? 0.16 : 0.965, alpha: framed ? 1 : 0))))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(framed ? (dark ? 0.18 : 0.10) : 0), lineWidth: 0.5))
        let host = NSHostingView(rootView: card)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.appearance = appearance
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = appearance
        window.contentView = host
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }
        // Always 2x, whatever screen this runs on, so the README stays sharp.
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote \(url.lastPathComponent) \(rep.pixelsWide)x\(rep.pixelsHigh)")
    }
}

/// Fixed, made-up data for the screenshots.
@MainActor enum Demo {
    struct Usage {
        let windows: [UsageWindow]
        let history: UsageHistory
    }

    static func usage(session: (used: Double, resetIn: TimeInterval),
                      weekly: (used: Double, resetIn: TimeInterval),
                      fable: Double, sessionBlocked: Bool = false) -> Usage {
        let now = Date()
        func w(_ name: String, _ used: Double, _ resetIn: TimeInterval, blocked: Bool = false) -> UsageWindow {
            UsageWindow(name: name, percent: used, left: max(0, 100 - used),
                        resetDate: now.addingTimeInterval(resetIn), blocked: blocked)
        }
        let week = w("weekly", weekly.used, weekly.resetIn)
        return Usage(windows: [w("session", session.used, session.resetIn, blocked: sessionBlocked),
                               week,
                               w("fable", fable, weekly.resetIn)],
                     history: history(for: week, now: now))
    }

    /// A week of readings that climbs in two working stretches a day and sits flat
    /// in between, ending at the window's current value.
    static func history(for week: UsageWindow, now: Date) -> UsageHistory {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudius-snapshot-\(UUID().uuidString).json")
        let h = UsageHistory(url: url)
        defer { try? FileManager.default.removeItem(at: url) }
        guard let start = week.windowStart, let end = week.percent else { return h }
        var slots: [Date] = []
        var t = start
        while t < now { slots.append(t); t = t.addingTimeInterval(15 * 60) }
        func working(_ d: Date) -> Bool {
            let hour = d.timeIntervalSince(start).truncatingRemainder(dividingBy: 86_400) / 3600
            return (3..<9.5).contains(hour) || (11..<15).contains(hour)
        }
        let step = end / Double(max(1, slots.filter(working).count))
        var used = 0.0
        for s in slots {
            if working(s) { used += step }
            h.record([UsageWindow(name: "weekly", percent: used.rounded(), left: nil,
                                  resetDate: nil, blocked: false)], at: s)
        }
        return h
    }

    static func popover(_ usage: Usage, consumption: Bool = false) -> some View {
        let model = UsageModel(live: false, history: usage.history)
        model.windows = usage.windows
        model.updatedAt = Date()
        let sessions = SessionsModel(live: false)
        sessions.sessions = [
            ("Refactor auth middleware", 4), ("Fix flaky checkout test", 21),
            ("Release notes for v2.3", 49), ("Migrate build to Swift 6", 33),
            ("Investigate memory leak", 74), ("Spike: streaming parser", 96),
        ].enumerated().map { i, s in
            CacheSession(session_id: "demo-\(i)", age_seconds: s.1 * 60, name: s.0, project: "demo")
        }
        sessions.keepAliveIDs = ["demo-0", "demo-2"]
        if consumption {
            sessions.showCosts = true
            sessions.costs = [
                ("Refactor auth middleware", 41.20, 6.8), ("Migrate build to Swift 6", 27.75, 4.6),
                ("Fix flaky checkout test", 12.40, 2.1), ("Release notes for v2.3", 6.15, 1.0),
                ("Investigate memory leak", 3.90, 0.6),
            ].enumerated().map { i, c in
                CostSession(session_id: "demo-c\(i)", name: c.0, cost_usd: c.1, week_percent: c.2)
            }
        }
        return PopoverView(model: model, pin: PinController(), sessions: sessions,
                           dock: DockController.shared)
    }

    /// GitHub's social preview card: 1280×640 once rendered at 2x.
    static func socialPreview(_ usage: Usage) -> some View {
        let model = UsageModel(live: false, history: usage.history)
        model.windows = usage.windows
        let badges: NSImage = { model.menuBarStyle = .badges; return model.menuBarImage }()
        return HStack(spacing: 30) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable().interpolation(.high).frame(width: 48, height: 48)
                    Text("Claudius").font(.system(size: 36, weight: .bold, design: .rounded))
                }
                Text("Your Claude Code limits,\nright in the menu bar.")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Image(nsImage: badges)
                    Text("Forecasts · alerts · 100% local")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            LimitsCard(model: model, now: Date())
                .frame(width: 270)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: NSColor(white: 0.15, alpha: 1))))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        }
        .padding(.horizontal, 40)
        .frame(width: 640, height: 320)
        .background(LinearGradient(
            colors: [Color(red: 0.10, green: 0.09, blue: 0.13), Color(red: 0.22, green: 0.13, blue: 0.09)],
            startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    static func menuBar(_ usage: Usage) -> some View {
        let model = UsageModel(live: false, history: usage.history)
        model.windows = usage.windows
        return HStack(spacing: 30) {
            ForEach(MenuBarStyle.allCases) { style in
                VStack(spacing: 8) {
                    Image(nsImage: { model.menuBarStyle = style; return model.menuBarImage }())
                    Text(style.title).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }
}
