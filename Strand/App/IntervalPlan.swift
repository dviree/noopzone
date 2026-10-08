import Foundation

/// A Zone training interval session such as 4×4: WORK blocks, coached toward the target zone, alternating
/// with REST blocks that are left silent apart from the cue that opens them.
///
/// Pure: the current phase is a function of the workout's own pause-aware elapsed time
/// (`AppModel.ActiveWorkout.elapsed()`), never of a separate clock. Pausing the workout therefore pauses the
/// intervals, and a workout rehydrated after an OS kill resumes in the phase it was really in.
///
/// The session is `rounds` work blocks with a rest between each pair and none after the last, so a 4×4
/// with 4-minute rests runs W R W R W R W: 28 minutes, after which the coaching stops and the wearer
/// cools down at will.
struct IntervalPlan: Equatable {
    enum Kind: Equatable {
        case work
        case rest
    }

    struct Phase: Equatable {
        let kind: Kind
        /// 1-based. A rest carries the number of the work block it follows.
        let round: Int
        /// Seconds from the start of the workout.
        let start: TimeInterval
        let duration: TimeInterval

        var end: TimeInterval { start + duration }

        func remaining(at elapsed: TimeInterval) -> TimeInterval { max(0, end - elapsed) }
    }

    let rounds: Int
    let workSeconds: TimeInterval
    let restSeconds: TimeInterval
    /// How long into each work block a reading BELOW the zone is not coached on: the heart rate needs time
    /// to climb, and "increase" a few seconds after "go" says nothing the wearer does not know. A reading
    /// above the zone is coached from the first second.
    let climbGraceSeconds: TimeInterval

    /// Norwegian 4×4 as this wearer runs it: four 4-minute blocks in Zone 4, 4 minutes easy between them,
    /// no warm-up, one minute to climb.
    static let fourByFour = IntervalPlan(rounds: 4, workSeconds: 240, restSeconds: 240, climbGraceSeconds: 60)

    /// The zone a plan's work blocks are coached toward.
    static let fourByFourZone = 4

    /// Every phase in order: W1 R1 W2 R2 … W`rounds`.
    var phases: [Phase] {
        var out: [Phase] = []
        var t: TimeInterval = 0
        for round in 1...max(1, rounds) {
            out.append(Phase(kind: .work, round: round, start: t, duration: workSeconds))
            t += workSeconds
            if round < rounds {
                out.append(Phase(kind: .rest, round: round, start: t, duration: restSeconds))
                t += restSeconds
            }
        }
        return out
    }

    /// When the last work block ends.
    var totalSeconds: TimeInterval { phases.last?.end ?? 0 }

    /// Index into `phases` for an elapsed time, or nil once the session is complete. A negative elapsed
    /// (clock skew) counts as the very start.
    func phaseIndex(at elapsed: TimeInterval) -> Int? {
        let t = max(0, elapsed)
        return phases.firstIndex { t >= $0.start && t < $0.end }
    }

    /// True while a reading below the zone should be withheld from the coach at `elapsed`.
    func inClimbGrace(_ phase: Phase, at elapsed: TimeInterval) -> Bool {
        phase.kind == .work && elapsed - phase.start < climbGraceSeconds
    }
}
