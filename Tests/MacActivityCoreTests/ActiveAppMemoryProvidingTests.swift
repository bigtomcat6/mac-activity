import XCTest
@testable import MacActivityCore

final class ActiveAppMemoryProvidingTests: XCTestCase {
    @MainActor
    func testActiveAppMemoryServiceConformsToProviderProtocol() {
        let provider: any ActiveAppMemoryProviding = ActiveAppMemoryService()
        XCTAssertTrue(type(of: provider) == ActiveAppMemoryService.self)
    }
}
