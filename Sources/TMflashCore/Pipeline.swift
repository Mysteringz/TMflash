import Foundation

/// Writes firmware to one board. A protocol so tests can stand in for esptool.
public protocol FirmwareWriter: Sendable {
    /// Returns the board's MAC if the tool reported it.
    func write(port: String, log: @escaping @Sendable (String) -> Void, progress: @escaping @Sendable (Double) -> Void) async throws -> String?
}

public struct EsptoolWriter: FirmwareWriter {
    public let build: FirmwareBuild
    public let toolchain: Toolchain
    public init(build: FirmwareBuild, toolchain: Toolchain) { self.build = build; self.toolchain = toolchain }
    public func write(port: String, log: @escaping @Sendable (String) -> Void, progress: @escaping @Sendable (Double) -> Void) async throws -> String? {
        try await Flasher.flash(build, port: port, toolchain: toolchain, log: log, progress: progress)
    }
}

public struct DeviceJob: Hashable, Sendable {
    public let port: String
    public let nodeID: Int
    public init(port: String, nodeID: Int) { self.port = port; self.nodeID = nodeID }
}

public enum JobStage: Equatable, Sendable {
    case queued
    case flashing(Double)
    case connecting
    case provisioning
    case joiningWiFi
    case done
    case failed

    public var label: String {
        switch self {
        case .queued: return "Waiting"
        case .flashing(let p): return "Writing firmware \(Int(p * 100))%"
        case .connecting: return "Waiting for the node to boot"
        case .provisioning: return "Writing settings"
        case .joiningWiFi: return "Checking it joins Wi-Fi"
        case .done: return "Done"
        case .failed: return "Failed"
        }
    }
}

public struct JobResult: Equatable, Sendable {
    public let job: DeviceJob
    public var uid: String?
    public var firmware: String?
    public var wifiIP: String?
    public var warnings: [String] = []
    public var error: String?
    public var ok: Bool { error == nil }

    public init(job: DeviceJob, uid: String? = nil, firmware: String? = nil, wifiIP: String? = nil,
                warnings: [String] = [], error: String? = nil) {
        self.job = job; self.uid = uid; self.firmware = firmware; self.wifiIP = wifiIP
        self.warnings = warnings; self.error = error
    }
}

public struct PipelineOptions: Sendable {
    /// Seconds for the node to answer after a reset.
    public var bootTimeout: TimeInterval = 25
    /// Reboot after saving and wait this long for the Wi-Fi join line; 0 = skip.
    public var wifiTimeout: TimeInterval = 30
    public init(bootTimeout: TimeInterval = 25, wifiTimeout: TimeInterval = 30) {
        self.bootTimeout = bootTimeout
        self.wifiTimeout = wifiTimeout
    }
}

public enum PipelineEvent: Sendable {
    case stage(port: String, JobStage)
    case log(port: String, String)
    case finished(JobResult)
}

public enum Pipeline {
    /// Flashes (if `writer` is given) and provisions every job concurrently.
    /// One board failing never stops the others.
    public static func run(jobs: [DeviceJob], settings: NodeSettings, writer: FirmwareWriter?,
                           options: PipelineOptions = .init(),
                           events: @escaping @Sendable (PipelineEvent) -> Void) async -> [JobResult] {
        await withTaskGroup(of: JobResult.self) { group in
            for job in jobs {
                group.addTask { await runOne(job, settings: settings, writer: writer, options: options, events: events) }
            }
            var out: [JobResult] = []
            for await r in group { out.append(r) }
            return jobs.compactMap { j in out.first { $0.job == j } }
        }
    }

    static func runOne(_ job: DeviceJob, settings: NodeSettings, writer: FirmwareWriter?, options: PipelineOptions,
                       events: @escaping @Sendable (PipelineEvent) -> Void) async -> JobResult {
        let port = job.port
        let log: @Sendable (String) -> Void = { events(.log(port: port, $0)) }
        var result = JobResult(job: job)
        do {
            if let writer {
                events(.stage(port: port, .flashing(0)))
                result.uid = try await writer.write(port: port, log: log) { events(.stage(port: port, .flashing($0))) }
            }
            try Task.checkCancellation()
            events(.stage(port: port, .connecting))
            let r = try await blocking {
                try provision(job, settings: settings, options: options, log: log) { events(.stage(port: port, $0)) }
            }
            result.uid = r.info.uid ?? result.uid
            result.firmware = r.info.firmware
            result.wifiIP = r.ip
            result.warnings = r.warnings
            events(.stage(port: port, .done))
        } catch {
            result.error = (error as? SerialError)?.description ?? (error is CancellationError ? "cancelled" : error.localizedDescription)
            log("✗ \(result.error ?? "")")
            events(.stage(port: port, .failed))
        }
        events(.finished(result))
        return result
    }

    /// Serial I/O blocks; keep it off Swift's cooperative threads, which ten
    /// boards waiting on boot could otherwise exhaust.
    static func blocking<T: Sendable>(_ f: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async { c.resume(with: Result { try f() }) }
        }
    }

    struct Provisioned: Sendable { let info: NodeInfo; let ip: String?; let warnings: [String] }

    static func provision(_ job: DeviceJob, settings: NodeSettings, options: PipelineOptions,
                          log: @escaping @Sendable (String) -> Void,
                          stage: @escaping @Sendable (JobStage) -> Void) throws -> Provisioned {
        let port = try SerialPort(path: job.port)
        defer { port.close() }
        let console = NodeConsole(port: port, log: log)
        let before = try console.waitUntilReady(timeout: options.bootTimeout)
        log("node \(before.uid ?? "?") running \(before.firmware ?? "unknown firmware")")
        stage(.provisioning)
        for c in ConsoleCommand.provisioning(id: job.nodeID, settings: settings) { try console.run(c) }
        let after = try console.show()
        let (errors, warnings) = after.verify(id: job.nodeID, settings: settings)
        if !errors.isEmpty { throw SerialError("verification failed: " + errors.joined(separator: "; ")) }
        var notes = warnings
        var ip: String?
        if settings.mode == .wifi && after.ssid != nil && options.wifiTimeout > 0 {
            stage(.joiningWiFi)
            ip = try console.rebootAndWaitForWiFi(timeout: options.wifiTimeout)
            if let ip { log("joined \(after.ssid ?? "Wi-Fi") as \(ip)") }
            else { notes.append("did not join “\(after.ssid ?? "")” within \(Int(options.wifiTimeout)) s — check the SSID, password and signal") }
        } else {
            try console.reboot()
        }
        for w in notes { log("⚠︎ \(w)") }
        return Provisioned(info: after, ip: ip, warnings: notes)
    }
}
