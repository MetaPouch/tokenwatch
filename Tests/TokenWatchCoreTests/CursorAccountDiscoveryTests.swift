import XCTest
import SQLite3
@testable import TokenWatchCore

final class CursorAccountDiscoveryTests: XCTestCase {
    private var home: URL!

    override func setUp() {
        super.setUp()
        home = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-discovery-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
        super.tearDown()
    }

    private func base64URL(_ text: String) -> String {
        Data(text.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private func token(user: String, exp: TimeInterval = 4_102_444_800) -> String {
        base64URL(#"{"alg":"HS256"}"#) + "." + base64URL(#"{"sub":"google-oauth2|\#(user)","exp":\#(Int(exp))}"#) + ".sig"
    }

    /// Cursor.app's state DB, holding `accessToken` the way the real one does.
    private func writeAppSignIn(_ accessToken: String) {
        let path = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb").path
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB); INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', '\(accessToken)');", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
    }

    private func writeCLIConfig(email: String) {
        let dir = home.appendingPathComponent(".cursor")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? #"{"authInfo":{"email":"\#(email)","teamName":"Acme"},"version":1}"#.write(to: dir.appendingPathComponent("cli-config.json"), atomically: true, encoding: .utf8)
    }

    private func cli(keychain: String?) -> CursorCLIAuth {
        CursorCLIAuth(homeDirectory: home.path, readKeychain: { _ in keychain })
    }

    private func discover(keychain: String?) async -> CursorAdditionalAccount? {
        await CursorAccountDiscovery.discoverAdditionalAccount(authStore: CursorAuthStore(homeDirectory: home.path), cli: cli(keychain: keychain))
    }

    // MARK: CursorCLIAuth

    func testCredentialCarriesOwnerExpiryAndConfigEmail() async {
        writeCLIConfig(email: "me@acme.test")
        let credential = await cli(keychain: "  \(token(user: "user_CLI", exp: 4_102_444_800))\n").credential()

        XCTAssertEqual(credential?.userID, "user_CLI")
        XCTAssertEqual(credential?.expiresAt, Date(timeIntervalSince1970: 4_102_444_800))
        XCTAssertEqual(credential?.email, "me@acme.test")
        XCTAssertEqual(credential?.accessToken, token(user: "user_CLI", exp: 4_102_444_800), "surrounding whitespace is trimmed off the token")
    }

    func testCredentialIsNilWithoutAReadableTokenOfAKnownOwner() async {
        let missing = await cli(keychain: nil).credential()
        let empty = await cli(keychain: "  ").credential()
        let opaque = await cli(keychain: "not-a-jwt").credential()
        XCTAssertNil(missing)
        XCTAssertNil(empty)
        XCTAssertNil(opaque, "a token whose owner can't be identified can't be told apart from the app's, so it isn't offered")
    }

    func testEmailIsNilWhenTheCLIConfigIsMissing() async {
        let credential = await cli(keychain: token(user: "user_CLI")).credential()
        XCTAssertNotNil(credential)
        XCTAssertNil(credential?.email)
    }

    // MARK: CursorAccountDiscovery

    func testADifferentCLIUserBecomesItsOwnAccount() async {
        writeAppSignIn(token(user: "user_APP"))
        writeCLIConfig(email: "team@acme.test")

        let account = await discover(keychain: token(user: "user_CLI"))

        XCTAssertEqual(account?.credential.userID, "user_CLI")
        XCTAssertEqual(account?.credential.email, "team@acme.test")
        XCTAssertEqual(account?.sourceLabel, "Cursor CLI")
    }

    func testTheSameUserInBothIsNotShownTwice() async {
        writeAppSignIn(token(user: "user_SAME"))
        let account = await discover(keychain: token(user: "user_SAME", exp: 4_102_444_000))
        XCTAssertNil(account, "the default card already shows this person")
    }

    func testWithoutAUsableAppSignInTheCLIIsTheDefaultCardsSourceNotAnExtra() async {
        let noApp = await discover(keychain: token(user: "user_CLI"))
        XCTAssertNil(noApp)

        writeAppSignIn(token(user: "user_APP", exp: Date().timeIntervalSince1970 - 3600))
        let expiredApp = await discover(keychain: token(user: "user_CLI"))
        XCTAssertNil(expiredApp, "an expired app token leaves the CLI as the default card's source too")
    }

    func testNoCLISignInMeansNoExtraAccount() async {
        writeAppSignIn(token(user: "user_APP"))
        let account = await discover(keychain: nil)
        XCTAssertNil(account)
    }

    func testALapsedCLITokenIsStillOfferedSoItsCardCanSayWhy() async {
        writeAppSignIn(token(user: "user_APP"))
        let account = await discover(keychain: token(user: "user_CLI", exp: Date().timeIntervalSince1970 - 3600))

        XCTAssertEqual(account?.credential.userID, "user_CLI")
        XCTAssertLessThan(account?.credential.expiresAt ?? .distantFuture, Date())
    }

    func testUserIDIsTheTokenSubjectAfterTheLastPipe() {
        XCTAssertEqual(CursorAuthStore.userID(fromAccessToken: token(user: "user_01ABC")), "user_01ABC")
        XCTAssertNil(CursorAuthStore.userID(fromAccessToken: "not-a-jwt"))
    }
}
