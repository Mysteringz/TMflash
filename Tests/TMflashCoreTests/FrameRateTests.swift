import XCTest
@testable import TMflashCore

final class FrameRateTests: XCTestCase {
    func testOnlyOneTwoAndFourFPSCanBeSelected() throws {
        XCTAssertEqual(FrameRate.allCases.map(\.rawValue), [1, 2, 4])
        for invalid in [0, 3, 8, -1] { XCTAssertNil(FrameRate(rawValue: invalid)) }
        let old = try JSONDecoder().decode(NodeSettings.self, from: Data("{}".utf8))
        XCTAssertNil(old.frameRate, "saved settings from an older TMflash keep the node's rate")
        for fps in FrameRate.allCases {
            let settings = NodeSettings(frameRate: fps)
            let data = try JSONEncoder().encode(settings)
            XCTAssertEqual(try JSONDecoder().decode(NodeSettings.self, from: data), settings)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(NodeSettings.self, from: Data("{\"frameRate\":3}".utf8)))
    }

    func testProvisioningSavesTheRequestedRateInBothRadioModes() {
        for mode in UplinkMode.allCases {
            for fps in FrameRate.allCases {
                let commands = ConsoleCommand.provisioning(id: 1, settings: NodeSettings(mode: mode, frameRate: fps))
                XCTAssertEqual(commands.suffix(2).map(\.line), ["set fps \(fps.rawValue)", "save"])
            }
            XCTAssertFalse(ConsoleCommand.provisioning(id: 1, settings: NodeSettings(mode: mode)).contains { $0.line.contains("fps") })
        }
    }

    func testReadbackMustMatchTheSelectedRate() {
        let info = NodeInfo(fields: ["node_id": "1", "mode": "wifi", "fps": "2", "caps": "wss1,ota-https1,fps1"])
        XCTAssertTrue(info.supportsFrameRate)
        XCTAssertEqual(info.frameRate, .fps2)
        XCTAssertTrue(info.verify(id: 1, settings: NodeSettings(frameRate: .fps2)).errors.isEmpty)
        XCTAssertTrue(info.verify(id: 1, settings: NodeSettings(frameRate: .fps4)).errors.contains { $0.contains("frame rate") })
        let missing = NodeInfo(fields: ["node_id": "1", "mode": "wifi"])
        XCTAssertFalse(missing.supportsFrameRate)
        XCTAssertTrue(missing.verify(id: 1, settings: NodeSettings(frameRate: .fps1)).errors.contains { $0.contains("frame rate") })
    }

    func testAllThreeRatesSurviveSavingAndRebootingThroughTheRealSerialPipeline() async throws {
        let nodes = try FrameRate.allCases.enumerated().map { i, _ in
            try FakeNode(uid: String(format: "30:ed:a0:00:02:%02x", i + 1))
        }
        defer { nodes.forEach { $0.stop() } }
        nodes.forEach { $0.start() }
        for (node, fps) in zip(nodes, FrameRate.allCases) {
            let result = await Pipeline.run(jobs: [DeviceJob(port: node.path, nodeID: fps.rawValue)],
                                            settings: NodeSettings(ssid: "Net", password: "password1", gateway: "10.0.0.1", key: "k", frameRate: fps),
                                            writer: nil, options: .init(bootTimeout: 5, wifiTimeout: 5)) { _ in }
            XCTAssertTrue(result[0].ok, result[0].error ?? "")
            XCTAssertEqual(node.savedState["fps"], String(fps.rawValue))
            XCTAssertTrue(node.commands.contains("reboot"))
            let port = try SerialPort(path: node.path)
            let console = NodeConsole(port: port, log: { _ in })
            XCTAssertEqual(try console.waitUntilReady(timeout: 5).frameRate, fps)
            port.close()
        }
    }

    func testKeepCurrentDoesNotOverwriteAPreviouslySelectedRate() async throws {
        let node = try FakeNode(uid: "30:ed:a0:00:02:04")
        node.start()
        defer { node.stop() }
        let jobs = [DeviceJob(port: node.path, nodeID: 1)]
        let options = PipelineOptions(bootTimeout: 5, wifiTimeout: 0)
        let first = await Pipeline.run(jobs: jobs, settings: NodeSettings(frameRate: .fps4), writer: nil, options: options) { _ in }
        XCTAssertTrue(first[0].ok, first[0].error ?? "")
        let second = await Pipeline.run(jobs: jobs, settings: NodeSettings(), writer: nil, options: options) { _ in }
        XCTAssertTrue(second[0].ok, second[0].error ?? "")
        XCTAssertEqual(node.savedState["fps"], "4")
        XCTAssertEqual(node.commands.filter { $0.hasPrefix("set fps") }, ["set fps 4"])
    }

    func testOldFirmwareIsRefusedBeforeAnySettingIsWritten() async throws {
        let node = try FakeNode(uid: "30:ed:a0:00:02:05")
        node.frameRateSelection = false
        node.start()
        defer { node.stop() }
        let result = await Pipeline.run(jobs: [DeviceJob(port: node.path, nodeID: 1)], settings: NodeSettings(frameRate: .fps2),
                                        writer: nil, options: .init(bootTimeout: 5, wifiTimeout: 0)) { _ in }
        XCTAssertFalse(result[0].ok)
        XCTAssertTrue(result[0].error?.contains("flash TMsense 1.6") == true)
        XCTAssertTrue(node.commands.allSatisfy { $0 == "show" })
        let keep = await Pipeline.run(jobs: [DeviceJob(port: node.path, nodeID: 1)], settings: NodeSettings(),
                                      writer: nil, options: .init(bootTimeout: 5, wifiTimeout: 0)) { _ in }
        XCTAssertTrue(keep[0].ok, keep[0].error ?? "")
    }

    func testAnAcknowledgedButUnstoredRateFailsVerification() async throws {
        let node = try FakeNode(uid: "30:ed:a0:00:02:06")
        node.ignoreFrameRate = true
        node.start()
        defer { node.stop() }
        let result = await Pipeline.run(jobs: [DeviceJob(port: node.path, nodeID: 1)], settings: NodeSettings(frameRate: .fps4),
                                        writer: nil, options: .init(bootTimeout: 5, wifiTimeout: 0)) { _ in }
        XCTAssertFalse(result[0].ok)
        XCTAssertTrue(result[0].error?.contains("verification failed: frame rate") == true)
    }
}
