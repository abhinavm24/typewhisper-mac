import AppKit
import Combine
import SwiftUI

@MainActor
final class WorkflowVoiceEditingWindowController: NSObject, NSWindowDelegate {
    private let coordinator: WorkflowVoiceEditingCoordinator
    private var panel: NSPanel?
    private var subscription: AnyCancellable?

    init(coordinator: WorkflowVoiceEditingCoordinator) {
        self.coordinator = coordinator
        super.init()
        subscription = coordinator.$state.receive(on: DispatchQueue.main).sink { [weak self] state in
            guard let self, state == coordinator.state else { return }
            if state == .idle { panel?.orderOut(nil) }
        }
    }

    func show() {
        if panel == nil {
            let panel = WorkflowVoiceEditingPanel(
                contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            panel.title = localizedAppText("Workflow review", de: "Workflow-Review")
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.contentMinSize = NSSize(width: 420, height: 360)
            panel.contentView = NSHostingView(rootView: WorkflowVoiceEditingView(coordinator: coordinator))
            panel.delegate = self
            panel.center()
            self.panel = panel
        }
        panel?.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard coordinator.state != .applying else { return false }
        coordinator.cancel()
        return true
    }
}

private final class WorkflowVoiceEditingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct WorkflowVoiceEditingView: View {
    @ObservedObject var coordinator: WorkflowVoiceEditingCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(coordinator.workflowName).font(.headline)
                    Text(status).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if coordinator.isBusy { ProgressView().controlSize(.small) }
            }
            if let error = coordinator.errorMessage {
                Text(error).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 16) {
                textPane(localizedAppText("Selected text", de: "Markierter Text"), text: coordinator.original)
                if !coordinator.result.isEmpty {
                    textPane(localizedAppText("Result", de: "Ergebnis"), text: coordinator.result)
                }
            }
            if coordinator.state == .preview || coordinator.state == .failed {
                VStack(alignment: .leading, spacing: 4) {
                    Text(localizedAppText("Additional instruction", de: "Zusätzliche Anweisung"))
                        .font(.subheadline)
                    TextEditor(text: $coordinator.instruction)
                        .frame(minHeight: 60, maxHeight: 100)
                        .border(Color.secondary.opacity(0.25))
                    if coordinator.instruction != coordinator.generatedInstruction && !coordinator.result.isEmpty {
                        Text(localizedAppText("Run again to apply the edited instruction.", de: "Erneut ausführen, um die geänderte Anweisung anzuwenden."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button(localizedAppText("Cancel", de: "Abbrechen")) { coordinator.cancel() }
                    .disabled(coordinator.state == .applying || coordinator.state == .cancelling)
                Spacer()
                if coordinator.state == .recording {
                    if coordinator.canUseSavedPrompt {
                        Button(localizedAppText("Use saved prompt", de: "Gespeicherten Prompt verwenden")) {
                            coordinator.finishRecording(useSavedPrompt: true)
                        }
                    }
                    Button(localizedAppText("Finish instruction", de: "Anweisung abschließen")) {
                        coordinator.finishRecording()
                    }.keyboardShortcut(.defaultAction)
                } else if coordinator.state == .preview || coordinator.state == .failed {
                    Button(localizedAppText("Run again", de: "Erneut ausführen")) { coordinator.retry() }
                        .disabled(coordinator.isBusy || (!coordinator.canUseSavedPrompt && coordinator.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    Button(localizedAppText("Copy", de: "Kopieren")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(coordinator.result, forType: .string)
                    }.disabled(coordinator.result.isEmpty || coordinator.isBusy || coordinator.instruction != coordinator.generatedInstruction)
                    Button(localizedAppText("Replace", de: "Ersetzen")) { coordinator.apply() }
                        .disabled(!coordinator.canApply)
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func textPane(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            ScrollView {
                Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var status: String {
        switch coordinator.state {
        case .idle: localizedAppText("Workflow review", de: "Workflow-Review")
        case .starting: localizedAppText("Starting microphone…", de: "Mikrofon wird gestartet…")
        case .recording: localizedAppText("Speak an instruction to add to this workflow.", de: "Sprich eine zusätzliche Anweisung für diesen Workflow.")
        case .transcribing: localizedAppText("Transcribing instruction…", de: "Anweisung wird transkribiert…")
        case .generating: localizedAppText("Running workflow…", de: "Workflow wird ausgeführt…")
        case .preview: localizedAppText("Review before replacing or copying.", de: "Vor dem Ersetzen oder Kopieren prüfen.")
        case .applying: localizedAppText("Checking and replacing selection…", de: "Auswahl wird geprüft und ersetzt…")
        case .cancelling: localizedAppText("Cancelling…", de: "Wird abgebrochen…")
        case .failed: localizedAppText("Workflow needs attention", de: "Workflow benötigt Aufmerksamkeit")
        }
    }
}
