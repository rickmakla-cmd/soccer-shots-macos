import Foundation

enum EvidenceVisionProbe {
    private static let leftColors = ["magenta", "fuchsia", "purple", "pink"]
    private static let rightColors = ["yellow", "gold", "golden", "lemon"]

    static func passes(_ response: String) -> Bool {
        let normalized = response.lowercased()
        guard let left = firstRange(ofAny: leftColors, in: normalized),
              let right = firstRange(ofAny: rightColors, in: normalized) else { return false }

        if labeledSegment("left", in: normalized).map({ containsAny(leftColors, in: $0) }) == true,
           labeledSegment("right", in: normalized).map({ containsAny(rightColors, in: $0) }) == true {
            return true
        }

        // A normal left-to-right answer names the magenta/pink half before the yellow/gold half.
        return left.lowerBound < right.lowerBound
    }

    static func diagnostic(_ response: String) -> String {
        let compact = response
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return "(empty)" }
        return String(compact.prefix(180))
    }

    private static func firstRange(ofAny values: [String], in text: String) -> Range<String.Index>? {
        values.compactMap { text.range(of: $0) }.min { $0.lowerBound < $1.lowerBound }
    }

    private static func labeledSegment(_ label: String, in text: String) -> Substring? {
        guard let labelRange = text.range(of: label) else { return nil }
        let tail = text[labelRange.upperBound...].prefix(80)
        return tail.prefix { character in
            character != ";" && character != "," && character != "\n" && character != "."
        }
    }

    private static func containsAny(_ values: [String], in text: Substring) -> Bool {
        values.contains { text.contains($0) }
    }
}

enum FaceVisibility: String, Codable, CaseIterable, Sendable {
    case full, threeQuarter = "three_quarter", profile, obscured, back, absent
}

enum FaceSharpness: String, Codable, CaseIterable, Sendable {
    case sharp, usable, soft, blurred, indeterminate
}

enum SubjectScale: String, Codable, CaseIterable, Sendable {
    case close, medium, distant, tiny
}

enum ActionMoment: String, Codable, CaseIterable, Sendable {
    case peak, strong, ordinary, idle, unclear
}

enum BallRelevance: String, Codable, CaseIterable, Sendable {
    case central, relevant, peripheral, absent
    case notApplicable = "not_applicable"
}

enum EvidenceLevel: String, Codable, CaseIterable, Sendable {
    case none, minor, moderate, severe
}

enum EmotionLevel: String, Codable, CaseIterable, Sendable {
    case strong, visible, neutral, unseen
}

enum ExposureQuality: String, Codable, CaseIterable, Sendable {
    case good, recoverable, poor, indeterminate
}

struct PhotoEvidence: Codable, Equatable, Sendable {
    let primarySubject: String
    let faceVisibility: FaceVisibility
    let faceSharpness: FaceSharpness
    let subjectScale: SubjectScale
    let actionMoment: ActionMoment
    let ballRelevance: BallRelevance
    let emotion: EmotionLevel
    let foregroundObstruction: EvidenceLevel
    let backgroundClutter: EvidenceLevel
    let exposureQuality: ExposureQuality
    let confidence: Double
    let observations: [String]

    enum CodingKeys: String, CodingKey {
        case primarySubject = "primary_subject"
        case faceVisibility = "face_visibility"
        case faceSharpness = "face_sharpness"
        case subjectScale = "subject_scale"
        case actionMoment = "action_moment"
        case ballRelevance = "ball_relevance"
        case emotion
        case foregroundObstruction = "foreground_obstruction"
        case backgroundClutter = "background_clutter"
        case exposureQuality = "exposure_quality"
        case confidence, observations
    }
}

struct EvidenceBenchmarkResult: Codable, Equatable, Sendable {
    let modelID: String
    let scoredAt: Date
    let durationSeconds: Double
    let evidence: PhotoEvidence
    let score: PhotoScore
}

enum EvidencePrompt {
    static let version = "evidence-v1"
    static let text = #"""
    Inspect this youth soccer photograph as evidence. Do not assign quality scores and do not suggest edits.
    Image 1 is the complete frame. Image 2, when present, is an automatically selected prominent-player crop.

    Identify the primary photographic subject: the person who is largest, sharpest, or carrying the visual story.
    Report only what is visibly supported. Use "indeterminate", "unclear", or "unseen" when pixels are insufficient.

    Allowed values:
    face_visibility: full | three_quarter | profile | obscured | back | absent
    face_sharpness: sharp | usable | soft | blurred | indeterminate
    subject_scale: close | medium | distant | tiny
    action_moment: peak | strong | ordinary | idle | unclear
      peak = exact ball contact, full extension, airborne contest, full-stretch save, or unmistakable celebration
      strong = clearly athletic movement immediately around the decisive moment
      ordinary = routine running, passing setup, positioning, or action without a decisive instant
      idle = standing, walking, or post-play relaxation
    ball_relevance: central | relevant | peripheral | absent | not_applicable
    emotion: strong | visible | neutral | unseen
    foreground_obstruction: none | minor | moderate | severe
    background_clutter: none | minor | moderate | severe
    exposure_quality: good | recoverable | poor | indeterminate
    confidence: number from 0.0 to 1.0

    Return JSON only in this exact shape, using 1-3 short factual observations:
    {
      "primary_subject": "short visual description",
      "face_visibility": "allowed value",
      "face_sharpness": "allowed value",
      "subject_scale": "allowed value",
      "action_moment": "allowed value",
      "ball_relevance": "allowed value",
      "emotion": "allowed value",
      "foreground_obstruction": "allowed value",
      "background_clutter": "allowed value",
      "exposure_quality": "allowed value",
      "confidence": 0.0,
      "observations": ["visible fact"]
    }
    """#
}

struct EvidenceParser: Sendable {
    func parse(_ response: String) throws -> PhotoEvidence {
        guard let start = response.firstIndex(of: "{"), let end = response.lastIndex(of: "}"), start <= end,
              let data = String(response[start...end]).data(using: .utf8) else {
            throw SoccerShotsError.message("The evidence model did not return JSON.")
        }
        do {
            return try JSONDecoder().decode(PhotoEvidence.self, from: data)
        } catch {
            throw SoccerShotsError.message("The evidence model returned invalid evidence: \(error.localizedDescription)")
        }
    }
}

struct EvidenceRuleEngine: Sendable {
    func score(_ evidence: PhotoEvidence) -> PhotoScore {
        var sharpness = value(evidence.faceSharpness)
        if evidence.subjectScale == .tiny { sharpness = min(sharpness, 4) }
        if evidence.subjectScale == .distant { sharpness = min(sharpness, 6) }

        let face = value(evidence.faceVisibility)
        let action = value(evidence.actionMoment)
        let ball: Double? = evidence.ballRelevance == .notApplicable ? nil : value(evidence.ballRelevance)
        let exposure = value(evidence.exposureQuality)

        var composition = 9.0
        composition -= scalePenalty(evidence.subjectScale)
        composition -= obstructionPenalty(evidence.foregroundObstruction)
        composition -= clutterPenalty(evidence.backgroundClutter)
        if evidence.foregroundObstruction == .severe { composition = min(composition, 3) }
        composition = max(0, composition)

        var convergence = convergence(action: evidence.actionMoment, emotion: evidence.emotion)
        if face <= 4 || action <= 5 { convergence = min(convergence, 5) }

        let autoReject = evidence.faceSharpness == .blurred && evidence.subjectScale != .tiny
        var result = PhotoScore(
            autoReject: autoReject,
            sharpness: sharpness,
            faceEyes: face,
            peakAction: action,
            ballInFrame: ball,
            exposure: exposure,
            composition: composition,
            convergence: convergence,
            composite: 0,
            lightroomSuggestions: [],
            developSettings: .init(),
            keepRecommendation: false,
            rejectReason: nil,
            jerseyNumber: nil,
            jerseyColor: nil,
            actionType: .unknown
        )
        result.recalculateComposite()
        result.keepRecommendation = !result.autoReject && result.composite >= 6.5
        if !result.keepRecommendation {
            result.rejectReason = evidence.observations.first ?? "Visible evidence did not meet the keeper threshold."
        }
        return result
    }

    private func value(_ value: FaceSharpness) -> Double {
        switch value { case .sharp: 9; case .usable: 7; case .soft: 5; case .blurred: 2; case .indeterminate: 4 }
    }
    private func value(_ value: FaceVisibility) -> Double {
        switch value { case .full: 9; case .threeQuarter: 8; case .profile: 6; case .obscured: 4; case .back: 2; case .absent: 0 }
    }
    private func value(_ value: ActionMoment) -> Double {
        switch value { case .peak: 9; case .strong: 7; case .ordinary: 5; case .idle: 2; case .unclear: 3 }
    }
    private func value(_ value: BallRelevance) -> Double {
        switch value { case .central: 9; case .relevant: 7; case .peripheral: 4; case .absent: 2; case .notApplicable: 0 }
    }
    private func value(_ value: ExposureQuality) -> Double {
        switch value { case .good: 9; case .recoverable: 7; case .poor: 3; case .indeterminate: 5 }
    }
    private func scalePenalty(_ value: SubjectScale) -> Double {
        switch value { case .close: 0; case .medium: 1; case .distant: 2; case .tiny: 4 }
    }
    private func obstructionPenalty(_ value: EvidenceLevel) -> Double {
        switch value { case .none: 0; case .minor: 1; case .moderate: 3; case .severe: 5 }
    }
    private func clutterPenalty(_ value: EvidenceLevel) -> Double {
        switch value { case .none: 0; case .minor: 1; case .moderate: 2; case .severe: 4 }
    }
    private func convergence(action: ActionMoment, emotion: EmotionLevel) -> Double {
        if action == .peak && emotion == .strong { return 10 }
        if action == .peak || emotion == .strong { return 8 }
        if action == .strong && emotion == .visible { return 7 }
        if action == .strong || emotion == .visible { return 6 }
        if action == .ordinary { return 4 }
        return 2
    }
}
