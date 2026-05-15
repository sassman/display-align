import XCTest

@testable import DisplayAlign

final class SmokeTests: XCTestCase {
    func testArrangementEmptyIsEmpty() {
        let arr = Arrangement.empty()
        XCTAssertEqual(arr.name, Arrangement.defaultName)
        XCTAssertTrue(arr.stacked.isEmpty)
        XCTAssertTrue(arr.flexible.isEmpty)
    }
}
