import AppKit
import ImageIO
import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var model: AppModel
    @State private var isShowingBurstComparison = false
    @State private var isShowingBenchmark = false
    @State private var isConfirmingGeminiBatch = false

    var body: some View {
        NavigationSplitView {
            List {
                Section("Session") {
                    Button("Choose Photo Folder…", systemImage: "folder") {
                        model.chooseFolder(modelContext: modelContext)
                    }
                    .disabled(model.isLoadingFolder || model.isBenchmarking || model.isExporting)
                    if let folder = model.selectedFolder {
                        LabeledContent("Folder", value: folder.lastPathComponent)
                        LabeledContent("Photos", value: "\(model.discoveredPhotos.count)")
                        Button("Compare \(model.photoBursts.count) Bursts…", systemImage: "square.grid.2x2") {
                            isShowingBurstComparison = true
                        }
                        .disabled(model.photoBursts.isEmpty)
                        Button("Close Session", systemImage: "xmark.circle") { model.closeSession() }
                            .disabled(model.isBenchmarking || model.isExporting)
                    }
                }
                if model.isLoadingFolder {
                    Section("Folder Scan") {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(model.isRestoringSession ? "Restoring session…" : "Reading RAW metadata…")
                        }
                        Button("Cancel Folder Scan", role: .cancel) { model.cancelFolderLoading() }
                    }
                }
                if !model.discoveredPhotos.isEmpty {
                    Section("Run") {
                        Button("Score \(model.discoveredPhotos.count) Originals", systemImage: "sparkles") {
                            model.startScoring(modelContext: modelContext)
                        }
                        .disabled(model.isScoring || model.isBenchmarking || model.isLoadingFolder)
                        if model.isScoring {
                            Button("Cancel after current photo", role: .cancel) { model.cancelScoring() }
                        }
                        if !model.completedScores.isEmpty {
                            Button("Evidence Benchmark…", systemImage: "arrow.left.arrow.right") {
                                isShowingBenchmark = true
                            }
                            .disabled(model.isScoring || model.isBenchmarking || model.isDeepReviewing)
                        }
                        if model.isBenchmarking {
                            Button("Cancel A/B after current photo", role: .cancel) { model.cancelBenchmark() }
                        }
                    }
                }
                if !model.completedScores.isEmpty {
                    Section("Export") {
                        Button {
                            model.exportSelectedPhotos()
                        } label: {
                            Label(
                                "Export \(model.selectedForExport.count) Selected + XMP…",
                                systemImage: "square.and.arrow.up"
                            )
                        }
                        .disabled(
                            model.selectedForExport.isEmpty || model.isScoring || model.isBenchmarking ||
                            model.isDeepReviewing || model.isLoadingFolder || model.isExporting
                        )
                        .help("Copy selected originals and create matching Lightroom XMP sidecars")

                        if model.isExporting {
                            VStack(alignment: .leading, spacing: 6) {
                                ProgressView()
                                Text(model.exportProgress.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Button("Cancel Export", role: .cancel) { model.cancelExport() }
                        }

                        if model.lastExportFolder != nil, !model.isExporting {
                            Button("Show Last Export in Finder", systemImage: "folder.badge.gearshape") {
                                model.revealLastExport()
                            }
                        }

                        Text("Copies originals and writes Lightroom ratings and suggested develop settings to same-name .xmp sidecars.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !model.completedScores.isEmpty || !model.activeGeminiBatchJobs.isEmpty {
                    Section("Gemini Batch") {
                        if model.activeGeminiBatchJobs.isEmpty {
                            Button {
                                if model.isGeminiConfigured {
                                    isConfirmingGeminiBatch = true
                                } else {
                                    model.isShowingSettings = true
                                }
                            } label: {
                                Label(
                                    "Score \(model.selectedForExport.count) Selected…",
                                    systemImage: "cloud.arrow.up"
                                )
                            }
                            .disabled(
                                model.selectedForExport.isEmpty || model.isScoring || model.isBenchmarking ||
                                model.isDeepReviewing || model.isExporting || model.isGeminiBatchRunning
                            )
                        } else if model.isGeminiBatchRunning {
                            ProgressView()
                            Text(model.geminiBatchProgress.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Pause Monitoring", role: .cancel) { model.pauseGeminiBatchMonitoring() }
                        } else {
                            Text("\(model.activeGeminiBatchJobs.count) submitted job\(model.activeGeminiBatchJobs.count == 1 ? "" : "s")")
                            Button("Resume Result Check", systemImage: "arrow.clockwise") {
                                model.resumeGeminiBatches(modelContext: modelContext)
                            }
                        }
                        Text("Uses Google’s asynchronous Batch API at the discounted batch rate. Results can take up to 24 hours and never replace Gemma scores.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Configuration") {
                    Button("Settings…", systemImage: "gearshape") { model.isShowingSettings = true }
                    LabeledContent("Primary", value: "Gemma local")
                    LabeledContent("Deep Review", value: model.isGeminiConfigured ? "Configured" : "Optional")
                }
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 270)
        } detail: {
            Group {
                if model.isLoadingFolder {
                    FolderLoadingView()
                } else if model.selectedFolder == nil {
                    ContentUnavailableView(
                        "Score Soccer Photos Locally",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("Choose a folder to find supported photos. Nothing is uploaded during scoring.")
                    )
                } else if model.completedScores.isEmpty {
                    ReadyToScoreView()
                } else {
                    ScoreGallery()
                }
            }
            .safeAreaInset(edge: .bottom) { statusBar }
        }
        .task {
            model.restoreSessionIfAvailable(modelContext: modelContext)
            model.resumeGeminiBatches(modelContext: modelContext)
        }
        .sheet(isPresented: $model.isShowingSettings) { SettingsView() }
        .sheet(isPresented: $isShowingBurstComparison) {
            BurstComparisonView(isPresented: $isShowingBurstComparison)
        }
        .sheet(isPresented: $isShowingBenchmark) {
            BenchmarkView(isPresented: $isShowingBenchmark)
        }
        .alert("SoccerShots", isPresented: Binding(
            get: { model.presentedError != nil },
            set: { if !$0 { model.presentedError = nil } }
        )) { Button("OK") { model.presentedError = nil } } message: {
            Text(model.presentedError ?? "")
        }
        .alert("SoccerShots", isPresented: Binding(
            get: { model.presentedNotice != nil },
            set: { if !$0 { model.presentedNotice = nil } }
        )) {
            if model.lastExportFolder != nil {
                Button("Show in Finder") {
                    model.revealLastExport()
                    model.presentedNotice = nil
                }
            }
            Button("OK") { model.presentedNotice = nil }
        } message: {
            Text(model.presentedNotice ?? "")
        }
        .confirmationDialog(
            "Submit \(model.selectedForExport.count) photos for Gemini Batch Scoring?",
            isPresented: $isConfirmingGeminiBatch,
            titleVisibility: .visible
        ) {
            Button("Submit Discounted Batch") {
                model.startGeminiBatch(modelContext: modelContext)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This sends prepared copies and the full scoring rubric to Gemini. Google says Batch API requests cost 50% of standard requests and can take up to 24 hours. A paid Gemini API project is required.")
        }
    }

    private var statusBar: some View {
        HStack {
            if model.isScoring || model.isBenchmarking || model.isDeepReviewing || model.isGeminiBatchRunning || model.isLoadingFolder || model.isExporting {
                ProgressView().controlSize(.small)
            }
            Text(statusMessage)
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text("Gemma local · offline primary").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }

    private var statusMessage: String {
        if model.isScoring { return model.progress.message }
        if model.isExporting { return model.exportProgress.message }
        if model.isBenchmarking { return model.benchmarkProgress.message }
        if model.isDeepReviewing { return "Gemini is performing an explicit Deep Review…" }
        if model.isGeminiBatchRunning { return model.geminiBatchProgress.message }
        return model.progress.message
    }
}

private struct FolderLoadingView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            ProgressView().controlSize(.large)
            Text(model.isRestoringSession ? "Restoring your last session" : "Reading the photo folder")
                .font(.title2.bold())
            Text("SoccerShots is reading RAW metadata in the background. The app remains usable, and you can cancel from the sidebar.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
        }
        .padding(40)
    }
}

private struct ReadyToScoreView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "photo.stack")
                .font(.system(size: 50)).foregroundStyle(.secondary)
            Text("\(model.discoveredPhotos.count) photos ready").font(.title2.bold())
            Text("RAW+JPEG pairs have been deduplicated. Scoring runs one photo at a time with local Gemma.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
            if model.isScoring || model.isLoadingFolder { ProgressView().controlSize(.large) }
        }.padding(40)
    }
}

private struct ScoreGallery: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var model: AppModel
    @FocusState private var acceptsKeyboardInput: Bool
    @State private var isShowingDetail = false
    @State private var isShowingBurstComparison = false
    @State private var photoFrames: [UUID: CGRect] = [:]
    @State private var marqueeStart: CGPoint?
    @State private var marqueeCurrent: CGPoint?
    @State private var marqueeBaselineIDs: Set<UUID> = []
    @State private var marqueeCurrentIDs: Set<UUID> = []
    @State private var marqueeTouchedIDs: Set<UUID> = []
    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 16)]

    private var visibleSelectedCount: Int {
        model.visiblePhotos.filter(\.isSelectedForExport).count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Filter", selection: $model.galleryFilter) {
                    ForEach(GalleryFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Menu {
                    Picker("Sort", selection: $model.gallerySort) {
                        ForEach(GallerySort.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: { Label(model.gallerySort.rawValue, systemImage: "arrow.up.arrow.down") }
                Button {
                    isShowingBurstComparison = true
                } label: {
                    Label("Compare Bursts", systemImage: "square.grid.2x2")
                }
                .disabled(model.photoBursts.isEmpty)
                Divider().frame(height: 20)
                Button("Select All") {
                    model.setVisibleExportSelection(true, modelContext: modelContext)
                }
                .disabled(visibleSelectedCount == model.visiblePhotos.count)
                .keyboardShortcut("a", modifiers: .command)
                .help("Select every photo in the current filter")
                Button("Deselect All") {
                    model.setVisibleExportSelection(false, modelContext: modelContext)
                }
                .disabled(visibleSelectedCount == 0)
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .help("Deselect every photo in the current filter")
                Text("\(visibleSelectedCount) selected · \(model.visiblePhotos.count) shown")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(16).background(.bar)

            if model.visiblePhotos.isEmpty {
                ContentUnavailableView("No photos in this filter", systemImage: "line.3.horizontal.decrease.circle")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(model.visiblePhotos) { photo in
                            PhotoCard(photo: photo, isFocused: model.selectedPhotoID == photo.id)
                                .contentShape(Rectangle())
                                .background {
                                    GeometryReader { proxy in
                                        Color.clear.preference(
                                            key: PhotoFramePreferenceKey.self,
                                            value: [photo.id: proxy.frame(in: .named("scoreGallery"))]
                                        )
                                    }
                                }
                                .onTapGesture {
                                    model.selectPhoto(photo.id)
                                    model.toggleExportSelection(for: photo.id, modelContext: modelContext)
                                }
                                .onTapGesture(count: 2) {
                                    model.selectPhoto(photo.id)
                                    isShowingDetail = true
                                }
                        }
                    }.padding(20)
                }
                .coordinateSpace(name: "scoreGallery")
                .onPreferenceChange(PhotoFramePreferenceKey.self) { photoFrames = $0 }
                .overlay { marqueeOverlay }
                .highPriorityGesture(marqueeSelectionGesture)
            }
        }
        .focusable()
        .focused($acceptsKeyboardInput)
        .onAppear {
            acceptsKeyboardInput = true
            if model.selectedPhotoID == nil { model.selectPhoto(model.visiblePhotos.first?.id) }
        }
        .onKeyPress(.leftArrow) { model.moveSelection(by: -1); return .handled }
        .onKeyPress(.rightArrow) { model.moveSelection(by: 1); return .handled }
        .onKeyPress(.upArrow) { model.moveSelection(by: -3); return .handled }
        .onKeyPress(.downArrow) { model.moveSelection(by: 3); return .handled }
        .onKeyPress(.space) {
            if let id = model.selectedPhotoID { model.toggleExportSelection(for: id, modelContext: modelContext) }
            return .handled
        }
        .onKeyPress(.return) {
            if model.selectedPhoto != nil { isShowingDetail = true }
            return .handled
        }
        .onKeyPress("x") {
            if let id = model.selectedPhotoID { model.toggleManualReject(for: id, modelContext: modelContext) }
            return .handled
        }
        .sheet(isPresented: $isShowingDetail) {
            if let photo = model.selectedPhoto {
                PhotoDetailView(photo: photo, isPresented: $isShowingDetail)
            }
        }
        .sheet(isPresented: $isShowingBurstComparison) {
            BurstComparisonView(isPresented: $isShowingBurstComparison)
        }
    }

    private var marqueeSelectionGesture: some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("scoreGallery"))
            .onChanged { value in
                guard !model.isScoring, !model.isBenchmarking else { return }
                if marqueeStart == nil {
                    marqueeStart = value.startLocation
                    marqueeBaselineIDs = Set(model.visiblePhotos.filter(\.isSelectedForExport).map(\.id))
                }
                marqueeCurrent = value.location
                updateMarqueeSelection()
            }
            .onEnded { _ in
                if !marqueeTouchedIDs.isEmpty {
                    model.commitExportSelections(for: marqueeTouchedIDs, modelContext: modelContext)
                }
                if let id = marqueeCurrentIDs.first { model.selectPhoto(id) }
                marqueeStart = nil
                marqueeCurrent = nil
                marqueeBaselineIDs = []
                marqueeCurrentIDs = []
                marqueeTouchedIDs = []
            }
    }

    @ViewBuilder
    private var marqueeOverlay: some View {
        if let rect = marqueeRect {
            Rectangle()
                .fill(Color.accentColor.opacity(0.16))
                .overlay {
                    Rectangle().stroke(Color.accentColor, lineWidth: 1.5)
                }
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
        }
    }

    private var marqueeRect: CGRect? {
        guard let start = marqueeStart, let current = marqueeCurrent else { return nil }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    private func updateMarqueeSelection() {
        guard let rect = marqueeRect else { return }
        let inside = Set(photoFrames.compactMap { id, frame in
            rect.intersects(frame) ? id : nil
        })
        let previouslySelected = marqueeBaselineIDs.union(marqueeCurrentIDs)
        let shouldBeSelected = marqueeBaselineIDs.union(inside)
        let select = shouldBeSelected.subtracting(previouslySelected)
        let deselect = previouslySelected.subtracting(shouldBeSelected)
        model.setExportSelection(true, for: select)
        model.setExportSelection(false, for: deselect)
        marqueeTouchedIDs.formUnion(select)
        marqueeTouchedIDs.formUnion(deselect)
        marqueeCurrentIDs = inside
    }
}

private struct PhotoFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct PhotoCard: View {
    let photo: ScoredPhoto
    let isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                LocalThumbnail(url: photo.fileURL)
                    .frame(height: 150).clipShape(RoundedRectangle(cornerRadius: 10))
                    .opacity(photo.isManuallyRejected ? 0.45 : 1)
                Text(String(format: "%.1f", photo.score.composite))
                    .font(.headline.monospacedDigit()).padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.black.opacity(0.72), in: Capsule()).foregroundStyle(.white).padding(8)
                Image(systemName: photo.isSelectedForExport ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(photo.isSelectedForExport ? .cyan : .white.opacity(0.8))
                    .background(.black.opacity(0.6), in: Circle()).padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            Text(photo.filename).font(.headline).lineLimit(1)
            HStack {
                Text(photo.score.actionType.rawValue.capitalized)
                if let number = photo.score.jerseyNumber { Text("#\(number)") }
                Spacer()
                Text(photo.isManuallyRejected ? "Rejected" : photo.score.keepRecommendation ? "Keeper" : "Review")
                    .foregroundStyle(photo.isManuallyRejected ? .red : photo.score.keepRecommendation ? .green : .secondary)
            }.font(.caption)
            if let result = photo.benchmarkResult {
                HStack {
                    Text("Gemma 4")
                    Spacer()
                    Text(result.score.composite, format: .number.precision(.fractionLength(1))).monospacedDigit()
                    Text(String(format: "%+.1f", result.score.composite - photo.score.composite))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.caption2)
                .foregroundStyle(.purple)
            }
            if let result = photo.geminiBatchResult {
                HStack {
                    Text("Gemini")
                    Spacer()
                    if result.score.autoReject {
                        Text("Reject").fontWeight(.semibold)
                    } else {
                        Text(result.score.composite, format: .number.precision(.fractionLength(1))).monospacedDigit()
                        Text(String(format: "%+.1f", result.score.composite - photo.score.composite))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.orange)
                .help(result.score.rejectReason ?? "Gemini comparison")
            }
            if let result = photo.evidenceBenchmarkResults.max(by: { $0.scoredAt < $1.scoredAt }) {
                HStack {
                    Text("Evidence")
                    Spacer()
                    Text(result.score.composite, format: .number.precision(.fractionLength(1))).monospacedDigit()
                    Text(String(format: "%+.1f", result.score.composite - photo.score.composite))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.caption2)
                .foregroundStyle(.cyan)
            }
            if let consensus = photo.consensusAssessment {
                HStack {
                    Text("Agreement")
                    Spacer()
                    Text(consensus.summary).monospacedDigit()
                }
                .font(.caption2)
                .foregroundStyle(consensus.decision == .split ? .orange : .secondary)
            }
            if let label = photo.manualReviewLabel {
                HStack {
                    Text("Your label")
                    Spacer()
                    Text(label.title).fontWeight(.semibold)
                }
                .font(.caption2)
                .foregroundStyle(label == .keep ? .green : .red)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(isFocused ? Color.accentColor : .clear, lineWidth: 3)
        }
        .accessibilityLabel("\(photo.filename), score \(photo.score.composite)")
    }
}

struct LocalThumbnail: View {
    let url: URL
    var maxPixelSize: Int = 600
    var contentMode: ContentMode = .fill
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                if contentMode == .fill {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(nsImage: image).resizable().scaledToFit()
                }
            } else { Rectangle().fill(.quaternary).overlay { ProgressView() } }
        }
        .clipped()
        .task(id: url) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                  ] as CFDictionary) else { return }
            image = NSImage(cgImage: cg, size: .zero)
        }
    }
}
