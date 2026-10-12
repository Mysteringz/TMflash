import TMflashCore
import XCTest
@testable import TMflash

final class ProvisioningSettingsTests: XCTestCase {
    @MainActor
    func testDamagedBundledFirmwareCannotFallBackToADeveloperSourceFolder() throws {
        let resources = FileManager.default.temporaryDirectory.appendingPathComponent("tmflash-damaged-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: resources.appendingPathComponent("Firmware"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: resources) }
        let suite = "TMflash.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(live: false, defaults: defaults, resources: resources)
        model.devices = [SerialDevice(path: "/dev/cu.test", vendorID: 0x10C4)]
        model.selectedPort = "/dev/cu.test"
        model.nodeIDText = "3"
        model.projectDir = resources.path
        XCTAssertNotNil(model.bundledFirmwareProblem)
        XCTAssertTrue(model.blockers.contains { $0.contains("included firmware") })
        XCTAssertFalse(model.blockers.contains { $0.contains("PlatformIO") })
        model.flashFirmware = false
        XCTAssertTrue(model.blockers.isEmpty, "settings-only still works without firmware")
    }

    @MainActor
    func testOptingIntoAdmissionCannotSilentlySkipMissingCredentials() throws {
        let suite = "TMflash.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(live: false, defaults: defaults)
        model.flashFirmware = false
        model.devices = [SerialDevice(path: "/dev/cu.test", vendorID: 0x10C4)]
        model.selectedPort = "/dev/cu.test"
        model.nodeIDText = "3"
        XCTAssertTrue(model.blockers.isEmpty)
        model.registerWithEdge = true
        XCTAssertFalse(model.blockers.isEmpty)
        model.edgeURL = "https://console.example.com"
        XCTAssertTrue(model.blockers.contains { $0.contains("Sign in") })
        model.edgeSession = FlasherSession(id: "test", token: String(repeating: "t", count: 32), user: "bench", expiresAt: Int64(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000), url: model.edgeURL)
        XCTAssertTrue(model.blockers.isEmpty)
        model.edgeCheck = "Connected. The token is accepted."
        model.edgeSession = nil
        XCTAssertNil(model.edgeCheck, "a test of the previous credential says nothing about the new one")
        model.edgeCheck = "Connected. The token is accepted."
        model.edgeURL = "https://another.example.com"
        XCTAssertNil(model.edgeCheck)
    }
}
