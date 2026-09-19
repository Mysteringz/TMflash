import Foundation

/// PlatformIO (to build TMsense) and the esptool it ships (to flash it).
public struct Toolchain: Sendable {
    public let pio: String
    public let python: String
    public let esptool: String

    public init(pio: String, python: String, esptool: String) {
        self.pio = pio
        self.python = python
        self.esptool = esptool
    }

    public static var platformioHome: String {
        ProcessInfo.processInfo.environment["PLATFORMIO_CORE_DIR"] ?? (NSHomeDirectory() + "/.platformio")
    }

    /// Finds PlatformIO. esptool is installed by the first ESP32 build, so it
    /// may legitimately be missing until then.
    public static func locate() -> Toolchain? {
        let fm = FileManager.default
        let home = platformioHome
        let candidates = [home + "/penv/bin/pio", "/opt/homebrew/bin/pio", "/usr/local/bin/pio"]
        guard let pio = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) else { return nil }
        let penvPython = home + "/penv/bin/python"
        let python = fm.isExecutableFile(atPath: penvPython) ? penvPython : "/usr/bin/python3"
        return Toolchain(pio: pio, python: python, esptool: home + "/packages/tool-esptoolpy/esptool.py")
    }

    public var hasEsptool: Bool { FileManager.default.fileExists(atPath: esptool) }
}

public struct FlashImage: Equatable, Sendable {
    public let offset: String
    public let path: String
}

/// A built TMsense firmware: what to write where, and how.
public struct FirmwareBuild: Equatable, Sendable {
    public let chip: String
    public let baud: Int
    public let flashMode: String
    public let flashFreq: String
    public let flashSize: String
    public let images: [FlashImage]
    public let version: String?

    public var totalBytes: Int {
        images.reduce(0) { $0 + ((try? FileManager.default.attributesOfItem(atPath: $1.path)[.size] as? Int) ?? 0) }
    }

    /// esptool arguments for one port. `--before default_reset` puts the chip
    /// in its bootloader via DTR/RTS; `--after hard_reset` starts the new
    /// firmware. No erase: the node's saved settings and boot counter live in
    /// NVS and must survive (a reset boot counter looks like a replay to TMedge).
    public func esptoolArguments(port: String) -> [String] {
        ["--chip", chip, "--port", port, "--baud", String(baud), "--before", "default_reset", "--after", "hard_reset",
         "write_flash", "-z", "--flash_mode", flashMode, "--flash_freq", flashFreq, "--flash_size", flashSize]
            + images.flatMap { [$0.offset, $0.path] }
    }
}

public enum FirmwareProject {
    public static let environment = "tmflash"

    /// The TMsense folder: `TMSENSE_DIR`, the path the app was built with, or
    /// a sibling of the current directory.
    public static func defaultDirectory(bundleHint: String? = nil) -> String? {
        let fm = FileManager.default
        let candidates = [ProcessInfo.processInfo.environment["TMSENSE_DIR"], bundleHint,
                          fm.currentDirectoryPath + "/../TMsense", fm.currentDirectoryPath + "/TMsense"]
        return candidates.compactMap { $0 }.map { ($0 as NSString).standardizingPath }
            .first { fm.fileExists(atPath: $0 + "/platformio.ini") }
    }

    public static func isProject(_ dir: String) -> Bool {
        guard let ini = try? String(contentsOfFile: dir + "/platformio.ini", encoding: .utf8) else { return false }
        return ini.contains("[env:\(environment)]")
    }

    /// Firmware version string from include/tm_config.h, for the manifest.
    public static func version(in dir: String) -> String? {
        guard let h = try? String(contentsOfFile: dir + "/include/tm_config.h", encoding: .utf8) else { return nil }
        for line in h.split(separator: "\n") where line.contains("#define TM_FW_VERSION") {
            let parts = line.split(separator: "\"")
            if parts.count >= 2 { return String(parts[1]) }
        }
        return nil
    }

    /// Builds the release image and returns what to flash.
    public static func build(dir: String, toolchain: Toolchain, log: @escaping @Sendable (String) -> Void) async throws -> FirmwareBuild {
        guard isProject(dir) else {
            throw SerialError("\(dir) is not a TMsense project with an [env:\(environment)] section")
        }
        log("Building TMsense firmware (pio run -e \(environment))…")
        let status = try await ProcessRunner.run(toolchain.pio, ["run", "-e", environment, "-d", dir], onLine: { line in
            // Compiler lines are long and many; keep what a person needs.
            if line.hasPrefix("Compiling") || line.hasPrefix("Archiving") || line.hasPrefix("Indexing") { return }
            log(line)
        })
        guard status == 0 else { throw SerialError("firmware build failed (pio exit \(status)); see the log") }
        let json = TextBox()
        let ms = try await ProcessRunner.run(toolchain.pio, ["project", "metadata", "-e", environment, "-d", dir, "--json-output"],
                                             onLine: { json.append($0 + "\n") })
        guard ms == 0 else { throw SerialError("could not read build metadata (pio exit \(ms))") }
        return try parseMetadata(json.text, boardFlashSize: "8MB", version: version(in: dir))
    }

    /// Reads `pio project metadata --json-output`. It lists the bootloader,
    /// partition table and boot_app0 with offsets; the application goes at
    /// `application_offset`.
    static func parseMetadata(_ text: String, boardFlashSize: String, version: String?) throws -> FirmwareBuild {
        // pio may print notices before the JSON.
        guard let start = text.firstIndex(of: "{"),
              let obj = try JSONSerialization.jsonObject(with: Data(text[start...].utf8)) as? [String: Any],
              let env = obj[environment] as? [String: Any],
              let extra = env["extra"] as? [String: Any],
              let prog = env["prog_path"] as? String else {
            throw SerialError("unexpected build metadata from PlatformIO")
        }
        var images: [FlashImage] = []
        for case let img as [String: Any] in (extra["flash_images"] as? [Any]) ?? [] {
            if let off = img["offset"] as? String, let path = img["path"] as? String { images.append(.init(offset: off, path: path)) }
        }
        let appOffset = (extra["application_offset"] as? String) ?? "0x10000"
        let bin = (prog as NSString).deletingPathExtension + ".bin"
        images.append(.init(offset: appOffset, path: bin))
        for i in images where !FileManager.default.fileExists(atPath: i.path) {
            throw SerialError("build output missing: \(i.path)")
        }
        // ESP32-S3 Heltec V3. PlatformIO's espressif32 writes QIO boards as
        // "dio" (the bootloader switches modes itself); 460800 is the board's
        // upload speed, which the CP2102 handles reliably.
        return FirmwareBuild(chip: "esp32s3", baud: 460800, flashMode: "dio", flashFreq: "80m",
                             flashSize: boardFlashSize, images: images, version: version)
    }
}

final class TextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buf = ""
    func append(_ s: String) { lock.lock(); buf += s; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return buf }
}
