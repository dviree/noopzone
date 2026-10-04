import XCTest
import StrandAnalytics
import WhoopProtocol
import WhoopStore
@testable import Strand

/// "Only run during training": the rule, and the BLE side of sleeping.
@MainActor
final class DormancyPolicyTests: XCTestCase {

    // MARK: - The rule

    func testSleepsOnlyInTheBackgroundWithNoWorkoutAndTheSettingOn() {
        XCTAssertTrue(DormancyPolicy.shouldSleep(enabled: true, inBackground: true, workoutActive: false))
        XCTAssertFalse(DormancyPolicy.shouldSleep(enabled: true, inBackground: true, workoutActive: true),
                       "a workout keeps the strap connected with the phone locked")
        XCTAssertFalse(DormancyPolicy.shouldSleep(enabled: true, inBackground: false, workoutActive: false),
                       "never asleep while the app is open")
        XCTAssertFalse(DormancyPolicy.shouldSleep(enabled: false, inBackground: true, workoutActive: false),
                       "off restores the always-connected behaviour")
    }

    func testTheSettingDefaultsOn() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: DormancyPolicy.enabledKey)
        defer { defaults.set(saved, forKey: DormancyPolicy.enabledKey) }
        defaults.removeObject(forKey: DormancyPolicy.enabledKey)
        XCTAssertTrue(DormancyPolicy.enabled)
        defaults.set(false, forKey: DormancyPolicy.enabledKey)
        XCTAssertFalse(DormancyPolicy.enabled)
    }

    // MARK: - BLE

    private final class NullStore: StoreWriting {
        func insert(_ streams: Streams, deviceId: String) async throws
            -> (hr: Int, rr: Int, events: Int, battery: Int,
                spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
            (0, 0, 0, 0, 0, 0, 0, 0)
        }

        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {}
    }

    /// Asleep is persisted, so a process relaunched in the background stays asleep, and waking clears it.
    func testSleepIsPersistedAndWakingClearsIt() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: BLEManager.dormantKey)
        defer { defaults.set(saved, forKey: BLEManager.dormantKey) }
        defaults.removeObject(forKey: BLEManager.dormantKey)

        let collector = Collector(store: NullStore(), deviceId: "test-strap", log: { _ in }, now: { 1_750_000_000 })
        let manager = BLEManager(state: LiveState(), collector: collector)
        XCTAssertFalse(manager.dormant)

        manager.setDormant(true)
        XCTAssertTrue(manager.dormant)
        XCTAssertTrue(defaults.bool(forKey: BLEManager.dormantKey))
        XCTAssertTrue(BLEManager(state: LiveState(), collector: collector).dormant,
                      "a new manager (a relaunched process) starts asleep")

        manager.setDormant(false)
        XCTAssertFalse(manager.dormant)
        XCTAssertFalse(defaults.bool(forKey: BLEManager.dormantKey))
    }
}
