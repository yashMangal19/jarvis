#if canImport(FoundationModels)
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

/// Smoke tests against the real on-device model; skipped where Apple Intelligence is unavailable.
@Suite(.enabled(if: modelAvailable(), "Apple Intelligence model not available on this Mac"))
struct FoundationModelsNoteWriterTests {
    private let prompt = "Write a short meeting note: decisions, then action items with owners."

    @available(macOS 26, *)
    @Test func writesANoteFromATranscriptThatFits() async throws {
        let note = try await FoundationModelsNoteWriter().note(from: transcript, prompt: prompt)
        #expect(!note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @available(macOS 26, *)
    @Test func writesANoteFromATranscriptOverTheBudget() async throws {
        // A budget of two lines forces two chunks and a merge call.
        let writer = FoundationModelsNoteWriter(maxCharacters: 130)
        let note = try await writer.note(from: transcript, prompt: prompt)
        #expect(!note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
#endif
