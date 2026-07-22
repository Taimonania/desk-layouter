# Releasing Desk Layouter

Desk Layouter ships as a signed, notarized, stapled `.dmg` on the project's
[GitHub Releases](https://github.com/Taimonania/desk-layouter/releases) page. A
stranger can download it and open it without Gatekeeper blocking it as
unidentified, and — because it is signed with a stable Developer ID identity —
keeps its Accessibility grant across updates (the reason signing is mandatory,
not optional; see `docs/research/macos-app-release-and-auto-update.md`).

The whole flow lives in one committed script, `Scripts/release.sh`, wrapped by
Make targets. Phase 1 (#44) produced the signed `.dmg`. **Phase 2** (#45, #46)
adds Sparkle auto-update: alongside the `.dmg`, the pipeline now emits a `.zip`
of the same signed/notarized/stapled `.app` and an EdDSA-signed `appcast.xml`,
uploads the `.zip` to the GitHub Release, and deploys the appcast to GitHub
Pages so installed builds can discover and install updates. Phase 3 automates
the same script in CI (#48).

## One-time manual prerequisites

These are human-only and cannot be scripted. `Scripts/release.sh preflight`
(a.k.a. `make release-preflight`) checks for them and reports every missing one
at once.

1. **Apple Developer Program membership.**
2. **A "Developer ID Application" certificate** in your login keychain
   (created via Xcode → Settings → Accounts, or the Developer portal). The
   script auto-detects a single such identity; if you have more than one, set
   `DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)"`.
   The project's Apple **Team ID is `Q353FAS349`** (non-secret; it is embedded
   in every signed build).
3. **A stored notary credential profile.** Create it once:
   ```sh
   xcrun notarytool store-credentials DeskLayouterNotary \
     --apple-id you@example.com --team-id Q353FAS349 \
     --password <app-specific-password>
   ```
   Override the profile name with `NOTARY_KEYCHAIN_PROFILE`.
4. **`create-dmg`**: `brew install create-dmg`.
5. **`gh`** authenticated with push access to the release repo
   (`gh auth login`; this repo uses the `Taimonania` account).
6. **GitHub Pages enabled for the appcast** — *one-time, human-only*. In the
   repo on GitHub: **Settings → Pages → Build and deployment → Deploy from a
   branch → Branch: `gh-pages` / `/ (root)`**. The pipeline creates and pushes
   the `gh-pages` branch on the first publish, but GitHub only serves it once
   Pages is turned on. Until then the appcast returns 404 and auto-update cannot
   find a feed. The appcast must be reachable at the `SUFeedURL` baked into
   `App/Info.plist` (`https://taimonania.github.io/desk-layouter/appcast.xml`),
   which is what `verify-release` asserts.

The Sparkle **EdDSA private key** already lives in the login keychain and is
read automatically by `generate_appcast`; the matching public key
(`SUPublicEDKey`) is baked into `App/Info.plist`. Back up **both** the Developer
ID certificate + private key **and** the EdDSA private key out of band — losing
the Developer ID would break the Accessibility-grant-survival guarantee, and
losing the EdDSA key would make it impossible to sign any future update that
existing installs will accept.

## Cutting a release

1. Bump `CFBundleShortVersionString` in `App/Info.plist` (SemVer). It is the
   single source of truth: the git tag is derived from it as `vX.Y.Z`, and
   `CFBundleVersion` should increment per build.
2. Edit `RELEASE_NOTES.md`; keep the `## Highlights` and `## Notes` sections.
3. Dry run (build → sign → notarize → staple → **appcast** → local verify,
   **no publish**):
   ```sh
   make release
   ```
   The appcast stage zips the signed/notarized/stapled `.app` with `ditto`
   (`ditto -c -k --keepParent`, so bundle metadata and symlinks survive) and
   runs Sparkle's `generate_appcast` over it to produce an EdDSA-signed
   `appcast.xml` whose enclosure points at the Release download URL. Artifacts
   land in `.build/release/appcast/` (`DeskLayouter-X.Y.Z.zip` + `appcast.xml`).
4. Publish (irreversible + public), then verify it is live:
   ```sh
   RELEASE_PUBLISH=1 make release
   ```
   Publish now does two public things: it creates the GitHub Release uploading
   **both** the `.dmg` and the update `.zip`, and it deploys `appcast.xml` to
   GitHub Pages. The Pages deploy runs entirely inside a throwaway clone checked
   out on the `gh-pages` branch — it overwrites only `appcast.xml` (preserving
   any other served files), commits, and pushes once. It **never touches
   `main`**. On the first release it creates `gh-pages` as an orphan branch;
   thereafter it seeds the staging directory from the currently published feed
   so older `<item>` entries are preserved. Remember Pages must be enabled once
   (prerequisite 6) or the feed will 404.

`RELEASE_PUBLISH` gating is deliberate: publishing is public and hard to undo,
so it never happens by accident.

## Verifying a release

`make verify-release` asserts **observable** properties, not that the script ran:

- **Local artifact**: `codesign --verify --strict --deep`, a Developer ID
  Application authority, the hardened-runtime flag, Gatekeeper acceptance
  (`spctl`), and a stapled ticket (`stapler validate`).
- **Availability** (once published): every published asset URL returns HTTP 200,
  the release is tagged and flagged latest, and the downloaded `.dmg`'s checksum
  matches the locally built artifact. Additionally, the appcast at `SUFeedURL`
  returns HTTP 200, parses as XML, its newest `<enclosure>` carries a non-empty
  `sparkle:edSignature`, and that enclosure's download URL returns HTTP 200.

## Individual stages

`Scripts/release.sh` also runs each stage on its own for debugging:
`preflight`, `build`, `sign`, `package`, `notarize`, `staple`, `appcast`,
`publish`, `verify-local`, `verify-available`, `verify`, `all`. `make
release-appcast` is a shortcut for the `appcast` stage.
