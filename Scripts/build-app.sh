#!/bin/sh

set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_directory=$(dirname -- "$script_directory")
configuration=${CONFIGURATION:-release}
app_bundle="$project_directory/.build/Desk Layouter.app"
contents_directory="$app_bundle/Contents"

swift build --package-path "$project_directory" --configuration "$configuration"
binary_directory=$(swift build --package-path "$project_directory" --configuration "$configuration" --show-bin-path)

rm -rf "$app_bundle"
mkdir -p "$contents_directory/MacOS" "$contents_directory/Resources"
cp "$binary_directory/DeskLayouter" "$contents_directory/MacOS/DeskLayouter"
cp "$project_directory/App/Info.plist" "$contents_directory/Info.plist"
plutil -lint "$contents_directory/Info.plist"

printf '%s\n' "$app_bundle"
