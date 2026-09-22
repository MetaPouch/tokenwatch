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

If a provider has a recent local-activity signal (currently: Claude and Codex, from local
session transcripts, refreshed within the last 24h), the status item shows that provider's name,
its current session percent (never weekly, even if weekly happens to be higher -- session is the
actionable number moment-to-moment), and a progress ring colored green (<70%), amber (70-90%),
or red (>90%). When the provider's prompt cache has local data for that session, the ring is
tinted green (warm -- a follow-up message stays cheap) or blue (cold -- the next message
re-reads the full context at full price) instead of the usual threshold color. That cache read
reflects exactly one local session -- whichever one you touched most recently, which matters if
you run several sessions in parallel. Hover the status item, or check the badge line in the
dashboard, to see which project it's describing and when. Otherwise it falls back to whichever
enabled provider's metric is closest to its limit (highest used/limit ratio), same coloring.

## Dashboard

Click the status item to open the dashboard: a provider picker (each provider's real logo, from
[Lobe Icons](https://github.com/lobehub/lobe-icons) -- see
[Sources/TokenWatch/Icons/NOTICE.md](Sources/TokenWatch/Icons/NOTICE.md) for license and
per-icon sourcing) above a detail view for whichever one is selected. It opens on the provider
the status item was just showing -- switch with the dropdown. Every progress bar is colored green
under 70% used, amber 70-90%, red above, so a card's own numbers tell you what needs attention
without reading every line. Claude's and Codex's detail views each list a compact row per
locally active session (touched within the last 5 hours) -- a flame or snowflake, the project
name, and a hit-ratio detail -- not just the newest session. Claude's detail includes a precise
expiry (`expires HH:mm`), since Anthropic's cache TTL is fixed and client-visible; Codex's does
not, since OpenAI's cache retention is server-side, org-dependent, and machine-local, so it only
reports whether the last turn itself was a cache hit. Every other provider shows its usual
session/weekly percent, credit balance, and spend lines.

Claude's local activity also picks up sessions run through a coding-agent harness that talks to
Anthropic's API directly rather than shelling out to the `claude` CLI (currently: `omp`, the CLI
behind [Superset](https://superset.sh)) -- without this, usage through such a harness would be
completely invisible to the local session list even though it's real Claude usage. This depends
on that harness's own undocumented local session-log format, not a stable public contract the
way Claude Code's and Codex's are, so it's read defensively and fails soft if the format ever
changes.

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
  API," using a pricing table that goes stale as vendors change prices (the table's last-updated
  date is shown next to the chart).

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
HTTPS, and nowhere else — no telemetry, no analytics, no server we operate. Full detail on what's
read, why, and how to report a security issue: [SECURITY.md](SECURITY.md).

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
