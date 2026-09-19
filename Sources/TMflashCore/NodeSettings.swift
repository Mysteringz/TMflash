import Foundation

public enum UplinkMode: String, Codable, CaseIterable, Sendable {
    case wifi, lora

    public var title: String { self == .wifi ? "Wi-Fi" : "LoRa" }
    /// The access gateway a node in this mode sends to.
    public var gatewayName: String { self == .wifi ? "TMWAccess" : "TMLAccess" }
}

/// What gets written to a TMsense node. An empty string means "keep what the
/// node already has", so re-flashing firmware never forces anyone to re-type
/// a password, and a fresh node is caught by verification instead.
public struct NodeSettings: Equatable, Codable, Sendable {
    public var mode: UplinkMode = .wifi
    public var ssid: String = ""
    public var password: String = ""
    /// TMWAccess IP in Wi-Fi mode, TMLAccess IP in LoRa mode.
    public var gateway: String = ""
    /// Shared signing key (TMedge's TM_KEY).
    public var key: String = ""

    public init(mode: UplinkMode = .wifi, ssid: String = "", password: String = "", gateway: String = "", key: String = "") {
        self.mode = mode
        self.ssid = ssid
        self.password = password
        self.gateway = gateway
        self.key = key
    }

    // Limits mirror TMsense's TmSettings buffers and its 160-byte console line.
    public static let maxSSID = 32
    public static let maxPassword = 63
    public static let maxKey = 64
    public static let idRange = 1...65535
    public static let maxBatch = 10

    /// Human-readable problems; empty means these settings can be written.
    public func problems() -> [String] {
        var out: [String] = []
        for (name, v) in [("SSID", ssid), ("Password", password), ("Gateway IP", gateway), ("Signing key", key)]
        where v.contains(where: { $0 == "\n" || $0 == "\r" }) {
            out.append("\(name) cannot contain a line break")
        }
        if ssid.utf8.count > Self.maxSSID { out.append("SSID is longer than \(Self.maxSSID) bytes") }
        if ssid.hasPrefix(" ") || ssid.hasSuffix(" ") { out.append("SSID starts or ends with a space") }
        if !password.isEmpty && (password.utf8.count < 8 || password.utf8.count > Self.maxPassword) {
            out.append("Wi-Fi password must be 8–\(Self.maxPassword) characters (WPA2)")
        }
        if !gateway.isEmpty && !Self.isIPv4(gateway) {
            out.append("\(mode.gatewayName) IP “\(gateway)” is not an IPv4 address")
        }
        if key.utf8.count > Self.maxKey { out.append("Signing key is longer than \(Self.maxKey) bytes") }
        if key.contains(" ") { out.append("Signing key cannot contain spaces") }
        return out
    }

    public static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { p in
            guard !p.isEmpty, p.count <= 3, p.allSatisfy(\.isASCII), p.allSatisfy(\.isNumber), let v = Int(p) else { return false }
            return v <= 255 && (p.count == 1 || p.first != "0")
        }
    }

    public static func problems(forID id: Int?) -> [String] {
        guard let id else { return ["Enter a node ID"] }
        return idRange.contains(id) ? [] : ["Node ID must be \(idRange.lowerBound)–\(idRange.upperBound)"]
    }

    /// Batch IDs: start...end, one per selected device, in order.
    public static func batchIDs(start: Int?, end: Int?, deviceCount: Int) -> Result<[Int], BatchError> {
        guard let start, let end else { return .failure(.missing) }
        guard idRange.contains(start), idRange.contains(end) else { return .failure(.outOfRange) }
        guard end >= start else { return .failure(.reversed) }
        let n = end - start + 1
        guard n <= maxBatch else { return .failure(.tooMany(n)) }
        guard n == deviceCount else { return .failure(.countMismatch(ids: n, devices: deviceCount)) }
        return .success(Array(start...end))
    }

    public enum BatchError: Error, Equatable, CustomStringConvertible {
        case missing, outOfRange, reversed, tooMany(Int), countMismatch(ids: Int, devices: Int)
        public var description: String {
            switch self {
            case .missing: return "Enter a starting and an ending ID"
            case .outOfRange: return "IDs must be \(idRange.lowerBound)–\(idRange.upperBound)"
            case .reversed: return "The ending ID is lower than the starting ID"
            case .tooMany(let n): return "\(n) IDs — at most \(maxBatch) nodes at a time"
            case let .countMismatch(ids, devices):
                return "\(ids) ID\(ids == 1 ? "" : "s") for \(devices) selected device\(devices == 1 ? "" : "s") — they must match"
            }
        }
    }
}

/// One line sent to the node's console, what a success looks like, and how it
/// may be shown in a log (secrets are masked).
public struct ConsoleCommand: Equatable, Sendable {
    public let line: String
    public let expect: String
    public let display: String

    /// The console commands that apply `settings` and `id`, then save.
    public static func provisioning(id: Int, settings s: NodeSettings) -> [ConsoleCommand] {
        var out = [ConsoleCommand(line: "set id \(id)", expect: "id updated", display: "set id \(id)"),
                   ConsoleCommand(line: "set mode \(s.mode.rawValue)", expect: "mode updated", display: "set mode \(s.mode.rawValue)")]
        switch s.mode {
        case .wifi:
            if !s.ssid.isEmpty { out.append(.init(line: "set ssid \(s.ssid)", expect: "ssid updated", display: "set ssid \(s.ssid)")) }
            if !s.password.isEmpty { out.append(.init(line: "set pass \(s.password)", expect: "pass updated", display: "set pass ••••••")) }
            if !s.gateway.isEmpty { out.append(.init(line: "set edges \(s.gateway)", expect: "edges updated", display: "set edges \(s.gateway)")) }
        case .lora:
            if !s.gateway.isEmpty { out.append(.init(line: "set lora_gw \(s.gateway)", expect: "lora_gw updated", display: "set lora_gw \(s.gateway)")) }
        }
        if !s.key.isEmpty { out.append(.init(line: "set key \(s.key)", expect: "key updated", display: "set key ••••••")) }
        out.append(.init(line: "save", expect: "saved", display: "save"))
        return out
    }
}
