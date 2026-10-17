import Foundation
import Testing
@testable import JarvisCore

@Suite struct EngineSelectorTests {
    @Test func macOS15WithClaudeAndWhisperPicksWhisperClaudeAndNaturalLanguage() {
        let probes = selectorProbes(os: 15, claude: true, whisper: true)
        let engines = EngineSelector.select(probes, settings: { .default })
        #expect(engines.description.line == "Speech: whisper (small) · Notes: Claude · Search: NaturalLanguage")
    }

    @Test(arguments: [
        SelectorRow(os: 27, whisper: true, foundationModels: true, ollama: true,
                    speech: "whisper (small)", notes: "Apple Foundation Models", search: "NaturalLanguage"),
        SelectorRow(os: 15, whisper: true, foundationModels: true, ollama: true,
                    speech: "whisper (small)", notes: "Ollama", search: "NaturalLanguage"),
        SelectorRow(os: 27, whisper: true, ollama: true,
                    speech: "whisper (small)", notes: "Ollama", search: "NaturalLanguage"),
        SelectorRow(os: 27, claude: true, foundationModels: true, ollama: true,
                    speech: "none — run install.sh", notes: "Claude", search: "NaturalLanguage"),
        SelectorRow(os: 15, speech: "none — run install.sh", notes: "off", search: "NaturalLanguage"),
        SelectorRow(os: 27, whisper: true, speechAnalyzer: true,
                    speech: "Apple SpeechAnalyzer", notes: "off", search: "NaturalLanguage"),
        SelectorRow(os: 15, whisper: true, speechAnalyzer: true,
                    speech: "whisper (small)", notes: "off", search: "NaturalLanguage"),
        SelectorRow(os: 27, whisper: true, coreAI: true, contextual: true,
                    speech: "whisper (small)", notes: "off", search: "Core AI"),
        SelectorRow(os: 27, whisper: true, contextual: true,
                    speech: "whisper (small)", notes: "off", search: "Apple contextual"),
    ])
    func probeMatrix(_ row: SelectorRow) {
        let engines = EngineSelector.select(row.probes, settings: { .default })
        #expect(engines.description == EnginesDescription(speech: row.speech, notes: row.notes, search: row.search))
        #expect((engines.transcriber == nil) == (row.speech == "none — run install.sh"))
        #expect((engines.noteWriter == nil) == (row.notes == "off"))
    }

    @Test func onlyClaudeGivesACommandRunner() {
        #expect(EngineSelector.select(selectorProbes(os: 15, claude: true), settings: { .default }).commandRunner != nil)
        #expect(EngineSelector.select(selectorProbes(os: 27, foundationModels: true, ollama: true),
                                      settings: { .default }).commandRunner == nil)
    }

    @Test func wakeWordUsesItsOwnModelOnItsOwnServerAndFallsBackToTheMainModel() throws {
        let base = URL(filePath: "/selector-test/models/ggml-base.en.bin")
        let own = EngineSelector.select(selectorProbes(os: 15, whisper: true, wakeWordModel: base), settings: { .default })
        let wake = try #require(own.wakeWordTranscriber as? WhisperTranscriber)
        guard case let .server(server) = wake.backend else { Issue.record("expected server backend"); return }
        #expect(server.model == base)
        #expect(server.port == WhisperServerProcess.wakePort)
        #expect(server.pidFile == WhisperServerProcess.pidFile(role: "wake"))

        let fallback = EngineSelector.select(selectorProbes(os: 15, whisper: true), settings: { .default })
        #expect((fallback.wakeWordTranscriber as? WhisperTranscriber)?.displayName == "whisper (ggml-small.bin)")
    }

    @Test func speechAnalyzerAlsoListensForTheWakeWord() {
        let engines = EngineSelector.select(selectorProbes(os: 27, whisper: true, speechAnalyzerLocale: Locale(identifier: "en_US")),
                                            settings: { .default })
        #expect(engines.wakeWordTranscriber != nil)
        #expect(!(engines.wakeWordTranscriber is WhisperTranscriber))
    }

    @Test func aCliOnlyInstallUsesTheCliBackend() throws {
        var probes = selectorProbes(os: 15)
        probes.whisper = (install: WhisperInstall(server: nil, cli: URL(filePath: "/selector-test/bin/whisper-cli")),
                          model: URL(filePath: "/selector-test/models/ggml-medium.bin"))
        let engines = EngineSelector.select(probes, settings: { .default })
        let main = try #require(engines.transcriber as? WhisperTranscriber)
        guard case .cli = main.backend else { Issue.record("expected cli backend"); return }
        #expect(engines.description.speech == "whisper (medium)")
    }
}

struct SelectorRow: Sendable, CustomTestStringConvertible {
    var os: Int
    var claude = false, whisper = false, speechAnalyzer = false, foundationModels = false
    var coreAI = false, contextual = false, ollama = false
    var speech: String, notes: String, search: String

    var probes: EngineProbes {
        selectorProbes(os: os, claude: claude, whisper: whisper,
                       speechAnalyzerLocale: speechAnalyzer ? Locale(identifier: "en_US") : nil,
                       foundationModels: foundationModels, coreAI: coreAI, contextual: contextual, ollama: ollama)
    }
    var testDescription: String { "macOS \(os) → \(speech) · \(notes) · \(search)" }
}

/// A probe set with everything off unless named.
private func selectorProbes(os major: Int, claude: Bool = false, whisper: Bool = false,
                            wakeWordModel: URL? = nil, speechAnalyzerLocale: Locale? = nil,
                            foundationModels: Bool = false, coreAI: Bool = false,
                            contextual: Bool = false, ollama: Bool = false) -> EngineProbes {
    let bin = URL(filePath: "/selector-test/bin")
    let models = URL(filePath: "/selector-test/models")
    return EngineProbes(
        osVersion: OperatingSystemVersion(majorVersion: major, minorVersion: 0, patchVersion: 0),
        claude: claude ? bin.appending(path: "claude") : nil,
        whisper: whisper ? (install: WhisperInstall(server: bin.appending(path: "whisper-server"), cli: nil),
                            model: models.appending(path: "ggml-small.bin")) : nil,
        wakeWordModel: wakeWordModel,
        speechAnalyzerLocale: speechAnalyzerLocale,
        foundationModelsAvailable: foundationModels,
        coreAIEmbedder: coreAI ? SelectorStubEmbedder() : nil,
        contextualEmbedder: contextual ? SelectorStubEmbedder() : nil,
        ollamaAvailable: ollama)
}

private struct SelectorStubEmbedder: Embedder {
    func embed(_ text: String) throws -> [Float] { [1] }
}
