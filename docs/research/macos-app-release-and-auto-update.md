# Releasing Desk Layouter publicly + adding auto-update (2026)

Research on how to sign, notarize, package, and publish this **SPM-built, Accessibility-using,
menu-bar** macOS app to the public, and how to add in-app auto-update via **Sparkle 2**.
Investigated against Apple, Sparkle, GitHub, and Homebrew first-party docs, plus the friend's
reference release repo.

Project facts assumed (see `CLAUDE.md` / `docs/research/macos-app-stack.md`): native Swift,
built with **Swift Package Manager — no Xcode project**; `.app` assembled by
`Scripts/build-app.sh`; bundle id `com.taimonania.DeskLayouter`; version `0.1.0`;
`LSMinimumSystemVersion 13.0`; `LSUIElement` menu-bar agent; uses the **Accessibility API**
(`AXUIElement`) to arrange windows, so it must run **unsandboxed**.

---

## Recommendation / TL;DR

- **Channel: GitHub Releases** as the primary distribution channel (a `.dmg` for humans + a
  `.zip` for the Sparkle feed), optionally fronted later by a **Homebrew Cask** pointing at those
  release URLs. **The Mac App Store is not an option**: MAS requires the App Sandbox, and the
  Accessibility API does not work from a sandboxed app.
- **Signing: mandatory, and not just for Gatekeeper.** Get an Apple Developer Program membership
  ($99/yr) and a **Developer ID Application** certificate. Sign the assembled `.app` with
  `codesign --options runtime --timestamp`, then **notarize with `notarytool`** and **staple with
  `stapler`**. This is required both for other users to open the app without Gatekeeper friction
  *and* for Sparkle to install updates.
- **A stable Developer ID signature is doubly important here because the app uses Accessibility.**
  TCC ties the Accessibility grant to the app's code-signing identity (designated requirement).
  An unsigned / ad-hoc-signed app gets a *new* identity on every rebuild, so the user's
  Accessibility grant is dropped/thrashed on each update. A Developer ID signature keeps the
  identity stable across versions, so the grant survives auto-updates.
- **Auto-update: Sparkle 2**, added as an SPM dependency. Host a static **`appcast.xml`** (e.g. on
  GitHub Pages or as a release asset) whose `<enclosure>` points at the `.zip` on GitHub Releases.
  Set `SUFeedURL` + `SUPublicEDKey` in `Info.plist`; sign each update with Sparkle's EdDSA keys
  (`generate_keys` once, then `generate_appcast`/`sign_update` per release). Sparkle-installed
  updates must themselves be signed + notarized.
- **The reference repo (`live-tokens-releases`) is NOT a Sparkle app** — its `latest-mac.yml` +
  `.blockmap` assets are the *electron-updater* feed format. Copy its *release layout* (dmg for
  humans, zip + feed file for the updater, semver tags), but the native equivalent of its updater
  is Sparkle, not electron-updater.

---

## 1. Signing & notarization for an SPM-built app (no Xcode project)

### 1a. What you need from Apple

To distribute a Mac app outside the App Store you must be a **member of the Apple Developer
Program** ($99/yr) and obtain a **Developer ID Application** certificate; Apple's Developer ID page
states: *"To distribute your Mac software with Developer ID, you'll need to be a member of the
Apple Developer Program … obtain a Developer ID certificate, and submit your app to be notarized
by Apple."* The certificate is valid for 5 years and enables Gatekeeper verification + notarization
([Apple — Developer ID](https://developer.apple.com/support/developer-id/)).

There is **nothing Xcode-project-specific** about any of the signing/notarization commands — they
all operate on the finished `.app` bundle, so the fact that we build with SPM and assemble the
bundle in `Scripts/build-app.sh` is irrelevant to signing. We just run `codesign`/`notarytool`/
`stapler` on the `.build/Desk Layouter.app` that the script already produces.

### 1b. Sign with hardened runtime + secure timestamp

Notarization requires the **hardened runtime** and a **secure timestamp**, signed with the
Developer ID Application identity. Apple's notarization docs give the flags directly
([Apple — Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution),
[Apple — Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)):

```bash
codesign --sign "Developer ID Application: <Name> (<TeamID>)" \
         --options runtime --timestamp \
         --force "<.build/Desk Layouter.app>"
```

- `--options runtime` = enable the hardened runtime (mandatory for notarization).
- `--timestamp` = embed Apple's secure timestamp (keeps the signature valid past cert expiry).
- Sign nested code (helpers, frameworks — e.g. Sparkle's XPC services, see §4) **inside-out first**,
  then the outer `.app`. Apple warns **against `--deep`** for bundles with their own signing needs
  (Sparkle's docs echo this — do not use `--deep`, see §4c).

### 1c. Notarize with `notarytool`, then staple

```bash
# One-time: store App-Store-Connect credentials in the keychain
xcrun notarytool store-credentials "DL-notary" \
      --apple-id <email> --team-id <TeamID> --password <app-specific-password>

# Per release: submit the DMG (or a zip) and block until Apple responds
xcrun notarytool submit "Desk Layouter.dmg" --keychain-profile "DL-notary" --wait

# On success, staple the ticket so it verifies offline
xcrun stapler staple "Desk Layouter.dmg"
```

`notarytool submit --wait` blocks until Apple returns accepted/rejected; `stapler staple` attaches
the ticket to the artifact so Gatekeeper can verify without a network round-trip
([Apple — Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)).
The `--password` must be an **app-specific password** (not your Apple ID password); this is a
manual secret you generate at appleid.apple.com and store once.

### 1d. Why signing matters *specifically* because of the Accessibility permission

This is the most important, non-obvious point for this app. macOS **TCC** (the privacy database
behind System Settings → Privacy & Security → Accessibility) attributes a permission grant to an
app by its **code-signing identity / designated requirement**, not merely its bundle id or path.

Apple DTS (Quinn) on the developer forums: *"when dealing with TCC it's best to sign your code with
a stable signing identity, typically Apple Developer for day-to-day work and Developer ID for final
distribution. Doing this will radically cut down on the amount of TCC thrash"*
([Apple Developer Forums — thread 730043](https://developer.apple.com/forums/thread/730043),
background on the designated requirement: Apple **TN3127 "Inside Code Signing: Requirements"**).

Consequence: an **unsigned or ad-hoc-signed** build gets a *fresh* identity every time it's rebuilt,
so TCC treats each build as a different app and the user's Accessibility grant is lost / must be
re-approved. For an app whose whole job depends on that grant and that will ship frequent
auto-updates, this is unacceptable. **A single stable Developer ID Application identity across all
versions means the Accessibility grant persists across updates.** (This alone justifies paying for
the Developer Program even before considering Gatekeeper.)

---

## 2. Packaging & distribution channels

### 2a. Mac App Store — ruled out

MAS apps **must** adopt the App Sandbox, and **the Accessibility API does not function inside the
sandbox**: the permission prompt never appears, the app can't be added under Privacy & Security →
Accessibility, and `AXIsProcessTrusted()` always returns `false`. Apple documents that App Sandbox
blocks the Accessibility APIs (see *"Protecting user data with App Sandbox"*), and the developer
forums confirm it plainly: *"It is not possible to use the accessibility API from a sandboxed app …
this will not work even if the user manually grants it permission."*
([Apple Developer Forums — Accessibility permission not granted for sandboxed macOS app](https://developer.apple.com/forums/thread/810677),
[thread 749494](https://developer.apple.com/forums/thread/749494)).
Since Desk Layouter arranges windows via `AXUIElement` (ADR 0003), it must be **unsandboxed**, which
excludes the Mac App Store. This is the same reasoning already noted in `macos-app-stack.md` §1.

### 2b. DMG vs ZIP for GitHub Releases

- **DMG** — the friendly download for humans (drag-to-`/Applications`). Best as the visible release
  asset. Can be notarized + stapled as a unit.
- **ZIP** — Sparkle's preferred update archive; small and simple. This is what the *auto-updater*
  downloads, not humans.
- Ship **both** (this is exactly what the reference repo does — see §3): DMG for first install, ZIP
  for the Sparkle feed.

### 2c. Homebrew Cask (optional, later)

A Homebrew Cask is a declarative Ruby file with `version`, `sha256`, `url`, and an `app` stanza; the
`url` can point straight at a GitHub Releases download and interpolate `#{version}`, e.g.
`"https://github.com/.../releases/download/#{version}/App-#{version}.zip"`; the `app` stanza names
the `.app` to move into `/Applications`
([Homebrew — Cask Cookbook](https://docs.brew.sh/Cask-Cookbook)). Good as a secondary "power-user"
channel once GitHub Releases exists; it adds nothing to signing/notarization (Homebrew just
downloads the already-signed artifact).

### 2d. Recommendation

**GitHub Releases (DMG + ZIP + appcast) as the primary channel**, mirroring the reference repo's
layout; add a **Homebrew Cask** later if desired. Everything downstream (Sparkle, Homebrew) consumes
the same signed+notarized artifacts.

---

## 3. GitHub Releases layout (mirroring the reference repo)

GitHub Releases are **based on Git tags** ("Releases are based on Git tags, which mark a specific
point in your repository's history"); a single release can carry **up to 1000 assets**, each **< 2
GiB**; anyone with read access can download, only writers can manage; you can auto-generate or
hand-write release notes
([GitHub — About releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)).
Asset download URLs follow
`https://github.com/<owner>/<repo>/releases/download/<tag>/<asset-name>` (confirmed against the
reference repo's live asset URLs).

**Versioning:** use **SemVer `MAJOR.MINOR.PATCH`** — increment MAJOR for incompatible changes, MINOR
for backward-compatible features, PATCH for backward-compatible bug fixes
([semver.org](https://semver.org/)). This must match `CFBundleShortVersionString` (currently
`0.1.0`) and increment `CFBundleVersion` (currently `1`) on every build.

**What the reference repo (`eiselmayer/live-tokens-releases`) actually does** (fetched live):

- Tags are `vMAJOR.MINOR.PATCH` (`v0.0.1` … `v0.0.8`); one GitHub Release per tag, `Latest` flag on
  the newest; release **notes use `## Highlights` / `## Notes` sections**; the source lives in a
  *separate private repo* and this public repo holds only downloads + the update feed (its README
  says so).
- Assets per release (for `v0.0.8`):
  - `Live-Tokens-0.0.8-arm64.dmg` — human download.
  - `Live-Tokens-0.0.8-arm64-mac.zip` — the archive the in-app updater downloads.
  - `latest-mac.yml` — the update **feed** (contains `version`, per-file `sha512` + `size`,
    `releaseDate`).
  - `*.blockmap` files — differential-download maps.
- **Caveat:** `latest-mac.yml` + `.blockmap` + `sha512` are the **electron-builder / electron-updater**
  format — i.e. that app is an **Electron** app. For our **native Swift** app the equivalent updater
  is **Sparkle**, and the feed file is an **`appcast.xml`** (EdDSA-signed `<enclosure>`s), *not*
  `latest-mac.yml`. So: copy the *shape* (dmg + zip + a feed file, semver tags, notes sections,
  separate public "releases" repo), but not the specific feed format.

**Repo choice:** the reference uses a dedicated public `*-releases` repo with the source kept
private. If Desk Layouter's source is/stays public, you can just use its own repo's Releases tab; if
you want to keep source private but downloads public, mirror the reference's split.

---

## 4. Auto-update via Sparkle 2

Sparkle is the de-facto framework for non-App-Store macOS auto-update; it's MIT-licensed, supports
**macOS 10.13+** (well below our 13.0 floor), and *"Supports Sparkle's own EdDSA signatures as well
as Apple Code Signing for ultra-secure updates"*
([sparkle-project.org](https://sparkle-project.org/)).

### 4a. Add Sparkle via SPM

Add `https://github.com/sparkle-project/Sparkle` as a Swift package dependency and link the
`Sparkle` product; drive updates with an `SPUStandardUpdaterController`
([Sparkle — Documentation](https://sparkle-project.org/documentation/)). Because we have **no Xcode
project**, we add it in `Package.swift` as a `.package(url:…)` dependency of the app target rather
than through Xcode's "Add Packages" UI. Sparkle ships its command-line tools *inside the resolved
package*: per the docs they live at
`…/artifacts/sparkle/Sparkle/bin/` (i.e. under the SwiftPM/Xcode `artifacts` checkout) — that's
where `generate_keys`, `generate_appcast`, and `sign_update` are found
([Sparkle — Documentation, "Adding Sparkle to your project"](https://sparkle-project.org/documentation/)).

### 4b. Info.plist keys + the appcast feed

Two `Info.plist` keys are required
([Sparkle — Documentation](https://sparkle-project.org/documentation/)):

- **`SUFeedURL`** — the HTTPS URL of your `appcast.xml` (e.g.
  `https://taimonania.github.io/desk-layouter/appcast.xml`).
- **`SUPublicEDKey`** — the **EdDSA public key** Sparkle uses to verify each update's signature.

The **appcast** is an RSS/XML file of `<item>` entries; each has an `<enclosure>` with `url`,
`length`, `sparkle:version`, and the **`sparkle:edSignature`** attribute, plus optional
`<sparkle:releaseNotesLink>` / `<pubDate>`
([Sparkle — Publishing an update](https://sparkle-project.org/documentation/publishing/)).

**Hosting on GitHub:** Sparkle's docs don't prescribe a host — `SUFeedURL` is simply "an appcast
URL" and the `<enclosure url=…>` is any reachable HTTPS URL. So the standard pattern works cleanly:
serve `appcast.xml` as a **static file via GitHub Pages** (or as a release asset), with each
`<enclosure url>` pointing at the **`.zip` on GitHub Releases**
(`https://github.com/…/releases/download/<tag>/DeskLayouter-<version>.zip`). (This is an inference
from how `SUFeedURL`/`<enclosure>` are defined, not an explicit Sparkle endorsement of GitHub.)

### 4c. EdDSA signing of updates

- Run **`./bin/generate_keys`** **once** — it creates a **private key stored in your macOS Keychain**
  and prints the **public key** you paste into `SUPublicEDKey`
  ([Sparkle — Documentation](https://sparkle-project.org/documentation/)).
- Per release, sign the archive. The recommended path is **`generate_appcast`**, which builds the
  appcast and signs every enclosure automatically: *"Signatures are automatically generated when you
  make an appcast using `generate_appcast` tool. This is the recommended method."* For manual/CI
  use, **`sign_update path/to/update.zip`** emits the `sparkle:edSignature="…" length="…"` fragment
  ([Sparkle — Publishing an update](https://sparkle-project.org/documentation/publishing/)).
- The EdDSA private key is a **manual secret** — back it up out of the Keychain; losing it means you
  can't sign future updates that existing installs will accept.

### 4d. Updates must be signed + notarized; XPC/SPM signing caveats

- Sparkle recommends you *"Notarize and code sign the application via Apple's Developer ID program"*;
  for Developer-ID-signed apps Sparkle even permits EdDSA key rotation
  ([Sparkle — Documentation](https://sparkle-project.org/documentation/)). So each update ZIP must
  contain a properly signed + notarized `.app` (§1) — Sparkle will refuse/complain otherwise, and
  Gatekeeper would block the swapped-in app anyway.
- **XPC services / SPM caveat:** Sparkle bundles `Installer.xpc` + `Downloader.xpc`. *"The Installer
  XPC Service is required for Sandboxed applications"*; **we are not sandboxed**, so per the docs you
  *"may choose to remove these services in a post install script."* Sparkle's helpers ship
  *"signed with an ad-hoc signature and Hardened Runtime enabled"* — with the standard Xcode
  archive/export flow *"you do not need to especially do anything for signing Sparkle or its XPC
  Services,"* but **we don't use Xcode's export flow**, so `Scripts/build-app.sh` must **re-sign
  Sparkle's nested helpers** (Autoupdate, Updater.app, and the XPC services we keep) with our
  Developer ID + `-o runtime`, signing **inside-out** and **without `--deep`** (the docs warn `--deep`
  causes sandboxing errors)
  ([Sparkle — Sandboxing / code-signing guide](https://sparkle-project.org/documentation/)).
  This nested-helper re-signing is the main extra work SPM (vs. Xcode) imposes for Sparkle.

---

## 5. End-to-end recommended release pipeline for Desk Layouter

Ordered checklist. **★ = manual / secret-handling step that cannot be fully automated.**

**One-time setup**

1. ★ Join the **Apple Developer Program**; create a **Developer ID Application** certificate; install
   it in the login keychain.
2. ★ Create an **app-specific password** and run `xcrun notarytool store-credentials "DL-notary" …`
   once.
3. ★ Add Sparkle to `Package.swift`; run `generate_keys` once; paste the public key into
   `SUPublicEDKey` and set `SUFeedURL` in `App/Info.plist`; **back up the EdDSA private key**.
4. Decide feed hosting (GitHub Pages branch/dir for `appcast.xml`) and the download repo layout
   (own repo vs. dedicated public `-releases` repo).

**Per release**

5. Bump `CFBundleShortVersionString` (SemVer) and `CFBundleVersion` in `App/Info.plist`.
6. **Build:** `Scripts/build-app.sh` (swift build → assemble `.build/Desk Layouter.app`).
7. **Sign:** re-sign Sparkle's nested helpers/XPC (§4d) inside-out, then the app, with
   `codesign --options runtime --timestamp --sign "Developer ID Application: …"` (no `--deep`).
8. **Package:** create the `.dmg` (human) and the `.zip` (Sparkle feed).
9. **Notarize + staple:** `notarytool submit … --wait` then `stapler staple` the DMG (and the app
   inside the zip / the zip as applicable).
10. **Appcast:** run `generate_appcast` (or `sign_update`) to produce/update EdDSA-signed
    `appcast.xml` with an `<enclosure>` URL pointing at the release's `.zip`.
11. **Tag + Release:** `git tag vX.Y.Z`; create the GitHub Release with notes (mirror the reference's
    `## Highlights` / `## Notes`); upload `.dmg` + `.zip` (+ appcast asset if hosting it there).
12. **Publish the feed:** commit/deploy the updated `appcast.xml` to its host (GitHub Pages) so
    `SUFeedURL` serves it.
13. Verify: fresh download opens without Gatekeeper prompt (stapled); a prior version offered the
    update in-app and installs it while **preserving the Accessibility grant** (stable Developer ID).

**CI later (GitHub Actions on a `macos` runner)**

- Automatable: build, package, notarize (`notarytool --wait`), staple, `generate_appcast`, create
  the Release + upload assets (`gh release create`), deploy Pages.
- ★ Must be provided as **encrypted secrets / manual**: the Developer ID cert + private key
  (imported into a temporary keychain), the notarytool app-specific password / API key, and the
  **Sparkle EdDSA private key**. These are the only true manual/secret pieces.

---

## Open questions for the user to decide

- **Public source or private?** Use the app's own repo's Releases tab (if source stays public), or a
  dedicated public `desk-layouter-releases` repo with private source (as the reference does)?
- **Appcast host:** GitHub Pages vs. a release asset for `appcast.xml`?
- **Homebrew Cask** now or later (secondary channel)?
- **Architectures:** ship arm64-only (like the reference) or a universal binary? SPM can build
  `arch -arch` / `--arch arm64 --arch x86_64`; decide based on target users.
- **CI now or ship manually first?** The pipeline runs fine by hand; CI is a follow-on once the
  secrets story is set up.

---

## Sources

- Apple — [Developer ID](https://developer.apple.com/support/developer-id/)
- Apple — [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- Apple — [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- Apple Developer Forums — [TCC & stable signing identity (thread 730043, Quinn/DTS)](https://developer.apple.com/forums/thread/730043)
- Apple Developer Forums — [Accessibility not granted for sandboxed app (thread 810677)](https://developer.apple.com/forums/thread/810677), [thread 749494](https://developer.apple.com/forums/thread/749494)
- Apple — TN3127 *Inside Code Signing: Requirements* (designated requirement)
- Sparkle — [Documentation (integration, SPM, Info.plist keys, generate_keys, XPC/sandboxing, code signing)](https://sparkle-project.org/documentation/)
- Sparkle — [Publishing an update (generate_appcast, sign_update, sparkle:edSignature)](https://sparkle-project.org/documentation/publishing/)
- Sparkle — [Project home (features, macOS 10.13+, EdDSA + Apple Code Signing)](https://sparkle-project.org/)
- GitHub — [About releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)
- Homebrew — [Cask Cookbook](https://docs.brew.sh/Cask-Cookbook)
- [Semantic Versioning 2.0.0](https://semver.org/)
- Reference repo — [eiselmayer/live-tokens-releases](https://github.com/eiselmayer/live-tokens-releases) (README + live release assets: `.dmg`, `-mac.zip`, `latest-mac.yml`, `.blockmap` — electron-updater feed)
