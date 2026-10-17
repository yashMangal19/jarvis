import Foundation

/// What this Mac offers, measured once at launch. `EngineSelector.select` turns it into engines.
public struct EngineProbes {
    public var osVersion: OperatingSystemVersion
    public var claude: URL?
    /// The whisper.cpp binaries and the main model; `nil` when either is missing.
    public var whisper: (install: WhisperInstall, model: URL)?
    public var wakeWordModel: URL?
    /// The locale SpeechAnalyzer would transcribe; `nil` when it does not cover every preferred locale.
    public var speechAnalyzerLocale: Locale?
    public var foundationModelsAvailable: Bool
    public var coreAIEmbedder: (any NamedEmbedder)?
    /// `NLContextualEmbedder`, `nil` below macOS 14 or when its assets are not on this Mac at launch.
    public var contextualEmbedder: (any NamedEmbedder)?
    public var ollamaAvailable: Bool

    public init(osVersion: OperatingSystemVersion, claude: URL?, whisper: (install: WhisperInstall, model: URL)?,
                wakeWordModel: URL?, speechAnalyzerLocale: Locale?, foundationModelsAvailable: Bool,
                coreAIEmbedder: (any NamedEmbedder)?, contextualEmbedder: (any NamedEmbedder)?,
                ollamaAvailable: Bool) {
        self.osVersion = osVersion
        self.claude = claude
        self.whisper = whisper
        self.wakeWordModel = wakeWordModel
        self.speechAnalyzerLocale = speechAnalyzerLocale
        self.foundationModelsAvailable = foundationModelsAvailable
        self.coreAIEmbedder = coreAIEmbedder
        self.contextualEmbedder = contextualEmbedder
        self.ollamaAvailable = ollamaAvailable
    }

    /// The only side-effecting part of selection: runs every detector behind its own guard.
    /// Not unit-tested — it may ask Ollama over HTTP. Missing contextual assets are requested in the
    /// background and do not delay selection; they are picked up at a later launch.
    public static func live(paths: JarvisPaths, preferredLocales: [Locale]) async -> EngineProbes {
        let install = WhisperInstall.locate()
        let model = WhisperInstall.preferredModel(in: paths.models)
        var speechLocale: Locale?
        #if canImport(Speech) && compiler(>=6.2)
        if #available(macOS 26, *), await SpeechAnalyzerTranscriber.isUsable(forPreferred: preferredLocales) {
            speechLocale = preferredLocales.first ?? Locale.current
        }
        #endif
        var foundationModels = false
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { foundationModels = FoundationModelsNoteWriter.isAvailable() }
        #endif
        var coreAI: (any NamedEmbedder)?
        #if canImport(CoreAI)
        if #available(macOS 27, *) { coreAI = await CoreAIEmbedder.load(from: paths.models) }
        #endif
        var contextual: (any NamedEmbedder)?
        if coreAI == nil, #available(macOS 14, *) { contextual = NLContextualEmbedder.load() }
        return EngineProbes(
            osVersion: ProcessInfo.processInfo.operatingSystemVersion,
            claude: ClaudeCLI.locate(),
            whisper: install.server == nil && install.cli == nil ? nil : model.map { (install, $0) },
            wakeWordModel: WhisperInstall.wakeWordModel(in: paths.models),
            speechAnalyzerLocale: speechLocale,
            foundationModelsAvailable: foundationModels,
            coreAIEmbedder: coreAI,
            contextualEmbedder: contextual,
            ollamaAvailable: await OllamaInstall.isAvailable())
    }
}
