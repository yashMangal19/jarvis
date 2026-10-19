#if canImport(FoundationModels)
import Foundation
import Testing
import JarvisCore

private func modelAvailable() -> Bool {
    if #available(macOS 26, *) { return FoundationModelsNoteWriter.isAvailable() }
    return false
}

private let transcript = """
    Me: Let's move the design review to Thursday at three.
    Others: Thursday works. I'll send the updated mockups by Wednesday night.
    Me: Great. Priya owns the onboarding copy, due Friday.
    Others: And we drop the dark-mode toggle from this release.
    """

/// Smoke tests against the real on-device model. Opt-in with `JARVIS_HW_TESTS=1`: the model's output varies,
/// so the gate stays deterministic, and they run once by hand before a release tag. Skipped where Apple
/// Intelligence is unavailable.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["JARVIS_HW_TESTS"] == "1", "set JARVIS_HW_TESTS=1 to use the on-device model"),
       .enabled(if: modelAvailable(), "Apple Intelligence model not available on this Mac"))
struct FoundationModelsNoteWriterTests {
    private let prompt = "Write a short meeting note: decisions, then action items with owners."

    @available(macOS 26, *)
    @Test func writesANoteFromATranscriptThatFits() async throws {
        let note = try await FoundationModelsNoteWriter().note(from: transcript, prompt: prompt)
        #expect(!note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @available(macOS 26, *)
    @Test func writesANoteFromATranscriptOverTheBudget() async throws {
        // Eight copies (~1,800 characters) over a 1,000-character budget force chunks and a merge;
        // the budget stays above one note's length so the partial notes can fit the merge.
        let long = Array(repeating: transcript, count: 8).joined(separator: "\n")
        let writer = FoundationModelsNoteWriter(maxCharacters: 1_000)
        let note = try await writer.note(from: long, prompt: prompt)
        #expect(!note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
#endif
