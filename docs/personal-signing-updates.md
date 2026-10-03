# Personal signing and Sparkle updates

This feature replaces upstream's update feed/key in personal builds. It does
not change the bundle identifier or claim upstream signing credentials.

## Local Apple signing

The dev build now honors a non-empty, gitignored `CodeSigning.local.xcconfig`,
adapted from [CarbonoDev/typewhisper-mac#1](https://github.com/CarbonoDev/typewhisper-mac/pull/1).
For example, after adding your Apple account and certificate in Xcode:

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
CODE_SIGN_IDENTITY = Apple Development
```

Run `scripts/build-dev-local.sh`. With this file present, Xcode uses the signing
configuration and can update provisioning. Without it, the old unsigned/ad-hoc
path remains available. Invalid signing configuration fails rather than silently
falling back. A consistent identity helps retain macOS permissions and Keychain
access; actual retention must be checked on the Mac using that identity.

The build marker is now beside the app, at
`~/Applications/TypeWhisper-Dev.app.build-source.txt`. Writing it inside the app
after signing invalidated the signature. Configured builds verify the copied
app's signature before reporting success.

## Personal update configuration

`SUFeedURL` and `SUPublicEDKey` now come from build settings:

- `TYPEWHISPER_PERSONAL_UPDATE_FEED_URL` defaults to
  `https://abhinavm24.github.io/typewhisper-mac/appcast.xml`.
- `TYPEWHISPER_PERSONAL_UPDATE_PUBLIC_KEY` defaults to empty.

The updater stays disabled until the URL is HTTPS and the public key is a
valid 32-byte base64 value. Upstream's feed and known public key are rejected.
Manual checks and resetting the update cycle are also gated. This prevents an
unconfigured personal build from fetching an upstream replacement.
The separate `.dev` app also leaves updates off because this feed distributes
the Release app, whose bundle identifier is different.

Local build settings can be placed in `CodeSigning.local.xcconfig`; CI supplies
public settings through repository variables. Private keys never go into the app.

## Opt-in CI feed publication

Feature PRs are assembled into app builds, but trusted workflow scripts are read
from **main**. The workflow changes in this PR must reach main before the new
signing/feed job can run. Leaving the PR open builds the app-side changes with
updates disabled; it does not activate credentials or publish a feed by itself.

After the trusted CI changes reach main:

1. Generate your own Sparkle key on a trusted Mac using the hash-verified Sparkle
   tools from `scripts/prepare_release_tools.py`. Use `generate_keys --account
   typewhisper-personal`; keep this account/key stable for future updates.
2. Set repository variable `PERSONAL_UPDATE_PUBLIC_KEY` to its public key. Export
   the private key outside this checkout using Sparkle's `generate_keys -x`, and
   store it as Actions secret `PERSONAL_SPARKLE_PRIVATE_KEY`. Do not commit it.
3. Set repository variable `PERSONAL_UPDATES_ENABLED` to `true`. Optionally set
   `PERSONAL_UPDATE_FEED_URL` when hosting the feed somewhere other than the
   default URL. The standard publishing job writes the `personal-updates` branch.
4. Run CI. Each app receives an increasing `CFBundleVersion` composed of the
   workflow run number and attempt. App tests, SDK tests and DMG verification
   still gate the Release. A separate trusted macOS job downloads that published
   DMG, compares it with the tested artifact, signs it, verifies the signature
   against the app's public key, and commits `appcast.xml` to `personal-updates`.
5. Configure GitHub Pages with **GitHub Actions** as its publishing source.
   The workflow explicitly uploads/deploys the appcast using the Pages actions;
   a GITHUB_TOKEN branch push alone does not trigger Pages. `personal-updates`
   retains feed history and prevents version rollback. Verify the public appcast
   URL works before installing the first update-enabled build.
6. Install that first build manually with `make update`. It contains your feed
   URL and key. A later successful CI build can then be offered through Sparkle.

Feed publication is serial and rejects older build numbers or a different
archive reusing the same build number. Tags/assets remain immutable; the appcast
branch is the mutable pointer to the newest signed personal update. The feed has
no Sparkle channel filter, so GitHub's prerelease label does not hide it from the
app's stable update preference. Normal Sparkle automatic-update preferences
remain under user control.

## Apple release signing is a separate next step

The CI DMG is still ad-hoc signed in this PR. Sparkle EdDSA authenticates the
download; it does not provide Apple Developer ID signing or notarization.
Importing a Developer ID certificate into an isolated CI keychain, re-signing
the app and Sparkle helpers, notarizing/stapling, and validating macOS permission
retention remain follow-up work once that certificate/account is available.
Local `make update` already supports optional re-signing with an installed Apple
Development identity. A genuine app-to-app Sparkle upgrade also needs a manual
two-build test after keys and Pages are configured.

## Checks

```sh
python3 scripts/test_dev_signing.py
python3 scripts/test_personal_appcast.py
swift scripts/verify_personal_update.swift --self-test
bash -n scripts/build-dev-local.sh .github/personal-integration/publish-feed.sh
actionlint .github/workflows/personal-integration.yml
xcodebuild test -skipPackagePluginValidation -project TypeWhisper.xcodeproj \
  -scheme TypeWhisper -destination 'platform=macOS,arch=arm64' \
  -only-testing:TypeWhisperTests/PersonalUpdateConfigurationTests \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```
