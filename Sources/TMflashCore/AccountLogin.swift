import CryptoKit
import Foundation
import Security

public struct FlasherSession: Codable, Equatable, Sendable {
    public let id: String
    public let token: String
    public let user: String
    public let expiresAt: Int64
    public var url: String
    public var isExpired: Bool { expiresAt <= Int64(Date().timeIntervalSince1970 * 1000) }
    public var server: EdgeServer { EdgeServer(url: url, token: token) }
    public init(id: String, token: String, user: String, expiresAt: Int64, url: String) {
        self.id = id; self.token = token; self.user = user; self.expiresAt = expiresAt; self.url = url
    }
}

/// Only the challenge and state go to the browser. The verifier stays on
/// this Mac, so intercepting the callback cannot produce a flasher session.
public struct AccountLoginAttempt: Sendable {
    public static let callbackScheme = "hk.hkumyseat.tmflash"
    public let authorizationURL: URL
    let serverURL: String
    let verifier: String
    let state: String

    public init(url: String) throws {
        let base = try EdgeClient.base(EdgeServer(url: url, token: ""))
        serverURL = base.absoluteString
        verifier = try Self.random()
        state = try Self.random()
        let challenge = Self.challenge(verifier)
        var components = URLComponents(url: base.appendingPathComponent("tmflash/connect"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "challenge", value: challenge), URLQueryItem(name: "state", value: state)]
        guard let authorization = components.url else { throw EdgeError("Cannot construct the console sign-in URL") }
        authorizationURL = authorization
    }

    static func challenge(_ verifier: String) -> String { encode(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    static func encode(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw EdgeError("Could not create a secure sign-in request") }
        return encode(Data(bytes))
    }

    func callbackCode(_ url: URL) throws -> String {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme == Self.callbackScheme,
              parts.host == "login", parts.path.isEmpty, parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              let items = parts.queryItems, items.count == 2,
              items.filter({ $0.name == "state" }).count == 1, items.first(where: { $0.name == "state" })?.value == state else {
            throw EdgeError("The console sign-in response could not be verified. Sign in again.")
        }
        if items.first(where: { $0.name == "error" })?.value == "cancelled" {
            throw EdgeError("Sign-in cancelled. No device was changed.")
        }
        guard
              let code = items.first(where: { $0.name == "code" })?.value,
              code.range(of: #"^[A-Za-z0-9_-]{43}$"#, options: .regularExpression) != nil else {
            throw EdgeError("The console sign-in response could not be verified. Sign in again.")
        }
        return code
    }

    public func complete(callback: URL) async throws -> FlasherSession {
        let code = try callbackCode(callback)
        let base = try EdgeClient.base(EdgeServer(url: serverURL, token: ""))
        var request = URLRequest(url: base.appendingPathComponent("api/tmflash/exchange"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code, "verifier": verifier])
        request.timeoutInterval = 15
        let (data, response) = try await EdgeClient.session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 201, response.mimeType == "application/json" else {
            throw EdgeError("The console could not complete sign-in. Check the account API's Cloudflare policy and sign in again.")
        }
        struct Reply: Decodable { let id: String; let token: String; let user: String; let expiresAt: Int64 }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data), !reply.id.isEmpty,
              reply.token.range(of: #"^tmflash_[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              reply.user.range(of: #"^[a-z0-9][a-z0-9_.-]{1,31}$"#, options: .regularExpression) != nil,
              reply.expiresAt > Int64(Date().timeIntervalSince1970 * 1000),
              reply.expiresAt <= Int64(Date().addingTimeInterval(25 * 3600).timeIntervalSince1970 * 1000) else {
            throw EdgeError("The console returned an invalid sign-in session")
        }
        return FlasherSession(id: reply.id, token: reply.token, user: reply.user, expiresAt: reply.expiresAt, url: serverURL)
    }
}

public enum AccountClient {
    public static func matches(_ session: FlasherSession, url: String) -> Bool {
        (try? EdgeClient.base(EdgeServer(url: url, token: "")).absoluteString) == session.url && !session.isExpired
    }
    public static func signOut(_ session: FlasherSession) async throws {
        let request = try EdgeClient.request(session.server, "api/tmflash/logout", method: "POST")
        let (_, response) = try await EdgeClient.session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 204 else { throw EdgeError("The console could not revoke this sign-in. Revoke it in Adoption.") }
    }
}
