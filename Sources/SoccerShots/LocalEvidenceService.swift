import CoreImage
import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import MLXVLM
import Tokenizers
import Vision

actor LocalEvidenceService {
    private let modelID: String
    private let modelDirectory: URL
    private var container: ModelContainer?
    private let preparer = ImagePreparer()

    init(modelID: String, modelDirectory: URL = ModelStorage.defaultDirectory) {
        self.modelID = modelID
        self.modelDirectory = modelDirectory
    }

    func inspect(photoURL: URL, progress: @Sendable @escaping (String) -> Void) async throws -> PhotoEvidence {
        try Task.checkCancellation()
        progress("Preparing full frame and player crop…")
        let prepared = try preparer.prepare(photoURL)
        var images: [UserInput.Image] = [.ciImage(prepared.ciImage)]
        if let crop = prominentHumanCrop(in: prepared.ciImage) { images.append(.ciImage(crop)) }
        let model = try await loadModel(progress: progress)
        progress("Inspecting visible evidence…")
        let session = ChatSession(model, generateParameters: .init(maxTokens: 900, temperature: 0))
        let response = try await session.respond(to: EvidencePrompt.text, images: images, videos: [], audios: [])
        return try EvidenceParser().parse(response)
    }

    func verifyVision(progress: @Sendable @escaping (String) -> Void) async throws {
        progress("Verifying image input…")
        let model = try await loadModel(progress: progress)
        let extent = CGRect(x: 0, y: 0, width: 512, height: 512)
        let left = CIImage(color: .init(red: 1, green: 0, blue: 1)).cropped(to: .init(x: 0, y: 0, width: 256, height: 512))
        let right = CIImage(color: .init(red: 1, green: 1, blue: 0)).cropped(to: .init(x: 256, y: 0, width: 256, height: 512))
        let image = left.composited(over: right).cropped(to: extent)
        let session = ChatSession(model, generateParameters: .init(maxTokens: 80, temperature: 0))
        let response = try await session.respond(
            to: "Return JSON only: {\"left\":\"color\",\"right\":\"color\"} for the two halves of this image.",
            images: [.ciImage(image)], videos: [], audios: []
        )
        guard let start = response.firstIndex(of: "{"), let end = response.lastIndex(of: "}"),
              let data = String(response[start...end]).data(using: .utf8),
              let answer = try? JSONDecoder().decode(VisionProbe.self, from: data),
              answer.left.lowercased().contains("magenta") || answer.left.lowercased().contains("purple"),
              answer.right.lowercased().contains("yellow") else {
            throw SoccerShotsError.message("The candidate loaded but did not pass the image-input check.")
        }
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

    private func prominentHumanCrop(in image: CIImage) -> CIImage? {
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observations = request.results, !observations.isEmpty else { return nil }
        let chosen = observations.max { lhs, rhs in
            prominence(lhs.boundingBox) < prominence(rhs.boundingBox)
        }
        guard let box = chosen?.boundingBox else { return nil }
        let extent = image.extent
        var crop = CGRect(
            x: extent.minX + box.minX * extent.width,
            y: extent.minY + box.minY * extent.height,
            width: box.width * extent.width,
            height: box.height * extent.height
        )
        crop = crop.insetBy(dx: -crop.width * 0.35, dy: -crop.height * 0.18).intersection(extent)
        guard crop.width > 40, crop.height > 40 else { return nil }
        return image.cropped(to: crop)
    }

    private func prominence(_ box: CGRect) -> CGFloat {
        let area = box.width * box.height
        let centerDistance = hypot(box.midX - 0.5, box.midY - 0.5)
        return area - centerDistance * 0.05
    }
}

private struct VisionProbe: Decodable {
    let left: String
    let right: String
}
