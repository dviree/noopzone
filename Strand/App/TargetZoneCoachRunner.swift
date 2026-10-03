import Foundation
import Combine
import StrandAnalytics
import WhoopProtocol

// MARK: - TargetZoneCoachRunner
//
// The transport half of target-zone coaching ("stay in Zone 2"): the pure `TargetZoneCoach` decides WHAT
// should happen; this object is the only place that touches a clock, the live HR stream, the strap buzz and
// the phone notification. It runs only while a recorded workout is active AND the wearer picked a target
// zone, and is owned by `AppModel`, which starts and stops it with the workout.
//
// Inputs, honestly gated: the smoothed `AppModel.bpm`, but only while a raw sample arrived within
// `staleAfterSec`, the strap is bonded and worn, and the workout is not paused. Anything else is fed to the
// engine as nil, which never coaches.
//
// Wrist vocabulary reuses `LiveSessionHaptics` so the feel matches Live Sessions:
//   • below the zone → `push`    (two light taps)
//   • above the zone → `easeOff` (three heavier taps)
//   • reached it     → one short tap (the lightest buzz there is)

/// Which target zones the coach offers, and how a stored value resolves to one.
enum TargetZonePrefs {
    /// The zones a workout can be coached toward. Zone 1 is recovery (nothing to coach) and Zone 5 is
    /// already covered by the HR-zone coaching's "ease off" buzz.
    static let selectableZones = [2, 3, 4]

    /// A stored value → a selectable zone, or 0 (off) for anything else.
    static func resolve(_ raw: Int) -> Int {
        selectableZones.contains(raw) ? raw : 0
    }

    /// Picker label for a stored value: "Off" or "Zone N".
    static func label(_ zone: Int) -> String {
        zone == 0 ? String(localized: "Off") : String(localized: "Zone \(zone)")
    }
}

/// The pure halves of the runner: which reading may be coached on, and how each feedback feels on the wrist.
enum TargetZoneCues {
    /// A sample older than this is not coached on (the strap went quiet, the wearer is between readings).
    static let staleAfterSec: TimeInterval = 8

    /// The reading the engine may coach on, or nil: a current smoothed bpm, a raw sample within
    /// `staleAfterSec`, a bonded strap on the wrist, and a workout that is not paused.
    static func coachableReading(bpm: Int?, lastSampleAt: Date?, now: Date,
                                 bonded: Bool, worn: Bool, paused: Bool) -> Int? {
        guard let bpm, bonded, worn, !paused,
              let at = lastSampleAt, now.timeIntervalSince(at) <= staleAfterSec else { return nil }
        return bpm
    }

    /// The wrist pattern for a feedback. Reuses the Live Sessions vocabulary; the in-zone confirmation is a
    /// single short pulse — enough to feel, light enough not to read as a warning.
    static func pulses(for feedback: TargetZoneCoach.Feedback) -> [HapticClock.Pulse] {
        switch feedback {
        case .below: return LiveSessionHaptics.pulses(for: .push)
        case .above: return LiveSessionHaptics.pulses(for: .easeOff)
        case .enteredZone:
            // One of `push`'s light taps on its own (trailing gap trimmed): the lightest buzz in the vocabulary.
            return LiveSessionHaptics.pulses(for: .push).prefix(1).map {
                HapticClock.Pulse(durationMs: $0.durationMs, gapMs: 0)
            }
        }
    }
}

@MainActor
final class TargetZoneCoachRunner: ObservableObject {

    /// See `LiveSessionRunner.timerToleranceSec`: elapsed math uses the wall clock, so a coalesced tick
    /// changes nothing but when the screen refreshes.
    static let timerToleranceSec: TimeInterval = 0.1

    // MARK: Published state (the workout screen's coaching card reads ONLY these)

    /// The zone being coached toward, or nil when the coach is off.
    @Published private(set) var zone: Int?
    /// The bpm interval being coached toward — the same `HRZoneSet` band every zone readout shows.
    @Published private(set) var config: TargetZoneCoach.Config?
    /// The committed state, nil until the first one is committed.
    @Published private(set) var state: TargetZoneCoach.State?
    /// Seconds spent in the target zone this workout (with a live reading).
    @Published private(set) var inZoneSeconds: Int = 0
    /// False while the engine is being fed no reading.
    @Published private(set) var hasReading = false

    var isActive: Bool { zone != nil }

    // MARK: Session wiring

    private var engine: TargetZoneCoach?
    private var timer: Timer?
    private var sinks = Set<AnyCancellable>()
    private weak var model: AppModel?
    private var lastSampleAt: Date?
    /// When the in-flight pulse walk finishes; a cue arriving before then skips the wrist (never queued).
    private var hapticWalkUntil = Date.distantPast

    deinit { timer?.invalidate() }

    // MARK: - Start / stop

    /// Begin coaching toward `zone` of the profile's zone set. A no-op when the zone is not selectable or the
    /// zone set has no usable band for it. Restarting (a new zone mid-workout) resets the time in zone,
    /// because "time in Zone 3" must not include minutes spent coaching toward Zone 2.
    func start(zone: Int, zoneSet: HRZoneSet, model: AppModel) {
        stop()
        guard TargetZonePrefs.resolve(zone) != 0,
              let config = TargetZoneCoach.Config.forZone(zone, in: zoneSet) else { return }
        self.model = model
        self.zone = zone
        self.config = config
        engine = TargetZoneCoach(config: config)
        // A sample that predates the session must not count as fresh.
        lastSampleAt = nil

        model.live.$heartRate
            .sink { [weak self] hr in
                guard let self, hr != nil else { return }
                self.lastSampleAt = Date()
                // Pocket-the-phone survival, as in LiveSessionRunner: a suspended app stops firing the
                // Timer, but CoreBluetooth keeps delivering HR notifies, so tick on arrival too. Deferred to
                // the next main-actor turn so `AppModel.bpm` has folded this sample in first.
                Task { @MainActor [weak self] in self?.tick() }
            }
            .store(in: &sinks)

        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = Self.timerToleranceSec
        timer = t
    }

    /// Stop coaching and clear the published state. Safe to call when not running.
    func stop() {
        timer?.invalidate()
        timer = nil
        sinks.removeAll()
        engine = nil
        model = nil
        lastSampleAt = nil
        hapticWalkUntil = .distantPast
        if zone != nil { zone = nil }
        if config != nil { config = nil }
        if state != nil { state = nil }
        if inZoneSeconds != 0 { inZoneSeconds = 0 }
        if hasReading { hasReading = false }
    }

    // MARK: - Tick

    private func tick() {
        guard let model, var engine, let zone else { return }
        let now = Date()
        let out = engine.update(now: Int(now.timeIntervalSince1970), bpm: TargetZoneCues.coachableReading(
            bpm: model.bpm, lastSampleAt: lastSampleAt, now: now,
            bonded: model.live.bonded, worn: model.live.worn,
            paused: model.activeWorkout?.isPaused ?? true))
        self.engine = engine

        // Publish only what changed: this runs every second and on every sample.
        if state != out.state { state = out.state }
        let secs = Int(out.inZoneSeconds)
        if inZoneSeconds != secs { inZoneSeconds = secs }
        let reading = !out.noReading
        if hasReading != reading { hasReading = reading }

        if let feedback = out.feedback {
            deliver(feedback, zone: zone, model: model, notify: model.behavior.targetZoneNotifications)
        }
    }

    // MARK: - Feedback → wrist + phone

    private func deliver(_ feedback: TargetZoneCoach.Feedback, zone: Int, model: AppModel, notify: Bool) {
        // #haptics (#1115): a workout cue, gated like the workout start/end buzz. Only the wrist is gated;
        // the notification follows its own toggle.
        if HapticPrefs.enabled(HapticPrefs.workout) {
            walk(TargetZoneCues.pulses(for: feedback), model: model)
        }
        if notify {
            TargetZoneNotifier.post(feedback, zone: zone)
        }
    }

    /// Walk a pulse list out through the strap the way `LiveSessionRunner.fire` does: each pulse is the
    /// existing `AppModel.buzz(loops:)` (bond-gated by the BLE layer), weighted by `isLong` (long = 2 loops,
    /// short = 1). Drop-tolerant: a walk still in flight means this one is skipped, because overlapping
    /// walks land on the wrist as one mush.
    private func walk(_ pulses: [HapticClock.Pulse], model: AppModel) {
        let nowDate = Date()
        guard nowDate >= hapticWalkUntil, !pulses.isEmpty else { return }
        var offsetMs = 0
        for pulse in pulses {
            let loops: UInt8 = pulse.isLong ? 2 : 1
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(offsetMs)) { [weak model] in
                model?.buzz(loops: loops)
            }
            offsetMs += pulse.durationMs + pulse.gapMs
        }
        hapticWalkUntil = nowDate.addingTimeInterval(Double(offsetMs) / 1000)
    }
}
