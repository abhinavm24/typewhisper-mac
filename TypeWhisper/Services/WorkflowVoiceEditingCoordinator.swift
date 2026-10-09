import AppKit
import Combine
import Foundation
import TypeWhisperPluginSDK

enum WorkflowVoiceEditingError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let message) = self { return message }
        return nil
    }
}

/// A captured source and its guarded, single-attempt replacement operation.
@MainActor
final class WorkflowVoiceEditingTarget {
    let text: String
    let supportsReplacement: Bool
    let sourceBundleIdentifier: String?
    let sourceURL: String?
    private var release: (@MainActor () -> Void)?
    let replace: @MainActor (String) async throws -> Void

    init(text: String, supportsReplacement: Bool = true, sourceBundleIdentifier: String? = nil, sourceURL: String? = nil, release: (@MainActor () -> Void)? = nil,
         replace: @escaping @MainActor (String) async throws -> Void) {
        self.text = text
        self.supportsReplacement = supportsReplacement
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.sourceURL = sourceURL
        self.release = release
        self.replace = replace
    }

    func releaseResources() {
        let action = release
        release = nil
        action?()
    }

    deinit {
        let action = release
        Task { @MainActor in action?() }
    }
}

struct WorkflowVoiceEditingSelectionSnapshot: Equatable {
    let value: String
    let range: NSRange
    let selectedText: String?

    func replacementDocument(original: String, replacement: String, current: Self) throws -> String {
        guard self == current, let selectedRange = Range(range, in: value),
              String(value[selectedRange]) == original else {
            throw WorkflowVoiceEditingError.message("The original field, selection, or document changed. Copy the result instead.")
        }
        var expected = value
        expected.replaceSubrange(selectedRange, with: replacement)
        return expected
    }
}

@MainActor
final class WorkflowVoiceEditingCoordinator: ObservableObject {
    enum State: Equatable {
        case idle, starting, recording, transcribing, generating, preview, applying, cancelling, failed
    }

    struct Dependencies {
        var canStart: @MainActor () -> Bool
        var capture: @MainActor () async throws -> WorkflowVoiceEditingTarget
        var start: @MainActor (WorkflowVoiceEditingConfiguration) async throws -> Void
        var stop: @MainActor () async -> [Float]
        var transcribe: @MainActor ([Float], WorkflowVoiceEditingConfiguration) async throws -> String
        var generate: @MainActor (WorkflowLLMRequest, _ instruction: String, _ source: String) async throws -> String
        var present: @MainActor () -> Void
        var cancellationAvailability: @MainActor (Bool) -> Void
        var limits: @MainActor () -> WorkflowVoiceEditingLimits = { WorkflowVoiceEditingLimits() }
        var waitForRecordingLimit: @MainActor (Int) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    }

    @Published private(set) var state: State = .idle {
        didSet { dependencies.cancellationAvailability(state != .idle && state != .applying && state != .cancelling) }
    }
    @Published private(set) var original = ""
    @Published var instruction = ""
    @Published private(set) var result = ""
    @Published private(set) var workflowName = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var replacementAvailable = false
    @Published private(set) var generatedInstruction = ""

    private let dependencies: Dependencies
    private var configuration: WorkflowVoiceEditingConfiguration?
    private var target: WorkflowVoiceEditingTarget?
    private var task: Task<Void, Never>?
    private var recordingLimitTask: Task<Void, Never>?
    private var sessionID = UUID()
    private var sessionLimits = WorkflowVoiceEditingLimits()

    init(dependencies: Dependencies) { self.dependencies = dependencies }

    /// Hold ownership through cleanup and generation, including providers that
    /// do not return promptly after cancellation. Preview does not own the mic.
    var isBusy: Bool {
        switch state {
        case .starting, .recording, .transcribing, .generating, .applying, .cancelling: true
        case .idle, .preview, .failed: false
        }
    }

    var canUseSavedPrompt: Bool { configuration?.hasSavedPrompt == true }

    var canApply: Bool {
        state == .preview && replacementAvailable && instruction == generatedInstruction
    }

    func start(configuration: WorkflowVoiceEditingConfiguration, capturedTarget: WorkflowVoiceEditingTarget? = nil) {
        if self.configuration?.workflowID == configuration.workflowID, state == .recording {
            capturedTarget?.releaseResources()
            finishRecording(); return
        }
        guard !isBusy else { capturedTarget?.releaseResources(); dependencies.present(); return }
        // A preview must be closed explicitly before capturing a new target.
        if target != nil { capturedTarget?.releaseResources(); dependencies.present(); return }
        clearContent()
        guard dependencies.canStart() else {
            capturedTarget?.releaseResources()
            errorMessage = "Finish the current recording or transcription first."
            state = .failed
            dependencies.present()
            return
        }
        self.configuration = configuration
        workflowName = configuration.name
        sessionLimits = dependencies.limits()
        sessionID = UUID()
        let id = sessionID
        state = .starting
        // Do not open the panel until selection capture (including Cmd+C) has
        // finished: taking focus here would copy from our own instruction field.
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let captured: WorkflowVoiceEditingTarget
                if let capturedTarget { captured = capturedTarget }
                else { captured = try await dependencies.capture() }
                do {
                    try checkSession(id)
                    try Self.validateSource(captured.text, limit: sessionLimits.sourceCharacters)
                } catch {
                    captured.releaseResources()
                    throw error
                }
                target = captured
                original = captured.text
                replacementAvailable = captured.supportsReplacement
                errorMessage = captured.supportsReplacement ? nil : "Selection captured for preview. This field cannot be verified for replacement; use Copy for the result."
                dependencies.present()
                try await dependencies.start(configuration)
                try checkSession(id)
                state = .recording
                let recordingSeconds = sessionLimits.recordingSeconds
                let waitForLimit = dependencies.waitForRecordingLimit
                recordingLimitTask = Task { [weak self] in
                    do { try await waitForLimit(recordingSeconds) }
                    catch { return }
                    guard !Task.isCancelled, let self, sessionID == id, state == .recording else { return }
                    finishRecording()
                }
            } catch {
                guard sessionID == id else { return }
                _ = await dependencies.stop()
                guard sessionID == id else { return }
                fail(error)
                dependencies.present()
            }
        }
    }

    func finishRecording(useSavedPrompt: Bool = false) {
        guard state == .recording, let configuration else { return }
        guard !useSavedPrompt || configuration.hasSavedPrompt else { return }
        recordingLimitTask?.cancel()
        state = .transcribing
        let id = sessionID
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let samples = await dependencies.stop()
                try checkSession(id)
                if useSavedPrompt {
                    instruction = ""
                } else {
                    guard !samples.isEmpty else { throw WorkflowVoiceEditingError.message("No speech recorded. Try again.") }
                    instruction = try await dependencies.transcribe(samples, configuration)
                    try checkSession(id)
                    try Self.validateInstruction(instruction, limit: sessionLimits.instructionCharacters)
                }
                try await generate(id: id)
            } catch {
                guard sessionID == id else { return }
                fail(error)
            }
        }
    }

    /// Retry deliberately uses the displayed instruction and original source.
    func retry() {
        guard !isBusy, target != nil, dependencies.canStart() else { return }
        sessionLimits = dependencies.limits()
        errorMessage = nil
        result = ""
        let id = sessionID
        state = .generating
        task = Task { [weak self] in
            guard let self else { return }
            do { try await generate(id: id) }
            catch {
                guard sessionID == id else { return }
                fail(error)
            }
        }
    }

    private func generate(id: UUID) async throws {
        try Self.validateSource(original, limit: sessionLimits.sourceCharacters)
        guard let configuration else { throw CancellationError() }
        if !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !configuration.hasSavedPrompt {
            try Self.validateInstruction(instruction, limit: sessionLimits.instructionCharacters)
        }
        state = .generating
        let submittedInstruction = instruction
        let output = try await dependencies.generate(configuration.request, submittedInstruction, original)
        try checkSession(id)
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkflowVoiceEditingError.message("The LLM returned no text. Your selection was not changed.")
        }
        guard output.utf8.count <= 512 * 1024, output.count <= sessionLimits.resultCharacters else {
            throw WorkflowVoiceEditingError.message("The result exceeds the preview limit (\(sessionLimits.resultCharacters.formatted()) characters or 512 KiB). Ask for a shorter result.")
        }
        result = output
        generatedInstruction = submittedInstruction
        state = .preview
    }

    func apply() {
        guard canApply, let target else { return }
        guard dependencies.canStart() else {
            errorMessage = "Finish the current recording or transcription before replacing text."
            return
        }
        // A failed/ambiguous write is never automatically attempted again.
        replacementAvailable = false
        state = .applying
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await target.replace(result)
                self.target?.releaseResources()
                self.target = nil
                clearContent()
                state = .idle
            } catch {
                errorMessage = error.localizedDescription
                state = .preview
            }
        }
    }

    func cancel() {
        guard state != .applying, state != .cancelling else { return }
        let previous = task
        previous?.cancel()
        recordingLimitTask?.cancel()
        sessionID = UUID()
        state = .cancelling
        task = Task { [weak self] in
            guard let self else { return }
            await previous?.value
            _ = await dependencies.stop()
            target?.releaseResources()
            target = nil
            clearContent()
            state = .idle
        }
    }

    private func clearContent() {
        original = ""
        instruction = ""
        generatedInstruction = ""
        result = ""
        workflowName = ""
        configuration = nil
        errorMessage = nil
        replacementAvailable = false
    }

    private func checkSession(_ id: UUID) throws {
        try Task.checkCancellation()
        guard id == sessionID else { throw CancellationError() }
    }

    private func fail(_ error: Error) {
        errorMessage = error.localizedDescription
        state = .failed
    }

    static func stopRecorder(_ recorder: AudioRecordingService) async -> [Float] {
        await recorder.stopRecording(policy: .immediate, bluetoothBehavior: .release)
    }

    static func validateSource(_ source: String, limit: Int = 12_000) throws {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkflowVoiceEditingError.message("Select text first.")
        }
        guard source.count <= limit else { throw WorkflowVoiceEditingError.message("Select at most \(limit.formatted()) characters.") }
    }

    static func validateInstruction(_ instruction: String, limit: Int = 2_000) throws {
        guard !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkflowVoiceEditingError.message("Describe the change you want to make.")
        }
        guard instruction.count <= limit else { throw WorkflowVoiceEditingError.message("Keep the expanded instruction at or below \(limit.formatted()) characters.") }
    }

}

struct WorkflowVoiceEditingLimits {
    var sourceCharacters = 12_000
    var instructionCharacters = 2_000
    var resultCharacters = 24_000
    var recordingSeconds = 120
}

struct WorkflowVoiceEditingConfiguration {
    let workflowID: UUID
    let name: String
    let request: WorkflowLLMRequest
    let hasSavedPrompt: Bool
    var languageSelection: LanguageSelection = .auto
    var microphoneBoostOverride: Bool? = nil
}
