.PHONY: build run test test-desktop-placement

build:
	./Scripts/build-app.sh

run: build
	open ".build/Desk Layouter.app"

test:
	swift run DeskLayouterPlannerTests
	swift run DeskLayouterConfigStoreTests

test-desktop-placement:
	./Scripts/verify-desktop-placement.sh
