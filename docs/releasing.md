# Releasing Desk Layouter

Desk Layouter ships as a signed, notarized, stapled `.dmg` on the project's
[GitHub Releases](https://github.com/Taimonania/desk-layouter/releases) page. A
stranger can download it and open it without Gatekeeper blocking it as
unidentified, and — because it is signed with a stable Developer ID identity —
keeps its Accessibility grant across updates (the reason signing is mandatory,
not optional; see `docs/research/macos-app-release-and-auto-update.md`).

The whole flow lives in one committed script, `Scripts/release.sh`, wrapped by
Make targets. This is **Phase 1** of #43 (manual, human-run release). Phase 2
adds Sparkle auto-update (#45, #46); Phase 3 automates the same script in CI
(#48).

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

Back up the Developer ID certificate + private key out of band — losing the
identity would break the Accessibility-grant-survival guarantee for existing
installs.

## Cutting a release

1. Bump `CFBundleShortVersionString` in `App/Info.plist` (SemVer). It is the
   single source of truth: the git tag is derived from it as `vX.Y.Z`, and
   `CFBundleVersion` should increment per build.
2. Edit `RELEASE_NOTES.md`; keep the `## Highlights` and `## Notes` sections.
3. Dry run (build + sign + notarize + staple + local verify, **no publish**):
   ```sh
   make release
   ```
4. Publish (creates the public GitHub Release — irreversible), then verify it is
   live:
   ```sh
   RELEASE_PUBLISH=1 make release
   ```

`RELEASE_PUBLISH` gating is deliberate: publishing is public and hard to undo,
so it never happens by accident.

## Verifying a release

`make verify-release` asserts **observable** properties, not that the script ran:

- **Local artifact**: `codesign --verify --strict --deep`, a Developer ID
  Application authority, the hardened-runtime flag, Gatekeeper acceptance
  (`spctl`), and a stapled ticket (`stapler validate`).
- **Availability** (once published): every published asset URL returns HTTP 200,
  the release is tagged and flagged latest, and the downloaded `.dmg`'s checksum
  matches the locally built artifact.

## Individual stages

`Scripts/release.sh` also runs each stage on its own for debugging:
`preflight`, `build`, `sign`, `package`, `notarize`, `staple`, `publish`,
`verify-local`, `verify-available`, `verify`, `all`.
