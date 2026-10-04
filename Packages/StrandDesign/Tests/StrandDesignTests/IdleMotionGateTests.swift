import XCTest
@testable import StrandDesign

/// The iPhone idle gate: with no touch for the idle window, every decorative loop poses still so a
/// ProMotion panel can drop its refresh rate, and the next touch brings the motion back.
///
/// Uses the shared singleton (the gate the views read), so each test switches tracking off again.
@MainActor
final class IdleMotionGateTests: XCTestCase {

    override func tearDown() async throws {
        NoopMotionState.shared.disableIdleTracking()
    }

    func testIdleTrackingIsOffUntilTheAppAsksForIt() {
        let motion = NoopMotionState.shared
        motion.noteInteraction()
        XCTAssertFalse(motion.idle)
    }

    func testGoesIdleAfterTheWindowAndWakesOnATouch() async throws {
        let motion = NoopMotionState.shared
        motion.enableIdleTracking(after: 0.05)
        XCTAssertFalse(motion.idle, "a fresh clock starts awake")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(motion.idle)
        XCTAssertTrue(motion.poseStill(false), "idle alone poses the loops still")
        XCTAssertTrue(motion.poseStillIgnoringReduceMotion, "and stops the tilt sensor")

        motion.noteInteraction()
        XCTAssertFalse(motion.idle, "a touch wakes the motion at once")
    }

    func testDisablingWakesTheMotion() async throws {
        let motion = NoopMotionState.shared
        motion.enableIdleTracking(after: 0.05)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(motion.idle)
        motion.disableIdleTracking()
        XCTAssertFalse(motion.idle)
    }
}
