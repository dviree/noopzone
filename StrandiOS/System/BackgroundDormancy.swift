#if os(iOS)
import Foundation
import UIKit
import Combine
import BackgroundTasks

/// "Only run during training": while NOOP is in the background with no workout running, it sleeps.
///
/// Asleep means the app gives iOS no reason to keep it running or to wake it: the strap link is released
/// with no scan and no standing reconnect (`BLEManager.setDormant`), every pending background task
/// request is cancelled, and HealthKit stops delivering in the background. With nothing left to deliver,
/// iOS suspends the process, so the offload timer, the keep-alive and the periodic analysis stop with it.
/// The strap keeps recording by itself; opening NOOP wakes the link and the usual foreground sync pulls
/// what it banked.
///
/// A workout is the exception. Started in the foreground, it keeps the strap connected when the phone is
/// locked, so heart rate keeps streaming to the zone coach. When it ends while the app is in the
/// background, NOOP falls asleep then.
///
/// On by default. Off restores the old always-connected behaviour.
@MainActor
final class BackgroundDormancy {
    /// How long the strap may keep syncing after the app is left. An offload that has not finished by
    /// then resumes from where the strap left it on the next open; the strap only trims what was
    /// acknowledged.
    static let maxSyncGraceSeconds: TimeInterval = 60

    private weak var model: AppModel?
    private weak var health: HealthKitBridge?
    private var inBackground = false
    private var sinks = Set<AnyCancellable>()
    private var pendingSleep: AnyCancellable?
    /// When the app last came to the foreground (epoch seconds, as `LiveState.lastSyncedAt`).
    private var openedAt: TimeInterval = 0
    /// Asks iOS for running time through the sync minute, so the 2 s check fires even between packets.
    private var graceTask: UIBackgroundTaskIdentifier = .invalid

    func attach(model: AppModel, health: HealthKitBridge) {
        self.model = model
        self.health = health
        // A workout starting or ending while the app is in the background re-decides at once.
        model.$activeWorkout
            .map { $0 != nil }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                // `@Published` emits in willSet; re-read on the next turn, once the value has landed.
                Task { @MainActor [weak self] in self?.reevaluate() }
            }
            .store(in: &sinks)
        // Relaunched in the background while asleep: launch has just scheduled its usual requests.
        if model.ble.dormant { cancelBackgroundWork() }
    }

    func appEnteredBackground() {
        inBackground = true
        reevaluate()
    }

    func appBecameActive() {
        inBackground = false
        openedAt = Date().timeIntervalSince1970
        reevaluate()
    }

    /// Re-read the setting, e.g. after the user flips it.
    func settingChanged() {
        reevaluate()
    }

    private func reevaluate() {
        guard let model else { return }
        if DormancyPolicy.shouldSleep(enabled: DormancyPolicy.enabled, inBackground: inBackground,
                            workoutActive: model.activeWorkout != nil) {
            scheduleSleep()
        } else {
            pendingSleep = nil
            endGraceTask()
            wake()
        }
    }

    /// Leaving the app gives the strap up to `maxSyncGraceSeconds` to finish syncing what it banked while
    /// NOOP was asleep: sleep as soon as a sync has completed since the app was opened and none is
    /// running, or when the minute is up, whichever comes first. Checked every 2 s, only inside that
    /// minute.
    private func scheduleSleep() {
        guard let model, !model.ble.dormant, pendingSleep == nil else { return }
        if syncDone(model) { sleep(); return }
        model.live.append(log: AppModel.stamped(
            "Asleep within \(Int(Self.maxSyncGraceSeconds)) s: letting the strap finish syncing first"))
        let deadline = Date().addingTimeInterval(Self.maxSyncGraceSeconds)
        graceTask = UIApplication.shared.beginBackgroundTask(withName: "noop.syncBeforeSleep") { [weak self] in
            // iOS is taking the time back early: sleep now rather than be suspended still connected.
            MainActor.assumeIsolated {
                self?.pendingSleep = nil
                self?.sleepIfStillWanted()
                self?.endGraceTask()
            }
        }
        pendingSleep = Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .filter { [weak self] now in
                // Timer.publish on the main run loop delivers on the main thread.
                MainActor.assumeIsolated {
                    guard let self, let model = self.model else { return true }
                    return now >= deadline || self.syncDone(model)
                }
            }
            .first()
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.pendingSleep = nil
                    self?.sleepIfStillWanted()
                    self?.endGraceTask()
                }
            }
    }

    private func endGraceTask() {
        guard graceTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(graceTask)
        graceTask = .invalid
    }

    private func syncDone(_ model: AppModel) -> Bool {
        DormancyPolicy.syncFinished(backfilling: model.live.backfilling, lastSyncedAt: model.live.lastSyncedAt,
                                    openedAt: openedAt, now: Date().timeIntervalSince1970)
    }

    private func sleepIfStillWanted() {
        guard let model, DormancyPolicy.shouldSleep(enabled: DormancyPolicy.enabled, inBackground: inBackground,
                                          workoutActive: model.activeWorkout != nil) else { return }
        sleep()
    }

    private func sleep() {
        guard let model, !model.ble.dormant else { return }
        model.ble.setDormant(true)
        cancelBackgroundWork()
    }

    private func cancelBackgroundWork() {
        BGTaskScheduler.shared.cancelAllTaskRequests()
        health?.suspendLiveDelivery()
    }

    private func wake() {
        guard let model, model.ble.dormant else { return }
        model.ble.setDormant(false)
        health?.enableLiveDelivery()
        // Launch is the only other place this is armed, and sleeping cancelled it.
        StaleBatteryBackgroundScheduler.schedule()
    }
}
#endif
