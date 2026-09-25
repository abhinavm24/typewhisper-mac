# Personal updates and local development

The normal update path downloads a tested personal prerelease from
`abhinavm24/typewhisper-mac`. It does not select/merge branches or require Xcode.

```sh
make update
# Or download without changing the installed app:
python3 scripts/update_personal.py --download-only
# Validate the installation without replacing the installed app:
python3 scripts/update_personal.py --dry-run
```

The helper selects the newest complete published `personal-` prerelease, verifies
DMG and manifest checksums and the tag's exact source commit, then installs it.
Drafts, incomplete releases and upstream version tags are ignored. GitHub CLI (`gh`)
and macOS tools are required. Downloads remain in `~/Downloads/TypeWhisper-Personal/`.

By default it re-signs the downloaded app with an existing Apple Development
identity when available. Use `--signing-identity -` for ad-hoc signing or specify
an installed identity explicitly. No certificate is uploaded to CI. Ad-hoc updates
can require fresh microphone/Accessibility grants. Run as your normal user; the
helper requests sudo only when the app destination is not writable.

Feature code belongs on its source PR branch. The GitHub integration workflow
combines every open PR targeting this fork's main. Do not edit its generated
`personal-integration` branch. See `docs/personal-integration.md` on fork main for
CI controls, failure recovery and release details.

## Optional local fallback

```sh
make build       # Build/sign locally
make check       # App, SDK and installer checks
make install     # Install that completed local build
make dmg         # Package that completed local build
make clean       # Remove the marked local build directory
```

`make update-local` is a compatibility alias for `make update`. The old interactive
branch selection, rebasing, resume state and dated build branches have been removed.
