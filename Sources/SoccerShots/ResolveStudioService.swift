import Foundation

struct ResolveTransferResult: Equatable, Sendable {
    let imported: Int
    let reused: Int
    let failed: Int
    let projectName: String
    let failures: [String]
}

enum ResolveTransferProgress: Equatable, Sendable {
    case idle
    case preparing(total: Int)
    case transferring(total: Int)
    case finished(imported: Int, reused: Int, failed: Int)

    var message: String {
        switch self {
        case .idle:
            "Resolve Studio ready"
        case let .preparing(total):
            "Preparing \(total) selected photo\(total == 1 ? "" : "s")…"
        case let .transferring(total):
            "Sending \(total) photo\(total == 1 ? "" : "s") to Resolve Studio…"
        case let .finished(imported, reused, failed):
            "Resolve finished: \(imported) imported, \(reused) updated, \(failed) failed"
        }
    }
}

struct ResolveStudioService {
    static let applicationURL = URL(
        fileURLWithPath: "/Applications/DaVinci Resolve/DaVinci Resolve.app",
        isDirectory: true
    )
    static let pythonURL = applicationURL
        .appendingPathComponent("Contents/Applications/ResolvePython", isDirectory: false)

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    static func category(for photo: ScoredPhoto) -> String {
        if photo.isManuallyRejected || photo.score.autoReject || photo.score.composite < ScoreThresholds.review {
            return "Rejects"
        }
        if photo.score.composite >= ScoreThresholds.keeper { return "Keepers" }
        if photo.score.composite >= ScoreThresholds.nearMiss { return "Near Miss" }
        return "Review"
    }

    static func rating(for composite: Double) -> Int {
        if composite >= 9 { return 5 }
        if composite >= 7.5 { return 4 }
        if composite >= 6 { return 3 }
        if composite >= 4 { return 2 }
        return 1
    }

    func transfer(
        photos: [ScoredPhoto],
        sessionName: String,
        progress: @Sendable (ResolveTransferProgress) -> Void = { _ in }
    ) async throws -> ResolveTransferResult {
        guard fileManager.fileExists(atPath: Self.applicationURL.path),
              fileManager.fileExists(atPath: Self.pythonURL.path) else {
            throw SoccerShotsError.message(
                "DaVinci Resolve Studio 21.1 or later was not found in Applications."
            )
        }

        progress(.preparing(total: photos.count))
        let workDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("SoccerShots-Resolve-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workDirectory) }

        let manifestURL = workDirectory.appendingPathComponent("manifest.json")
        let scriptURL = workDirectory.appendingPathComponent("send_to_resolve.py")
        let manifest = Manifest(
            sessionName: sanitizedFolderName(sessionName),
            photos: photos.map(ManifestPhoto.init)
        )
        try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
        try Self.pythonScript.write(to: scriptURL, atomically: true, encoding: .utf8)

        try launchResolve()
        progress(.transferring(total: photos.count))
        let response = try await runResolvePython(scriptURL: scriptURL, manifestURL: manifestURL)
        progress(.finished(imported: response.imported, reused: response.reused, failed: response.failed))
        return .init(
            imported: response.imported,
            reused: response.reused,
            failed: response.failed,
            projectName: response.projectName,
            failures: response.failures
        )
    }

    private func launchResolve() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "DaVinci Resolve"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SoccerShotsError.message("DaVinci Resolve Studio could not be opened.")
        }
    }

    private func runResolvePython(scriptURL: URL, manifestURL: URL) async throws -> ScriptResponse {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = Self.pythonURL
        process.arguments = [scriptURL.path, manifestURL.path]
        process.standardOutput = output
        process.standardError = errors
        try process.run()

        do {
            while process.isRunning {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            if process.isRunning {
                process.terminate()
            }
            throw error
        }

        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(decoding: outputData, as: UTF8.self)
        let stderr = String(decoding: errorData, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SoccerShotsError.message(
                detail.isEmpty ? "Resolve Studio rejected the transfer." : detail
            )
        }
        guard let marker = stdout.split(separator: "\n").last(where: {
            $0.hasPrefix(Self.resultPrefix)
        }),
              let data = String(marker.dropFirst(Self.resultPrefix.count)).data(using: .utf8) else {
            throw SoccerShotsError.message("Resolve Studio returned no transfer result.")
        }
        return try JSONDecoder().decode(ScriptResponse.self, from: data)
    }

    private func sanitizedFolderName(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:")
        let cleaned = value.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Photo Session" : String(cleaned.prefix(80))
    }

    private static let resultPrefix = "SOCCERSHOTS_RESULT:"

    private struct Manifest: Codable {
        let sessionName: String
        let photos: [ManifestPhoto]

        enum CodingKeys: String, CodingKey {
            case sessionName = "session_name"
            case photos
        }
    }

    private struct ManifestPhoto: Codable {
        let path: String
        let filename: String
        let category: String
        let rating: Int
        let comments: String
        let keywords: String
        let clipColor: String

        enum CodingKeys: String, CodingKey {
            case path, filename, category, rating, comments, keywords
            case clipColor = "clip_color"
        }

        init(_ photo: ScoredPhoto) {
            path = photo.fileURL.path
            filename = photo.filename
            category = ResolveStudioService.category(for: photo)
            rating = ResolveStudioService.rating(for: photo.score.composite)
            clipColor = Self.color(for: category)
            keywords = ["SoccerShots", category, photo.score.actionType.rawValue]
                .joined(separator: ", ")

            var parts = ["SoccerShots score: \(String(format: "%.1f", photo.score.composite))/10"]
            let dimensions: [(String, Double?)] = [
                ("sharpness", photo.score.sharpness),
                ("face/eyes", photo.score.faceEyes),
                ("peak action", photo.score.peakAction),
                ("ball", photo.score.ballInFrame),
                ("exposure", photo.score.exposure),
                ("composition", photo.score.composition),
                ("convergence", photo.score.convergence)
            ]
            let values = dimensions.compactMap { label, value in
                value.map { "\(label) \(String(format: "%.1f", $0))" }
            }
            if !values.isEmpty { parts.append(values.joined(separator: ", ")) }
            if let number = photo.score.jerseyNumber { parts.append("jersey #\(number)") }
            if let reason = photo.score.rejectReason { parts.append(reason) }
            if !photo.score.lightroomSuggestions.isEmpty {
                parts.append(photo.score.lightroomSuggestions.joined(separator: " · "))
            }
            comments = parts.joined(separator: " | ")
        }

        private static func color(for category: String) -> String {
            switch category {
            case "Keepers": "Green"
            case "Near Miss": "Blue"
            case "Review": "Yellow"
            default: "Red"
            }
        }
    }

    private struct ScriptResponse: Decodable {
        let imported: Int
        let reused: Int
        let failed: Int
        let projectName: String
        let failures: [String]

        enum CodingKeys: String, CodingKey {
            case imported, reused, failed, failures
            case projectName = "project_name"
        }
    }

    private static let pythonScript = #"""
import json
import os
import sys
import time

import DaVinciResolveScript as dvr_script


def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)


with open(sys.argv[1], "r", encoding="utf-8") as handle:
    manifest = json.load(handle)

resolve = None
deadline = time.time() + 60
while resolve is None and time.time() < deadline:
    resolve = dvr_script.scriptapp("Resolve")
    if resolve is None:
        time.sleep(1)

if resolve is None:
    fail(
        "SoccerShots could not connect to Resolve Studio. In Resolve, open "
        "Settings > System > General and set External scripting to Local, then try again."
    )

manager = resolve.GetProjectManager()
project = manager.GetCurrentProject()
if project is None:
    fail("Open or create a Resolve project, then choose Send to Resolve Studio again.")
if project.GetName() not in manager.GetProjectListInCurrentFolder():
    fail("Save the open Resolve project with a name, then choose Send to Resolve Studio again.")

pool = project.GetMediaPool()
root = pool.GetRootFolder()


def ensure_folder(parent, name):
    for folder in parent.GetSubFolderList():
        if folder.GetName() == name:
            return folder
    folder = pool.AddSubFolder(parent, name)
    if folder is None:
        fail("Resolve could not create the media folder: " + name)
    return folder


def collect_clips(folder, found):
    for clip in folder.GetClipList():
        properties = clip.GetClipProperty()
        path = properties.get("File Path") or properties.get("FilePath")
        if path:
            found[os.path.normcase(os.path.realpath(path))] = (clip, folder)
    for child in folder.GetSubFolderList():
        collect_clips(child, found)


soccer_folder = ensure_folder(root, "SoccerShots")
session_folder = ensure_folder(soccer_folder, manifest["session_name"])
category_folders = {
    name: ensure_folder(session_folder, name)
    for name in ("Keepers", "Near Miss", "Review", "Rejects")
}

existing = {}
collect_clips(root, existing)
imported = 0
reused = 0
failures = []

for photo in manifest["photos"]:
    try:
        normalized = os.path.normcase(os.path.realpath(photo["path"]))
        target = category_folders[photo["category"]]
        match = existing.get(normalized)
        if match:
            clip, current_folder = match
            if current_folder.GetUniqueId() != target.GetUniqueId():
                if not pool.MoveClips([clip], target):
                    raise RuntimeError("could not move the existing clip into " + photo["category"])
            was_reused = True
        else:
            if not pool.SetCurrentFolder(target):
                raise RuntimeError("could not select the destination folder")
            added = pool.ImportMedia([{"FilePath": photo["path"]}])
            if not added:
                # Resolve 21.1.1 can reject the documented clip-info form for
                # still images while accepting the legacy simple-path form.
                added = pool.ImportMedia([photo["path"]])
            if not added:
                raise RuntimeError("Resolve could not import this file")
            clip = added[0]
            existing[normalized] = (clip, target)
            was_reused = False

        metadata = {
            "Rating": str(photo["rating"]),
            "Comments": photo["comments"],
            "Keywords": photo["keywords"],
        }
        for key, value in metadata.items():
            if not clip.SetMetadata({key: value}):
                raise RuntimeError("Resolve rejected the " + key + " metadata")
        if not clip.SetClipColor(photo["clip_color"]):
            raise RuntimeError("Resolve rejected the category color")
        if was_reused:
            reused += 1
        else:
            imported += 1
    except Exception as error:
        failures.append(photo["filename"] + ": " + str(error))

if not manager.SaveProject():
    fail("Resolve imported the photos but could not save the open project.")
resolve.OpenPage("photo")
response = {
    "imported": imported,
    "reused": reused,
    "failed": len(failures),
    "project_name": project.GetName(),
    "failures": failures,
}
print("SOCCERSHOTS_RESULT:" + json.dumps(response, separators=(",", ":")))
"""#
}
