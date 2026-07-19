.PHONY: build run test test-desktop-placement

build:
	./Scripts/build-app.sh

run: build
	open ".build/Desk Layouter.app"

test:
	swift run DeskLayouterPlannerTests

test-desktop-placement:
	./Scripts/verify-desktop-placement.sh
