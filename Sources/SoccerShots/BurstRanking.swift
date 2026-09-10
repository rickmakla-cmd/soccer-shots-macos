import AppKit
import CoreImage
import Foundation

struct BurstRankingResponse: Equatable, Sendable {
    let winnerIndex: Int
    let ranking: [Int]
    let reason: String
    let observations: [String]
}

struct BurstRecommendation: Equatable, Sendable {
    let burstID: String
    let modelID: String
    let winnerID: UUID
    let rankedPhotoIDs: [UUID]
    let reason: String
    let observations: [String]
    let candidateCount: Int
    let totalFrameCount: Int
}

enum BurstRankingPrompt {
    static func text(filenames: [String]) -> String {
        let mapping = filenames.enumerated().map { "Frame \($0.offset + 1): \($0.element)" }.joined(separator: "\n")
        return """
        Rank this soccer burst for a photographer choosing one best frame. The single image is a contact sheet ordered left-to-right, then top-to-bottom.

        \(mapping)

        Select the frame with the strongest visibly supported photographic moment. Exact ball contact, a full-stretch save, a genuine airborne contest, or clear emotion should beat routine running and setup frames. Prefer a clearly focused subject over a soft one. Do not mistake a ball visibly held in hands above the head for a header or airborne contest. Compare the frames directly; do not assign absolute quality scores.

        Return JSON only:
        {
          "winner_index": 1,
          "ranking": [1, 2],
          "reason": "one short comparison explaining why the winner beats the runner-up",
          "observations": ["visible fact", "visible fact"]
        }
        Include every frame index exactly once in ranking, best first.
        """
    }
}

struct BurstRankingParser: Sendable {
    private struct Payload: Decodable {
        let winnerIndex: Int
        let ranking: [Int]
        let reason: String
        let observations: [String]

        enum CodingKeys: String, CodingKey {
            case winnerIndex = "winner_index"
            case ranking, reason, observations
        }
    }

    func parse(_ response: String, frameCount: Int) throws -> BurstRankingResponse {
        guard frameCount >= 2,
              let start = response.firstIndex(of: "{"), let end = response.lastIndex(of: "}"), start <= end,
              let data = String(response[start...end]).data(using: .utf8) else {
            throw SoccerShotsError.message("The burst model did not return JSON.")
        }
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: data) }
        catch { throw SoccerShotsError.message("The burst model returned invalid JSON: \(error.localizedDescription)") }

        let expected = Set(1...frameCount)
        guard expected.contains(payload.winnerIndex),
              payload.ranking.first == payload.winnerIndex,
              payload.ranking.count == frameCount,
              Set(payload.ranking) == expected else {
            throw SoccerShotsError.message("The burst model returned an incomplete or invalid frame ranking.")
        }
        return .init(
            winnerIndex: payload.winnerIndex,
            ranking: payload.ranking,
            reason: payload.reason,
            observations: Array(payload.observations.prefix(3))
        )
    }
}

enum BurstRankingCandidates {
    static let maximumFrames = 12

    static func select<T>(_ values: [T], maximum: Int = maximumFrames) -> [T] {
        BenchmarkAnalysis.evenlySpaced(values, count: maximum)
    }
}

struct BurstContactSheetBuilder: Sendable {
    private let preparer = ImagePreparer()
    private let cellSize = CGSize(width: 560, height: 380)
    private let gutter: CGFloat = 12

    func build(photoURLs: [URL]) throws -> CIImage {
        guard photoURLs.count >= 2 else {
            throw SoccerShotsError.message("At least two burst frames are required.")
        }
        let columns = min(3, photoURLs.count)
        let rows = Int(ceil(Double(photoURLs.count) / Double(columns)))
        let width = CGFloat(columns) * cellSize.width + CGFloat(columns + 1) * gutter
        let height = CGFloat(rows) * cellSize.height + CGFloat(rows + 1) * gutter
        var sheet = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))

        for (index, url) in photoURLs.enumerated() {
            try Task.checkCancellation()
            let source = try preparer.prepare(url, maxDimension: 1_200, quality: 0.8).ciImage
            let scale = min(cellSize.width / source.extent.width, cellSize.height / source.extent.height)
            let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let column = index % columns
            let row = index / columns
            let x = gutter + CGFloat(column) * (cellSize.width + gutter)
                + (cellSize.width - scaled.extent.width) / 2 - scaled.extent.minX
            let y = height - gutter - CGFloat(row + 1) * cellSize.height - CGFloat(row) * gutter
                + (cellSize.height - scaled.extent.height) / 2 - scaled.extent.minY
            sheet = scaled.transformed(by: CGAffineTransform(translationX: x, y: y)).composited(over: sheet)
            if let label = frameLabel(index + 1) {
                let plateRect = CGRect(
                    x: x + 10,
                    y: y + cellSize.height - label.extent.height - 18,
                    width: label.extent.width + 18,
                    height: label.extent.height + 8
                )
                let plate = CIImage(color: .init(red: 0, green: 0, blue: 0, alpha: 0.78))
                    .cropped(to: plateRect)
                let positionedLabel = label.transformed(by: CGAffineTransform(
                    translationX: plateRect.minX + 9 - label.extent.minX,
                    y: plateRect.minY + 4 - label.extent.minY
                ))
                sheet = positionedLabel.composited(over: plate.composited(over: sheet))
            }
        }
        return sheet
    }

    private func frameLabel(_ index: Int) -> CIImage? {
        let text = NSAttributedString(
            string: "FRAME \(index)",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 26, weight: .bold),
                .foregroundColor: NSColor.white
            ]
        )
        guard let filter = CIFilter(name: "CIAttributedTextImageGenerator") else { return nil }
        filter.setValue(text, forKey: "inputText")
        filter.setValue(1, forKey: "inputScaleFactor")
        return filter.outputImage
    }
}
