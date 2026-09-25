#!/usr/bin/env bash
# Package an existing signed app; never build, install, re-sign, or notarize it.
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: package_local_dmg.sh APP OUTPUT.dmg LICENSE" >&2
  exit 2
fi
app_path="$1"
output="$2"
license_path="$3"
if [[ "$output" != *.dmg || -e "$output" || -L "$output" ]]; then
  echo "error: output must be a new .dmg path: $output" >&2
  exit 2
fi
if [[ ! -d "$app_path" || ! -f "$license_path" ]]; then
  echo "error: a completed app and license file are required" >&2
  exit 2
fi
identifier="$(plutil -extract CFBundleIdentifier raw -o - "$app_path/Contents/Info.plist")"
if [[ "$identifier" != com.typewhisper.mac ]]; then
  echo "error: unexpected app bundle identifier: $identifier" >&2
  exit 2
fi
codesign --verify --deep --strict "$app_path"

output_parent="$(dirname "$output")"
mkdir -p "$output_parent"
# Stage on the output filesystem so publication can be atomic and no-clobber.
stage_root="$(mktemp -d "$output_parent/.typewhisper-dmg.XXXXXX")"
trap 'rm -rf "$stage_root"' EXIT
mkdir "$stage_root/payload"
ditto "$app_path" "$stage_root/payload/TypeWhisper.app"
codesign --verify --deep --strict "$stage_root/payload/TypeWhisper.app"
ln -s /Applications "$stage_root/payload/Applications"
cp "$license_path" "$stage_root/payload/LICENSE.txt"

hdiutil create -volname "TypeWhisper" -srcfolder "$stage_root/payload" \
  -fs HFS+ -format UDZO "$stage_root/package.dmg"
hdiutil verify "$stage_root/package.dmg"
ln "$stage_root/package.dmg" "$output"
printf 'DMG: %s\n' "$output"
shasum -a 256 "$output"
echo "Local package only: the existing app signature is preserved; no notarization is performed."
