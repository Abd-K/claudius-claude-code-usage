import SwiftUI
import AppKit
import ImageIO

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
        Reel.write(to: out.appendingPathComponent("demo.gif"))
    }

    /// Draws a view on a popover-like card and writes it as a PNG.
    @MainActor static func snap<V: View>(_ view: V, dark: Bool, framed: Bool = true, to url: URL) {
        guard let rep = render(view.modifier(PopoverCard(dark: dark, visible: framed)), dark: dark)
        else { return }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote \(url.lastPathComponent) \(rep.pixelsWide)x\(rep.pixelsHigh)")
    }

    /// Renders a view offscreen at a fixed scale — 2x by default, whatever screen
    /// this runs on, so the README stays sharp.
    @MainActor static func render<V: View>(_ view: V, dark: Bool, scale: CGFloat = 2,
                                           settle: TimeInterval = 0.5) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: view)
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
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        host.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }
}

/// The popover's own look: a rounded dark or light card with a hairline edge.
struct PopoverCard: ViewModifier {
    let dark: Bool
    var visible = true
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: NSColor(white: dark ? 0.16 : 0.965, alpha: visible ? 1 : 0))))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(visible ? (dark ? 0.18 : 0.10) : 0), lineWidth: 0.5))
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

// MARK: - Demo reel

/// The README's animated demo: limits draining toward a forecast, the low alert,
/// the limited banner, the limit coming back, then the three menu-bar styles.
@MainActor enum Reel {
    typealias Point = (session: Double, sessionReset: TimeInterval, weekly: Double,
                       weeklyReset: TimeInterval, fable: Double)
    static let healthy: Point = (38, 2 * 3600 + 14 * 60, 29, 4 * 86_400 + 17 * 3600, 12)
    static let tight: Point = (86, 2 * 3600 + 4 * 60, 62, 3 * 86_400 + 9 * 3600, 41)
    static let limited: Point = (100, 47 * 60, 78, 2 * 86_400 + 6 * 3600, 55)
    static let back: Point = (0, 5 * 3600, 79, 2 * 86_400 + 5 * 3600, 55)

    static func mix(_ a: Point, _ b: Point, _ t: Double) -> Point {
        func m(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        return (m(a.0, b.0), m(a.1, b.1), m(a.2, b.2), m(a.3, b.3), m(a.4, b.4))
    }

    static func usage(_ p: Point, blocked: Bool = false) -> Demo.Usage {
        Demo.usage(session: (p.session.rounded(), p.sessionReset), weekly: (p.weekly.rounded(), p.weeklyReset),
                   fable: p.fable.rounded(), sessionBlocked: blocked)
    }

    static func write(to url: URL) {
        var frames: [(CGImage, Double)] = []
        func add(_ u: Demo.Usage, open: Bool = true, style: MenuBarStyle = .badges,
                 alert: (String, String)? = nil, hold: Double) {
            let scene = DemoScene(usage: u, open: open, style: style, alert: alert)
            if let img = Snapshot.render(scene, dark: true, scale: 1.5, settle: 0.2)?.cgImage {
                frames.append((img, hold))
            }
        }
        let clock = { (s: TimeInterval) in Fmt.clock(Date().addingTimeInterval(s)) }

        add(usage(healthy), hold: 1.8)
        for i in 1...10 { add(usage(mix(healthy, tight, Double(i) / 10)), hold: 0.08) }
        add(usage(tight), hold: 2.6)
        add(usage(tight), open: false,
            alert: ("5-hour limit running low", "14% left · resets \(clock(tight.sessionReset))"), hold: 2.4)
        for i in 1...5 { add(usage(mix(tight, limited, Double(i) / 6)), hold: 0.08) }
        add(usage(limited, blocked: true), hold: 2.6)
        add(usage(back), open: false, alert: ("5-hour limit is back", "100% available"), hold: 2.2)
        for style in MenuBarStyle.allCases { add(usage(back), open: false, style: style, hold: 1.1) }

        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString,
                                                         frames.count, nil) else { return }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary:
            [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (img, hold) in frames {
            CGImageDestinationAddImage(dest, img, [kCGImagePropertyGIFDictionary:
                [kCGImagePropertyGIFDelayTime: hold, kCGImagePropertyGIFUnclampedDelayTime: hold]] as CFDictionary)
        }
        CGImageDestinationFinalize(dest)
        print("wrote \(url.lastPathComponent) \(frames.count) frames")
    }
}

/// A desktop corner: wallpaper, a menu bar with Claudius in it, and either the
/// open panel hanging from it or a notification banner.
struct DemoScene: View {
    let usage: Demo.Usage
    let open: Bool
    let style: MenuBarStyle
    let alert: (String, String)?

    var body: some View {
        let model = UsageModel(live: false, history: usage.history)
        model.windows = usage.windows
        model.menuBarStyle = style
        return ZStack(alignment: .topTrailing) {
            LinearGradient(colors: [Color(red: 0.10, green: 0.09, blue: 0.14),
                                    Color(red: 0.24, green: 0.14, blue: 0.10)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 14) {
                    Image(systemName: "apple.logo")
                    Text("Finder").fontWeight(.bold)
                    Text("File")
                    Text("Edit")
                    Text("View")
                    Spacer()
                    Image(nsImage: model.menuBarImage)
                        .padding(.horizontal, 4)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(Color.white.opacity(open ? 0.18 : 0)))
                    Image(systemName: "wifi")
                    Image(systemName: "battery.75percent")
                    Text("Mon 9:41")
                }
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 26)
                .background(Color.black.opacity(0.35))
                if open {
                    Demo.popover(usage)
                        .modifier(PopoverCard(dark: true))
                        .compositingGroup()   // one shadow for the card, not one per glyph
                        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
                        .padding(.trailing, 108)
                }
            }
            if let alert {
                HStack(alignment: .top, spacing: 10) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable().interpolation(.high).frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(alert.0).font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text("now").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Text(alert.1).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .frame(width: 330)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(white: 0.2)))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                .compositingGroup()
                .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
                .padding(.top, 36)
                .padding(.trailing, 12)
            }
        }
        .frame(width: 600, height: 700, alignment: .top)
    }
}
