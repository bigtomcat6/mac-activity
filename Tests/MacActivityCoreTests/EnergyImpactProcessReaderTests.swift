import Darwin
import XCTest
@testable import MacActivityCore

final class EnergyImpactProcessReaderTests: XCTestCase {
    func testCurrentProcessReadReturnsStructuredSuccessWithActivityEvidence() throws {
        let result = SystemProcessEnergyReader().reading(for: getpid())

        guard case let .success(reading) = result else {
            return XCTFail("The current process must produce a successful structured reading")
        }
        XCTAssertGreaterThan(reading.processStartAbsoluteTime, 0)
        XCTAssertGreaterThan(reading.userCPUTime + reading.systemCPUTime, 0)
    }

    func testInvalidProcessReadReturnsAClassifiedFailure() {
        let result = SystemProcessEnergyReader().reading(for: Int32.max)

        guard case let .failure(failure) = result else {
            return XCTFail("An invalid process must not produce an energy reading")
        }
        switch failure {
        case .exited, .other:
            break
        case .permissionDenied, .unsupported:
            XCTFail("Invalid PID failure was misclassified as \(failure)")
        }
    }

    func testAccessErrorsMapToPermissionDenied() {
        XCTAssertEqual(SystemProcessEnergyReader.failure(for: EPERM), .permissionDenied)
        XCTAssertEqual(SystemProcessEnergyReader.failure(for: EACCES), .permissionDenied)
    }

    func testUnsupportedErrorsIncludeInvalidArgument() {
        XCTAssertEqual(SystemProcessEnergyReader.failure(for: ENOTSUP), .unsupported)
        XCTAssertEqual(SystemProcessEnergyReader.failure(for: EINVAL), .unsupported)
    }
}
