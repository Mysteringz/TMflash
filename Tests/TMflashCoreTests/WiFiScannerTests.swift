import XCTest
@testable import TMflashCore

final class WiFiScannerTests: XCTestCase {
    private func ap(_ ssid: String, _ rssi: Int, is2GHz: Bool = true) -> WiFiAccessPoint {
        WiFiAccessPoint(ssid: Data(ssid.utf8), rssi: rssi, is2GHz: is2GHz)
    }

    func testOnly24GHzIsOfferedEvenWhenIts5GHzSiblingIsStronger() {
        let choices = WiFiScanner.choices(from: [
            ap("Dual band", -20, is2GHz: false), ap("Dual band", -70),
            ap("5 GHz only", -30, is2GHz: false), ap("Nearby", -40),
        ])
        XCTAssertEqual(choices.map(\.ssid), ["Nearby", "Dual band"])
        XCTAssertEqual(choices.map(\.rssi), [-40, -70])
    }

    func testDuplicateAccessPointsAppearOnceStrongestFirstWithStableTies() {
        let choices = WiFiScanner.choices(from: [
            ap("B", -50), ap("Mesh", -80), ap("Mesh", -40), ap("A", -50), ap("Mesh", -60),
        ])
        XCTAssertEqual(choices.map(\.ssid), ["Mesh", "A", "B"])
        XCTAssertEqual(choices.first?.rssi, -40)
    }

    func testHiddenRedactedAndUnprovisionableNamesAreNotChoices() {
        let choices = WiFiScanner.choices(from: [
            WiFiAccessPoint(ssid: nil, rssi: -10, is2GHz: true), ap("", -10),
            WiFiAccessPoint(ssid: Data([0xff]), rssi: -10, is2GHz: true),
            ap("bad\nname", -10), ap("nul\0name", -10), ap("tab\tname", -10),
            ap(" padded ", -10), ap(String(repeating: "x", count: 33), -10), ap("Usable", -60),
        ])
        XCTAssertEqual(choices.map(\.ssid), ["Usable"])
        XCTAssertTrue(WiFiScanner.choices(from: []).isEmpty)
    }

    func testSSIDBytesArePreservedIncludingDistinctUnicodeSpellings() {
        let names = ["Café", "Cafe\u{301}", "Lab 網絡, 2.4G"]
        let choices = WiFiScanner.choices(from: names.map { ap($0, -50) })
        XCTAssertEqual(Set(choices.map(\.id)), Set(names.map { Data($0.utf8) }))
        for network in choices {
            let command = ConsoleCommand.provisioning(id: 7, settings: NodeSettings(ssid: network.ssid))
                .first { $0.expect == "ssid updated" }
            XCTAssertEqual(command.map { Data($0.line.utf8) }, Data("set ssid \(network.ssid)".utf8))
        }
    }

    func testSelectedScannedSSIDReachesTheNodeAndIsVerified() async throws {
        let node = try FakeNode(uid: "30:ed:a0:00:00:77")
        node.start()
        defer { node.stop() }
        let network = try XCTUnwrap(WiFiScanner.choices(from: [ap("Lab 網絡, 2.4G", -45)]).first)
        let settings = NodeSettings(ssid: network.ssid, password: "test-password", gateway: "10.0.0.1", key: "test-key")
        let results = await Pipeline.run(jobs: [DeviceJob(port: node.path, nodeID: 7)], settings: settings,
                                         writer: nil, options: .init(bootTimeout: 5, wifiTimeout: 2)) { _ in }
        XCTAssertTrue(results[0].ok, results[0].error ?? "")
        XCTAssertEqual(node.savedState["ssid"], network.ssid)
        XCTAssertNotNil(results[0].wifiIP)
    }

    func testSelectedScannedSSIDWorksWithDirectCloud() async throws {
        let node = try FakeNode(uid: "02:00:00:00:00:78")
        node.start()
        defer { node.stop() }
        let network = try XCTUnwrap(WiFiScanner.choices(from: [ap("Lab 網絡, 2.4G", -45)]).first)
        let settings = NodeSettings(ssid: network.ssid, password: "test-password", key: "test-key",
                                    transport: .wss, cloudURL: "wss://sense.example.com/tmnode")
        let results = await Pipeline.run(jobs: [DeviceJob(port: node.path, nodeID: 8)], settings: settings,
                                         writer: nil, options: .init(bootTimeout: 5, wifiTimeout: 2, edgeTimeout: 2)) { _ in }
        XCTAssertTrue(results[0].ok, results[0].error ?? "")
        XCTAssertEqual(node.savedState["ssid"], network.ssid)
        XCTAssertEqual(node.savedState["transport"], "wss")
        XCTAssertEqual(results[0].edgeAccepted, true)
    }
}
