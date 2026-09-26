import Foundation
import Security

/// Every node TMflash writes, as CSV: node ID ↔ MAC is what you need to add a
/// node to TMedge's nodes.json (which identifies nodes by MAC). No secrets.
public enum Manifest {
    public static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TMflash")
        return dir.appendingPathComponent("manifest.csv")
    }

    /// New columns are appended at the end, so rows written by an older
    /// TMflash still line up (their extra fields read as empty).
    static let header = "time,node_id,uid,mode,gateway,ssid,firmware,port,wifi_ip,result,notes,transport,cloud_url,edge_accepted\n"
    static let headerV1 = "time,node_id,uid,mode,gateway,ssid,firmware,port,wifi_ip,result,notes\n"

    public static func append(_ results: [JobResult], settings: NodeSettings, to url: URL = Manifest.url) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { try header.write(to: url, atomically: true, encoding: .utf8) }
        else if let existing = try? String(contentsOf: url, encoding: .utf8), existing.hasPrefix(headerV1) {
            // A manifest from before direct cloud: widen its header, keep every row.
            try (header + existing.dropFirst(headerV1.count)).write(to: url, atomically: true, encoding: .utf8)
        }
        let now = ISO8601DateFormatter().string(from: Date())
        var text = ""
        for r in results {
            let fields: [String] = [now, String(r.job.nodeID), r.uid ?? "", settings.mode.rawValue, settings.gateway,
                                    settings.mode == .wifi ? settings.ssid : "", r.firmware ?? "", r.job.port, r.wifiIP ?? "",
                                    r.ok ? "ok" : "failed", (r.error.map { [$0] } ?? r.warnings).joined(separator: "; "),
                                    // What the node reports, not what was asked for.
                                    (r.transport ?? (settings.mode == .wifi ? settings.transport : .udp)).rawValue,
                                    r.cloudURL ?? "",
                                    r.edgeAccepted.map { $0 ? "yes" : "no" } ?? ""]
            text += fields.map(csv).joined(separator: ",") + "\n"
        }
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: Data(text.utf8))
    }

    static func csv(_ s: String) -> String {
        s.contains(where: { ",\"\n".contains($0) }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }
}

/// Wi-Fi password and signing key, remembered in the login Keychain, never on disk.
public enum SecretStore {
    static let service = "TMflash"

    public static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    public static func set(_ account: String, _ value: String?) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        SecItemAdd(add as CFDictionary, nil)
    }
}

public enum Probe {
    /// Asks a connected board what it is, without flashing. Opening the port
    /// leaves the board running (see SerialPort), so this is safe on a live node.
    public static func identify(port: String, timeout: TimeInterval = 4) async -> NodeInfo? {
        try? await Pipeline.blocking {
            let p = try SerialPort(path: port)
            defer { p.close() }
            return try NodeConsole(port: p, log: { _ in }).waitUntilReady(timeout: timeout)
        }
    }
}
