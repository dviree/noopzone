import Foundation
import UserNotifications
import StrandAnalytics

// MARK: - Target-zone coaching notifications
//
// The phone half of target-zone coaching: each wrist cue the `TargetZoneCoachRunner` delivers is mirrored as
// a local notification, so a phone on an arm band or a bike mount says the same thing the strap just did.
// `NotificationPresenter` already presents banners while the app is in the foreground.
//
// Every cue uses ONE stable identifier: a new cue replaces the previous one in Notification Center instead of
// stacking a workout's worth of them. The cadence itself is the coach's (state changes, cooldown, reminder) —
// this file never decides when to post, only what to say.
//
// Permission follows the StrainTargetNotifier / BatteryNotifier idiom: asked once when the wearer turns the
// coaching on (`requestAuthorization`), only CHECKED when posting, so a workout never raises a system prompt.
enum TargetZoneNotifier {
    /// The one identifier every target-zone notification is posted under (replace-in-place).
    static let identifier = "target-zone-coach"

    /// Title + body for a feedback toward `zone`. NOOP's own wording.
    static func copy(_ feedback: TargetZoneCoach.Feedback, zone: Int) -> (title: String, body: String) {
        switch feedback {
        case .below:
            return (String(localized: "Below Zone \(zone)"),
                    String(localized: "Increase the intensity to get back into Zone \(zone)."))
        case .enteredZone:
            return (String(localized: "Zone \(zone)"),
                    String(localized: "You're in Zone \(zone). Hold this pace."))
        case .above:
            return (String(localized: "Above Zone \(zone)"),
                    String(localized: "Lower the intensity to get back into Zone \(zone)."))
        }
    }

    /// Ask up front, at the moment the wearer turns target-zone coaching on, so the system dialog never
    /// appears mid-workout. A no-op once the user has answered (the system does not prompt twice).
    static func requestAuthorization() {
        #if os(iOS)
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
        #endif
    }

    /// Post (or replace) the coaching notification. Only when the OS already authorized notifications — no
    /// second system prompt from here. No-op on macOS, matching the wrist alerts.
    static func post(_ feedback: TargetZoneCoach.Feedback, zone: Int) {
        #if os(iOS)
        let text = Self.copy(feedback, zone: zone)
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = text.title
            content.body = text.body
            content.sound = .default
            content.threadIdentifier = identifier
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
        #endif
    }

    /// Remove the last coaching notification once the workout ends, so a stale "Below Zone 2" does not
    /// outlive the session it was about.
    static func clear() {
        #if os(iOS)
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        #endif
    }
}
