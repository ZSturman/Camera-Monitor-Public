import XCTest
@testable import CameraCore

final class ServiceProbeTests: XCTestCase {
    /// Read-only probe of a real host, e.g. CAMERA_MONITOR_PROBE_HOST=pi.example.local.
    func testProbeHost() async throws {
        guard let host = ProcessInfo.processInfo.environment["CAMERA_MONITOR_PROBE_HOST"] else {
            throw XCTSkip("Set CAMERA_MONITOR_PROBE_HOST to probe a real host.")
        }
        let findings = await ServiceProbe().probe(host)
        for finding in findings { print("FOUND \(finding.kind.rawValue) \(finding.address) — \(finding.detail)") }
        let expected = ProcessInfo.processInfo.environment["CAMERA_MONITOR_PROBE_EXPECT"]?.split(separator: ",").map(String.init) ?? []
        for kind in expected {
            XCTAssertTrue(findings.contains { $0.kind.rawValue == kind }, "expected \(kind)")
        }
    }
}
