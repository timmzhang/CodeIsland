import XCTest
@testable import CodeIsland

final class UpdateCheckerTests: XCTestCase {
    @MainActor
    func testAutomaticUpdateChecksRemainDisabled() {
        XCTAssertFalse(UpdateChecker.automaticUpdateChecksEnabled)
    }
}
