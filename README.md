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

Single account per provider on the menu bar and per-provider dashboard tab. The Usage tab (below)
additionally discovers and shows every local Claude/Codex login it can find, not just the
default one. Everything runs locally: no telemetry, no data leaves your device.

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

Click the status item to open the dashboard: every enabled provider stacked in one scrollable
list (in whatever order Customize has them in), instead of a one-at-a-time picker. Provider
logos are real, from [Lobe Icons](https://github.com/lobehub/lobe-icons) -- see
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
/ Customize; right-click a provider's header for the same, plus hiding the whole provider. A
provider whose last successful fetch is more than two refresh cycles old gets a quiet "Outdated"
tag next to its name.

A cross-provider **Total Spend** card sits above the list when at least one enabled provider has
local spend data (today: Claude, via the 30-day scan below) -- a small donut with a
Today/Yesterday/30 Days toggle and a per-provider legend.

Claude's and Codex's cards also list a compact row per locally active session (touched within
the last 5 hours) -- a flame or snowflake, the project name, and a hit-ratio detail -- not just
the newest session. Claude's detail includes a precise expiry (`expires HH:mm`), since
Anthropic's cache TTL is fixed and client-visible; Codex's does not, since OpenAI's cache
retention is server-side, org-dependent, and machine-local, so it only reports whether the last
turn itself was a cache hit.

Claude's local activity also picks up sessions run through a coding-agent harness that talks to
Anthropic's API directly rather than shelling out to the `claude` CLI (currently: `omp`, the CLI
behind [Superset](https://superset.sh)) -- without this, usage through such a harness would be
completely invisible to the local session list even though it's real Claude usage. This depends
on that harness's own undocumented local session-log format, not a stable public contract the
way Claude Code's and Codex's are, so it's read defensively and fails soft if the format ever
changes.

## Customize

Open from a card's right-click menu, or the gear icon: a provider list (on/off, drag to
reorder) and, per provider, an **Always Visible** / **On Demand** split -- drag a metric between
them to tuck it behind that provider's expand caret, or star it (up to two per provider) to pin
it to the menu bar. **Reset** restores one provider's defaults; **Reset All** restores every
provider's order and metrics.

## Usage tab

A second tab in the dashboard (next to the per-provider one), switched via the segmented control
at the top: a consolidated list of quota meters across every locally discovered account for
every enabled provider, instead of one provider at a time.

- **Default accounts.** Whatever each provider's own dashboard tab already tracks, shown as a
  card per provider -- no extra network call, it reuses the same poll.
- **Additional accounts (Claude, Codex only).** A second (or third...) local login under a
  different `CLAUDE_CONFIG_DIR`/`CODEX_HOME` profile directory shows as its own card, fetched
  fresh when the tab appears. Discovery is file-based only: it finds a profile whose login wrote
  its own `.credentials.json`/`auth.json`, not one that only ever reached the macOS Keychain
  under a profile-specific service name. A found-but-lapsed credential shows why (self-heals on
  next CLI run, or needs a real re-login) rather than a raw HTTP error. This is read-only
  visibility, not account switching -- TokenWatch doesn't change which login your `claude`/`codex`
  CLI actually uses.
- **Cost history (Claude only, last 7 days).** A daily bar chart -- toggle Cost/Tokens -- built
  by summing *every* turn's token usage (not just the newest, the way cache-temperature works)
  across local Claude session logs, both the real `claude` CLI's transcripts and a coding-agent
  harness's own (see above), and pricing them at API list rates. This can take several real
  seconds on a machine with a long session history, so it always runs off the main thread and
  shows its own loading state rather than blocking the tab. The estimate is explicitly labeled as
  one: subscription usage isn't billed per token, this is "what the same work would cost on the
  API." Rates come from a small static table refreshed against LiteLLM's public,
  community-maintained price list roughly hourly (`PricingRefreshService`) -- a fetch failure or
  not having fetched yet falls straight through to the static table, so cost estimates work
  offline and on first launch too.

## Build & run

Requires Xcode 15+ / Swift 5.10 toolchain on macOS 14+.

```sh
swift build
swift run TokenWatch
```

Enable providers and add API keys from the gear icon in the dashboard popover. Configuration
lives at `~/Library/Application Support/TokenWatch/config.json`; API keys are stored in the macOS
Keychain under the service `dev.tokenwatch.credentials`, and cached derived sessions (e.g. Cursor's
Safari-cookie fallback) under `dev.tokenwatch.cookiecache`.

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
file, nothing about you or your usage. No telemetry, no analytics, no server we operate. Full
detail on what's read, why, and how to report a security issue: [SECURITY.md](SECURITY.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for project layout, how to add a provider, and code style.

## Scope

This is a from-scratch, clean-room build. It implements one reliable auth path and the primary
usage metric(s) per provider, plus read-only multi-account visibility for Claude/Codex and a
Claude-only cost history (see Usage tab, above) -- not every edge case (account *switching*,
team budgets, enterprise hosts) that larger, multi-year usage trackers eventually grow. See
inline doc comments on each provider for the specific scope cuts.

Distributed as a signed, notarized DMG and a Homebrew cask (see
[DISTRIBUTION.md](DISTRIBUTION.md)); in-app auto-update is not implemented yet, and the cask sets
`auto_updates false` so Homebrew won't silently upgrade it either -- update by running
`brew update && brew upgrade --cask tokenwatch` (Homebrew installs) or re-downloading the
[latest release](https://github.com/MetaPouch/tokenwatch/releases/latest) DMG and dragging it
over the old app (manual installs).
