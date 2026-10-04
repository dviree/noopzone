#if os(iOS)
import Foundation
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
    /// The longest an in-flight offload may hold off sleep. An offload that has not finished by then
    /// resumes from where the strap left it on the next open; the strap only trims what was acknowledged.
    static let maxSyncGraceSeconds: TimeInterval = 60

    private weak var model: AppModel?
    private weak var health: HealthKitBridge?
    private var inBackground = false
    private var sinks = Set<AnyCancellable>()
    private var pendingSleep: AnyCancellable?

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
            wake()
        }
    }

    /// Sleep now, or as soon as an offload in flight finishes (bounded by `maxSyncGraceSeconds`).
    private func scheduleSleep() {
        guard let model, !model.ble.dormant, pendingSleep == nil else { return }
        guard model.live.backfilling else { sleep(); return }
        model.live.append(log: AppModel.stamped(
            "Asleep soon: letting the strap sync in progress finish first (at most \(Int(Self.maxSyncGraceSeconds)) s)"))
        pendingSleep = model.live.$backfilling
            .filter { !$0 }
            .map { _ in () }
            .merge(with: Just(()).delay(for: .seconds(Self.maxSyncGraceSeconds), scheduler: RunLoop.main))
            .first()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.pendingSleep = nil
                self?.sleepIfStillWanted()
            }
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
