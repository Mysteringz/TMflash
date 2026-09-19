import Darwin
import Foundation
@testable import TMflashCore

/// A pretend TMsense on a pseudo-terminal: it speaks the firmware's serial
/// console (`show`, `set …`, `save`, `reboot`) closely enough that the real
/// SerialPort / NodeConsole / Pipeline code runs against it unchanged.
final class FakeNode: @unchecked Sendable {
    let path: String
    let uid: String
    private let master: Int32
    private let slave: Int32
    private let lock = NSLock()
    private var thread: Thread?
    private var running = true

    // Behaviour knobs.
    var bootDelay: TimeInterval = 0.3
    var silent = false                     // never answers (not a TMsense)
    var refuse: String?                    // answer this setting with "invalid: …"
    var wifiJoins = true

    // Node state (RAM and "flash").
    private var ram: [String: String] = [:]
    private(set) var saved: [String: String] = [:]
    private(set) var received: [String] = []
    private var readyAt = Date()

    init(uid: String) throws {
        var m: Int32 = 0, s: Int32 = 0
        guard openpty(&m, &s, nil, nil, nil) == 0 else { throw SerialError("openpty failed") }
        master = m
        // Held open for the node's lifetime: with no slave open, macOS reports
        // hang-up on the master, as a real board would when unplugged.
        slave = s
        path = String(cString: ttyname(s))
        var t = termios()
        tcgetattr(s, &t); cfmakeraw(&t); tcsetattr(s, TCSANOW, &t)
        self.uid = uid
        ram = ["node_id": "(unset)", "mode": "wifi", "lora_gw": "(none)", "ssid": "(unset)", "password": "(unset)",
               "edges": "(none) ", "key": "(unset - telemetry unsigned)"]
        saved = ram
    }

    func start() {
        readyAt = Date().addingTimeInterval(bootDelay)
        let t = Thread { [weak self] in self?.loop() }
        thread = t
        t.start()
    }

    func stop() {
        lock.lock(); running = false; lock.unlock()
        Darwin.close(master)
        Darwin.close(slave)
    }

    var savedState: [String: String] { lock.lock(); defer { lock.unlock() }; return saved }
    var commands: [String] { lock.lock(); defer { lock.unlock() }; return received }

    /// Pretend esptool wrote new firmware and reset the chip: RAM reloads from flash.
    func reset() {
        lock.lock(); ram = saved; readyAt = Date().addingTimeInterval(bootDelay); lock.unlock()
    }

    private func say(_ s: String) {
        let d = Array((s + "\r\n").utf8)
        _ = d.withUnsafeBytes { Darwin.write(master, $0.baseAddress, d.count) }
    }

    private func loop() {
        var line = [UInt8]()
        var buf = [UInt8](repeating: 0, count: 256)
        var frame = 0
        while true {
            lock.lock(); let alive = running; lock.unlock()
            if !alive { return }
            var p = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            if poll(&p, 1, 100) <= 0 {
                // Frame logs arrive whether or not anyone is typing.
                if !silent && Date() > readyAt { frame += 1; if frame % 5 == 0 { say("[frame \(frame)] people=1 scene 21.0..33.5 C fps=1.00") } }
                continue
            }
            let n = Darwin.read(master, &buf, buf.count)
            if n <= 0 { usleep(20_000); continue }
            if silent || Date() < readyAt { continue }   // still booting: input lost, as on a real reset
            for b in buf[0..<n] {
                if b == 0x0D { continue }
                if b == 0x0A {
                    let text = String(decoding: line, as: UTF8.self)
                    line.removeAll()
                    if !text.isEmpty { handle(text) }
                } else { line.append(b) }
            }
        }
    }

    private func handle(_ text: String) {
        lock.lock(); received.append(text); lock.unlock()
        let parts = text.split(separator: " ", maxSplits: 2).map(String.init)
        switch parts.first {
        case "show":
            lock.lock(); let r = ram; lock.unlock()
            say("uid       : \(uid)")
            say("fw        : tmsense-1.1")
            for k in ["node_id", "mode", "lora_gw", "ssid", "password", "edges", "key"] {
                say("\(k.padding(toLength: 10, withPad: " ", startingAt: 0)): \(r[k] ?? "")")
            }
            say("boot      : 7   last_cmd: 0")
            say("param min_contrast = 50 centi-C")
        case "set" where parts.count == 3:
            let (what, value) = (parts[1], parts[2])
            if what == refuse { say("invalid: \(what)"); return }
            lock.lock()
            switch what {
            case "id": ram["node_id"] = value
            case "mode": ram["mode"] = value
            case "lora_gw": ram["lora_gw"] = value
            case "ssid": ram["ssid"] = value
            case "pass": ram["password"] = "(set)"
            case "edges": ram["edges"] = value + " "
            case "key": ram["key"] = "(set)"
            default: lock.unlock(); say("unknown setting"); return
            }
            lock.unlock()
            say("\(what) updated (not saved)")
        case "save":
            lock.lock(); saved = ram; lock.unlock()
            say("saved")
        case "reboot":
            reset()
            say("")
            say("=== TMsense tmsense-1.1 ===")
            say("[boot] uid     \(uid)   boot #8")
            lock.lock(); let joins = wifiJoins && ram["ssid"] != "(unset)" && ram["mode"] == "wifi"; lock.unlock()
            if joins { say("[wifi] connected ip=192.168.0.\(Int(uid.suffix(2), radix: 16) ?? 1) rssi=-55 dBm ch=6, commands on udp/5201") }
        default:
            say("unknown command; try `help`")
        }
    }
}

/// Writer that "flashes" a FakeNode: reports progress and the MAC, then resets it.
struct FakeWriter: FirmwareWriter {
    let nodes: [String: FakeNode]
    var failPort: String?
    func write(port: String, log: @escaping @Sendable (String) -> Void, progress: @escaping @Sendable (Double) -> Void) async throws -> String? {
        if port == failPort { throw SerialError("Failed to connect to ESP32-S3: No serial data received.") }
        for i in 1...4 { try await Task.sleep(nanoseconds: 20_000_000); progress(Double(i) / 4) }
        nodes[port]?.reset()
        return nodes[port]?.uid
    }
}
