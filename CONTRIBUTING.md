# Contributing to TokenWatch

## Getting set up

```sh
git clone https://github.com/ajays97/tokenwatch.git
cd tokenwatch
swift build
swift test
swift run TokenWatch
```

Requires Xcode 15+ / Swift 5.10 toolchain on macOS 14+. No external dependencies to install —
`Package.swift` has none.

## Project layout

- `Sources/TokenWatchCore/` — the provider pipeline (auth store → usage client → mapper →
  `ProviderSnapshot`), stores, and shared services. No AppKit/SwiftUI here.
- `Sources/TokenWatch/` — the menu-bar shell: status item, dashboard popover, settings.
- `Tests/TokenWatchCoreTests/` — one mapper fixture test per provider (sample JSON in, expected
  `MetricLine`s out), plus tests for the shared models and services.
- `docs/` — the tokenwatch.fyi landing page (published via GitHub Pages).
- `scripts/` — build, packaging, notarization, and release automation (see
  [DISTRIBUTION.md](DISTRIBUTION.md)).

## Adding a provider

Each provider lives in `Sources/TokenWatchCore/Providers/<Name>/` with four files:

1. `<Name>AuthStore.swift` — resolves credentials (Keychain, OAuth file, or a plain API key via
   the shared `APIKeyAuthStore`).
2. `<Name>UsageClient.swift` — the HTTP calls and response DTOs (`Decodable` structs matching the
   provider's actual API shape).
3. `<Name>Mapper.swift` — a pure function from the DTO to `[MetricLine]`. This is what gets unit
   tested.
4. `<Name>Provider.swift` — implements `ProviderRuntime`, wiring the three above together with
   `do`/`catch` around every network/parse call. **Never force-unwrap a response** — a
   provider's `refresh()` must return `.error(...)` on any failure, never throw or crash.

Register the new runtime in `Sources/TokenWatch/App/AppContainer.swift`'s `buildRuntimes()`, and
add it to `buildAPIKeyManagers()` too if it's key-based.

Write one test file per provider under `Tests/TokenWatchCoreTests/<Name>MapperTests.swift`,
feeding a captured (or hand-built, matching the real API's documented shape) sample response
through the mapper and asserting the resulting `MetricLine`s. If you have a real account with the
provider, a quick live run (`swift run TokenWatch` with it enabled) comparing the displayed
numbers against the provider's own dashboard is the best proof a new provider actually works.

## Code style

- No third-party dependencies. If a task seems to need one, it probably means the task is bigger
  than a single provider addition — open an issue to discuss first.
- Every provider's UI comes from the generic `ProviderCardView` renderer over the five
  `MetricLine` cases (`progress`, `values`, `badge`, `chart`, `text`). Don't add bespoke SwiftUI
  per provider.
- Match existing patterns in a neighboring provider before introducing a new one.
- Run `swift test` before opening a PR. There's no linter/formatter configured; keep changes
  consistent with the surrounding code.

## Reporting bugs vs. security issues

Regular bugs: open a GitHub issue. Anything involving a credential leak, an injection vector, or
similar: see [SECURITY.md](SECURITY.md) instead — please don't file those publicly.
