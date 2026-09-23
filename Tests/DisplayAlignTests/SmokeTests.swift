import XCTest

@testable import DisplayAlign

final class SmokeTests: XCTestCase {
    func testArrangementEmptyIsEmpty() {
        let arr = Arrangement.empty()
        XCTAssertEqual(arr.name, Arrangement.defaultName)
        XCTAssertTrue(arr.stacked.isEmpty)
        XCTAssertTrue(arr.flexible.isEmpty)
    }

    /// `canShowSave` is pure phase logic: true only when idle or fine-tuning,
    /// false while placing a display or during the preview countdown.
    @MainActor
    func testCanShowSaveOnlyInIdleOrFinetuning() {
        let coord = PlacementCoordinator(arrangement: [])
        let cfg = PlacementConfig(
            anchorName: "builtin", position: .right, align: .center,
            offset: 0, rotation: 0, pendingId: "0-0")

        coord.phase = .idle
        XCTAssertTrue(coord.canShowSave)

        coord.phase = .finetuning(cfg, displayId: "ext")
        XCTAssertTrue(coord.canShowSave)

        coord.phase = .placed(cfg)
        XCTAssertFalse(coord.canShowSave)

        coord.phase = .previewing(cfg, secondsLeft: 20)
        XCTAssertFalse(coord.canShowSave)

        coord.phase = .anchorSelected("builtin")
        XCTAssertFalse(coord.canShowSave)

        coord.phase = .pickingDisplay("builtin", .right)
        XCTAssertFalse(coord.canShowSave)
    }

    /// The resolution opt-out defaults to on, so Save captures modes unless the
    /// user flips the top-left toggle.
    @MainActor
    func testRememberResolutionsDefaultsOn() {
        let coord = PlacementCoordinator(arrangement: [])
        XCTAssertTrue(coord.rememberResolutions)
    }
}
