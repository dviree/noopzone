import XCTest
@testable import Strand

/// Pins the live-HR banner's off switch: off by default, turned off once for an install that had it on, and
/// left alone after that so a wearer who switches it back on keeps it.
final class LiveActivityTurnOffTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        let name = "LiveActivityTurnOffTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testTurnsAStoredOnSwitchOffOnce() {
        let d = freshDefaults()
        d.set(true, forKey: UnitPrefs.liveActivityKey)
        UnitPrefs.turnLiveActivityOffOnce(d)
        XCTAssertEqual(d.object(forKey: UnitPrefs.liveActivityKey) as? Bool, false)
    }

    func testASwitchTurnedBackOnAfterwardsSticks() {
        let d = freshDefaults()
        UnitPrefs.turnLiveActivityOffOnce(d)
        d.set(true, forKey: UnitPrefs.liveActivityKey)
        UnitPrefs.turnLiveActivityOffOnce(d)
        XCTAssertEqual(d.object(forKey: UnitPrefs.liveActivityKey) as? Bool, true)
    }
}
