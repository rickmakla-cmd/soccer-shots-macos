import Foundation

/// SoccerShots client for the existing llama.cpp multimodal endpoint.
/// This only calls the inference API; it does not modify the Video Director service.
struct LinuxQwenClient: Sendable {
    static let modelID = "qwen3.5-35b-a3b-video"
    static let endpoint = URL(string: "http://192.168.1.163:8080/v1/chat/completions")!
    static let sshTarget = "rmakla@192.168.1.163"
    static let mediaRoot = "/home/rmakla"
    private let preparer = ImagePreparer()

    struct Result: Sendable {
        let evidence: PhotoEvidence
        let pixelSharpness: Double?
        let duration: TimeInterval
    }

    func prepare(photoURL: URL) async throws -> PreparedPhoto {
        let prepared = try await preparer.prepare(photoURL)
        let pixelSharpness = PixelSharpnessAnalyzer().score(prepared.cgImage, horizontalPosition: nil)
        return PreparedPhoto(data: prepared.jpegData, pixelSharpness: pixelSharpness)
    }

    func inspect(stagedRelativePath: String, pixelSharpness: Double?, apiKey: String) async throws -> Result {
        let started = Date()
        let fileURL = "file://" + stagedRelativePath
        let body: [String: Any] = [
            "model": "qwen3.5-35b-a3b-video",
            "temperature": 0,
            "max_tokens": 900,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": EvidencePrompt.text],
                    ["type": "image_url", "image_url": ["url": fileURL]]
                ]
            ]]
        ]
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 240
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let detail = String(data: responseData, encoding: .utf8).map { String($0.prefix(700)) } ?? ""
            throw SoccerShotsError.message("Linux Qwen request failed (HTTP \(status)): \(detail)")
        }
        let envelope = try JSONDecoder().decode(ChatCompletion.self, from: responseData)
        guard let content = envelope.choices.first?.message.content,
              !content.isEmpty else {
            throw SoccerShotsError.message("Linux Qwen returned an empty response.")
        }
        let evidence = try EvidenceParser().parse(content)
        return Result(evidence: evidence, pixelSharpness: pixelSharpness, duration: Date().timeIntervalSince(started))
    }

    struct PreparedPhoto: Sendable {
        let data: Data
        let pixelSharpness: Double?
    }

    static func runSSH(_ arguments: [String]) async throws {
        try await runProcess("/usr/bin/ssh", ["-o", "BatchMode=yes", sshTarget] + arguments)
    }

    static func upload(localURL: URL, remotePath: String) async throws {
        try await runProcess("/usr/bin/scp", ["-q", "-o", "BatchMode=yes", localURL.path, "\(sshTarget):\(remotePath)"])
    }

    private static func runProcess(_ executable: String, _ arguments: [String]) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let errorPipe = Pipe()
            process.standardError = errorPipe
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let reason = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw SoccerShotsError.message("Secure photo transfer failed. \(reason)")
            }
        }.value
    }

    private struct ChatCompletion: Decodable {
        let choices: [Choice]
        struct Choice: Decodable { let message: Message }
        struct Message: Decodable { let content: String }
    }
}
