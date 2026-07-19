.PHONY: build run test

build:
	./Scripts/build-app.sh

run: build
	open ".build/Desk Layouter.app"

test:
	swift run DeskLayouterPlannerTests
