import Foundation
import Combine

/// Opens tokenwat.ch's consent page and answers the `tokenwatch://` callback URL it redirects
/// to. The app implements it with `ASWebAuthenticationSession`.
@MainActor
public protocol LeaderboardWebAuthenticating: AnyObject {
    /// Throws `LeaderboardSignInError.cancelled` when the user closes the window.
    func authenticate(url: URL, callbackScheme: String) async throws -> URL
    /// Closes an open sign-in window; `authenticate` then throws `.cancelled`.
    func cancel()
}

/// The opt-in leaderboard: joining (device sign-in), leaving, and the local state behind them.
/// Off by default: until the user joins, nothing here reads the Keychain or touches the network.
@MainActor
public final class LeaderboardService: ObservableObject {
    public enum SignInState: Equatable, Sendable {
        case idle
        case inProgress
        case failed(LeaderboardSignInError)
    }

    /// The joined account, or `nil` when this Mac isn't on the leaderboard.
    @Published public private(set) var account: LeaderboardAccount?
    @Published public private(set) var notice: LeaderboardNotice?
    @Published public private(set) var signInState: SignInState = .idle

    public var endpoints: LeaderboardEndpoints { api.endpoints }

    private let api: LeaderboardAPI
    private let tokens: LeaderboardTokenStore
    private let clientVersion: String
    private let deviceName: @Sendable () -> String
    private let enrollmentFile: LeaderboardFile<LeaderboardEnrollment>
    private var enrollment: LeaderboardEnrollment
    private weak var authenticator: LeaderboardWebAuthenticating?

    /// `directory` defaults to TokenWatch's Application Support directory, next to `config.json`.
    public init(api: LeaderboardAPI = LeaderboardAPI(), tokens: LeaderboardTokenStore = KeychainLeaderboardTokenStore(), directory: URL? = nil, clientVersion: String, deviceName: @escaping @Sendable () -> String = { LeaderboardAuth.deviceName(from: Host.current().localizedName) }) {
        self.api = api
        self.tokens = tokens
        self.clientVersion = clientVersion
        self.deviceName = deviceName
        enrollmentFile = LeaderboardFile(directory: directory ?? ConfigStore.defaultDirectory(), name: "leaderboard.json")
        var enrollment = enrollmentFile.load() ?? LeaderboardEnrollment()
        if enrollment.notice == .updateRequired, enrollment.updateRequiredVersion != clientVersion {
            // A different app version may be accepted again.
            enrollment.notice = nil
            enrollment.updateRequiredVersion = nil
        }
        self.enrollment = enrollment
        account = enrollment.account
        notice = enrollment.notice
    }

    // MARK: - Joining and leaving

    /// Joins with GitHub: opens `/connect` through `authenticator`, checks the callback and
    /// exchanges its code for this Mac's token, which goes to the Keychain.
    public func signIn(with authenticator: LeaderboardWebAuthenticating) async {
        guard account == nil, signInState != .inProgress else { return }
        signInState = .inProgress
        self.authenticator = authenticator
        defer { self.authenticator = nil }
        do {
            let deviceID = ensureDeviceID()
            let name = await Task.detached(priority: .userInitiated) { [deviceName] in deviceName() }.value
            let pkce = LeaderboardAuth.PKCE.generate()
            let state = LeaderboardAuth.makeState()
            guard let url = LeaderboardAuth.connectURL(api.endpoints.connect, challenge: pkce.challenge, state: state, deviceID: deviceID, deviceName: name, clientVersion: clientVersion) else {
                throw LeaderboardSignInError.couldNotStart
            }
            let callback = try await authenticator.authenticate(url: url, callbackScheme: LeaderboardAuth.callbackScheme)
            let code = try LeaderboardAuth.code(fromCallback: callback, expectedState: state)
            let timeZone = TimeZone.current.identifier
            let response: LeaderboardDeviceTokenResponse
            do {
                response = try await api.exchangeCode(LeaderboardDeviceTokenRequest(
                    code: code, codeVerifier: pkce.verifier, deviceID: deviceID,
                    timeZone: LeaderboardAuth.isValidTimeZone(timeZone) ? timeZone : nil
                ))
            } catch LeaderboardAPIError.invalidGrant {
                throw LeaderboardSignInError.expired
            } catch let error as LeaderboardAPIError {
                throw LeaderboardSignInError.api(error)
            }
            do {
                try tokens.setToken(response.token)
            } catch {
                throw LeaderboardSignInError.keychain
            }
            let joined = LeaderboardAccount(login: response.login, avatarURL: response.avatarUrl, profileURL: response.profileUrl)
            updateEnrollment {
                $0.account = joined
                $0.isPaused = false
                $0.notice = nil
                $0.updateRequiredVersion = nil
            }
            signInState = .idle
        } catch let error as LeaderboardSignInError {
            signInState = error == .cancelled ? .idle : .failed(error)
        } catch {
            signInState = .failed(.couldNotStart)
        }
    }

    /// Closes the sign-in window, if one is open.
    public func cancelSignIn() {
        authenticator?.cancel()
    }

    /// Leaves: revokes this Mac on the server (best effort -- offline still signs out here), then
    /// deletes the token and the account.
    public func signOut() async {
        guard account != nil else { return }
        if let token = tokens.token() {
            try? await api.signOutDevice(token: token)
        }
        signOutLocally(notice: nil)
    }

    /// Forgets the token and the account, keeping the device id.
    func signOutLocally(notice: LeaderboardNotice?) {
        try? tokens.deleteToken()
        updateEnrollment {
            $0.account = nil
            $0.isPaused = false
            $0.notice = notice
            $0.updateRequiredVersion = nil
        }
    }

    // MARK: - State

    /// This Mac's leaderboard id: a random lowercase UUID made on the first sign-in and kept for
    /// good. No hardware identifier is involved.
    private func ensureDeviceID() -> String {
        if let id = enrollment.deviceID, LeaderboardAuth.isValidDeviceID(id) { return id }
        let id = UUID().uuidString.lowercased()
        updateEnrollment { $0.deviceID = id }
        return id
    }

    private func updateEnrollment(_ change: (inout LeaderboardEnrollment) -> Void) {
        change(&enrollment)
        enrollmentFile.save(enrollment)
        if account != enrollment.account { account = enrollment.account }
        if notice != enrollment.notice { notice = enrollment.notice }
    }
}
