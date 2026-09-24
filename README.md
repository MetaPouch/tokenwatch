# TokenWatch

[tokenwatch.fyi](https://tokenwatch.fyi)

A native macOS menu-bar app that shows session/weekly usage, limits, credit balances, and spend
for the AI subscriptions, routing providers, and API keys you actually use — in one place, with
nothing relayed off your device unless you join the optional [leaderboard](#leaderboard-optional).

## Supported providers

| Provider | Auth | Primary metric(s) |
| --- | --- | --- |
| Claude (Claude.ai / Claude Code) | OAuth (Claude CLI Keychain / `~/.claude/.credentials.json`) | Session (5h) + weekly (7d) percent, extra usage spend, cache temperature |
| Codex / ChatGPT | `~/.codex/auth.json`, `codex app-server` fallback | Session + weekly percent, cache temperature |
| OpenAI (raw API key) | API key | Today/7d spend |
| Cursor | Cursor.app local session (Safari cookie fallback) | Plan usage, on-demand spend |
| GitHub Copilot | Reused sign-in from another Copilot client | Premium interaction quota |
| Gemini + Antigravity | Gemini CLI OAuth / Antigravity CLI's own OAuth token file | Pro/Flash quota remaining |
| OpenRouter | API key | Credit balance, key limit |
| z.ai | API key | Token/credit quota |
| Kimi | API key | Session + weekly quota |
| Amp | CLI or API key | Free meter, credit balance |
| Grok | `~/.grok/auth.json` | Credit usage percent |
| OpenCode Go | API key | Rolling + weekly usage percent |

Quota summaries use a single account per provider on the menu bar and the Limits tab. The Limits
tab additionally discovers and shows every local Claude/Codex login it can find, not just the default one.
Everything runs locally: no telemetry, and no usage data leaves your device unless you join the
optional [leaderboard](#leaderboard-optional).

## Menu bar behavior

On the very first launch, before anything is configured, TokenWatch opens the dashboard once on
its own -- the status item alone (a plain ring, nothing to show yet) is easy to miss the very
first time. Every later launch leaves discovery to the status item.

While no provider is enabled, the dashboard is an onboarding screen listing every provider found
on this Mac (`ProviderRuntime.detect()`, run by `ProviderDetectionStore` each time the popover
opens), all pre-selected with where each was found ("Signed in with Claude Code", "API key saved
in TokenWatch", "OPENAI_API_KEY is set"); one click (or Return) tracks them, and they're fetched
immediately rather than on the next refresh cycle. Detection is silent by construction: file and
directory checks, a lookup of CLIs on `PATH` plus the usual install directories (Homebrew, npm,
`~/.local/bin`, ...) that an app launched from Finder doesn't inherit, and Keychain *existence*
probes that ask for attributes only with authentication UI disallowed -- never a secret read, so
no macOS access prompt, no network, no subprocess. Settings marks each provider found on this Mac
the same way.

Reading Claude Code's sign-in doesn't raise macOS's "wants to use your confidential information"
prompt either. Claude Code writes its Keychain item with Apple's `security` tool, which puts that
tool on the item's access list; TokenWatch checks the access list (never the secret, so the check
itself can't prompt) and, when it trusts `/usr/bin/security` and admits Apple's command-line
tools, reads the item through `security find-generic-password` instead of from its own process.
Only when the item doesn't allow that -- written some other way -- does TokenWatch read it
directly, where macOS asks once; onboarding then says so up front.

By default (nothing starred yet) the status item shows a smart summary: whichever enabled
provider has a recent local-activity signal (currently: Claude and Codex, from local session
transcripts, refreshed within the last 24h) shows its name, its current session percent (never
weekly, even if weekly happens to be higher), and a progress ring. Ring/cache-badge coloring is
unchanged from before. Otherwise it falls back to whichever enabled provider's metric is closest
to its limit (highest used/limit ratio).

Star a metric from its right-click menu (or from Customize) to pin it instead -- once anything
is starred, the primary status-item display switches to those pinned metrics, one segment per
provider with real data, up to two metrics per provider. A provider whose stars have no data
yet drops out of the strip entirely rather than showing a placeholder.

Alongside that summary (including Bars style), compact **In / Out / Cache** counters show today's
tokens across enabled providers with usage history, including their omp/pi sessions. **In**
excludes cache reads/writes, **Out** is output, and **Cache** combines cache reads and writes:
the three counts are disjoint. Hover for exact counts, separate cache-read/write totals, and
the included providers. These are daily totals, not tokens per second.
Named services (Devin, fx, Muse Code) and Other remain in Total Spend; they have no provider
enablement toggle and are not included in the enabled-provider menu-bar counts.

Counters update from local log changes without opening the popover, follow provider enablement,
and reset for the new local calendar day. They remain hidden until history is loaded or when no
enabled provider has local history available.

**Settings → Menu Bar** provides an independent checklist: **Session limit / pinned metrics**,
**Input tokens**, **Output tokens**, and **Cache tokens**. Uncheck the limit entry for a
numbers-only display; its quota text and indicator are hidden in both Text and Bars styles.
Choose any subset of token counts, or uncheck everything for just a small clickable app icon.
Tooltips follow the same selection. Choices persist across launches. Existing installations
keep their prior token-count visibility when migrating from the old all-or-nothing toggle.

## Dashboard

One popover, three screens that slide horizontally instead of stacking as separate windows: the
dashboard (default), Customize, and Settings all share one fixed top bar and footer, and the
popover grows or shrinks to fit whichever screen is showing instead of staying one fixed size
with an internal scrollbar for short content. Click the status item to open it. The dashboard
screen itself has two tabs, switched via the segmented control at the top: **Limits** (default)
answers "how close am I to a wall," **Usage** answers "what have I actually spent or done" --
every metric belongs under exactly one of the two (see `MetricLine.category`), so nothing shows
up mixed together on the same card the way it used to.

A dismissible banner the first time providers are found ("Found N providers on this Mac") points
at Customize; it's gone for good once dismissed, on this Mac or any other install sharing the
same config. The footer shows the installed version and a live "Next update in Xs" countdown to
the next background refresh (click it to refresh immediately); the ⋯ menu on the right opens
Customize or Settings, shares a screenshot of any visible provider, opens the standard About
panel, or quits.

## Limits tab

Every enabled provider's quota bars stacked in one scrollable list (in whatever order Customize
has them in, drag any provider's header to reorder right there), instead of a one-at-a-time
picker. Provider logos are real, from [Lobe Icons](https://github.com/lobehub/lobe-icons) -- see
[Sources/TokenWatch/Icons/NOTICE.md](Sources/TokenWatch/Icons/NOTICE.md) for license and
per-icon sourcing.

A metric with a reset window is colored by burn-rate pace, not raw percentage: blue means
current usage is on course to finish with room to spare, amber means it's projected to land
close to the limit, red means it's projected to run out before the window resets (or is already
there). An elapsed-time tick mark on the bar marks how far through the window "now" is, so you
can see at a glance whether the fill is ahead of or behind that mark. The headline ("34% used")
and the reset label ("Resets in 3h") are both click-to-flip -- click the headline to switch
every metric to "% left" instead of "% used," click a reset label to switch every metric between
a countdown and an exact clock time. Right-click any row for Star for menu bar / Hide / Refresh
/ Customize; right-click a provider's header for the same, plus **Share Screenshot** (renders
that card to a PNG and copies it to the clipboard) and hiding the whole provider. A provider
whose last successful fetch is more than two refresh cycles old gets a quiet "Outdated" tag next
to its name.

Any additional locally discovered account (Claude, Codex only, via a second
`CLAUDE_CONFIG_DIR`/`CODEX_HOME` profile -- see `ClaudeAccountDiscovery`/`CodexAccountDiscovery`)
shows as its own card below the main list -- quota bars only, the same read-only visibility the
old separate Usage-tab account list used to provide, just filed under Limits now since that's
what it's showing. Discovery is file-based only: it finds a profile whose login wrote its own
`.credentials.json`/`auth.json`, not one that only ever reached the macOS Keychain under a
profile-specific service name. A found-but-lapsed credential shows why (self-heals on next CLI
run, or needs a real re-login) rather than a raw HTTP error. This is read-only visibility, not
account switching -- TokenWatch doesn't change which login your `claude`/`codex` CLI actually
uses. Spend history on the Usage tab reads every account's local logs the same way, whether or
not it has a card here.

## Usage tab

Spend, cache activity, and cost history -- never a quota bar, those are all on Limits. Only a
provider with something to actually show here gets a card; most providers have none today (see
`MetricLine.category`).

A cross-provider **Total Spend** card sits at the top when Settings' **Show Total Spend** is on
and anything on this Mac has local activity in the last 7 days, via a 30-day scan shared with the
per-provider spend rows below it (one scan, cached). It totals every source with history --
Claude and Codex from their CLIs, every other coding agent's local logs (below), Cursor's account
usage, a named slice each for Devin, fx and Muse Code (which bill through their own services), and
**Other** for model providers TokenWatch has no card for -- whether or not that provider's
card is enabled: it's what was spent, not just what's tracked. The title is a
pull-down for **Cost** / **Cost per MTok** / **Tokens**; a **Today** / **Yesterday** / **30 Days**
segmented toggle sits alongside it. The donut's segments use each provider's real brand color
(Anthropic's terracotta, OpenAI's teal-green, and so on); hover the center for the exact figure
instead of the rounded one; hover a provider's legend row for a ranked per-model spend breakdown
(name, cost, share, tokens). A period with no usage says so instead of drawing an empty donut.
Under it, in the same card, the last 7 days as bars in the same mode -- stacked by provider for
Cost and Tokens, one combined bar per day for Cost per MTok (rates don't stack) -- with the days
the selected period covers at full strength and the rest dimmed. The share icon copies a PNG of
the whole card to your clipboard, and the ⓘ names which providers feed the total.

Any provider with local spend history in the last two days shows a **Today/Yesterday** line
directly on its own card, chevron-collapsible to that provider's own per-model breakdown -- the
same figures as the Total Spend card's hover popover, without needing to open it.

Claude's and Codex's cards also list a compact row per locally active session (touched within
the last 5 hours) -- a flame or snowflake, the project name, and a hit-ratio detail -- not just
the newest session. Claude's detail includes a precise expiry (`expires HH:mm`): Anthropic's cache
TTL is client-visible, and both Claude Code and `omp` log which TTL (5 minutes or 1 hour) each
turn's cache writes used, so the expiry follows each session's own TTL -- falling back to 5
minutes only for a log that doesn't record it. Codex's detail does not, since OpenAI's cache
retention is server-side, org-dependent, and machine-local, so it only reports whether the last
turn itself was a cache hit.

Local activity also picks up sessions run through a coding-agent harness that talks to the model
APIs directly rather than shelling out to the `claude` or `codex` CLI -- `omp` (the CLI behind
[Superset](https://superset.sh), `~/.omp/agent/sessions`) and `pi`, which omp is a fork of
(`~/.pi/agent/sessions`, or `PI_CODING_AGENT_SESSION_DIR` / `PI_CODING_AGENT_DIR/sessions`).
Without this, usage through such a harness would be completely invisible to the session lists
and spend even though it's real usage. One harness session can switch providers turn to turn, and
each turn counts toward the provider that served it: Anthropic turns as Claude, `openai-codex`
turns (a ChatGPT sign-in, the Codex quota) as Codex, and OpenRouter, OpenAI, Gemini, xAI, z.ai,
Kimi, Copilot, Cursor, OpenCode and Amp turns as their own providers' spend; anything else is
Other.

Spend also reads the other coding agents' own local usage records, each attributed to the service
it's billed through:

| Agent | Where | Counts toward |
| --- | --- | --- |
| OpenCode | `~/.local/share/opencode/opencode.db` (or the pre-database `storage/` tree) | The provider that served each message, like omp; `openai` is Codex when OpenCode's `auth.json` holds a ChatGPT sign-in |
| GitHub Copilot CLI | `~/.copilot/session-store.db` | Copilot |
| Grok CLI | `~/.grok/logs/unified.jsonl` (and `$GROK_HOME`) | Grok |
| Antigravity CLI | `~/.gemini/antigravity-cli/brain/*/…/transcript_full.jsonl` | Antigravity |
| Devin CLI | `~/.local/share/devin/cli/sessions.db` | Devin (its own slice) |
| fx | `~/.fx/sessions/*/events.jsonl` | fx (its own slice) |
| Muse Code | `~/.local/share/muse/sessions/**/session.jsonl` | Muse Code (its own slice) |

(`~/.local/share` follows `XDG_DATA_HOME`.) Databases are opened read-only while the agent may be
using them. None of these formats is a public contract the way Claude Code's and Codex's are, so
each is read defensively and fails soft if the format ever changes.

Cursor keeps no token counts on disk, so while the Cursor provider is enabled its spend comes from
Cursor's own per-request usage history for the account (the dashboard's usage-events call, with
Cursor.app's saved sign-in, fetched at most every 5 minutes) -- covering the app, `cursor-agent`,
and any other client signed into it, omp's `cursor` provider included, so it replaces any locally
logged Cursor turns rather than adding to them.

Every spend figure -- the donut, the 7-day bars, each provider's spend row -- is built by summing
*every* turn's local session tokens (not just the newest, the way cache-temperature works) and
pricing them at API list rates -- no Admin API key required. A day's token total is input + cache
reads + cache writes + output.

- **Claude** (Claude Code logs in every Claude config dir on this Mac -- `~/.claude`,
  `~/.config/claude`, each `CLAUDE_CONFIG_DIR` entry, and any other account profile holding
  Claude's own `.claude.json` or `.credentials.json`, a folder shared through a symlink counted
  once -- plus Anthropic turns from omp, pi and OpenCode): each Claude Code API response counts once,
  deduplicated the way OpenUsage and ccusage do it -- Claude Code writes one line per content
  block of a response, each repeating the full usage, and subagent (sidechain) and
  resumed-session logs replay earlier messages. A cost the log itself records (Claude Code's
  `costUSD`, another agent's per-turn cost) is used as-is; otherwise tokens are priced at list rates,
  with 1-hour cache writes at 2x input and 5-minute ones at 1.25x. A dotted version
  (`claude-haiku-4.5`, as OpenRouter and harnesses spell it) prices as Anthropic's dashed id,
  and `<synthetic>` (locally generated) messages cost nothing.
- **Codex** (`sessions` and `archived_sessions` in `$CODEX_HOME` and every other `~/.codex*`
  home, plus omp/pi's `openai-codex` turns and OpenCode's ChatGPT-sign-in turns at the agent's
  own recorded cost), ported from
  OpenUsage's Codex scanner: a turn is a `token_count` event's `last_token_usage` (or its delta
  from the previous running total); a re-emitted, unchanged running total isn't a new turn; a
  subagent or forked session's replay of its parent's history isn't counted; and an identical
  event in two files counts once. Cached input bills at the cache-read rate and cache writes
  (also counted inside Codex's input) at 1.25x input, a request above 272K input tokens at the
  model's long-context rate, and a priority ("fast") tier session at 2x (2.5x for gpt-5.5).
- **Every other agent and provider** at the agent's own recorded cost (omp, pi, OpenCode, fx, Muse
  Code; Cursor's token-rate cost), or, when there is none, at the list rate of whichever known
  model family (Claude, OpenAI, Grok, Gemini) matches the model id. Each agent's token buckets
  are normalized to input / cache reads / cache writes / output -- OpenCode's reasoning tokens,
  which it logs apart from output, count as output, and so do Gemini's thinking tokens.

All of it shares one 30-day history with the Total Spend card and each provider's inline spend
row. While TokenWatch is running, a local filesystem watcher updates these figures as Claude
Code, Codex, omp, and pi write usage records, even with the popover closed. Changes are coalesced
for 300 ms after macOS delivers them; OS scheduling and scan time can add latency. Native
Claude/Codex and harness JSONL records are read incrementally; other agent files and databases
retain their format-specific caches and periodic refreshes. This is live **logged usage**, not token-by-token streaming:
figures cannot update before the agent writes its usage.
Native Claude and Codex changes refresh only their own provider, covering discovered account
histories as well as default/configured roots. Shared omp/pi changes reconcile every billed
source, including Other. Changes arriving during a scan are unioned into a follow-up scan;
full reconciliation requests take precedence, and untouched source histories are preserved.

The Total Spend card's **Recent local usage** rows show each provider as **Active** for 8 seconds
after observing increased usage with a newer, recent record timestamp, then **Idle**. Startup,
counter resets, and old imported records do not create a live sample. This is recent logged
activity, not a claim that a model is currently streaming.

When a new sample has trustworthy timing, its **output tok/s** is the newly recorded timed output
divided by its matching response duration. This uses verified request-duration metadata from
omp-format harness responses; those durations include first-token wait and request overhead,
so the number is response throughput, not pure decoding speed. Native Claude Code and Codex CLI records remain
untimed: their activity still updates, but the app does not invent a rate from refresh intervals
or tool-inclusive turn durations. An idle timed sample is labeled **Last** and expires after
3 minutes; a new untimed sample clears the old rate. Status transitions use scheduled expiries,
not a continuously running animation.


Provider quota/limit APIs still use the configured refresh interval. Provider refreshes and
opening the popover after a minute also reconcile all local history as a fallback if filesystem
notifications are unavailable. Cursor account history keeps its five-minute fetch throttle and
is never fetched because of a local log event. The estimate is explicitly
labeled as one: subscription usage isn't billed per token. Rates come from a small static table
refreshed against LiteLLM's public, community-maintained price list roughly hourly
(`PricingRefreshService`) -- a fetch failure or not having fetched yet falls straight through to
the static table, so cost estimates work offline and on first launch too.

## Customize

Open from a card's right-click menu, or the ⋯ menu in the footer: a provider list (on/off, drag
to reorder) and, per provider, an **Always Visible** / **On Demand** split -- drag a metric
between them to tuck it behind that provider's expand caret, or star it (up to two per provider)
to pin it to the menu bar. **Reset** (in the shared top bar) restores one provider's defaults
while its detail is open; **Reset All** restores every provider's order and metrics from the
provider list. A dismissible tip at the top explains drag-to-reorder and starring the first time
it's opened.

## Keyboard shortcuts

| Key | Action |
| --- | --- |
| Return | Open Customize from the dashboard; on Customize's provider detail, go back to the list |
| Esc | Go back one level (Customize detail → list → dashboard; Settings → dashboard); closes the popover if already on the dashboard |
| ⌘Z | Undo the last customization change (hide/show, reorder, star, tier move), app-wide |
| ⌘R | Refresh now |
| ⌘, | Toggle Settings |

A global shortcut (recorded in Settings → General) also toggles the popover from anywhere, via
the Carbon Event Manager -- no external dependency and no Input Monitoring permission needed
(unlike `NSEvent`'s global key monitor).


## Settings

- **General** -- Show Total Spend, Launch at Login ([`SMAppService`](https://developer.apple.com/documentation/servicemanagement/smappservice), the modern login-item API), the global shortcut recorder.
- **Menu Bar** -- Icon Style (Text, or a compact **Bars** glyph of up to four starred bounded
  metrics), plus the independent session-limit/pinned-metrics, input, output, and cache checklist.
- **Appearance** -- Theme (System/Light/Dark), Density (Default/Compact), Time Format
  (Auto/12-hour/24-hour) for exact reset times, Reduce Animations, Increase Transparency
  (auto-disabled while macOS's own Reduce Transparency accessibility setting is on), Hide From
  Screen Share (excludes the popover from screen recordings/screen sharing).
- **Notifications** -- three independent, default-off pace-crossing alerts: **Almost Out**
  (under 10% remaining), **Cutting It Close** (projected to land close to the limit),
  **Will Run Out** (projected to run out before reset). Deduplicated so a refresh loop doesn't
  repeat the same alert: a metric already in a bad state when the app launches establishes a
  silent baseline, then only a new crossing or a worsening trigger fires again. macOS asks for
  notification permission the first time you turn one on; if you decline, Settings shows a
  warning with a link to System Settings.
- **Leaderboard** -- off by default: Join with GitHub, then status, Preview Upload, Pause Syncing,
  Resync All History, Sign Out and Delete Account. See [Leaderboard (optional)](#leaderboard-optional).
- **Refresh interval**, **Providers** -- unchanged.

## Leaderboard (optional)

[tokenwat.ch](https://tokenwat.ch) ranks daily token usage and API-equivalent spend across
TokenWatch users. It's off by default, and until you join nothing about it runs: no request to
tokenwat.ch, no Keychain read, and no prompt or banner anywhere in the app.

- **Join** -- Settings → Leaderboard → **Join with GitHub**. tokenwat.ch's consent page opens in
  a sign-in sheet (`ASWebAuthenticationSession`, reusing your browser's GitHub session). Approve,
  and this Mac gets its own device token, stored in the Keychain under `dev.tokenwatch.credentials`
  / `leaderboard.deviceToken`. GitHub's own token never reaches the app.
- **What's uploaded** -- per local day, source (`claude`, `codex`, ..., `service.devin`, `other`)
  and model: input, cache-read, cache-write and output tokens, the estimated cost, and whether
  that cost used a fallback rate. These are the Usage tab's own numbers: first the 30 days it
  shows, then every older day the same local logs still hold, newest month first; after that,
  changes to today and the two days before, at most every 15 minutes (the server sets the pace),
  plus an hourly check-in. **Preview Upload** shows the exact JSON of the next upload. Never
  uploaded: prompts, code, project or folder names, file paths, API keys. This version sends no
  plan or quota data. The full field list is in [SECURITY.md](SECURITY.md).
- **What's public** -- everything uploaded, on your profile at `tokenwat.ch/@<GitHub login>` and
  on the boards. On [tokenwat.ch/account](https://tokenwat.ch/account) you can hide individual
  stats (tokens, cost, providers, models, ...) from your profile and the boards that rank on them.
- **Pause** -- **Pause Syncing** stops all uploads and check-ins until you resume. Pausing on
  tokenwat.ch instead keeps the app sending while the server stores nothing; Settings then says
  "Paused on tokenwat.ch".
- **Leave** -- **Sign Out** revokes this Mac on the server and deletes its token; what you
  uploaded stays on your profile until you delete it. **Delete Account…** opens
  tokenwat.ch/account, where you can delete your account and everything uploaded.

If the server rejects this Mac's token, TokenWatch signs out locally and says "Disconnected, sign
in again". If it stops accepting this version's uploads, syncing stops with "Update TokenWatch to
keep syncing".

## Build & run

Requires Xcode 26+ / Swift 6.2 toolchain on macOS 26 (Tahoe)+ -- the popover's background uses
real Liquid Glass (`glassEffect`), which needs the macOS 26 SDK.

```sh
swift build
swift run TokenWatch
```

Enable providers and add API keys from Settings, opened via the ⋯ menu in the popover's footer.
Configuration lives at `~/Library/Application Support/TokenWatch/config.json`; API keys are
stored in the macOS Keychain under the service `dev.tokenwatch.credentials`, and cached derived
sessions (e.g. Cursor's Safari-cookie fallback) under `dev.tokenwatch.cookiecache`.

To try the leaderboard against a local stack (tokenwatch-cloud's web app on :3000 and API on
:8787), a DEBUG build reads two overrides; release builds ignore them:

```sh
TOKENWATCH_WEB_URL=http://localhost:3000 TOKENWATCH_API_URL=http://localhost:8787 swift run TokenWatch
```

## Tests

```sh
swift test
```

Each provider has a mapper fixture test: sample JSON in, expected metric lines out. The
leaderboard's payload and sign-in tests check against the server's own contract:
`Tests/TokenWatchCoreTests/Contracts/` is a copy of tokenwatch-cloud's `packages/contracts` build
output (`pnpm --filter @tokenwatch/contracts build`, then copy its `schema/` and `fixtures/`).

## Privacy & security

Every credential TokenWatch reads goes to that same provider's own official usage API over
HTTPS, and nowhere else. Beyond those, it makes two kinds of request. The optional pricing
refresh (`PricingRefreshService`) is a plain, unauthenticated GET of a public GitHub-hosted price
list, roughly hourly, carrying no usage data or credentials -- it only ever sends a request for
the file, nothing about you or your usage. And only if you join the
[leaderboard](#leaderboard-optional), it sends daily token counts and estimated cost per
provider and model to `api.tokenwat.ch`. Notifications use Apple's local
`UNUserNotificationCenter` directly -- nothing about a quota alert leaves your Mac. No telemetry
or analytics. Nothing leaves your Mac unless you join the leaderboard. Full detail on what's
read, what's sent, why, and how to report a security issue: [SECURITY.md](SECURITY.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for project layout, how to add a provider, and code style.

## Scope

This is a from-scratch, clean-room build. It implements one reliable auth path and the primary
usage metric(s) per provider, plus read-only multi-account visibility for Claude/Codex and a
local cost history for Claude and Codex (see Usage tab, above) -- not every edge case (account *switching*,
team budgets, enterprise hosts) that larger, multi-year usage trackers eventually grow. See
inline doc comments on each provider for the specific scope cuts. Zero external SwiftPM
dependencies and zero telemetry are firm project principles -- the leaderboard is opt-in and
uploads only what Preview Upload shows, and an in-app auto-updater and any analytics SDK are
deliberately not implemented, even though comparable menu-bar usage trackers ship both; see
[DISTRIBUTION.md](DISTRIBUTION.md) for how updates work instead.

Distributed as a signed, notarized DMG and a Homebrew cask (see
[DISTRIBUTION.md](DISTRIBUTION.md)); in-app auto-update is not implemented yet, and the cask sets
`auto_updates false` so Homebrew won't silently upgrade it either -- update by running
`brew update && brew upgrade --cask tokenwatch` (Homebrew installs) or re-downloading the
[latest release](https://github.com/MetaPouch/tokenwatch/releases/latest) DMG and dragging it
over the old app (manual installs).
