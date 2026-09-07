import Foundation
import SwiftData

@Model
final class ScoreRecord {
    @Attribute(.unique) var filepath: String
    var filename: String
    var fileSize: Int64
    var modificationDate: Date
    var sessionFolder: String
    var scoredAt: Date
    var scoringVersion: String
    var scoringEngine: String
    var isPostProcessed: Bool
    var isManuallyRejected: Bool
    var isSelectedForExport: Bool
    var manualReviewLabelRaw: String?
    @Attribute(.externalStorage) var scoreData: Data
    @Attribute(.externalStorage) var deepReviewData: Data?
    @Attribute(.externalStorage) var benchmarkData: Data?
    @Attribute(.externalStorage) var geminiBatchData: Data?
    @Attribute(.externalStorage) var evidenceBenchmarkData: Data?

    init(photo: ScoredPhoto) throws {
        filepath = photo.fileURL.path
        filename = photo.filename
        fileSize = photo.fileSize
        modificationDate = photo.modificationDate
        sessionFolder = photo.sessionFolder.path
        scoredAt = photo.scoredAt
        scoringVersion = photo.scoringVersion
        scoringEngine = photo.scoringEngine
        isPostProcessed = photo.isPostProcessed
        isManuallyRejected = photo.isManuallyRejected
        isSelectedForExport = photo.isSelectedForExport
        manualReviewLabelRaw = photo.manualReviewLabel?.rawValue
        scoreData = try JSONEncoder().encode(photo.score)
        deepReviewData = try photo.deepReview.map { try JSONEncoder().encode($0) }
        benchmarkData = try photo.benchmarkResult.map { try JSONEncoder().encode($0) }
        geminiBatchData = try photo.geminiBatchResult.map { try JSONEncoder().encode($0) }
        evidenceBenchmarkData = photo.evidenceBenchmarkResults.isEmpty
            ? nil
            : try JSONEncoder().encode(photo.evidenceBenchmarkResults)
    }

    var score: PhotoScore? { try? JSONDecoder().decode(PhotoScore.self, from: scoreData) }
    var deepReview: DeepReview? { deepReviewData.flatMap { try? JSONDecoder().decode(DeepReview.self, from: $0) } }
    var benchmarkResult: ModelBenchmarkResult? {
        benchmarkData.flatMap { try? JSONDecoder().decode(ModelBenchmarkResult.self, from: $0) }
    }
    var geminiBatchResult: ModelBenchmarkResult? {
        geminiBatchData.flatMap { try? JSONDecoder().decode(ModelBenchmarkResult.self, from: $0) }
    }
    var evidenceBenchmarkResults: [EvidenceBenchmarkResult] {
        evidenceBenchmarkData.flatMap { try? JSONDecoder().decode([EvidenceBenchmarkResult].self, from: $0) } ?? []
    }

    func setDeepReview(_ review: DeepReview?) throws {
        deepReviewData = try review.map { try JSONEncoder().encode($0) }
    }

    func setBenchmarkResult(_ result: ModelBenchmarkResult?) throws {
        benchmarkData = try result.map { try JSONEncoder().encode($0) }
    }

    func setGeminiBatchResult(_ result: ModelBenchmarkResult?) throws {
        geminiBatchData = try result.map { try JSONEncoder().encode($0) }
    }

    func setEvidenceBenchmarkResults(_ results: [EvidenceBenchmarkResult]) throws {
        evidenceBenchmarkData = results.isEmpty ? nil : try JSONEncoder().encode(results)
    }

    func cacheMatches(_ photo: DiscoveredPhoto) -> Bool {
        fileSize == photo.fileSize && abs(modificationDate.timeIntervalSince(photo.modificationDate)) < 0.001
    }
}
