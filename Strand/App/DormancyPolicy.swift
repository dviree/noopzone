import Foundation

/// The rule behind "Only run during training" (iPhone): sleep while the app is in the background with no
/// workout running, if the setting is on. `BackgroundDormancy` (iOS target) applies it; kept here, in the
/// shared app code, so `StrandTests` can pin it.
enum DormancyPolicy {
    /// UserDefaults key of the setting. Absent reads as on.
    static let enabledKey = "noop.trainOnlyBackground"

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static func shouldSleep(enabled: Bool, inBackground: Bool, workoutActive: Bool) -> Bool {
        enabled && inBackground && !workoutActive
    }
}
