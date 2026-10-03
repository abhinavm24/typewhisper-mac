import AppKit
import AVFoundation
import TypeWhisperPluginSDK
import XCTest
@testable import TypeWhisper

@MainActor
final class WorkflowVoiceEditingTests: XCTestCase {
    @MainActor
    private final class Fixture {
        var starts = 0
        var stops = 0
        var releases = 0
        var replacements: [String] = []
        var requests: [(WorkflowLLMRequest, String, String)] = []
        var startOverride: (() async throws -> Void)?
        var captureOverride: (() async throws -> WorkflowVoiceEditingTarget)?
        var generationOverride: (() async throws -> String)?
        var replacementFails = false
        var supportsReplacement = true
        var canStart = true
        var output = "Rewritten text"
        var spoken = "Make it shorter"
        var recordingLimit = 120
        var configuration = WorkflowVoiceEditingConfiguration(
            workflowID: UUID(), name: "Improve email",
            request: WorkflowLLMRequest(systemPrompt: "Improve this email", providerId: "chosen-provider", cloudModel: "chosen-model",
                                        temperatureDirective: .inheritProviderSetting, effortId: "high"),
            hasSavedPrompt: true
        )
        lazy var coordinator = makeCoordinator()

        private func makeCoordinator() -> WorkflowVoiceEditingCoordinator {
            WorkflowVoiceEditingCoordinator(dependencies: .init(
                canStart: { [unowned self] in canStart },
                capture: { [unowned self] in
                    if let captureOverride { return try await captureOverride() }
                    return WorkflowVoiceEditingTarget(text: "Original 🐱 text", supportsReplacement: supportsReplacement,
                                                      release: { [unowned self] in releases += 1 }) { [unowned self] text in
                        replacements.append(text)
                        if replacementFails { throw WorkflowVoiceEditingError.message("Selection changed") }
                    }
                },
                start: { [unowned self] _ in starts += 1; try await startOverride?() },
                stop: { [unowned self] in stops += 1; return [0.1, 0.2] },
                transcribe: { [unowned self] _, _ in spoken },
                generate: { [unowned self] request, instruction, source in
                    requests.append((request, instruction, source))
                    if let generationOverride { return try await generationOverride() }
                    return output
                },
                present: {}, cancellationAvailability: { _ in },
                limits: { WorkflowVoiceEditingLimits() },
                waitForRecordingLimit: { [unowned self] _ in try await Task.sleep(for: .seconds(recordingLimit)) }
            ))
        }
    }

    private func waitFor(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Expected state not reached", file: file, line: line)
    }

    private func preview(_ fixture: Fixture, useSavedPrompt: Bool = false) async throws {
        fixture.coordinator.start(configuration: fixture.configuration)
        try await waitFor { fixture.coordinator.state == .recording }
        fixture.coordinator.finishRecording(useSavedPrompt: useSavedPrompt)
        try await waitFor { fixture.coordinator.state == .preview || fixture.coordinator.state == .failed }
    }

    func testWorkflowConfigurationAndSpokenInstructionReachReviewBeforeAnyWrite() async throws {
        let fixture = Fixture()
        try await preview(fixture)
        XCTAssertEqual(fixture.coordinator.workflowName, "Improve email")
        XCTAssertEqual(fixture.requests.first?.0, fixture.configuration.request)
        XCTAssertEqual(fixture.requests.first?.1, "Make it shorter")
        XCTAssertEqual(fixture.requests.first?.2, "Original 🐱 text")
        XCTAssertEqual(fixture.stops, 1)
        XCTAssertTrue(fixture.replacements.isEmpty)
        XCTAssertTrue(fixture.coordinator.canApply)
        fixture.coordinator.apply()
        try await waitFor { fixture.coordinator.state == .idle }
        XCTAssertEqual(fixture.replacements, ["Rewritten text"])
        XCTAssertEqual(fixture.releases, 1)
    }

    func testSavedPromptCanRunWithoutSpokenAddition() async throws {
        let fixture = Fixture()
        try await preview(fixture, useSavedPrompt: true)
        XCTAssertEqual(fixture.coordinator.state, .preview)
        XCTAssertEqual(fixture.requests.first?.1, "")
        XCTAssertEqual(fixture.stops, 1)
        fixture.coordinator.cancel()
        try await waitFor { fixture.coordinator.state == .idle }
    }

    func testSpokenOnlyCustomWorkflowRejectsEmptyInstruction() async throws {
        let fixture = Fixture()
        fixture.configuration = WorkflowVoiceEditingConfiguration(
            workflowID: UUID(), name: "Voice edit selected text", request: fixture.configuration.request, hasSavedPrompt: false
        )
        fixture.spoken = "   "
        try await preview(fixture)
        XCTAssertEqual(fixture.coordinator.state, .failed)
        XCTAssertTrue(fixture.requests.isEmpty)
        fixture.coordinator.cancel()
        try await waitFor { fixture.coordinator.state == .idle }
    }

    func testCopyOnlyCaptureNeverOffersReplacement() async throws {
        let fixture = Fixture()
        fixture.supportsReplacement = false
        try await preview(fixture)
        XCTAssertEqual(fixture.coordinator.result, "Rewritten text")
        XCTAssertFalse(fixture.coordinator.canApply)
        fixture.coordinator.apply()
        XCTAssertTrue(fixture.replacements.isEmpty)
        fixture.coordinator.cancel()
        try await waitFor { fixture.coordinator.state == .idle }
    }

    func testChangedInstructionRequiresRegenerationAndKeepsWorkflowRoute() async throws {
        let fixture = Fixture()
        try await preview(fixture)
        fixture.coordinator.instruction = "Keep the dates"
        XCTAssertFalse(fixture.coordinator.canApply)
        fixture.coordinator.retry()
        try await waitFor { fixture.requests.count == 2 && fixture.coordinator.state == .preview }
        XCTAssertEqual(fixture.requests.last?.1, "Keep the dates")
        XCTAssertEqual(fixture.requests.last?.0, fixture.configuration.request)
        fixture.coordinator.cancel()
        try await waitFor { fixture.coordinator.state == .idle }
    }

    func testAmbiguousReplacementIsNeverRetried() async throws {
        let fixture = Fixture()
        fixture.replacementFails = true
        try await preview(fixture)
        fixture.coordinator.apply()
        try await waitFor { fixture.replacements.count == 1 && fixture.coordinator.state == .preview }
        fixture.coordinator.apply()
        XCTAssertEqual(fixture.replacements.count, 1)
        XCTAssertFalse(fixture.coordinator.canApply)
        XCTAssertEqual(fixture.coordinator.result, "Rewritten text")
        fixture.coordinator.cancel()
        try await waitFor { fixture.coordinator.state == .idle }
    }

    func testStartFailureStopsRecorderAndCancellationReleasesTarget() async throws {
        let fixture = Fixture()
        fixture.startOverride = { throw WorkflowVoiceEditingError.message("No microphone") }
        fixture.coordinator.start(configuration: fixture.configuration)
        try await waitFor { fixture.coordinator.state == .failed }
        XCTAssertEqual(fixture.stops, 1)
        fixture.coordinator.cancel()
        try await waitFor { fixture.coordinator.state == .idle }
        XCTAssertEqual(fixture.releases, 1)
    }

    func testCancellationWaitsForStartAndStopsBeforeBecomingIdle() async throws {
        let fixture = Fixture()
        var resumeStart: CheckedContinuation<Void, Never>?
        fixture.startOverride = { await withCheckedContinuation { resumeStart = $0 } }
        fixture.coordinator.start(configuration: fixture.configuration)
        try await waitFor { resumeStart != nil }
        fixture.coordinator.cancel()
        XCTAssertEqual(fixture.coordinator.state, .cancelling)
        XCTAssertTrue(fixture.coordinator.isBusy)
        resumeStart?.resume()
        try await waitFor { fixture.coordinator.state == .idle }
        XCTAssertGreaterThanOrEqual(fixture.stops, 1)
        XCTAssertEqual(fixture.releases, 1)
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testLateGenerationAfterCancellationCannotPublishOrWrite() async throws {
        let fixture = Fixture()
        var resumeGeneration: CheckedContinuation<String, Never>?
        fixture.generationOverride = { await withCheckedContinuation { resumeGeneration = $0 } }
        fixture.coordinator.start(configuration: fixture.configuration)
        try await waitFor { fixture.coordinator.state == .recording }
        fixture.coordinator.finishRecording()
        try await waitFor { resumeGeneration != nil }
        fixture.coordinator.cancel()
        XCTAssertTrue(fixture.coordinator.isBusy)
        resumeGeneration?.resume(returning: "Late result")
        try await waitFor { fixture.coordinator.state == .idle }
        XCTAssertTrue(fixture.coordinator.result.isEmpty)
        XCTAssertTrue(fixture.replacements.isEmpty)
    }

    func testCapturedPaletteTargetIsUsedWithoutRecapturingFocusedPanel() async throws {
        let fixture = Fixture()
        fixture.captureOverride = { XCTFail("Should use source captured before palette"); throw CancellationError() }
        fixture.coordinator.start(configuration: fixture.configuration, capturedTarget: WorkflowVoiceEditingTarget(text: "Selected before palette") { _ in })
        try await waitFor { fixture.coordinator.state == .recording }
        fixture.coordinator.finishRecording()
        try await waitFor { fixture.coordinator.state == .preview }
        XCTAssertEqual(fixture.requests.first?.2, "Selected before palette")
        fixture.coordinator.cancel()
        try await waitFor { fixture.coordinator.state == .idle }
    }

    func testRepressingSameWorkflowShortcutStopsInstructionRecording() async throws {
        let fixture = Fixture()
        fixture.coordinator.start(configuration: fixture.configuration)
        try await waitFor { fixture.coordinator.state == .recording }
        fixture.coordinator.start(configuration: fixture.configuration)
        try await waitFor { fixture.coordinator.state == .preview }
        XCTAssertEqual(fixture.starts, 1)
        fixture.coordinator.cancel()
        try await waitFor { fixture.coordinator.state == .idle }
    }

    func testRecordingLimitStopsAndRunsWorkflow() async throws {
        let fixture = Fixture()
        fixture.recordingLimit = 0
        fixture.coordinator.start(configuration: fixture.configuration)
        try await waitFor { fixture.coordinator.state == .preview }
        XCTAssertEqual(fixture.stops, 1)
        fixture.coordinator.cancel()
        try await waitFor { fixture.coordinator.state == .idle }
    }

    func testRejectsEmptyAndOversizedResults() async throws {
        for output in ["   ", String(repeating: "a", count: 24_001)] {
            let fixture = Fixture()
            fixture.output = output
            try await preview(fixture)
            XCTAssertEqual(fixture.coordinator.state, .failed)
            XCTAssertTrue(fixture.replacements.isEmpty)
            fixture.coordinator.cancel()
            try await waitFor { fixture.coordinator.state == .idle }
        }
    }

    func testSelectionValidationIncludesDocumentRangeAndUnicode() throws {
        let original = "🐱 hello"
        let value = "Before \(original) after"
        let range = (value as NSString).range(of: original)
        let snapshot = WorkflowVoiceEditingSelectionSnapshot(value: value, range: range, selectedText: original)
        XCTAssertEqual(try snapshot.replacementDocument(original: original, replacement: "new", current: snapshot), "Before new after")
        XCTAssertThrowsError(try snapshot.replacementDocument(original: original, replacement: "new",
            current: .init(value: value + " changed", range: range, selectedText: original)))
        XCTAssertThrowsError(try snapshot.replacementDocument(original: original, replacement: "new",
            current: .init(value: value, range: NSRange(location: 0, length: 2), selectedText: original)))
    }

    func testProviderOverridesAndInheritedFallbackRequestUseExistingWorkflowProcessor() async throws {
        var received: (String, String, String?, String?, PluginLLMTemperatureDirective)?
        let processor = WorkflowTextProcessingService(promptProcessor: { prompt, text, provider, model, temperature in
            received = (prompt, text, provider, model, temperature)
            return "result"
        }, appleTranslator: nil)
        let workflow = Workflow(name: "Improve email", template: .emailReply, trigger: .manual(),
                                behavior: WorkflowBehavior(fineTuning: "Keep dates", providerId: "provider", cloudModel: "model", effortId: "high", voiceEditingEnabled: true))
        let configuration = processor.voiceEditingConfiguration(workflow: workflow)
        XCTAssertTrue(configuration.hasSavedPrompt)
        XCTAssertEqual(configuration.request.effortId, "high")
        _ = try await processor.processVoiceEditing(request: configuration.request, instruction: "Make it shorter", text: "Selected email")
        XCTAssertTrue(received?.0.contains("Keep dates") == true)
        XCTAssertTrue(received?.0.contains("Make it shorter") == true)
        XCTAssertTrue(received?.0.contains("takes precedence") == true)
        XCTAssertEqual(received?.1, "Selected email")
        XCTAssertEqual(received?.2, "provider")
        XCTAssertEqual(received?.3, "model")
        let inherited = Workflow(name: "Voice edit", template: .custom, trigger: .manual(), behavior: WorkflowBehavior(voiceEditingEnabled: true))
        let inheritedConfiguration = processor.voiceEditingConfiguration(workflow: inherited)
        XCTAssertNil(inheritedConfiguration.request.providerId)
        XCTAssertNil(inheritedConfiguration.request.cloudModel)
        XCTAssertFalse(inheritedConfiguration.hasSavedPrompt)
        XCTAssertTrue(inherited.isManuallyRunnable)
    }

    func testWorkflowBackupRoundTripAndLegacyDefaultsDoNotUseSnippetScopes() throws {
        let workflow = Workflow(name: "Voice edit", template: .custom, trigger: .manual(), behavior: WorkflowBehavior(voiceEditingEnabled: true))
        let draft = WorkflowDraft(workflow)
        XCTAssertEqual(draft.resolvedBehavior().voiceEditingEnabled, true)
        let encoded = try JSONEncoder().encode(draft.resolvedBehavior())
        XCTAssertEqual(try JSONDecoder().decode(WorkflowBehavior.self, from: encoded).voiceEditingEnabled, true)
        let legacy = Data(#"{"settings":{},"fineTuning":""}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(WorkflowBehavior.self, from: legacy).voiceEditingEnabled)
    }
    func testHostStopInvalidatesPreparedBluetoothInputEvenWhenNoRecordingIsActive() async throws {
        let recorder = AudioRecordingService()
        recorder.testingSetPreparedBluetoothInput(AVAudioEngine(), deviceID: 123)
        XCTAssertTrue(recorder.testingHasPreparedBluetoothInput())
        _ = await WorkflowVoiceEditingCoordinator.stopRecorder(recorder)
        XCTAssertEqual(recorder.testingLastBluetoothStopBehavior, .release)
        XCTAssertFalse(recorder.testingHasPreparedBluetoothInput())
    }

    func testVoiceWorkflowDraftAcceptsSpokenOnlyPromptAndRejectsAutomaticInsertion() throws {
        let directory = try TestSupport.makeTemporaryDirectory(prefix: "WorkflowVoiceEditingTests")
        defer { TestSupport.remove(directory) }
        let service = WorkflowService(appSupportDirectory: directory)
        let hotkeys = HotkeyService()
        let plugins = PluginManager(appSupportDirectory: directory)
        var draft = WorkflowDraft(template: .custom)
        draft.voiceEditingEnabled = true
        XCTAssertNil(draft.validationError(hotkeyService: hotkeys, workflowService: service, pluginManager: plugins, existingWorkflowId: nil))
        draft.triggerMode = .global
        XCTAssertNotNil(draft.validationError(hotkeyService: hotkeys, workflowService: service, pluginManager: plugins, existingWorkflowId: nil))
        let workflow = service.addWorkflow(name: "Voice edit", template: .custom, trigger: .global(), behavior: draft.resolvedBehavior())
        XCTAssertNotNil(workflow)
        XCTAssertNil(service.matchWorkflow(bundleIdentifier: "com.apple.mail"))
    }

    func testReviewPanelFitsMinimumAndNormalWindowSizes() async throws {
        let fixture = Fixture()
        try await preview(fixture)
        let controller = WorkflowVoiceEditingWindowController(coordinator: fixture.coordinator)
        controller.show()
        let panel = try XCTUnwrap(NSApp.windows.first { $0.title == localizedAppText("Workflow review", de: "Workflow-Review") && $0.isVisible })
        for (name, size) in [("minimum", NSSize(width: 420, height: 360)), ("narrow", NSSize(width: 420, height: 520)),
                             ("short", NSSize(width: 680, height: 360)), ("normal", NSSize(width: 680, height: 520))] {
            panel.setContentSize(size)
            try await Task.sleep(for: .milliseconds(150))
            let view = try XCTUnwrap(panel.contentView)
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/tmp/workflow-voice-review-\(name).png"))
        }
        panel.orderOut(nil)
        fixture.coordinator.cancel()
        try await waitFor { fixture.coordinator.state == .idle }
    }

    func testEscapeCancelsVoiceWorkflowWithoutRoutingToDictation() async throws {
        let service = HotkeyService()
        service.suspendMonitoring()
        defer { service.suspendMonitoring() }
        var dictationCancels = 0
        var voiceCancels = 0
        service.onCancelPressed = { dictationCancels += 1 }
        service.onWorkflowVoiceEditingCancel = { voiceCancels += 1 }
        service.isWorkflowVoiceEditingCancellationAvailable = true
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0x35, keyDown: true))
        event.timestamp = DispatchTime.now().uptimeNanoseconds
        event.flags = []
        let escape = try XCTUnwrap(NSEvent(cgEvent: event))
        XCTAssertTrue(service.processEventForTesting(escape, source: .eventTap))
        try await waitFor { voiceCancels == 1 }
        XCTAssertEqual(dictationCancels, 0)
        service.isWorkflowVoiceEditingCancellationAvailable = false
        XCTAssertFalse(service.isCancellationAvailable)
    }

    func testDroppingUnselectedPaletteTargetReleasesAccessibilityLease() async throws {
        var releases = 0
        do {
            let target = WorkflowVoiceEditingTarget(text: "Source", release: { releases += 1 }) { _ in }
            XCTAssertEqual(target.text, "Source")
        }
        try await waitFor { releases == 1 }
    }

    func testSwitchingToIncompatibleTemplateClearsVoiceEditingOption() {
        var draft = WorkflowDraft(template: .custom)
        draft.voiceEditingEnabled = true
        draft.selectTemplate(.dictation)
        XCTAssertNil(draft.voiceEditingEnabled)
        var translationDraft = WorkflowDraft(template: .translation)
        translationDraft.translationProcessor = .llmPrompt
        translationDraft.voiceEditingEnabled = true
        translationDraft.normalizeTranslationTarget(for: .appleTranslate)
        XCTAssertNil(translationDraft.voiceEditingEnabled)
    }

    func testScopedLegacyPromptMigratesOnceAndCannotReturnAsDictationThroughSync() throws {
        let directory = try TestSupport.makeTemporaryDirectory(prefix: "WorkflowLegacyPromptTests")
        defer { TestSupport.remove(directory) }
        let workflows = WorkflowService(appSupportDirectory: directory)
        let snippets = SnippetService(appSupportDirectory: directory)
        snippets.connectLegacyVoiceEditingMigration(to: workflows)
        let now = Date()
        let scoped = UserDataSyncSnippet(trigger: "improve email", replacement: "Make emails concise", caseSensitive: false,
                                         isEnabled: true, createdAt: now, updatedAt: now, scopeRawValue: "voiceTransform")
        // Exercise the real decoder used by the old proposal's schema-1 payload.
        let decoded = try JSONDecoder().decode(UserDataSyncSnippet.self, from: JSONEncoder().encode(scoped))
        try snippets.applyUserDataSyncMutations([.upsertSnippet(decoded)])
        XCTAssertEqual(workflows.workflows.count, 1)
        XCTAssertTrue(workflows.workflows.first?.usesVoiceEditing == true)
        XCTAssertEqual(workflows.workflows.first?.behavior.settings["instruction"], "Make emails concise")
        XCTAssertEqual(snippets.applySnippets(to: "improve email"), "improve email")
        XCTAssertTrue(snippets.userDataSyncSnippets().isEmpty)
        let legacyReturn = UserDataSyncSnippet(trigger: "improve email", replacement: "Old client edited this", caseSensitive: false,
                                               isEnabled: true, createdAt: now, updatedAt: now.addingTimeInterval(10))
        try snippets.applyUserDataSyncMutations([.upsertSnippet(legacyReturn)])
        XCTAssertEqual(snippets.snippets.first?.scopeRawValue, "voiceTransform")
        XCTAssertEqual(snippets.applySnippets(to: "improve email"), "improve email")
        XCTAssertTrue(snippets.userDataSyncSnippets().isEmpty)
        XCTAssertEqual(workflows.workflows.count, 1)
        snippets.loadSnippets()
        XCTAssertEqual(workflows.workflows.count, 1)
        let reopened = SnippetService(appSupportDirectory: directory)
        reopened.connectLegacyVoiceEditingMigration(to: workflows)
        XCTAssertEqual(workflows.workflows.count, 1)
        XCTAssertTrue(reopened.userDataSyncSnippets().isEmpty)
    }

    func testLegacyBothScopeIsMigratedAndOrdinarySnippetSyncKeepsItsMeaning() throws {
        let directory = try TestSupport.makeTemporaryDirectory(prefix: "WorkflowLegacyBothTests")
        defer { TestSupport.remove(directory) }
        let workflows = WorkflowService(appSupportDirectory: directory)
        let snippets = SnippetService(appSupportDirectory: directory)
        snippets.connectLegacyVoiceEditingMigration(to: workflows)
        let now = Date()
        try snippets.applyUserDataSyncMutations([
            .upsertSnippet(.init(trigger: "rewrite", replacement: "Be brief", caseSensitive: false, isEnabled: false,
                                 createdAt: now, updatedAt: now, scopeRawValue: "both")),
            .upsertSnippet(.init(trigger: ";sig", replacement: "Best, Alex", caseSensitive: false, isEnabled: true,
                                 createdAt: now, updatedAt: now))
        ])
        XCTAssertEqual(workflows.workflows.count, 1)
        XCTAssertFalse(try XCTUnwrap(workflows.workflows.first).isEnabled)
        XCTAssertEqual(snippets.applySnippets(to: "rewrite ;sig"), "rewrite Best, Alex")
        XCTAssertEqual(snippets.userDataSyncSnippets().map(\.trigger), [";sig"])
        XCTAssertEqual(SnippetsViewModel(snippetService: snippets).totalCount, 1)
    }

}
