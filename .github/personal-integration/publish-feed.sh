#!/usr/bin/env bash
# Trusted post-publication job only. Never execute scripts from candidate artifacts.
set -euo pipefail
control="$1"
source_artifacts="$2"
products="$3"
sign_update="$4"
: "${PERSONAL_SPARKLE_PRIVATE_KEY:?Configure the Sparkle private key secret}"
: "${PERSONAL_UPDATE_PUBLIC_KEY:?Configure the matching public key repository variable}"
temporary="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/personal-feed.XXXXXX")"
mounted=false
cleanup() {
  rm -f "$temporary/key"
  if [[ "$mounted" == true ]]; then hdiutil detach "$temporary/mounted" >/dev/null || true; fi
  rm -rf "$temporary"
}
trap cleanup EXIT
umask 077
printf '%s\n' "$PERSONAL_SPARKLE_PRIVATE_KEY" > "$temporary/key"
unset PERSONAL_SPARKLE_PRIVATE_KEY
python3 - "$temporary/key" <<'PY'
import base64, pathlib, sys
try:
    key = base64.b64decode(pathlib.Path(sys.argv[1]).read_text().strip(), validate=True)
    assert len(key) in (32, 64, 96)
except (ValueError, AssertionError):
    raise SystemExit("Invalid Sparkle private-key encoding or length")
PY

tag="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tag"])' "$source_artifacts/integration-manifest.json")"
repo=abhinavm24/typewhisper-mac
test "$(gh release view "$tag" --repo "$repo" --json isDraft --jq .isDraft)" = false
gh release download "$tag" --repo "$repo" --pattern TypeWhisper-personal.dmg --dir "$temporary"
cmp "$temporary/TypeWhisper-personal.dmg" "$products/TypeWhisper-personal.dmg"
mkdir "$temporary/mounted"
hdiutil attach -readonly -nobrowse -mountpoint "$temporary/mounted" "$temporary/TypeWhisper-personal.dmg"
mounted=true
plist="$temporary/mounted/TypeWhisper.app/Contents/Info.plist"
test "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$plist")" = "$PERSONAL_UPDATE_PUBLIC_KEY"
"$sign_update" "$temporary/TypeWhisper-personal.dmg" --ed-key-file "$temporary/key" > "$temporary/signature"
rm -f "$temporary/key"
# Verify the archive with the public key embedded in the app, before advertising it.
swift "$control/scripts/verify_personal_update.swift" \
  "$temporary/TypeWhisper-personal.dmg" "$temporary/signature" "$PERSONAL_UPDATE_PUBLIC_KEY"

git init -q "$temporary/feed"
git -C "$temporary/feed" remote add origin "https://github.com/$repo.git"
git -C "$temporary/feed" config user.name 'Abhinav Misra'
git -C "$temporary/feed" config user.email '4698976+abhinavm24@users.noreply.github.com'
git -C "$temporary/feed" config commit.gpgsign false
if [[ -n "$(git -C "$temporary/feed" ls-remote --heads origin personal-updates)" ]]; then
  git -C "$temporary/feed" fetch origin refs/heads/personal-updates
  git -C "$temporary/feed" checkout -b personal-updates FETCH_HEAD
else
  git -C "$temporary/feed" checkout --orphan personal-updates
fi
python3 "$control/scripts/personal_appcast.py" \
  --archive "$temporary/TypeWhisper-personal.dmg" --info-plist "$plist" \
  --manifest "$source_artifacts/integration-manifest.json" --signature "$temporary/signature" \
  --previous "$temporary/feed/appcast.xml" --output "$temporary/feed/appcast.xml"
touch "$temporary/feed/.nojekyll"
git -C "$temporary/feed" add appcast.xml .nojekyll
if ! git -C "$temporary/feed" diff --cached --quiet; then
  git -C "$temporary/feed" commit -m "Publish personal update $tag"
  git -C "$temporary/feed" -c credential.helper= -c 'credential.helper=!gh auth git-credential' push origin personal-updates
fi
mkdir -p "$products/appcast"
cp "$temporary/feed/appcast.xml" "$products/appcast/appcast.xml"
printf 'Prepared feed for %s; the Pages deployment step serves the signed update metadata.\n' "$tag"
