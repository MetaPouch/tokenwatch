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

/// The opt-in leaderboard: joining (device sign-in), leaving, and syncing local usage to
/// tokenwat.ch. Off by default: until the user joins -- and while they pause -- nothing here
/// reads the Keychain or makes a request.
///
/// Syncing reuses what `SpendHistoryStore` already scanned (`usageDidChange`); it never rescans
/// on its own, except once for the history upload:
/// - **Incremental:** today's and the two previous days' rows that changed since the server
///   last acknowledged them, a minute after the first change, and never sooner than the
///   server's `nextSyncAfterSeconds`. With nothing changed, an hourly heartbeat resends them (or
///   checks in when there's no usage) so the device's last-seen time stays fresh.
/// - **History:** after joining (and on "Resync all history"), the 30 days the app already holds,
///   then every older month `UsageBackfill` finds, newest first, in requests of at most 2,000
///   rows. Progress is saved per month, so a quit resumes where it stopped.
/// - **Errors:** 401/403/410 sign out here ("Disconnected, sign in again"); 426 stops syncing
///   until TokenWatch is updated; 429/503 wait out `Retry-After`; offline and other failures back
///   off from a minute up to an hour.
@MainActor
public final class LeaderboardService: ObservableObject {
    public enum SignInState: Equatable, Sendable {
        case idle
        case inProgress
        case failed(LeaderboardSignInError)
    }

    /// What syncing needs from the outside world; tests substitute a clock and a history.
    public struct Environment {
        public var now: () -> Date
        public var calendar: () -> Calendar
        /// Waits between scheduled syncs.
        public var sleep: @Sendable (TimeInterval) async throws -> Void
        /// Whether the history upload asks Cursor's API (only while the Cursor provider is on).
        public var includeCursorHistory: () -> Bool
        /// Local history through `through`'s day, newest month first. Called off the main actor.
        public var scanHistory: @Sendable (_ through: Date, _ includeCursor: Bool) async throws -> [UsageBackfill.Month]

        public init(
            now: @escaping () -> Date = Date.init,
            calendar: @escaping () -> Calendar = { .current },
            sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) },
            includeCursorHistory: @escaping () -> Bool = { false },
            scanHistory: @escaping @Sendable (_ through: Date, _ includeCursor: Bool) async throws -> [UsageBackfill.Month] = { try await LeaderboardService.scanLocalHistory(through: $0, includeCursor: $1) }
        ) {
            self.now = now
            self.calendar = calendar
            self.sleep = sleep
            self.includeCursorHistory = includeCursorHistory
            self.scanHistory = scanHistory
        }
    }

    /// The joined account, or `nil` when this Mac isn't on the leaderboard.
    @Published public private(set) var account: LeaderboardAccount?
    @Published public private(set) var notice: LeaderboardNotice?
    @Published public private(set) var signInState: SignInState = .idle
    /// Paused here: no request at all until resumed.
    @Published public private(set) var isPaused: Bool
    @Published public private(set) var lastSyncAt: Date?
    @Published public private(set) var syncIssue: LeaderboardSyncIssue?
    /// The user paused syncing on tokenwat.ch: uploads are accepted but not stored.
    @Published public private(set) var isPausedOnWeb: Bool
    /// `nil` when there's no history upload to do.
    @Published public private(set) var history: LeaderboardHistoryProgress?

    public var endpoints: LeaderboardEndpoints { api.endpoints }

    private typealias Policy = LeaderboardSyncPolicy
    private let api: LeaderboardAPI
    private let tokens: LeaderboardTokenStore
    private let clientVersion: String
    private let deviceName: @Sendable () -> String
    private let environment: Environment
    private let enrollmentFile: LeaderboardFile<LeaderboardEnrollment>
    private let syncFile: LeaderboardFile<LeaderboardSyncState>
    private var enrollment: LeaderboardEnrollment
    private var sync: LeaderboardSyncState
    private weak var authenticator: LeaderboardWebAuthenticating?
    private var started = false
    private var cachedToken: String?
    /// `SpendHistoryStore`'s latest days; `nil` until its first load.
    private var latestDays: [SpendSource: [UsageDay]]?
    /// When a not-yet-sent local change first arrived.
    private var changedAt: Date?
    /// History read this launch and not yet uploaded, newest month first.
    private var historyQueue: [(month: String, rows: [LeaderboardUsageRow])]?
    private var timer: Task<Void, Never>?
    private var work: Task<Void, Never>?
    private var workGeneration = 0

    /// `directory` defaults to TokenWatch's Application Support directory, next to `config.json`.
    public init(api: LeaderboardAPI = LeaderboardAPI(), tokens: LeaderboardTokenStore = KeychainLeaderboardTokenStore(), directory: URL? = nil, clientVersion: String, deviceName: @escaping @Sendable () -> String = { LeaderboardAuth.deviceName(from: Host.current().localizedName) }, environment: Environment = Environment()) {
        self.api = api
        self.tokens = tokens
        self.clientVersion = clientVersion
        self.deviceName = deviceName
        self.environment = environment
        let directory = directory ?? ConfigStore.defaultDirectory()
        enrollmentFile = LeaderboardFile(directory: directory, name: "leaderboard.json")
        syncFile = LeaderboardFile(directory: directory, name: "leaderboard-sync.json")
        var enrollment = enrollmentFile.load() ?? LeaderboardEnrollment()
        if enrollment.notice == .updateRequired, enrollment.updateRequiredVersion != clientVersion {
            // A different app version may be accepted again.
            enrollment.notice = nil
            enrollment.updateRequiredVersion = nil
        }
        self.enrollment = enrollment
        sync = enrollment.account == nil ? LeaderboardSyncState() : syncFile.load() ?? LeaderboardSyncState()
        account = enrollment.account
        notice = enrollment.notice
        isPaused = enrollment.isPaused
        lastSyncAt = sync.lastSuccessAt
        syncIssue = sync.issue
        isPausedOnWeb = sync.pausedOnWeb
        history = sync.backfill == nil ? nil : .waiting
    }

    // MARK: - App events

    /// At launch. Syncing starts only if this Mac joined and isn't paused.
    public func start() {
        guard !started else { return }
        started = true
        schedule()
    }

    /// `SpendHistoryStore` finished a scan (a filesystem event, a provider refresh, a panel open).
    public func usageDidChange(_ daysBySource: [SpendSource: [UsageDay]]) {
        latestDays = daysBySource
        guard canSync else { return }
        if changedAt == nil, changedRecentRows() != nil { changedAt = environment.now() }
        schedule()
    }

    public func setPaused(_ paused: Bool) {
        guard account != nil, paused != enrollment.isPaused else { return }
        updateEnrollment { $0.isPaused = paused }
        if paused { stopWork() } else { schedule() }
    }

    /// Uploads all local history again (the server keeps one row per day, source and model).
    public func resyncAllHistory() {
        guard account != nil else { return }
        stopWork()
        historyQueue = nil
        updateSync { $0.backfill = LeaderboardBackfillProgress() }
        schedule()
    }

    /// The next incremental upload's exact body -- the same bytes the sync sends -- or `nil`
    /// when there's nothing to send (no usage in the last three days, or history still loading).
    public func nextUploadPreview() -> String? {
        nextIncrementalRequest(heartbeat: true).map { String(decoding: LeaderboardPayloadBuilder.encode($0), as: UTF8.self) }
    }

    // MARK: - Joining and leaving

    /// Joins with GitHub: opens `/connect` through `authenticator`, checks the callback and
    /// exchanges its code for this Mac's token, which goes to the Keychain. Then uploads history.
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
            let response: LeaderboardDeviceTokenResponse
            do {
                response = try await api.exchangeCode(LeaderboardDeviceTokenRequest(code: code, codeVerifier: pkce.verifier, deviceID: deviceID, timeZone: timeZoneIdentifier()))
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
            cachedToken = response.token
            let joined = LeaderboardAccount(login: response.login, avatarURL: response.avatarUrl, profileURL: response.profileUrl)
            updateEnrollment {
                $0.account = joined
                $0.isPaused = false
                $0.notice = nil
                $0.updateRequiredVersion = nil
            }
            resetSync(LeaderboardSyncState(backfill: LeaderboardBackfillProgress()))
            signInState = .idle
            schedule()
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
        stopWork()
        if let token = token() {
            try? await api.signOutDevice(token: token)
        }
        signOutLocally(notice: nil)
    }

    /// Forgets the token, the account and the sync state, keeping the device id.
    func signOutLocally(notice: LeaderboardNotice?) {
        stopWork()
        try? tokens.deleteToken()
        cachedToken = nil
        updateEnrollment {
            $0.account = nil
            $0.isPaused = false
            $0.notice = notice
            $0.updateRequiredVersion = nil
        }
        resetSync(LeaderboardSyncState())
        syncFile.delete()
    }

    // MARK: - Scheduling

    private var canSync: Bool {
        started && account != nil && !enrollment.isPaused && enrollment.notice != .updateRequired
    }

    /// When there's next something to do, or `nil` while syncing is off or local history hasn't
    /// loaded yet.
    func nextWake() -> Date? {
        guard canSync, latestDays != nil else { return nil }
        let allowed = sync.nextAllowedAt ?? .distantPast
        if sync.backfill != nil { return max(allowed, environment.now()) }
        var due = (sync.lastAttemptAt ?? .distantPast).addingTimeInterval(Policy.heartbeat)
        if let changedAt { due = min(due, changedAt.addingTimeInterval(Policy.debounce)) }
        return max(allowed, due)
    }

    private func schedule() {
        timer?.cancel()
        timer = nil
        guard work == nil, let wake = nextWake() else { return }
        let delay = wake.timeIntervalSince(environment.now())
        let sleep = environment.sleep
        timer = Task { [weak self] in
            do { try await sleep(max(0, delay)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.startWork()
        }
    }

    private func startWork() {
        timer = nil
        guard work == nil else { return }
        workGeneration += 1
        let generation = workGeneration
        work = Task { [weak self] in
            await self?.performDueWork()
            guard let self, self.workGeneration == generation else { return }
            self.work = nil
            self.schedule()
        }
    }

    private func stopWork() {
        timer?.cancel()
        timer = nil
        work?.cancel()
        work = nil
        workGeneration += 1
    }

    /// Does whatever is due now: the history upload while one is pending, else an incremental
    /// sync, a heartbeat, or nothing.
    func performDueWork() async {
        guard canSync, latestDays != nil else { return }
        let now = environment.now()
        if let allowed = sync.nextAllowedAt, now < allowed { return }
        guard let token = token(), let deviceID = enrollment.deviceID else {
            signOutLocally(notice: .disconnected)
            return
        }
        if sync.backfill != nil {
            await uploadHistory(token: token, deviceID: deviceID)
            return
        }
        let dueChange = changedAt.map { now >= $0.addingTimeInterval(Policy.debounce) } ?? false
        let dueHeartbeat = now >= (sync.lastAttemptAt ?? .distantPast).addingTimeInterval(Policy.heartbeat)
        guard dueChange || dueHeartbeat else { return }
        if let request = nextIncrementalRequest(heartbeat: dueHeartbeat) {
            await sendIncremental(request, token: token)
        } else if dueHeartbeat {
            await checkIn(token: token)
        } else {
            changedAt = nil
        }
    }

    // MARK: - Incremental

    /// Today's and the two previous local days' ids.
    private func recentDates() -> [String] {
        let calendar = environment.calendar()
        let today = calendar.startOfDay(for: environment.now())
        return (0..<Policy.recentDays)
            .compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
            .map { UsageDay.dayID(for: $0, timeZone: calendar.timeZone) }
    }

    /// Every row of each recent day whose rows changed since the server acknowledged them.
    private func changedRecentRows() -> [LeaderboardUsageRow]? {
        guard let latestDays else { return nil }
        let rows = LeaderboardPayloadBuilder.rows(from: latestDays, dates: Set(recentDates()))
        let changed = Dictionary(grouping: rows, by: \.date)
            .filter { LeaderboardPayloadBuilder.fingerprint($0.value) != sync.acknowledgedDays[$0.key] }
        return changed.isEmpty ? nil : rows.filter { changed[$0.date] != nil }
    }

    /// The changed recent rows or, for a heartbeat, every recent row.
    private func nextIncrementalRequest(heartbeat: Bool) -> LeaderboardUsageRequest? {
        guard let deviceID = enrollment.deviceID, let latestDays else { return nil }
        let rows = changedRecentRows() ?? (heartbeat ? LeaderboardPayloadBuilder.rows(from: latestDays, dates: Set(recentDates())) : [])
        guard !rows.isEmpty else { return nil }
        return LeaderboardPayloadBuilder.request(rows: rows, mode: .incremental, deviceID: deviceID, timeZone: timeZoneIdentifier(), clientVersion: clientVersion)
    }

    private func sendIncremental(_ request: LeaderboardUsageRequest, token: String) async {
        updateSync { $0.lastAttemptAt = environment.now() }
        do {
            let response = try await api.putUsage(LeaderboardPayloadBuilder.encode(request), token: token)
            succeeded(response)
            if !response.paused { acknowledge(request.rows) }
            changedAt = changedRecentRows() == nil ? nil : environment.now()
        } catch {
            failed(error)
        }
    }

    private func checkIn(token: String) async {
        updateSync { $0.lastAttemptAt = environment.now() }
        do {
            try await api.checkIn(token: token)
            updateSync {
                $0.lastSuccessAt = environment.now()
                $0.failures = 0
                $0.issue = nil
            }
        } catch {
            failed(error)
        }
    }

    /// Records what the server now holds for each recent day in `rows`.
    private func acknowledge(_ rows: [LeaderboardUsageRow]) {
        let recent = Set(recentDates())
        updateSync { state in
            for (date, dayRows) in Dictionary(grouping: rows, by: \.date) where recent.contains(date) {
                state.acknowledgedDays[date] = LeaderboardPayloadBuilder.fingerprint(dayRows)
            }
            state.acknowledgedDays = state.acknowledgedDays.filter { recent.contains($0.key) }
        }
    }

    // MARK: - History

    private func uploadHistory(token: String, deviceID: String) async {
        guard let latestDays, var progress = sync.backfill else { return }
        let calendar = environment.calendar()
        if progress.through == nil {
            let today = calendar.startOfDay(for: environment.now())
            let windowStart = calendar.date(byAdding: .day, value: -(Policy.historyWindowDays - 1), to: today) ?? today
            progress.through = windowStart.addingTimeInterval(-1)
            let fixed = progress
            updateSync { $0.backfill = fixed }
        }

        // 1. The days the app already shows, exactly as it shows them.
        if !progress.recentUploaded {
            history = .uploading(month: String(UsageDay.dayID(for: environment.now(), timeZone: calendar.timeZone).prefix(7)))
            let rows = LeaderboardPayloadBuilder.rows(from: latestDays)
            var sent = 0
            while sent < rows.count {
                let remaining = Array(rows[sent...])
                let count = LeaderboardPayloadBuilder.leadingRowsPerRequest(remaining, mode: .backfill, deviceID: deviceID, timeZone: timeZoneIdentifier(), clientVersion: clientVersion)
                guard await putHistory(Array(remaining.prefix(count)), token: token, deviceID: deviceID) else { return }
                sent += count
            }
            acknowledge(rows)
            updateSync { $0.backfill?.recentUploaded = true }
        }

        // 2. Everything older, read once per launch.
        if historyQueue == nil {
            history = .reading
            var through = progress.through ?? environment.now()
            if let month = progress.oldestUploadedMonth, let start = firstDay(ofMonth: month, calendar: calendar) {
                through = min(through, start.addingTimeInterval(-1))
            }
            let includeCursor = environment.includeCursorHistory()
            let scan = environment.scanHistory
            let task = Task.detached(priority: .utility) { [through] in try await scan(through, includeCursor) }
            do {
                let months = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                historyQueue = months
                    .map { (month: $0.id, rows: LeaderboardPayloadBuilder.rows(from: $0.daysBySource)) }
                    .filter { !$0.rows.isEmpty }
            } catch {
                history = .waiting
                // Cancelled by a pause or sign-out, which stopped the work; anything else waits.
                if !Task.isCancelled {
                    let retry = environment.now().addingTimeInterval(Policy.backoff(failures: 1))
                    updateSync { $0.nextAllowedAt = retry }
                }
                return
            }
        }

        // 3. Upload, newest month first; months share a request up to the row and size limits.
        while var queue = historyQueue, let first = queue.first {
            guard !Task.isCancelled else { return }
            history = .uploading(month: first.month)
            var pending: [LeaderboardUsageRow] = []
            for entry in queue where pending.count < LeaderboardPayloadBuilder.maxRowsPerRequest {
                pending += entry.rows
            }
            let count = LeaderboardPayloadBuilder.leadingRowsPerRequest(pending, mode: .backfill, deviceID: deviceID, timeZone: timeZoneIdentifier(), clientVersion: clientVersion)
            guard await putHistory(Array(pending.prefix(count)), token: token, deviceID: deviceID) else { return }
            var consumed = count
            var finished: String?
            while consumed > 0, !queue.isEmpty {
                if queue[0].rows.count <= consumed {
                    consumed -= queue[0].rows.count
                    finished = queue.removeFirst().month
                } else {
                    queue[0].rows.removeFirst(consumed)
                    consumed = 0
                }
            }
            historyQueue = queue
            if let finished { updateSync { $0.backfill?.oldestUploadedMonth = finished } }
        }
        historyQueue = nil
        updateSync { $0.backfill = nil }
    }

    /// One `mode: backfill` request. False when it wasn't stored: the upload stops there and is
    /// retried later (the error or a web pause already decided when).
    private func putHistory(_ rows: [LeaderboardUsageRow], token: String, deviceID: String) async -> Bool {
        guard !Task.isCancelled else { return false }
        let request = LeaderboardPayloadBuilder.request(rows: rows, mode: .backfill, deviceID: deviceID, timeZone: timeZoneIdentifier(), clientVersion: clientVersion)
        updateSync { $0.lastAttemptAt = environment.now() }
        do {
            let response = try await api.putUsage(LeaderboardPayloadBuilder.encode(request), token: token)
            succeeded(response)
            if response.paused {
                history = .waiting
                return false
            }
            return true
        } catch {
            history = .waiting
            failed(error)
            return false
        }
    }

    // MARK: - Outcomes

    private func succeeded(_ response: LeaderboardIngestResponse) {
        let now = environment.now()
        updateSync {
            $0.lastSuccessAt = now
            $0.failures = 0
            $0.issue = nil
            $0.pausedOnWeb = response.paused
            $0.nextAllowedAt = now.addingTimeInterval(TimeInterval(max(0, response.nextSyncAfterSeconds)))
        }
    }

    private func failed(_ error: Error) {
        // A pause or sign-out cancelled the request: not a failure.
        guard !Task.isCancelled, account != nil else { return }
        let failures = sync.failures + 1
        switch Policy.reaction(to: error as? LeaderboardAPIError ?? .offline, failures: failures) {
        case .signOut:
            signOutLocally(notice: .disconnected)
        case .stop:
            stopWork()
            updateEnrollment {
                $0.notice = .updateRequired
                $0.updateRequiredVersion = clientVersion
            }
        case let .retry(after, issue):
            let now = environment.now()
            updateSync {
                $0.failures = failures
                $0.issue = issue
                $0.nextAllowedAt = now.addingTimeInterval(after)
            }
        }
    }

    // MARK: - State

    private func token() -> String? {
        if cachedToken == nil { cachedToken = tokens.token() }
        return cachedToken
    }

    private func timeZoneIdentifier() -> String {
        let identifier = environment.calendar().timeZone.identifier
        return LeaderboardAuth.isValidTimeZone(identifier) ? identifier : "UTC"
    }

    private func firstDay(ofMonth month: String, calendar: Calendar) -> Date? {
        let parts = month.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return gregorian.date(from: DateComponents(year: parts[0], month: parts[1], day: 1))
    }

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
        if isPaused != enrollment.isPaused { isPaused = enrollment.isPaused }
    }

    private func updateSync(_ change: (inout LeaderboardSyncState) -> Void) {
        change(&sync)
        syncFile.save(sync)
        publishSync()
    }

    private func resetSync(_ state: LeaderboardSyncState) {
        sync = state
        historyQueue = nil
        changedAt = nil
        syncFile.save(sync)
        publishSync()
    }

    private func publishSync() {
        if lastSyncAt != sync.lastSuccessAt { lastSyncAt = sync.lastSuccessAt }
        if syncIssue != sync.issue { syncIssue = sync.issue }
        if isPausedOnWeb != sync.pausedOnWeb { isPausedOnWeb = sync.pausedOnWeb }
        if sync.backfill == nil, history != nil { history = nil }
        if sync.backfill != nil, history == nil { history = .waiting }
    }

    /// Reads local history for the upload, in `withBackgroundActivity` so App Nap doesn't
    /// throttle it.
    public nonisolated static func scanLocalHistory(through: Date, includeCursor: Bool) async throws -> [UsageBackfill.Month] {
        try await withBackgroundActivity(reason: "Reading local usage history for the leaderboard") {
            var months: [UsageBackfill.Month] = []
            try await UsageBackfill.scan(through: through, inputs: .standard(includeCursor: includeCursor)) { months.append($0) }
            return months
        }
    }
}
