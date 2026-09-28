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
    struct Reply: Sendable { var code: Int; var body: String }
    nonisolated(unsafe) static var requestReply = Reply(code: 202, body: #"{"status":"pending","id":"1"}"#)
    nonisolated(unsafe) static var statuses: [String] = []
    nonisolated(unsafe) static var seenAuth: [String] = []
    nonisolated(unsafe) static var seenBodies: [String] = []

    static func reset() {
        requestReply = Reply(code: 202, body: #"{"status":"pending","id":"1"}"#)
        statuses = []
        seenAuth = []
        seenBodies = []
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

        let reply: StubEdge.Reply = path.hasSuffix("/request")
            ? StubEdge.requestReply
            : Reply(code: 200, body: #"{"status":"\#(StubEdge.statuses.isEmpty ? "unknown" : StubEdge.statuses.removeFirst())"}"#)

        let response = HTTPURLResponse(url: request.url!, statusCode: reply.code,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
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
        EdgeClient.session = .shared
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
        StubEdge.requestReply = .init(code: 200, body: #"{"status":"registered"}"#)

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
            XCTAssertTrue(e.description.contains("token"), e.description)
        }
        // check() uses the status endpoint, which the stub always allows.
        let note = await EdgeClient.check(StubEdge.server)
        XCTAssertEqual(note, "Connected. The token is accepted.")
    }
}
