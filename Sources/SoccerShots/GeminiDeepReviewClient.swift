import Foundation

struct GeminiDeepReviewClient: Sendable {
    var modelID: String
    private let preparer = ImagePreparer()

    init(modelID: String) {
        self.modelID = modelID
    }

    func review(photoURL: URL, localScore: PhotoScore, apiKey: String) async throws -> DeepReview {
        let prepared = try preparer.prepare(photoURL)
        let scoreJSON = String(data: try JSONEncoder().encode(localScore), encoding: .utf8) ?? "{}"
        let prompt = Self.prompt(localScoreJSON: scoreJSON)
        let body: [String: Any] = [
            "model": modelID,
            "store": false,
            "input": [
                ["type": "image", "mime_type": "image/jpeg", "data": prepared.jpegData.base64EncodedString()],
                ["type": "text", "text": prompt]
            ],
            "generation_config": ["temperature": 0.2],
            "response_format": [
                "type": "text",
                "mime_type": "application/json",
                "schema": Self.responseSchema
            ]
        ]
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw GeminiHTTPError.make(statusCode: status, data: data, prefix: "Gemini Deep Review failed")
        }
        let envelope = try JSONDecoder().decode(GeminiInteractionEnvelope.self, from: data)
        if envelope.status == "failed" {
            throw SoccerShotsError.message(envelope.error?.message ?? "Gemini Deep Review failed.")
        }
        guard let text = envelope.steps?.reversed().first(where: { $0.type == "model_output" })?
            .content?.compactMap(\.text).first,
              let reviewData = text.data(using: .utf8) else {
            throw SoccerShotsError.message("Gemini returned no Deep Review text.")
        }
        return try JSONDecoder().decode(DeepReview.self, from: reviewData)
    }

    private static var responseSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "assessment": ["type": "string"],
                "limiting_factors": ["type": "array", "items": ["type": "string"]],
                "fixable": ["type": "boolean"],
                "suggested_fix": ["type": ["string", "null"]],
                "crop_suggestion": ["type": ["string", "null"]]
            ],
            "required": ["assessment", "limiting_factors", "fixable", "suggested_fix", "crop_suggestion"]
        ]
    }

    static func prompt(localScoreJSON: String) -> String {
        """
        Give this soccer photo an optional deep second review. The local Gemma score below remains authoritative and must never be overwritten. Confirm or challenge it, identify anything the local pass missed, and give concrete Lightroom/crop guidance.

        Local score: \(localScoreJSON)

        Return only JSON with this exact shape:
        {"assessment":"one or two sentence overall take","limiting_factors":["short phrase"],"fixable":true,"suggested_fix":"concrete recommendation or null","crop_suggestion":"specific crop or null"}
        """
    }

}

private struct GeminiInteractionEnvelope: Decodable {
    let status: String?
    let steps: [Step]?
    let error: APIError?
    struct Step: Decodable {
        let type: String
        let content: [Content]?
    }
    struct Content: Decodable {
        let type: String?
        let text: String?
    }
    struct APIError: Decodable { let message: String? }
}
