# Personal integration builds

This fork builds a personal app from `main` plus **all open PRs targeting this
fork's `main`**, including drafts. PRs remain open. Their code is never merged
into main by this workflow. Only owner-authored, same-repository PRs run
on request; an unexpected external PR stops assembly for review.

Releases run only on manual dispatch. There are no scheduled, push or PR-event
triggers. Push source changes, then request a build when you want a release.
Branches without an open PR are ignored. `personal-integration` is generated
output: make fixes in the source PR, never directly on that branch.

Sync upstream locally first so you can resolve conflicts before running CI.
From a clean checkout of `main`:

```sh
make sync-main
# Review the upstream merge, then push it:
git push origin main
# Request a tested personal release from remote main plus open PRs:
make release
# Rebuild inputs that already have a successful release:
make release FORCE=true
```

`make sync-main` fetches `origin/main` and `upstream/main`, fast-forwards local
main from origin, then merges upstream with a merge commit when needed. It
requires a clean main checkout and never pushes. If local main has diverged
from origin, it stops for a manual merge or rebase. Upstream conflicts stay in
your checkout: resolve them, `git add` the resolved files and `git commit`, or
cancel with `git merge --abort`. If main is checked out in another worktree,
run the command there.

`make release` requires an authenticated GitHub CLI (`gh auth login`). It
dispatches asynchronously on remote `main`; local unpushed changes are not
included. CI observes upstream but does not sync or update fork main. You can
also use the workflow's **Run workflow** button on GitHub. Follow the Actions
link printed by Make, then run `make update` after publication succeeds.

At most two runs are active, using alternating concurrency slots. Each new run
replaces the older run in its slot. App tests, SDK tests and DMG packaging run in
parallel within each run; release publishing remains serial. Inputs are checked again before publication;
changed inputs prevent promotion. The new run uses the current open PR set.
Repeated requests skip work when those inputs already have a complete
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

From a checkout of main or personal-integration:

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

On a PR conflict, the run summary names the PR and files. Fix that source branch
and push it, then run `make release` again. Nothing is automatically resolved with ours/theirs. On build/test
failure, inspect the `personal-*-logs` artifacts and repair the source PR.
The previous successful integration and release remain available.

Publishing uses a draft until all assets have been uploaded and verified. If
publication is interrupted, rerun the failed job: drafts are looked up by numeric release ID, existing assets are compared,
and a completed branch promotion is recognized. If another run already published
the same inputs, the duplicate publication is skipped. A checksum mismatch is an error,
not an invitation to overwrite the release. If the inputs changed, start a fresh
workflow instead of publishing the old candidate.

## Keeping local main and upstream contributions clean

Main contains fork CI and the download/install tooling, but no personal feature overrides. Sync it from your fork:

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
make test-sync-main
bash -n scripts/sync_main.sh
bash -n .github/personal-integration/build.sh
actionlint .github/workflows/personal-integration.yml
```

Trusted assembly and publishing run on separate Linux runners. Candidate app
code runs only on the macOS build runners with read-only tokens, no publishing
secrets, no persistent checkout credentials and no shared build cache. Publishing
uses the assembly artifact and trusted main script, not files produced by PR code.

Disable inherited duplicate/release/registry workflows through repository
settings rather than deleting upstream YAML. Keep CodeQL and secret scanning.
Review newly introduced upstream workflows when necessary. To roll back the
automation, disable `personal-integration.yml` and re-enable `build.yml`; source
PRs and published releases remain intact.
