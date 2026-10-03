#!/usr/bin/env bash
# Prepare upstream synchronization locally so conflicts can be resolved by hand.
set -euo pipefail

if [[ "$(git symbolic-ref --quiet --short HEAD || true)" != main ]]; then
  echo 'error: run make sync-main from a checkout of main (git switch main).' >&2
  exit 2
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo 'error: commit or stash local changes before running make sync-main.' >&2
  exit 2
fi
if git rev-parse --verify -q MERGE_HEAD >/dev/null ||
   [[ -d "$(git rev-parse --git-path rebase-merge)" ]] ||
   [[ -d "$(git rev-parse --git-path rebase-apply)" ]]; then
  echo 'error: finish or abort the current merge/rebase before syncing main.' >&2
  exit 2
fi

git fetch --no-tags origin main
git fetch --no-tags upstream main
if ! git merge --ff-only origin/main; then
  echo 'error: local main diverged from origin/main; merge or rebase it manually, then retry.' >&2
  exit 1
fi
if ! git merge --no-ff --no-edit upstream/main; then
  printf '%s\n' \
    'Upstream merge stopped. Inspect git status and resolve any conflicts, then git add and git commit.' \
    'To cancel the merge, run git merge --abort.' >&2
  exit 1
fi
printf '%s\n' \
  'Main is synced locally. Review the changes, then git push origin main.' \
  'When you want a personal release, run make release.'
