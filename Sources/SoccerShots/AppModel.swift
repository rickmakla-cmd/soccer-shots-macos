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
    @Published private(set) var isBenchmarking = false
    @Published private(set) var isDeepReviewing = false
    @Published private(set) var isExporting = false
    @Published private(set) var isRestoringSession = false
    @Published private(set) var isLoadingFolder = false
    @Published var selectedPhotoID: UUID?
    @Published var galleryFilter: GalleryFilter = .all { didSet { persistSession() } }
    @Published var gallerySort: GallerySort = .scoreDescending { didSet { persistSession() } }
    @Published var isShowingSettings = false
    @Published private(set) var isGeminiConfigured = false
    @Published private(set) var modelDiskUsageBytes: Int64 = 0
    @Published private(set) var localModelID: String
    @Published private(set) var benchmarkModelID: String
    @Published private(set) var geminiModelID: String
    @Published private(set) var benchmarkProgress: BenchmarkProgress = .idle
    @Published private(set) var exportProgress: ExportProgress = .idle
    @Published private(set) var lastExportFolder: URL?
    @Published var presentedError: String?
    @Published var presentedNotice: String?

    private var scorer: LocalGemmaService
    private let keychain = KeychainStore()
    private let sessionStore = SessionStore()
    private var scoringTask: Task<Void, Never>?
    private var benchmarkTask: Task<Void, Never>?
    private var folderLoadingTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var folderLoadID: UUID?
    private var activeFolderBookmark: Data?
    private var securityScopedFolderURL: URL?
    private var hasAttemptedSessionRestore = false

    init() {
        let defaults = UserDefaults.standard
        let localID = defaults.string(forKey: "SoccerShots.localModelID") ?? LocalGemmaService.defaultModelID
        localModelID = localID
        benchmarkModelID = defaults.string(forKey: "SoccerShots.benchmarkModelID")
            ?? LocalGemmaService.defaultBenchmarkModelID
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

    var benchmarkedPhotos: [ScoredPhoto] {
        completedScores.filter { $0.benchmarkResult?.modelID == benchmarkModelID }
    }

    var benchmarkSummary: BenchmarkSummary? {
        BenchmarkAnalysis.summary(for: benchmarkedPhotos)
    }

    var selectedForExport: [ScoredPhoto] {
        completedScores.filter(\.isSelectedForExport)
    }

    func chooseFolder(modelContext: ModelContext) {
        guard !isLoadingFolder, !isBenchmarking, !isExporting else { return }
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
        benchmarkTask?.cancel()
        exportTask?.cancel()
        cancelFolderLoading()
        securityScopedFolderURL?.stopAccessingSecurityScopedResource()
        securityScopedFolderURL = nil
        activeFolderBookmark = nil
        selectedFolder = nil
        discoveredPhotos = []
        completedScores = []
        selectedPhotoID = nil
        progress = .idle
        benchmarkProgress = .idle
        isBenchmarking = false
        isExporting = false
        exportProgress = .idle
        lastExportFolder = nil
        sessionStore.clear()
    }

    func exportSelectedPhotos() {
        guard !isScoring, !isBenchmarking, !isDeepReviewing, !isLoadingFolder, !isExporting else { return }
        let photos = selectedForExport
        guard !photos.isEmpty else {
            presentedError = "Select at least one photo before exporting."
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Export selected originals and Lightroom XMP sidecars"
        panel.message = "SoccerShots will copy each selected original and place a matching .xmp sidecar beside it. Existing files are never overwritten."
        panel.prompt = "Export Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let hasNonSidecarFormat = photos.contains {
            !PhotoDiscovery.proprietaryRawExtensions.contains($0.fileURL.pathExtension.lowercased())
        }
        let isAccessing = destination.startAccessingSecurityScopedResource()
        isExporting = true
        exportProgress = .exporting(index: 0, total: photos.count, filename: "Preparing export…")

        exportTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if isAccessing { destination.stopAccessingSecurityScopedResource() }
            }
            let worker = Task.detached(priority: .userInitiated) {
                try ExportService().export(photos: photos, to: destination) { update in
                    Task { @MainActor [weak self] in self?.exportProgress = update }
                }
            }
            do {
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                lastExportFolder = destination
                let formatNote = hasNonSidecarFormat
                    ? "\n\nNote: Adobe automatically reads sidecar develop settings for camera RAW files. Raster files were copied with an XMP record, but Lightroom may require metadata to be embedded in those files."
                    : ""
                let failureNote = result.failures.isEmpty
                    ? ""
                    : "\n\n\(result.failures.prefix(3).joined(separator: "\n"))"
                presentedNotice = "Exported \(result.exported) photo\(result.exported == 1 ? "" : "s") with Lightroom XMP to:\n\(destination.path)\n\nImport the originals from this folder into Lightroom Classic; the matching sidecars contain the rating and suggested develop settings.\(formatNote)\(failureNote)"
            } catch is CancellationError {
                exportProgress = .idle
            } catch {
                presentedError = "The export could not be completed.\n\n\(error.localizedDescription)"
                exportProgress = .idle
            }
            isExporting = false
            exportTask = nil
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    func revealLastExport() {
        guard let lastExportFolder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastExportFolder])
    }

    func startScoring(modelContext: ModelContext, isPostProcessed: Bool = false) {
        guard !isScoring, !isBenchmarking, !isLoadingFolder, !isExporting,
              let folder = selectedFolder, !discoveredPhotos.isEmpty else { return }
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
                        scoringEngine: "mlx:\(localModelID)", score: score, deepReview: nil,
                        isPostProcessed: isPostProcessed, isManuallyRejected: false,
                        isSelectedForExport: false
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

    func startBenchmark(sampleCount: Int, modelContext: ModelContext) {
        guard !isScoring, !isBenchmarking, !isDeepReviewing, !isLoadingFolder, !isExporting else { return }
        let candidates = BenchmarkAnalysis.evenlySpaced(visiblePhotos, count: sampleCount)
        guard !candidates.isEmpty else { return }
        let candidateModelID = benchmarkModelID
        isBenchmarking = true
        benchmarkProgress = .unloadingPrimary

        benchmarkTask = Task { [weak self] in
            guard let self else { return }
            await scorer.unload()
            guard !Task.isCancelled else {
                isBenchmarking = false
                benchmarkProgress = .idle
                benchmarkTask = nil
                return
            }

            let candidateScorer = LocalGemmaService(modelID: candidateModelID)
            var completed = 0
            var failed = 0
            var lastFailure: String?

            do {
                try await candidateScorer.verifyVision { [weak self] message in
                    Task { @MainActor in self?.benchmarkProgress = .model("Gemma 4: \(message)") }
                }
            } catch is CancellationError {
                await candidateScorer.unload()
                isBenchmarking = false
                benchmarkProgress = .idle
                benchmarkTask = nil
                return
            } catch {
                await candidateScorer.unload()
                isBenchmarking = false
                benchmarkProgress = .finished(completed: 0, failed: candidates.count)
                benchmarkTask = nil
                refreshModelDiskUsage()
                presentedError = error.localizedDescription
                return
            }

            for (offset, candidate) in candidates.enumerated() {
                guard !Task.isCancelled else { break }
                let index = offset + 1
                benchmarkProgress = .preparing(
                    index: index,
                    total: candidates.count,
                    filename: candidate.filename
                )
                let startedAt = Date()
                do {
                    let score = try await candidateScorer.score(photoURL: candidate.fileURL) { [weak self] message in
                        Task { @MainActor in self?.benchmarkProgress = .model("Gemma 4: \(message)") }
                    }
                    try Task.checkCancellation()
                    let result = ModelBenchmarkResult(
                        modelID: candidateModelID,
                        scoredAt: Date(),
                        durationSeconds: Date().timeIntervalSince(startedAt),
                        score: score
                    )
                    guard let current = completedScores.firstIndex(where: { $0.fileURL.path == candidate.fileURL.path }) else {
                        continue
                    }
                    completedScores[current].benchmarkResult = result
                    if let record = try? record(for: candidate.fileURL.path, modelContext: modelContext) {
                        try record.setBenchmarkResult(result)
                        try modelContext.save()
                    }
                    completed += 1
                } catch is CancellationError {
                    break
                } catch {
                    failed += 1
                    lastFailure = "\(candidate.filename): \(error.localizedDescription)"
                }
            }

            await candidateScorer.unload()
            benchmarkProgress = .finished(completed: completed, failed: failed)
            isBenchmarking = false
            benchmarkTask = nil
            refreshModelDiskUsage()
            if completed == 0, let lastFailure {
                presentedError = "Gemma 4 could not complete the benchmark.\n\n\(lastFailure)"
            }
        }
    }

    func cancelBenchmark() { benchmarkTask?.cancel() }

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
        guard let photo = completedScores.first(where: { $0.id == id }) else { return }
        setExportSelection(!photo.isSelectedForExport, for: [id])
        commitExportSelections(for: [id], modelContext: modelContext)
    }

    func setVisibleExportSelection(_ selected: Bool, modelContext: ModelContext) {
        let ids = Set(visiblePhotos.map(\.id))
        guard !ids.isEmpty else { return }
        setExportSelection(selected, for: ids)
        commitExportSelections(for: ids, modelContext: modelContext)
    }

    /// Updates the gallery immediately while a pointer drag is in progress.
    /// SwiftData is committed once at the end of the drag to avoid a disk write
    /// for every card the pointer crosses.
    func setExportSelection(_ selected: Bool, for ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for index in completedScores.indices where ids.contains(completedScores[index].id) {
            completedScores[index].isSelectedForExport = selected
        }
    }

    func commitExportSelections(for ids: Set<UUID>, modelContext: ModelContext) {
        guard !ids.isEmpty else { return }
        let photos = completedScores.filter { ids.contains($0.id) }
        let selectedByPath = Dictionary(uniqueKeysWithValues: photos.map {
            ($0.fileURL.path, $0.isSelectedForExport)
        })
        do {
            let records = try modelContext.fetch(FetchDescriptor<ScoreRecord>())
            for record in records {
                if let selected = selectedByPath[record.filepath] {
                    record.isSelectedForExport = selected
                }
            }
            try modelContext.save()
        } catch {
            presentedError = error.localizedDescription
        }
        persistSession()
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

    func updateBenchmarkModelID(_ modelID: String) {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != benchmarkModelID else { return }
        benchmarkModelID = trimmed
        UserDefaults.standard.set(trimmed, forKey: "SoccerShots.benchmarkModelID")
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
        guard !isDeepReviewing, !isBenchmarking, !isExporting,
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
            score: score, deepReview: record.deepReview, benchmarkResult: record.benchmarkResult,
            isPostProcessed: record.isPostProcessed,
            isManuallyRejected: record.isManuallyRejected, isSelectedForExport: record.isSelectedForExport
        )
    }
}
