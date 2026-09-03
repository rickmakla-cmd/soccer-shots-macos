import Foundation

enum ActionType: String, Codable, CaseIterable, Identifiable, Sendable {
    case shot, tackle, header, save, celebration, sprint, dribble, pass, positioning, unknown
    var id: String { rawValue }
}

enum GalleryFilter: String, Codable, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case keepers = "Keepers"
    case nearMiss = "Near Miss"
    case review = "Review"
    case rejects = "Rejects"
    case manuallyRejected = "Rejected"

    var id: String { rawValue }

    func includes(_ photo: ScoredPhoto) -> Bool {
        switch self {
        case .all: true
        case .keepers: !photo.isManuallyRejected && photo.score.composite >= 8
        case .nearMiss: !photo.isManuallyRejected && (7..<8).contains(photo.score.composite)
        case .review: !photo.isManuallyRejected && (5..<7).contains(photo.score.composite)
        case .rejects: !photo.isManuallyRejected && photo.score.composite < 5
        case .manuallyRejected: photo.isManuallyRejected
        }
    }
}

enum GallerySort: String, Codable, CaseIterable, Identifiable, Sendable {
    case scoreDescending = "Score: High to Low"
    case scoreAscending = "Score: Low to High"
    case filename = "Filename"

    var id: String { rawValue }
}

struct DevelopSettings: Codable, Equatable, Sendable {
    var exposure2012: String? = nil
    var highlights2012: Int? = nil
    var shadows2012: Int? = nil
    var whites2012: Int? = nil
    var blacks2012: Int? = nil
    var clarity2012: Int? = nil
    var vibrance: Int? = nil
    var saturation: Int? = nil
    var luminanceSmoothing: Int? = nil
    var colorNoiseReduction: Int? = nil
    var whiteBalance: String? = nil

    enum CodingKeys: String, CodingKey {
        case exposure2012 = "Exposure2012"
        case highlights2012 = "Highlights2012"
        case shadows2012 = "Shadows2012"
        case whites2012 = "Whites2012"
        case blacks2012 = "Blacks2012"
        case clarity2012 = "Clarity2012"
        case vibrance = "Vibrance"
        case saturation = "Saturation"
        case luminanceSmoothing = "LuminanceSmoothing"
        case colorNoiseReduction = "ColorNoiseReduction"
        case whiteBalance = "WhiteBalance"
    }
}

struct DeepReview: Codable, Equatable, Sendable {
    let assessment: String
    let limitingFactors: [String]
    let fixable: Bool
    let suggestedFix: String?
    let cropSuggestion: String?

    enum CodingKeys: String, CodingKey {
        case assessment, fixable
        case limitingFactors = "limiting_factors"
        case suggestedFix = "suggested_fix"
        case cropSuggestion = "crop_suggestion"
    }
}

struct ModelBenchmarkResult: Codable, Equatable, Sendable {
    let modelID: String
    let scoredAt: Date
    let durationSeconds: Double
    let score: PhotoScore
}

struct PhotoScore: Codable, Equatable, Sendable {
    var autoReject: Bool
    var sharpness: Double?
    var faceEyes: Double?
    var peakAction: Double?
    var ballInFrame: Double?
    var exposure: Double?
    var composition: Double?
    var convergence: Double?
    var composite: Double
    var lightroomSuggestions: [String]
    var developSettings: DevelopSettings
    var keepRecommendation: Bool
    var rejectReason: String?
    var jerseyNumber: String?
    var jerseyColor: String?
    var actionType: ActionType

    mutating func recalculateComposite() {
        guard !autoReject else {
            composite = 0
            keepRecommendation = false
            return
        }
        var total = 0.0
        var weight = 0.0
        let weightedValues: [(Double?, Double)] = [
            (sharpness, 1.0), (faceEyes, 1.5), (peakAction, 1.5),
            (ballInFrame, 1.0), (exposure, 0.75), (composition, 0.75),
            (convergence, 2.0)
        ]
        for (value, itemWeight) in weightedValues {
            if let value {
                total += min(10, max(0, value)) * itemWeight
                weight += itemWeight
            }
        }
        composite = weight == 0 ? 0 : (total / weight * 10).rounded() / 10
    }
}

struct ScoredPhoto: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let fileURL: URL
    let filename: String
    let fileSize: Int64
    let modificationDate: Date
    let sessionFolder: URL
    let scoredAt: Date
    let scoringVersion: String
    let scoringEngine: String
    var score: PhotoScore
    var deepReview: DeepReview?
    var benchmarkResult: ModelBenchmarkResult? = nil
    var geminiBatchResult: ModelBenchmarkResult? = nil
    var evidenceBenchmarkResults: [EvidenceBenchmarkResult] = []
    var isPostProcessed: Bool
    var isManuallyRejected: Bool
    var isSelectedForExport: Bool

    func cacheMatches(fileSize currentSize: Int64, modificationDate currentDate: Date) -> Bool {
        fileSize == currentSize && abs(modificationDate.timeIntervalSince(currentDate)) < 0.001
    }
}

struct BenchmarkSummary: Equatable, Sendable {
    let completed: Int
    let averageBaseline: Double
    let averageCandidate: Double
    let averageDelta: Double
    let keeperAgreementRate: Double
    let averageDurationSeconds: Double
}

enum BenchmarkAnalysis {
    static func evenlySpaced<T>(_ values: [T], count: Int) -> [T] {
        guard !values.isEmpty, count > 0 else { return [] }
        let target = min(count, values.count)
        guard target > 1 else { return [values[values.count / 2]] }
        guard target < values.count else { return values }
        return (0..<target).map { offset in
            let position = Double(offset) * Double(values.count - 1) / Double(target - 1)
            return values[Int(position.rounded())]
        }
    }

    static func summary(for photos: [ScoredPhoto]) -> BenchmarkSummary? {
        let completed = photos.compactMap { photo -> (PhotoScore, ModelBenchmarkResult)? in
            photo.benchmarkResult.map { (photo.score, $0) }
        }
        guard !completed.isEmpty else { return nil }
        let count = Double(completed.count)
        let baseline = completed.reduce(0) { $0 + $1.0.composite } / count
        let candidate = completed.reduce(0) { $0 + $1.1.score.composite } / count
        let agreements = completed.filter { $0.0.keepRecommendation == $0.1.score.keepRecommendation }.count
        let duration = completed.reduce(0) { $0 + $1.1.durationSeconds } / count
        return BenchmarkSummary(
            completed: completed.count,
            averageBaseline: baseline,
            averageCandidate: candidate,
            averageDelta: candidate - baseline,
            keeperAgreementRate: Double(agreements) / count,
            averageDurationSeconds: duration
        )
    }
}

enum EvidenceBenchmarkAnalysis {
    static func summary(for photos: [ScoredPhoto], modelID: String) -> BenchmarkSummary? {
        let completed = photos.compactMap { photo -> (PhotoScore, EvidenceBenchmarkResult)? in
            photo.evidenceBenchmarkResults.last(where: { $0.modelID == modelID }).map { (photo.score, $0) }
        }
        guard !completed.isEmpty else { return nil }
        let count = Double(completed.count)
        return BenchmarkSummary(
            completed: completed.count,
            averageBaseline: completed.reduce(0) { $0 + $1.0.composite } / count,
            averageCandidate: completed.reduce(0) { $0 + $1.1.score.composite } / count,
            averageDelta: completed.reduce(0) { $0 + $1.1.score.composite - $1.0.composite } / count,
            keeperAgreementRate: Double(completed.filter { $0.0.keepRecommendation == $0.1.score.keepRecommendation }.count) / count,
            averageDurationSeconds: completed.reduce(0) { $0 + $1.1.durationSeconds } / count
        )
    }
}

struct PhotoBurst: Identifiable, Equatable, Sendable {
    let id: String
    let capturedAt: Date
    let photos: [ScoredPhoto]

    var bestScore: Double { photos.map(\.score.composite).max() ?? 0 }
    var selectedCount: Int { photos.filter(\.isSelectedForExport).count }
}

enum BurstGrouping {
    static func make(
        discovered: [DiscoveredPhoto],
        scored: [ScoredPhoto],
        window: TimeInterval = 2
    ) -> [PhotoBurst] {
        let scoredByPath = Dictionary(uniqueKeysWithValues: scored.map { ($0.fileURL.path, $0) })
        return PhotoDiscovery.burstGroups(discovered, window: window).compactMap { group in
            let photos = group.compactMap { scoredByPath[$0.url.path] }
            guard photos.count > 1, let capturedAt = group.first?.captureDate else { return nil }
            return PhotoBurst(id: group[0].url.path, capturedAt: capturedAt, photos: photos)
        }
    }
}

enum ScoringProgress: Equatable, Sendable {
    case idle
    case discovering
    case preparing(index: Int, total: Int, filename: String)
    case model(String)
    case scoring(index: Int, total: Int, filename: String)
    case finished(completed: Int, failed: Int)

    var message: String {
        switch self {
        case .idle: "Ready"
        case .discovering: "Finding supported photos…"
        case let .preparing(index, total, filename): "Preparing \(index) of \(total): \(filename)"
        case let .model(message): message
        case let .scoring(index, total, filename): "Scoring \(index) of \(total): \(filename)"
        case let .finished(completed, failed): "Finished: \(completed) scored, \(failed) failed"
        }
    }
}

enum BenchmarkProgress: Equatable, Sendable {
    case idle
    case unloadingPrimary
    case preparing(index: Int, total: Int, filename: String)
    case model(String)
    case finished(completed: Int, failed: Int)

    var message: String {
        switch self {
        case .idle: "Benchmark ready"
        case .unloadingPrimary: "Releasing the primary model before loading the benchmark model…"
        case let .preparing(index, total, filename): "Evidence benchmark \(index) of \(total): \(filename)"
        case let .model(message): message
        case let .finished(completed, failed): "A/B finished: \(completed) compared, \(failed) failed"
        }
    }
}

enum SoccerShotsError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self { case let .message(message): message }
    }
}
