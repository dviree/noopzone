import XCTest
import StrandAnalytics
import WhoopProtocol
@testable import Strand

/// Pins the app half of target-zone coaching that can be tested without a strap: which reading may be
/// coached on, how each feedback feels on the wrist, how a stored setting resolves, and the notification's
/// stable identifier and copy. The state machine itself is pinned by `TargetZoneCoachTests` in
/// StrandAnalytics.
final class TargetZoneCoachRunnerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Reading gate

    func testAFreshReadingOnABondedWornStrapIsCoached() {
        XCTAssertEqual(TargetZoneCues.coachableReading(bpm: 128, lastSampleAt: now.addingTimeInterval(-1), now: now,
                                                       bonded: true, worn: true, paused: false), 128)
    }

    func testNoBpmIsNoReading() {
        XCTAssertNil(TargetZoneCues.coachableReading(bpm: nil, lastSampleAt: now, now: now,
                                                     bonded: true, worn: true, paused: false))
    }

    func testAStaleSampleIsNoReading() {
        let stale = now.addingTimeInterval(-(TargetZoneCues.staleAfterSec + 1))
        XCTAssertNil(TargetZoneCues.coachableReading(bpm: 128, lastSampleAt: stale, now: now,
                                                     bonded: true, worn: true, paused: false))
        XCTAssertNil(TargetZoneCues.coachableReading(bpm: 128, lastSampleAt: nil, now: now,
                                                     bonded: true, worn: true, paused: false))
    }

    func testUnbondedOffWristOrPausedIsNoReading() {
        let fresh = now.addingTimeInterval(-1)
        XCTAssertNil(TargetZoneCues.coachableReading(bpm: 128, lastSampleAt: fresh, now: now,
                                                     bonded: false, worn: true, paused: false))
        XCTAssertNil(TargetZoneCues.coachableReading(bpm: 128, lastSampleAt: fresh, now: now,
                                                     bonded: true, worn: false, paused: false))
        XCTAssertNil(TargetZoneCues.coachableReading(bpm: 128, lastSampleAt: fresh, now: now,
                                                     bonded: true, worn: true, paused: true))
    }

    // MARK: - Wrist patterns

    func testBelowAndAboveReuseTheLiveSessionVocabulary() {
        XCTAssertEqual(TargetZoneCues.pulses(for: .below), LiveSessionHaptics.pulses(for: .push))
        XCTAssertEqual(TargetZoneCues.pulses(for: .above), LiveSessionHaptics.pulses(for: .easeOff))
        XCTAssertEqual(TargetZoneCues.pulses(for: .below).count, 2)
        XCTAssertEqual(TargetZoneCues.pulses(for: .above).count, 3)
    }

    func testEnteringTheZoneIsOneLightTap() {
        let pulses = TargetZoneCues.pulses(for: .enteredZone)
        XCTAssertEqual(pulses.count, 1)
        XCTAssertFalse(pulses[0].isLong)
        XCTAssertEqual(pulses[0].gapMs, 0)
        XCTAssertEqual(pulses[0].durationMs, LiveSessionHaptics.pulses(for: .push)[0].durationMs)
    }

    // MARK: - Setting

    func testOnlyZonesTwoToFourAreSelectable() {
        XCTAssertEqual(TargetZonePrefs.selectableZones, [2, 3, 4])
        XCTAssertEqual(TargetZonePrefs.resolve(0), 0)
        XCTAssertEqual(TargetZonePrefs.resolve(1), 0)
        XCTAssertEqual(TargetZonePrefs.resolve(2), 2)
        XCTAssertEqual(TargetZonePrefs.resolve(3), 3)
        XCTAssertEqual(TargetZonePrefs.resolve(4), 4)
        XCTAssertEqual(TargetZonePrefs.resolve(5), 0)
        XCTAssertEqual(TargetZonePrefs.resolve(-7), 0)
    }

    // MARK: - Notification

    func testEveryCueSharesOneStableIdentifier() {
        XCTAssertEqual(TargetZoneNotifier.identifier, "target-zone-coach")
    }

    func testCopyNamesTheTargetZone() {
        for zone in TargetZonePrefs.selectableZones {
            for feedback in [TargetZoneCoach.Feedback.below, .enteredZone, .above] {
                let copy = TargetZoneNotifier.copy(feedback, zone: zone)
                XCTAssertTrue(copy.title.contains("\(zone)"), "\(feedback) title: \(copy.title)")
                XCTAssertTrue(copy.body.contains("\(zone)"), "\(feedback) body: \(copy.body)")
            }
        }
    }
}
