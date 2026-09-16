import Foundation

struct GeminiBatchJob: Codable, Equatable, Sendable, Identifiable {
    var id: String { name }
    let name: String
    let modelID: String
    let photoPaths: [String]
    let submittedAt: Date
    let requestKeys: [String]?

    init(
        name: String,
        modelID: String,
        photoPaths: [String],
        submittedAt: Date,
        requestKeys: [String]? = nil
    ) {
        self.name = name
        self.modelID = modelID
        self.photoPaths = photoPaths
        self.submittedAt = submittedAt
        self.requestKeys = requestKeys
    }
}

struct PreparedGeminiBatch: Sendable {
    let body: Data
    let photoPaths: [String]
    let requestKeys: [String]
    let usesFileInput: Bool
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
    static let maximumFileBytes = 2_000_000_000
    private let preparer = ImagePreparer()

    func prepare(
        photos: [ScoredPhoto],
        progress: (Int, Int, String) -> Void = { _, _, _ in }
    ) async throws -> PreparedGeminiBatch {
        var requests: [[String: Any]] = []
        var paths: [String] = []
        var keys: [String] = []

        for (offset, photo) in photos.enumerated() {
            try Task.checkCancellation()
            progress(offset + 1, photos.count, photo.filename)
            let prepared = try await preparer.prepare(photo.fileURL, maxDimension: 1_600, quality: 0.82)
            let key = "photo-\(offset)"
            requests.append(try Self.requestObject(jpegData: prepared.jpegData, key: key))
            paths.append(photo.fileURL.path)
            keys.append(key)
        }

        let inlineBody = try bodyData(requests: requests)
        if inlineBody.count <= Self.maximumBodyBytes {
            return .init(
                body: inlineBody,
                photoPaths: paths,
                requestKeys: keys,
                usesFileInput: false
            )
        }

        let fileBody = try Self.jsonLinesData(requests: requests)
        guard fileBody.count <= Self.maximumFileBytes else {
            throw SoccerShotsError.message("The Gemini batch exceeds Google's 2 GB input-file limit.")
        }
        return .init(
            body: fileBody,
            photoPaths: paths,
            requestKeys: keys,
            usesFileInput: true
        )
    }

    func submit(_ batch: PreparedGeminiBatch, modelID: String, apiKey: String) async throws -> GeminiBatchJob {
        let body: Data
        if batch.usesFileInput {
            let fileName = try await uploadBatchFile(batch.body, apiKey: apiKey)
            body = try Self.fileBatchBodyData(fileName: fileName)
        } else {
            body = batch.body
        }

        var request = URLRequest(
            url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelID):batchGenerateContent")!
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let data = try await responseData(for: request)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let name = object?["name"] as? String, name.hasPrefix("batches/") else {
            throw SoccerShotsError.message("Gemini created no recognizable batch job.")
        }
        return .init(
            name: name,
            modelID: modelID,
            photoPaths: batch.photoPaths,
            submittedAt: Date(),
            requestKeys: batch.usesFileInput ? batch.requestKeys : nil
        )
    }

    func status(of job: GeminiBatchJob, apiKey: String) async throws -> GeminiBatchResult {
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/\(job.name)")!)
        request.timeoutInterval = 60
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let data = try await responseData(for: request)
        let result = try Self.parseStatus(data, job: job)
        guard case .succeeded = result.state else { return result }
        guard let requestKeys = job.requestKeys, !requestKeys.isEmpty else { return result }
        guard let fileName = try Self.outputFileName(in: data) else {
            throw SoccerShotsError.message(
                "Gemini completed the file batch but returned no result file. The submitted job was kept so it can be checked again."
            )
        }
        let output = try await downloadFile(named: fileName, apiKey: apiKey)
        return try Self.parseFileResults(output, job: job)
    }

    static func parseStatus(_ data: Data, job: GeminiBatchJob) throws -> GeminiBatchResult {
        let envelope: StatusEnvelope
        do {
            envelope = try JSONDecoder().decode(StatusEnvelope.self, from: data)
        } catch {
            throw SoccerShotsError.message("Gemini returned an unreadable batch status: \(error.localizedDescription)")
        }
        guard let rawState = envelope.state ?? envelope.metadata?.state else {
            throw SoccerShotsError.message(
                "Gemini returned a batch status without a state. The submitted job was kept so it can be checked again."
            )
        }
        let state = rawState.uppercased()

        if state.hasSuffix("PENDING") { return .init(state: .pending, scoresByPath: [:], failedPaths: []) }
        if state.hasSuffix("RUNNING") { return .init(state: .running, scoresByPath: [:], failedPaths: []) }
        if state.hasSuffix("FAILED") || state.hasSuffix("CANCELLED") || state.hasSuffix("EXPIRED") {
            return .init(
                state: .failed(envelope.error?.message ?? "Gemini batch ended in \(rawState)."),
                scoresByPath: [:], failedPaths: job.photoPaths
            )
        }
        guard state.hasSuffix("SUCCEEDED") else {
            return .init(state: .pending, scoresByPath: [:], failedPaths: [])
        }

        let responses = (envelope.output ?? envelope.dest ?? envelope.response)?
            .inlinedResponses?.inlinedResponses ?? []
        var scores: [String: PhotoScore] = [:]
        var failed: [String] = []
        let parser = ScoringParser()
        for (index, path) in job.photoPaths.enumerated() {
            guard responses.indices.contains(index),
                  let text = responses[index].response?.candidates?.first?.content?.parts?.compactMap(\.text).first,
                  let score = (try? parser.parse(text, enforceAutoReject: false))
                    ?? (try? parser.parse(text, enforceAutoReject: true)) else {
                failed.append(path)
                continue
            }
            scores[path] = score
        }
        return .init(state: .succeeded, scoresByPath: scores, failedPaths: failed)
    }

    static func requestObject(jpegData: Data, key: String? = nil) throws -> [String: Any] {
        var object: [String: Any] = [
            "request": [
                "contents": [["role": "user", "parts": [
                    ["text": ScoringPrompt.text],
                    ["inline_data": ["mime_type": "image/jpeg", "data": jpegData.base64EncodedString()]]
                ]]],
                "generationConfig": ["responseMimeType": "application/json", "temperature": 0.2]
            ]
        ]
        if let key { object["metadata"] = ["key": key] }
        return object
    }

    static func jsonLinesData(requests: [[String: Any]]) throws -> Data {
        var result = Data()
        for request in requests {
            guard let key = (request["metadata"] as? [String: Any])?["key"] as? String,
                  let content = request["request"] as? [String: Any] else {
                throw SoccerShotsError.message("Gemini batch request metadata was incomplete.")
            }
            let line = try JSONSerialization.data(withJSONObject: ["key": key, "request": content])
            result.append(line)
            result.append(0x0A)
        }
        return result
    }

    static func fileBatchBodyData(fileName: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "batch": [
                "display_name": "SoccerShots Deep Review \(ISO8601DateFormatter().string(from: Date()))",
                "input_config": ["file_name": fileName]
            ]
        ])
    }

    static func parseFileResults(_ data: Data, job: GeminiBatchJob) throws -> GeminiBatchResult {
        guard let requestKeys = job.requestKeys,
              requestKeys.count == job.photoPaths.count,
              Set(requestKeys).count == requestKeys.count else {
            throw SoccerShotsError.message(
                "The saved Gemini batch does not contain a valid image-to-result mapping. The job was kept so it can be checked again."
            )
        }
        let keyToPath = Dictionary(uniqueKeysWithValues: zip(requestKeys, job.photoPaths))
        var scores: [String: PhotoScore] = [:]
        var returnedKeys: Set<String> = []
        let parser = ScoringParser()

        for rawLine in data.split(separator: 0x0A) {
            let line: FileResponseLine
            do { line = try JSONDecoder().decode(FileResponseLine.self, from: Data(rawLine)) }
            catch { continue }
            guard let path = keyToPath[line.key] else { continue }
            returnedKeys.insert(line.key)
            guard line.error == nil,
                  let text = line.response?.candidates?.first?.content?.parts?.compactMap(\.text).first,
                  let score = (try? parser.parse(text, enforceAutoReject: false))
                    ?? (try? parser.parse(text, enforceAutoReject: true)) else { continue }
            scores[path] = score
        }

        let failed = zip(requestKeys, job.photoPaths).compactMap { key, path in
            scores[path] == nil || !returnedKeys.contains(key) ? path : nil
        }
        return .init(state: .succeeded, scoresByPath: scores, failedPaths: failed)
    }

    private func uploadBatchFile(_ data: Data, apiKey: String) async throws -> String {
        var start = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/upload/v1beta/files")!)
        start.httpMethod = "POST"
        start.timeoutInterval = 180
        start.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        start.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        start.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        start.setValue(String(data.count), forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        start.setValue("application/jsonl", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        start.setValue("application/jsonl", forHTTPHeaderField: "Content-Type")
        start.httpBody = try JSONSerialization.data(withJSONObject: [
            "file": ["display_name": "SoccerShots Batch \(ISO8601DateFormatter().string(from: Date()))"]
        ])
        let (_, response) = try await responseDataAndHTTPResponse(for: start)
        guard let uploadValue = response.value(forHTTPHeaderField: "X-Goog-Upload-URL"),
              let uploadURL = URL(string: uploadValue) else {
            throw SoccerShotsError.message("Gemini created no upload URL for the batch file.")
        }

        var upload = URLRequest(url: uploadURL)
        upload.httpMethod = "POST"
        upload.timeoutInterval = 300
        upload.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        upload.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        upload.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        upload.httpBody = data
        let uploaded = try await responseData(for: upload)
        let envelope = try JSONDecoder().decode(UploadedFileEnvelope.self, from: uploaded)
        guard envelope.file.name.hasPrefix("files/") else {
            throw SoccerShotsError.message("Gemini returned no recognizable batch input file.")
        }
        return envelope.file.name
    }

    private func downloadFile(named fileName: String, apiKey: String) async throws -> Data {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/download/v1beta/\(fileName):download?alt=media") else {
            throw SoccerShotsError.message("Gemini returned an invalid batch result file name.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 180
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        return try await responseData(for: request)
    }

    static func outputFileName(in data: Data) throws -> String? {
        let envelope = try JSONDecoder().decode(StatusEnvelope.self, from: data)
        return envelope.output?.fileReference
            ?? envelope.dest?.fileReference
            ?? envelope.response?.fileReference
            ?? envelope.metadata?.output?.fileReference
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
        try await responseDataAndHTTPResponse(for: request).0
    }

    private func responseDataAndHTTPResponse(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw GeminiHTTPError.make(statusCode: status, data: data, prefix: "Gemini Batch failed")
        }
        return (data, http)
    }
}

private struct StatusEnvelope: Decodable {
    let state: String?
    let metadata: Metadata?
    let output: Output?
    let dest: Output?
    let response: Output?
    let error: APIError?

    struct Metadata: Decodable {
        let state: String?
        let output: Output?
    }

    struct Output: Decodable {
        let inlinedResponses: Responses?
        let responsesFile: String?
        let fileName: String?

        var fileReference: String? { responsesFile ?? fileName }
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

private struct UploadedFileEnvelope: Decodable {
    let file: UploadedFile

    struct UploadedFile: Decodable {
        let name: String
    }
}

private struct FileResponseLine: Decodable {
    let key: String
    let response: StatusEnvelope.GeneratedResponse?
    let error: StatusEnvelope.APIError?
}
