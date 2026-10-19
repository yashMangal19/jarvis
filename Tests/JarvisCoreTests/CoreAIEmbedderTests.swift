#if canImport(CoreAI)
import Foundation
import Testing
@testable import JarvisCore

private let macOS27 = ProcessInfo.processInfo.isOperatingSystemAtLeast(
    OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))

private let installedModel = macOS27 && FileManager.default.fileExists(
    atPath: JarvisPaths.standard.models.appending(path: "jarvis-embedding.aimodel").path)

private struct ModelRan: Error {}

@Suite(.enabled(if: macOS27, "Core AI needs macOS 27"))
struct CoreAIEmbedderTests {
    private func emptyModelsFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func loadIsNilWhenTheModelFileIsMissing() async throws {
        guard #available(macOS 27, *) else { return }
        let models = try emptyModelsFolder()
        defer { try? FileManager.default.removeItem(at: models) }

        #expect(await CoreAIEmbedder.load(from: models, environment: [:]) == nil)
    }
    @Test func loadIsNilWhenTheModelFileIsNotAModel() async throws {
        guard #available(macOS 27, *) else { return }
        let models = try emptyModelsFolder()
        defer { try? FileManager.default.removeItem(at: models) }
        try Data("not a model".utf8).write(to: models.appending(path: CoreAIEmbedder.modelFileName))

        #expect(await CoreAIEmbedder.load(from: models, environment: [:]) == nil)
    }

    @Test func emptyTextEmbedsToAZeroVectorWithoutRunningTheModel() throws {
        guard #available(macOS 27, *) else { return }
        let embedder = CoreAIEmbedder(dimension: 3) { _ in throw ModelRan() }

        #expect(try embedder.embed("") == [0, 0, 0])
    }

    @Test func textLongerThanTheModelSequenceLengthIsTruncated() throws {
        guard #available(macOS 27, *) else { return }
        let embedder = CoreAIEmbedder(dimension: 1, maxInputLength: 4) { ids in [Float(ids.count)] }

        #expect(try embedder.embed("standup") == [4])
    }

    /// Many more blocked async callers than cores: the old bridge deadlocked here.
    @Test(.timeLimit(.minutes(1)))
    func concurrentEmbedsFromAsyncTasksComplete() async throws {
        guard #available(macOS 27, *) else { return }
        let embedder = CoreAIEmbedder(dimension: 1) { _ in await Task.yield(); return [1] }

        let total = try await withThrowingTaskGroup(of: Float.self) { group in
            for _ in 0..<64 { group.addTask { try embedder.embed("x")[0] } }
            return try await group.reduce(0, +)
        }
        #expect(total == 64)
    }

    /// Runs only on a Mac where the real model has been installed in the data home's models folder.
    @Test(.enabled(if: installedModel, "needs models/jarvis-embedding.aimodel in the data home"))
    func installedModelLoadsEmbedsAtFixedDimensionAndCanBeDisabled() async throws {
        guard #available(macOS 27, *) else { return }
        let models = JarvisPaths.standard.models
        let embedder = try #require(await CoreAIEmbedder.load(from: models, environment: [:]))

        #expect(try embedder.embed("standup moved to Thursday").count == embedder.dimension)
        #expect(try embedder.embed("a").count == embedder.dimension)
        #expect(await CoreAIEmbedder.load(from: models, environment: ["JARVIS_DISABLE_COREAI": "1"]) == nil)
    }
}
#endif
