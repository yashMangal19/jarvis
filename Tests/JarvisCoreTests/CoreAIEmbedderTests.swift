#if canImport(CoreAI)
import Foundation
import Testing
@testable import JarvisCore

@Suite struct CoreAIEmbedderTests {
    private func emptyModelsFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func loadIsNilWhenTheModelFileIsMissing() throws {
        guard #available(macOS 27, *) else { return }
        let models = try emptyModelsFolder()
        defer { try? FileManager.default.removeItem(at: models) }

        #expect(CoreAIEmbedder.load(from: models, environment: [:]) == nil)
    }
    @Test func loadIsNilWhenTheModelFileIsNotAModel() throws {
        guard #available(macOS 27, *) else { return }
        let models = try emptyModelsFolder()
        defer { try? FileManager.default.removeItem(at: models) }
        try Data("not a model".utf8).write(to: models.appending(path: CoreAIEmbedder.modelFileName))

        #expect(CoreAIEmbedder.load(from: models, environment: [:]) == nil)
    }

    /// Runs only on a Mac where the real model has been installed in ~/Jarvis/models.
    @Test(.enabled(if: FileManager.default.fileExists(
        atPath: JarvisPaths.standard.models.appending(path: "jarvis-embedding.aimodel").path)))
    func installedModelLoadsEmbedsAtFixedDimensionAndCanBeDisabled() throws {
        guard #available(macOS 27, *) else { return }
        let models = JarvisPaths.standard.models
        let embedder = try #require(CoreAIEmbedder.load(from: models, environment: [:]))

        #expect(try embedder.embed("standup moved to Thursday").count == embedder.dimension)
        #expect(try embedder.embed("a").count == embedder.dimension)
        #expect(CoreAIEmbedder.load(from: models, environment: ["JARVIS_DISABLE_COREAI": "1"]) == nil)
    }
}
#endif
