import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import MLXVLM
import Tokenizers

actor LocalGemmaService {
    static let defaultModelID = "mlx-community/gemma-3-4b-it-4bit"

    private let modelID: String
    private let modelDirectory: URL
    private var container: ModelContainer?
    private let preparer = ImagePreparer()
    private let parser = ScoringParser()

    init(modelID: String = LocalGemmaService.defaultModelID, modelDirectory: URL = ModelStorage.defaultDirectory) {
        self.modelID = modelID
        self.modelDirectory = modelDirectory
    }

    func score(
        photoURL: URL,
        progress: @Sendable @escaping (String) -> Void
    ) async throws -> PhotoScore {
        try Task.checkCancellation()
        progress("Preparing \(photoURL.lastPathComponent)…")
        let image = try preparer.prepare(photoURL)
        let model = try await loadModel(progress: progress)
        progress("Gemma is scoring \(photoURL.lastPathComponent)…")
        let session = ChatSession(model, generateParameters: .init(maxTokens: 2_400, temperature: 0))
        let response = try await session.respond(
            to: ScoringPrompt.text,
            images: [.ciImage(image.ciImage)],
            videos: []
        )
        do { return try parser.parse(response) }
        catch {
            progress("Gemma is repairing the score format…")
            let repair = ChatSession(model, generateParameters: .init(maxTokens: 2_400, temperature: 0))
            let repaired = try await repair.respond(to: """
            Rewrite the attempted answer below as valid JSON only. Preserve its judgments; do not invent new scores. Follow the return shape in the scoring instructions.

            Attempted answer:
            \(response)
            """)
            return try parser.parse(repaired)
        }
    }

    private func loadModel(progress: @Sendable @escaping (String) -> Void) async throws -> ModelContainer {
        if let container { return container }
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        let hub = HubClient(cache: HubCache(cacheDirectory: modelDirectory))
        let configuration = ModelConfiguration(id: modelID, defaultPrompt: "", extraEOSTokens: ["<end_of_turn>"])
        let loaded = try await VLMModelFactory.shared.loadContainer(
            from: #hubDownloader(hub),
            using: #huggingFaceTokenizerLoader(),
            configuration: configuration
        ) { download in
            progress("Preparing local Gemma model… \(Int(download.fractionCompleted * 100))%")
        }
        container = loaded
        return loaded
    }
}

enum ModelStorage {
    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("com.rickmakla.SoccerShots/models", isDirectory: true)
    }
}
