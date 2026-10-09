# Workflow Voice Editing verification

Automated tests cover session ownership, cancellation during startup/generation, late-result suppression, workflow routing and prompt composition, empty/oversized output, selection snapshots with Unicode, Copy-only capture, single-attempt replacement, timeout, prepared Bluetooth cleanup, editor validation, and backup preservation. The review panel is rendered at minimum, narrow, short, and normal sizes by the focused tests.

```sh
xcodebuild test -skipPackagePluginValidation \
  -project TypeWhisper.xcodeproj -scheme TypeWhisper \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  -derivedDataPath /tmp/typewhisper-workflow-voice-editing-derived \
  -only-testing:TypeWhisperTests/WorkflowVoiceEditingTests \
  -only-testing:TypeWhisperTests/WorkflowServiceTests \
  -only-testing:TypeWhisperTests/PromptPaletteControllerTests \
  -only-testing:TypeWhisperTests/SettingsBackupExporterTests \
  -only-testing:TypeWhisperTests/HotkeyServiceCompatibilityTests \
  -only-testing:TypeWhisperTests/AudioRecorderViewModelTests \
  -only-testing:TypeWhisperTests/AudioEngineRecoverySupportTests \
  -only-testing:TypeWhisperTests/SnippetServiceTests \
  -only-testing:TypeWhisperTests/CloudFolderSyncTests \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=branch.sort GIT_CONFIG_VALUE_0=refname \
  bash scripts/pr-preflight.sh origin/LLM-transform
git diff --check origin/LLM-transform
```

Hardware and Accessibility checks still require a signed installed app with permissions:

1. Create a custom “Voice edit selected text” workflow with the voice-edit option and no saved prompt. Select an email, invoke its shortcut, say “make this shorter”, finish, review, and Replace.
2. Enable the option on an “Improve email” workflow with a saved prompt. Confirm the Workflow Palette captures the source before taking focus. Add a spoken instruction and confirm the saved provider/model settings are used. Repeat with Use saved prompt, and with the inherited global fallback list.
3. Change the original field, selection, document, or app while the review is visible. Replace must refuse a changed target; Copy remains available. Test Unicode selections and copy-only fields in Chromium/Electron apps.
4. Cancel during microphone startup, recording, transcription, and generation. No late result may appear or replace text. The main dictation and Recorder cannot acquire the microphone during the workflow session.
5. Enable Faster Bluetooth start and invoke voice editing on a Bluetooth headset. Finish or cancel and confirm the microphone indicator and headset call-quality audio stop. Disable Faster Bluetooth start or select another microphone afterward; no idle workflow stream should remain active.
6. Export/import settings and confirm workflow prompts and the voice-edit option survive. Sync ordinary snippets with an older client; no voice-edit instructions should appear as dictation expansions.
7. Check the workflow editor and review panel at minimum and normal window sizes, including long prompts/results and German labels. Replace and Copy must remain visible and keyboard accessible.
