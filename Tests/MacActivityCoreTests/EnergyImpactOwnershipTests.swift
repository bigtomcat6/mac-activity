import Darwin
import XCTest
@testable import MacActivityCore

final class EnergyImpactOwnershipTests: XCTestCase {
    func testNearestRegularRootOwnsNestedRootDescendantsExactlyOnce() {
        let owners = EnergyImpactOwnership.nearestRootOwners(
            rootProcessIdentifiers: [100, 200],
            snapshots: [
                ProcessParentSnapshot(processIdentifier: 100, parentProcessIdentifier: 1),
                ProcessParentSnapshot(processIdentifier: 150, parentProcessIdentifier: 100),
                ProcessParentSnapshot(processIdentifier: 200, parentProcessIdentifier: 150),
                ProcessParentSnapshot(processIdentifier: 250, parentProcessIdentifier: 200),
            ]
        )

        XCTAssertEqual(owners[100], 100)
        XCTAssertEqual(owners[150], 100)
        XCTAssertEqual(owners[200], 200)
        XCTAssertEqual(owners[250], 200)
        XCTAssertEqual(owners.values.filter { $0 == 100 }.count, 2)
        XCTAssertEqual(owners.values.filter { $0 == 200 }.count, 2)
    }

    func testCycleAndOrphanDoNotAcquireAnOwner() {
        let owners = EnergyImpactOwnership.nearestRootOwners(
            rootProcessIdentifiers: [100],
            snapshots: [
                ProcessParentSnapshot(processIdentifier: 100, parentProcessIdentifier: 1),
                ProcessParentSnapshot(processIdentifier: 300, parentProcessIdentifier: 301),
                ProcessParentSnapshot(processIdentifier: 301, parentProcessIdentifier: 300),
                ProcessParentSnapshot(processIdentifier: 400, parentProcessIdentifier: 999),
            ]
        )

        XCTAssertNil(owners[300])
        XCTAssertNil(owners[301])
        XCTAssertNil(owners[400])
    }
}
