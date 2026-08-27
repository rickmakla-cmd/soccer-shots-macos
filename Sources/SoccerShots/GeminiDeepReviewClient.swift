import Foundation

struct GeminiDeepReviewClient: Sendable {
    var modelID = "gemini-2.5-pro"
    private let preparer = ImagePreparer()

    func review(photoURL: URL, localScore: PhotoScore, apiKey: String) async throws -> DeepReview {
        let prepared = try preparer.prepare(photoURL)
        let scoreJSON = String(data: try JSONEncoder().encode(localScore), encoding: .utf8) ?? "{}"
        let prompt = """
        Give this soccer photo an optional deep second review. The local Gemma score below remains authoritative and must never be overwritten. Confirm or challenge it, identify anything the local pass missed, and give concrete Lightroom/crop guidance.

        Local score: \(scoreJSON)

        Return only JSON with this exact shape:
        {"assessment":"one or two sentence overall take","limiting_factors":["short phrase"],"fixable":true,"suggested_fix":"concrete recommendation or null","crop_suggestion":"specific crop or null"}
        """
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [
                ["text": prompt],
                ["inline_data": ["mime_type": "image/jpeg", "data": prepared.jpegData.base64EncodedString()]]
            ]]],
            "generationConfig": ["responseMimeType": "application/json", "temperature": 0.2]
        ]
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelID):generateContent")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SoccerShotsError.message(Self.errorMessage(from: data))
        }
        let envelope = try JSONDecoder().decode(GeminiEnvelope.self, from: data)
        guard let text = envelope.candidates?.first?.content?.parts?.compactMap(\.text).first,
              let reviewData = text.data(using: .utf8) else {
            throw SoccerShotsError.message("Gemini returned no Deep Review text.")
        }
        return try JSONDecoder().decode(DeepReview.self, from: reviewData)
    }

    private static func errorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return "Gemini Deep Review failed: \(message.prefix(800))"
        }
        return "Gemini Deep Review failed."
    }
}

private struct GeminiEnvelope: Decodable {
    let candidates: [Candidate]?
    struct Candidate: Decodable { let content: Content? }
    struct Content: Decodable { let parts: [Part]? }
    struct Part: Decodable { let text: String? }
}
