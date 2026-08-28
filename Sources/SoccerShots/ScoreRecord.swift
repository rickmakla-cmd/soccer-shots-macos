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
    @Attribute(.externalStorage) var scoreData: Data
    @Attribute(.externalStorage) var deepReviewData: Data?

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
        scoreData = try JSONEncoder().encode(photo.score)
        deepReviewData = try photo.deepReview.map { try JSONEncoder().encode($0) }
    }

    var score: PhotoScore? { try? JSONDecoder().decode(PhotoScore.self, from: scoreData) }
    var deepReview: DeepReview? { deepReviewData.flatMap { try? JSONDecoder().decode(DeepReview.self, from: $0) } }

    func setDeepReview(_ review: DeepReview?) throws {
        deepReviewData = try review.map { try JSONEncoder().encode($0) }
    }

    func cacheMatches(_ photo: DiscoveredPhoto) -> Bool {
        fileSize == photo.fileSize && abs(modificationDate.timeIntervalSince(photo.modificationDate)) < 0.001
    }
}
