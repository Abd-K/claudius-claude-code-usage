import Foundation
import UserNotifications

/// The few alerts worth interrupting for: a limit running low, a limit hit, and a
/// limit coming back. Each fires on a change between two readings, so launching
/// into a state that's already low stays quiet instead of repeating old news.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    /// "Running low" fires when a limit drops to this much left.
    static let lowPercent: Double = 20

    func start(requestingAccess: Bool) {
        UNUserNotificationCenter.current().delegate = self
        if requestingAccess { requestAccess() }
    }

    func requestAccess() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func compare(old: [UsageWindow], new: [UsageWindow]) {
        let before = Dictionary(old.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for w in new {
            guard let prev = before[w.name] else { continue }
            let back = w.resetDate.map { "Back at \(Fmt.clock($0))" } ?? ""
            if w.blocked && !prev.blocked {
                post("\(w.displayName) limit reached", back)
            } else if prev.blocked && !w.blocked {
                post("\(w.displayName) limit is back",
                     w.leftPercent.map { "\(Int($0.rounded()))% available" } ?? "")
            } else if !w.blocked, let l = w.leftPercent, let pl = prev.leftPercent,
                      l <= Self.lowPercent, pl > Self.lowPercent {
                let reset = w.resetDate.map { " · resets \(Fmt.clock($0))" } ?? ""
                post("\(w.displayName) limit running low", "\(Int(l.rounded()))% left\(reset)")
            }
        }
    }

    private func post(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// A menu-bar app counts as frontmost while its panel is open; show the banner
    /// anyway rather than letting the system swallow it.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
