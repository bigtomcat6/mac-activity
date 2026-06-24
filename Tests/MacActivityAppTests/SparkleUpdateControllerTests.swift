import MacActivityCore
import XCTest
@testable import MacActivityApp

final class SparkleUpdateControllerTests: XCTestCase {
    func testAllowedSparkleChannelsTreatsReleaseAsDefaultChannel() {
        XCTAssertEqual(SparkleUpdateController.allowedSparkleChannels(for: .release), [])
        XCTAssertEqual(SparkleUpdateController.allowedSparkleChannels(for: .beta), ["beta"])
        XCTAssertEqual(SparkleUpdateController.allowedSparkleChannels(for: .alpha), ["alpha", "beta"])
    }
}
