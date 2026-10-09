import AVFoundation
import Foundation

extension ServiceContainer {
    func makeWorkflowVoiceEditingCoordinator() -> WorkflowVoiceEditingCoordinator {
        let recorder = AudioRecordingService(
            recoveryAudioStore: DictationRecoveryAudioStore(
                directory: AppConstants.appSupportDirectory.appendingPathComponent("workflow-voice-editing-recovery", isDirectory: true),
                retentionPolicy: .immediately
            )
        )
        return WorkflowVoiceEditingCoordinator(dependencies: .init(
            canStart: { [weak self] in
                guard let self else { return false }
                return dictationViewModel.state == .idle && audioRecorderViewModel.state == .idle
                    && audioRecorderViewModel.retranscribingRecordingURL == nil
            },
            capture: { [weak self] in
                guard let self else { throw CancellationError() }
                return try await textInsertionService.captureWorkflowVoiceEditingTarget()
            },
            start: { [weak self] configuration in
                guard let self else { throw CancellationError() }
                guard modelManagerService.canTranscribe else {
                    throw WorkflowVoiceEditingError.message("Choose an available speech-to-text model first.")
                }
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    throw WorkflowVoiceEditingError.message("Allow microphone access in System Settings to speak an instruction.")
                }
                try Task.checkCancellation()
                let input = audioDeviceService.resolvedRecordingInputSelection()
                recorder.microphoneBoostEnabled = configuration.microphoneBoostOverride
                    ?? UserDefaults.standard.bool(forKey: UserDefaultsKeys.microphoneBoostEnabled)
                recorder.configureInputSelection(
                    deviceID: input.deviceID, hasExplicitDeviceSelection: input.hasExplicitDeviceSelection,
                    usesBluetoothTransport: input.usesBluetoothTransport, deviceName: input.deviceName
                )
                try await recorder.startRecordingAsync()
            },
            // A review session never owns a prepared Bluetooth stream after stop,
            // including start failure and cancellation. No preference observer is needed.
            stop: { await WorkflowVoiceEditingCoordinator.stopRecorder(recorder) },
            transcribe: { [weak self] samples, configuration in
                guard let self else { throw CancellationError() }
                let language = configuration.languageSelection == .inheritGlobal
                    ? settingsViewModel.languageSelection : configuration.languageSelection
                let result = try await modelManagerService.transcribe(
                    audioSamples: samples, languageSelection: language,
                    task: .transcribe, normalizeNumbers: false
                )
                return result.text
            },
            generate: { [weak self] request, instruction, source in
                guard let self else { throw CancellationError() }
                let processor = WorkflowTextProcessingService(
                    promptProcessingService: promptProcessingService,
                    translationService: translationService
                )
                return try await processor.processVoiceEditing(request: request, instruction: instruction, text: source)
            },
            present: { [weak self] in self?.workflowVoiceEditingWindow.show() },
            cancellationAvailability: { [weak self] available in
                self?.hotkeyService.isWorkflowVoiceEditingCancellationAvailable = available
            }
        ))
    }

    func startWorkflowVoiceEditing(workflow: Workflow, target: WorkflowVoiceEditingTarget? = nil) {
        guard workflow.isEnabled, workflow.usesVoiceEditing else { target?.releaseResources(); return }
        let activeApp = textInsertionService.captureActiveApp()
        let format = WorkflowOutputFormatResolver.resolvedFormat(
            storedFormat: workflow.output.format, bundleIdentifier: target?.sourceBundleIdentifier ?? activeApp.bundleId, url: target?.sourceURL ?? activeApp.url
        )
        let processor = WorkflowTextProcessingService(
            promptProcessingService: promptProcessingService, translationService: translationService,
            vocabularyProvider: { [weak self] in self?.dictionaryService.vocabularyForPrompt() ?? [] }
        )
        workflowVoiceEditingCoordinator.start(
            configuration: processor.voiceEditingConfiguration(workflow: workflow, resolvedOutputFormat: format),
            capturedTarget: target
        )
    }
}
