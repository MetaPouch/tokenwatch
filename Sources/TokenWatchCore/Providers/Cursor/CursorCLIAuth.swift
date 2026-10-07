import Foundation

/// The Cursor CLI's (`cursor-agent`) saved sign-in: one access token the CLI keeps in the macOS
/// Keychain, plus the identity it writes next to its settings.
struct CursorCLICredential: Equatable {
    let accessToken: String
    /// The WorkOS user id in the token's `sub` claim -- what tells this login apart from (or
    /// recognises it as the same person as) Cursor.app's.
    let userID: String
    let expiresAt: Date?
    /// From `~/.cursor/cli-config.json`, written at login; the usage API's own answer wins when
    /// it has one (`MultiAccountUsageService`).
    let email: String?
}

/// Reads the Cursor CLI's sign-in. Read-only: TokenWatch never writes to the CLI's Keychain
/// items, never uses its refresh token, and never refreshes anything -- the CLI renews its own
/// access token whenever it runs, so a lapsed one just shows as "renews next time you run it".
///
/// The Keychain item is the CLI's own (service `cursor-access-token`, account `cursor-user`), so
/// macOS may ask once to let TokenWatch read it; `detect()` only checks it exists, silently
/// (`KeychainPresence`), and flags `needsKeychainApproval` so onboarding can say so up front.
struct CursorCLIAuth: Sendable {
    static let accessTokenService = "cursor-access-token"
    static let keychainAccount = "cursor-user"

    private let homeDirectory: String
    private let readKeychain: @Sendable (String) async -> String?

    init(
        homeDirectory: String = NSHomeDirectory(),
        readKeychain: @escaping @Sendable (String) async -> String? = { await ExternalKeychainReader.readStringSilently(service: $0) }
    ) {
        self.homeDirectory = homeDirectory
        self.readKeychain = readKeychain
    }

    /// Whether the CLI has saved a sign-in, without reading it (never prompts).
    func hasSavedSignIn() -> Bool {
        KeychainPresence.exists(service: Self.accessTokenService, account: Self.keychainAccount)
    }

    /// True when reading the item would show macOS's approval dialog: it exists, but its access
    /// list doesn't let Apple's `security` tool read it silently.
    func needsKeychainApproval() -> Bool {
        hasSavedSignIn() && !ExternalKeychainReader.trustsSecurityTool(service: Self.accessTokenService)
    }

    /// The saved sign-in, or `nil` when there's none, it can't be read (e.g. approval declined),
    /// or it isn't a token whose owner can be identified. An expired token is still returned --
    /// the caller decides what a lapse means.
    func credential() async -> CursorCLICredential? {
        guard let raw = await readKeychain(Self.accessTokenService) else { return nil }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, let userID = CursorAuthStore.userID(fromAccessToken: token) else { return nil }
        return CursorCLICredential(accessToken: token, userID: userID, expiresAt: JWT.expiry(token), email: identityEmail())
    }

    private struct ConfigFile: Decodable {
        struct AuthInfo: Decodable { let email: String? }
        let authInfo: AuthInfo?
    }

    private func identityEmail() -> String? {
        guard let data = FileManager.default.contents(atPath: homeDirectory + "/.cursor/cli-config.json"),
              let config = try? JSONDecoder().decode(ConfigFile.self, from: data),
              let email = config.authInfo?.email, !email.isEmpty
        else { return nil }
        return email
    }
}

/// A Cursor CLI login that is a different person from the one Cursor.app is signed in as, shown
/// as its own card next to the default one.
struct CursorAdditionalAccount: Equatable {
    let sourceLabel: String
    let credential: CursorCLICredential
}

enum CursorAccountDiscovery {
    static let cliSourceLabel = "Cursor CLI"

    /// The CLI login to show as an extra card, or `nil` when there isn't one *to add*:
    /// - no CLI sign-in (or it can't be read);
    /// - Cursor.app has no usable token, in which case the CLI *is* the default card's source
    ///   (`CursorProvider.refresh()`), so there's nothing extra to show;
    /// - it's the same person as Cursor.app's, which the default card already shows.
    static func discoverAdditionalAccount(
        authStore: CursorAuthStore = CursorAuthStore(),
        cli: CursorCLIAuth = CursorCLIAuth()
    ) async -> CursorAdditionalAccount? {
        guard let appToken = authStore.validAccessToken(),
              let appUserID = CursorAuthStore.userID(fromAccessToken: appToken),
              let credential = await cli.credential(),
              credential.userID != appUserID
        else { return nil }
        return CursorAdditionalAccount(sourceLabel: cliSourceLabel, credential: credential)
    }
}
