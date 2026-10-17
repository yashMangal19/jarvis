import AppKit
import JarvisCore
import SwiftUI

/// The Ask my memory panel: a typed question goes to `jarvis.askMemory`; a spoken one's answer arrives through
/// `onMemoryAnswer` and shows here too (story 22: spoken and shown).
struct AskMemoryView: View {
    let jarvis: Jarvis
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
            if let answer = panel.answer {
                if panel.answerWasSpoken {
                    Text("Answer to your spoken question").font(.caption).foregroundStyle(.secondary)
                }
                ScrollView {
                    Text(answer.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !answer.usedNoteIDs.isEmpty {
                    Text("Notes used").font(.headline)
                    ForEach(answer.usedNoteIDs, id: \.self) { id in
                        let file = noteFile(id)
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
        .onAppear { panel.attach(to: jarvis) }
    }

    private func ask() {
        Task { await panel.ask(jarvis) }
    }

    /// `notes/{hourly,daily,weekly}/<id>.md`, the layout `NoteStore` writes.
    private func noteFile(_ id: String) -> URL? {
        let paths = JarvisPaths.standard
        return [paths.notesHourly, paths.notesDaily, paths.notesWeekly]
            .map { $0.appending(path: "\(id).md") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// Outlives the window, so the last question and answer are still there when the panel is reopened, and a spoken
/// answer that arrives while it is closed is shown on reopening.
@MainActor
private final class AskMemoryPanel: ObservableObject {
    static let shared = AskMemoryPanel()

    @Published var question = ""
    @Published private(set) var answer: MemoryAnswer?
    @Published private(set) var answerWasSpoken = false
    @Published private(set) var asking = false
    private var attached = false

    var canAsk: Bool { !asking && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Once per process; whatever else listens to `onMemoryAnswer` keeps being called.
    func attach(to jarvis: Jarvis) {
        guard !attached else { return }
        attached = true
        let previous = jarvis.onMemoryAnswer
        jarvis.onMemoryAnswer = { [weak self] answer in
            previous(answer)
            self?.show(answer, spoken: true)
        }
    }

    func ask(_ jarvis: Jarvis) async {
        guard canAsk else { return }
        asking = true
        let answer = await jarvis.askMemory(question.trimmingCharacters(in: .whitespacesAndNewlines))
        asking = false
        show(answer, spoken: false)
    }

    private func show(_ answer: MemoryAnswer, spoken: Bool) {
        self.answer = answer
        answerWasSpoken = spoken
    }
}
