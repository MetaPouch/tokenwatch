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
- Never phones home. There is no telemetry, no analytics SDK, no crash reporter, no update-check
  ping, no server TokenWatch's authors operate. You can verify this directly: every outbound host
  is a literal string in the relevant `*UsageClient.swift` file (per-provider) or
  `PricingRefreshService.swift` (the one exception below), and `git grep -n 'URL(string:'` finds
  all of them.
- The one non-credential network call: `PricingRefreshService` does a plain, unauthenticated GET
  of a public GitHub-hosted model-price list roughly hourly, to keep local cost estimates current.
  This request carries no credential, no usage data, and no identifying information -- it's
  indistinguishable from any other visitor fetching that public file. A fetch failure falls
  straight through to a bundled static table, so it's never a hard dependency.
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
  Security, SQLite3).
- Every subprocess invocation (`Process`, in `BoundedSubprocess.swift` and
  `CodexAppServerClient.swift`) uses an argument array against a resolved executable path — never
  a shell string, so there's no command-injection surface from provider CLI output or PATH
  contents.
- `SafariCookieReader.swift` parses an externally-formatted binary file (Safari's cookie jar) with
  explicit bounds checks on every offset read from the file, since that file's structure isn't
  Apple-documented and its contents aren't fully trusted input.
- Distribution builds are signed with a Developer ID certificate and notarized by Apple (see
  [DISTRIBUTION.md](DISTRIBUTION.md)); Gatekeeper verifies the signature chain on every launch.
