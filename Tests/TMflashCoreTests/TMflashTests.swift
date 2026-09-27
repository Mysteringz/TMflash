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

final class DirectCloudTests: XCTestCase {
    private let url = "wss://sense.hkumyseat.com/tmnode"

    private func node(_ uid: String, cloud: Bool = true) throws -> FakeNode {
        let f = try FakeNode(uid: uid)
        f.directCloud = cloud
        f.start()
        return f
    }

    func testCloudURLsAreRefusedExactlyAsTheFirmwareRefusesThem() {
        XCTAssertNil(NodeSettings.cloudURLProblem(url))
        XCTAssertNil(NodeSettings.cloudURLProblem("wss://sense.hkumyseat.com:443/tmnode"))
        for bad in ["ws://sense.hkumyseat.com/tmnode", "https://sense.hkumyseat.com/tmnode", "wss://sense.hkumyseat.com:8443/tmnode",
                    "wss://u:p@sense.hkumyseat.com/tmnode", "wss://sense.hkumyseat.com/tmnode?k=1", "wss://sense.hkumyseat.com/tmnode#x",
                    "wss://Sense.hkumyseat.com/tmnode", "wss://13.251.45.51/tmnode", "wss://sense.hkumyseat.com", "wss://sense.hkumyseat.com/",
                    "wss://sense.hkumyseat.com/a/../b", "wss://sense.hkumyseat.com//x", "wss://sense.hkumyseat.com/tm node",
                    "wss://sense.hkumyseat.com/tm%20node", "wss://-x.example.com/tmnode", ""] {
            XCTAssertNotNil(NodeSettings.cloudURLProblem(bad), bad)
        }
        let longest = "wss://" + String(repeating: "a", count: 60) + ".example.com/" + String(repeating: "p", count: 49)
        XCTAssertEqual(longest.utf8.count, 128)
        XCTAssertNil(NodeSettings.cloudURLProblem(longest), "128 bytes is allowed, as on the node")
        XCTAssertNotNil(NodeSettings.cloudURLProblem(longest + "p"), "129 is refused, never truncated")
        XCTAssertEqual(NodeSettings.canonicalCloudURL(" WSS://Sense.HKUMySeat.com:443/tmnode "), url, "one canonical spelling is what is sent")
        XCTAssertFalse(NodeSettings(mode: .lora, transport: .wss, cloudURL: url).problems().isEmpty, "LoRa has no wss")
        XCTAssertFalse(NodeSettings(transport: .wss, cloudURL: "wss://x.example.com/a\nset key k").problems().isEmpty, "no line breaks")
    }

    func testSettingsSavedBeforeDirectCloudStillDecodeAsUDP() throws {
        let old = #"{"mode":"wifi","ssid":"EsanHouse","password":"","gateway":"192.168.0.43","key":""}"#
        let s = try JSONDecoder().decode(NodeSettings.self, from: Data(old.utf8))
        XCTAssertEqual(s.transport, .udp)
        XCTAssertEqual(s.cloudURL, "")
        XCTAssertEqual(s.gateway, "192.168.0.43")
        let round = try JSONDecoder().decode(NodeSettings.self, from: JSONEncoder().encode(NodeSettings(transport: .wss, cloudURL: url)))
        XCTAssertEqual(round.transport, .wss)
    }

    func testCloudCommandsGoOnlyToFirmwareThatHasThem() {
        let s = NodeSettings(ssid: "Net", transport: .wss, cloudURL: url)
        XCTAssertEqual(ConsoleCommand.provisioning(id: 3, settings: s, directCloud: true).map(\.line),
                       ["set id 3", "set mode wifi", "set ssid Net", "set cloud_url \(url)", "set transport wss", "save"],
                       "the URL first: the firmware refuses transport wss without one")
        XCTAssertFalse(ConsoleCommand.provisioning(id: 3, settings: NodeSettings(ssid: "Net"), directCloud: false).map(\.line)
            .contains { $0.hasPrefix("set transport") || $0.hasPrefix("set cloud_url") }, "old firmware is never sent the new commands")
        XCTAssertEqual(ConsoleCommand.provisioning(id: 4, settings: NodeSettings(mode: .lora, gateway: "10.0.0.3"), directCloud: true).map(\.line),
                       ["set id 4", "set transport udp", "set mode lora", "set lora_gw 10.0.0.3", "save"])
        let longest = "wss://" + String(repeating: "a", count: 60) + ".example.com/" + String(repeating: "p", count: 49)
        let line = ConsoleCommand.provisioning(id: 1, settings: NodeSettings(transport: .wss, cloudURL: longest), directCloud: true)
            .first { $0.line.hasPrefix("set cloud_url") }?.line ?? ""
        XCTAssertLessThan(line.utf8.count, 160, "the longest URL still fits the firmware's console line")
    }

    func testDirectCloudProvisioningWaitsForTheEdgeNotJustWiFi() async throws {
        let n = try node("30:ed:a0:00:01:01")
        defer { n.stop() }
        let r = await Pipeline.run(jobs: [DeviceJob(port: n.path, nodeID: 7)],
                                   settings: NodeSettings(ssid: "Net", password: "password1", gateway: "192.168.0.43", key: "k", transport: .wss, cloudURL: url),
                                   writer: nil, options: .init(bootTimeout: 5, wifiTimeout: 5, edgeTimeout: 5)) { _ in }
        XCTAssertTrue(r[0].ok, r[0].error ?? "")
        XCTAssertEqual(n.savedState["transport"], "wss")
        XCTAssertEqual(n.savedState["cloud_url"], url)
        XCTAssertEqual(n.savedState["edges"], "192.168.0.43 ", "the UDP destination is kept for a rollback")
        XCTAssertNotNil(r[0].wifiIP)
        XCTAssertEqual(r[0].edgeAccepted, true)
        XCTAssertEqual(r[0].transport, .wss)
    }

    func testJoiningWiFiIsNotReportedAsReachingTheEdge() async throws {
        let n = try node("30:ed:a0:00:01:02")
        n.edgeAccepts = false
        defer { n.stop() }
        let r = await Pipeline.run(jobs: [DeviceJob(port: n.path, nodeID: 8)],
                                   settings: NodeSettings(ssid: "Net", password: "password1", key: "k", transport: .wss, cloudURL: url),
                                   writer: nil, options: .init(bootTimeout: 5, wifiTimeout: 5, edgeTimeout: 2)) { _ in }
        XCTAssertNotNil(r[0].wifiIP, "it did join Wi-Fi")
        XCTAssertEqual(r[0].edgeAccepted, false)
        XCTAssertTrue(r[0].warnings.contains { $0.contains("did not accept a report") && $0.contains("certificate refused") }, r[0].warnings.joined())
    }

    func testOldFirmwareIsNeverQuietlyLeftOnUDPWhenCloudWasAskedFor() async throws {
        let n = try node("30:ed:a0:00:01:03", cloud: false)
        defer { n.stop() }
        let r = await Pipeline.run(jobs: [DeviceJob(port: n.path, nodeID: 9)],
                                   settings: NodeSettings(ssid: "Net", transport: .wss, cloudURL: url), writer: nil,
                                   options: .init(bootTimeout: 5, wifiTimeout: 0)) { _ in }
        XCTAssertFalse(r[0].ok)
        XCTAssertEqual(r[0].error?.contains("no direct-to-cloud transport"), true)
        XCTAssertTrue(n.commands.allSatisfy { $0 == "show" }, "nothing was written before the refusal")
    }

    func testOldFirmwareStillProvisionsForUDPExactlyAsBefore() async throws {
        let n = try node("30:ed:a0:00:01:04", cloud: false)
        defer { n.stop() }
        let r = await Pipeline.run(jobs: [DeviceJob(port: n.path, nodeID: 10)],
                                   settings: NodeSettings(ssid: "Net", password: "password1", gateway: "10.0.0.2", key: "k"), writer: nil,
                                   options: .init(bootTimeout: 5, wifiTimeout: 5)) { _ in }
        XCTAssertTrue(r[0].ok, r[0].error ?? "")
        XCTAssertNil(r[0].edgeAccepted, "UDP has no acknowledgement to wait for")
        XCTAssertFalse(n.commands.contains { $0.contains("transport") || $0.contains("cloud_url") })
    }

    func testBlankCloudFieldsKeepWhatTheNodeHas() async throws {
        let n = try node("30:ed:a0:00:01:05")
        defer { n.stop() }
        _ = await Pipeline.run(jobs: [DeviceJob(port: n.path, nodeID: 11)],
                               settings: NodeSettings(ssid: "Net", password: "password1", key: "k", transport: .wss, cloudURL: url), writer: nil,
                               options: .init(bootTimeout: 5, wifiTimeout: 0)) { _ in }
        // Re-provision later with the URL left blank: it stays.
        let r = await Pipeline.run(jobs: [DeviceJob(port: n.path, nodeID: 11)],
                                   settings: NodeSettings(transport: .wss), writer: nil, options: .init(bootTimeout: 5, wifiTimeout: 0)) { _ in }
        XCTAssertTrue(r[0].ok, r[0].error ?? "")
        XCTAssertEqual(n.savedState["cloud_url"], url)
        XCTAssertEqual(n.savedState["password"], "(set)")
    }

    func testAnOverlongLineIsRefusedWholeByTheFirmware() throws {
        let n = try node("30:ed:a0:00:01:06")
        defer { n.stop() }
        let port = try SerialPort(path: n.path)
        defer { port.close() }
        let console = NodeConsole(port: port, log: { _ in })
        _ = try console.waitUntilReady(timeout: 5)
        let long = ConsoleCommand(line: "set cloud_url wss://x.example.com/" + String(repeating: "a", count: 150), expect: "cloud_url updated", display: "long")
        XCTAssertThrowsError(try console.run(long)) { XCTAssertTrue(String(describing: $0).contains("line too long")) }
        XCTAssertEqual(n.savedState["cloud_url"], "(none)")
    }

    func testManifestFromBeforeDirectCloudIsWidenedNotBroken() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "manifest-\(UUID().uuidString).csv")
        try (Manifest.headerV1 + "2026-09-20T00:00:00Z,3,30:ed:a0:cb:f5:f8,wifi,192.168.0.43,EsanHouse,tmsense-1.1,/dev/x,,ok,\n")
            .write(to: url, atomically: true, encoding: .utf8)
        var r = JobResult(job: DeviceJob(port: "/dev/y", nodeID: 4), uid: "aa:bb:cc:dd:ee:ff", firmware: "tmsense-1.4", wifiIP: "10.0.0.9")
        r.transport = .wss
        r.cloudURL = self.url
        r.edgeAccepted = true
        try Manifest.append([r], settings: NodeSettings(transport: .wss, cloudURL: self.url), to: url)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0] + "\n", Manifest.header)
        XCTAssertTrue(lines[1].hasPrefix("2026-09-20T00:00:00Z,3,"), "the old row is kept")
        XCTAssertTrue(lines[2].hasSuffix(",wss,\(self.url),yes"), lines[2])
    }
}

final class LogBox: @unchecked Sendable {
    private let l = NSLock(); private var v: [String] = []
    func add(_ s: String) { l.lock(); v.append(s); l.unlock() }
    var all: [String] { l.lock(); defer { l.unlock() }; return v }
}
