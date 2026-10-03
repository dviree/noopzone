import XCTest
import StrandAnalytics
import WhoopProtocol
@testable import Strand

/// Pins the app half of target-zone coaching that can be tested without a strap: which reading may be
/// coached on, how each feedback feels on the wrist, how a stored setting resolves, and the notification's
/// stable identifier and copy. The state machine itself is pinned by `TargetZoneCoachTests` in
/// StrandAnalytics.
final class TargetZoneCoachRunnerTests: XCTestCase {

    // MARK: - Reading gate

    func testASmoothedBpmOnAWornStrapIsCoached() {
        XCTAssertEqual(TargetZoneCues.coachableReading(bpm: 128, worn: true, paused: false), 128)
    }

    func testNoBpmIsNoReading() {
        // `AppModel.bpm` goes nil when the live heart rate is stale or gone; that is the freshness authority.
        XCTAssertNil(TargetZoneCues.coachableReading(bpm: nil, worn: true, paused: false))
    }

    func testOffWristOrPausedIsNoReading() {
        XCTAssertNil(TargetZoneCues.coachableReading(bpm: 128, worn: false, paused: false))
        XCTAssertNil(TargetZoneCues.coachableReading(bpm: 128, worn: true, paused: true))
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
