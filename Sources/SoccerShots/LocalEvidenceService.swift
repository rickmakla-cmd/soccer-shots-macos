import CoreImage
import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import MLXVLM
import Tokenizers

actor LocalEvidenceService {
    struct Inspection: Sendable {
        let evidence: PhotoEvidence
        let pixelSharpness: Double?
    }
    private let modelID: String
    private let modelDirectory: URL
    private var container: ModelContainer?
    private let preparer = ImagePreparer()
    private let contactSheetBuilder = BurstContactSheetBuilder()

    init(modelID: String, modelDirectory: URL = ModelStorage.defaultDirectory) {
        self.modelID = modelID
        self.modelDirectory = modelDirectory
    }

    func inspect(photoURL: URL, progress: @Sendable @escaping (String) -> Void) async throws -> Inspection {
        try Task.checkCancellation()
        progress("Preparing full frame…")
        let prepared = try preparer.prepare(photoURL)
        // The pinned Gemma 4 and Qwen 3.5 processors can both terminate the
        // process while combining differently shaped images. MLX reports these
        // failures as fatal assertions, so every local model receives one image.
        let images: [UserInput.Image] = [.ciImage(prepared.ciImage)]
        let model = try await loadModel(progress: progress)
        progress("Inspecting visible evidence…")
        let session = ChatSession(
            model,
            generateParameters: .init(maxTokens: 900, temperature: 0),
            additionalContext: ["enable_thinking": false]
        )
        let response = try await session.respond(to: EvidencePrompt.text, images: images, videos: [], audios: [])
        let evidence = try EvidenceParser().parse(response)
        return .init(
            evidence: evidence,
            pixelSharpness: PixelSharpnessAnalyzer().score(
                prepared.cgImage,
                horizontalPosition: evidence.subjectHorizontalPosition
            )
        )
    }

    func verifyVision(progress: @Sendable @escaping (String) -> Void) async throws {
        progress("Verifying image input…")
        let model = try await loadModel(progress: progress)
        let extent = CGRect(x: 0, y: 0, width: 512, height: 512)
        let left = CIImage(color: .init(red: 1, green: 0, blue: 1)).cropped(to: .init(x: 0, y: 0, width: 256, height: 512))
        let right = CIImage(color: .init(red: 1, green: 1, blue: 0)).cropped(to: .init(x: 256, y: 0, width: 256, height: 512))
        let image = left.composited(over: right).cropped(to: extent)
        let session = ChatSession(
            model,
            generateParameters: .init(maxTokens: 240, temperature: 0),
            additionalContext: ["enable_thinking": false]
        )
        let response = try await session.respond(
            to: "Name the visible color on each half of this image. Answer briefly as LEFT=<color>; RIGHT=<color>.",
            images: [.ciImage(image)], videos: [], audios: []
        )
        guard EvidenceVisionProbe.passes(response) else {
            let diagnostic = EvidenceVisionProbe.diagnostic(response)
            throw SoccerShotsError.message(
                "The candidate loaded but its image check was inconclusive. Response: \(diagnostic)"
            )
        }
    }

    func rankBurst(
        photoURLs: [URL],
        filenames: [String],
        progress: @Sendable @escaping (String) -> Void
    ) async throws -> BurstRankingResponse {
        guard photoURLs.count == filenames.count else {
            throw SoccerShotsError.message("The burst frames and filenames did not match.")
        }
        try Task.checkCancellation()
        progress("Building one \(photoURLs.count)-frame contact sheet…")
        let sheet = try contactSheetBuilder.build(photoURLs: photoURLs)
        let model = try await loadModel(progress: progress)
        progress("Comparing burst moments…")
        let session = ChatSession(
            model,
            generateParameters: .init(maxTokens: 700, temperature: 0),
            additionalContext: ["enable_thinking": false]
        )
        let response = try await session.respond(
            to: BurstRankingPrompt.text(filenames: filenames),
            images: [.ciImage(sheet)], videos: [], audios: []
        )
        return try BurstRankingParser().parse(response, frameCount: photoURLs.count)
    }

    func unload() { container = nil }

    private func loadModel(progress: @Sendable @escaping (String) -> Void) async throws -> ModelContainer {
        if let container { return container }
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        let hub = HubClient(cache: HubCache(cacheDirectory: modelDirectory))
        let configuration = ModelConfiguration(id: modelID, defaultPrompt: "")
        let loaded = try await VLMModelFactory.shared.loadContainer(
            from: #hubDownloader(hub), using: #huggingFaceTokenizerLoader(), configuration: configuration
        ) { download in
            progress("Preparing \(self.modelID)… \(Int(download.fractionCompleted * 100))%")
        }
        container = loaded
        return loaded
    }

}
