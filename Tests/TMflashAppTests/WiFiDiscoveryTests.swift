import CoreLocation
import TMflashCore
import XCTest
@testable import TMflash

final class WiFiDiscoveryTests: XCTestCase {
    @MainActor
    private func finishScan(_ discovery: WiFiDiscovery) async throws {
        for _ in 0..<200 {
            if discovery.state != .scanning { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Scan did not finish")
    }

    @MainActor
    func testAuthorizationRunsTheScanOffTheMainThreadAndPublishesResults() async throws {
        let networks = [WiFiNetwork(ssid: "Lab", rssi: -40)]
        let discovery = WiFiDiscovery(live: false) {
            XCTAssertFalse(Thread.isMainThread)
            return networks
        }
        discovery.updateAuthorization(.authorizedAlways)
        XCTAssertEqual(discovery.state, .scanning)
        try await finishScan(discovery)
        XCTAssertEqual(discovery.state, .ready)
        XCTAssertEqual(discovery.networks, networks)
    }

    @MainActor
    func testScanFailureClearsOldResultsAndAllowsRetry() async throws {
        let discovery = WiFiDiscovery(live: false) { throw WiFiScanError.poweredOff }
        discovery.networks = [WiFiNetwork(ssid: "Old", rssi: -50)]
        discovery.updateAuthorization(.authorizedAlways)
        XCTAssertTrue(discovery.networks.isEmpty)
        try await finishScan(discovery)
        XCTAssertEqual(discovery.state, .failed(WiFiScanError.poweredOff.localizedDescription))
        XCTAssertFalse(discovery.isBusy)
        discovery.updateAuthorization(.authorizedAlways)
        XCTAssertEqual(discovery.state, .scanning)
        try await finishScan(discovery)
    }

    @MainActor
    func testEmptyScanGivesManualEntryGuidance() async throws {
        let discovery = WiFiDiscovery(live: false) { [] }
        discovery.updateAuthorization(.authorizedAlways)
        try await finishScan(discovery)
        XCTAssertEqual(discovery.state, .ready)
        XCTAssertTrue(discovery.message.contains("No usable 2.4 GHz networks"))
        XCTAssertTrue(discovery.message.contains("manually"))
    }

    @MainActor
    func testPermissionDenialNeverScansAndOffersManualEntry() async {
        let discovery = WiFiDiscovery(live: false) { XCTFail("Must not scan without permission"); return [] }
        discovery.networks = [WiFiNetwork(ssid: "Old", rssi: -50)]
        discovery.updateAuthorization(.denied)
        XCTAssertTrue(discovery.networks.isEmpty)
        XCTAssertFalse(discovery.isBusy)
        XCTAssertTrue(discovery.message.contains("Location Services"))
        XCTAssertTrue(discovery.message.contains("manually"))
    }

    @MainActor
    func testRevokedPermissionDiscardsAnInFlightScan() async throws {
        let gate = DispatchSemaphore(value: 0)
        let returned = expectation(description: "Scanner returned")
        let discovery = WiFiDiscovery(live: false) {
            _ = gate.wait(timeout: .now() + 2)
            defer { returned.fulfill() }
            return [WiFiNetwork(ssid: "Private", rssi: -40)]
        }
        discovery.updateAuthorization(.authorizedAlways)
        discovery.updateAuthorization(.denied)
        let denied = discovery.state
        gate.signal()
        await fulfillment(of: [returned], timeout: 3)
        // Allow the task to deliver its result back to the main actor.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(discovery.state, denied)
        XCTAssertTrue(discovery.networks.isEmpty)
    }

    @MainActor
    func testSnapshotsNeverRequestPermissionOrScanHardware() async {
        let discovery = WiFiDiscovery(live: false) { XCTFail("Snapshot touched hardware"); return [] }
        discovery.scanIfAuthorized()
        discovery.scan()
        XCTAssertEqual(discovery.state, .idle)
    }
}
