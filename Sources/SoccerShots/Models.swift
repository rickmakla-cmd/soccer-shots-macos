import Foundation

enum ActionType: String, Codable, CaseIterable, Identifiable, Sendable {
    case shot, tackle, header, save, celebration, sprint, dribble, pass, positioning, unknown
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
    var isPostProcessed: Bool
    var isManuallyRejected: Bool
    var isSelectedForExport: Bool

    func cacheMatches(fileSize currentSize: Int64, modificationDate currentDate: Date) -> Bool {
        fileSize == currentSize && abs(modificationDate.timeIntervalSince(currentDate)) < 0.001
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

enum SoccerShotsError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self { case let .message(message): message }
    }
}
