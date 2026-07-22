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

# App icon (issue #74). Info.plist's CFBundleIconFile ("AppIcon") resolves to
# Contents/Resources/AppIcon.icns; Finder and the Dock read it from there.
cp "$project_directory/App/AppIcon.icns" "$contents_directory/Resources/AppIcon.icns"

# Bundle CHANGELOG.md into Resources (issue #73) so the app can read the release
# highlights at runtime and show the What's-New screen after an upgrade. The
# unbundled `swift run` build has no Resources dir and reads nil (graceful
# fallback), so this is needed only for the packaged app.
cp "$project_directory/CHANGELOG.md" "$contents_directory/Resources/CHANGELOG.md"

# Embed Sparkle.framework. The executable links it as @rpath/Sparkle.framework,
# but SwiftPM only leaves it in the build directory, so a relocatable .app must
# carry its own copy under Contents/Frameworks and gain an rpath that points
# there. This is required for the app to launch at all (signed or not), so it is
# unconditional and does not depend on a signing identity. `cp -R` preserves the
# framework's version symlinks; `install_name_tool` adds the load path.
frameworks_directory="$contents_directory/Frameworks"
sparkle_source="$binary_directory/Sparkle.framework"
if [ -d "$sparkle_source" ]; then
	mkdir -p "$frameworks_directory"
	cp -R "$sparkle_source" "$frameworks_directory/"
	install_name_tool -add_rpath "@executable_path/../Frameworks" \
		"$contents_directory/MacOS/DeskLayouter"
else
	echo "build-app: Sparkle.framework not found at $sparkle_source" >&2
	exit 1
fi

# Re-sign Sparkle's nested helpers inside-out with the Developer ID identity and
# a hardened runtime, then the framework, then the app. This runs ONLY when a
# signing identity is provided via DEVELOPER_ID_APPLICATION (the release/sign
# path in Scripts/release.sh, which resolves and exports it). The default
# `make build` local-iteration flow leaves this unset and ships an un-signed app,
# even on a machine that happens to hold a Developer ID certificate. We sign each
# nested item explicitly (never --deep) so every code object gets its own
# hardened-runtime signature, which notarization requires. --timestamp matches
# release.sh's do_sign convention.
signing_identity="${DEVELOPER_ID_APPLICATION:-}"
if [ -n "$signing_identity" ]; then
	echo "build-app: re-signing Sparkle helpers inside-out with '$signing_identity'..."
	sparkle_versioned="$frameworks_directory/Sparkle.framework/Versions/B"

	sign() {
		codesign --force --options runtime --timestamp --sign "$signing_identity" "$1"
	}

	# 1) Innermost XPC services.
	for xpc in "$sparkle_versioned/XPCServices"/*.xpc; do
		[ -e "$xpc" ] && sign "$xpc"
	done
	# 2) The command-line Autoupdate helper and the Updater.app helper bundle.
	sign "$sparkle_versioned/Autoupdate"
	sign "$sparkle_versioned/Updater.app"
	# 3) The framework itself (sign the concrete version, not the symlinks).
	sign "$sparkle_versioned"
	# 4) The main executable, then 5) the outer app bundle.
	sign "$contents_directory/MacOS/DeskLayouter"
	sign "$app_bundle"

	codesign --verify --strict --verbose=2 "$app_bundle" \
		|| { echo "build-app: signature verification failed" >&2; exit 1; }
	echo "build-app: signed and verified OK"
fi

printf '%s\n' "$app_bundle"
