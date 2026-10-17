import Foundation

/// The engines picked at launch. `nil` means that engine is off (D-4).
public struct Engines {
    public let transcriber: (any Transcriber)?
    public let wakeWordTranscriber: (any Transcriber)?
    public let noteWriter: (any NoteWriter)?
    public let embedder: any Embedder
    public let commandRunner: (any CommandRunner)?
    public let description: EnginesDescription
}

/// The Settings "Engines" line (story 11a).
public struct EnginesDescription: Equatable {
    public let speech: String
    public let notes: String
    public let search: String
    public var line: String { "Speech: \(speech) · Notes: \(notes) · Search: \(search)" }
}

/// A search embedder that names itself, so the Engines line reads the name from the engine.
public protocol NamedEmbedder: Embedder {
    var displayName: String { get }
}

extension NLEmbedder: NamedEmbedder {}
@available(macOS 14, *) extension NLContextualEmbedder: NamedEmbedder {}
#if canImport(CoreAI)
@available(macOS 27, *) extension CoreAIEmbedder: NamedEmbedder {}
#endif

public enum EngineSelector {
    /// Pure: builds engines from probes in the spec's order and starts nothing. Whisper servers
    /// are created stopped; whoever owns the session starts them. Discarding the result is safe:
    /// a server that never launched leaves the shared pidfiles alone.
    public static func select(_ p: EngineProbes, settings: @escaping () -> Settings) -> Engines {
        let os26 = p.osVersion.majorVersion >= 26
        let speech = transcribers(p, os26: os26)
        let notes = noteWriter(p, os26: os26)
        let search: any NamedEmbedder = p.coreAIEmbedder ?? p.contextualEmbedder ?? NLEmbedder()
        let claude = p.claude.map { ClaudeCLI(executable: $0) }
        return Engines(
            transcriber: speech?.main, wakeWordTranscriber: speech?.wake, noteWriter: notes?.writer,
            embedder: search,
            commandRunner: claude.map { ClaudeCommandRunner(cli: $0, settings: settings) },
            description: EnginesDescription(speech: speech?.name ?? "none — run install.sh",
                                            notes: notes?.name ?? "off", search: search.displayName))
    }

    private static func transcribers(_ p: EngineProbes, os26: Bool)
        -> (main: any Transcriber, wake: any Transcriber, name: String)? {
        #if canImport(Speech) && compiler(>=6.2)
        if os26, let locale = p.speechAnalyzerLocale, #available(macOS 26, *) {
            let analyzer = SpeechAnalyzerTranscriber(locale: locale)
            return (analyzer, analyzer, analyzer.displayName)
        }
        #endif
        guard let (install, model) = p.whisper else { return nil }
        let wakeModel = p.wakeWordModel ?? model
        func whisper(_ model: URL, port: Int, role: String) -> WhisperTranscriber? {
            if let server = install.server {
                return WhisperTranscriber(backend: .server(WhisperServerProcess(
                    binary: server, model: model, port: port, pidFile: WhisperServerProcess.pidFile(role: role))))
            }
            return install.cli.map { WhisperTranscriber(backend: .cli(binary: $0, model: model)) }
        }
        guard let main = whisper(model, port: WhisperServerProcess.mainPort, role: "main"),
              let wake = whisper(wakeModel, port: WhisperServerProcess.wakePort, role: "wake")
        else { return nil }
        // "ggml-small.bin" → "whisper (small)".
        let size = model.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "ggml-", with: "")
        return (main, wake, "whisper (\(size))")
    }

    private static func noteWriter(_ p: EngineProbes, os26: Bool) -> (writer: any NoteWriter, name: String)? {
        if let claude = p.claude { return (ClaudeNoteWriter(cli: ClaudeCLI(executable: claude)), "Claude") }
        #if canImport(FoundationModels)
        if os26, p.foundationModelsAvailable, #available(macOS 26, *) {
            return (FoundationModelsNoteWriter(), "Apple Foundation Models")
        }
        #endif
        return p.ollamaAvailable ? (OllamaNoteWriter(), "Ollama") : nil
    }
}
