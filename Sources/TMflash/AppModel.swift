import AppKit
import Foundation
import SwiftUI
import TMflashCore

@MainActor
final class AppModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case single = "Single node", batch = "Batch (up to 10)"
        var id: String { rawValue }
    }

    enum ProbeState: Equatable {
        case checking
        case tmsense(NodeInfo)
        case noAnswer
    }

    enum Phase: Equatable { case setup, building, flashing, finished }

    struct Row: Identifiable, Equatable {
        let port: String
        let nodeID: Int
        var stage: JobStage = .queued
        var log: [String] = []
        var result: JobResult?
        var id: String { port }
        var name: String { (port as NSString).lastPathComponent.replacingOccurrences(of: "cu.", with: "") }
    }

    // Devices
    @Published var devices: [SerialDevice] = []
    @Published var probes: [String: ProbeState] = [:]

    // Setup
    @Published var mode: Mode = .single { didSet { defaults.set(mode.rawValue, forKey: "mode") } }
    @Published var selectedPort: String?
    @Published var batchPorts: Set<String> = []
    @Published var nodeIDText = "" { didSet { defaults.set(nodeIDText, forKey: "nodeID") } }
    @Published var startIDText = "" { didSet { defaults.set(startIDText, forKey: "startID") } }
    @Published var endIDText = "" { didSet { defaults.set(endIDText, forKey: "endID") } }
    @Published var settings = NodeSettings() { didSet { persistSettings() } }
    @Published var rememberSecrets = true { didSet { defaults.set(rememberSecrets, forKey: "rememberSecrets"); persistSecrets() } }
    @Published var flashFirmware = true
    @Published var projectDir: String? { didSet { defaults.set(projectDir, forKey: "projectDir") } }

    // Run
    @Published var phase: Phase = .setup
    @Published var rows: [Row] = []
    @Published var buildLog: [String] = []
    @Published var buildError: String?
    @Published var firmwareVersion: String?

    let toolchain: Toolchain?
    private let defaults: UserDefaults
    private var runTask: Task<Void, Never>?
    private var pollTimer: Timer?
    private let live: Bool

    /// `live: false` builds a model for previews/snapshots: no Keychain, no
    /// timers, no hardware.
    init(live: Bool = true, defaults: UserDefaults = .standard) {
        self.live = live
        self.defaults = defaults
        toolchain = Toolchain.locate()
        guard live else { return }
        mode = Mode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .single
        nodeIDText = defaults.string(forKey: "nodeID") ?? ""
        startIDText = defaults.string(forKey: "startID") ?? ""
        endIDText = defaults.string(forKey: "endID") ?? ""
        rememberSecrets = defaults.object(forKey: "rememberSecrets") as? Bool ?? true
        var s = NodeSettings()
        s.mode = UplinkMode(rawValue: defaults.string(forKey: "uplink") ?? "") ?? .wifi
        s.ssid = defaults.string(forKey: "ssid") ?? ""
        s.gateway = defaults.string(forKey: s.mode == .wifi ? "wifiGateway" : "loraGateway") ?? ""
        // Absent before direct cloud existed: UDP, as those nodes were.
        s.transport = s.mode == .wifi ? UplinkTransport(rawValue: defaults.string(forKey: "transport") ?? "") ?? .udp : .udp
        s.cloudURL = defaults.string(forKey: "cloudURL") ?? ""
        if rememberSecrets {
            s.password = SecretStore.get("wifi-password") ?? ""
            s.key = SecretStore.get("signing-key") ?? ""
        }
        settings = s
        let hint = Bundle.main.object(forInfoDictionaryKey: "TMSenseDir") as? String
        projectDir = defaults.string(forKey: "projectDir").flatMap { FirmwareProject.isProject($0) ? $0 : nil }
            ?? FirmwareProject.defaultDirectory(bundleHint: hint)
        refreshFirmwareVersion()
        refreshDevices()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            // Give the task its own weak capture across the actor boundary.
            Task { @MainActor [weak self] in self?.refreshDevices() }
        }
    }

    // MARK: persistence

    private func persistSettings() {
        guard live else { return }
        defaults.set(settings.mode.rawValue, forKey: "uplink")
        defaults.set(settings.ssid, forKey: "ssid")
        defaults.set(settings.gateway, forKey: settings.mode == .wifi ? "wifiGateway" : "loraGateway")
        defaults.set(settings.transport.rawValue, forKey: "transport")
        defaults.set(settings.cloudURL, forKey: "cloudURL")
        persistSecrets()
    }

    private var lastSecrets: (String, String)?
    private func persistSecrets() {
        guard live else { return }
        let now = rememberSecrets ? (settings.password, settings.key) : ("", "")
        if let last = lastSecrets, last == now { return }
        lastSecrets = now
        SecretStore.set("wifi-password", now.0)
        SecretStore.set("signing-key", now.1)
    }

    /// Switching uplink swaps the gateway field to the address remembered for that mode.
    func setUplink(_ m: UplinkMode) {
        guard m != settings.mode else { return }
        var s = settings
        s.mode = m
        s.gateway = defaults.string(forKey: m == .wifi ? "wifiGateway" : "loraGateway") ?? ""
        // LoRa has no direct-cloud transport; coming back to Wi-Fi restores the choice.
        s.transport = m == .lora ? .udp : UplinkTransport(rawValue: defaults.string(forKey: "transport") ?? "") ?? .udp
        settings = s
    }

    func refreshFirmwareVersion() {
        firmwareVersion = projectDir.flatMap(FirmwareProject.version(in:))
    }

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the TMsense firmware folder (the one with platformio.ini)"
        if let projectDir { panel.directoryURL = URL(fileURLWithPath: projectDir) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if FirmwareProject.isProject(url.path) {
            projectDir = url.path
            refreshFirmwareVersion()
        } else {
            buildError = "\(url.lastPathComponent) is not a TMsense folder (no [env:tmflash] in platformio.ini)."
        }
    }

    // MARK: devices

    func refreshDevices() {
        let now = SerialDevices.list()
        guard now != devices else { return }
        devices = now
        let paths = Set(now.map(\.path))
        batchPorts.formIntersection(paths)
        if let s = selectedPort, !paths.contains(s) { selectedPort = nil }
        if selectedPort == nil { selectedPort = now.first(where: \.looksLikeESP32)?.path ?? now.first?.path }
        for k in probes.keys where !paths.contains(k) { probes[k] = nil }
        // Ask each new board what it is, unless we are busy talking to boards.
        if phase == .setup || phase == .finished {
            for d in now where probes[d.path] == nil && d.looksLikeESP32 { probe(d.path) }
        }
    }

    func probe(_ path: String) {
        probes[path] = .checking
        Task {
            let info = await Probe.identify(port: path, timeout: 3.5)
            probes[path] = info.map(ProbeState.tmsense) ?? .noAnswer
            // Re-flashing a known node: offer the ID it already has.
            if mode == .single, selectedPort == path, nodeIDText.isEmpty, let id = info?.nodeID { nodeIDText = String(id) }
        }
    }

    // MARK: plan

    var orderedBatchPorts: [String] { devices.map(\.path).filter(batchPorts.contains) }

    func toggleBatch(_ path: String) {
        if batchPorts.contains(path) { batchPorts.remove(path) }
        else if batchPorts.count < NodeSettings.maxBatch { batchPorts.insert(path) }
    }

    /// The jobs to run, or why there are none yet.
    var plan: Result<[DeviceJob], PlanError> {
        switch mode {
        case .single:
            guard let port = selectedPort else { return .failure(.init("Connect a TMsense and select it")) }
            let id = Int(nodeIDText.trimmingCharacters(in: .whitespaces))
            if let p = NodeSettings.problems(forID: id).first { return .failure(.init(p)) }
            return .success([DeviceJob(port: port, nodeID: id!)])
        case .batch:
            let ports = orderedBatchPorts
            if ports.isEmpty { return .failure(.init("Tick the boards to flash")) }
            switch NodeSettings.batchIDs(start: Int(startIDText.trimmingCharacters(in: .whitespaces)),
                                         end: Int(endIDText.trimmingCharacters(in: .whitespaces)), deviceCount: ports.count) {
            case .failure(let e): return .failure(.init(e.description))
            case .success(let ids): return .success(zip(ports, ids).map { DeviceJob(port: $0, nodeID: $1) })
            }
        }
    }

    struct PlanError: Error, Equatable { let message: String; init(_ m: String) { message = m } }

    /// Everything stopping the Flash button, first one shown.
    var blockers: [String] {
        var out: [String] = []
        if case .failure(let e) = plan { out.append(e.message) }
        // Identifying holds the port open; flashing now would find it busy.
        if case .success(let jobs) = plan, jobs.contains(where: { probes[$0.port] == .checking }) {
            out.append("Identifying the board…")
        }
        out += settings.problems()
        if flashFirmware {
            if toolchain == nil { out.append("PlatformIO is not installed (brew install platformio)") }
            if projectDir == nil { out.append("Choose the TMsense firmware folder") }
        }
        return out
    }

    /// Batch IDs in port order, for the device list badges.
    func assignedID(for path: String) -> Int? {
        guard case .success(let jobs) = plan else {
            if mode == .batch, let start = Int(startIDText), let i = orderedBatchPorts.firstIndex(of: path) { return start + i }
            return nil
        }
        return jobs.first { $0.port == path }?.nodeID
    }

    // MARK: run

    func start() {
        guard case .success(let jobs) = plan, blockers.isEmpty else { return }
        rows = jobs.map { Row(port: $0.port, nodeID: $0.nodeID) }
        buildLog = []
        buildError = nil
        let settings = self.settings
        let flash = flashFirmware
        let dir = projectDir
        let tc = toolchain
        phase = flash ? .building : .flashing
        runTask = Task {
            var writer: FirmwareWriter?
            if flash, let dir, let tc {
                do {
                    let build = try await FirmwareProject.build(dir: dir, toolchain: tc) { line in
                        DispatchQueue.main.async { self.appendBuild(line) }
                    }
                    firmwareVersion = build.version
                    writer = EsptoolWriter(build: build, toolchain: tc)
                } catch {
                    buildError = (error as? SerialError)?.description ?? error.localizedDescription
                    phase = .finished
                    return
                }
            }
            if Task.isCancelled { phase = .finished; return }
            phase = .flashing
            let results = await Pipeline.run(jobs: jobs, settings: settings, writer: writer) { e in
                // Main-queue hops keep events in order.
                DispatchQueue.main.async { self.apply(e) }
            }
            try? Manifest.append(results, settings: settings)
            phase = .finished
            for d in devices { probes[d.path] = nil }   // re-identify what is now on the boards
            refreshDevices()
        }
    }

    func cancel() { runTask?.cancel() }

    func backToSetup() {
        phase = .setup
        rows = []
        buildError = nil
    }

    private func appendBuild(_ line: String) {
        buildLog.append(line)
        if buildLog.count > 500 { buildLog.removeFirst(buildLog.count - 500) }
    }

    private func apply(_ e: PipelineEvent) {
        switch e {
        case .stage(let port, let st):
            if let i = rows.firstIndex(where: { $0.port == port }) { rows[i].stage = st }
        case .log(let port, let line):
            if let i = rows.firstIndex(where: { $0.port == port }) {
                rows[i].log.append(line)
                if rows[i].log.count > 400 { rows[i].log.removeFirst() }
            }
        case .finished(let r):
            if let i = rows.firstIndex(where: { $0.port == r.job.port }) { rows[i].result = r }
        }
    }

    var succeeded: Int { rows.filter { $0.result?.ok == true }.count }
    var failed: Int { rows.filter { $0.result?.ok == false }.count }

    func revealManifest() {
        NSWorkspace.shared.activateFileViewerSelecting([Manifest.url])
    }
}
