# Security

## What this app reads, and why

TokenWatch's entire purpose is showing you usage/limits/credits across AI providers you've
already signed into elsewhere. To do that, each provider's runtime reads **one** local credential
source (see the table in [README.md](README.md)) — a Keychain item another CLI wrote, an OAuth
token file, a locally-stored API key you paste in, or (for Cursor) a local SQLite session
database. Full detail per provider, including exact file paths and Keychain service names, is in
each provider's doc comment under `Sources/TokenWatchCore/Providers/`.

**What TokenWatch does with what it reads:**
- Sends the credential to that same provider's own official usage API, over HTTPS, to ask "what's
  my current usage." Nothing else -- a credential is never sent anywhere but the provider that
  issued it.
- Never writes to, modifies, or deletes another app's credential file or Keychain item — every
  read is read-only.
- Doesn't phone home. There is no telemetry, no analytics SDK, no crash reporter and no
  update-check ping, and out of the box it contacts no server TokenWatch's authors operate. You
  can verify this directly: every outbound host is a literal string in the relevant provider file
  (`*UsageClient.swift`, and `CursorUsageHistory.swift`), in `PricingRefreshService.swift` or in
  `LeaderboardAPI.swift` (the two exceptions below), and `git grep -n 'URL(string:'` finds all of
  them -- plus the one host allowlisted by name rather than URL, `LeaderboardAPI.avatarHost`.
- Exception 1, the price list: `PricingRefreshService` does a plain, unauthenticated GET of a
  public GitHub-hosted model-price list roughly hourly, to keep local cost estimates current.
  This request carries no credential, no usage data, and no identifying information -- it's
  indistinguishable from any other visitor fetching that public file. A fetch failure falls
  straight through to a bundled static table, so it's never a hard dependency.
- Exception 2, the opt-in leaderboard: `tokenwat.ch` and `api.tokenwat.ch` are contacted **only**
  after you join the leaderboard on the Leaderboard screen (the dashboard's top-right **Join
  Leaderboard** button, or ⋯ → Leaderboard), and while you pause syncing there nothing is sent
  unless you click Sign Out. The top-right button makes no request of its own. Until you join,
  nothing reads the leaderboard's Keychain item either. Both hosts are named only in
  `LeaderboardAPI.swift`; a DEBUG build can point them at local servers with `TOKENWATCH_WEB_URL`
  and `TOKENWATCH_API_URL`, which release builds ignore. What's sent:
  - Joining: the sign-in sheet opens `https://tokenwat.ch/connect` with `challenge` (PKCE S256),
    `state`, `device_id` (a random UUID made on the first sign-in and kept in
    `~/Library/Application Support/TokenWatch/leaderboard.json`; no hardware identifier),
    `device_name` (this Mac's name) and `client_version`. You sign in to GitHub on tokenwat.ch;
    no GitHub token reaches the app. The app then exchanges the one-time code at
    `POST /v1/devices/token` with `code`, `code_verifier`, `device_id` and `time_zone`.
  - Syncing: `PUT /v1/usage` with `schemaVersion`, `client` (`app`, `version`), `deviceId`,
    `timeZone`, `mode` (`incremental` or `backfill`) and `rows`, one per local day, source and
    model: `date`, `source`, `model`, `input`, `cacheRead`, `cacheWrite`, `output`, `costUSD` and
    `approximate`. Nothing else from your logs: no prompts, code, project or folder names, file
    paths or API keys. This version sends no plan or quota data. Leaderboard → Preview Upload
    shows the exact JSON of the next upload.
  - `GET /v1/devices` as an hourly check-in when there's no recent usage to send, and
    `DELETE /v1/devices/current` when you sign out.
  - Your avatar, from `avatars.githubusercontent.com` only (`LeaderboardAPI.avatarHost`, also
    named only in `LeaderboardAPI.swift`): the leaderboard button and screen show the GitHub
    avatar tokenwat.ch returned at sign-in, and GitHub's avatar CDN is where that image lives.
    It's a plain HTTPS GET with no token, no cookies and no redirects followed; any `avatarUrl`
    on another host, over plain HTTP, or with a port or credentials is never fetched. Only while
    joined and not paused, at most once a day or when the URL changes; the image is cached in
    `~/Library/Application Support/TokenWatch/leaderboard-avatar` and deleted when you sign out
    or tokenwat.ch signs this Mac out. GitHub sees your IP address, as for any image it serves.
  - With the Cursor provider on, the history upload asks Cursor's own usage API (the same
    request the Usage tab makes for its 30 days) for older Cursor history.

  The device token is stored in the Keychain under the service `dev.tokenwatch.credentials`,
  account `leaderboard.deviceToken` -- never in `config.json`, `UserDefaults` or logs -- and is
  sent only to `api.tokenwat.ch`. To leave, Leaderboard → Sign Out revokes this Mac on
  the server and deletes the token; Delete Account… opens `tokenwat.ch/account`, where you can
  delete your account and everything uploaded.
- API keys you enter yourself are stored in the macOS Keychain under the service
  `dev.tokenwatch.credentials`, scoped to TokenWatch's own code-signing identity. Cached derived
  sessions (currently: Cursor's Safari-cookie fallback) live under `dev.tokenwatch.cookiecache`,
  same scoping.

## Reporting a vulnerability

Please **do not** open a public GitHub issue for a suspected security vulnerability. Instead,
open a [private security advisory](https://github.com/MetaPouch/tokenwatch/security/advisories/new)
on this repository. Include:

- The provider(s) or file(s) involved.
- Steps to reproduce, or a proof of concept.
- What you'd expect to happen instead.

We'll acknowledge reports within a few days. There's no bug bounty — this is a small open-source
project — but we take credential-handling issues seriously given what the app touches, and will
credit reporters in the fix's release notes unless you'd rather stay anonymous.

## Scope notes for reviewers

- Zero external Swift package dependencies (`Package.swift` has no `dependencies:` entries) — the
  entire dependency-vulnerability surface is Apple's own frameworks (Foundation, AppKit, SwiftUI,
  Security, SQLite3, and for the leaderboard CryptoKit, AuthenticationServices and ImageIO).
- Every subprocess invocation (`Process`, in `BoundedSubprocess.swift` and
  `CodexAppServerClient.swift`) uses an argument array against a resolved executable path — never
  a shell string, so there's no command-injection surface from provider CLI output or PATH
  contents.
- `SafariCookieReader.swift` parses an externally-formatted binary file (Safari's cookie jar) with
  explicit bounds checks on every offset read from the file, since that file's structure isn't
  Apple-documented and its contents aren't fully trusted input.
- Distribution builds are signed with a Developer ID certificate and notarized by Apple (see
  [DISTRIBUTION.md](DISTRIBUTION.md)); Gatekeeper verifies the signature chain on every launch.
