import Foundation

struct LightroomRecommendation: Codable, Equatable, Sendable {
    let suggestions: [String]
    let developSettings: DevelopSettings

    init(suggestions: [String], developSettings: DevelopSettings) {
        self.suggestions = suggestions
        self.developSettings = developSettings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        suggestions = try container.decodeIfPresent([String].self, forKey: .suggestions) ?? []
        developSettings = try container.decodeIfPresent(DevelopSettings.self, forKey: .developSettings) ?? .init()
    }

    enum CodingKeys: String, CodingKey {
        case suggestions = "lightroom_suggestions"
        case developSettings = "develop_settings"
    }
}

enum LightroomRecommendationPrompt {
    static let text = #"""
    Inspect this soccer photograph and recommend only the Lightroom Classic corrections visibly needed.
    Return JSON only. Do not score the photo and do not include markdown or explanation outside the JSON.

    Use 1-5 concise, specific suggestions. The develop_settings object is written directly to an Adobe Camera Raw XMP sidecar. Omit controls that should stay at their defaults.

    Allowed develop_settings fields and ranges:
    Exposure2012: string from "-5.00" to "+5.00"
    Highlights2012, Shadows2012, Whites2012, Blacks2012, Clarity2012, Vibrance, Saturation: integer -100 to 100
    LuminanceSmoothing, ColorNoiseReduction: integer 0 to 100
    WhiteBalance: "As Shot", "Auto", "Daylight", "Cloudy", "Shade", "Tungsten", "Fluorescent", or "Flash"

    Use conservative photographic corrections. Do not invent a problem. Do not recommend sharpening because this sidecar does not expose sharpening controls. Mention a crop only in suggestions because crop coordinates are not part of develop_settings.

    Exact JSON shape:
    {
      "lightroom_suggestions": ["Exposure: +0.35 — lift the subject slightly"],
      "develop_settings": {"Exposure2012": "+0.35"}
    }
    """#
}

struct LightroomRecommendationParser: Sendable {
    func parse(_ response: String) throws -> LightroomRecommendation {
        guard let start = response.firstIndex(of: "{"),
              let end = response.lastIndex(of: "}"), start <= end,
              let data = String(response[start...end]).data(using: .utf8) else {
            throw SoccerShotsError.message("The Lightroom recommendation model did not return JSON.")
        }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SoccerShotsError.message("The Lightroom recommendation model returned a JSON value instead of an object.")
            }
            let suggestions: [String]
            switch object["lightroom_suggestions"] {
            case let values as [Any]:
                suggestions = values.compactMap { $0 as? String }
            case let value as String:
                suggestions = [value]
            case nil, is NSNull:
                suggestions = []
            default:
                throw SoccerShotsError.message("The Lightroom recommendation model returned an invalid lightroom_suggestions value.")
            }

            let settingsObject: [String: Any]
            switch object["develop_settings"] {
            case let values as [String: Any]:
                settingsObject = Dictionary(uniqueKeysWithValues: values.map { ($0.key.lowercased(), $0.value) })
            case nil, is NSNull:
                settingsObject = [:]
            default:
                throw SoccerShotsError.message("The Lightroom recommendation model returned an invalid develop_settings object.")
            }
            let settings = DevelopSettings(
                exposure2012: Self.stringValue(settingsObject["exposure2012"]),
                highlights2012: Self.intValue(settingsObject["highlights2012"]),
                shadows2012: Self.intValue(settingsObject["shadows2012"]),
                whites2012: Self.intValue(settingsObject["whites2012"]),
                blacks2012: Self.intValue(settingsObject["blacks2012"]),
                clarity2012: Self.intValue(settingsObject["clarity2012"]),
                vibrance: Self.intValue(settingsObject["vibrance"]),
                saturation: Self.intValue(settingsObject["saturation"]),
                luminanceSmoothing: Self.intValue(settingsObject["luminancesmoothing"]),
                colorNoiseReduction: Self.intValue(settingsObject["colornoisereduction"]),
                whiteBalance: Self.stringValue(settingsObject["whitebalance"])
            )
            return .init(
                suggestions: Array(suggestions.prefix(5)),
                developSettings: settings.normalizedForLightroom()
            )
        } catch {
            if let error = error as? SoccerShotsError { throw error }
            throw SoccerShotsError.message("The Lightroom recommendation model returned invalid settings: \(error.localizedDescription)")
        }
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let value as String: value
        case let value as NSNumber: value.stringValue
        default: nil
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let value as NSNumber: Int(value.doubleValue.rounded())
        case let value as String: Double(value).map { Int($0.rounded()) }
        default: nil
        }
    }
}
