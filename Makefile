.PHONY: build run

build:
	./Scripts/build-app.sh

run: build
	open ".build/Desk Layouter.app"
