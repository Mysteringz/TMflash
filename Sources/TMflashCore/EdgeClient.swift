/// Asking TMedge to admit a node we have just flashed.
///
/// A node cannot authenticate to the edge until its uid is in the edge's
/// node list, and nobody knows that uid until the node has been flashed. So
/// this closes the loop: once the board has been provisioned and can say what
/// its uid is, TMflash asks, and somebody with the edge's debug console open
/// answers. The wait is on purpose -- admitting a node decides which devices
/// the edge will talk to, and that is a person's decision, not a flasher's.
///
/// The token buys exactly one thing: the right to queue that question. It is
/// kept in the login Keychain like every other secret here, is never logged,
/// and never reaches a command line.
import Foundation

public struct EdgeServer: Equatable, Sendable {
    /// The console's base URL, e.g. https://sense.hkumyseat.com
    public var url: String
    public var token: String

    public init(url: String, token: String) {
        self.url = url
        self.token = token
    }

    public var isConfigured: Bool { !url.trimmingCharacters(in: .whitespaces).isEmpty && !token.isEmpty }
}

public enum AdmissionState: Equatable, Sendable {
    /// Already in the edge's list: nothing to ask.
    case registered
    /// Queued, waiting for somebody at the console.
    case pending
    case denied
    /// Asked, but nobody answered inside the timeout. The request stays
    /// queued at the edge, so this is "not yet", not "no".
    case timedOut
}

public struct EdgeError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ d: String) { description = d }
}

public enum EdgeClient {
    /// How often to ask whether somebody has answered yet.
    /// Settable so tests do not have to wait in real seconds.
    static var pollInterval: TimeInterval = 2
    /// The session every call goes through, so tests can supply their own.
    static var session: URLSession = .shared

    static func base(_ server: EdgeServer) throws -> URL {
        var text = server.url.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("/") { text.removeLast() }
        // A bare hostname is the common typo, and http:// would send the
        // token in clear. Assume the secure scheme rather than the reachable one.
        if !text.contains("://") { text = "https://" + text }
        guard let u = URL(string: text), let scheme = u.scheme, scheme == "https" || scheme == "http" else {
            throw EdgeError("“\(server.url)” is not a URL like https://sense.hkumyseat.com")
        }
        return u
    }

    static func request(_ server: EdgeServer, _ path: String, method: String, body: [String: Any]? = nil) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: try base(server)) else { throw EdgeError("could not build a URL for \(path)") }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 15
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    /// Does this server answer, and does it accept the token? Used by the
    /// Test button, so the answer has to be a sentence someone can act on.
    public static func check(_ server: EdgeServer) async -> String {
        do {
            // Asking the status of a uid that cannot exist: it touches the
            // same token check as a real request but queues nothing.
            let r = try request(server, "api/provision/status/00:00:00:00:00:00", method: "GET")
            let (_, response) = try await session.data(for: r)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200: return "Connected. The token is accepted."
            case 401: return "Reached the server, but it refused the token."
            case 404: return "Reached the server, but it has no provisioning endpoint — is TMFLASH_TOKEN set on the edge?"
            default: return "Reached the server, but it answered HTTP \(code)."
            }
        } catch {
            return "Could not reach the server: \(error.localizedDescription)"
        }
    }

    /// Queue a join request. Returns whether the node is already known.
    public static func requestJoin(_ server: EdgeServer, uid: String, label: String, firmware: String?) async throws -> AdmissionState {
        var body: [String: Any] = ["uid": uid, "label": label]
        if let firmware { body["firmware"] = firmware }
        let r = try request(server, "api/provision/request", method: "POST", body: body)
        let (data, response) = try await session.data(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        switch code {
        case 200 where (json["status"] as? String) == "registered": return .registered
        case 202: return .pending
        case 401: throw EdgeError("the edge refused the provisioning token")
        default: throw EdgeError((json["error"] as? String) ?? "the edge answered HTTP \(code)")
        }
    }

    public static func status(_ server: EdgeServer, uid: String) async throws -> String {
        let r = try request(server, "api/provision/status/\(uid)", method: "GET")
        let (data, response) = try await session.data(for: r)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw EdgeError("the edge would not say whether \(uid) is registered") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (json["status"] as? String) ?? "unknown"
    }

    /// Ask, then wait for somebody at the console to answer.
    ///
    /// A request that disappears means it was denied: the edge drops a denied
    /// request, so a uid that was pending and is now unknown has been turned
    /// down. Reporting that as a refusal rather than a timeout is the
    /// difference between "try again" and "go and ask why".
    public static func join(_ server: EdgeServer, uid: String, label: String, firmware: String?,
                            timeout: TimeInterval,
                            log: @Sendable (String) -> Void = { _ in }) async -> AdmissionState {
        do {
            let first = try await requestJoin(server, uid: uid, label: label, firmware: firmware)
            if first == .registered {
                log("TMedge already knows \(uid)")
                return .registered
            }
            log("asked TMedge to admit \(uid) — waiting for someone to allow it in the console")
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                let s = try await status(server, uid: uid)
                if s == "registered" {
                    log("TMedge admitted \(uid)")
                    return .registered
                }
                if s == "unknown" {
                    log("the request for \(uid) was turned down")
                    return .denied
                }
            }
            return .timedOut
        } catch is CancellationError {
            return .timedOut
        } catch {
            log("could not ask TMedge to admit \(uid): \(error)")
            return .timedOut
        }
    }
}
