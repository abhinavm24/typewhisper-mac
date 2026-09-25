# Personal integration builds

This fork builds a personal app from `main` plus **all open PRs targeting this
fork's `main`**, including drafts. PRs remain open. Their code is never merged
into main by this workflow. Only owner-authored, same-repository PRs run
automatically; an unexpected external PR stops assembly for review.

Push changes to a source PR branch to queue a build. Main pushes and PR
opening/reopening/closing/retargeting also recompute the combination. Branches
without an open PR are ignored. `personal-integration` is generated output:
make fixes in the source PR, never directly on that branch.

Every day at 02:17 UTC (07:47 India time), the workflow merges upstream main
into fork main, preserving the fork's CI files, then builds the open PRs. A
manual run performs the same upstream sync:

```sh
gh workflow run personal-integration.yml --repo abhinavm24/typewhisper-mac --ref main
# Rebuild inputs that already have a successful release:
gh workflow run personal-integration.yml --repo abhinavm24/typewhisper-mac --ref main -f force=true
```

The workflow serializes runs. If a newer event arrives while a build is running,
the old run checks its inputs again before publishing; changed inputs prevent
promotion. The next queued run uses the current open PR set. Title-only changes
and other duplicate events skip work when those inputs already have a complete
published release. No external scheduler, PAT or Apple signing key is required.

## Releases and installation

Successful builds publish a prerelease in **this fork** with a unique
`personal-YYYYMMDD-HHMMSS-runID-attemptN` tag at the exact tested commit:

- `TypeWhisper-personal.dmg`
- `integration-manifest.json` (main, observed upstream, PR heads, merge results,
  exact candidate and Actions run)
- `SHA256SUMS`

App tests, plugin SDK tests, instrumentation/warning checks, the Release build
and DMG signature verification must pass before publication. Release tags and
assets are never overwritten. Old successful releases remain available for
rollback. These are prereleases, so use the personal release list rather than
GitHub's generic `releases/latest` URL. Actions artifacts are temporary transport;
Release assets are the durable installation source.

On the makefile source branch or a checkout of personal-integration:

```sh
make update
python3 scripts/update_personal.py --download-only
python3 scripts/update_personal.py --dry-run
```

The helper verifies downloads and re-signs locally with an existing Apple
Development identity when available. CI uses ad-hoc signing; this is not a
notarized upstream release, and ad-hoc updates can need fresh macOS permissions.
No app auto-update feed or Homebrew release is published by this workflow.

## Conflict and failure recovery

Assembly begins from current fork main each time, merges PRs by number, and
records commits already included through another PR's ancestry. Closing a PR
removes that direct input, but cannot remove code retained in another open PR.
Keep features independent when individual removal matters.

On a conflict, the run summary names the PR and files. Fix that source branch
and push it. Nothing is automatically resolved with ours/theirs. On build/test
failure, inspect the `personal-build-logs` artifact and repair the source PR.
The previous successful integration and release remain available.

Publishing uses a draft until all assets have been uploaded and verified. If
publication is interrupted, rerun the failed job: existing assets are compared,
and a completed branch promotion is recognized. A checksum mismatch is an error,
not an invitation to overwrite the release. If the inputs changed, start a fresh
workflow instead of publishing the old candidate.

## Keeping local main and upstream contributions clean

Main contains fork CI but no personal features. Sync it from your fork:

```sh
git fetch origin
git switch main
git merge --ff-only origin/main
```

Start upstream contributions from `upstream/main`, not the fork's CI-bearing
main. The existing upstream PR is independent of this integration workflow.

## Verification and maintenance

```sh
python3 -m unittest discover -s .github/personal-integration -p 'test_*.py' -v
bash -n .github/personal-integration/build.sh
actionlint .github/workflows/personal-integration.yml
```

Trusted assembly and publishing run on separate Linux runners. Candidate app
code runs only on the macOS build runner with a read-only token, no publishing
secrets, no persistent checkout credentials and no shared build cache. Publishing
uses the assembly artifact and trusted main script, not files produced by PR code.

Disable inherited duplicate/release/registry workflows through repository
settings rather than deleting upstream YAML. Keep CodeQL and secret scanning.
Review newly introduced upstream workflows when necessary. To roll back the
automation, disable `personal-integration.yml` and re-enable `build.yml`; source
PRs and published releases remain intact.
