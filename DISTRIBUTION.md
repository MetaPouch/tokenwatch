# Distributing TokenWatch

Full pipeline: build → sign → notarize → staple → package → publish. The build/package/notarize
steps are scripted (`scripts/*.sh`). Two one-time setup steps need your MetaPouch Apple Developer
account interactively — nothing here can be done without your Apple ID / 2FA.

## One-time setup (do this once, in Xcode)

**1. Add the MetaPouch team to Xcode and create a Developer ID Application certificate.**

1. Xcode → Settings → Accounts → **+** → sign in with the Apple ID that belongs to the MetaPouch
   team. You'll need Account Holder or Admin role on that team to create Developer ID certs.
2. Select the MetaPouch team in the list → **Manage Certificates…** → **+** (bottom left) →
   **Developer ID Application**.
3. Xcode generates the keypair, requests the cert from Apple, and installs it in your login
   keychain automatically. No manual CSR needed.
4. Confirm it's there:
   ```sh
   security find-identity -v -p codesigning
   ```
   You should see a line like `"Developer ID Application: MetaPouch (ABCDE12345)"`. That whole
   quoted string is your `SIGN_IDENTITY`.

**2. Store notarytool credentials** (separate from the signing cert — this authenticates the
*upload* to Apple's notary service). Either path works; the profile name `TokenWatch Notary`
used below is what `scripts/notarize.sh` and `scripts/release.sh` expect by default.

**Option A — Apple ID + app-specific password** (simpler, what `store-credentials` defaults to
when you skip the API key prompt):
```sh
xcrun notarytool store-credentials "TokenWatch Notary"
# Profile name: TokenWatch Notary
# Path to App Store Connect API private key: <leave blank, press enter>
# Developer Apple ID: <your Apple ID email on the MetaPouch team>
# App-specific password: <generate one at appleid.apple.com -> Sign-In and Security ->
#   App-Specific Passwords -> + -> copy the xxxx-xxxx-xxxx-xxxx password shown once>
```
Re-run `store-credentials` again later if the app-specific password is ever revoked.

**Option B — App Store Connect API key** (doesn't expire with your Apple ID password, better
for long-lived CI use):
1. Go to [appstoreconnect.apple.com](https://appstoreconnect.apple.com) → **Users and Access** →
   **Integrations** tab → **Team Keys** → **+** to generate a key with the **Developer** role.
2. Download the `.p8` file **immediately** — Apple only lets you download it once. Note the **Key
   ID** and **Issuer ID** shown on that page.
3. Store it as a keychain profile:
   ```sh
   xcrun notarytool store-credentials "TokenWatch Notary" \
     --key /path/to/AuthKey_XXXXXXXXXX.p8 \
     --key-id XXXXXXXXXX \
     --issuer YOUR-ISSUER-UUID
   ```
4. Delete the `.p8` file from Downloads after storing it; the keychain profile is the only copy
   needed going forward.

**Either way, confirm it's stored:**
```sh
xcrun notarytool history --keychain-profile "TokenWatch Notary"
```
An empty list is a success — it just proves the credentials authenticate correctly.

## Build → sign → notarize → package

```sh
# 1. Build and code-sign the .app (auto-detects your Developer ID identity)
./scripts/build-app.sh

# 2. Package into a DMG (auto-detects and signs with the same identity)
./scripts/build-dmg.sh

# 3. Submit to Apple's notary service, wait for approval, staple the ticket
./scripts/notarize.sh
```

After step 3, `dist/TokenWatch-<version>.dmg` is signed, notarized, and stapled: it opens on any
Mac with a plain double-click, no Gatekeeper warning, no "unidentified developer" prompt, and no
network call to Apple at launch time (the staple embeds the ticket in the file itself).

Verify independently at any point:
```sh
spctl -a -t open --context context:primary-signature -v dist/TokenWatch-<version>.dmg
# should print: accepted, source=Notarized Developer ID
```

## Publish

- **GitHub Release**: `./scripts/release.sh <version>` builds, signs, notarizes, uploads the DMG
  to a new GitHub release, and (once the one-time Sparkle key setup below is done) regenerates
  and pushes `docs/appcast.xml` so existing installs see the update -- one shot (see that
  script's header for prerequisites).
- **Homebrew Cask**: `homebrew-cask/tokenwatch.rb` is a ready-to-submit cask formula. Update its
  `sha256` after cutting a release (the release script prints it), then open a PR against
  [homebrew/homebrew-cask](https://github.com/Homebrew/homebrew-cask) or tap it yourself first:
  `brew tap MetaPouch/tokenwatch && brew install --cask tokenwatch`. `auto_updates true` since
  Sparkle is the app's own update mechanism now -- Homebrew defers to it instead of managing
  upgrades itself.
- **tokenwatch.fyi**: the landing page's Download button points at the latest GitHub release
  asset directly (`/releases/latest/download/...`), so publishing a release is enough — no
  separate landing-page edit needed per version. `docs/appcast.xml` is served from the same
  GitHub Pages site, at `/appcast.xml`.

## Versioning

Bump both `CFBundleShortVersionString` in `Resources/Info.plist` and the tag passed to
`scripts/release.sh`; the script does this for you. `CFBundleVersion` (the build number Sparkle
actually compares to decide whether an update exists) is set automatically from the commit count
(`git rev-list --count HEAD`) — monotonic for as long as history only fast-forwards, so it never
needs manual bookkeeping or risks colliding between releases.

## Auto-update (Sparkle)

In-app update checks use [Sparkle](https://sparkle-project.org/) (`Package.swift`'s one external
dependency). `AppUpdater` (`Sources/TokenWatch/Support/AppUpdater.swift`) wraps
`SPUStandardUpdaterController`: a daily background check against `SUFeedURL`
(`https://tokenwatch.fyi/appcast.xml`), a "Check for Updates…" item in the ⋯ menu, and an
"Automatically Check for Updates" toggle in Settings. Checking never installs anything without
an explicit click, and `SUEnableSystemProfiling` is off, so the check carries no system-profile
data — see SECURITY.md.

### One-time setup (do this once, on whichever Mac cuts releases)

**1. Download the Sparkle command-line tools.** The SPM package only vends the framework, not
`generate_keys`/`generate_appcast`/`sign_update` — those ship in the separate release tarball:
```sh
mkdir -p ~/.sparkle-tools
curl -L -o /tmp/sparkle-tools.tar.xz \
  https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz
tar -xf /tmp/sparkle-tools.tar.xz -C ~/.sparkle-tools
```
`scripts/release.sh` looks for these under `~/.sparkle-tools/bin` by default (override with
`SPARKLE_BIN_DIR`).

**2. Generate the EdDSA signing keypair.** Stores the private key in your login Keychain and
prints the public key:
```sh
~/.sparkle-tools/bin/generate_keys
```
Paste the printed public key into `Resources/Info.plist`'s `SUPublicEDKey`, replacing the
`REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY` placeholder. Without a valid key there, Sparkle's signature
check fails closed and every check finds nothing — safe, but no auto-update actually works until
this is done. The private key never leaves this Keychain; `generate_appcast` (next release, and
every one after) finds it there automatically to sign.

### Every release after that

`scripts/release.sh <version>` does it: copies the freshly-published DMG into a persistent local
archive (`~/.tokenwatch-release-archive` by default, override with
`TOKENWATCH_RELEASE_ARCHIVE`; kept outside `dist/`, which `build-app.sh` wipes every run, so
`generate_appcast` always sees the full release history), regenerates `docs/appcast.xml` from
that archive with `generate_appcast --maximum-deltas 0` (delta updates are off — this app is
small enough that full-download updates are simpler to operate), and commits + pushes
`docs/appcast.xml` if it changed. If the Sparkle tools aren't installed, the script warns and
skips this step instead of failing the release — the DMG still publishes normally, existing
installs just won't see it as an in-app update until the appcast catches up.
