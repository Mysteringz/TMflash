import Foundation
import TMflashCore

// tmflash-cli: the same engine as the TMflash app, for scripts and tests.
// Secrets come from the environment (TMFLASH_PASSWORD, TMFLASH_KEY), never
// from arguments, which end up in shell history and `ps`.

let usage = """
usage:
  tmflash-cli ports [--probe]                 list USB serial boards (--probe: ask each what it runs)
  tmflash-cli build [--project DIR]           build the TMsense release image
  tmflash-cli flash --port P --id N [options] flash + provision one node
  tmflash-cli batch --ports P1,P2,... --start N --end M [options]
                                          flash + provision up to 10 nodes at once, IDs N..M in port order
options:
  --mode wifi|lora      uplink (default wifi)
  --ssid NAME           Wi-Fi network (wifi mode)
  --gateway IP          TMWAccess IP (wifi) or TMLAccess IP (lora); with wss, kept for a USB rollback
  --transport udp|wss   wifi only: local gateway (udp, default) or straight to TMedge (wss; TMsense 1.4+)
  --cloud-url URL       TMedge's node endpoint for wss, e.g. wss://sense.example.com/tmnode
  --no-flash            only write settings (firmware already on the board)
  --no-wifi-check       don't reboot and wait for the node to join Wi-Fi
  --no-edge-check       wss: don't wait for TMedge to accept a report after joining
  --project DIR         TMsense folder (default: $TMSENSE_DIR or ../TMsense)
  --esptool CMD         use CMD instead of esptool (testing)
environment:
  TMFLASH_PASSWORD      Wi-Fi password
  TMFLASH_KEY           signing key (TMedge's TM_KEY)
Blank settings keep what the node already has.
Exit status: 0 all nodes set up (and, for wss, heard by TMedge); 1 otherwise.
"""

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("tmflash-cli: \(msg)\n".utf8))
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()
var opts: [String: String] = [:]
var flags = Set<String>()
while let a = args.first {
    args.removeFirst()
    guard a.hasPrefix("--") else { fail("unexpected argument \(a)") }
    if ["--probe", "--no-flash", "--no-wifi-check", "--no-edge-check", "--help"].contains(a) { flags.insert(a); continue }
    guard let v = args.first else { fail("\(a) needs a value") }
    args.removeFirst()
    opts[a] = v
}
if flags.contains("--help") { print(usage); exit(0) }

let out = FileHandle.standardOutput
@Sendable func say(_ s: String) { out.write(Data((s + "\n").utf8)) }

@MainActor func settingsFromArgs() -> NodeSettings {
    let env = ProcessInfo.processInfo.environment
    guard let mode = UplinkMode(rawValue: opts["--mode"] ?? "wifi") else { fail("--mode must be wifi or lora") }
    guard let transport = UplinkTransport(rawValue: opts["--transport"] ?? "udp") else { fail("--transport must be udp or wss") }
    let s = NodeSettings(mode: mode, ssid: opts["--ssid"] ?? "", password: env["TMFLASH_PASSWORD"] ?? "",
                         gateway: opts["--gateway"] ?? "", key: env["TMFLASH_KEY"] ?? "", transport: transport,
                         cloudURL: NodeSettings.canonicalCloudURL(opts["--cloud-url"] ?? ""))
    let p = s.problems()
    if !p.isEmpty { fail(p.joined(separator: "; ")) }
    return s
}

@MainActor func project() -> String {
    guard let dir = opts["--project"].map({ ($0 as NSString).standardizingPath }) ?? FirmwareProject.defaultDirectory() else {
        fail("TMsense folder not found; pass --project or set TMSENSE_DIR")
    }
    return dir
}

/// Stand-in writer: runs a command with the port as its last argument.
struct CommandWriter: FirmwareWriter {
    let command: [String]
    func write(port: String, log: @escaping @Sendable (String) -> Void, progress: @escaping @Sendable (Double) -> Void) async throws -> String? {
        var mac: String?
        let box = MacBox()
        let status = try await ProcessRunner.run(command[0], Array(command.dropFirst()) + [port]) { line in
            if line.hasPrefix("MAC: ") { box.set(String(line.dropFirst(5))) }
            log(line)
        }
        mac = box.get()
        if status != 0 { throw SerialError("\(command[0]) exited \(status)") }
        progress(1)
        return mac
    }
}
final class MacBox: @unchecked Sendable {
    private var v: String?; private let l = NSLock()
    func set(_ s: String) { l.lock(); v = s; l.unlock() }
    func get() -> String? { l.lock(); defer { l.unlock() }; return v }
}

@MainActor func writer() async -> FirmwareWriter? {
    if flags.contains("--no-flash") { return nil }
    if let cmd = opts["--esptool"] { return CommandWriter(command: cmd.split(separator: " ").map(String.init)) }
    guard let tc = Toolchain.locate() else { fail("PlatformIO not found (brew install platformio)") }
    do {
        let build = try await FirmwareProject.build(dir: project(), toolchain: tc) { say("  \($0)") }
        say("firmware \(build.version ?? "?"): " + build.images.map { "\($0.offset) \(($0.path as NSString).lastPathComponent)" }.joined(separator: ", "))
        return EsptoolWriter(build: build, toolchain: tc)
    } catch { fail("\(error)") }
}

@MainActor func runJobs(_ jobs: [DeviceJob]) async -> Never {
    let settings = settingsFromArgs()
    let w = await writer()
    var options = PipelineOptions()
    if flags.contains("--no-wifi-check") { options.wifiTimeout = 0 }
    if flags.contains("--no-edge-check") { options.edgeTimeout = 0 }
    let lastPct = PctBox()
    let results = await Pipeline.run(jobs: jobs, settings: settings, writer: w, options: options) { e in
        switch e {
        case .log(let port, let line): say("[\((port as NSString).lastPathComponent)] \(line)")
        case .stage(let port, let st):
            if case .flashing(let p) = st {
                let pct = Int(p * 100) / 10 * 10
                if !lastPct.changed(port, pct) { return }
            }
            say("[\((port as NSString).lastPathComponent)] == \(st.label)")
        case .finished: break
        }
    }
    try? Manifest.append(results, settings: settings)
    say("")
    for r in results {
        let name = (r.job.port as NSString).lastPathComponent
        if r.ok {
            let edge = r.edgeAccepted.map { $0 ? "  edge accepted" : "  edge NOT heard" } ?? ""
            say("OK    #\(r.job.nodeID)  \(r.uid ?? "?")  \(name)  \(r.firmware ?? "")\(r.wifiIP.map { "  wifi \($0)" } ?? "")\(edge)\(r.warnings.isEmpty ? "" : "  (\(r.warnings.count) warning\(r.warnings.count == 1 ? "" : "s"))")")
        } else {
            say("FAIL  #\(r.job.nodeID)  \(name)  \(r.error ?? "")")
        }
    }
    say("manifest: \(Manifest.url.path)")
    // A wss node TMedge never heard is not a working node, whatever else went right.
    exit(results.allSatisfy { $0.ok && $0.edgeAccepted != false } ? 0 : 1)
}
final class PctBox: @unchecked Sendable {
    private var m: [String: Int] = [:]; private let l = NSLock()
    func changed(_ k: String, _ v: Int) -> Bool { l.lock(); defer { l.unlock() }; if m[k] == v { return false }; m[k] = v; return true }
}

switch command {
case "ports":
    let devices = SerialDevices.list()
    if devices.isEmpty { say("no USB serial boards found") }
    for d in devices {
        var line = "\(d.path)  \(d.summary)"
        if flags.contains("--probe") {
            if let info = await Probe.identify(port: d.path) {
                line += "  → TMsense \(info.firmware ?? "?") uid \(info.uid ?? "?") id \(info.nodeID.map(String.init) ?? "unset") mode \(info.mode?.rawValue ?? "?")"
            } else {
                line += "  → no TMsense answer"
            }
        }
        say(line)
    }
case "build":
    guard let tc = Toolchain.locate() else { fail("PlatformIO not found (brew install platformio)") }
    do {
        let b = try await FirmwareProject.build(dir: project(), toolchain: tc) { say($0) }
        say("built \(b.version ?? "?"); esptool \(b.esptoolArguments(port: "<port>").joined(separator: " "))")
    } catch { fail("\(error)") }
case "flash":
    guard let port = opts["--port"], let id = opts["--id"].flatMap(Int.init) else { fail("flash needs --port and --id") }
    if let p = NodeSettings.problems(forID: id).first { fail(p) }
    await runJobs([DeviceJob(port: port, nodeID: id)])
case "batch":
    guard let ports = opts["--ports"]?.split(separator: ",").map(String.init), !ports.isEmpty else { fail("batch needs --ports") }
    switch NodeSettings.batchIDs(start: opts["--start"].flatMap(Int.init), end: opts["--end"].flatMap(Int.init), deviceCount: ports.count) {
    case .failure(let e): fail(e.description)
    case .success(let ids): await runJobs(zip(ports, ids).map { DeviceJob(port: $0, nodeID: $1) })
    }
default:
    print(usage)
    exit(2)
}
