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

    func testTheSyncCountsAsFinishedOnlyOnceItHasSettled() {
        let opened: TimeInterval = 1_000
        func done(_ backfilling: Bool, _ synced: TimeInterval?, at now: TimeInterval) -> Bool {
            DormancyPolicy.syncFinished(backfilling: backfilling, lastSyncedAt: synced, openedAt: opened, now: now)
        }
        XCTAssertFalse(done(false, nil, at: 1_100), "no sync completed yet")
        XCTAssertFalse(done(false, 900, at: 1_100), "the last completed sync is from before the open")
        XCTAssertFalse(done(true, 1_050, at: 1_100), "a slice completed but the next one is running")
        XCTAssertFalse(done(false, 1_050, at: 1_052),
                       "between two slices of one offload, and before the debounced push has started")
        XCTAssertTrue(done(false, 1_050, at: 1_050 + DormancyPolicy.syncSettleSeconds))
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

    /// A strap the user disconnected before NOOP slept is not reconnected when NOOP wakes.
    func testWakingKeepsAUserDisconnect() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: BLEManager.dormantKey)
        defer { defaults.set(saved, forKey: BLEManager.dormantKey) }
        defaults.removeObject(forKey: BLEManager.dormantKey)

        let collector = Collector(store: NullStore(), deviceId: "test-strap", log: { _ in }, now: { 1_750_000_000 })
        let live = LiveState()
        let manager = BLEManager(state: live, collector: collector)
        manager.disconnect()
        manager.setDormant(true)
        manager.setDormant(false)
        XCTAssertTrue(live.log.contains { $0.contains("the strap stays disconnected") })
        XCTAssertFalse(live.log.contains { $0.contains("asking to reconnect") })
    }
}
