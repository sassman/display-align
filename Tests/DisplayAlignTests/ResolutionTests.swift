import XCTest

@testable import DisplayAlign

final class ResolutionConfigTests: XCTestCase {

    private func encode(_ arr: Arrangement) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(arr)
    }

    func testArrangementWithResolutionsRoundTrips() throws {
        let res = DisplayResolution(
            vendor: 4268, model: 17092,
            width: 3440, height: 1440,
            pixelWidth: 3440, pixelHeight: 1440,
            refreshHz: 60.0
        )
        let arr = Arrangement(
            name: "desk", stacked: [], flexible: [], dock_owner: nil, resolutions: [res])

        let data = try encode(arr)
        let decoded = try JSONDecoder().decode(Arrangement.self, from: data)

        XCTAssertEqual(decoded.resolutions, [res])
        XCTAssertEqual(decoded, arr)
    }

    func testNilResolutionsOmittedFromJSON() throws {
        let arr = Arrangement(name: "desk")
        let json = String(data: try encode(arr), encoding: .utf8)!
        XCTAssertFalse(json.contains("resolutions"))
    }

    func testJSONWithoutResolutionsKeyDecodesAsNil() throws {
        // Hand-written JSON lacking the key — no migration needed.
        let json = """
            {"name":"desk","stacked":[],"flexible":[]}
            """
        let arr = try JSONDecoder().decode(Arrangement.self, from: Data(json.utf8))
        XCTAssertNil(arr.resolutions)
    }

    func testResolutionLookupByVendorModel() {
        let a = DisplayResolution(
            vendor: 1, model: 2, width: 1920, height: 1080,
            pixelWidth: 1920, pixelHeight: 1080, refreshHz: 60)
        let b = DisplayResolution(
            vendor: 3, model: 4, width: 2560, height: 1440,
            pixelWidth: 2560, pixelHeight: 1440, refreshHz: 144)
        let arr = Arrangement(name: "d", resolutions: [a, b])

        XCTAssertEqual(arr.resolution(vendor: 3, model: 4), b)
        XCTAssertNil(arr.resolution(vendor: 9, model: 9))
        XCTAssertNil(Arrangement(name: "empty").resolution(vendor: 1, model: 2))
    }

    func testDedupedResolutionsKeepsFirstPerVendorModel() {
        // Identical monitors share a (vendor, model) key; capture must collapse
        // them to one entry (first seen wins) so `.first` lookups are reachable.
        let first = DisplayResolution(
            vendor: 1, model: 1, width: 2560, height: 1440,
            pixelWidth: 2560, pixelHeight: 1440, refreshHz: 60)
        let dupeKey = DisplayResolution(
            vendor: 1, model: 1, width: 1920, height: 1080,
            pixelWidth: 1920, pixelHeight: 1080, refreshHz: 30)
        let other = DisplayResolution(
            vendor: 2, model: 2, width: 3440, height: 1440,
            pixelWidth: 3440, pixelHeight: 1440, refreshHz: 100)

        let deduped = dedupedResolutions([first, dupeKey, other])
        XCTAssertEqual(deduped, [first, other])
    }
}

final class BestMatchModeTests: XCTestCase {

    private let target = DisplayResolution(
        vendor: 1, model: 1,
        width: 1920, height: 1080,
        pixelWidth: 3840, pixelHeight: 2160,
        refreshHz: 60.0
    )

    func testExactMatchWins() {
        let modes = [
            DisplayModeCandidate(width: 1280, height: 720, pixelWidth: 2560, pixelHeight: 1440, refreshHz: 60),
            DisplayModeCandidate(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, refreshHz: 60),
            DisplayModeCandidate(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, refreshHz: 30),
        ]
        XCTAssertEqual(bestMatchModeIndex(for: target, among: modes), 1)
    }

    func testRefreshAgnosticMatch() {
        // No exact refresh; same pixel + point at a different refresh should win.
        let modes = [
            DisplayModeCandidate(width: 1280, height: 720, pixelWidth: 2560, pixelHeight: 1440, refreshHz: 60),
            DisplayModeCandidate(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, refreshHz: 30),
        ]
        XCTAssertEqual(bestMatchModeIndex(for: target, among: modes), 1)
    }

    func testNearestFallback() {
        // Nothing matches pixel+point exactly; nearest by pixel distance wins.
        let modes = [
            DisplayModeCandidate(width: 1280, height: 720, pixelWidth: 2560, pixelHeight: 1440, refreshHz: 60),
            DisplayModeCandidate(width: 1800, height: 1012, pixelWidth: 3600, pixelHeight: 2024, refreshHz: 60),
        ]
        XCTAssertEqual(bestMatchModeIndex(for: target, among: modes), 1)
    }

    func testNearestFallbackTieBreaksOnPointThenRefresh() {
        // Same pixel distance; the one closer on point size wins.
        let modes = [
            DisplayModeCandidate(width: 1600, height: 900, pixelWidth: 3800, pixelHeight: 2140, refreshHz: 60),
            DisplayModeCandidate(width: 1900, height: 1070, pixelWidth: 3800, pixelHeight: 2140, refreshHz: 60),
        ]
        // Both have identical pixel distance (40+20); index 1 is nearer on point size.
        XCTAssertEqual(bestMatchModeIndex(for: target, among: modes), 1)
    }

    func testNoMatchWhenNoModes() {
        XCTAssertNil(bestMatchModeIndex(for: target, among: []))
    }

    func testRefreshJitterStillCountsAsExactMatch() {
        // Refresh rates are reported with minor jitter; 60.0 vs 59.97 is within
        // the tolerance, so the same-size mode is still an exact match.
        let modes = [
            DisplayModeCandidate(width: 1280, height: 720, pixelWidth: 2560, pixelHeight: 1440, refreshHz: 60),
            DisplayModeCandidate(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, refreshHz: 59.97),
        ]
        XCTAssertEqual(bestMatchModeIndex(for: target, among: modes), 1)
    }

    func testZeroRefreshTargetPrefersZeroRefreshMode() {
        // Built-in panels report a 0 refresh rate; a 0-refresh target must pick
        // the 0-refresh mode over an otherwise identical 60-refresh mode.
        let zeroTarget = DisplayResolution(
            vendor: 1, model: 1,
            width: 1920, height: 1080,
            pixelWidth: 3840, pixelHeight: 2160,
            refreshHz: 0
        )
        let modes = [
            DisplayModeCandidate(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, refreshHz: 60),
            DisplayModeCandidate(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, refreshHz: 0),
        ]
        XCTAssertEqual(bestMatchModeIndex(for: zeroTarget, among: modes), 1)
    }

    func testFarOffModeReturnsNilToLeaveDisplayAlone() {
        // Nothing is reasonably close (pixel delta 2000 ≫ 15% budget), so the
        // matcher declines rather than forcing a wildly different mode.
        let modes = [
            DisplayModeCandidate(width: 1280, height: 720, pixelWidth: 2560, pixelHeight: 1440, refreshHz: 60)
        ]
        XCTAssertNil(bestMatchModeIndex(for: target, among: modes))
    }

    func testCloseEnoughModeStillMatchesUnderThreshold() {
        // A far mode and a close one: the close one is within the 15% budget on
        // both pixel and point deltas, so it's selected (not nil).
        let modes = [
            DisplayModeCandidate(width: 1280, height: 720, pixelWidth: 2560, pixelHeight: 1440, refreshHz: 60),
            DisplayModeCandidate(width: 1800, height: 1012, pixelWidth: 3600, pixelHeight: 2024, refreshHz: 60),
        ]
        XCTAssertEqual(bestMatchModeIndex(for: target, among: modes), 1)
    }
}
