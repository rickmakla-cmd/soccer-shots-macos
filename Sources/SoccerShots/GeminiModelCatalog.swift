import Foundation

struct GeminiRemoteModel: Codable, Equatable, Identifiable, Sendable {
    let name: String
    let displayName: String?
    let supportedGenerationMethods: [String]

    var id: String { name.replacingOccurrences(of: "models/", with: "") }
    var supportsGenerateContent: Bool {
        supportedGenerationMethods.contains { $0.caseInsensitiveCompare("generateContent") == .orderedSame }
    }
    var supportsBatch: Bool {
        supportedGenerationMethods.contains { $0.caseInsensitiveCompare("batchGenerateContent") == .orderedSame }
    }
}

struct GeminiModelCatalogClient: Sendable {
    func list(apiKey: String) async throws -> [GeminiRemoteModel] {
        var models: [GeminiRemoteModel] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models")!
            components.queryItems = [URLQueryItem(name: "pageSize", value: "1000")]
            if let pageToken { components.queryItems?.append(.init(name: "pageToken", value: pageToken)) }
            var request = URLRequest(url: components.url!)
            request.timeoutInterval = 60
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw SoccerShotsError.message(GeminiHTTPError.message(data: data, prefix: "Gemini model discovery failed"))
            }
            let page = try JSONDecoder().decode(Page.self, from: data)
            models.append(contentsOf: page.models ?? [])
            pageToken = page.nextPageToken
        } while pageToken?.isEmpty == false
        return models.filter(Self.isPhotoReviewModel).sorted { Self.selectorScore($0) > Self.selectorScore($1) }
    }

    private struct Page: Decodable {
        let models: [GeminiRemoteModel]?
        let nextPageToken: String?
    }

    static func isPhotoReviewModel(_ model: GeminiRemoteModel) -> Bool {
        let id = model.id.lowercased()
        let excluded = ["embedding", "image", "tts", "audio", "live", "robotics", "lyria", "veo", "aqa"]
        return id.hasPrefix("gemini-") && model.supportsGenerateContent && !excluded.contains(where: id.contains)
    }

    static func selectorScore(_ model: GeminiRemoteModel) -> Int {
        let id = model.id.lowercased()
        let numbers = id.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        let version = numbers.prefix(3).reduce(0) { $0 * 100 + $1 }
        return version + (id.contains("pro") ? 50_000 : 0) + (id.contains("preview") ? 0 : 10_000)
    }
}

enum GeminiModelSelector {
    static func interactiveCandidates(preferred: String, catalog: [GeminiRemoteModel]) -> [String] {
        let eligible = catalog.filter(GeminiModelCatalogClient.isPhotoReviewModel)
        return unique(([preferred] + eligible.map(\.id)).filter { id in
            eligible.contains { $0.id == id }
        })
    }

    static func batchCandidates(preferred: String, catalog: [GeminiRemoteModel]) -> [String] {
        let photoModels = catalog.filter(GeminiModelCatalogClient.isPhotoReviewModel)
        let explicit = photoModels.filter(\.supportsBatch)
        let pool = explicit.isEmpty
            ? photoModels.filter { $0.id.localizedCaseInsensitiveContains("flash") }
            : explicit
        let sorted = pool.sorted { lhs, rhs in
            let lhsFlash = lhs.id.localizedCaseInsensitiveContains("flash")
            let rhsFlash = rhs.id.localizedCaseInsensitiveContains("flash")
            if lhsFlash != rhsFlash { return lhsFlash }
            return GeminiModelCatalogClient.selectorScore(lhs) > GeminiModelCatalogClient.selectorScore(rhs)
        }
        let preferredIsEligible = pool.contains { $0.id == preferred }
        return unique((preferredIsEligible ? [preferred] : []) + sorted.map(\.id))
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}

struct GeminiHTTPError: LocalizedError, Sendable {
    let statusCode: Int
    let serverMessage: String

    var errorDescription: String? { serverMessage }
    var definitelyRejectsModel: Bool {
        guard statusCode == 400 || statusCode == 404 else { return false }
        let text = serverMessage.lowercased()
        return text.contains("model") && [
            "not found", "not supported", "unsupported", "no longer available", "not available"
        ].contains(where: text.contains)
    }

    static func message(data: Data, prefix: String) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return "\(prefix): \(message.prefix(800))"
        }
        return "\(prefix)."
    }

    static func make(statusCode: Int, data: Data, prefix: String) -> Self {
        .init(statusCode: statusCode, serverMessage: message(data: data, prefix: prefix))
    }
}
