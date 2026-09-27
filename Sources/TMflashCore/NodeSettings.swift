import Foundation

public enum UplinkMode: String, Codable, CaseIterable, Sendable {
    case wifi, lora

    public var title: String { self == .wifi ? "Wi-Fi" : "LoRa" }
    /// The access gateway a node in this mode sends to.
    public var gatewayName: String { self == .wifi ? "TMWAccess" : "TMLAccess" }
}

/// How a Wi-Fi node reaches TMedge (TMsense `set transport`). Separate from
/// the radio: `udp` sends to a local gateway or edge (`edges`); `wss` goes
/// straight to TMedge in the cloud over one TLS WebSocket, with no gateway
/// machine at the site.
public enum UplinkTransport: String, Codable, CaseIterable, Sendable {
    case udp, wss

    public var title: String { self == .udp ? "Local gateway (UDP)" : "Direct to cloud (WSS)" }
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
    /// Wi-Fi only. `.udp` is also what every node provisioned before direct
    /// cloud existed runs, and what a node keeps unless told otherwise.
    public var transport: UplinkTransport = .udp
    /// TMedge's node endpoint for `.wss`, e.g. wss://sense.example.com/tmnode.
    /// Blank keeps what the node has.
    public var cloudURL: String = ""

    public init(mode: UplinkMode = .wifi, ssid: String = "", password: String = "", gateway: String = "", key: String = "",
                transport: UplinkTransport = .udp, cloudURL: String = "") {
        self.mode = mode
        self.ssid = ssid
        self.password = password
        self.gateway = gateway
        self.key = key
        self.transport = transport
        self.cloudURL = cloudURL
    }

    enum CodingKeys: String, CodingKey { case mode, ssid, password, gateway, key, transport, cloudURL }

    /// Settings saved before direct cloud existed have no transport or URL:
    /// they decode as the UDP they always were.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(UplinkMode.self, forKey: .mode) ?? .wifi
        ssid = try c.decodeIfPresent(String.self, forKey: .ssid) ?? ""
        password = try c.decodeIfPresent(String.self, forKey: .password) ?? ""
        gateway = try c.decodeIfPresent(String.self, forKey: .gateway) ?? ""
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        transport = try c.decodeIfPresent(UplinkTransport.self, forKey: .transport) ?? .udp
        cloudURL = try c.decodeIfPresent(String.self, forKey: .cloudURL) ?? ""
    }

    // Limits mirror TMsense's TmSettings buffers and its 160-byte console line.
    public static let maxSSID = 32
    public static let maxPassword = 63
    public static let maxKey = 64
    /// TMsense TM_CLOUD_URL_MAX: ASCII bytes, never truncated.
    public static let maxCloudURL = 128
    public static let idRange = 1...65535
    public static let maxBatch = 10

    /// Human-readable problems; empty means these settings can be written.
    public func problems() -> [String] {
        var out: [String] = []
        for (name, v) in [("SSID", ssid), ("Password", password), ("Gateway IP", gateway), ("Signing key", key), ("Cloud URL", cloudURL)]
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
        if mode == .lora && transport == .wss { out.append("LoRa has no direct-cloud transport; choose the local gateway") }
        if !cloudURL.isEmpty, let p = Self.cloudURLProblem(cloudURL) { out.append(p) }
        return out
    }

    /// The form TMsense stores and compares: lowercase scheme and host, no
    /// explicit :443. The firmware refuses an uppercase host rather than
    /// guessing, so TMflash normalises before sending.
    public static func canonicalCloudURL(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard let schemeEnd = t.range(of: "://") else { return t }
        let scheme = t[..<schemeEnd.lowerBound].lowercased()
        let rest = t[schemeEnd.upperBound...]
        let slash = rest.firstIndex(of: "/") ?? rest.endIndex
        var authority = rest[..<slash].lowercased()
        if authority.hasSuffix(":443") { authority.removeLast(4) }
        return "\(scheme)://\(authority)\(rest[slash...])"
    }

    /// Mirrors TMsense tm_cloud_parse_url for a production build: the same
    /// URL is refused in the same way on both sides, before a node is touched.
    public static func cloudURLProblem(_ url: String) -> String? {
        let bytes = Array(url.utf8)
        if bytes.isEmpty || bytes.count > maxCloudURL { return "Cloud URL must be 1–\(maxCloudURL) characters" }
        if bytes.contains(where: { $0 <= 0x20 || $0 >= 0x7f || $0 == UInt8(ascii: "%") || $0 == UInt8(ascii: "\\") }) {
            return "Cloud URL may contain only printable ASCII, no spaces, % or \\"
        }
        if url.contains("?") || url.contains("#") { return "Cloud URL must not have a query or fragment" }
        guard url.hasPrefix("wss://") else { return "Cloud URL must start with wss://" }
        let rest = url.dropFirst(6)
        guard let slash = rest.firstIndex(of: "/") else { return "Cloud URL needs a path, like /tmnode" }
        let authority = rest[..<slash]
        if authority.contains("@") { return "Cloud URL must not contain a user name or password" }
        var host = Substring(authority)
        if let colon = authority.firstIndex(of: ":") {
            host = authority[..<colon]
            if authority[authority.index(after: colon)...] != "443" { return "Cloud URL port must be 443" }
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let hostOK = !host.isEmpty && host.count <= 100 && labels.allSatisfy { l in
            !l.isEmpty && l.count <= 63 && l.first != "-" && l.last != "-" &&
                l.allSatisfy { ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "-" }
        } && host.contains(where: { $0 >= "a" && $0 <= "z" })
        if !hostOK { return "Cloud URL host must be a lowercase DNS name" }
        let path = rest[slash...]
        let pathChars = path.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "/-_.~".contains($0)) }
        if path.count < 2 || path.count > 64 || !pathChars || path.contains("//") ||
            path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) {
            return "Cloud URL path must be like /tmnode"
        }
        return nil
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
    /// `directCloud`: the firmware on the board understands `transport` and
    /// `cloud_url` (its `show` lists capability wss1). Without it, nothing
    /// about transport is sent -- old firmware is UDP by definition -- and a
    /// request for direct cloud is refused before any command, by the caller.
    public static func provisioning(id: Int, settings s: NodeSettings, directCloud: Bool = false) -> [ConsoleCommand] {
        var out = [ConsoleCommand(line: "set id \(id)", expect: "id updated", display: "set id \(id)"),
                   ConsoleCommand(line: "set mode \(s.mode.rawValue)", expect: "mode updated", display: "set mode \(s.mode.rawValue)")]
        switch s.mode {
        case .wifi:
            if !s.ssid.isEmpty { out.append(.init(line: "set ssid \(s.ssid)", expect: "ssid updated", display: "set ssid \(s.ssid)")) }
            if !s.password.isEmpty { out.append(.init(line: "set pass \(s.password)", expect: "pass updated", display: "set pass ••••••")) }
            if !s.gateway.isEmpty { out.append(.init(line: "set edges \(s.gateway)", expect: "edges updated", display: "set edges \(s.gateway)")) }
            if directCloud {
                // The URL first: the firmware refuses `transport wss` without one.
                let url = NodeSettings.canonicalCloudURL(s.cloudURL)
                if !url.isEmpty { out.append(.init(line: "set cloud_url \(url)", expect: "cloud_url updated", display: "set cloud_url \(url)")) }
                out.append(.init(line: "set transport \(s.transport.rawValue)", expect: "transport updated", display: "set transport \(s.transport.rawValue)"))
            }
        case .lora:
            // Leaving Wi-Fi: a node set to wss must go back to udp first, or the firmware refuses LoRa.
            if directCloud { out.insert(.init(line: "set transport udp", expect: "transport updated", display: "set transport udp"), at: 1) }
            if !s.gateway.isEmpty { out.append(.init(line: "set lora_gw \(s.gateway)", expect: "lora_gw updated", display: "set lora_gw \(s.gateway)")) }
        }
        if !s.key.isEmpty { out.append(.init(line: "set key \(s.key)", expect: "key updated", display: "set key ••••••")) }
        out.append(.init(line: "save", expect: "saved", display: "save"))
        return out
    }
}
