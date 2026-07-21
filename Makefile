.PHONY: build run relaunch test test-desktop-placement \
	session-boundary-arm session-boundary-verify session-boundary-restore

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
	swift run DeskLayouterLayoutTests
	swift run DeskLayouterLayoutEditorTests
	swift run DeskLayouterConfigStoreTests
	swift run DeskLayouterPickerTests
	swift run DeskLayouterReconcilerTests
	swift run DeskLayouterAdapterFailureTests
	swift run DeskLayouterDisplayTests
	swift run DeskLayouterArrangeTests
	swift run DeskLayouterArrangePlanTests
	swift run DeskLayouterArrangeReportTests
	swift run DeskLayouterMenuBarTests

test-desktop-placement:
	./Scripts/verify-desktop-placement.sh

# Two-phase, human-gated session-boundary compatibility harness (issue #8).
# Run `arm`, then log out / reboot yourself, then `verify` from a different
# Desktop. `restore` is transactional and idempotent.
session-boundary-arm:
	./Scripts/verify-session-boundary.sh arm

session-boundary-verify:
	./Scripts/verify-session-boundary.sh verify

session-boundary-restore:
	./Scripts/verify-session-boundary.sh restore
