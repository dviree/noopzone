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

    /// How long a completed sync must stay completed before the strap is released: long enough for the
    /// gap between two slices of one offload (#755 auto-continue re-kicks after a completed slice), and
    /// for the debounced post-sync work (the 2 s rescore, the 3 s self-hosted push) to start.
    static let syncSettleSeconds: TimeInterval = 5

    /// Whether the sync after an open has finished: one completed since `openedAt` (epoch seconds), none
    /// running now, and nothing restarted for `syncSettleSeconds`.
    static func syncFinished(backfilling: Bool, lastSyncedAt: TimeInterval?, openedAt: TimeInterval,
                             now: TimeInterval) -> Bool {
        guard !backfilling, let synced = lastSyncedAt, synced >= openedAt else { return false }
        return now - synced >= syncSettleSeconds
    }
}
