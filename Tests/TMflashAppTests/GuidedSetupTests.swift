import TMflashCore
import XCTest
@testable import TMflash

final class GuidedSetupTests: XCTestCase {
    @MainActor
    private func model() throws -> AppModel {
        let suite = "TMflash.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(live: false, defaults: defaults)
        model.flashFirmware = false
        return model
    }

    @MainActor
    func testConnectionCanBeChosenBeforeDeviceIdentity() async throws {
        let model = try model()
        XCTAssertTrue(model.setupProblems.isEmpty)
        model.moveSetup(by: 1)
        XCTAssertEqual(model.setupStep, .route)
        model.moveSetup(by: 1)
        XCTAssertEqual(model.setupStep, .network)
        XCTAssertTrue(model.setupProblems.isEmpty, "blank fields can reuse an existing device's settings")
        model.setupStep = .device
        XCTAssertFalse(model.setupProblems.isEmpty)
        model.setupStep = .review
        XCTAssertFalse(model.blockers.isEmpty, "navigation must not bypass the device and ID checks")
    }

    @MainActor
    func testLoRaSkipsWiFiDestinationWithoutStrandingNavigation() async throws {
        let model = try model()
        model.settings.transport = .wss
        model.setupStep = .route
        model.setUplink(.lora)
        XCTAssertEqual(model.setupStep, .network)
        model.moveSetup(by: -1)
        XCTAssertEqual(model.setupStep, .connection)
        model.moveSetup(by: 1)
        XCTAssertEqual(model.setupStep, .network)
        model.moveSetup(by: 1)
        XCTAssertEqual(model.setupStep, .security)
        model.setUplink(.wifi)
        XCTAssertEqual(model.settings.transport, .wss, "a temporary LoRa choice must not erase the Wi-Fi route")
        model.setupStep = .connection
        model.moveSetup(by: 1)
        XCTAssertEqual(model.setupStep, .route)
    }

    @MainActor
    func testHiddenGatewayIsNeitherValidatedNorWrittenForDirectWiFi() async throws {
        let model = try model()
        model.settings = NodeSettings(gateway: "old gateway name", transport: .wss, cloudURL: "wss://sense.example.com/tmnode")
        model.setupStep = .network
        XCTAssertTrue(model.setupProblems.isEmpty)
        let commands = ConsoleCommand.provisioning(id: 3, settings: model.settingsForRun, directCloud: true)
        XCTAssertFalse(commands.contains { $0.line.hasPrefix("set edges ") })
        XCTAssertTrue(commands.contains { $0.line == "set transport wss" })
        XCTAssertEqual(model.settings.gateway, "old gateway name", "switching routes must preserve the editable value")
        model.settings.transport = .udp
        XCTAssertFalse(model.setupProblems.isEmpty, "the gateway becomes relevant again when selected")
    }

    @MainActor
    func testHiddenCloudAndWiFiFieldsDoNotBlockOtherModes() async throws {
        let model = try model()
        model.setupStep = .network
        model.settings = NodeSettings(gateway: "192.0.2.10", cloudURL: "not a cloud endpoint")
        XCTAssertTrue(model.setupProblems.isEmpty)
        let udpCommands = ConsoleCommand.provisioning(id: 3, settings: model.settingsForRun, directCloud: true)
        XCTAssertFalse(udpCommands.contains { $0.line.hasPrefix("set cloud_url ") })
        model.settings.mode = .lora
        model.settings.password = "short"
        XCTAssertTrue(model.setupProblems.isEmpty)
        XCTAssertEqual(model.settingsForRun.password, "")
        model.settings.mode = .wifi
        XCTAssertFalse(model.setupProblems.isEmpty, "Wi-Fi must still validate the password when it is visible")
    }

    @MainActor
    func testSecurityStepAndReviewRequireMatchingUnexpiredAccount() async throws {
        let model = try model()
        model.devices = [SerialDevice(path: "/dev/cu.test", vendorID: 0x10C4)]
        model.selectedPort = "/dev/cu.test"
        model.nodeIDText = "3"
        model.setupStep = .security
        model.registerWithEdge = true
        XCTAssertFalse(model.setupProblems.isEmpty)
        XCTAssertFalse(model.blockers.isEmpty)
        model.edgeSession = FlasherSession(id: "fixture", token: String(repeating: "t", count: 32), user: "bench",
                                          expiresAt: Int64(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000), url: model.edgeURL)
        XCTAssertTrue(model.setupProblems.isEmpty)
        XCTAssertTrue(model.blockers.isEmpty)
        model.edgeURL = "https://other.example.com"
        XCTAssertFalse(model.setupProblems.isEmpty)
        model.edgeURL = "https://algo.hkumyseat.com"
        model.edgeSession = FlasherSession(id: "expired", token: String(repeating: "t", count: 32), user: "bench",
                                          expiresAt: 0, url: model.edgeURL)
        XCTAssertFalse(model.setupProblems.isEmpty)
        XCTAssertFalse(model.blockers.isEmpty)
        model.registerWithEdge = false
        XCTAssertTrue(model.setupProblems.isEmpty, "existing approved devices need no new adoption session")
        model.settings.key = "contains spaces"
        XCTAssertFalse(model.setupProblems.isEmpty)
    }

    @MainActor
    func testReviewChecksChangedNetworkSettingsAndBatchIDCount() async throws {
        let model = try model()
        model.mode = .batch
        model.devices = (1...2).map { SerialDevice(path: "/dev/cu.test-\($0)", vendorID: 0x10C4) }
        model.selectAllBatch()
        model.startIDText = "11"
        model.endIDText = "12"
        model.settings.frameRate = .fps4
        model.setupStep = .review
        XCTAssertTrue(model.blockers.isEmpty)
        XCTAssertEqual(model.settingsForRun.frameRate, .fps4)
        model.endIDText = "13"
        XCTAssertFalse(model.blockers.isEmpty)
        model.endIDText = "12"
        model.settings.password = "short"
        XCTAssertFalse(model.blockers.isEmpty, "review must catch fields changed after their step was completed")
    }
}
