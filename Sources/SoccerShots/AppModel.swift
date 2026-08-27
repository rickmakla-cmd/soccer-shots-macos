import AppKit
import Foundation
import SwiftData

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var selectedFolder: URL?
    @Published private(set) var discoveredPhotos: [DiscoveredPhoto] = []
    @Published private(set) var completedScores: [ScoredPhoto] = []
    @Published private(set) var progress: ScoringProgress = .idle
    @Published private(set) var isScoring = false
    @Published var presentedError: String?

    private let discovery = PhotoDiscovery()
    private let scorer = LocalGemmaService()
    private var scoringTask: Task<Void, Never>?

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a soccer photo folder"
        panel.prompt = "Choose Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        inspectFolder(url)
    }

    func inspectFolder(_ url: URL) {
        progress = .discovering
        do {
            let photos = try discovery.discover(in: url)
            selectedFolder = url
            discoveredPhotos = photos
            completedScores = []
            progress = .idle
        } catch {
            progress = .idle
            presentedError = error.localizedDescription
        }
    }

    func startScoring(modelContext: ModelContext, isPostProcessed: Bool = false) {
        guard !isScoring, let folder = selectedFolder, !discoveredPhotos.isEmpty else { return }
        isScoring = true
        completedScores = []
        let photos = discoveredPhotos
        scoringTask = Task { [weak self] in
            guard let self else { return }
            var completed = 0
            var failed = 0
            let existing = (try? modelContext.fetch(FetchDescriptor<ScoreRecord>())) ?? []
            let cachedByPath = Dictionary(uniqueKeysWithValues: existing.map { ($0.filepath, $0) })

            for (offset, photo) in photos.enumerated() {
                guard !Task.isCancelled else { break }
                let index = offset + 1
                if let cached = cachedByPath[photo.url.path], cached.cacheMatches(photo), let score = cached.score {
                    completedScores.append(Self.photo(from: cached, score: score))
                    completed += 1
                    continue
                }
                progress = .preparing(index: index, total: photos.count, filename: photo.url.lastPathComponent)
                do {
                    let score = try await scorer.score(photoURL: photo.url) { [weak self] message in
                        Task { @MainActor in self?.progress = .model(message) }
                    }
                    guard !Task.isCancelled else { break }
                    let scored = ScoredPhoto(
                        id: UUID(), fileURL: photo.url, filename: photo.url.lastPathComponent,
                        fileSize: photo.fileSize, modificationDate: photo.modificationDate,
                        sessionFolder: folder, scoredAt: Date(), scoringVersion: ScoringPrompt.version,
                        scoringEngine: "gemma-local", score: score, deepReview: nil,
                        isPostProcessed: isPostProcessed, isManuallyRejected: false,
                        isSelectedForExport: score.keepRecommendation
                    )
                    if let stale = cachedByPath[photo.url.path] { modelContext.delete(stale) }
                    modelContext.insert(try ScoreRecord(photo: scored))
                    try modelContext.save()
                    completedScores.append(scored)
                    completed += 1
                } catch is CancellationError {
                    break
                } catch {
                    failed += 1
                    presentedError = "\(photo.url.lastPathComponent): \(error.localizedDescription)"
                }
                progress = .scoring(index: index, total: photos.count, filename: photo.url.lastPathComponent)
            }
            progress = .finished(completed: completed, failed: failed)
            isScoring = false
            scoringTask = nil
        }
    }

    func cancelScoring() { scoringTask?.cancel() }

    private static func photo(from record: ScoreRecord, score: PhotoScore) -> ScoredPhoto {
        .init(
            id: UUID(), fileURL: URL(fileURLWithPath: record.filepath), filename: record.filename,
            fileSize: record.fileSize, modificationDate: record.modificationDate,
            sessionFolder: URL(fileURLWithPath: record.sessionFolder), scoredAt: record.scoredAt,
            scoringVersion: record.scoringVersion, scoringEngine: record.scoringEngine,
            score: score, deepReview: record.deepReview, isPostProcessed: record.isPostProcessed,
            isManuallyRejected: record.isManuallyRejected, isSelectedForExport: record.isSelectedForExport
        )
    }
}
