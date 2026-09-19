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
*upload* to Apple's notary service). Either path works; the profile name `TokenWatch` used below
is what `scripts/notarize.sh` and `scripts/release.sh` expect by default.

**Option A — Apple ID + app-specific password** (simpler, what `store-credentials` defaults to
when you skip the API key prompt):
```sh
xcrun notarytool store-credentials "TokenWatch Notary"
# Profile name: TokenWatch
# Path to App Store Connect API private key: <leave blank, press enter>
# Developer Apple ID: <your Apple ID email on the MetaPouch team>
# App-specific password: <generate one at appleid.apple.com -> Sign-In and Security ->
#   App-Specific Passwords -> + -> copy the xxxx-xxxx-xxxx-xxxx password shown once>
# Team ID: <MetaPouch's 10-character Team ID, from developer.apple.com/account -> Membership,
#   or Xcode -> Settings -> Accounts -> select the MetaPouch team>
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
spctl -a -t open --context context:primary-signature -v dist/TokenWatch-1.0.0.dmg
# should print: accepted, source=Notarized Developer ID
```

## Publish

- **GitHub Release**: `./scripts/release.sh <version>` builds, signs, notarizes, and uploads the
  DMG to a new GitHub release in one shot (see that script's header for prerequisites).
- **Homebrew Cask**: `homebrew-cask/tokenwatch.rb` is a ready-to-submit cask formula. Update its
  `sha256` after cutting a release (the release script prints it), then open a PR against
  [homebrew/homebrew-cask](https://github.com/Homebrew/homebrew-cask) or tap it yourself first:
  `brew tap ajays97/tokenwatch && brew install --cask tokenwatch`.
- **tokenwatch.fyi**: the landing page's Download button points at the latest GitHub release
  asset directly (`/releases/latest/download/...`), so publishing a release is enough — no
  separate landing-page edit needed per version.

## Versioning

Bump both `CFBundleShortVersionString` in `Resources/Info.plist` and the tag passed to
`scripts/release.sh`. `CFBundleVersion` (the build number) can stay monotonically increasing
separately if you want Sparkle-style auto-update later; not required for manual DMG distribution.

## Auto-update (not set up yet)

Out of scope for this pass. If you want in-app update checks later, the standard approach is
[Sparkle](https://sparkle-project.org/): add it as a dependency, generate an EdDSA signing key,
publish an `appcast.xml` alongside releases. Flag it separately when you want it — it changes the
app's dependency graph and adds a signing key to manage, which is a real decision, not a script.
