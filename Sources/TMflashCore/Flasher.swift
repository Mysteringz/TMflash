import Foundation

/// Follows esptool's output: which image is being written, how far, the MAC.
public struct EsptoolProgress: Sendable {
    private let sizes: [Int]
    private var current = -1
    private var fraction = 0.0
    public private(set) var mac: String?
    public private(set) var chip: String?
    public private(set) var fatal: String?

    public init(imageSizes: [Int]) { sizes = imageSizes }

    /// 0...1 across all images, weighted by size.
    public var overall: Double {
        let total = sizes.reduce(0, +)
        guard total > 0, current >= 0 else { return 0 }
        let done = sizes.prefix(current).reduce(0, +)
        let cur = current < sizes.count ? Double(sizes[current]) * fraction : 0
        return min(1, (Double(done) + cur) / Double(total))
    }

    /// Feed one output line; true if the progress changed.
    @discardableResult
    public mutating func feed(_ line: String) -> Bool {
        if line.hasPrefix("MAC: ") { mac = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces).lowercased(); return false }
        if line.hasPrefix("Chip is ") { chip = String(line.dropFirst(8)); return false }
        if line.hasPrefix("A fatal error occurred:") { fatal = String(line.dropFirst("A fatal error occurred:".count)).trimmingCharacters(in: .whitespaces) }
        if line.hasPrefix("Compressed ") {   // one per image, before its writes
            current += 1
            fraction = 0
            return true
        }
        if line.hasPrefix("Writing at "), let open = line.lastIndex(of: "("), let pct = line[line.index(after: open)...].split(separator: " ").first,
           let v = Double(pct) {
            if current < 0 { current = 0 }
            fraction = v / 100
            return true
        }
        if line.hasPrefix("Wrote ") { fraction = 1; return true }
        return false
    }
}

public enum Flasher {
    /// Writes `build` to the board on `port`. Returns the MAC esptool read.
    public static func flash(_ build: FirmwareBuild, port: String, toolchain: Toolchain,
                             log: @escaping @Sendable (String) -> Void,
                             progress: @escaping @Sendable (Double) -> Void) async throws -> String? {
        guard toolchain.hasEsptool else { throw SerialError("esptool not found at \(toolchain.esptool); build the firmware once first") }
        let sizes = build.images.map { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int) ?? 0 }
        let state = ProgressBox(EsptoolProgress(imageSizes: sizes))
        let status = try await ProcessRunner.run(toolchain.python, [toolchain.esptool] + build.esptoolArguments(port: port)) { line in
            let changed = state.update { $0.feed(line) }
            if changed { progress(state.value.overall) }
            if !line.hasPrefix("Writing at ") { log(line) }
        }
        let p = state.value
        guard status == 0 else {
            var msg = p.fatal ?? "esptool failed (exit \(status))"
            if msg.contains("Failed to connect") || msg.contains("No serial data") {
                msg += " — hold the board's PRG/BOOT button, tap RST, and try again"
            }
            throw SerialError(msg)
        }
        progress(1)
        return p.mac
    }
}

final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v: EsptoolProgress
    init(_ v: EsptoolProgress) { self.v = v }
    var value: EsptoolProgress { lock.lock(); defer { lock.unlock() }; return v }
    func update(_ f: (inout EsptoolProgress) -> Bool) -> Bool { lock.lock(); defer { lock.unlock() }; return f(&v) }
}
