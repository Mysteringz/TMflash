import XCTest
@testable import TMflashCore

final class AccountLoginTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubEdge.reset()
        EdgeClient.session = StubEdge.session
    }
    override func tearDown() {
        EdgeClient.session = EdgeClient.defaultSession
        super.tearDown()
    }

    func testExchangeUsesThePrivateVerifierAndRejectsInvalidOrExpiredSessions() async throws {
        let attempt = try AccountLoginAttempt(url: "https://algo.example")
        let callback = URL(string: "hk.hkumyseat.tmflash://login?code=\(String(repeating: "c", count: 43))&state=\(attempt.state)")!
        let expiry = Int64(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        let body = #"{"id":"session","token":"tmflash_\#(String(repeating: "a", count: 64))","user":"alice","expiresAt":\#(expiry)}"#
        StubEdge.accountReply = .init(code: 201, body: body)
        let session = try await attempt.complete(callback: callback)
        XCTAssertEqual(session.user, "alice")
        XCTAssertEqual(session.url, "https://algo.example")
        XCTAssertEqual(StubEdge.seenAuth, [""])
        XCTAssertEqual(StubEdge.seenURLs.first?.path, "/api/tmflash/exchange")
        let request = try XCTUnwrap(StubEdge.seenBodies.first).data(using: .utf8)!
        XCTAssertEqual((try JSONSerialization.jsonObject(with: request) as? [String: String])?["verifier"], attempt.verifier)
        for reply in [StubEdge.Reply(code: 201, body: body.replacingOccurrences(of: String(expiry), with: "1")),
                      .init(code: 201, body: body.replacingOccurrences(of: "tmflash_", with: "invalid_")),
                      .init(code: 201, body: "<html>Sign in</html>", contentType: "text/html"),
                      .init(code: 302, body: body), .init(code: 401, body: body)] {
            StubEdge.accountReply = reply
            do { _ = try await attempt.complete(callback: callback); XCTFail("An invalid exchange must not create a session") }
            catch { XCTAssertTrue(error is EdgeError) }
        }
    }

    func testPKCEUsesThePublishedSHA256VectorAndKeepsTheVerifierOffTheBrowserURL() throws {
        XCTAssertEqual(AccountLoginAttempt.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let attempt = try AccountLoginAttempt(url: "https://algo.example")
        XCTAssertEqual(attempt.verifier.count, 43)
        XCTAssertEqual(attempt.state.count, 43)
        XCTAssertFalse(attempt.authorizationURL.absoluteString.contains(attempt.verifier))
        let other = try AccountLoginAttempt(url: "https://algo.example")
        XCTAssertNotEqual(attempt.state, other.state)
        XCTAssertNotEqual(attempt.verifier, other.verifier)
    }

    func testTheCallbackCannotChangeOriginStateOrAddDuplicateParameters() throws {
        let attempt = try AccountLoginAttempt(url: "https://algo.example")
        let code = String(repeating: "x", count: 43)
        let good = "hk.hkumyseat.tmflash://login?code=\(code)&state=\(attempt.state)"
        XCTAssertEqual(try attempt.callbackCode(URL(string: good)!), code)
        XCTAssertThrowsError(try attempt.callbackCode(URL(string: "hk.hkumyseat.tmflash://login?error=cancelled&state=\(attempt.state)")!)) { error in
            XCTAssertTrue(String(describing: error).contains("cancelled"))
        }
        for bad in [good.replacingOccurrences(of: "login?", with: "evil?"), good + "&state=other", good + "#fragment",
                    good.replacingOccurrences(of: attempt.state, with: String(repeating: "a", count: 43)), "https://evil.example?code=\(code)&state=\(attempt.state)"] {
            XCTAssertThrowsError(try attempt.callbackCode(URL(string: bad)!))
        }
    }

    func testAStoredAccountSessionCannotBeSentToAnotherConsoleOrUsedAfterExpiry() {
        let session = FlasherSession(id: "test", token: "tmflash_" + String(repeating: "a", count: 64), user: "alice", expiresAt: Int64(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000), url: "https://algo.example")
        XCTAssertTrue(AccountClient.matches(session, url: "algo.example"))
        XCTAssertFalse(AccountClient.matches(session, url: "https://another.example"))
        let expired = FlasherSession(id: session.id, token: session.token, user: session.user, expiresAt: 1, url: session.url)
        XCTAssertFalse(AccountClient.matches(expired, url: session.url))
    }
}
