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
// Inputs, honestly gated: the smoothed `AppModel.bpm` (nil once the live heart rate is stale or gone), but
// only while the strap is worn and the workout is not paused. Anything else is fed to the engine as nil,
// which never coaches.
//
// Wrist vocabulary reuses `LiveSessionHaptics` so the feel matches Live Sessions:
//   • below the zone → `push`    (two light taps)
//   • above the zone → `easeOff` (three heavier taps)
//   • reached it     → one short tap (the lightest buzz there is)
//
// With an `IntervalPlan` (4×4) the zone coaching runs only inside WORK blocks; each phase change gets its
// own cue instead, matching the Interval timer's convention: one strong 3-loop buzz to GO, two long buzzes
// to REST, one long 5-loop buzz when the session is done.

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
    /// The reading the engine may coach on, or nil: the smoothed `AppModel.bpm` while the strap is on the
    /// wrist and the workout is not paused.
    ///
    /// Freshness is deliberately NOT judged here. `AppModel.bpm` already goes nil when the live heart rate
    /// does (`LiveState`'s 10 s silence timer, a disconnect, wrist-off), and that is the one place the app
    /// decides a reading is current. An earlier version timed its own freshness off `live.$heartRate`
    /// emissions, but the WHOOP path only writes `heartRate` when the value CHANGES, so a steady heart rate
    /// read as "no reading" after a few seconds, every debounce restarted, and no cue was ever sent.
    static func coachableReading(bpm: Int?, worn: Bool, paused: Bool) -> Int? {
        guard let bpm, worn, !paused else { return nil }
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

    /// The cue at an interval phase change.
    enum IntervalCue: Equatable {
        case go(round: Int)
        case rest(round: Int)
        case done
    }

    /// The cue for entering phase `index` of `plan` (nil = the session is complete).
    static func intervalCue(enteringPhase index: Int?, of plan: IntervalPlan) -> IntervalCue {
        guard let index, plan.phases.indices.contains(index) else { return .done }
        let phase = plan.phases[index]
        switch phase.kind {
        case .work: return .go(round: phase.round)
        case .rest: return .rest(round: phase.round)
        }
    }

    /// The strap buzzes for an interval cue: (loops, milliseconds to the next buzz). Same convention as the
    /// Interval timer: a strong cue into work, a softer double into rest, a long one at the end.
    static func buzzes(for cue: IntervalCue) -> [(loops: UInt8, afterMs: Int)] {
        switch cue {
        case .go: return [(3, 0)]
        case .rest: return [(2, 900), (2, 0)]
        case .done: return [(5, 0)]
        }
    }
}

@MainActor
final class TargetZoneCoachRunner: ObservableObject {

    /// See `LiveSessionRunner.timerToleranceSec`: elapsed math uses the wall clock, so a coalesced tick
    /// changes nothing but when the screen refreshes.
    static let timerToleranceSec: TimeInterval = 0.1
    /// How long an interval cue holds the wrist, so a zone cue in the same second cannot overlap it.
    static let intervalCueHoldSec: TimeInterval = 2.5

    // MARK: Published state (the workout screen's coaching card reads ONLY these)

    /// The zone being coached toward, or nil when the coach is off.
    @Published private(set) var zone: Int?
    /// The bpm interval being coached toward — the same `HRZoneSet` band every zone readout shows.
    @Published private(set) var config: TargetZoneCoach.Config?
    /// The committed state, nil until the first one is committed (and outside work blocks).
    @Published private(set) var state: TargetZoneCoach.State?
    /// Seconds spent in the target zone this workout (with a live reading).
    @Published private(set) var inZoneSeconds: Int = 0
    /// False while the engine is being fed no reading.
    @Published private(set) var hasReading = false
    /// The interval session, when this is a 4×4 rather than steady zone training.
    @Published private(set) var plan: IntervalPlan?
    /// The current interval phase; nil before the first tick and once the session is complete.
    @Published private(set) var phase: IntervalPlan.Phase?
    /// Whole seconds left in the current phase.
    @Published private(set) var phaseRemaining: Int = 0
    /// Whole seconds left in the whole interval session (to the end of the last work block).
    @Published private(set) var sessionRemaining: Int = 0
    /// True once every work block of the plan has run.
    @Published private(set) var intervalsDone = false

    var isActive: Bool { zone != nil }

    // MARK: Session wiring

    private var engine: TargetZoneCoach?
    private var timer: Timer?
    private var sinks = Set<AnyCancellable>()
    private weak var model: AppModel?
    /// When the in-flight pulse walk finishes; a cue arriving before then skips the wrist (never queued).
    private var hapticWalkUntil = Date.distantPast
    /// The phase index the last tick saw; `.none` (outer nil) until the first tick.
    private var lastPhaseIndex: Int??
    /// In-zone seconds from work blocks already finished (each block gets a fresh engine).
    private var bankedInZoneSeconds: Double = 0

    deinit { timer?.invalidate() }

    // MARK: - Start / stop

    /// Begin coaching toward `zone` of the profile's zone set, optionally as an interval session. A no-op
    /// when the zone is not selectable or the zone set has no usable band for it. Restarting (a new zone
    /// mid-workout) resets the time in zone, because "time in Zone 3" must not include minutes spent
    /// coaching toward Zone 2.
    func start(zone: Int, zoneSet: HRZoneSet, model: AppModel, plan: IntervalPlan? = nil) {
        stop()
        guard TargetZonePrefs.resolve(zone) != 0,
              let config = TargetZoneCoach.Config.forZone(zone, in: zoneSet) else { return }
        self.model = model
        self.zone = zone
        self.config = config
        self.plan = plan
        engine = TargetZoneCoach(config: config)
        let mode = plan.map { " as \($0.rounds)x\(Int($0.workSeconds / 60)) intervals" } ?? ""
        model.live.append(log: AppModel.stamped(
            "Zone training: coaching Zone \(zone) (\(Int(config.lowerBpm))-\(Int(config.upperBpm)) bpm)\(mode)"))

        // Pocket-the-phone survival, as in LiveSessionRunner: a suspended app stops firing the Timer, but
        // CoreBluetooth keeps delivering packets, so tick on each one too. R-R arrives with every packet even
        // when the heart rate itself does not change (the WHOOP path only writes `heartRate` on a change).
        // Deferred to the next main-actor turn so `AppModel.bpm` has folded the sample in first.
        Publishers.Merge(model.live.$heartRate.map { _ in () }, model.live.$rr.map { _ in () })
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.tick() }
            }
            .store(in: &sinks)

        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = Self.timerToleranceSec
        timer = t
        tick()
    }

    /// Stop coaching and clear the published state. Safe to call when not running.
    func stop() {
        timer?.invalidate()
        timer = nil
        sinks.removeAll()
        engine = nil
        model = nil
        hapticWalkUntil = .distantPast
        lastPhaseIndex = .none
        bankedInZoneSeconds = 0
        if zone != nil { zone = nil }
        if config != nil { config = nil }
        if state != nil { state = nil }
        if inZoneSeconds != 0 { inZoneSeconds = 0 }
        if hasReading { hasReading = false }
        if plan != nil { plan = nil }
        if phase != nil { phase = nil }
        if phaseRemaining != 0 { phaseRemaining = 0 }
        if sessionRemaining != 0 { sessionRemaining = 0 }
        if intervalsDone { intervalsDone = false }
    }

    // MARK: - Tick

    private func tick() {
        guard let model, let zone, let config, engine != nil else { return }
        let now = Date()
        var reading = TargetZoneCues.coachableReading(
            bpm: model.bpm, worn: model.live.worn, paused: model.activeWorkout?.isPaused ?? true)

        if let plan {
            let elapsed = model.activeWorkout?.elapsed(at: now) ?? 0
            let index = plan.phaseIndex(at: elapsed)
            if lastPhaseIndex != .some(index) {
                enterPhase(index, of: plan, zone: zone, config: config, model: model)
            }
            let current = index.map { plan.phases[$0] }
            if phase != current { phase = current }
            let left = Int(current?.remaining(at: elapsed).rounded(.up) ?? 0)
            if phaseRemaining != left { phaseRemaining = left }
            let total = Int(max(0, plan.totalSeconds - max(0, elapsed)).rounded(.up))
            if sessionRemaining != total { sessionRemaining = total }
            if intervalsDone != (index == nil) { intervalsDone = index == nil }

            // Rest and after the last block: no zone coaching at all, only the time.
            guard let current, current.kind == .work else {
                if state != nil { state = nil }
                let hasNow = reading != nil
                if hasReading != hasNow { hasReading = hasNow }
                return
            }
            // The climb: a reading below the zone early in a work block is withheld, so it neither commits
            // "below" nor says "increase" while the heart rate is still on its way up. Above-zone and
            // in-zone readings pass, so "decrease" still works from the first second.
            if plan.inClimbGrace(current, at: elapsed), let r = reading, engine?.classify(Double(r)) == .below {
                reading = nil
            }
        }

        guard var engine else { return }
        let out = engine.update(now: Int(now.timeIntervalSince1970), bpm: reading)
        self.engine = engine

        // Publish only what changed: this runs every second and on every sample.
        if state != out.state { state = out.state }
        let secs = Int(bankedInZoneSeconds + out.inZoneSeconds)
        if inZoneSeconds != secs { inZoneSeconds = secs }
        let hasNow = plan == nil ? !out.noReading : model.bpm != nil
        if hasReading != hasNow { hasReading = hasNow }

        if let feedback = out.feedback, let bpm = reading {
            deliver(feedback, zone: zone, bpm: bpm, model: model, notify: model.behavior.targetZoneNotifications)
        }
    }

    /// A phase change in an interval session: a fresh engine for each work block (so a state committed in
    /// the last block, or its cooldown, does not carry into this one), and the cue for the new phase.
    private func enterPhase(_ index: Int?, of plan: IntervalPlan, zone: Int, config: TargetZoneCoach.Config,
                            model: AppModel) {
        lastPhaseIndex = .some(index)
        if let engine { bankedInZoneSeconds += engine.inZoneSeconds }
        engine = TargetZoneCoach(config: config)

        let cue = TargetZoneCues.intervalCue(enteringPhase: index, of: plan)
        let notify = model.behavior.targetZoneNotifications
        let wristOn = HapticPrefs.enabled(HapticPrefs.workout)
        if wristOn { walkBuzzes(TargetZoneCues.buzzes(for: cue), model: model) }
        if notify { TargetZoneNotifier.postInterval(cue, zone: zone, plan: plan) }

        let what: String
        switch cue {
        case .go(let round): what = "go, interval \(round) of \(plan.rounds)"
        case .rest(let round): what = "rest after interval \(round)"
        case .done: what = "intervals done"
        }
        model.live.append(log: AppModel.stamped(
            "Zone training: \(what); wrist cue \(wristOn ? "requested" : "off (workout haptics disabled)"); "
            + "notification \(notify ? "on" : "off")"))
    }

    // MARK: - Feedback → wrist + phone

    private func deliver(_ feedback: TargetZoneCoach.Feedback, zone: Int, bpm: Int, model: AppModel,
                         notify: Bool) {
        // #haptics (#1115): a workout cue, gated like the workout start/end buzz. Only the wrist is gated;
        // the notification follows its own toggle.
        let wristOn = HapticPrefs.enabled(HapticPrefs.workout)
        let walked = wristOn ? walk(TargetZoneCues.pulses(for: feedback), model: model) : false
        if notify {
            TargetZoneNotifier.post(feedback, zone: zone)
        }
        // Rare-event evidence, always on: one line per cue (a few per workout), saying only what this side
        // did — a buzz REQUESTED is not a buzz felt, and `send` logs its own refusal if the link is down.
        let what: String
        switch feedback {
        case .below: what = "below"
        case .enteredZone: what = "entered"
        case .above: what = "above"
        }
        let wrist = !wristOn ? "wrist cue off (workout haptics disabled)"
            : walked ? "wrist cue requested" : "wrist cue skipped (previous one still playing)"
        model.live.append(log: AppModel.stamped(
            "Zone training: \(what) Zone \(zone) at \(bpm) bpm; \(wrist); notification \(notify ? "on" : "off")"))
    }

    /// Walk a pulse list out through the strap the way `LiveSessionRunner.fire` does: each pulse is the
    /// existing `AppModel.buzz(loops:)` (bond-gated by the BLE layer), weighted by `isLong` (long = 2 loops,
    /// short = 1). Drop-tolerant: a walk still in flight means this one is skipped, because overlapping
    /// walks land on the wrist as one mush.
    @discardableResult
    private func walk(_ pulses: [HapticClock.Pulse], model: AppModel) -> Bool {
        let nowDate = Date()
        guard nowDate >= hapticWalkUntil, !pulses.isEmpty else { return false }
        var offsetMs = 0
        for pulse in pulses {
            let loops: UInt8 = pulse.isLong ? 2 : 1
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(offsetMs)) { [weak model] in
                model?.buzz(loops: loops)
            }
            offsetMs += pulse.durationMs + pulse.gapMs
        }
        hapticWalkUntil = nowDate.addingTimeInterval(Double(offsetMs) / 1000)
        return true
    }

    /// Fire an interval cue's buzzes. Unlike a zone cue it is never skipped — a missed GO is a missed
    /// interval — and it holds the wrist for `intervalCueHoldSec` so a zone cue cannot land on top of it.
    private func walkBuzzes(_ buzzes: [(loops: UInt8, afterMs: Int)], model: AppModel) {
        var offsetMs = 0
        for buzz in buzzes {
            let loops = buzz.loops
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(offsetMs)) { [weak model] in
                model?.buzz(loops: loops)
            }
            offsetMs += buzz.afterMs
        }
        hapticWalkUntil = Date().addingTimeInterval(Self.intervalCueHoldSec + Double(offsetMs) / 1000)
    }
}
