import XCTest
@testable import TokenWatchCore

final class LeaderboardAuthTests: XCTestCase {
    private let state = "state-0123456789abcdefghijklmnopqrstuvwxyzABC"
    private let code = "m7k91GbRKi-2618MxYJCbWyzxU0sby69gqnZ4e11uc4"

    // MARK: - PKCE and state

    func testPKCEChallengeMatchesRFC7636AppendixB() {
        let pkce = LeaderboardAuth.PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(pkce.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testGeneratedVerifierAndStateAreFreshContractShapedValues() {
        let first = LeaderboardAuth.PKCE.generate(), second = LeaderboardAuth.PKCE.generate()
        XCTAssertNotEqual(first.verifier, second.verifier)
        for pkce in [first, second] {
            // The server's code_verifier and challenge rules.
            XCTAssertTrue(LeaderboardAuth.matches(pkce.verifier, #"^[A-Za-z0-9._~-]{43,128}$"#), pkce.verifier)
            XCTAssertTrue(LeaderboardAuth.matches(pkce.challenge, #"^[A-Za-z0-9_-]{43}$"#), pkce.challenge)
            XCTAssertEqual(pkce.challenge, LeaderboardAuth.PKCE.challenge(for: pkce.verifier))
        }
        let states = (0..<2).map { _ in LeaderboardAuth.makeState() }
        XCTAssertNotEqual(states[0], states[1])
        XCTAssertTrue(states.allSatisfy { LeaderboardAuth.matches($0, #"^[A-Za-z0-9._~-]{16,128}$"#) })
    }

    // MARK: - Callback

    private func callback(_ query: String) -> URL { URL(string: "tokenwatch://auth/callback?\(query)")! }

    func testCallbackWithMatchingStateYieldsCode() throws {
        XCTAssertEqual(try LeaderboardAuth.code(fromCallback: callback("code=\(code)&state=\(state)"), expectedState: state), code)
    }

    func testCallbackWithAnotherStateIsRejectedWhateverElseItCarries() {
        for query in ["code=\(code)&state=someone-elses-state-value", "error=access_denied&state=someone-elses-state-value", "code=\(code)"] {
            XCTAssertThrowsError(try LeaderboardAuth.code(fromCallback: callback(query), expectedState: state), query) {
                XCTAssertEqual($0 as? LeaderboardSignInError, .stateMismatch, query)
            }
        }
    }

    func testCallbackErrorParameterMeansTheUserDeclined() {
        XCTAssertThrowsError(try LeaderboardAuth.code(fromCallback: callback("error=access_denied&state=\(state)"), expectedState: state)) {
            XCTAssertEqual($0 as? LeaderboardSignInError, .denied)
        }
        XCTAssertThrowsError(try LeaderboardAuth.code(fromCallback: callback("error=server_error&state=\(state)"), expectedState: state)) {
            XCTAssertEqual($0 as? LeaderboardSignInError, .unexpectedCallback)
        }
    }

    func testCallbackWithoutAWellFormedCodeIsRejected() {
        for query in ["state=\(state)", "code=&state=\(state)", "code=short&state=\(state)", "code=\(code)%0A&state=\(state)"] {
            XCTAssertThrowsError(try LeaderboardAuth.code(fromCallback: callback(query), expectedState: state), query) {
                XCTAssertEqual($0 as? LeaderboardSignInError, .missingCode, query)
            }
        }
    }

    func testOnlyTheTokenWatchCallbackURLIsAccepted() {
        for url in ["https://tokenwat.ch/auth/callback?code=\(code)&state=\(state)", "tokenwatch://other/callback?code=\(code)&state=\(state)", "tokenwatch://auth/elsewhere?code=\(code)&state=\(state)"] {
            XCTAssertThrowsError(try LeaderboardAuth.code(fromCallback: URL(string: url)!, expectedState: state), url) {
                XCTAssertEqual($0 as? LeaderboardSignInError, .unexpectedCallback, url)
            }
        }
    }

    // MARK: - Connect URL and device name

    func testConnectURLCarriesEveryParameterEncodedForURLSearchParams() throws {
        let pkce = LeaderboardAuth.PKCE.generate()
        let url = try XCTUnwrap(LeaderboardAuth.connectURL(
            LeaderboardEndpoints.production.connect, challenge: pkce.challenge, state: state,
            deviceID: "5d0c6f1e-8a4b-4c2d-9e3f-7a1b2c3d4e5f", deviceName: "Ajay's MacBook Pro+Max", clientVersion: "1.9.0+build.7"
        ))
        XCTAssertTrue(url.absoluteString.hasPrefix("https://tokenwat.ch/connect?"))
        // `+` must not survive unencoded: URLSearchParams would read it as a space.
        XCTAssertFalse(url.query!.contains("+"))
        XCTAssertEqual(FakeAuthenticator.query(url, "challenge"), pkce.challenge)
        XCTAssertEqual(FakeAuthenticator.query(url, "state"), state)
        XCTAssertEqual(FakeAuthenticator.query(url, "device_id"), "5d0c6f1e-8a4b-4c2d-9e3f-7a1b2c3d4e5f")
        XCTAssertEqual(FakeAuthenticator.query(url, "device_name"), "Ajay's MacBook Pro+Max")
        XCTAssertEqual(FakeAuthenticator.query(url, "client_version"), "1.9.0+build.7")
    }

    func testConnectURLRefusesParametersTokenwatchWouldRejectWithAnErrorPage() {
        let challenge = LeaderboardAuth.PKCE.generate().challenge
        let device = "5d0c6f1e-8a4b-4c2d-9e3f-7a1b2c3d4e5f"
        let connect = LeaderboardEndpoints.production.connect
        XCTAssertNil(LeaderboardAuth.connectURL(connect, challenge: challenge, state: "short", deviceID: device, deviceName: "Mac", clientVersion: "1.9.0"))
        XCTAssertNil(LeaderboardAuth.connectURL(connect, challenge: challenge, state: state, deviceID: device.uppercased(), deviceName: "Mac", clientVersion: "1.9.0"))
        XCTAssertNil(LeaderboardAuth.connectURL(connect, challenge: challenge, state: state, deviceID: device, deviceName: "Evil\u{202E}Mac", clientVersion: "1.9.0"))
        XCTAssertNil(LeaderboardAuth.connectURL(connect, challenge: challenge, state: state, deviceID: device, deviceName: "Mac", clientVersion: "dev"))
        XCTAssertNil(LeaderboardAuth.connectURL(connect, challenge: "not-a-challenge", state: state, deviceID: device, deviceName: "Mac", clientVersion: "1.9.0"))
    }

    func testDeviceNameIsSanitizedToWhatConnectAccepts() {
        XCTAssertEqual(LeaderboardAuth.deviceName(from: "  Ajay's MacBook Pro \n"), "Ajay's MacBook Pro")
        XCTAssertEqual(LeaderboardAuth.deviceName(from: "Mac\u{0007}Book\u{202E}\u{2066}\u{FEFF} Air"), "Mac Book Air")
        XCTAssertEqual(LeaderboardAuth.deviceName(from: nil), "Mac")
        XCTAssertEqual(LeaderboardAuth.deviceName(from: "\u{202E}\n"), "Mac")
        // 64 UTF-16 code units at most, never splitting a character (each flag is 4 units).
        let flags = String(repeating: "🇮🇳", count: 20)
        let name = LeaderboardAuth.deviceName(from: flags)
        XCTAssertEqual(name.utf16.count, 64)
        XCTAssertEqual(name, String(repeating: "🇮🇳", count: 16))
    }

    // MARK: - Wire shapes

    func testTokenRequestEncodesLikeTheContractFixture() throws {
        let request = LeaderboardDeviceTokenRequest(code: code, codeVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", deviceID: "5d0c6f1e-8a4b-4c2d-9e3f-7a1b2c3d4e5f", timeZone: "Asia/Kolkata")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
        XCTAssertEqual(encoded as? NSDictionary, try Contract.json("fixtures/device-token.v1.valid.json") as? NSDictionary)
        XCTAssertEqual(JSONSchemaCheck.errors(encoded, try Contract.schema("device-token.v1")), [])
        // No time zone: the key is left out, not sent as null.
        let bare = try JSONSerialization.jsonObject(with: JSONEncoder().encode(LeaderboardDeviceTokenRequest(code: code, codeVerifier: request.codeVerifier, deviceID: request.deviceID, timeZone: nil)))
        XCTAssertNil((bare as? [String: Any])?["time_zone"])
        XCTAssertEqual(JSONSchemaCheck.errors(bare, try Contract.schema("device-token.v1")), [])
    }

    func testDecodesTheContractsTokenResponse() throws {
        let response = try JSONDecoder().decode(LeaderboardDeviceTokenResponse.self, from: Contract.data("fixtures/device-token-response.v1.valid.json"))
        XCTAssertEqual(response.login, "octocat")
        XCTAssertEqual(response.profileUrl.absoluteString, "https://tokenwat.ch/@octocat")
        XCTAssertNotNil(response.avatarUrl)
    }

    func testMapsTheContractsErrorBodies() throws {
        func error(_ status: Int, _ fixture: String) throws -> LeaderboardAPIError? {
            LeaderboardAPI.error(status: status, body: try Contract.data("fixtures/\(fixture)"), retryAfter: nil, now: Date())
        }
        XCTAssertEqual(try error(400, "error.v1.valid.invalid-grant.json"), .invalidGrant)
        XCTAssertEqual(try error(410, "error.v1.valid.device-revoked.json"), .revoked)
        XCTAssertEqual(try error(426, "error.v1.valid.unsupported-schema-version.json"), .upgradeRequired)
        XCTAssertEqual(LeaderboardAPI.error(status: 400, body: Data(#"{"error":"invalid_request","message":"x"}"#.utf8), retryAfter: nil, now: Date()), .rejected(status: 400, code: "invalid_request"))
        XCTAssertNil(LeaderboardAPI.error(status: 204, body: Data(), retryAfter: nil, now: Date()))
    }

    func testRetryAfterReadsSecondsAndHTTPDates() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertEqual(LeaderboardAPI.retryAfterSeconds("120", now: now), 120)
        XCTAssertEqual(LeaderboardAPI.retryAfterSeconds("-5", now: now), 0)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        XCTAssertEqual(LeaderboardAPI.retryAfterSeconds(formatter.string(from: now.addingTimeInterval(90)), now: now), 90)
        XCTAssertNil(LeaderboardAPI.retryAfterSeconds("soon", now: now))
        XCTAssertNil(LeaderboardAPI.retryAfterSeconds(nil, now: now))
    }

    func testEndpointOverridesAreDebugOnlyAndNeedAnHTTPURL() {
        let local = LeaderboardEndpoints.current(environment: ["TOKENWATCH_WEB_URL": "http://localhost:3000", "TOKENWATCH_API_URL": "http://localhost:8787"])
        #if DEBUG
        XCTAssertEqual(local.web.absoluteString, "http://localhost:3000")
        XCTAssertEqual(local.api.absoluteString, "http://localhost:8787")
        XCTAssertEqual(local.connect.absoluteString, "http://localhost:3000/connect")
        #else
        XCTAssertEqual(local, .production)
        #endif
        XCTAssertEqual(LeaderboardEndpoints.current(environment: ["TOKENWATCH_API_URL": "file:///etc/passwd"]), .production)
        XCTAssertEqual(LeaderboardEndpoints.current(environment: [:]), .production)
    }
}
