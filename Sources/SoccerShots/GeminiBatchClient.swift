import Foundation

struct GeminiBatchJob: Codable, Equatable, Sendable, Identifiable {
    var id: String { name }
    let name: String
    let modelID: String
    let photoPaths: [String]
    let submittedAt: Date
}

struct PreparedGeminiBatch: Sendable {
    let body: Data
    let photoPaths: [String]
}

struct GeminiBatchResult: Sendable {
    enum State: Equatable, Sendable {
        case pending
        case running
        case succeeded
        case failed(String)
    }

    let state: State
    let scoresByPath: [String: PhotoScore]
    let failedPaths: [String]
}

enum GeminiBatchProgress: Equatable, Sendable {
    case idle
    case preparing(index: Int, total: Int, filename: String)
    case submitting(index: Int, total: Int)
    case waiting(jobs: Int, photos: Int)
    case importing(completed: Int, total: Int)
    case finished(completed: Int, failed: Int)

    var message: String {
        switch self {
        case .idle: "Gemini batch ready"
        case let .preparing(index, total, filename): "Preparing Gemini batch \(index) of \(total): \(filename)"
        case let .submitting(index, total): "Submitting discounted batch \(index) of \(total)…"
        case let .waiting(jobs, photos): "Gemini batch processing: \(photos) photos in \(jobs) job\(jobs == 1 ? "" : "s")"
        case let .importing(completed, total): "Saving Gemini reviews \(completed) of \(total)…"
        case let .finished(completed, failed): "Gemini batch finished: \(completed) reviewed, \(failed) failed"
        }
    }
}

struct GeminiBatchStore {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "SoccerShots.geminiBatchJobs") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> [GeminiBatchJob] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([GeminiBatchJob].self, from: data)) ?? []
    }

    func save(_ jobs: [GeminiBatchJob]) throws {
        defaults.set(try JSONEncoder().encode(jobs), forKey: key)
    }
}

struct GeminiBatchClient: Sendable {
    static let maximumBodyBytes = 18 * 1_024 * 1_024
    private let preparer = ImagePreparer()

    func prepare(
        photos: [ScoredPhoto],
        progress: (Int, Int, String) -> Void = { _, _, _ in }
    ) throws -> [PreparedGeminiBatch] {
        var groups: [PreparedGeminiBatch] = []
        var requests: [[String: Any]] = []
        var paths: [String] = []

        for (offset, photo) in photos.enumerated() {
            try Task.checkCancellation()
            progress(offset + 1, photos.count, photo.filename)
            let prepared = try preparer.prepare(photo.fileURL, maxDimension: 1_600, quality: 0.82)
            let request = try requestObject(photo: photo, jpegData: prepared.jpegData)
            let singleBody = try bodyData(requests: [request])
            guard singleBody.count <= Self.maximumBodyBytes else {
                throw SoccerShotsError.message("\(photo.filename) is too large for Gemini Batch after preparation.")
            }
            var candidateRequests = requests
            candidateRequests.append(request)
            let candidateBody = try bodyData(requests: candidateRequests)

            if candidateBody.count > Self.maximumBodyBytes, !requests.isEmpty {
                groups.append(.init(body: try bodyData(requests: requests), photoPaths: paths))
                requests = [request]
                paths = [photo.fileURL.path]
            } else {
                requests = candidateRequests
                paths.append(photo.fileURL.path)
            }
        }

        if !requests.isEmpty {
            groups.append(.init(body: try bodyData(requests: requests), photoPaths: paths))
        }
        return groups
    }

    func submit(_ batch: PreparedGeminiBatch, modelID: String, apiKey: String) async throws -> GeminiBatchJob {
        var request = URLRequest(
            url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelID):batchGenerateContent")!
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = batch.body
        let data = try await responseData(for: request)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let name = object?["name"] as? String, name.hasPrefix("batches/") else {
            throw SoccerShotsError.message("Gemini created no recognizable batch job.")
        }
        return .init(name: name, modelID: modelID, photoPaths: batch.photoPaths, submittedAt: Date())
    }

    func status(of job: GeminiBatchJob, apiKey: String) async throws -> GeminiBatchResult {
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/\(job.name)")!)
        request.timeoutInterval = 60
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let data = try await responseData(for: request)
        let envelope = try JSONDecoder().decode(StatusEnvelope.self, from: data)
        let state = envelope.state.uppercased()

        if state.hasSuffix("PENDING") { return .init(state: .pending, scoresByPath: [:], failedPaths: []) }
        if state.hasSuffix("RUNNING") { return .init(state: .running, scoresByPath: [:], failedPaths: []) }
        if state.hasSuffix("FAILED") || state.hasSuffix("CANCELLED") || state.hasSuffix("EXPIRED") {
            return .init(
                state: .failed(envelope.error?.message ?? "Gemini batch ended in \(envelope.state)."),
                scoresByPath: [:], failedPaths: job.photoPaths
            )
        }
        guard state.hasSuffix("SUCCEEDED") else {
            return .init(state: .pending, scoresByPath: [:], failedPaths: [])
        }

        let responses = (envelope.output ?? envelope.dest)?.inlinedResponses?.inlinedResponses ?? []
        var scores: [String: PhotoScore] = [:]
        var failed: [String] = []
        for (index, path) in job.photoPaths.enumerated() {
            guard responses.indices.contains(index),
                  let text = responses[index].response?.candidates?.first?.content?.parts?.compactMap(\.text).first,
                  let score = try? ScoringParser().parse(text) else {
                failed.append(path)
                continue
            }
            scores[path] = score
        }
        return .init(state: .succeeded, scoresByPath: scores, failedPaths: failed)
    }

    private func requestObject(photo: ScoredPhoto, jpegData: Data) throws -> [String: Any] {
        return [
            "request": [
                "contents": [["role": "user", "parts": [
                    ["text": ScoringPrompt.text],
                    ["inline_data": ["mime_type": "image/jpeg", "data": jpegData.base64EncodedString()]]
                ]]],
                "generationConfig": ["responseMimeType": "application/json", "temperature": 0.2]
            ],
            "metadata": ["photoPath": photo.fileURL.path]
        ]
    }

    private func bodyData(requests: [[String: Any]]) throws -> Data {
        let body: [String: Any] = [
            "batch": [
                "display_name": "SoccerShots Deep Review \(ISO8601DateFormatter().string(from: Date()))",
                "input_config": ["requests": ["requests": requests]]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func responseData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SoccerShotsError.message(Self.errorMessage(from: data))
        }
        return data
    }

    private static func errorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return "Gemini Batch failed: \(message.prefix(800))"
        }
        return "Gemini Batch request failed."
    }
}

private struct StatusEnvelope: Decodable {
    let state: String
    let output: Output?
    let dest: Output?
    let error: APIError?

    struct Output: Decodable {
        let inlinedResponses: Responses?
    }
    struct Responses: Decodable {
        let inlinedResponses: [InlineResponse]
    }
    struct InlineResponse: Decodable {
        let response: GeneratedResponse?
    }
    struct GeneratedResponse: Decodable {
        let candidates: [Candidate]?
    }
    struct Candidate: Decodable {
        let content: Content?
    }
    struct Content: Decodable {
        let parts: [Part]?
    }
    struct Part: Decodable {
        let text: String?
    }
    struct APIError: Decodable {
        let message: String?
    }
}
