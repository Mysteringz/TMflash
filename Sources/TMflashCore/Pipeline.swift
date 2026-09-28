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
    case awaitingApproval
    case reachingEdge
    case done
    case failed

    public var label: String {
        switch self {
        case .queued: return "Waiting"
        case .flashing(let p): return "Writing firmware \(Int(p * 100))%"
        case .connecting: return "Waiting for the node to boot"
        case .provisioning: return "Writing settings"
        case .joiningWiFi: return "Checking it joins Wi-Fi"
        case .awaitingApproval: return "Waiting for TMedge to admit this node"
        case .reachingEdge: return "Checking TMedge accepts its reports"
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
    /// Direct cloud only: TMedge acknowledged a report after provisioning.
    /// nil = not checked (UDP, or the check was skipped).
    public var edgeAccepted: Bool?
    /// Whether the edge was asked to admit this node, and what came back.
    /// nil = not asked (no server configured).
    public var admission: AdmissionState?
    public var transport: UplinkTransport?
    /// The node's cloud_url as it reports it (not a secret).
    public var cloudURL: String?
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
    /// Direct cloud: after joining Wi-Fi, wait this long for TMedge to accept
    /// a report (time sync, TLS and authentication come first); 0 = skip.
    public var edgeTimeout: TimeInterval = 90
    /// Where to ask for the node to be admitted. nil = do not ask, for a node
    /// whose uid is already in the edge's list.
    public var server: EdgeServer?
    /// How long to wait for a person at the console to answer. It is a human
    /// on a ladder's colleague, so minutes, not seconds.
    public var approvalTimeout: TimeInterval = 300
    public init(bootTimeout: TimeInterval = 25, wifiTimeout: TimeInterval = 30, edgeTimeout: TimeInterval = 90,
                server: EdgeServer? = nil, approvalTimeout: TimeInterval = 300) {
        self.bootTimeout = bootTimeout
        self.wifiTimeout = wifiTimeout
        self.edgeTimeout = edgeTimeout
        self.server = server
        self.approvalTimeout = approvalTimeout
    }
}

public enum PipelineEvent: Sendable {
    case stage(port: String, JobStage)
    case log(port: String, String)
    case finished(JobResult)
}

/// One value handed back across a semaphore. A class because the closure
/// that fills it and the one that reads it are different.
final class ResultBox: @unchecked Sendable {
    var value: AdmissionState = .timedOut
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
            // provision() runs on a plain dispatch queue (serial I/O blocks),
            // so waiting on the asynchronous join there costs a thread that is
            // already dedicated to this board, not a cooperative one.
            let admit: (@Sendable (NodeInfo) -> AdmissionState)? = options.server.map { server in
                { info in
                    guard let uid = info.uid else { return .timedOut }
                    // The number TMflash assigned this board. Whoever places
                    // the node renames it to where it ends up.
                    let label = "Node \(job.nodeID)"
                    let box = ResultBox()
                    let done = DispatchSemaphore(value: 0)
                    Task {
                        box.value = await EdgeClient.join(server, uid: uid, label: label,
                                                          firmware: info.firmware,
                                                          timeout: options.approvalTimeout, log: log)
                        done.signal()
                    }
                    done.wait()
                    return box.value
                }
            }
            let r = try await blocking {
                try provision(job, settings: settings, options: options, log: log,
                              stage: { events(.stage(port: port, $0)) }, admit: admit)
            }
            result.uid = r.info.uid ?? result.uid
            result.firmware = r.info.firmware
            result.wifiIP = r.ip
            result.edgeAccepted = r.edgeAccepted
            result.admission = r.admission
            result.transport = r.info.transport
            result.cloudURL = r.info.cloudURL
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

    /// Serial I/O blocks; keep it off Swift's cooperative threads, which many
    /// boards waiting on boot could otherwise exhaust.
    static func blocking<T: Sendable>(_ f: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async { c.resume(with: Result { try f() }) }
        }
    }

    struct Provisioned: Sendable {
        let info: NodeInfo; let ip: String?; let edgeAccepted: Bool?
        let admission: AdmissionState?; let warnings: [String]
    }

    static func provision(_ job: DeviceJob, settings: NodeSettings, options: PipelineOptions,
                          log: @escaping @Sendable (String) -> Void,
                          stage: @escaping @Sendable (JobStage) -> Void,
                          admit: (@Sendable (NodeInfo) -> AdmissionState)? = nil) throws -> Provisioned {
        let port = try SerialPort(path: job.port)
        defer { port.close() }
        let console = NodeConsole(port: port, log: log)
        let before = try console.waitUntilReady(timeout: options.bootTimeout)
        log("node \(before.uid ?? "?") running \(before.firmware ?? "unknown firmware")")
        // Asked before anything is written: old firmware would answer
        // `set transport` with "unknown setting" halfway through, or -- worse
        // -- keep sending over UDP while the manifest says cloud.
        if settings.mode == .wifi && settings.transport == .wss && !before.supportsDirectCloud {
            throw SerialError("\(before.firmware ?? "this firmware") has no direct-to-cloud transport: flash the current TMsense, or choose the local gateway")
        }
        stage(.provisioning)
        for c in ConsoleCommand.provisioning(id: job.nodeID, settings: settings, directCloud: before.supportsDirectCloud) { try console.run(c) }
        let after = try console.show()
        let (errors, warnings) = after.verify(id: job.nodeID, settings: settings)
        if !errors.isEmpty { throw SerialError("verification failed: " + errors.joined(separator: "; ")) }
        var notes = warnings
        var ip: String?
        var accepted: Bool?
        var admission: AdmissionState?

        // Before the node is asked to reach the edge, not after: an edge that
        // has never heard of this uid answers its very first packet with
        // "authentication failed", so checking delivery first would report a
        // configuration problem as a broken node.
        if let admit, let uid = after.uid {
            stage(.awaitingApproval)
            let state = admit(after)
            admission = state
            switch state {
            case .registered: break
            case .denied:
                throw SerialError("TMedge turned down the request to admit \(uid): the node is flashed but will not be allowed to connect")
            case .pending, .timedOut:
                notes.append("TMedge has not admitted \(uid) yet — the request is waiting in the edge console; the node will connect once somebody allows it")
            }
        }

        if settings.mode == .wifi && after.ssid != nil && options.wifiTimeout > 0 {
            stage(.joiningWiFi)
            // No point waiting for an ACK from an edge that has not admitted
            // this node: it would refuse every packet and we would blame the node.
            let cloud = after.transport == .wss && options.edgeTimeout > 0 && admission != .timedOut && admission != .pending
            if cloud { log("then waiting up to \(Int(options.edgeTimeout)) s for TMedge to accept a report") }
            let w = try console.rebootAndWatch(wifiTimeout: options.wifiTimeout, cloudTimeout: cloud ? options.edgeTimeout : 0)
            ip = w.ip
            if let ip { log("joined \(after.ssid ?? "Wi-Fi") as \(ip)") }
            else { notes.append("did not join “\(after.ssid ?? "")” within \(Int(options.wifiTimeout)) s — check the SSID, password and signal") }
            if cloud && ip != nil {
                stage(.reachingEdge)
                accepted = w.edgeAccepted
                if w.edgeAccepted { log("TMedge accepted a report") }
                else {
                    notes.append("joined Wi-Fi, but TMedge did not accept a report within \(Int(options.edgeTimeout)) s" +
                                 (w.cloudError.map { " (last error: \($0))" } ?? "") + " — the node is not delivering occupancy yet")
                }
            }
        } else {
            try console.reboot()
        }
        for w in notes { log("⚠︎ \(w)") }
        return Provisioned(info: after, ip: ip, edgeAccepted: accepted, admission: admission, warnings: notes)
    }
}
