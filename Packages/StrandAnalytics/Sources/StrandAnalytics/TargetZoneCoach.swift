import Foundation

// TargetZoneCoach.swift — the "stay in Zone N" coach for a live workout. Pure, deterministic, DB-free.
//
// The wearer picks ONE target zone (2, 3 or 4) for a workout. This engine watches the smoothed live heart
// rate against that zone's bpm interval — taken from the user's own `HRZoneSet`, never a hardcoded
// threshold — and decides when the wrist (and the phone) should say something:
//
//   • below the zone  → `.below`        ("give a bit more")
//   • reached it      → `.enteredZone`  ("you're in, hold this")
//   • above the zone  → `.above`        ("ease off")
//
// Like `LiveSessionEngine`, everything is a value type and time is passed in on every `update(now:bpm:)`,
// so a session replays deterministically from a synthetic trace with no clock, no BLE and no UI. The app's
// `TargetZoneCoachRunner` owns the clock, the strap buzz and the notification.
//
// A wrong buzz is worse than a missed one, so three mechanisms keep a heart rate that hovers on a zone edge
// from producing buzz–notification–buzz–notification:
//
//   1. Hysteresis — once the zone is committed, leaving it needs the reading to cross the edge by
//      `hysteresisBpm`. Entering the zone needs only the edge itself, so a reading hovering on the lower
//      bound settles IN the zone instead of flickering in and out of it.
//   2. Debounce — a new state must be seen on every reading for `debounceSec` before it is committed. One
//      stray sample, or a gap in the stream, restarts the wait.
//   3. Cooldown — the same feedback kind never fires twice within `cooldownSec`. A warning blocked by its
//      cooldown is held, not dropped: if the state still stands once the cooldown passes, it is sent then.
//      A blocked in-zone confirmation is simply skipped (a late "you're in" is noise).
//
// Feedback is emitted on a committed state CHANGE. While the state stays out of the zone, a reminder of
// the same warning is repeated every `reminderSec` (0 disables it). A nil reading — the stream is quiet,
// the strap is off the wrist, the workout is paused — never produces feedback, never accrues time in zone,
// and restarts any pending debounce.
public struct TargetZoneCoach {

    /// Where the committed heart rate sits relative to the target zone.
    public enum State: String, Equatable, Sendable {
        case below
        case inZone
        case above
    }

    /// What should be said, at most once per update. `nil` (silence) is by far the most common answer.
    public enum Feedback: Equatable, Sendable {
        case below
        case enteredZone
        case above

        fileprivate init(_ state: State) {
            switch state {
            case .below: self = .below
            case .inZone: self = .enteredZone
            case .above: self = .above
            }
        }
    }

    // MARK: - Config

    public struct Config: Equatable, Sendable {
        /// Inclusive lower bound of the target zone (bpm).
        public let lowerBpm: Double
        /// Exclusive upper bound of the target zone (bpm).
        public let upperBpm: Double
        /// Margin a committed state must be left by before it changes (bpm).
        public let hysteresisBpm: Double
        /// Seconds a new state must hold on every reading before it is committed.
        public let debounceSec: Int
        /// Minimum seconds between two feedbacks of the same kind.
        public let cooldownSec: Int
        /// Seconds after which an unchanged out-of-zone state is reminded again; 0 = never.
        public let reminderSec: Int
        /// Largest gap between two readings credited to time in zone (seconds).
        public let maxAccrualDtSec: Int
        /// A reading below this is a dropout artifact, not a heart rate.
        public let minPlausibleBpm: Int

        public static let defaultHysteresisBpm: Double = 3
        public static let defaultDebounceSec = 5
        public static let defaultCooldownSec = 60
        public static let defaultReminderSec = 120
        public static let defaultMaxAccrualDtSec = 5
        public static let defaultMinPlausibleBpm = 30

        public init(lowerBpm: Double,
                    upperBpm: Double,
                    hysteresisBpm: Double = Config.defaultHysteresisBpm,
                    debounceSec: Int = Config.defaultDebounceSec,
                    cooldownSec: Int = Config.defaultCooldownSec,
                    reminderSec: Int = Config.defaultReminderSec,
                    maxAccrualDtSec: Int = Config.defaultMaxAccrualDtSec,
                    minPlausibleBpm: Int = Config.defaultMinPlausibleBpm) {
            self.lowerBpm = lowerBpm
            self.upperBpm = upperBpm
            self.hysteresisBpm = max(0, hysteresisBpm)
            self.debounceSec = max(0, debounceSec)
            self.cooldownSec = max(0, cooldownSec)
            self.reminderSec = max(0, reminderSec)
            self.maxAccrualDtSec = max(0, maxAccrualDtSec)
            self.minPlausibleBpm = minPlausibleBpm
        }

        /// The config for zone `number` (1...5) of the user's zone set, or nil when the set has no such zone
        /// or the zone is degenerate. This is the only way the app builds one, so the coach's interval is
        /// always the same interval every zone readout shows.
        public static func forZone(_ number: Int, in set: HRZoneSet) -> Config? {
            guard let z = set.zones.first(where: { $0.number == number }),
                  z.lower.isFinite, z.upper.isFinite, z.lower > 0, z.upper > z.lower else { return nil }
            return Config(lowerBpm: z.lower, upperBpm: z.upper)
        }
    }

    // MARK: - Output

    public struct Output: Equatable, Sendable {
        /// The committed state, or nil before the first one has been committed.
        public let state: State?
        /// Feedback to deliver now, or nil.
        public let feedback: Feedback?
        /// Accumulated seconds with a committed in-zone state and a live reading.
        public let inZoneSeconds: Double
        /// True when this update carried no usable reading.
        public let noReading: Bool
    }

    // MARK: - State

    public let config: Config
    public private(set) var state: State?
    public private(set) var inZoneSeconds: Double = 0

    private var candidate: State?
    private var candidateSince: Int?
    /// The state the wearer was last told about (or silently acknowledged, for a skipped confirmation).
    private var announced: State?
    private var lastFeedbackTs: [State: Int] = [:]
    private var lastReadingTs: Int?

    public init(config: Config) {
        self.config = config
    }

    // MARK: - Update

    /// Feed one tick. `bpm` is the current smoothed live heart rate, or nil when there is none worth
    /// coaching on. Returns the committed state and at most one feedback.
    public mutating func update(now: Int, bpm: Int?) -> Output {
        guard let bpm, bpm >= config.minPlausibleBpm else {
            // No reading: no coaching, no accrual, and the debounce must start over on the next reading.
            candidate = nil
            candidateSince = nil
            lastReadingTs = nil
            return Output(state: state, feedback: nil, inZoneSeconds: inZoneSeconds, noReading: true)
        }

        // Accrue time in zone for the interval since the previous reading, under the state that held over it.
        if let last = lastReadingTs, state == .inZone {
            let dt = min(max(now - last, 0), config.maxAccrualDtSec)
            inZoneSeconds += Double(dt)
        }
        lastReadingTs = now

        // Debounce the classification into a committed state.
        let observed = classify(Double(bpm))
        if observed == state {
            candidate = nil
            candidateSince = nil
        } else {
            if candidate != observed {
                candidate = observed
                candidateSince = now
            }
            if let since = candidateSince, now - since >= config.debounceSec {
                state = observed
                candidate = nil
                candidateSince = nil
            }
        }

        return Output(state: state, feedback: decideFeedback(now: now), inZoneSeconds: inZoneSeconds,
                      noReading: false)
    }

    /// The state a reading points to, given the committed state. Only LEAVING the zone needs the edge
    /// crossed by the hysteresis margin; out of the zone (or before anything is committed) the plain
    /// interval decides, so coming back in needs nothing more than the zone's own edge.
    public func classify(_ bpm: Double) -> State {
        let margin = state == .inZone ? config.hysteresisBpm : 0
        if bpm < config.lowerBpm - margin { return .below }
        if bpm >= config.upperBpm + margin { return .above }
        return .inZone
    }

    private mutating func decideFeedback(now: Int) -> Feedback? {
        guard let state else { return nil }
        let coolingDown = lastFeedbackTs[state].map { now - $0 < config.cooldownSec } ?? false

        if state != announced {
            if !coolingDown {
                return emit(state, now: now)
            }
            // A confirmation that can't go out now is not worth sending late; a warning is held until the
            // cooldown passes (it fires then if the state still stands).
            if state == .inZone { announced = .inZone }
            return nil
        }

        // Unchanged and out of the zone: a periodic reminder.
        if state != .inZone, config.reminderSec > 0,
           let last = lastFeedbackTs[state], now - last >= max(config.reminderSec, config.cooldownSec) {
            return emit(state, now: now)
        }
        return nil
    }

    private mutating func emit(_ state: State, now: Int) -> Feedback {
        announced = state
        lastFeedbackTs[state] = now
        return Feedback(state)
    }
}
