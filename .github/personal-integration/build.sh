#!/usr/bin/env bash
# Run on a read-only, secret-free macOS build runner.
set -euo pipefail
source_dir="$1"
products="$2"
mkdir -p "$products"
cd "$source_dir"
common=(-skipPackagePluginValidation -project TypeWhisper.xcodeproj -scheme TypeWhisper
  -derivedDataPath build-personal CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO)

for attempt in 1 2 3; do
  if xcodebuild -resolvePackageDependencies "${common[@]}" > "$products/packages.log" 2>&1; then break; fi
  if [[ "$attempt" == 3 ]]; then cat "$products/packages.log"; exit 1; fi
  sleep 10
done
bash scripts/check_release_binary_instrumentation.sh --self-test
xcodebuild test "${common[@]}" -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO | tee "$products/app-tests.log"
bash scripts/check_first_party_warnings.sh "$products/app-tests.log"
swift test --package-path TypeWhisperPluginSDK 2>&1 | tee "$products/sdk-tests.log"
if [[ -f scripts/test_install_local.py ]]; then python3 scripts/test_install_local.py; fi
if [[ -f scripts/test_update_personal.py ]]; then python3 scripts/test_update_personal.py; fi
xcodebuild build "${common[@]}" -configuration Release -destination 'generic/platform=macOS' \
  ENABLE_CODE_COVERAGE=NO | tee "$products/build.log"
bash scripts/check_first_party_warnings.sh "$products/build.log"
app="$source_dir/build-personal/Build/Products/Release/TypeWhisper.app"
bash scripts/check_release_binary_instrumentation.sh "$app/Contents/MacOS/typewhisper-cli"
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"

# A plain drag-to-Applications DMG avoids upstream release credentials and tooling.
stage="$(mktemp -d "${TMPDIR:-/tmp}/typewhisper-dmg.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/TypeWhisper.app"
cp LICENSE "$stage/LICENSE"
ln -s /Applications "$stage/Applications"
hdiutil create -volname 'TypeWhisper Personal' -srcfolder "$stage" -ov -format UDZO "$products/TypeWhisper-personal.dmg"
hdiutil verify "$products/TypeWhisper-personal.dmg"
