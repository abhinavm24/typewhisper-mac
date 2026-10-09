# Workflow Voice Editing

This replaces the standalone Transform proposal in PR #1355. It implements the required product direction in [the maintainer's comment](https://github.com/TypeWhisper/typewhisper-mac/pull/1355#issuecomment-5773460346) and addresses [the functional review](https://github.com/TypeWhisper/typewhisper-mac/pull/1355#pullrequestreview-5275677663).

## User flow

1. Create or edit an LLM workflow in Settings → Workflows, and enable **Voice edit selected text**. A custom workflow may have no saved instruction; existing templates such as Email Reply keep their saved prompt and fine-tuning.
2. Keep the manual Workflow Palette trigger, or configure an existing **Process Selected Text** shortcut. Voice editing requires an explicit invocation rather than app, website, or global dictation matching.
3. Select source text in the original app, then invoke the workflow. The host captures the source before opening any panel.
4. Speak an instruction to supplement the saved prompt. Press the same workflow shortcut again or **Finish instruction**. **Use saved prompt** discards the microphone samples and runs the saved instruction alone.
5. Review the selected text and result. Edit the additional instruction and **Run again** if needed. **Replace** validates the original target before one write; **Copy** lets the user insert the result manually. Closing or cancelling discards the session.

There is no Transform settings destination, global Transform shortcut, separate provider picker, or editing-prompt snippet scope. Provider/model, effort, temperature, output format, protected vocabulary, spoken language, and microphone boost come from the workflow and its existing global defaults. Generation uses the existing workflow LLM executor and fallback list.

## Host safeguards

- The host takes a snapshot of workflow processing settings when the execution starts. Retrying uses that snapshot and the original source.
- Selected text is the processing input. The spoken instruction supplements the saved workflow instruction and takes precedence where they conflict.
- Source text, including embedded instructions, is treated as untrusted content, not an instruction to execute commands or tools.
- AX capture binds replacement to the original app instance, field, full document, and selection. It rejects changed documents, focus, selection, or relaunched apps. An ambiguous/failed write is never attempted a second time.
- A fresh Command-C capture is review/Copy only, with clipboard restoration when the host still owns the copied value. Existing clipboard content is not accepted as proof of a selection.
- Starting, recording, transcription, generation, cancellation cleanup, and replacement exclude competing microphone/recorder work. Cancellation waits for pending work and suppresses late results.
- Every stop, cancellation, and start-failure cleanup uses `bluetoothBehavior: .release`; a review session never keeps a Bluetooth stream prepared. A session resolves the current input when recording starts, so idle sessions need no input/preference observer.
- Host bounds are 12,000 source characters, 2,000 instruction characters, 24,000 result characters (also 512 KiB), and 120 seconds of recording. Long before/after documents remain scrollable.
- Review uses explicit Replace/Copy; plugin action dispatch and auto-submit are not part of voice editing.

## Persistence and legacy snippet compatibility

The optional `WorkflowBehavior.voiceEditingEnabled` value is saved with the existing workflow behavior. Older workflow data omitting it remains ordinary workflow behavior. Backup export/import preserves the option with the workflow. Older builds do not implement this workflow behavior; round-tripping an edited workflow through such a build may omit the new option.

Saved editing instructions now live exclusively in workflows. No editing prompts are exported as snippet upserts. Existing snippets keep their dictation meaning; Workflows are not part of dictionary/snippet cloud-folder sync.

For data from the standalone Transform build, the old optional scope string remains as a compatibility field, with no scope editor or prompt-expansion UI. Transform and Both snippets are copied into manual voice-edit workflows once, preserving their enabled state and using the snippet UUID as the migration identity. The original records remain hidden compatibility markers, excluded from dictation, snippet inventories, backups, and snippet-sync exports. A scope-less legacy sync return with the same normalized trigger is ignored, so it cannot reset the archived classification or overwrite the migrated prompt. Scoped legacy payloads received later are migrated the same way. Ordinary legacy snippets remain supported. Importing old scoped snippet backups creates workflows rather than dictation snippets.

This protects newly emitted sync data and known scoped entries. A previously exposed prompt renamed by a legacy client and returned without scope is indistinguishable from a new ordinary snippet; the host cannot infer a missing classification for unknown triggers.
