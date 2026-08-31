import Foundation
import CoreImage
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import MLXVLM
import Tokenizers

actor LocalGemmaService {
    static let defaultModelID = "mlx-community/gemma-3-4b-it-4bit"
    static let defaultBenchmarkModelID = "mlx-community/gemma-4-e4b-it-8bit"

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

    func unload() {
        container = nil
    }

    /// Confirms that the loaded VLM is actually consuming image input. Some
    /// Gemma 4 runtime combinations can generate plausible text while silently
    /// dropping the image, which would make an A/B score look valid when it is not.
    func verifyVision(progress: @Sendable @escaping (String) -> Void) async throws {
        try Task.checkCancellation()
        progress("Loading Gemma 4 for a vision check…")
        let model = try await loadModel(progress: progress)

        let extent = CGRect(x: 0, y: 0, width: 512, height: 512)
        let leftExtent = CGRect(x: 0, y: 0, width: 256, height: 512)
        let rightExtent = CGRect(x: 256, y: 0, width: 256, height: 512)
        let magenta = CIImage(color: CIColor(red: 1, green: 0, blue: 1)).cropped(to: leftExtent)
        let yellow = CIImage(color: CIColor(red: 1, green: 1, blue: 0)).cropped(to: rightExtent)
        let testImage = magenta.composited(over: yellow).cropped(to: extent)

        progress("Verifying that Gemma 4 can see image pixels…")
        let session = ChatSession(model, generateParameters: .init(maxTokens: 120, temperature: 0))
        let response = try await session.respond(
            to: """
            Inspect the supplied test image. Name the solid color filling its left half and the solid color filling its right half. Return JSON only in this exact shape:
            {"left":"basic color name","right":"basic color name"}
            """,
            images: [.ciImage(testImage)],
            videos: []
        )

        guard let jsonStart = response.firstIndex(of: "{"),
              let jsonEnd = response.lastIndex(of: "}"),
              jsonStart <= jsonEnd,
              let data = String(response[jsonStart...jsonEnd]).data(using: .utf8),
              let answer = try? JSONDecoder().decode(VisionProbeAnswer.self, from: data) else {
            throw SoccerShotsError.message(
                "Gemma 4 loaded, but its vision check did not return valid JSON. No benchmark scores were saved."
            )
        }

        let left = answer.left.lowercased()
        let right = answer.right.lowercased()
        let recognizedLeft = left.contains("magenta") || left.contains("purple")
        guard recognizedLeft, right.contains("yellow") else {
            throw SoccerShotsError.message(
                "Gemma 4 loaded, but it did not identify the test image correctly (left: \(answer.left), right: \(answer.right)). The runtime may be ignoring images, so no benchmark scores were saved."
            )
        }
    }

    private func loadModel(progress: @Sendable @escaping (String) -> Void) async throws -> ModelContainer {
        if let container { return container }
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        let hub = HubClient(cache: HubCache(cacheDirectory: modelDirectory))
        let legacyGemmaEOS = modelID.lowercased().contains("gemma-3") ? ["<end_of_turn>"] : []
        let configuration = ModelConfiguration(
            id: modelID,
            defaultPrompt: "",
            extraEOSTokens: legacyGemmaEOS
        )
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

private struct VisionProbeAnswer: Decodable {
    let left: String
    let right: String
}

enum ModelStorage {
    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("com.rickmakla.SoccerShots/models", isDirectory: true)
    }
}
