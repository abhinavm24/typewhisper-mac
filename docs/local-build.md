# Personal updates and local development

Source work happens in this checkout. Personal CI and installer tools live in the
separate `../typewhisper-ci` worktree of the same repository.

```sh
make -C ../typewhisper-ci sync-main
make -C ../typewhisper-ci release
make -C ../typewhisper-ci update

# Download without installing, or preview replacement of the installed app:
python3 ../typewhisper-ci/scripts/update_personal.py --download-only
python3 ../typewhisper-ci/scripts/update_personal.py --dry-run
```

The updater selects the newest complete `personal-` prerelease from
`abhinavm24/typewhisper-mac`, verifies its checksums and exact source commit, then
installs it. GitHub CLI and macOS tools are required; Xcode is not required for
updates. Downloads remain in `~/Downloads/TypeWhisper-Personal/`.

It prefers an existing Apple Development identity for local re-signing. Use
`--signing-identity -` for ad-hoc signing or specify an installed identity.
Run as your normal user; only app replacement may request sudo.

For local source builds, use upstream's `scripts/build-dev-local.sh` or
`scripts/build-release-local.sh`. The duplicate personal Makefile build,
packaging and cleanup wrappers have been removed.

See `docs/personal-integration.md` on personal-ci for setup and failure recovery.
