import AppKit
import JarvisCore
import SwiftUI

/// The Ask my memory panel: a typed question goes to `jarvis.askMemory`. The answer shown is
/// `jarvis.lastMemoryAnswer`, the latest one since launch, typed or spoken (story 22: spoken and shown).
struct AskMemoryView: View {
    @ObservedObject var jarvis: Jarvis
    @ObservedObject private var panel = AskMemoryPanel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Ask a question about your notes", text: $panel.question)
                    .onSubmit(ask)
                Button("Ask", action: ask)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!panel.canAsk)
            }
            if panel.asking {
                ProgressView().controlSize(.small)
            }
            if let shown = jarvis.lastMemoryAnswer {
                if shown.spoken {
                    Text("Answer to your spoken question").font(.caption).foregroundStyle(.secondary)
                }
                ScrollView {
                    Text(shown.answer.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !shown.answer.usedNoteIDs.isEmpty {
                    Text("Notes used").font(.headline)
                    ForEach(shown.answer.usedNoteIDs, id: \.self) { id in
                        let file = jarvis.noteFile(id: id)
                        Button(id) { if let file { NSWorkspace.shared.open(file) } }
                            .buttonStyle(.link)
                            .disabled(file == nil)
                            .help(file == nil ? "This note no longer exists" : "Open the note")
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding()
        .frame(minWidth: 420, minHeight: 280)
    }

    private func ask() {
        Task { await panel.ask(jarvis) }
    }
}

/// Outlives the window, so the question typed last is still there when the panel is reopened.
@MainActor
private final class AskMemoryPanel: ObservableObject {
    static let shared = AskMemoryPanel()

    @Published var question = ""
    @Published private(set) var asking = false

    var canAsk: Bool { !asking && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func ask(_ jarvis: Jarvis) async {
        guard canAsk else { return }
        asking = true
        _ = await jarvis.askMemory(question.trimmingCharacters(in: .whitespacesAndNewlines))
        asking = false
    }
}
