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
    @Published private(set) var isRestoringSession = false
    @Published private(set) var isLoadingFolder = false
    @Published var selectedPhotoID: UUID?
    @Published var galleryFilter: GalleryFilter = .all { didSet { persistSession() } }
    @Published var gallerySort: GallerySort = .scoreDescending { didSet { persistSession() } }
    @Published var isShowingSettings = false
    @Published private(set) var isGeminiConfigured = false
    @Published private(set) var modelDiskUsageBytes: Int64 = 0
    @Published private(set) var localModelID: String
    @Published private(set) var geminiModelID: String
    @Published var presentedError: String?

    private var scorer: LocalGemmaService
    private let keychain = KeychainStore()
    private let sessionStore = SessionStore()
    private var scoringTask: Task<Void, Never>?
    private var folderLoadingTask: Task<Void, Never>?
    private var folderLoadID: UUID?
    private var activeFolderBookmark: Data?
    private var securityScopedFolderURL: URL?
    private var hasAttemptedSessionRestore = false

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
        case .scoreDescending:
            return filtered.sorted { $0.score.composite > $1.score.composite }
        case .scoreAscending:
            return filtered.sorted { $0.score.composite < $1.score.composite }
        case .filename:
            return filtered.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        }
    }

    var selectedPhoto: ScoredPhoto? {
        guard let selectedPhotoID else { return nil }
        return completedScores.first { $0.id == selectedPhotoID }
    }

    var photoBursts: [PhotoBurst] {
        BurstGrouping.make(discovered: discoveredPhotos, scored: completedScores)
    }

    func chooseFolder(modelContext: ModelContext) {
        guard !isLoadingFolder else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a soccer photo folder"
        panel.prompt = "Choose Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        inspectFolder(url, modelContext: modelContext)
    }

    func inspectFolder(_ url: URL, modelContext: ModelContext) {
        beginFolderLoad(url, restoring: nil, modelContext: modelContext)
    }

    func restoreSessionIfAvailable(modelContext: ModelContext) {
        guard !hasAttemptedSessionRestore else { return }
        hasAttemptedSessionRestore = true
        guard let snapshot = sessionStore.load() else { return }

        do {
            let folder = try restoredFolder(from: snapshot)
            beginFolderLoad(folder, restoring: snapshot, modelContext: modelContext)
        } catch {
            sessionStore.clear()
            presentedError = "The previous session could not be restored. Choose the photo folder again.\n\n\(error.localizedDescription)"
        }
    }

    func cancelFolderLoading() {
        folderLoadingTask?.cancel()
        folderLoadingTask = nil
        folderLoadID = nil
        isLoadingFolder = false
        isRestoringSession = false
        progress = .idle
    }

    func closeSession() {
        scoringTask?.cancel()
        cancelFolderLoading()
        securityScopedFolderURL?.stopAccessingSecurityScopedResource()
        securityScopedFolderURL = nil
        activeFolderBookmark = nil
        selectedFolder = nil
        discoveredPhotos = []
        completedScores = []
        selectedPhotoID = nil
        progress = .idle
        sessionStore.clear()
    }

    func startScoring(modelContext: ModelContext, isPostProcessed: Bool = false) {
        guard !isScoring, !isLoadingFolder, let folder = selectedFolder, !discoveredPhotos.isEmpty else { return }
        isScoring = true
        completedScores = []
        selectedPhotoID = nil
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
                    if selectedPhotoID == nil { selectedPhotoID = completedScores.last?.id }
                    completed += 1
                    persistSession()
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
                    if selectedPhotoID == nil { selectedPhotoID = scored.id }
                    completed += 1
                    persistSession()
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
            persistSession()
        }
    }

    func cancelScoring() { scoringTask?.cancel() }

    func selectPhoto(_ id: UUID?) {
        selectedPhotoID = id
        persistSession()
    }

    func moveSelection(by offset: Int) {
        let photos = visiblePhotos
        guard !photos.isEmpty else { selectedPhotoID = nil; return }
        guard let selectedPhotoID, let index = photos.firstIndex(where: { $0.id == selectedPhotoID }) else {
            self.selectedPhotoID = photos[0].id
            return
        }
        self.selectedPhotoID = photos[min(photos.count - 1, max(0, index + offset))].id
        persistSession()
    }

    func markBurstWinner(_ winnerID: UUID, in burst: PhotoBurst, modelContext: ModelContext) {
        let burstIDs = Set(burst.photos.map(\.id))
        for index in completedScores.indices where burstIDs.contains(completedScores[index].id) {
            let isWinner = completedScores[index].id == winnerID
            let record = try? record(for: completedScores[index].fileURL.path, modelContext: modelContext)
            completedScores[index].isSelectedForExport = isWinner
            completedScores[index].isManuallyRejected = !isWinner
            record?.isSelectedForExport = isWinner
            record?.isManuallyRejected = !isWinner
        }
        selectedPhotoID = winnerID
        do { try modelContext.save() }
        catch { presentedError = error.localizedDescription }
        persistSession()
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
        persistSession()
    }

    private func beginFolderLoad(
        _ url: URL,
        restoring snapshot: SessionSnapshot?,
        modelContext: ModelContext
    ) {
        folderLoadingTask?.cancel()
        let loadID = UUID()
        folderLoadID = loadID
        isLoadingFolder = true
        isRestoringSession = snapshot != nil
        progress = .discovering
        activateFolderAccess(url)
        activeFolderBookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        folderLoadingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let discoveryTask = Task.detached(priority: .userInitiated) {
                    try PhotoDiscovery().discover(in: url)
                }
                let photos = try await withTaskCancellationHandler {
                    try await discoveryTask.value
                } onCancel: {
                    discoveryTask.cancel()
                }
                try Task.checkCancellation()
                guard folderLoadID == loadID else { return }
                try applyFolder(url, photos: photos, modelContext: modelContext)
                if let snapshot {
                    galleryFilter = snapshot.galleryFilter
                    gallerySort = snapshot.gallerySort
                    selectedPhotoID = snapshot.selectedPhotoPath.flatMap { path in
                        completedScores.first { $0.fileURL.path == path }?.id
                    } ?? visiblePhotos.first?.id
                }
                progress = .idle
                persistSession()
            } catch is CancellationError {
                guard folderLoadID == loadID else { return }
                progress = .idle
            } catch {
                guard folderLoadID == loadID else { return }
                if snapshot != nil { sessionStore.clear() }
                progress = .idle
                presentedError = snapshot == nil
                    ? error.localizedDescription
                    : "The previous session could not be restored. Choose the photo folder again.\n\n\(error.localizedDescription)"
            }
            guard folderLoadID == loadID else { return }
            folderLoadingTask = nil
            folderLoadID = nil
            isLoadingFolder = false
            isRestoringSession = false
        }
    }

    private func applyFolder(_ url: URL, photos: [DiscoveredPhoto], modelContext: ModelContext) throws {
        let records = try modelContext.fetch(FetchDescriptor<ScoreRecord>())
        let cachedByPath = Dictionary(uniqueKeysWithValues: records.map { ($0.filepath, $0) })
        selectedFolder = url
        discoveredPhotos = photos
        completedScores = photos.compactMap { photo in
            guard let record = cachedByPath[photo.url.path], record.cacheMatches(photo), let score = record.score else {
                return nil
            }
            return Self.photo(from: record, score: score)
        }
        selectedPhotoID = completedScores.first?.id
    }

    private func restoredFolder(from snapshot: SessionSnapshot) throws -> URL {
        if let bookmark = snapshot.folderBookmark {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), !isStale, FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        let fallback = URL(fileURLWithPath: snapshot.folderPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: fallback.path) else {
            throw SoccerShotsError.message("The folder no longer exists at \(snapshot.folderPath).")
        }
        return fallback
    }

    private func activateFolderAccess(_ url: URL) {
        securityScopedFolderURL?.stopAccessingSecurityScopedResource()
        securityScopedFolderURL = url.startAccessingSecurityScopedResource() ? url : nil
    }

    private func persistSession() {
        guard let folder = selectedFolder else { return }
        let selectedPath = completedScores.first { $0.id == selectedPhotoID }?.fileURL.path
        let snapshot = SessionSnapshot(
            folderPath: folder.path,
            folderBookmark: activeFolderBookmark,
            selectedPhotoPath: selectedPath,
            galleryFilter: galleryFilter,
            gallerySort: gallerySort,
            updatedAt: Date()
        )
        do { try sessionStore.save(snapshot) }
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
