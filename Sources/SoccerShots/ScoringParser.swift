import Foundation

struct ScoringParser: Sendable {
    private struct Payload: Decodable {
        let autoReject: Bool?
        let sharpness: Double?
        let faceEyes: Double?
        let peakAction: Double?
        let ballInFrame: Double?
        let exposure: Double?
        let composition: Double?
        let convergence: Double?
        let lightroomSuggestions: [String]?
        let developSettings: DevelopSettings?
        let keepRecommendation: Bool?
        let rejectReason: String?
        let jerseyNumber: String?
        let jerseyColor: String?
        let actionType: String?

        enum CodingKeys: String, CodingKey {
            case autoReject = "auto_reject"
            case sharpness = "sharpness_score"
            case faceEyes = "face_eyes_score"
            case peakAction = "peak_action_score"
            case ballInFrame = "ball_in_frame_score"
            case exposure = "exposure_score"
            case composition = "composition_score"
            case convergence = "convergence_score"
            case lightroomSuggestions = "lightroom_suggestions"
            case developSettings = "develop_settings"
            case keepRecommendation = "keep_recommendation"
            case rejectReason = "reject_reason"
            case jerseyNumber = "jersey_number"
            case jerseyColor = "jersey_color"
            case actionType = "action_type"
        }
    }

    func parse(_ raw: String) throws -> PhotoScore {
        guard let object = jsonObject(in: raw), let data = object.data(using: .utf8) else {
            throw SoccerShotsError.message("Local Gemma returned text without a JSON object.")
        }
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: data) }
        catch { throw SoccerShotsError.message("Local Gemma returned unreadable score JSON: \(error.localizedDescription)") }

        let sharpness = payload.sharpness.map(clamped)
        if payload.autoReject == true || (sharpness ?? 10) <= 2 {
            return PhotoScore(
                autoReject: true, sharpness: sharpness, faceEyes: nil, peakAction: nil,
                ballInFrame: nil, exposure: nil, composition: nil, convergence: nil,
                composite: 0, lightroomSuggestions: [], developSettings: .init(),
                keepRecommendation: false,
                rejectReason: payload.rejectReason ?? "Motion blur or focus miss — unrecoverable.",
                jerseyNumber: nil, jerseyColor: nil, actionType: .unknown
            )
        }

        guard let sharpness, let faceEyes = payload.faceEyes, let peakAction = payload.peakAction,
              let exposure = payload.exposure, let composition = payload.composition,
              let convergence = payload.convergence else {
            throw SoccerShotsError.message("Local Gemma omitted a required scoring dimension.")
        }
        var score = PhotoScore(
            autoReject: false,
            sharpness: sharpness,
            faceEyes: clamped(faceEyes),
            peakAction: clamped(peakAction),
            ballInFrame: payload.ballInFrame.map(clamped),
            exposure: clamped(exposure),
            composition: clamped(composition),
            convergence: clamped(convergence),
            composite: 0,
            lightroomSuggestions: Array((payload.lightroomSuggestions ?? []).prefix(5)),
            developSettings: payload.developSettings ?? .init(),
            keepRecommendation: payload.keepRecommendation ?? false,
            rejectReason: payload.rejectReason,
            jerseyNumber: sanitized(payload.jerseyNumber),
            jerseyColor: sanitized(payload.jerseyColor),
            actionType: ActionType(rawValue: payload.actionType ?? "") ?? .unknown
        )
        score.recalculateComposite()
        // The deterministic rubric, not model arithmetic, owns the final composite.
        score.keepRecommendation = score.composite >= 6.5 && (payload.keepRecommendation ?? false)
        if !score.keepRecommendation, score.rejectReason == nil {
            score.rejectReason = "Composite score is below the keeper threshold."
        }
        return score
    }

    private func clamped(_ value: Double) -> Double { min(10, max(0, value)) }

    private func sanitized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return String(value.prefix(80))
    }

    private func jsonObject(in raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```JSON", with: "")
            .replacingOccurrences(of: "```", with: "")
        guard let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), first <= last else { return nil }
        text = String(text[first...last])
        if let expression = try? NSRegularExpression(pattern: #",\s*([}\]])"#) {
            text = expression.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: "$1"
            )
        }
        return text
    }
}
