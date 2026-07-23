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
Add the new version's entry to `CHANGELOG.md`: a `## <version> — <date>` section
(the version matching the `CFBundleShortVersionString` you just bumped) with one
user-facing highlight bullet per real change. `CHANGELOG.md` is the single source
of release notes — the app bundles it for the What's-New screen, and the pipeline
derives this release's GitHub notes from the matching section (`preflight` and
`publish` both refuse without a non-empty entry). Gather the changes:
```sh
last=$(GH_HOST=github.com gh release view --repo Taimonania/desk-layouter --json tagName -q .tagName)
git log --oneline "$last"..HEAD
GH_HOST=github.com gh pr list --repo Taimonania/desk-layouter --state merged \
  --search "merged:>$(git log -1 --format=%aI "$last")" --json number,title
```

**Write for users, not developers.** Describe what changed from the user's point
of view — what they can now do, what feels better, what problem went away — not how
it was built. Skip implementation vocabulary (layout/column/widths/alignment/refactor,
class or component names, PR numbers) and internal-only changes (tooling, CI, release
plumbing, test-only work); if a change has no visible effect for the user, leave it
out. Prefer plain, concrete language over jargon.

**Format each highlight as a bold lead-in plus an explanation.** Start the bullet
with a short, punchy **bold** summary — a headline fragment, not a full grammatical
sentence (no trailing period on the bold part) — then follow with one or two plain
sentences explaining what it does. Pattern: `- **<fat summary>**. <sentence or two>`

- Example: `- **Enable more rows/columns for your Layout**. You can now pick a
  custom split count per axis in the Layout editor. Split into up to 9 columns or rows.`
- Bad (technical, no lead-in): "The Settings pane is now a capped left-aligned
  column with consistent section spacing; footer actions use count-stable equal widths."
- Good (fat lead-in + explanation): "**Cleaner, easier-to-scan Settings**. The
  Settings layout is more organized, and the editor's buttons now line up neatly and
  stay put instead of shifting around as you work."

One bullet per real, user-visible change; honest and concise. Done when `CHANGELOG.md`
has a `## <version> — <date>` section for the new version and every user-facing change
since `$last` is represented as a fat-lead-in highlight in it.

### 4. Dry run (no publish)
```sh
make release
```
Builds (universal) → signs inside-out → notarizes → staples → generates the signed
appcast, then runs local verification. Emits the `.dmg`, `.zip`, and `appcast.xml`
under `.build/release/` but publishes nothing. Notarization needs the network and takes
a few minutes. Done when notarization reports `status: Accepted` and the `.dmg`, `.zip`,
and `appcast.xml` all exist under `.build/release/`.

### 5. Preview the release notes and get approval (last changeable point)
Render the **exact** GitHub release notes that will be published and show them to
the user verbatim:
```sh
make release-notes
```
This prints what `publish` feeds to `gh release create` — the `## Highlights`
block derived from `CHANGELOG.md` — without building or publishing anything. Publishing (step 6) is the point of no return, so
this is the last moment the notes can change: to revise them, edit `CHANGELOG.md`
and re-run `make release-notes`. (Editing `CHANGELOG.md` after the dry run also
changes the What's-New content bundled into the app, so re-run the dry run in step
4 before publishing if you change it here.) **Wait for the user's explicit approval
of these notes before continuing to publish.**

### 6. Publish (irreversible — requires the user's authorization)
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
  specific failure is not a real problem — re-assert in step 7 once the feed is live.
  Any other failure is real.

### 7. Verify availability
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

### 8. Confirm
Report the release URL and that existing installs will now be offered the update.

## When the signing/update mechanism changes — not a normal release step
If the Developer ID identity, bundle id, designated requirement, or major Sparkle
version changes, re-run the one-shot harness proving the Accessibility grant survives an
update: `make update-arm` → (human) grant Accessibility to the installed test app and let
Sparkle install N+1 → `make update-verify`; `make update-restore` cleans up. See issue
#47. This is deliberately excluded from normal releases and from CI.
