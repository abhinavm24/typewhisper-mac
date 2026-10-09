# Personal integration builds

This fork keeps `main` identical to upstream. Personal automation and installer
tools live on `personal-ci`; `personal-integration` is generated app source.
The repository's default branch remains `main`.

## One-time local setup

From the source checkout, create a separate worktree for the tools:

```sh
git fetch origin
git worktree add ../typewhisper-ci personal-ci
```

The migration already created this worktree on this Mac. It shares the source
repository's Git history and remotes; it is not another repository.

## Sync, release and install

```sh
# Or use GitHub's Sync fork button while viewing main.
make -C ../typewhisper-ci sync-main
# Update the local source checkout from remote main when needed.
git fetch origin
git merge --ff-only origin/main

make -C ../typewhisper-ci release
make -C ../typewhisper-ci release FORCE=true
make -C ../typewhisper-ci update
```

`sync-main` uses `gh repo sync --branch main` to fast-forward fork main on
GitHub. It never forces a divergent branch. Feature changes belong on source
branches with open PRs; never merge personal-ci or generated integration into main.

`release` requires a clean personal-ci worktree, fetches its remote branch,
fast-forwards it, then pushes an empty build-request commit. Only pushes to
personal-ci trigger the personal workflow. Source pushes, PR events and schedules
do not trigger it. Do not depend on a Run workflow button after removing the
workflow from default main. CI-tool changes pushed to personal-ci also request a
build. `FORCE=true` marks the request with `[force]`.

CI snapshots remote main and all open, owner-authored same-repository PRs
targeting main, including drafts. Branches without such a PR are ignored. It
merges PRs by number into a separate checkout; trusted CI code never enters the
app source through the control checkout. Unexpected external PRs stop assembly.
PRs remain open. Fix conflicts in the source PR, then request another build.

One run is active at a time; a new request cancels the previous run. App tests,
SDK tests, the App Store compile check and DMG packaging run in parallel.
Publication waits for every check. A changed main or PR set prevents publication.
A request with unchanged source and CI-tool trees reuses an existing complete
release unless forced. Empty request commits do not change the CI-tool tree.

## Releases and recovery

Successful runs publish an immutable prerelease in this repository at the exact
tested candidate, with a unique `personal-YYYYMMDD-HHMMSS-runID-attemptN` tag:

- `TypeWhisper-personal.dmg`
- `integration-manifest.json`: source main, selected PR heads, merge results,
  candidate, trusted CI commit/tree, observed upstream and Actions run
- `SHA256SUMS`

`make update` verifies downloads and uses an existing Apple Development identity
for local re-signing when available. CI uses ad-hoc signing, so macOS permissions
may need fresh grants. No certificate or PAT is needed for the normal CI build.
Optional Sparkle feed publication remains off until explicitly configured; see
`docs/personal-signing-updates.md` on personal-ci.

Previous successful releases remain available for rollback. Assembly/build failure
leaves them intact; inspect `personal-*-logs` Actions artifacts. A cancelled run
can leave a draft release, which the installer ignores. Retry publication through
Actions when its inputs still match, or request a fresh build. Existing assets are
verified rather than overwritten.

Closing a PR removes its direct input; code retained in another PR's ancestry
remains. Keep features independent when individual removal matters.
The generated integration branch is updated with an explicit lease only after
tests pass. Never edit it directly.

## Verification

```sh
make -C ../typewhisper-ci check
actionlint ../typewhisper-ci/.github/workflows/personal-integration.yml
```

Trusted assembly/publication use Linux runners; candidate code runs on separate
macOS runners with read-only tokens, no publishing secrets, no persistent checkout
credentials and no shared build cache. Publication executes the pinned CI revision.

Inherited upstream workflows remain disabled through repository settings. To stop
personal automation, disable personal-integration.yml. Source PRs, clean main and
published releases remain available.
