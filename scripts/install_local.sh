#!/usr/bin/env bash
set -euo pipefail

source_path=""
destination="/Applications/TypeWhisper.app"
dry_run=false
skip_quit=false

validate_app() {
  local app_path="$1"
  local info_plist="$app_path/Contents/Info.plist"
  local bundle_identifier
  local bundle_executable
  local executable_path

  if [[ ! -f "$info_plist" ]]; then
    echo "error: app is missing Contents/Info.plist: $app_path" >&2
    return 1
  fi
  bundle_identifier="$(plutil -extract CFBundleIdentifier raw -o - "$info_plist" 2>/dev/null || true)"
  bundle_executable="$(plutil -extract CFBundleExecutable raw -o - "$info_plist" 2>/dev/null || true)"
  if [[ "$bundle_identifier" != "com.typewhisper.mac" ||
        "$bundle_executable" != "TypeWhisper" ]]; then
    echo "error: app has unexpected bundle metadata: $app_path" >&2
    return 1
  fi
  executable_path="$app_path/Contents/MacOS/$bundle_executable"
  if [[ ! -x "$executable_path" ]] ||
     ! file "$executable_path" | grep -q 'Mach-O'; then
    echo "error: app does not contain a runnable Mach-O executable: $app_path" >&2
    return 1
  fi
  if ! codesign --verify --deep --strict "$app_path"; then
    echo "error: app does not have a valid local code signature: $app_path" >&2
    return 1
  fi
}

report_signing_identity() {
  local app_path="$1"
  local signature_details
  local authority

  signature_details="$(codesign -dvv "$app_path" 2>&1)"
  if grep -q '^Signature=adhoc$' <<< "$signature_details"; then
    echo "warning: source app uses ad-hoc signing" >&2
    echo "warning: installing a changed build may reset microphone and Accessibility grants" >&2
    echo "warning: use 'make install' with an Apple Development certificate for stable identity" >&2
    return
  fi

  authority="$(sed -n 's/^Authority=//p' <<< "$signature_details" | head -n 1)"
  echo "signing identity: ${authority:-certificate-backed signature}"
}

usage() {
  cat <<'USAGE'
Usage: scripts/install_local.sh --source APP [options]

Replace an installed TypeWhisper app with a locally built app bundle.

Options:
  --source APP       Built TypeWhisper.app bundle to install (required)
  --destination APP  Installation path (default: /Applications/TypeWhisper.app)
  --dry-run          Validate and print the replacement without changing files
  --skip-quit        Do not check for or quit a running TypeWhisper process
  -h, --help         Show this help

Examples:
  scripts/install_local.sh --source build/Build/Products/Release/TypeWhisper.app
  scripts/install_local.sh --source build/TypeWhisper.app --dry-run
  scripts/install_local.sh --source build/TypeWhisper.app \
    --destination "$HOME/Applications/TypeWhisper.app"
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source) source_path="${2:-}"; shift 2 ;;
    --destination) destination="${2:-}"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    --skip-quit) skip_quit=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$source_path" ]]; then
  echo "error: --source is required" >&2
  echo "example: scripts/install_local.sh --source build/Build/Products/Release/TypeWhisper.app" >&2
  exit 2
fi
if [[ ! -d "$source_path" ]]; then
  echo "error: built app not found: $source_path" >&2
  exit 2
fi
validate_app "$source_path"
report_signing_identity "$source_path"
if [[ "$destination" != *.app || "$destination" == "/" ]]; then
  echo "error: destination must be an .app path: $destination" >&2
  exit 2
fi

echo "source: $source_path"
echo "destination: $destination"
if [[ "$dry_run" == true ]]; then
  echo "dry-run: no files changed"
  exit 0
fi

if [[ "$skip_quit" == false ]] && pgrep -x TypeWhisper >/dev/null; then
  osascript -e 'tell application "TypeWhisper" to quit' >/dev/null 2>&1 || true
  for _ in {1..20}; do
    if ! pgrep -x TypeWhisper >/dev/null; then
      break
    fi
    sleep 0.25
  done
  if pgrep -x TypeWhisper >/dev/null; then
    echo "error: TypeWhisper is still running; quit it and retry" >&2
    exit 1
  fi
fi

destination_parent="$(dirname "$destination")"
destination_name="$(basename "$destination")"
mkdir -p "$destination_parent"
stage_root="$(mktemp -d "$destination_parent/.typewhisper-install.XXXXXX")"
staged_app="$stage_root/$destination_name"
backup_path="$destination_parent/.typewhisper-backup.${stage_root##*.}"

cleanup() {
  local exit_status=$?
  trap - EXIT

  if [[ -e "$backup_path" && ! -e "$destination" ]]; then
    if ! mv "$backup_path" "$destination"; then
      echo "error: original app remains at $backup_path" >&2
    fi
  fi
  rm -rf "$stage_root"
  exit "$exit_status"
}
trap cleanup EXIT

ditto "$source_path" "$staged_app"
validate_app "$staged_app"

if [[ -e "$destination" ]]; then
  mv "$destination" "$backup_path"
fi

if mv "$staged_app" "$destination"; then
  rm -rf "$backup_path"
else
  if [[ -e "$backup_path" && ! -e "$destination" ]]; then
    mv "$backup_path" "$destination"
  fi
  echo "error: failed to install app at $destination" >&2
  exit 1
fi

echo "installed: $destination"

