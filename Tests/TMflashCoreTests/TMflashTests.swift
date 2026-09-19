import XCTest
@testable import TMflashCore

// Claims about TMflash's behaviour. The pipeline tests run the real serial
// code against FakeNode on pseudo-terminals.

final class SettingsTests: XCTestCase {
    func testBatchIDsMustCoverExactlyTheSelectedBoards() {
        XCTAssertEqual(try NodeSettings.batchIDs(start: 11, end: 20, deviceCount: 10).get(), Array(11...20))
        XCTAssertEqual(NodeSettings.batchIDs(start: 1, end: 3, deviceCount: 2), .failure(.countMismatch(ids: 3, devices: 2)))
        XCTAssertEqual(NodeSettings.batchIDs(start: 5, end: 4, deviceCount: 2), .failure(.reversed))
        XCTAssertEqual(NodeSettings.batchIDs(start: 1, end: 11, deviceCount: 11), .failure(.tooMany(11)), "at most 10 at once")
        XCTAssertEqual(NodeSettings.batchIDs(start: 0, end: 1, deviceCount: 2), .failure(.outOfRange))
        XCTAssertEqual(NodeSettings.batchIDs(start: nil, end: 1, deviceCount: 1), .failure(.missing))
    }

    func testValidationCatchesWhatTheFirmwareWouldMangle() {
        XCTAssertEqual(NodeSettings(ssid: "EsanHouse", password: "longenough", gateway: "192.168.0.43", key: "abc").problems(), [])
        XCTAssertFalse(NodeSettings(gateway: "192.168.0.256").problems().isEmpty)
        XCTAssertFalse(NodeSettings(gateway: "192.168.00.1").problems().isEmpty)
        XCTAssertFalse(NodeSettings(password: "short").problems().isEmpty, "WPA2 needs 8+")
        XCTAssertFalse(NodeSettings(ssid: String(repeating: "x", count: 33)).problems().isEmpty)
        XCTAssertFalse(NodeSettings(ssid: "a\nb").problems().isEmpty, "a newline would end the console command early")
        XCTAssertFalse(NodeSettings(key: "has space").problems().isEmpty)
        XCTAssertEqual(NodeSettings(ssid: "My Net").problems(), [], "SSIDs may contain spaces; the console takes the rest of the line")
        XCTAssertEqual(NodeSettings.problems(forID: 70000).count, 1)
    }

    func testCommandsMaskSecretsAndFollowTheMode() {
        let wifi = ConsoleCommand.provisioning(id: 7, settings: NodeSettings(mode: .wifi, ssid: "Net", password: "password1", gateway: "10.0.0.2", key: "k3y"))
        XCTAssertEqual(wifi.map(\.line), ["set id 7", "set mode wifi", "set ssid Net", "set pass password1", "set edges 10.0.0.2", "set key k3y", "save"])
        XCTAssertFalse(wifi.map(\.display).joined().contains("password1"), "the log never shows the password")
        XCTAssertFalse(wifi.map(\.display).joined().contains("k3y"), "the log never shows the key")

        let lora = ConsoleCommand.provisioning(id: 8, settings: NodeSettings(mode: .lora, ssid: "ignored", gateway: "10.0.0.3"))
        XCTAssertEqual(lora.map(\.line), ["set id 8", "set mode lora", "set lora_gw 10.0.0.3", "save"])

        let keep = ConsoleCommand.provisioning(id: 9, settings: NodeSettings())
        XCTAssertEqual(keep.map(\.line), ["set id 9", "set mode wifi", "save"], "blank fields keep what the node has")
    }
}

final class ParsingTests: XCTestCase {
    func testShowOutputFromTheFirmware() {
        let lines = """
        [frame 12] people=1 scene 21.0..33.5 C fps=1.00
        uid       : 30:ed:a0:cb:f5:f8
        fw        : tmsense-1.1
        node_id   : 3
        mode      : wifi
        lora_gw   : (none)
        ssid      : EsanHouse
        password  : (set)
        edges     : 192.168.0.43
        key       : (set)
        boot      : 41   last_cmd: 0
        param min_contrast = 50 centi-C
        """.split(separator: "\n").map(String.init)
        var f: [String: String] = [:]
        for l in lines { if let (k, v) = NodeInfo.parseField(l) { f[k] = v } }
        let info = NodeInfo(fields: f)
        XCTAssertEqual(info.uid, "30:ed:a0:cb:f5:f8")
        XCTAssertEqual(info.nodeID, 3)
        XCTAssertEqual(info.edge, "192.168.0.43")
        XCTAssertTrue(info.passwordSet && info.keySet)
        XCTAssertNil(info.loraGateway)
        let v = info.verify(id: 3, settings: NodeSettings(ssid: "EsanHouse", gateway: "192.168.0.43"))
        XCTAssertEqual(v.errors, [])
        XCTAssertEqual(v.warnings, [])
        XCTAssertEqual(info.verify(id: 4, settings: NodeSettings()).errors.count, 1)
    }

    func testNoKeyIsAWarningNotSilence() {
        let info = NodeInfo(fields: ["uid": "x", "node_id": "1", "mode": "wifi", "ssid": "N", "password": "(set)", "edges": "1.2.3.4 ",
                                     "key": "(unset - telemetry unsigned)"])
        let v = info.verify(id: 1, settings: NodeSettings())
        XCTAssertEqual(v.errors, [])
        XCTAssertTrue(v.warnings.contains { $0.contains("unsigned") })
    }

    func testEsptoolProgressIsWeightedByImageSize() {
        var p = EsptoolProgress(imageSizes: [1000, 3000])
        for l in ["esptool.py v4.5.1", "Chip is ESP32-S3 (revision v0.2)", "MAC: 30:ED:A0:CB:F5:F8", "Compressed 1000 bytes to 700...",
                  "Writing at 0x00000000... (100 %)", "Wrote 1000 bytes (700 compressed) at 0x00000000 in 0.1 seconds"] { p.feed(l) }
        XCTAssertEqual(p.overall, 0.25, accuracy: 0.001)
        XCTAssertEqual(p.mac, "30:ed:a0:cb:f5:f8")
        p.feed("Compressed 3000 bytes to 2000...")
        p.feed("Writing at 0x00010000... (50 %)")
        XCTAssertEqual(p.overall, 0.625, accuracy: 0.001)
        p.feed("A fatal error occurred: Packet content transfer stopped")
        XCTAssertEqual(p.fatal, "Packet content transfer stopped")
    }

    func testMetadataGivesEveryImageAndTheApplication() throws {
        let dir = NSTemporaryDirectory() + "tmflash-meta-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for f in ["bootloader.bin", "partitions.bin", "boot_app0.bin", "firmware.bin"] { FileManager.default.createFile(atPath: "\(dir)/\(f)", contents: Data([1])) }
        let json = """
        Some notice
        {"tmflash": {"prog_path": "\(dir)/firmware.elf", "extra": {"application_offset": "0x10000", "flash_images": [
          {"offset": "0x0000", "path": "\(dir)/bootloader.bin"}, {"offset": "0x8000", "path": "\(dir)/partitions.bin"},
          {"offset": "0xe000", "path": "\(dir)/boot_app0.bin"}]}}}
        """
        let b = try FirmwareProject.parseMetadata(json, boardFlashSize: "8MB", version: "tmsense-1.1")
        XCTAssertEqual(b.images.map(\.offset), ["0x0000", "0x8000", "0xe000", "0x10000"])
        let args = b.esptoolArguments(port: "/dev/cu.x")
        XCTAssertFalse(args.contains("erase_flash") || args.contains("--erase-all"), "never erase: NVS holds settings and the boot counter")
        XCTAssertEqual(args.suffix(2), ["0x10000", "\(dir)/firmware.bin"])
    }

    func testOneBoardTwoDriversIsOneDevice() {
        let a = SerialDevice(path: "/dev/cu.SLAB_USBtoUART", vendorID: 0x10C4, locationID: 0x0110_0000)
        let b = SerialDevice(path: "/dev/cu.usbserial-0001", vendorID: 0x10C4, locationID: 0x0110_0000)
        let c = SerialDevice(path: "/dev/cu.usbserial-0002", vendorID: 0x10C4, locationID: 0x0120_0000)
        XCTAssertEqual(SerialDevices.dedupe([a, b, c]).map(\.path), ["/dev/cu.usbserial-0001", "/dev/cu.usbserial-0002"])
    }

    func testManifestQuotesAwkwardFields() {
        XCTAssertEqual(Manifest.csv("Esan, House"), "\"Esan, House\"")
        XCTAssertEqual(Manifest.csv("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(Manifest.csv("plain"), "plain")
    }
}

final class PipelineTests: XCTestCase {
    private func fakes(_ n: Int) throws -> [FakeNode] {
        try (0..<n).map { i in
            let f = try FakeNode(uid: String(format: "30:ed:a0:00:00:%02x", i + 1))
            f.start()
            return f
        }
    }

    func testTenBoardsAtOnceEachGetTheirOwnID() async throws {
        let nodes = try fakes(10)
        defer { nodes.forEach { $0.stop() } }
        let ids = try NodeSettings.batchIDs(start: 101, end: 110, deviceCount: 10).get()
        let jobs = zip(nodes, ids).map { DeviceJob(port: $0.path, nodeID: $1) }
        let settings = NodeSettings(mode: .wifi, ssid: "EsanHouse", password: "secret-pass", gateway: "192.168.0.43", key: "k")
        let writer = FakeWriter(nodes: Dictionary(uniqueKeysWithValues: nodes.map { ($0.path, $0) }))
        let t0 = Date()
        let results = await Pipeline.run(jobs: jobs, settings: settings, writer: writer, options: .init(bootTimeout: 5, wifiTimeout: 5)) { _ in }
        XCTAssertEqual(results.map(\.ok), Array(repeating: true, count: 10), results.compactMap(\.error).joined(separator: "\n"))
        for (node, id) in zip(nodes, ids) {
            XCTAssertEqual(node.savedState["node_id"], String(id), "IDs follow port order")
            XCTAssertEqual(node.savedState["edges"], "192.168.0.43 ")
            XCTAssertEqual(node.savedState["password"], "(set)")
        }
        XCTAssertEqual(results.map(\.uid), nodes.map(\.uid))
        XCTAssertTrue(results.allSatisfy { $0.wifiIP != nil }, "each node was seen joining Wi-Fi")
        XCTAssertLessThan(Date().timeIntervalSince(t0), 8, "boards run in parallel, not one after another")
    }

    func testOneBadBoardDoesNotStopTheOthers() async throws {
        let nodes = try fakes(3)
        defer { nodes.forEach { $0.stop() } }
        nodes[1].refuse = "edges"
        var writer = FakeWriter(nodes: Dictionary(uniqueKeysWithValues: nodes.map { ($0.path, $0) }))
        writer.failPort = nodes[2].path
        let jobs = nodes.enumerated().map { DeviceJob(port: $1.path, nodeID: $0 + 1) }
        let results = await Pipeline.run(jobs: jobs, settings: NodeSettings(ssid: "N", password: "password1", gateway: "10.0.0.1", key: "k"),
                                         writer: writer, options: .init(bootTimeout: 5, wifiTimeout: 3)) { _ in }
        XCTAssertTrue(results[0].ok)
        XCTAssertEqual(results[1].error?.contains("refused"), true)
        XCTAssertNotEqual(nodes[1].savedState["node_id"], "2", "a refused setting means nothing was saved")
        XCTAssertEqual(results[2].error?.contains("Failed to connect"), true)
    }

    func testABoardThatNeverAnswersFailsInsteadOfHanging() async throws {
        let node = try FakeNode(uid: "30:ed:a0:00:00:99")
        node.silent = true
        node.start()
        defer { node.stop() }
        let t0 = Date()
        let r = await Pipeline.run(jobs: [DeviceJob(port: node.path, nodeID: 1)], settings: NodeSettings(), writer: nil,
                                   options: .init(bootTimeout: 2, wifiTimeout: 0)) { _ in }
        XCTAssertFalse(r[0].ok)
        XCTAssertEqual(r[0].error?.contains("no answer"), true)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 5)
    }

    func testSecretsNeverReachTheLog() async throws {
        let nodes = try fakes(1)
        defer { nodes.forEach { $0.stop() } }
        let lines = LogBox()
        _ = await Pipeline.run(jobs: [DeviceJob(port: nodes[0].path, nodeID: 5)],
                               settings: NodeSettings(ssid: "Net", password: "hunter2hunter2", gateway: "10.0.0.1", key: "topsecretkey"),
                               writer: nil, options: .init(bootTimeout: 5, wifiTimeout: 2)) { e in
            if case .log(_, let l) = e { lines.add(l) }
        }
        XCTAssertTrue(nodes[0].commands.contains("set pass hunter2hunter2"), "the node did receive it")
        XCTAssertFalse(lines.all.contains { $0.contains("hunter2") || $0.contains("topsecret") })
    }

    func testLoRaModeStoresTheGatewayAndSaysItCannotSendYet() async throws {
        let nodes = try fakes(1)
        defer { nodes.forEach { $0.stop() } }
        let r = await Pipeline.run(jobs: [DeviceJob(port: nodes[0].path, nodeID: 2)],
                                   settings: NodeSettings(mode: .lora, gateway: "10.1.1.1", key: "k"), writer: nil,
                                   options: .init(bootTimeout: 5, wifiTimeout: 5)) { _ in }
        XCTAssertTrue(r[0].ok, r[0].error ?? "")
        XCTAssertEqual(nodes[0].savedState["mode"], "lora")
        XCTAssertEqual(nodes[0].savedState["lora_gw"], "10.1.1.1")
        XCTAssertTrue(r[0].warnings.contains { $0.contains("no LoRa uplink yet") })
    }
}

final class LogBox: @unchecked Sendable {
    private let l = NSLock(); private var v: [String] = []
    func add(_ s: String) { l.lock(); v.append(s); l.unlock() }
    var all: [String] { l.lock(); defer { l.unlock() }; return v }
}
