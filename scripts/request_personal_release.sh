#!/usr/bin/env bash
# Request CI without changing main or the caller's source checkout.
set -euo pipefail
force="${1:-false}"
if [[ $# -gt 1 || ( "$force" != true && "$force" != false ) ]]; then
  echo 'usage: request_personal_release.sh [true|false]' >&2
  exit 2
fi
repo_root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$repo_root"
if [[ "$(git branch --show-current)" != personal-ci ]]; then
  echo 'error: run make release from the personal-ci worktree' >&2
  exit 2
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo 'error: commit or stash changes in personal-ci before requesting a release' >&2
  exit 2
fi
git fetch origin personal-ci
git merge --ff-only FETCH_HEAD
message='ci: request personal release'
if [[ "$force" == true ]]; then message+=' [force]'; fi
git -c commit.gpgsign=false commit --allow-empty -m "$message"
git push origin HEAD:refs/heads/personal-ci
printf '%s\n' 'Personal CI requested: https://github.com/abhinavm24/typewhisper-mac/actions' 'After publication succeeds, run make update.'
