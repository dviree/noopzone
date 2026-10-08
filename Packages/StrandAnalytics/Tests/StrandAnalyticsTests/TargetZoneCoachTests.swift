import XCTest
@testable import StrandAnalytics

/// Pins the target-zone coach state machine: classification, hysteresis at both edges, debounce, cooldown,
/// reminders, no-reading handling, and that feedback follows state CHANGES rather than samples.
final class TargetZoneCoachTests: XCTestCase {

    /// Zone 2 of a 200 bpm max-HR conventional set: [120, 140).
    private let zone2 = TargetZoneCoach.Config(lowerBpm: 120, upperBpm: 140, hysteresisBpm: 3,
                                               debounceSec: 5, cooldownSec: 60, reminderSec: 120)

    /// Feed one reading per second starting at `start`; returns every output.
    @discardableResult
    private func feed(_ coach: inout TargetZoneCoach, from start: Int, _ readings: [Int?]) -> [TargetZoneCoach.Output] {
        readings.enumerated().map { i, bpm in coach.update(now: start + i, bpm: bpm) }
    }

    private func repeated(_ bpm: Int?, _ seconds: Int) -> [Int?] { Array(repeating: bpm, count: seconds) }

    private func feedbacks(_ outs: [TargetZoneCoach.Output]) -> [TargetZoneCoach.Feedback] {
        outs.compactMap(\.feedback)
    }

    // MARK: - 1–3. Classification

    func test_below_zone_commits_below_and_says_so_once() {
        var c = TargetZoneCoach(config: zone2)
        let outs = feed(&c, from: 0, repeated(100, 20))
        XCTAssertEqual(c.state, .below)
        XCTAssertEqual(feedbacks(outs), [.below])
    }

    func test_in_zone_commits_in_zone_and_confirms_once() {
        var c = TargetZoneCoach(config: zone2)
        let outs = feed(&c, from: 0, repeated(130, 20))
        XCTAssertEqual(c.state, .inZone)
        XCTAssertEqual(feedbacks(outs), [.enteredZone])
    }

    func test_above_zone_commits_above_and_says_so_once() {
        var c = TargetZoneCoach(config: zone2)
        let outs = feed(&c, from: 0, repeated(155, 20))
        XCTAssertEqual(c.state, .above)
        XCTAssertEqual(feedbacks(outs), [.above])
    }

    func test_zone_edges_are_lower_inclusive_upper_exclusive() {
        var c = TargetZoneCoach(config: zone2)
        XCTAssertEqual(c.classify(119), .below)
        XCTAssertEqual(c.classify(120), .inZone)
        XCTAssertEqual(c.classify(139), .inZone)
        XCTAssertEqual(c.classify(140), .above)
        feed(&c, from: 0, repeated(120, 10))
        XCTAssertEqual(c.state, .inZone)
    }

    // MARK: - 4. Hysteresis at the lower edge

    func test_hysteresis_holds_in_zone_just_under_lower_edge() {
        var c = TargetZoneCoach(config: zone2)
        feed(&c, from: 0, repeated(130, 10))
        XCTAssertEqual(c.state, .inZone)
        // 118 and 117 are under the zone but within the 3 bpm margin: still in zone, nothing said.
        let hold = feed(&c, from: 10, repeated(118, 30) + repeated(117, 30))
        XCTAssertEqual(c.state, .inZone)
        XCTAssertTrue(feedbacks(hold).isEmpty)
        // 116 crosses the margin: below, once the debounce has passed.
        let drop = feed(&c, from: 70, repeated(116, 10))
        XCTAssertEqual(c.state, .below)
        XCTAssertEqual(feedbacks(drop), [.below])
    }

    func test_heart_rate_pendulum_on_lower_edge_does_not_flicker() {
        var c = TargetZoneCoach(config: zone2)
        let warmIn = feed(&c, from: 0, repeated(125, 10))
        XCTAssertEqual(feedbacks(warmIn), [.enteredZone])
        // 119 / 121 / 118 / 120 … for five minutes: the textbook "vibration–notification–vibration" trap.
        let pattern = [119, 121, 118, 120, 117, 122]
        let readings: [Int?] = (0..<300).map { pattern[$0 % pattern.count] }
        let outs = feed(&c, from: 10, readings)
        XCTAssertEqual(c.state, .inZone)
        XCTAssertTrue(feedbacks(outs).isEmpty)
    }

    func test_pendulum_from_below_needs_a_held_reading_to_come_in() {
        var c = TargetZoneCoach(config: zone2)
        feed(&c, from: 0, repeated(100, 10))
        XCTAssertEqual(c.state, .below)
        // Alternating 119 / 120 never holds the zone for the debounce window.
        let outs = feed(&c, from: 10, (0..<40).map { $0 % 2 == 0 ? 119 : 120 })
        XCTAssertEqual(c.state, .below)
        XCTAssertTrue(feedbacks(outs).isEmpty)
    }

    // MARK: - 5. Hysteresis at the upper edge

    func test_hysteresis_holds_in_zone_just_over_upper_edge() {
        var c = TargetZoneCoach(config: zone2)
        feed(&c, from: 0, repeated(135, 10))
        // 140–142 is over the zone but within the margin (hi + 3 = 143 is the exit).
        let hold = feed(&c, from: 10, repeated(140, 20) + repeated(142, 20))
        XCTAssertEqual(c.state, .inZone)
        XCTAssertTrue(feedbacks(hold).isEmpty)
        let climb = feed(&c, from: 50, repeated(143, 10))
        XCTAssertEqual(c.state, .above)
        XCTAssertEqual(feedbacks(climb), [.above])
    }

    func test_coming_back_down_from_above_needs_only_the_upper_edge() {
        var c = TargetZoneCoach(config: zone2)
        feed(&c, from: 0, repeated(150, 10))
        XCTAssertEqual(c.state, .above)
        let outs = feed(&c, from: 10, repeated(139, 10))
        XCTAssertEqual(c.state, .inZone)
        XCTAssertEqual(feedbacks(outs), [.enteredZone])
    }

    // MARK: - 6. Debounce

    func test_debounce_needs_the_new_state_held_for_the_whole_window() {
        var c = TargetZoneCoach(config: zone2)
        feed(&c, from: 0, repeated(130, 10))
        // Candidate seen at t=10…14 (five readings, 4 s elapsed): not yet.
        let early = feed(&c, from: 10, repeated(100, 5))
        XCTAssertEqual(c.state, .inZone)
        XCTAssertTrue(feedbacks(early).isEmpty)
        // t=15 — 5 s after the candidate first appeared: committed.
        let out = c.update(now: 15, bpm: 100)
        XCTAssertEqual(out.state, .below)
        XCTAssertEqual(out.feedback, .below)
    }

    func test_a_short_excursion_is_ignored() {
        var c = TargetZoneCoach(config: zone2)
        feed(&c, from: 0, repeated(130, 10))
        let outs = feed(&c, from: 10, repeated(100, 4) + repeated(130, 10) + repeated(160, 4) + repeated(130, 10))
        XCTAssertEqual(c.state, .inZone)
        XCTAssertTrue(feedbacks(outs).isEmpty)
    }

    func test_a_missing_reading_restarts_the_debounce() {
        var c = TargetZoneCoach(config: zone2)
        feed(&c, from: 0, repeated(130, 10))
        // Four below readings, a gap, four more: never five continuous seconds below.
        let outs = feed(&c, from: 10, repeated(100, 4) + [nil] + repeated(100, 4))
        XCTAssertEqual(c.state, .inZone)
        XCTAssertTrue(feedbacks(outs).isEmpty)
    }

    // MARK: - 7. Cooldown

    func test_cooldown_holds_a_repeated_warning_until_it_expires() {
        var c = TargetZoneCoach(config: zone2)
        // Below warning at t=5.
        let first = feed(&c, from: 0, repeated(100, 10))
        XCTAssertEqual(feedbacks(first), [.below])
        // In zone at t=15 (confirmed), below again at t=25: inside the 60 s below-cooldown → held.
        let bounce = feed(&c, from: 10, repeated(130, 10) + repeated(100, 20))
        XCTAssertEqual(feedbacks(bounce), [.enteredZone])
        XCTAssertEqual(c.state, .below)
        // Still below when the cooldown passes (t=65): the held warning goes out then, exactly once.
        let later = feed(&c, from: 30, repeated(100, 60))
        XCTAssertEqual(feedbacks(later), [.below])
        XCTAssertEqual(later.firstIndex { $0.feedback != nil }.map { 30 + $0 }, 65)
    }

    func test_cooldown_skips_a_confirmation_rather_than_sending_it_late() {
        var c = TargetZoneCoach(config: zone2)
        // Confirm at t=5, drop below (warn), come back in within 60 s of the first confirmation.
        let outs = feed(&c, from: 0, repeated(130, 10) + repeated(100, 10) + repeated(130, 120))
        XCTAssertEqual(feedbacks(outs), [.enteredZone, .below])
        XCTAssertEqual(c.state, .inZone)
    }

    // MARK: - 8. No reading

    func test_nil_readings_never_coach_or_commit() {
        var c = TargetZoneCoach(config: zone2)
        let outs = feed(&c, from: 0, repeated(nil, 300))
        XCTAssertNil(c.state)
        XCTAssertTrue(feedbacks(outs).isEmpty)
        XCTAssertTrue(outs.allSatisfy(\.noReading))
        XCTAssertEqual(c.inZoneSeconds, 0)
    }

    func test_implausible_readings_count_as_no_reading() {
        var c = TargetZoneCoach(config: zone2)
        let outs = feed(&c, from: 0, repeated(0, 30) + repeated(20, 30))
        XCTAssertNil(c.state)
        XCTAssertTrue(feedbacks(outs).isEmpty)
    }

    func test_a_stale_stream_after_a_warning_stays_silent() {
        var c = TargetZoneCoach(config: zone2)
        feed(&c, from: 0, repeated(100, 10))
        XCTAssertEqual(c.state, .below)
        // Ten minutes of nothing: no reminders, no accrual.
        let outs = feed(&c, from: 10, repeated(nil, 600))
        XCTAssertTrue(feedbacks(outs).isEmpty)
        XCTAssertEqual(c.inZoneSeconds, 0)
    }

    // MARK: - 9. Feedback follows transitions, not samples

    func test_steady_state_gives_one_feedback_not_one_per_second() {
        var c = TargetZoneCoach(config: zone2)
        let outs = feed(&c, from: 0, repeated(130, 600))
        XCTAssertEqual(feedbacks(outs), [.enteredZone])
    }

    func test_out_of_zone_reminds_on_the_reminder_interval_only() {
        var c = TargetZoneCoach(config: zone2)
        let outs = feed(&c, from: 0, repeated(100, 300))
        // t=5 on commit, then every 120 s while nothing changes.
        let at = outs.enumerated().compactMap { $0.element.feedback == nil ? nil : $0.offset }
        XCTAssertEqual(at, [5, 125, 245])
        XCTAssertTrue(feedbacks(outs).allSatisfy { $0 == .below })
    }

    func test_reminders_can_be_turned_off() {
        let cfg = TargetZoneCoach.Config(lowerBpm: 120, upperBpm: 140, reminderSec: 0)
        var c = TargetZoneCoach(config: cfg)
        let outs = feed(&c, from: 0, repeated(160, 900))
        XCTAssertEqual(feedbacks(outs), [.above])
    }

    func test_each_transition_gives_exactly_one_feedback() {
        var c = TargetZoneCoach(config: zone2)
        // below → in → above → in, each held two minutes (well past debounce and cooldown).
        let outs = feed(&c, from: 0, repeated(100, 90) + repeated(130, 90) + repeated(160, 90) + repeated(130, 90))
        XCTAssertEqual(feedbacks(outs), [.below, .enteredZone, .above, .enteredZone])
    }

    // MARK: - Time in zone

    func test_time_in_zone_accrues_only_while_committed_in_zone_with_readings() {
        var c = TargetZoneCoach(config: zone2)
        feed(&c, from: 0, repeated(130, 6))      // commits at t=5
        XCTAssertEqual(c.inZoneSeconds, 0)
        feed(&c, from: 6, repeated(130, 60))     // 60 more seconds in zone
        XCTAssertEqual(c.inZoneSeconds, 60)
        feed(&c, from: 66, repeated(nil, 30))    // a gap accrues nothing …
        XCTAssertEqual(c.inZoneSeconds, 60)
        c.update(now: 96, bpm: 130)              // … nor does the first reading after it
        XCTAssertEqual(c.inZoneSeconds, 60)
        c.update(now: 97, bpm: 130)
        XCTAssertEqual(c.inZoneSeconds, 61)
    }

    func test_a_long_gap_between_readings_is_clamped() {
        var c = TargetZoneCoach(config: zone2)
        feed(&c, from: 0, repeated(130, 6))
        c.update(now: 100, bpm: 130)             // 94 s later, but only maxAccrualDtSec counts
        XCTAssertEqual(c.inZoneSeconds, Double(TargetZoneCoach.Config.defaultMaxAccrualDtSec))
    }

    // MARK: - Zone set → config

    func test_config_uses_the_users_zone_set() {
        let conventional = HRZones.zones(maxHR: 200)
        let z2 = TargetZoneCoach.Config.forZone(2, in: conventional)
        XCTAssertEqual(z2?.lowerBpm, 120)
        XCTAssertEqual(z2?.upperBpm, 140)

        let custom = HRZones.zones(maxHR: 190, customLowerBounds: [100, 118, 135, 152, 170])
        let c2 = TargetZoneCoach.Config.forZone(2, in: custom)
        XCTAssertEqual(c2?.lowerBpm, 118)
        XCTAssertEqual(c2?.upperBpm, 135)
        let c4 = TargetZoneCoach.Config.forZone(4, in: custom)
        XCTAssertEqual(c4?.lowerBpm, 152)
        XCTAssertEqual(c4?.upperBpm, 170)

        XCTAssertNil(TargetZoneCoach.Config.forZone(0, in: custom))
        XCTAssertNil(TargetZoneCoach.Config.forZone(6, in: custom))
    }
}
