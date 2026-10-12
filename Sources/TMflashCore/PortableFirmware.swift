import CryptoKit
import Foundation

public enum AppResources {
    /// Both executables live in Contents/MacOS. Resolving from the executable
    /// keeps the CLI portable even when Foundation treats it as a plain tool.
    public static var directory: URL? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let macOS = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", macOS.deletingLastPathComponent().lastPathComponent == "Contents" else { return nil }
        return macOS.deletingLastPathComponent().appendingPathComponent("Resources", isDirectory: true)
    }
}

/// A checked, published release carried inside the app. A damaged bundle
/// must fail before USB writes, rather than fall back to a local source tree.
public struct PortableFirmware: Sendable {
    public let version: String
    public let tag: String
    public let commit: String
    public let build: FirmwareBuild

    private struct Manifest: Decodable {
        let format: Int
        let project: String
        let board: String
        let version: String
        let tag: String
        let commit: String
        let files: [Image]
    }
    private struct Image: Decodable {
        let name: String
        let size: Int
        let sha256: String
    }
    private struct Partition {
        let type: UInt8
        let subtype: UInt8
        let offset: Int
        let size: Int
    }

    public static func load(resources: URL? = AppResources.directory) throws -> PortableFirmware? {
        guard let resources else { return nil }
        let directory = resources.appendingPathComponent("Firmware", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        do {
            let manifestData = try read(directory.appendingPathComponent("tmflash-manifest.json"), limit: 16 * 1024)
            let m = try JSONDecoder().decode(Manifest.self, from: manifestData)
            guard m.format == 1, m.project == "TMsense", m.board == "heltec_wifi_lora_32_V3",
                  matches(m.version, "^tmsense-[0-9]+\\.[0-9]+(\\.[0-9]+)?$"), m.version.count <= 12,
                  m.tag == "v" + String(m.version.dropFirst("tmsense-".count)), matches(m.commit, "^[0-9a-f]{40}$") else {
                throw SerialError("the included firmware manifest is not a supported TMsense release")
            }
            let limits = ["bootloader.bin": 0x8000, "partitions.bin": 0xC00, "firmware.bin": 0x330000]
            guard m.files.count == limits.count, Set(m.files.map(\.name)) == Set(limits.keys) else {
                throw SerialError("the included release must list each of its three images exactly once")
            }
            var data: [String: Data] = [:]
            for image in m.files {
                guard let limit = limits[image.name], image.size > 0, image.size <= limit,
                      matches(image.sha256, "^[0-9a-f]{64}$") else {
                    throw SerialError("the included release has invalid file sizes or hashes")
                }
                let bytes = try read(directory.appendingPathComponent(image.name), limit: limit)
                guard bytes.count == image.size, hash(bytes) == image.sha256 else {
                    throw SerialError("the included \(image.name) failed its size or SHA-256 check")
                }
                data[image.name] = bytes
            }
            guard let boot = data["bootloader.bin"], let table = data["partitions.bin"], let app = data["firmware.bin"] else {
                throw SerialError("the included firmware is incomplete")
            }
            for bytes in [boot, app] {
                guard bytes.count >= 24, bytes[0] == 0xE9, bytes[12] == 9, bytes[13] == 0 else {
                    throw SerialError("the included firmware was not built for an ESP32-S3")
                }
            }
            guard boot[3] >> 4 == 3, app.range(of: Data((m.version + "\0").utf8)) != nil else {
                throw SerialError("the included firmware does not match its version or the board's 8 MB flash")
            }
            let partitions = try parsePartitions(table)
            let selectors = partitions.filter { $0.type == 1 && $0.subtype == 0 }
            let slots = partitions.filter { $0.type == 0 && $0.subtype == 0x10 }
            guard selectors.count == 1, slots.count == 1, let selector = selectors.first, let slot = slots.first,
                  selector.size == 0x2000,
                  partitions.contains(where: { $0.type == 1 && $0.subtype == 2 }) else {
                throw SerialError("the included partition table needs NVS, a boot selector and the first OTA slot")
            }
            // A previously updated board can be booting slot two. The same
            // selector PlatformIO writes makes the newly written slot one boot.
            let bootSelector = try read(directory.appendingPathComponent("boot_app0.bin"), limit: 0x2000)
            guard bootSelector.count == selector.size,
                  hash(bootSelector) == "f94c5d786a7a8fab06ac5d10e33bf37711a6697636dc037559ea19cc410a17f0" else {
                throw SerialError("the included boot selector is damaged")
            }
            let regions = [(0, boot.count), (0x8000, table.count), (selector.offset, bootSelector.count), (slot.offset, app.count)]
            guard app.count <= slot.size else { throw SerialError("the included application does not fit its OTA slot") }
            for (index, region) in regions.enumerated() {
                let end = region.0 + ((region.1 + 0xFFF) / 0x1000) * 0x1000
                for p in partitions {
                    let ownPartition = (index == 2 && p.type == 1 && p.subtype == 0) || (index == 3 && p.type == 0 && p.subtype == 0x10)
                    if !ownPartition, region.0 < p.offset + p.size, end > p.offset {
                        throw SerialError("the included flash layout would overwrite a preserved partition")
                    }
                }
            }
            let offsets = ["bootloader.bin": "0x0", "partitions.bin": "0x8000", "boot_app0.bin": String(format: "0x%x", selector.offset),
                           "firmware.bin": String(format: "0x%x", slot.offset)]
            let images = try ["bootloader.bin", "partitions.bin", "boot_app0.bin", "firmware.bin"].map { name -> FlashImage in
                guard let offset = offsets[name] else { throw SerialError("the included flash layout is incomplete") }
                return FlashImage(offset: offset, path: directory.appendingPathComponent(name).path)
            }
            let build = FirmwareBuild(chip: "esp32s3", baud: 460800, flashMode: "dio", flashFreq: "80m", flashSize: "8MB", images: images, version: m.version)
            return PortableFirmware(version: m.version, tag: m.tag, commit: m.commit, build: build)
        } catch let error as SerialError {
            throw error
        } catch {
            throw SerialError("cannot read the included firmware: \(error.localizedDescription)")
        }
    }

    private static func read(_ url: URL, limit: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: limit + 1) ?? Data()
        guard !bytes.isEmpty, bytes.count <= limit else { throw SerialError("the included \(url.lastPathComponent) has an invalid size") }
        return bytes
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) == value.startIndex..<value.endIndex
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func parsePartitions(_ data: Data) throws -> [Partition] {
        var partitions: [Partition] = []
        var checked = false
        func integer(_ offset: Int) -> Int {
            (0..<4).reduce(0) { $0 | (Int(data[offset + $1]) << ($1 * 8)) }
        }
        for offset in stride(from: 0, to: data.count - 31, by: 32) {
            if data[offset] == 0xEB, data[offset + 1] == 0xEB {
                let digest = Data(Insecure.MD5.hash(data: data.prefix(offset)))
                guard digest == data.subdata(in: (offset + 16)..<(offset + 32)) else {
                    throw SerialError("the included partition table failed its checksum")
                }
                checked = true
                break
            }
            guard data[offset] == 0xAA, data[offset + 1] == 0x50 else { break }
            let p = Partition(type: data[offset + 2], subtype: data[offset + 3], offset: integer(offset + 4), size: integer(offset + 8))
            guard p.offset >= 0x9000, p.offset % 0x1000 == 0, p.size > 0, p.size % 0x1000 == 0, p.offset + p.size <= 8 * 1024 * 1024,
                  !partitions.contains(where: { p.offset < $0.offset + $0.size && p.offset + p.size > $0.offset }) else {
                throw SerialError("the included partition table has overlapping or out-of-range partitions")
            }
            partitions.append(p)
        }
        guard checked, !partitions.isEmpty else { throw SerialError("the included partition table is incomplete") }
        return partitions
    }
}
