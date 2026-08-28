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
    @Published private(set) var isDeepReviewing = false
    @Published var selectedPhotoID: UUID?
    @Published var galleryFilter: GalleryFilter = .all
    @Published var gallerySort: GallerySort = .scoreDescending
    @Published var isShowingSettings = false
    @Published private(set) var isGeminiConfigured = false
    @Published private(set) var modelDiskUsageBytes: Int64 = 0
    @Published private(set) var localModelID: String
    @Published private(set) var geminiModelID: String
    @Published var presentedError: String?

    private let discovery = PhotoDiscovery()
    private var scorer: LocalGemmaService
    private let keychain = KeychainStore()
    private var scoringTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        let localID = defaults.string(forKey: "SoccerShots.localModelID") ?? LocalGemmaService.defaultModelID
        localModelID = localID
        geminiModelID = defaults.string(forKey: "SoccerShots.geminiModelID") ?? "gemini-2.5-pro"
        scorer = LocalGemmaService(modelID: localID)
        isGeminiConfigured = keychain.geminiAPIKey()?.isEmpty == false
        refreshModelDiskUsage()
    }

    var visiblePhotos: [ScoredPhoto] {
        let filtered = completedScores.filter(galleryFilter.includes)
        switch gallerySort {
        case .scoreDescending: filtered.sorted { $0.score.composite > $1.score.composite }
        case .scoreAscending: filtered.sorted { $0.score.composite < $1.score.composite }
        case .filename: filtered.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        }
    }

    var selectedPhoto: ScoredPhoto? {
        guard let selectedPhotoID else { return nil }
        return completedScores.first { $0.id == selectedPhotoID }
    }

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
            selectedPhotoID = nil
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
            refreshModelDiskUsage()
        }
    }

    func cancelScoring() { scoringTask?.cancel() }

    func selectPhoto(_ id: UUID?) { selectedPhotoID = id }

    func moveSelection(by offset: Int) {
        let photos = visiblePhotos
        guard !photos.isEmpty else { selectedPhotoID = nil; return }
        guard let selectedPhotoID, let index = photos.firstIndex(where: { $0.id == selectedPhotoID }) else {
            self.selectedPhotoID = photos[0].id
            return
        }
        self.selectedPhotoID = photos[min(photos.count - 1, max(0, index + offset))].id
    }

    func toggleExportSelection(for id: UUID, modelContext: ModelContext) {
        updatePhoto(id: id, modelContext: modelContext) { photo, record in
            photo.isSelectedForExport.toggle()
            record?.isSelectedForExport = photo.isSelectedForExport
        }
    }

    func toggleManualReject(for id: UUID, modelContext: ModelContext) {
        updatePhoto(id: id, modelContext: modelContext) { photo, record in
            photo.isManuallyRejected.toggle()
            record?.isManuallyRejected = photo.isManuallyRejected
        }
    }

    func saveGeminiSettings(apiKey: String, geminiModelID: String) {
        do {
            let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedKey.isEmpty { try keychain.saveGeminiAPIKey(trimmedKey) }
            let trimmedModel = geminiModelID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.geminiModelID = trimmedModel.isEmpty ? "gemini-2.5-pro" : trimmedModel
            UserDefaults.standard.set(self.geminiModelID, forKey: "SoccerShots.geminiModelID")
            isGeminiConfigured = keychain.geminiAPIKey()?.isEmpty == false
        } catch { presentedError = error.localizedDescription }
    }

    func removeGeminiAPIKey() {
        do {
            try keychain.saveGeminiAPIKey("")
            isGeminiConfigured = false
        } catch { presentedError = error.localizedDescription }
    }

    func updateLocalModelID(_ modelID: String) {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != localModelID else { return }
        localModelID = trimmed
        UserDefaults.standard.set(trimmed, forKey: "SoccerShots.localModelID")
        scorer = LocalGemmaService(modelID: trimmed)
    }

    func refreshModelDiskUsage() {
        var total: Int64 = 0
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        if let enumerator = FileManager.default.enumerator(
            at: ModelStorage.defaultDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true {
                    total += Int64(values.fileSize ?? 0)
                }
            }
        }
        modelDiskUsageBytes = total
    }

    func runDeepReview(for id: UUID, modelContext: ModelContext) {
        guard !isDeepReviewing,
              let index = completedScores.firstIndex(where: { $0.id == id }),
              let apiKey = keychain.geminiAPIKey(), !apiKey.isEmpty else {
            isShowingSettings = true
            return
        }
        let photo = completedScores[index]
        isDeepReviewing = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let review = try await GeminiDeepReviewClient(modelID: geminiModelID).review(
                    photoURL: photo.fileURL,
                    localScore: photo.score,
                    apiKey: apiKey
                )
                guard let current = completedScores.firstIndex(where: { $0.id == id }) else { return }
                completedScores[current].deepReview = review
                if let record = try? record(for: photo.fileURL.path, modelContext: modelContext) {
                    try record.setDeepReview(review)
                    try modelContext.save()
                }
            } catch { presentedError = error.localizedDescription }
            isDeepReviewing = false
        }
    }

    private func updatePhoto(
        id: UUID,
        modelContext: ModelContext,
        mutation: (inout ScoredPhoto, ScoreRecord?) -> Void
    ) {
        guard let index = completedScores.firstIndex(where: { $0.id == id }) else { return }
        let record = try? record(for: completedScores[index].fileURL.path, modelContext: modelContext)
        mutation(&completedScores[index], record)
        do { try modelContext.save() }
        catch { presentedError = error.localizedDescription }
    }

    private func record(for filepath: String, modelContext: ModelContext) throws -> ScoreRecord? {
        let records = try modelContext.fetch(FetchDescriptor<ScoreRecord>())
        return records.first { $0.filepath == filepath }
    }

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
