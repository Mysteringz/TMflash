import CryptoKit
import Foundation
import XCTest
@testable import TMflashCore

final class PortableFirmwareTests: XCTestCase {
    private func fixture() throws -> URL {
        let resources = FileManager.default.temporaryDirectory.appendingPathComponent("tmflash-portable-\(UUID().uuidString)")
        let dir = resources.appendingPathComponent("Firmware")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var image = Data(repeating: 0, count: 24)
        image[0] = 0xE9; image[3] = 0x3F; image[12] = 9
        try image.write(to: dir.appendingPathComponent("bootloader.bin"))
        image.append(Data("tmsense-1.8\0".utf8))
        try image.write(to: dir.appendingPathComponent("firmware.bin"))
        var table = Data()
        func add(_ type: UInt8, _ subtype: UInt8, _ offset: UInt32, _ size: UInt32) {
            var entry = Data([0xAA, 0x50, type, subtype])
            for value in [offset, size] { entry.append(contentsOf: (0..<4).map { UInt8((value >> ($0 * 8)) & 0xFF) }) }
            entry.append(Data(repeating: 0, count: 20))
            table.append(entry)
        }
        add(1, 2, 0x9000, 0x5000)
        add(1, 0, 0xE000, 0x2000)
        add(0, 0x10, 0x10000, 0x330000)
        appendTableChecksum(&table)
        try table.write(to: dir.appendingPathComponent("partitions.bin"))
        var selector = Data(repeating: 0xFF, count: 0x2000)
        selector.replaceSubrange(0..<4, with: [1, 0, 0, 0])
        selector.replaceSubrange(28..<32, with: [0x9A, 0x98, 0x43, 0x47])
        selector.replaceSubrange(0x1000..<0x1004, with: [0, 0, 0, 0])
        try selector.write(to: dir.appendingPathComponent("boot_app0.bin"))
        try manifest(resources)
        return resources
    }

    private func appendTableChecksum(_ table: inout Data) {
        let digest = Data(Insecure.MD5.hash(data: table))
        table.append(contentsOf: [0xEB, 0xEB] + Array(repeating: UInt8(0xFF), count: 14))
        table.append(digest)
    }

    private func manifest(_ resources: URL, change: (inout [String: Any]) -> Void = { _ in }) throws {
        let directory = resources.appendingPathComponent("Firmware")
        let images: [[String: Any]] = try ["bootloader.bin", "partitions.bin", "firmware.bin"].map { name in
            let bytes = try Data(contentsOf: directory.appendingPathComponent(name))
            return ["name": name, "size": bytes.count, "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()]
        }
        var m: [String: Any] = ["format": 1, "project": "TMsense", "board": "heltec_wifi_lora_32_V3", "version": "tmsense-1.8",
                                "tag": "v1.8", "commit": String(repeating: "a", count: 40), "files": images]
        change(&m)
        try JSONSerialization.data(withJSONObject: m).write(to: directory.appendingPathComponent("tmflash-manifest.json"))
    }

    func testACompleteBundledReleaseNeedsNeitherSourceNorPlatformIOAndPreservesNVS() throws {
        let resources = try fixture()
        defer { try? FileManager.default.removeItem(at: resources) }
        let release = try XCTUnwrap(PortableFirmware.load(resources: resources))
        XCTAssertEqual(release.version, "tmsense-1.8")
        XCTAssertEqual(release.build.images.map(\.offset), ["0x0", "0x8000", "0xe000", "0x10000"])
        let args = release.build.esptoolArguments(port: "/dev/cu.test")
        XCTAssertFalse(args.contains("erase_flash") || args.contains("--erase-all"))
        XCTAssertFalse(args.contains("0x9000"), "the NVS partition is never written")
    }

    func testDamagedOrMissingImagesAreRefusedBeforeAWriterCanUseThem() throws {
        let resources = try fixture()
        defer { try? FileManager.default.removeItem(at: resources) }
        let file = resources.appendingPathComponent("Firmware/firmware.bin")
        var bytes = try Data(contentsOf: file)
        bytes[24] ^= 1
        try bytes.write(to: file)
        XCTAssertThrowsError(try PortableFirmware.load(resources: resources))
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try PortableFirmware.load(resources: resources))
    }

    func testManifestsCannotChangeBoardsFormatsVersionsOrImageNames() throws {
        let resources = try fixture()
        defer { try? FileManager.default.removeItem(at: resources) }
        for (key, value) in [("board", "another-board"), ("project", "another-project"), ("version", "tmsense-1.9"), ("tag", "v9"), ("commit", "abc")] {
            try manifest(resources) { $0[key] = value }
            XCTAssertThrowsError(try PortableFirmware.load(resources: resources), key)
        }
        try manifest(resources) { $0["format"] = 2 }
        XCTAssertThrowsError(try PortableFirmware.load(resources: resources))
        try manifest(resources) { m in
            var files = m["files"] as? [[String: Any]] ?? []
            files[0]["name"] = "../outside.bin"
            m["files"] = files
        }
        XCTAssertThrowsError(try PortableFirmware.load(resources: resources))
    }

    func testAValidHashCannotMakeFirmwareForAnotherChipAcceptable() throws {
        let resources = try fixture()
        defer { try? FileManager.default.removeItem(at: resources) }
        let file = resources.appendingPathComponent("Firmware/firmware.bin")
        var data = try Data(contentsOf: file)
        data[12] = 0
        try data.write(to: file)
        try manifest(resources)
        XCTAssertThrowsError(try PortableFirmware.load(resources: resources))
    }

    func testPartitionChecksProtectSettingsEvenWhenTheManifestHashesAreUpdated() throws {
        let resources = try fixture()
        defer { try? FileManager.default.removeItem(at: resources) }
        let file = resources.appendingPathComponent("Firmware/partitions.bin")
        var table = try Data(contentsOf: file)
        table = table.prefix(96)
        // Move the first OTA slot on top of NVS, then repair both checksums.
        table.replaceSubrange(68..<72, with: [0, 0x90, 0, 0])
        appendTableChecksum(&table)
        try table.write(to: file)
        try manifest(resources)
        XCTAssertThrowsError(try PortableFirmware.load(resources: resources))
    }

    func testAChangedBootSelectorAndATruncatedTableAreRefused() throws {
        let resources = try fixture()
        defer { try? FileManager.default.removeItem(at: resources) }
        let selector = resources.appendingPathComponent("Firmware/boot_app0.bin")
        try Data(repeating: 0, count: 8192).write(to: selector)
        XCTAssertThrowsError(try PortableFirmware.load(resources: resources))
        try Data([0xAA, 0x50]).write(to: resources.appendingPathComponent("Firmware/partitions.bin"))
        try manifest(resources)
        XCTAssertThrowsError(try PortableFirmware.load(resources: resources))
    }

    func testSourceBuildsStillUsePythonWhilePortableBuildsRunTheirOwnExecutable() async throws {
        let resources = try fixture()
        defer { try? FileManager.default.removeItem(at: resources) }
        let release = try XCTUnwrap(PortableFirmware.load(resources: resources))
        let executable = resources.appendingPathComponent("fake-esptool")
        try Data("#!/bin/sh\nprintf 'MAC: 02:00:00:00:00:03\\n'\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let portable = Toolchain(pio: "", python: "", esptool: executable.path, standalone: true)
        XCTAssertEqual(portable.flashCommand(release.build, port: "fake").executable, executable.path)
        let mac = try await Flasher.flash(release.build, port: "fake", toolchain: portable, log: { _ in }, progress: { _ in })
        XCTAssertEqual(mac, "02:00:00:00:00:03")
        let source = Toolchain(pio: "pio", python: "python", esptool: "esptool.py")
        XCTAssertEqual(source.flashCommand(release.build, port: "fake").executable, "python")
        XCTAssertEqual(source.flashCommand(release.build, port: "fake").arguments.first, "esptool.py")
    }
}
