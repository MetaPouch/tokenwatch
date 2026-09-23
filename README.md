# TokenWatch

[tokenwatch.fyi](https://tokenwatch.fyi)

A native macOS menu-bar app that shows session/weekly usage, limits, credit balances, and spend
for the AI subscriptions, routing providers, and API keys you actually use — in one place, with
nothing relayed off your device.

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

Single account per provider on the menu bar and the Limits tab. The Limits tab additionally
discovers and shows every local Claude/Codex login it can find, not just the default one.
Everything runs locally: no telemetry, no data leaves your device.

## Menu bar behavior

On the very first launch, before anything is configured, TokenWatch opens the dashboard once on
its own -- the status item alone (a plain ring, nothing to show yet) is easy to miss the very
first time. It goes straight to "No providers enabled -- Open Settings." Every later launch
leaves discovery to the status item.

By default (nothing starred yet) the status item shows a smart summary: whichever enabled
provider has a recent local-activity signal (currently: Claude and Codex, from local session
transcripts, refreshed within the last 24h) shows its name, its current session percent (never
weekly, even if weekly happens to be higher), and a progress ring. Ring/cache-badge coloring is
unchanged from before. Otherwise it falls back to whichever enabled provider's metric is closest
to its limit (highest used/limit ratio).

Star a metric from its right-click menu (or from Customize) to pin it instead -- once anything
is starred, the status item switches to showing exactly those pinned metrics, one segment per
provider with real data, up to two metrics per provider. A provider whose stars have no data
yet drops out of the strip entirely rather than showing a placeholder.

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
uses.

## Usage tab

Spend, cache activity, and cost history -- never a quota bar, those are all on Limits. Only a
provider with something to actually show here gets a card; most providers have none today (see
`MetricLine.category`).

A cross-provider **Total Spend** card sits at the top when Settings' **Show Total Spend** is on
and at least one enabled provider has local spend data (Claude and Codex, via a 30-day scan shared
with the per-provider spend row below it and the cost history chart at the bottom -- one scan,
cached, not three). The title is a pull-down for **Cost** / **Cost per MTok** / **Tokens**; a
**Today** / **Yesterday** / **30 Days** segmented toggle sits alongside it. The donut's segments
use each provider's real brand color (Anthropic's terracotta, OpenAI's teal-green, and so on);
hover the center for the exact figure instead of the rounded one; hover a provider's legend row
for a ranked per-model spend breakdown (name, cost, share, tokens); the share icon copies a PNG
of the card to your clipboard, and the ⓘ names which providers feed the total.

Any provider with its own local spend history (Claude and Codex) shows a **Today/Yesterday** line
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

Claude's local activity also picks up sessions run through a coding-agent harness that talks to
Anthropic's API directly rather than shelling out to the `claude` CLI (currently: `omp`, the CLI
behind [Superset](https://superset.sh)) -- without this, usage through such a harness would be
completely invisible to the local session list even though it's real Claude usage. This depends
on that harness's own undocumented local session-log format, not a stable public contract the
way Claude Code's and Codex's are, so it's read defensively and fails soft if the format ever
changes.

A daily Cost/Tokens bar chart for the last 7 days sits at the bottom, one bar per day stacked by
provider in brand colors, built by summing *every* turn's local session tokens (not just the
newest, the way cache-temperature works) and pricing them at API list rates -- no Admin API key
required. A day's token total is input + cache reads + cache writes + output.

- **Claude** (Claude Code and `omp` logs): each Claude Code API response counts once,
  deduplicated the way OpenUsage and ccusage do it -- Claude Code writes one line per content
  block of a response, each repeating the full usage, and subagent (sidechain) and
  resumed-session logs replay earlier messages. A cost the log itself records (Claude Code's
  `costUSD`, `omp`'s per-turn cost) is used as-is; otherwise tokens are priced at list rates, with
  1-hour cache writes at 2x input and 5-minute ones at 1.25x. `<synthetic>` (locally generated)
  messages cost nothing.
- **Codex** (`$CODEX_HOME/sessions` and `archived_sessions`), ported from OpenUsage's Codex
  scanner: a turn is a `token_count` event's `last_token_usage` (or its delta from the previous
  running total); a re-emitted, unchanged running total isn't a new turn; a subagent or forked
  session's replay of its parent's history isn't counted; and an identical event in two files
  counts once. Cached input bills at the cache-read rate, a request above 272K input tokens at the
  model's long-context rate, and a priority ("fast") tier session at 2x (2.5x for gpt-5.5).

All of it shares one 30-day scan with the Total Spend card and each provider's inline spend row,
rescanned when the Usage tab is opened more than a minute after the last scan -- instant after
the first load, and still current while the app keeps running. The estimate is explicitly
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
- **Appearance** -- menu-bar Icon Style (Text, or a compact **Bars** glyph of up to four starred
  bounded metrics' fill fractions), Theme (System/Light/Dark), Density (Default/Compact), Time
  Format (Auto/12-hour/24-hour) for exact reset times, Reduce Animations, Increase Transparency
  (auto-disabled while macOS's own Reduce Transparency accessibility setting is on), Hide From
  Screen Share (excludes the popover from screen recordings/screen sharing).
- **Notifications** -- three independent, default-off pace-crossing alerts: **Almost Out**
  (under 10% remaining), **Cutting It Close** (projected to land close to the limit),
  **Will Run Out** (projected to run out before reset). Deduplicated so a refresh loop doesn't
  repeat the same alert: a metric already in a bad state when the app launches establishes a
  silent baseline, then only a new crossing or a worsening trigger fires again. macOS asks for
  notification permission the first time you turn one on; if you decline, Settings shows a
  warning with a link to System Settings.
- **Refresh interval**, **Providers** -- unchanged.

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

## Tests

```sh
swift test
```

Each provider has a mapper fixture test: sample JSON in, expected metric lines out.

## Privacy & security

Every credential TokenWatch reads goes to that same provider's own official usage API over
HTTPS, and nowhere else. The one exception is the optional pricing refresh
(`PricingRefreshService`): a plain, unauthenticated GET of a public GitHub-hosted price list,
roughly hourly, carrying no usage data or credentials -- it only ever sends a request for the
file, nothing about you or your usage. Notifications use Apple's local `UNUserNotificationCenter`
directly -- nothing about a quota alert leaves your Mac. No telemetry, no analytics, no server we
operate. Full detail on what's read, why, and how to report a security issue: [SECURITY.md](SECURITY.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for project layout, how to add a provider, and code style.

## Scope

This is a from-scratch, clean-room build. It implements one reliable auth path and the primary
usage metric(s) per provider, plus read-only multi-account visibility for Claude/Codex and a
local cost history for Claude and Codex (see Usage tab, above) -- not every edge case (account *switching*,
team budgets, enterprise hosts) that larger, multi-year usage trackers eventually grow. See
inline doc comments on each provider for the specific scope cuts. Zero external SwiftPM
dependencies and zero telemetry are firm project principles -- an in-app auto-updater and any
analytics SDK are deliberately not implemented, even though comparable menu-bar usage trackers
ship both; see [DISTRIBUTION.md](DISTRIBUTION.md) for how updates work instead.

Distributed as a signed, notarized DMG and a Homebrew cask (see
[DISTRIBUTION.md](DISTRIBUTION.md)); in-app auto-update is not implemented yet, and the cask sets
`auto_updates false` so Homebrew won't silently upgrade it either -- update by running
`brew update && brew upgrade --cask tokenwatch` (Homebrew installs) or re-downloading the
[latest release](https://github.com/MetaPouch/tokenwatch/releases/latest) DMG and dragging it
over the old app (manual installs).
