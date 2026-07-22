.PHONY: build run relaunch test test-desktop-placement benchmark-picker \
	multi-display-arm multi-display-verify multi-display-restore \
	unavailable-display-arm unavailable-display-external-disconnected \
	unavailable-display-external-reconnected unavailable-display-lid-closed \
	unavailable-display-lid-open unavailable-display-restore \
	session-boundary-arm session-boundary-verify session-boundary-restore \
	update-arm update-verify update-restore \
	release release-preflight release-notes release-appcast verify-release

build:
	./Scripts/build-app.sh

run: build
	open ".build/Desk Layouter.app"

# Quit any running instance first, then rebuild and launch. Use this after code
# changes: plain `run` won't replace an already-running menu-bar instance.
relaunch: build
	-pkill -x DeskLayouter
	open ".build/Desk Layouter.app"

test:
	swift run DeskLayouterPlannerTests
	swift run DeskLayouterBoardTests
	swift run DeskLayouterPresetTests
	swift run DeskLayouterPresetSwitchTests
	swift run DeskLayouterPresetEditingTests
	swift run DeskLayouterPresetStartupTests
	swift run DeskLayouterLayoutTests
	swift run DeskLayouterLayoutEditorTests
	swift run DeskLayouterConfigStoreTests
	swift run DeskLayouterPickerTests
	swift run DeskLayouterReconcilerTests
	swift run DeskLayouterAdapterFailureTests
	swift run DeskLayouterDisplayTests
	swift run DeskLayouterMultiDisplayTests
	swift run DeskLayouterMigrationTests
	swift run DeskLayouterArrangeTests
	swift run DeskLayouterArrangePlanTests
	swift run DeskLayouterTransitionTests
	swift run DeskLayouterActiveDesktopTests
	swift run DeskLayouterArrangeReportTests
	swift run DeskLayouterDisplayNameTests
	swift run DeskLayouterMenuBarTests
	swift run DeskLayouterUnavailableTests
	swift run DeskLayouterUnavailableDisplayTests
	swift run DeskLayouterVersionTests
	swift run DeskLayouterChangelogTests
	swift run DeskLayouterAppStateTests
	swift run DeskLayouterWelcomeTourTests
	swift run DeskLayouterWhatsNewTests

test-desktop-placement:
	./Scripts/verify-desktop-placement.sh

# Human-gated transactional issue #22 harness. `arm` verifies placement and
# Layout on both built-in + external Displays under the current Main role. Change
# Main in System Settings, then run `verify`; `restore` is safe standalone.
multi-display-arm:
	./Scripts/verify-multi-display.sh arm

multi-display-verify:
	./Scripts/verify-multi-display.sh verify

multi-display-restore:
	./Scripts/verify-multi-display.sh restore

# Human-gated transactional issue #23 harness. Start with the laptop open and
# one external extended Display connected, then follow each phase's prompt.
unavailable-display-arm:
	./Scripts/verify-unavailable-display.sh arm

unavailable-display-external-disconnected:
	./Scripts/verify-unavailable-display.sh external-disconnected

unavailable-display-external-reconnected:
	./Scripts/verify-unavailable-display.sh external-reconnected

unavailable-display-lid-closed:
	./Scripts/verify-unavailable-display.sh lid-closed

unavailable-display-lid-open:
	./Scripts/verify-unavailable-display.sh lid-open

unavailable-display-restore:
	./Scripts/verify-unavailable-display.sh restore

# Repeatable input-to-results diagnostic for issue #89. It measures in-memory
# filtering, row presentation, and icon lookup separately over a 240-app catalog.
benchmark-picker:
	swift run -c release DeskLayouterPickerBenchmark

# Two-phase, human-gated session-boundary compatibility harness (issue #8).
# Run `arm`, then log out / reboot yourself, then `verify` from a different
# Desktop. `restore` is transactional and idempotent.
session-boundary-arm:
	./Scripts/verify-session-boundary.sh arm

session-boundary-verify:
	./Scripts/verify-session-boundary.sh verify

session-boundary-restore:
	./Scripts/verify-session-boundary.sh restore

# Human-gated, run-once mechanism-validation harness (issue #47): proves a
# stable Developer ID identity keeps the Accessibility (TCC) grant alive across
# a Sparkle auto-update. NOT part of `make test`/CI — re-run only when the
# signing/Sparkle/OS-TCC mechanism changes. Run `update-arm`, then (as a human)
# grant Accessibility to the installed test app and let Sparkle install N+1, then
# `update-verify`. `update-restore` is transactional and idempotent.
update-arm:
	./Scripts/verify-update.sh arm

update-verify:
	./Scripts/verify-update.sh verify

update-restore:
	./Scripts/verify-update.sh restore

# Release pipeline (issues #44, #46). `release-preflight` checks tools +
# credentials and publishes nothing. `release-notes` prints the exact GitHub
# release notes for the current version (for review before publishing) and
# publishes nothing. `release` builds → signs → notarizes →
# staples → generates the EdDSA-signed Sparkle appcast locally; it publishes to
# GitHub Releases and deploys the appcast to GitHub Pages only when
# RELEASE_PUBLISH=1. `release-appcast` runs just the zip+appcast stage against an
# already-built/signed app (handy for iterating on the feed). `verify-release`
# asserts the local artifact and, once published, its public availability
# (assets + the signed appcast at SUFeedURL). Manual prerequisites (Developer ID
# cert, notary credential, create-dmg, enabling GitHub Pages) are documented in
# docs/releasing.md.
release-preflight:
	./Scripts/release.sh preflight

release-notes:
	@./Scripts/release.sh notes

release:
	./Scripts/release.sh all

release-appcast:
	./Scripts/release.sh appcast

verify-release:
	./Scripts/release.sh verify
