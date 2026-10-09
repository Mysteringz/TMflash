/// Claims about asking TMedge to admit a node.
///
/// The interesting cases are the unhappy ones. A denied request and a request
/// nobody has answered look almost identical over the wire -- the uid is not
/// registered either way -- and telling them apart is the difference between
/// "go and ask why" and "somebody is still walking to the console".
import XCTest
@testable import TMflashCore

/// A stand-in for the edge's provisioning endpoints. Answers in-process
/// through URLProtocol rather than over a socket: no ports, no sleeping, and
/// no chance of the machine's VPN deciding loopback is not allowed today.
final class StubEdge: URLProtocol {
    struct Reply: Sendable { var code: Int; var body: String; var contentType = "application/json" }
    nonisolated(unsafe) static var requestReply = Reply(code: 202, body: #"{"status":"pending","id":"1","uid":"$uid"}"#)
    nonisolated(unsafe) static var statusReply: Reply?
    nonisolated(unsafe) static var accountReply: Reply?
    nonisolated(unsafe) static var statuses: [String] = []
    nonisolated(unsafe) static var seenAuth: [String] = []
    nonisolated(unsafe) static var seenBodies: [String] = []
    nonisolated(unsafe) static var seenURLs: [URL] = []
    nonisolated(unsafe) static var preflightReply = Reply(code: 200, body: #"{"protocol":"tmflash.adoption.v1","ready":true,"approval":"human"}"#)

    static func reset() {
        requestReply = Reply(code: 202, body: #"{"status":"pending","id":"1","uid":"$uid"}"#)
        statusReply = nil
        accountReply = nil
        statuses = []
        seenAuth = []
        seenBodies = []
        seenURLs = []
        preflightReply = Reply(code: 200, body: #"{"protocol":"tmflash.adoption.v1","ready":true,"approval":"human"}"#)
    }

    static var session: URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubEdge.self]
        return URLSession(configuration: c)
    }

    static var server: EdgeServer { EdgeServer(url: "https://edge.test", token: String(repeating: "t", count: 32)) }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        if let url = request.url { StubEdge.seenURLs.append(url) }
        StubEdge.seenAuth.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
        // URLProtocol hands the body back as a stream, so read it that way.
        if let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 2048)
            let n = stream.read(&buf, maxLength: buf.count)
            if n > 0 { StubEdge.seenBodies.append(String(decoding: buf[0..<n], as: UTF8.self)) }
            stream.close()
        } else if let b = request.httpBody {
            StubEdge.seenBodies.append(String(decoding: b, as: UTF8.self))
        }

        let requestUID = StubEdge.seenBodies.last.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }?["uid"] ?? ""
        let uid = path.hasSuffix("/request") ? requestUID : request.url?.lastPathComponent ?? ""
        let reply: StubEdge.Reply = path.hasSuffix("/exchange") ? StubEdge.accountReply ?? Reply(code: 401, body: "{}") : path.hasSuffix("/preflight") ? StubEdge.preflightReply : path.hasSuffix("/request")
            ? StubEdge.requestReply
            : StubEdge.statusReply ?? Reply(code: 200, body: #"{"uid":"$uid","status":"\#(StubEdge.statuses.isEmpty ? "unknown" : StubEdge.statuses.removeFirst())"}"#)

        let response = HTTPURLResponse(url: request.url!, statusCode: reply.code,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": reply.contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.replacingOccurrences(of: "$uid", with: uid).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class EdgeClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubEdge.reset()
        EdgeClient.session = StubEdge.session
        EdgeClient.pollInterval = 0.05   // the logic is the subject, not the clock
    }

    override func tearDown() {
        EdgeClient.session = EdgeClient.defaultSession
        EdgeClient.pollInterval = 2
        super.tearDown()
    }

    func testABareHostnameIsAssumedSecureRatherThanSentInClear() throws {
        // http:// would put the provisioning token on the wire in clear, so a
        // typed-in hostname gets https, not whatever happens to answer.
        XCTAssertEqual(try EdgeClient.base(EdgeServer(url: "sense.example.com", token: "x")).scheme, "https")
        XCTAssertEqual(try EdgeClient.base(EdgeServer(url: "https://e.example/", token: "x")).absoluteString, "https://e.example")
        XCTAssertThrowsError(try EdgeClient.base(EdgeServer(url: "not a url", token: "x")))
    }

    func testAnAlreadyKnownNodeIsNotQueuedAgain() async throws {
        StubEdge.requestReply = .init(code: 200, body: #"{"status":"registered","uid":"$uid"}"#)

        let state = await EdgeClient.join(StubEdge.server, uid: "30:ed:a0:00:00:01", label: "Node 7", firmware: "1.4.2", timeout: 2)
        XCTAssertEqual(state, .registered)
        XCTAssertEqual(StubEdge.seenAuth.count, 1, "asked once and stopped: nothing to wait for")
        XCTAssertTrue(StubEdge.seenAuth.allSatisfy { $0.hasPrefix("Bearer ") }, "the token travels as a bearer credential")
        XCTAssertTrue(StubEdge.seenBodies.first?.contains("30:ed:a0:00:00:01") ?? false)
        XCTAssertTrue(StubEdge.seenBodies.first?.contains("1.4.2") ?? false, "the firmware version helps whoever decides")
    }

    func testWaitingResolvesWhenSomebodyAllowsItAtTheConsole() async throws {
        StubEdge.statuses = ["pending", "pending", "registered"]

        let state = await EdgeClient.join(StubEdge.server, uid: "30:ed:a0:00:00:02", label: "Node 8", firmware: nil, timeout: 5)
        XCTAssertEqual(state, .registered)
    }

    func testADeniedRequestIsReportedAsRefusedRatherThanAsATimeout() async throws {
        // The edge drops a denied request, so the uid goes from pending to
        // simply not being there. That is a "no", not a "not yet".
        StubEdge.statuses = ["pending", "unknown"]

        let state = await EdgeClient.join(StubEdge.server, uid: "30:ed:a0:00:00:03", label: "Node 9", firmware: nil, timeout: 5)
        XCTAssertEqual(state, .denied)
    }

    func testNobodyAnsweringIsATimeoutAndNotAFailure() async throws {
        StubEdge.statuses = Array(repeating: "pending", count: 100)

        let state = await EdgeClient.join(StubEdge.server, uid: "30:ed:a0:00:00:04", label: "Node 10", firmware: nil, timeout: 0.3)
        XCTAssertEqual(state, .timedOut, "the request is still queued at the edge; it just has no answer yet")
    }

    func testARefusedTokenSaysSoRatherThanLookingLikeAnUnreachableServer() async throws {
        StubEdge.requestReply = .init(code: 401, body: #"{"error":"provisioning is not available with that token"}"#)

        do {
            _ = try await EdgeClient.requestJoin(StubEdge.server, uid: "30:ed:a0:00:00:05", label: "x", firmware: nil)
            XCTFail("expected a refusal")
        } catch let e as EdgeError {
            XCTAssertTrue(e.description.contains("credential"), e.description)
        }
        StubEdge.preflightReply = .init(code: 401, body: #"{"error":"refused"}"#)
        let note = await EdgeClient.check(StubEdge.server)
        XCTAssertTrue(note.contains("refused the sign-in credential"))
    }

    func testASignInPageOrMalformedJSONNeverVerifiesAToken() async {
        for reply in [StubEdge.Reply(code: 200, body: "<html>Sign in</html>", contentType: "text/html"),
                      .init(code: 200, body: "{}"), .init(code: 200, body: "not JSON"),
                      .init(code: 200, body: #"{"uid":"wrong","status":"registered"}"#)] {
            StubEdge.preflightReply = reply
            let note = await EdgeClient.check(StubEdge.server)
            XCTAssertFalse(note.contains("Adoption is ready"))
        }
        StubEdge.preflightReply = .init(code: 302, body: "")
        let note = await EdgeClient.check(StubEdge.server)
        XCTAssertTrue(note.contains("redirected"))
    }

    func testRemoteHTTPAndCredentialsInURLsAreRefusedBeforeSendingAToken() throws {
        for url in ["http://edge.example", "https://user:password@edge.example", "https://edge.example?token=x", "https://edge.example/#x"] {
            XCTAssertThrowsError(try EdgeClient.request(EdgeServer(url: url, token: StubEdge.server.token), "api/provision/request", method: "POST"))
        }
        let local = try EdgeClient.request(EdgeServer(url: "http://127.0.0.1:8090/console/", token: StubEdge.server.token), "api/provision/request", method: "POST")
        XCTAssertEqual(local.url?.absoluteString, "http://127.0.0.1:8090/console/api/provision/request")
        XCTAssertFalse(EdgeServer(url: "https://edge.example", token: "short").problems().isEmpty)
        XCTAssertFalse(EdgeServer(url: "https://edge.example", token: String(repeating: "t", count: 32) + "\n").problems().isEmpty)
        XCTAssertFalse(EdgeServer(url: "https://edge.example", token: String(repeating: "t", count: 32) + ",").problems().isEmpty)
    }

    func testTokenRejectionFailsAdmissionAndDoesNotClaimAPendingRequest() async throws {
        StubEdge.requestReply = .init(code: 401, body: "{}")
        let state = await EdgeClient.join(StubEdge.server, uid: "30:ed:a0:00:00:06", label: "Node 6", firmware: nil, timeout: 1)
        guard case .failed(let reason) = state else { return XCTFail("expected a verification failure, got \(state)") }
        XCTAssertTrue(reason.contains("credential"))
        let node = try FakeNode(uid: "30:ed:a0:00:00:07")
        node.start()
        defer { node.stop() }
        let result = await Pipeline.run(jobs: [DeviceJob(port: node.path, nodeID: 7)], settings: NodeSettings(), writer: nil,
                                        options: .init(bootTimeout: 5, wifiTimeout: 0, server: StubEdge.server, approvalTimeout: 1)) { _ in }
        XCTAssertFalse(result[0].ok)
        XCTAssertTrue(result[0].error?.contains("refused the sign-in credential") == true)
        XCTAssertFalse(node.commands.contains("reboot"), "a refused admission is not reported as a waiting success")
    }

    func testInvalidPreflightNeverTouchesUSBOrInvokesTheFirmwareWriter() async throws {
        for reply in [StubEdge.Reply(code: 401, body: "{}"), .init(code: 403, body: "denied"), .init(code: 503, body: "{}"),
                      .init(code: 302, body: ""), .init(code: 200, body: "<html>Sign in</html>", contentType: "text/html"),
                      .init(code: 200, body: #"{"protocol":"tmflash.adoption.v1","ready":false,"approval":"human"}"#),
                      .init(code: 200, body: #"{"protocol":"tmflash.adoption.v1","ready":1,"approval":"human"}"#)] {
            StubEdge.reset()
            StubEdge.preflightReply = reply
            let node = try FakeNode(uid: "30:ed:a0:00:00:0a")
            node.start()
            let writer = AdoptionWriter()
            let result = await Pipeline.run(jobs: [.init(port: node.path, nodeID: 10)], settings: NodeSettings(), writer: writer,
                                            options: .init(server: StubEdge.server)) { _ in }
            node.stop()
            XCTAssertFalse(result[0].ok)
            let writes = await writer.calls()
            XCTAssertEqual(writes, 0, "failed access must be detected before flashing")
            XCTAssertTrue(node.commands.isEmpty, "no serial configuration command may precede preflight")
            XCTAssertEqual(StubEdge.seenURLs.count, 1)
            XCTAssertEqual(StubEdge.seenURLs.first?.path, "/api/provision/preflight")
        }
    }

    func testThePendingRequestShowsAMatchingCodeWithoutLoggingCredentials() async throws {
        StubEdge.requestReply = .init(code: 202, body: #"{"status":"pending","id":"1","uid":"$uid","pairingCode":"ABCDEF12"}"#)
        let log = LogBox()
        _ = try await EdgeClient.requestJoin(StubEdge.server, uid: "30:ed:a0:00:00:0b", label: "Node 11", firmware: nil) { log.add($0) }
        XCTAssertTrue(log.all.joined().contains("ABCDEF12"))
        XCTAssertFalse(log.all.joined().contains(StubEdge.server.token))
    }

    func testUnexpectedStatusesAndServerErrorsCannotMasqueradeAsAdmission() async throws {
        StubEdge.requestReply = .init(code: 202, body: #"{"status":"pending"}"#)
        let malformed = await EdgeClient.join(StubEdge.server, uid: "30:ed:a0:00:00:08", label: "Node 8", firmware: nil, timeout: 1)
        guard case .failed = malformed else { return XCTFail("malformed request confirmation was accepted") }
        StubEdge.requestReply = .init(code: 503, body: "{\"error\":\"\(StubEdge.server.token)\"}")
        let log = LogBox()
        _ = await EdgeClient.join(StubEdge.server, uid: "30:ed:a0:00:00:09", label: "Node 9", firmware: nil, timeout: 1) { log.add($0) }
        XCTAssertFalse(log.all.joined().contains(StubEdge.server.token), "server error bodies must not echo credentials into logs")
    }
}

private actor AdoptionWriter: FirmwareWriter {
    private var count = 0
    func write(port: String, log: @escaping @Sendable (String) -> Void, progress: @escaping @Sendable (Double) -> Void) async throws -> String? {
        count += 1
        return nil
    }
    func calls() -> Int { count }
}
