import XCTest
@testable import Strand

/// Pins the 4×4 interval session: the phase sequence, where each phase starts and ends on the workout's
/// own clock, the climb grace at the start of each work block, and the cue (wrist, sound, copy) at each
/// phase change.
final class IntervalPlanTests: XCTestCase {

    private let plan = IntervalPlan.fourByFour

    // MARK: - Schedule

    func testFourByFourIsFourWorkBlocksWithRestsBetween() {
        XCTAssertEqual(plan.phases.map(\.kind), [.work, .rest, .work, .rest, .work, .rest, .work])
        XCTAssertEqual(plan.phases.filter { $0.kind == .work }.map(\.round), [1, 2, 3, 4])
        XCTAssertEqual(plan.phases.filter { $0.kind == .rest }.map(\.round), [1, 2, 3])
        XCTAssertEqual(plan.totalSeconds, 28 * 60)
        XCTAssertEqual(IntervalPlan.fourByFourZone, 4)
    }

    func testPhaseBoundaries() {
        XCTAssertEqual(plan.phaseIndex(at: 0), 0)
        XCTAssertEqual(plan.phaseIndex(at: -5), 0)          // clock skew counts as the start
        XCTAssertEqual(plan.phaseIndex(at: 239.9), 0)
        XCTAssertEqual(plan.phaseIndex(at: 240), 1)         // rest 1 at 4:00
        XCTAssertEqual(plan.phaseIndex(at: 480), 2)         // work 2 at 8:00
        XCTAssertEqual(plan.phaseIndex(at: 1440), 6)        // work 4 at 24:00
        XCTAssertNil(plan.phaseIndex(at: 1680))             // done at 28:00
        XCTAssertEqual(plan.phases[0].remaining(at: 30), 210)
    }

    func testClimbGraceIsTheFirstMinuteOfEachWorkBlockOnly() {
        let work2 = plan.phases[2]
        XCTAssertTrue(plan.inClimbGrace(work2, at: work2.start + 59))
        XCTAssertFalse(plan.inClimbGrace(work2, at: work2.start + 60))
        XCTAssertFalse(plan.inClimbGrace(plan.phases[1], at: plan.phases[1].start + 5))
    }

    // MARK: - Cues

    func testEachPhaseChangeHasItsCue() {
        XCTAssertEqual(TargetZoneCues.intervalCue(enteringPhase: 0, of: plan), .go(round: 1))
        XCTAssertEqual(TargetZoneCues.intervalCue(enteringPhase: 1, of: plan), .rest(round: 1))
        XCTAssertEqual(TargetZoneCues.intervalCue(enteringPhase: 6, of: plan), .go(round: 4))
        XCTAssertEqual(TargetZoneCues.intervalCue(enteringPhase: nil, of: plan), .done)
    }

    func testWristCuesAreDistinct() {
        XCTAssertEqual(TargetZoneCues.buzzes(for: .go(round: 1)).map { $0.loops }, [3])
        XCTAssertEqual(TargetZoneCues.buzzes(for: .rest(round: 1)).map { $0.loops }, [2, 2])
        XCTAssertEqual(TargetZoneCues.buzzes(for: .done).map { $0.loops }, [5])
    }

    func testSpokenCuesAndTheirSoundFiles() {
        XCTAssertEqual(TargetZoneNotifier.voicePhrase(for: .below), "Raise")
        XCTAssertEqual(TargetZoneNotifier.voicePhrase(for: .enteredZone), "In the zone")
        XCTAssertEqual(TargetZoneNotifier.voicePhrase(for: .above), "Lower")
        XCTAssertEqual(TargetZoneNotifier.intervalVoicePhrase(for: .go(round: 2)), "Go")
        XCTAssertEqual(TargetZoneNotifier.intervalVoicePhrase(for: .rest(round: 2)), "Rest")
        XCTAssertEqual(TargetZoneNotifier.intervalVoicePhrase(for: .done), "Done")
        XCTAssertEqual(TargetZoneNotifier.voiceFileName(for: "In the zone"), "zone-voice-in-the-zone.caf")
        XCTAssertEqual(TargetZoneNotifier.voiceFileName(for: "Raise"), "zone-voice-raise.caf")
    }

    func testReachingTheZoneIsSilentOnThePhone() {
        XCTAssertTrue(TargetZoneCues.notifies(.below))
        XCTAssertTrue(TargetZoneCues.notifies(.above))
        XCTAssertFalse(TargetZoneCues.notifies(.enteredZone))
    }

    func testIntervalSoundsAndCopy() {
        XCTAssertEqual(TargetZoneNotifier.intervalSoundName(for: .go(round: 1)), "zone-go.wav")
        XCTAssertEqual(TargetZoneNotifier.intervalSoundName(for: .rest(round: 1)), "zone-rest.wav")
        XCTAssertEqual(TargetZoneNotifier.intervalSoundName(for: .done), "zone-done.wav")

        let go = TargetZoneNotifier.intervalCopy(.go(round: 2), zone: 4, plan: plan)
        XCTAssertTrue(go.title.contains("2") && go.title.contains("4"), go.title)
        let rest = TargetZoneNotifier.intervalCopy(.rest(round: 2), zone: 4, plan: plan)
        XCTAssertTrue(rest.body.contains("3"), "rest names the next interval: \(rest.body)")
    }
}
