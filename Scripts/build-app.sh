#!/bin/sh

set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_directory=$(dirname -- "$script_directory")
configuration=${CONFIGURATION:-release}
app_bundle="$project_directory/.build/Desk Layouter.app"
contents_directory="$app_bundle/Contents"

# Optional universal build. `make build`/`run`/`relaunch` build single-arch for
# fast local iteration (default: whole package, unchanged); the release pipeline
# sets RELEASE_ARCHS="arm64 x86_64" to emit a universal binary that runs natively
# on Apple Silicon and Intel. In that mode we also restrict to the DeskLayouter
# product, because the multi-arch build routes through Xcode's stricter build
# system, which rejects the @main test executables' `main.swift` files. Arch
# names never contain spaces, so word-splitting the flag string is safe and keeps
# this POSIX-sh (bash 3.2) compatible without arrays.
build_flags=""
if [ -n "${RELEASE_ARCHS:-}" ]; then
	build_flags="--product DeskLayouter"
	for arch in $RELEASE_ARCHS; do
		build_flags="$build_flags --arch $arch"
	done
fi

# shellcheck disable=SC2086
swift build --package-path "$project_directory" --configuration "$configuration" $build_flags
# shellcheck disable=SC2086
binary_directory=$(swift build --package-path "$project_directory" --configuration "$configuration" $build_flags --show-bin-path)

rm -rf "$app_bundle"
mkdir -p "$contents_directory/MacOS" "$contents_directory/Resources"
cp "$binary_directory/DeskLayouter" "$contents_directory/MacOS/DeskLayouter"
cp "$project_directory/App/Info.plist" "$contents_directory/Info.plist"
plutil -lint "$contents_directory/Info.plist"

printf '%s\n' "$app_bundle"
