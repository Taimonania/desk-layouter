---
name: release
description: Cut and publish a new signed, notarized Desk Layouter release with a Sparkle auto-update feed. Use when the user wants to cut, ship, or publish a new Desk Layouter version.
---

# Releasing Desk Layouter

Runbook for cutting a public release: a signed, notarized, stapled `.dmg`, plus a
Sparkle update `.zip` and an EdDSA-signed `appcast.xml` served from GitHub Pages so
existing installs auto-update. The whole pipeline is one script, `Scripts/release.sh`,
wrapped by `make` targets. Releases are cut **manually** — CI is intentionally deferred
(issue #48).

Read `docs/releasing.md` for the one-time human prerequisites (Apple Developer
membership, Developer ID cert, notary profile, `create-dmg`, `gh` auth). This skill
assumes they already exist; `make release-preflight` confirms them.

## Key facts

- **The version is the single source of truth.** `CFBundleShortVersionString` in
  `App/Info.plist` drives the git tag (`vX.Y.Z`), the asset names, and the appcast.
  Bump it (SemVer) together with `CFBundleVersion` (a monotonic build integer).
- **gh account:** every `gh` command uses `GH_HOST=github.com` with the `Taimonania`
  account (`GH_HOST=github.com gh auth switch --user Taimonania`). Never the personal
  account — it lacks push/merge rights.
- **Publishing is irreversible and public.** The `RELEASE_PUBLISH=1` env var gates it.
  Never set it until the dry run is clean and the user has authorized the publish.
- The signing identity (`Developer ID Application: Timo Angerer (Q353FAS349)`) and the
  notary keychain profile (`DeskLayouterNotary`) resolve automatically.

## Steps

### 1. Preflight
`make release-preflight` — reports every missing tool/credential at once. Fix before continuing.

### 2. Bump the version
Edit `App/Info.plist`: raise `CFBundleShortVersionString` (SemVer) and `CFBundleVersion`
(next integer). Nothing else needs editing to change the version.

### 3. Write the release notes
Draft `RELEASE_NOTES.md` from what shipped since the last tag. It MUST keep the two
sections `## Highlights` (user-facing changes) and `## Notes` (platform/signing facts);
the publish step refuses without them. Gather the changes:
```sh
last=$(GH_HOST=github.com gh release view --repo Taimonania/desk-layouter --json tagName -q .tagName)
git log --oneline "$last"..HEAD
GH_HOST=github.com gh pr list --repo Taimonania/desk-layouter --state merged \
  --search "merged:>$(git log -1 --format=%aI "$last")" --json number,title
```
One line per real change; honest and concise. Done when `RELEASE_NOTES.md` has both
`## Highlights` and `## Notes` and every change since `$last` is represented in one of them.

### 4. Dry run (no publish)
```sh
make release
```
Builds (universal) → signs inside-out → notarizes → staples → generates the signed
appcast, then runs local verification. Emits the `.dmg`, `.zip`, and `appcast.xml`
under `.build/release/` but publishes nothing. Notarization needs the network and takes
a few minutes. Done when notarization reports `status: Accepted` and the `.dmg`, `.zip`,
and `appcast.xml` all exist under `.build/release/`.

### 5. Publish (irreversible — requires the user's authorization)
```sh
RELEASE_PUBLISH=1 make release
```
Creates the GitHub Release (uploads `.dmg` + `.zip`), then pushes `appcast.xml` to the
`gh-pages` branch (a throwaway clone, plain push, never touches `main`).

- **First release ever only:** enable GitHub Pages once (Settings → Pages → Deploy from
  branch → `gh-pages` / `(root)`). Already enabled for this repo.
- **Pages-rebuild race (expected):** after the push, GitHub Pages takes ~30–120s to
  serve the new `appcast.xml`. `make release` runs its `verify` step immediately, so it
  can fail *only* on the appcast-availability check while Pages is still rebuilding. That
  specific failure is not a real problem — re-assert in step 6 once the feed is live.
  Any other failure is real.

### 6. Verify availability
Poll the feed until Pages has rebuilt, then assert everything:
```sh
until [ "$(curl -sI -o /dev/null -w '%{http_code}' https://taimonania.github.io/desk-layouter/appcast.xml)" = 200 ]; do sleep 10; done
make verify-release
```
`verify-release` asserts, against observable reality: locally — `codesign --verify
--strict --deep`, Developer ID authority, hardened runtime, Gatekeeper (`spctl`), a
stapled ticket; and availability — every published asset URL returns 200, the downloaded
`.dmg` checksum matches the local artifact, the appcast returns 200 and parses, its newest
`<enclosure>` carries a non-empty `sparkle:edSignature`, and that enclosure URL returns 200.

### 7. Confirm
Report the release URL and that existing installs will now be offered the update.

## When the signing/update mechanism changes — not a normal release step
If the Developer ID identity, bundle id, designated requirement, or major Sparkle
version changes, re-run the one-shot harness proving the Accessibility grant survives an
update: `make update-arm` → (human) grant Accessibility to the installed test app and let
Sparkle install N+1 → `make update-verify`; `make update-restore` cleans up. See issue
#47. This is deliberately excluded from normal releases and from CI.
