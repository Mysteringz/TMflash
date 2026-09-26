import Foundation

/// What a TMsense node reports for `show`: its `name : value` lines.
public struct NodeInfo: Equatable, Sendable {
    public var fields: [String: String]

    public init(fields: [String: String]) { self.fields = fields }

    public var uid: String? { fields["uid"] }
    public var firmware: String? { fields["fw"] }
    public var nodeID: Int? { fields["node_id"].flatMap { Int($0) } }
    public var mode: UplinkMode? { fields["mode"].flatMap(UplinkMode.init(rawValue:)) }
    public var ssid: String? { fields["ssid"].flatMap { $0 == "(unset)" ? nil : $0 } }
    public var passwordSet: Bool { fields["password"] == "(set)" }
    public var keySet: Bool { fields["key"] == "(set)" }
    /// First edge (Wi-Fi destination), nil if none.
    public var edge: String? {
        guard let e = fields["edges"]?.split(separator: " ").first.map(String.init), e != "(none)" else { return nil }
        return e
    }
    public var loraGateway: String? { fields["lora_gw"].flatMap { $0 == "(none)" ? nil : $0 } }
    /// What the firmware says it can do (`caps : wss1,ota-https1`); empty on older firmware.
    public var capabilities: Set<String> { Set((fields["caps"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
    /// The firmware has the direct-to-cloud transport and its settings.
    public var supportsDirectCloud: Bool { capabilities.contains("wss1") }
    /// No `transport` line means firmware from before direct cloud: UDP.
    public var transport: UplinkTransport { fields["transport"].flatMap(UplinkTransport.init(rawValue:)) ?? .udp }
    public var cloudURL: String? { fields["cloud_url"].flatMap { $0 == "(none)" ? nil : $0 } }

    /// Parses one console line; nil for anything that is not a `show` field
    /// (frame logs, `param` lines, boot banner).
    static func parseField(_ line: String) -> (String, String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let name = line[..<colon].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.allSatisfy({ $0.isLowercase || $0 == "_" }) else { return nil }
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return (name, value)
    }

    /// Differences between what was asked for and what the node reports.
    /// `errors` mean the node is not provisioned as asked; `warnings` mean it
    /// is, but will not work as a node yet (e.g. no key: TMedge rejects it).
    public func verify(id: Int, settings s: NodeSettings) -> (errors: [String], warnings: [String]) {
        var errors: [String] = [], warnings: [String] = []
        if nodeID != id { errors.append("node ID reads \(fields["node_id"] ?? "nothing"), expected \(id)") }
        if mode != s.mode { errors.append("mode reads \(fields["mode"] ?? "nothing"), expected \(s.mode.rawValue)") }
        switch s.mode {
        case .wifi:
            if !s.ssid.isEmpty && ssid != s.ssid { errors.append("SSID was not stored") }
            if !s.password.isEmpty && !passwordSet { errors.append("Wi-Fi password was not stored") }
            if !s.gateway.isEmpty && edge != s.gateway { errors.append("TMWAccess IP reads \(edge ?? "nothing"), expected \(s.gateway)") }
            if ssid == nil { warnings.append("no Wi-Fi SSID on the node") }
            if !passwordSet { warnings.append("no Wi-Fi password on the node") }
            if s.transport == .wss || transport == .wss {
                if transport != s.transport { errors.append("transport reads \(fields["transport"] ?? "nothing (old firmware)"), expected \(s.transport.rawValue)") }
                let want = NodeSettings.canonicalCloudURL(s.cloudURL)
                if !want.isEmpty && cloudURL != want { errors.append("cloud URL reads \(cloudURL ?? "nothing"), expected \(want)") }
                if s.transport == .wss && cloudURL == nil { errors.append("no cloud URL on the node: transport wss has nowhere to go") }
                if edge == nil { warnings.append("no TMWAccess IP kept on the node: a USB rollback to UDP will need one") }
            } else {
                if supportsDirectCloud && transport != .udp { errors.append("transport reads \(fields["transport"] ?? "nothing"), expected udp") }
                if edge == nil { warnings.append("no TMWAccess IP on the node: it has nowhere to send") }
            }
        case .lora:
            if !s.gateway.isEmpty && loraGateway != s.gateway { errors.append("TMLAccess IP reads \(loraGateway ?? "nothing"), expected \(s.gateway)") }
            if loraGateway == nil { warnings.append("no TMLAccess IP on the node") }
            warnings.append("this firmware has no LoRa uplink yet: the node stores the settings but sends nothing until it does")
        }
        if !s.key.isEmpty && !keySet { errors.append("signing key was not stored") }
        if !keySet { warnings.append("no signing key: telemetry is unsigned and TMedge will reject it") }
        return (errors, warnings)
    }
}

/// Talks to a running TMsense firmware over its serial console.
public final class NodeConsole {
    private let port: SerialPort
    private let log: (String) -> Void

    public init(port: SerialPort, log: @escaping (String) -> Void) {
        self.port = port
        self.log = log
    }

    private static let failures = ["invalid", "unknown", "usage:", "SAVE FAILED", "line too long"]

    /// Waits until the firmware answers `show` (after a reset it may still be
    /// booting), and returns what it reported.
    public func waitUntilReady(timeout: TimeInterval) throws -> NodeInfo {
        let deadline = Date().addingTimeInterval(timeout)
        while deadline.timeIntervalSinceNow > 0 {
            try port.write("\nshow\n")
            if let info = try collectShow(timeout: min(1.5, max(0.1, deadline.timeIntervalSinceNow))) { return info }
        }
        throw SerialError("no answer from TMsense firmware on \(port.path) within \(Int(timeout)) s — is it a TMsense, and is its firmware running?")
    }

    public func show(timeout: TimeInterval = 4) throws -> NodeInfo {
        try port.drain(for: 0.2)
        try port.write("show\n")
        guard let info = try collectShow(timeout: timeout) else { throw SerialError("node did not answer `show`") }
        return info
    }

    /// Reads `show` output: fields from `uid` through `boot` (the last fixed
    /// line before the parameters). Other output is skipped.
    private func collectShow(timeout: TimeInterval) throws -> NodeInfo? {
        let deadline = Date().addingTimeInterval(timeout)
        var fields: [String: String] = [:]
        while let line = try port.readLine(timeout: max(0, deadline.timeIntervalSinceNow)) {
            guard let (name, value) = NodeInfo.parseField(line) else { continue }
            if name == "uid" { fields = [:] }   // a fresh block
            fields[name] = value
            if name == "boot" && fields["uid"] != nil { return NodeInfo(fields: fields) }
        }
        return nil
    }

    public func run(_ c: ConsoleCommand, timeout: TimeInterval = 4) throws {
        log("› \(c.display)")
        try port.write(c.line + "\n")
        let deadline = Date().addingTimeInterval(timeout)
        while let line = try port.readLine(timeout: max(0, deadline.timeIntervalSinceNow)) {
            if line.hasPrefix(c.expect) { return }
            if Self.failures.contains(where: { line.hasPrefix($0) }) {
                throw SerialError("node refused `\(c.display)`: \(line)")
            }
        }
        throw SerialError("no answer to `\(c.display)` within \(Int(timeout)) s")
    }

    /// Reboots and waits for the Wi-Fi join line. Returns the node's IP, or
    /// nil if it did not join within `timeout` (wrong password, out of range).
    public func rebootAndWaitForWiFi(timeout: TimeInterval) throws -> String? {
        try rebootAndWatch(wifiTimeout: timeout, cloudTimeout: 0).ip
    }

    public struct BootWatch: Equatable, Sendable {
        /// Joined Wi-Fi as this address; nil if it did not.
        public var ip: String?
        /// TMedge acknowledged a report from this boot (transport wss only).
        public var edgeAccepted = false
        /// Why the cloud session last failed, as the node put it.
        public var cloudError: String?
    }

    /// Reboots, waits for Wi-Fi, and -- if `cloudTimeout` > 0 -- for the node
    /// to say TMedge accepted one of its reports. Two separate facts: a DHCP
    /// lease proves nothing about the edge.
    public func rebootAndWatch(wifiTimeout: TimeInterval, cloudTimeout: TimeInterval) throws -> BootWatch {
        log("› reboot")
        try port.write("reboot\n")
        var w = BootWatch()
        var deadline = Date().addingTimeInterval(wifiTimeout)
        while let line = try port.readLine(timeout: max(0, deadline.timeIntervalSinceNow)) {
            // "[wifi] connected ip=192.168.0.9 rssi=-60 dBm ch=6, ..."
            if w.ip == nil, line.hasPrefix("[wifi] connected ip="), let ip = line.split(separator: "=").dropFirst().first?.split(separator: " ").first {
                w.ip = String(ip)
                log(line)
                if cloudTimeout <= 0 { return w }
                deadline = Date().addingTimeInterval(cloudTimeout)
                continue
            }
            if line.hasPrefix("[cloud] report accepted") {
                log(line)
                w.edgeAccepted = true
                return w
            }
            // "[cloud] backoff: tls: certificate refused"
            if line.hasPrefix("[cloud] backoff: ") { w.cloudError = String(line.dropFirst("[cloud] backoff: ".count)) }
            if line.hasPrefix("[boot]") || line.hasPrefix("[wifi]") || line.hasPrefix("[lora]") || line.hasPrefix("[sensor]") ||
                line.hasPrefix("[cloud]") {
                log(line)
            }
        }
        return w
    }

    public func reboot() throws {
        log("› reboot")
        try port.write("reboot\n")
    }
}
